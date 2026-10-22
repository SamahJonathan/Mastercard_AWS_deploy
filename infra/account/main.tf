# =================================================================================================
#  Etapa 0: la identidad de administrador con la que se opera el proyecto desde tu PC.
#  Se aplica UNA vez desde AWS CloudShell (ya autenticado en la consola): ./infra/command/cloudshell_admin.sh
#  Apuntes: docs/iam.md, sección "Etapa 0".
#
#  Igual que un binding de GCP: el permiso se ata a un GRUPO y las personas son miembros del grupo.
#  Agregar o quitar a alguien no toca permisos; sólo cambia la membresía.
#
#  La access key NO se crea aquí: si la creara Terraform, el secreto quedaría en texto plano en el
#  terraform.tfstate. La crea el script con el CLI y se muestra una sola vez.
# =================================================================================================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
  # Estado en el mismo bucket que la plataforma (lo crea el bootstrap), así se administra desde la PC
  # (infra/command/account.ps1) o desde CloudShell con el mismo estado. Configuración parcial: el bucket
  # se pasa con -backend-config=../platform/backend.hcl.
  # En una cuenta NUEVA el bucket aún no existe: cloudshell_admin.sh usa estado local con un archivo
  # backend_override.tf y, después del bootstrap, se migra con `terraform init -migrate-state`.
  backend "s3" {
    key          = "account/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "paylake", ManagedBy = "terraform", Stack = "account" }
  }
}

variable "region" {
  type    = string
  default = "sa-east-1"
}

variable "admin_users" {
  description = "Personas que operan el proyecto (miembros del grupo de administradores)"
  type        = list(string)
  default     = ["admin-joony"]
}

# --- El grupo: aquí vive el permiso --------------------------------------------------------------

resource "aws_iam_group" "admins" {
  name = "paylake-admins"
  path = "/paylake/"
}

# Aditivo: ata UNA política a ESTE grupo. (aws_iam_policy_attachment sería exclusivo: el set-iam-policy)
resource "aws_iam_group_policy_attachment" "admins" {
  group      = aws_iam_group.admins.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- Las personas: sólo membresía, sin permisos propios -------------------------------------------

resource "aws_iam_user" "admin" {
  for_each      = toset(var.admin_users)
  name          = each.value
  path          = "/paylake/"
  force_destroy = true # permite borrar el usuario aunque tenga access keys creadas por el CLI
}

# Aditivo: agrega ESTE usuario a sus grupos, respetando otras membresías.
# (aws_iam_group_membership sería exclusivo: dejaría en el grupo sólo a los que declara)
resource "aws_iam_user_group_membership" "admin" {
  for_each = toset(var.admin_users) # claves estáticas: conocidas antes de crear nada (import y primer plan)
  user     = aws_iam_user.admin[each.key].name
  groups   = [aws_iam_group.admins.name]
}

output "admin_user_arns" {
  description = "Úsalos como lakeformation_admin_arns (bootstrap.ps1 lo hace solo)"
  value       = { for k, u in aws_iam_user.admin : k => u.arn }
}

# =================================================================================================
#  Consultores: sólo consultan tablas de Gold. Una identidad por propósito: el administrador
#  despliega, el consultor consulta.
#
#  Agregar un nombre a consultant_users y ejecutar infra/command/account.ps1 deja a la persona lista
#  para consultar DIRECTO (sin cambiar de rol):
#    - IAM (llavero paylake-consultores): Athena en el workgroup del proyecto, catálogo sólo de Gold,
#      resultados en su bucket, la llave KMS del lake y cuidar su propia cuenta (contraseña y MFA).
#    - Lake Formation (por persona, porque LF no acepta grupos de IAM): SELECT sobre las tablas con
#      layer = gold. Silver y Bronze no existen para el consultor.
#  Requiere la plataforma desplegada (workgroup, llave KMS y LF-Tags los crea infra/platform).
# =================================================================================================

# Para dar acceso a otra persona, se agrega aquí (se le entrega el llavero); para quitarlo, se borra.
# Es el ÚNICO lugar donde está esta lista: los scripts no la reemplazan.
variable "consultant_users" {
  description = "Personas que sólo consultan tablas de Gold (Athena / Power BI)"
  type        = list(string)
  default     = ["consultor-joony", "consultor-juan", "consultor-maria"]
}

variable "platform_name" {
  description = "Prefijo de los recursos de infra/platform (project-environment)"
  type        = string
  default     = "paylake-dev"
}

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  gold_db      = "${replace(var.platform_name, "-", "_")}_gold"
  workgroup    = "arn:aws:athena:${var.region}:${local.account_id}:workgroup/${var.platform_name}-analytics"
  results      = "arn:aws:s3:::${var.platform_name}-athena-results-${local.account_id}"
  glue_catalog = "arn:aws:glue:${var.region}:${local.account_id}:catalog"
}

resource "aws_iam_group" "consultants" {
  name = "paylake-consultores"
  path = "/paylake/"
}

resource "aws_iam_group_policy" "consultants" {
  name  = "solo-consultar-gold"
  group = aws_iam_group.consultants.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsultarEnElWorkgroupDelProyecto"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:StopQueryExecution", "athena:GetQueryExecution",
          "athena:GetQueryResults", "athena:GetQueryResultsStream", "athena:GetQueryRuntimeStatistics",
          "athena:ListQueryExecutions", "athena:BatchGetQueryExecution", "athena:GetWorkGroup",
          "athena:ListNamedQueries", "athena:GetNamedQuery", "athena:BatchGetNamedQuery",
        ]
        Resource = local.workgroup
      },
      {
        # Las List* de nivel cuenta sólo admiten "*" (catálogos y workgroups disponibles)
        Sid      = "VerCatalogosYWorkgroups"
        Effect   = "Allow"
        Action   = ["athena:ListWorkGroups", "athena:ListDataCatalogs", "athena:ListEngineVersions"]
        Resource = "*"
      },
      {
        Sid      = "MetadatosDeAthena"
        Effect   = "Allow"
        Action   = ["athena:GetDataCatalog", "athena:ListDatabases", "athena:GetDatabase", "athena:ListTableMetadata", "athena:GetTableMetadata"]
        Resource = "arn:aws:athena:${var.region}:${local.account_id}:datacatalog/AwsDataCatalog"
      },
      {
        # Catálogo sólo de Gold: Silver y Bronze ni siquiera aparecen
        Sid      = "CatalogoSoloGold"
        Effect   = "Allow"
        Action   = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions"]
        Resource = [local.glue_catalog, "arn:aws:glue:${var.region}:${local.account_id}:database/${local.gold_db}", "arn:aws:glue:${var.region}:${local.account_id}:table/${local.gold_db}/*"]
      },
      {
        # Sin s3:GetObject sobre Gold: Lake Formation entrega credenciales temporales por tabla concedida
        Sid      = "DatosViaLakeFormation"
        Effect   = "Allow"
        Action   = "lakeformation:GetDataAccess"
        Resource = "*"
      },
      {
        Sid      = "ResultadosDeSusConsultas"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation", "s3:AbortMultipartUpload"]
        Resource = [local.results, "${local.results}/*"]
      },
      {
        # La llave del lake se identifica por su alias (el ARN lo genera la plataforma)
        Sid       = "LlaveDelLake"
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
        Condition = { "ForAnyValue:StringEquals" = { "kms:ResourceAliases" = "alias/${var.platform_name}-lake" } }
      },
      {
        # Sólo sobre su propio usuario (${aws:username}): cambiar su contraseña y gestionar su MFA
        Sid    = "CuidarSuPropiaCuenta"
        Effect = "Allow"
        Action = [
          "iam:GetUser", "iam:ChangePassword", "iam:GetLoginProfile",
          "iam:ListMFADevices", "iam:EnableMFADevice", "iam:ResyncMFADevice", "iam:DeactivateMFADevice",
        ]
        Resource = "arn:aws:iam::${local.account_id}:user/paylake/$${aws:username}"
      },
      {
        Sid      = "CrearSuPropioMfaVirtual"
        Effect   = "Allow"
        Action   = ["iam:CreateVirtualMFADevice", "iam:DeleteVirtualMFADevice"]
        Resource = "arn:aws:iam::${local.account_id}:mfa/$${aws:username}"
      },
      {
        Sid      = "LeerPoliticaDeContrasenas"
        Effect   = "Allow"
        Action   = ["iam:GetAccountPasswordPolicy", "iam:ListVirtualMFADevices"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_user" "consultant" {
  for_each      = toset(var.consultant_users)
  name          = each.value
  path          = "/paylake/"
  force_destroy = true # la contraseña de consola la crea el CLI (account.ps1), fuera del tfstate
}

resource "aws_iam_user_group_membership" "consultant" {
  for_each = toset(var.consultant_users)
  user     = aws_iam_user.consultant[each.key].name
  groups   = [aws_iam_group.consultants.name]
}

# --- Lake Formation: qué tablas ve cada consultor (por etiqueta: hereda las tablas futuras de Gold) ---

resource "aws_lakeformation_permissions" "consultant_databases" {
  for_each    = toset(var.consultant_users)
  principal   = aws_iam_user.consultant[each.key].arn
  permissions = ["DESCRIBE"]

  lf_tag_policy {
    resource_type = "DATABASE"
    expression {
      key    = "layer"
      values = ["gold"]
    }
  }
}

resource "aws_lakeformation_permissions" "consultant_tables" {
  for_each    = toset(var.consultant_users)
  principal   = aws_iam_user.consultant[each.key].arn
  permissions = ["SELECT", "DESCRIBE"]

  lf_tag_policy {
    resource_type = "TABLE"
    expression {
      key    = "layer"
      values = ["gold"]
    }
  }
}

output "consultant_user_arns" {
  value = { for k, u in aws_iam_user.consultant : k => u.arn }
}
