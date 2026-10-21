# AWS Lake Formation gobierna Silver y Gold:
#  - Las bases nuevas no reciben IAM_ALLOWED_PRINCIPALS: el acceso por catálogo lo deciden los permisos de LF.
#  - LF-Tags (layer, sensitivity) en las bases; las tablas que crea el pipeline los heredan.
#  - Analista: sólo Gold.  Analista de riesgo: Silver + Gold.  Pipeline: permisos mínimos por base.

locals {
  deploy_role_arn = "arn:aws:iam::${local.account_id}:role/${var.project}-github-deploy"
  lf_admins       = distinct(concat([local.deploy_role_arn], var.lakeformation_admin_arns))
}

resource "aws_lakeformation_data_lake_settings" "this" {
  admins = local.lf_admins
  # Sin bloques create_*_default_permissions => nada se concede por defecto a IAM_ALLOWED_PRINCIPALS
}

# --- Registro de ubicaciones S3 con un rol propio (necesita KMS, el rol vinculado al servicio no puede) ---

resource "aws_lakeformation_resource" "layer" {
  for_each = toset(["silver", "gold"])
  arn      = local.arn[each.key]
  role_arn = module.role["lakeformation-data-access"].arn

  depends_on = [module.role]
}

# --- LF-Tags ----------------------------------------------------------------------------------

resource "aws_lakeformation_lf_tag" "layer" {
  key        = "layer"
  values     = ["bronze", "silver", "gold"]
  depends_on = [aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_lf_tag" "sensitivity" {
  key        = "sensitivity"
  values     = ["public", "confidential"]
  depends_on = [aws_lakeformation_data_lake_settings.this]
}

locals {
  db_tags = {
    silver = { layer = "silver", sensitivity = "confidential" } # tokens de tarjeta, detalle transaccional
    gold   = { layer = "gold", sensitivity = "public" }         # agregados para negocio
  }
}

resource "aws_lakeformation_resource_lf_tags" "db" {
  for_each = local.db_tags

  database {
    name = aws_glue_catalog_database.layer[each.key].name
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.layer.key
    value = each.value.layer
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.sensitivity.key
    value = each.value.sensitivity
  }
}

# --- Consumidores: permisos por expresión de tags (aplican a tablas futuras) ---------------------

locals {
  # principal => capas que puede leer
  readers = merge(
    {
      analyst      = { arn = module.role["analyst"].arn, layers = ["gold"] }
      risk_analyst = { arn = module.role["risk-analyst"].arn, layers = ["silver", "gold"] }
    },
    { for i, arn in var.lakeformation_admin_arns : "admin_${i}" => { arn = arn, layers = ["silver", "gold"] } },
    var.enable_quicksight && var.quicksight_user_arn != "" ? { quicksight = { arn = var.quicksight_user_arn, layers = ["gold"] } } : {},
  )
}

resource "aws_lakeformation_permissions" "reader_databases" {
  for_each    = local.readers
  principal   = each.value.arn
  permissions = ["DESCRIBE"]

  lf_tag_policy {
    resource_type = "DATABASE"
    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = each.value.layers
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.db]
}

resource "aws_lakeformation_permissions" "reader_tables" {
  for_each    = local.readers
  principal   = each.value.arn
  permissions = ["SELECT", "DESCRIBE"]

  lf_tag_policy {
    resource_type = "TABLE"
    expression {
      key    = aws_lakeformation_lf_tag.layer.key
      values = each.value.layers
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.db]
}

# --- Productores: cada etapa sólo administra las tablas de su capa ------------------------------

locals {
  writers = {
    bronze_to_silver = { arn = module.role["bronze-to-silver"].arn, layer = "silver" }
    silver_to_gold   = { arn = module.role["silver-to-gold"].arn, layer = "gold" }
  }
}

resource "aws_lakeformation_permissions" "writer_database" {
  for_each    = local.writers
  principal   = each.value.arn
  permissions = ["CREATE_TABLE", "ALTER", "DESCRIBE"]

  database {
    name = aws_glue_catalog_database.layer[each.value.layer].name
  }

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_permissions" "writer_tables" {
  for_each    = local.writers
  principal   = each.value.arn
  permissions = ["ALL"]

  table {
    database_name = aws_glue_catalog_database.layer[each.value.layer].name
    wildcard      = true
  }

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_permissions" "writer_location" {
  for_each    = local.writers
  principal   = each.value.arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = aws_lakeformation_resource.layer[each.value.layer].arn
  }
}
