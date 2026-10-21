# =================================================================================================
#  IAM: TODAS las identidades del proyecto viven en este archivo.  Apuntes: docs/iam.md
#
#  Misma idea que las service accounts y el rol personalizado del lab de GCP:
#    - QUIÉN:  una identidad por propósito (cada Lambda, Glue, DMS, la EC2, cada analista, cada emisor).
#    - QUÉ:    una política propia, acción por acción, sobre recursos concretos. Nada de "s3:*" ni de
#              políticas administradas amplias (AWSGlueServiceRole, AWSLambdaBasicExecutionRole...).
#    - TECHO:  todas llevan el permissions boundary del proyecto (creado en infra/bootstrap/bootstrap.yaml).
#              El rol de despliegue NO puede crear roles sin ese límite: así no puede fabricarse un admin.
#    - ADITIVO: se usa aws_iam_role_policy / aws_iam_role_policy_attachment (añaden), nunca
#              aws_iam_policy_attachment (reemplaza TODOS los usos de una política, como set-iam-policy).
#
#  Dos mapas con la misma clave:
#    identities         -> QUIÉN: nombre, descripción y confianza de cada rol
#    identity_policies  -> QUÉ:   sus llaves exactas
#  Van separados porque las políticas nombran recursos (Lambdas, Step Functions) que a su vez
#  necesitan el rol ya creado; juntos formarían un ciclo.
# =================================================================================================

locals {
  boundary_arn = "arn:aws:iam::${local.account_id}:policy/${var.project}-workload-boundary"

  arn       = { for k, b in aws_s3_bucket.layer : k => b.arn }
  log_group = "arn:aws:logs:${var.region}:${local.account_id}:log-group"

  glue_db_arn  = { for k, d in aws_glue_catalog_database.layer : k => d.arn }
  glue_tables  = { for k, d in aws_glue_catalog_database.layer : k => "arn:aws:glue:${var.region}:${local.account_id}:table/${d.name}/*" }
  glue_catalog = "arn:aws:glue:${var.region}:${local.account_id}:catalog"

  glue_write_actions = [
    "glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:CreateTable", "glue:UpdateTable",
    "glue:GetPartition", "glue:GetPartitions", "glue:CreatePartition", "glue:BatchCreatePartition",
    "glue:UpdatePartition", "glue:DeletePartition", "glue:BatchDeletePartition",
  ]

  # --- Relaciones de confianza (quién puede ponerse el rol) ----------------------------------------
  trust = { for svc in ["lambda", "states", "scheduler", "glue", "dms", "ec2", "lakeformation", "cloudtrail", "vpc-flow-logs"] :
    svc => contains(["lambda", "ec2"], svc)
    ? jsonencode({ Version = "2012-10-17", Statement = [{
      Effect    = "Allow"
      Principal = { Service = "${svc}.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }] })
    # Evita el "confused deputy": el servicio sólo puede usar el rol actuando en ESTA cuenta
    : jsonencode({ Version = "2012-10-17", Statement = [{
      Effect    = "Allow"
      Principal = { Service = "${svc}.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }] })
  }

  trust_humans = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow"
    Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
    Action    = "sts:AssumeRole"
  }] })

  # ===============================================================================================
  #  QUIÉN
  # ===============================================================================================
  all_identities = merge(
    { for k in keys(local.functions) : k => {
      enabled     = true, name = "${local.name}-${k}", trust = local.trust["lambda"], instance_profile = false
      description = "Lambda ${k} del pipeline medallion"
    } },
    {
      pipeline-sfn = {
        enabled     = true, name = "${local.name}-pipeline-sfn", trust = local.trust["states"], instance_profile = false
        description = "Step Functions: invoca las 3 etapas del pipeline"
      }
      scheduler = {
        enabled     = true, name = "${local.name}-scheduler", trust = local.trust["scheduler"], instance_profile = false
        description = "EventBridge Scheduler: sólo puede iniciar el pipeline"
      }
      glue-gold-analytics = {
        enabled     = true, name = "${local.name}-glue-gold-analytics", trust = local.trust["glue"], instance_profile = false
        description = "Job de Glue: lee Silver, escribe Gold y publica Data Quality"
      }
      lakeformation-data-access = {
        enabled     = true, name = "${local.name}-lakeformation-data-access", trust = local.trust["lakeformation"], instance_profile = false
        description = "Rol con el que Lake Formation lee Silver/Gold para entregar credenciales temporales"
      }
      analyst = {
        enabled     = true, name = "${local.name}-analyst", trust = local.trust_humans, instance_profile = false
        description = "Analista de negocio: Athena sobre Gold (Lake Formation)"
      }
      risk-analyst = {
        enabled     = true, name = "${local.name}-risk-analyst", trust = local.trust_humans, instance_profile = false
        description = "Analista de riesgo: Athena sobre Silver y Gold (Lake Formation)"
      }
      vpc-flow-logs = {
        enabled     = true, name = "${local.name}-vpc-flow-logs", trust = local.trust["vpc-flow-logs"], instance_profile = false
        description = "VPC Flow Logs: escribe sólo en su log group"
      }
      cloudtrail-logs = {
        enabled     = var.enable_cloudtrail, name = "${local.name}-cloudtrail-logs", trust = local.trust["cloudtrail"], instance_profile = false
        description = "CloudTrail: entrega eventos a su log group"
      }
      core-loader = {
        enabled     = var.enable_dms, name = "${local.name}-core-loader", trust = local.trust["ec2"], instance_profile = true
        description = "EC2 de carga del core: script, snapshot, clave de la BD y Session Manager"
      }
      dms-s3-target = {
        enabled     = var.enable_dms, name = "${local.name}-dms-s3-target", trust = local.trust["dms"], instance_profile = false
        description = "DMS: escribe la réplica del core sólo en bronze/dms/"
      }
      # DMS exige estos dos roles con nombre fijo y su política administrada (no admite otra)
      dms-vpc-role = {
        enabled     = var.enable_dms && var.create_dms_service_roles, name = "dms-vpc-role", trust = local.trust["dms"], instance_profile = false
        description = "Rol de servicio exigido por DMS para gestionar interfaces de red en la VPC"
      }
      dms-cloudwatch-logs-role = {
        enabled     = var.enable_dms && var.create_dms_service_roles, name = "dms-cloudwatch-logs-role", trust = local.trust["dms"], instance_profile = false
        description = "Rol de servicio exigido por DMS para escribir sus logs"
      }
    },
    # Intercambio B2B: cada emisor asume SU rol; el ExternalId evita el "confused deputy"
    { for issuer in var.partner_issuers : "partner-${lower(issuer)}" => {
      enabled     = true, name = "${local.name}-partner-${lower(issuer)}", instance_profile = false
      description = "Emisor ${issuer}: lee sólo sus archivos de liquidación"
      trust = jsonencode({ Version = "2012-10-17", Statement = [{
        Effect    = "Allow"
        Principal = { AWS = coalesce(var.partner_principal_arn, "arn:aws:iam::${local.account_id}:root") }
        Action    = "sts:AssumeRole"
        Condition = { StringEquals = { "sts:ExternalId" = random_password.partner_external_id[issuer].result } }
      }] })
    } },
  )

  identities = { for k, v in local.all_identities : k => v if v.enabled }

  # ===============================================================================================
  #  QUÉ (las llaves de cada identidad)
  # ===============================================================================================
  key_kms     = { Sid = "UseLakeKey", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:Encrypt"], Resource = [aws_kms_key.lake.arn] }
  key_decrypt = { Sid = "DecryptLakeKey", Effect = "Allow", Action = ["kms:Decrypt"], Resource = [aws_kms_key.lake.arn] }
  key_xray    = { Sid = "Tracing", Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"], Resource = ["*"] }

  # Logs de cada Lambda: sólo su propio log group (lo crea Terraform, así que no necesita CreateLogGroup)
  lambda_common = { for k in keys(local.functions) : k => [
    { Sid = "OwnLogGroup", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = ["${local.log_group}:/aws/lambda/${local.name}-${k}:*"] },
    local.key_xray,
    local.key_kms,
  ] }

  # Cada etapa lee la capa anterior y escribe sólo la suya
  lambda_keys = {
    ingest = [
      { Sid = "WriteBronzeTransactions", Effect = "Allow", Action = ["s3:PutObject"], Resource = ["${local.arn["bronze"]}/transactions/*"] },
    ]
    bronze-to-silver = [
      { Sid = "ReadBronze", Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket"], Resource = [local.arn["bronze"], "${local.arn["bronze"]}/*"] },
      { Sid = "WriteSilver", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"], Resource = [local.arn["silver"], "${local.arn["silver"]}/*"] },
      { Sid = "CatalogSilver", Effect = "Allow", Action = local.glue_write_actions, Resource = [local.glue_catalog, local.glue_db_arn["silver"], local.glue_tables["silver"]] },
      { Sid = "PanTokenSecret", Effect = "Allow", Action = ["ssm:GetParameter"], Resource = [aws_ssm_parameter.pan_token_secret.arn] },
    ]
    silver-to-gold = [
      { Sid = "ReadSilver", Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket"], Resource = [local.arn["silver"], "${local.arn["silver"]}/*"] },
      { Sid = "WriteGold", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"], Resource = [local.arn["gold"], "${local.arn["gold"]}/*"] },
      { Sid = "WriteExchangeOutbound", Effect = "Allow", Action = ["s3:PutObject"], Resource = ["${local.arn["exchange"]}/outbound/*"] },
      { Sid = "CatalogGold", Effect = "Allow", Action = local.glue_write_actions, Resource = [local.glue_catalog, local.glue_db_arn["gold"], local.glue_tables["gold"]] },
    ]
    api = [
      { Sid = "ReadGold", Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket"], Resource = [local.arn["gold"], "${local.arn["gold"]}/*"] },
      { Sid = "ApiKey", Effect = "Allow", Action = ["ssm:GetParameter"], Resource = [aws_ssm_parameter.api_key.arn] },
    ]
  }

  # Consulta con Athena. Qué tablas ve cada analista lo decide Lake Formation (lakeformation.tf)
  analyst_keys = [
    { Sid = "Athena", Effect = "Allow", Action = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:StopQueryExecution", "athena:GetWorkGroup", "athena:ListNamedQueries", "athena:GetNamedQuery"], Resource = [aws_athena_workgroup.analytics.arn] },
    { Sid = "CatalogRead", Effect = "Allow", Action = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions"], Resource = [local.glue_catalog, local.glue_db_arn["silver"], local.glue_tables["silver"], local.glue_db_arn["gold"], local.glue_tables["gold"]] },
    # Sin s3:GetObject sobre Silver/Gold: Lake Formation entrega credenciales temporales por tabla concedida
    { Sid = "LakeFormationVendedCredentials", Effect = "Allow", Action = ["lakeformation:GetDataAccess"], Resource = ["*"] },
    { Sid = "AthenaResults", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation"], Resource = [local.arn["athena-results"], "${local.arn["athena-results"]}/*"] },
    local.key_kms,
  ]

  identity_policies = merge(
    { for k in keys(local.functions) : k => jsonencode({ Version = "2012-10-17", Statement = concat(local.lambda_common[k], local.lambda_keys[k]) }) },
    {
      pipeline-sfn = "" # ver orchestration_policies
      scheduler    = "" # ver orchestration_policies
      glue-gold-analytics = jsonencode({ Version = "2012-10-17", Statement = [
        { Sid = "ReadSilver", Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket"], Resource = [local.arn["silver"], "${local.arn["silver"]}/*"] },
        { Sid = "ReadScript", Effect = "Allow", Action = ["s3:GetObject"], Resource = ["${local.arn["artifacts"]}/glue/*"] },
        { Sid = "WriteGold", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"], Resource = [local.arn["gold"], "${local.arn["gold"]}/*"] },
        { Sid = "TempAndDqResults", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${local.arn["artifacts"]}/glue-temp/*", "${local.arn["artifacts"]}/dq-results/*"] },
        { Sid = "ListArtifacts", Effect = "Allow", Action = ["s3:ListBucket"], Resource = [local.arn["artifacts"]] },
        { Sid = "CatalogGold", Effect = "Allow", Action = concat(local.glue_write_actions, ["glue:DeleteTable", "glue:GetDatabases"]), Resource = [local.glue_catalog, local.glue_db_arn["gold"], local.glue_tables["gold"], "arn:aws:glue:${var.region}:${local.account_id}:database/default"] },
        { Sid = "GlueLogs", Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = ["${local.log_group}:/aws-glue/*"] },
        { Sid = "MetricsAndDataQuality", Effect = "Allow", Action = ["cloudwatch:PutMetricData", "glue:PublishDataQuality"], Resource = ["*"] },
        { Sid = "LakeFormationVendedCredentials", Effect = "Allow", Action = ["lakeformation:GetDataAccess"], Resource = ["*"] },
        local.key_kms,
      ] })
      lakeformation-data-access = jsonencode({ Version = "2012-10-17", Statement = [
        { Sid = "SilverGoldData", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"], Resource = [local.arn["silver"], "${local.arn["silver"]}/*", local.arn["gold"], "${local.arn["gold"]}/*"] },
        local.key_kms,
      ] })
      analyst      = jsonencode({ Version = "2012-10-17", Statement = local.analyst_keys })
      risk-analyst = jsonencode({ Version = "2012-10-17", Statement = local.analyst_keys })
      vpc-flow-logs = jsonencode({ Version = "2012-10-17", Statement = [
        { Sid = "WriteFlowLogs", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"], Resource = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"] },
      ] })
      cloudtrail-logs = jsonencode({ Version = "2012-10-17", Statement = [
        { Sid = "WriteTrailLogs", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = ["${try(aws_cloudwatch_log_group.trail[0].arn, "none")}:*"] },
      ] })
      core-loader = jsonencode({ Version = "2012-10-17", Statement = [
        { Sid = "ReadLoaderAndSnapshot", Effect = "Allow", Action = ["s3:GetObject"], Resource = ["${local.arn["artifacts"]}/${local.core_loader_key}", "${local.arn["bronze"]}/${local.core_snapshot_s3}"] },
        { Sid = "DbPassword", Effect = "Allow", Action = ["ssm:GetParameter"], Resource = [try(aws_ssm_parameter.core_db_password[0].arn, "arn:aws:ssm:${var.region}:${local.account_id}:parameter/none")] },
        # Las 5 acciones mínimas de Session Manager, en vez de AmazonSSMManagedInstanceCore
        { Sid = "SessionManager", Effect = "Allow", Action = ["ssm:UpdateInstanceInformation", "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"], Resource = ["*"] },
        local.key_decrypt,
      ] })
      dms-s3-target = jsonencode({ Version = "2012-10-17", Statement = [
        { Sid = "WriteBronzeDms", Effect = "Allow", Action = ["s3:PutObject", "s3:DeleteObject", "s3:PutObjectTagging"], Resource = ["${local.arn["bronze"]}/dms/*"] },
        { Sid = "ListBronze", Effect = "Allow", Action = ["s3:ListBucket"], Resource = [local.arn["bronze"]] },
        local.key_kms,
      ] })
      dms-vpc-role             = ""
      dms-cloudwatch-logs-role = ""
    },
    { for issuer in var.partner_issuers : "partner-${lower(issuer)}" => jsonencode({ Version = "2012-10-17", Statement = [
      { Sid = "ListOwnPrefix", Effect = "Allow", Action = ["s3:ListBucket"], Resource = [local.arn["exchange"]], Condition = { StringLike = { "s3:prefix" = ["outbound/issuer_id=${issuer}/*"] } } },
      { Sid = "ReadOwnFiles", Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = ["${local.arn["exchange"]}/outbound/issuer_id=${issuer}/*"] },
      { Sid = "DecryptViaS3Only", Effect = "Allow", Action = ["kms:Decrypt"], Resource = [aws_kms_key.lake.arn], Condition = { StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com" } } },
    ] }) },
  )

  # Políticas de orquestación: nombran las Lambdas y la máquina de estados, que a su vez usan roles del
  # módulo. Se adjuntan aparte (abajo) para no crear un ciclo de dependencias.
  orchestration_policies = {
    pipeline-sfn = jsonencode({ Version = "2012-10-17", Statement = [
      { Sid = "InvokeStages", Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = [for k in ["ingest", "bronze-to-silver", "silver-to-gold"] : aws_lambda_function.fn[k].arn] },
      # La entrega de logs de Step Functions sólo admite estas acciones a nivel de cuenta
      { Sid = "LogDelivery", Effect = "Allow", Action = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"], Resource = ["*"] },
    ] })
    scheduler = jsonencode({ Version = "2012-10-17", Statement = [
      { Sid = "StartPipeline", Effect = "Allow", Action = ["states:StartExecution"], Resource = [aws_sfn_state_machine.pipeline.arn] },
    ] })
  }

  # Únicas políticas administradas por AWS del proyecto, y por qué: DMS no acepta otra
  managed_attachments = {
    for k, v in {
      dms-vpc-role             = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
      dms-cloudwatch-logs-role = "arn:aws:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
    } : k => v if contains(keys(local.identities), k)
  }
}

module "role" {
  source   = "./modules/workload_role"
  for_each = local.identities

  name                 = each.value.name
  description          = each.value.description
  assume_role_policy   = each.value.trust
  instance_profile     = each.value.instance_profile
  policy               = local.identity_policies[each.key]
  permissions_boundary = local.boundary_arn
}

resource "aws_iam_role_policy" "orchestration" {
  for_each = local.orchestration_policies
  name     = "least-privilege"
  role     = module.role[each.key].name
  policy   = each.value
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = local.managed_attachments
  role       = module.role[each.key].name
  policy_arn = each.value
}

resource "random_password" "partner_external_id" {
  for_each = toset(var.partner_issuers)
  length   = 24
  special  = false
}
