# Un rol por función con mínimo privilegio: cada etapa sólo lee la capa anterior y escribe la suya.

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

locals {
  arn = { for k, b in aws_s3_bucket.layer : k => b.arn }

  glue_db_arn  = { for k, d in aws_glue_catalog_database.layer : k => d.arn }
  glue_tables  = { for k, d in aws_glue_catalog_database.layer : k => "arn:aws:glue:${var.region}:${local.account_id}:table/${d.name}/*" }
  glue_catalog = "arn:aws:glue:${var.region}:${local.account_id}:catalog"

  glue_write_actions = [
    "glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:CreateTable", "glue:UpdateTable",
    "glue:GetPartition", "glue:GetPartitions", "glue:CreatePartition", "glue:BatchCreatePartition",
    "glue:UpdatePartition", "glue:DeletePartition", "glue:BatchDeletePartition",
  ]
}

data "aws_iam_policy_document" "fn" {
  for_each = local.functions

  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:Encrypt"]
    resources = [aws_kms_key.lake.arn]
  }

  statement {
    sid       = "XRay"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = each.key == "ingest" ? [1] : []
    content {
      sid       = "WriteBronze"
      actions   = ["s3:PutObject"]
      resources = ["${local.arn["bronze"]}/transactions/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "bronze-to-silver" ? [1] : []
    content {
      sid       = "ReadBronze"
      actions   = ["s3:GetObject", "s3:ListBucket"]
      resources = [local.arn["bronze"], "${local.arn["bronze"]}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "bronze-to-silver" ? [1] : []
    content {
      sid       = "WriteSilver"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      resources = [local.arn["silver"], "${local.arn["silver"]}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "bronze-to-silver" ? [1] : []
    content {
      sid       = "CatalogSilver"
      actions   = local.glue_write_actions
      resources = [local.glue_catalog, local.glue_db_arn["silver"], local.glue_tables["silver"]]
    }
  }

  dynamic "statement" {
    for_each = each.key == "bronze-to-silver" ? [1] : []
    content {
      sid       = "PanSecret"
      actions   = ["ssm:GetParameter"]
      resources = [aws_ssm_parameter.pan_token_secret.arn]
    }
  }

  dynamic "statement" {
    for_each = each.key == "silver-to-gold" ? [1] : []
    content {
      sid       = "ReadSilver"
      actions   = ["s3:GetObject", "s3:ListBucket"]
      resources = [local.arn["silver"], "${local.arn["silver"]}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "silver-to-gold" ? [1] : []
    content {
      sid       = "WriteGoldAndExchange"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      resources = [local.arn["gold"], "${local.arn["gold"]}/*", local.arn["exchange"], "${local.arn["exchange"]}/outbound/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "silver-to-gold" ? [1] : []
    content {
      sid       = "CatalogGold"
      actions   = local.glue_write_actions
      resources = [local.glue_catalog, local.glue_db_arn["gold"], local.glue_tables["gold"]]
    }
  }

  dynamic "statement" {
    for_each = each.key == "api" ? [1] : []
    content {
      sid       = "ReadGold"
      actions   = ["s3:GetObject", "s3:ListBucket"]
      resources = [local.arn["gold"], "${local.arn["gold"]}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "api" ? [1] : []
    content {
      sid       = "ApiKey"
      actions   = ["ssm:GetParameter"]
      resources = [aws_ssm_parameter.api_key.arn]
    }
  }
}

resource "aws_iam_role" "fn" {
  for_each           = local.functions
  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy" "fn" {
  for_each = local.functions
  name     = "least-privilege"
  role     = aws_iam_role.fn[each.key].id
  policy   = data.aws_iam_policy_document.fn[each.key].json
}

resource "aws_iam_role_policy_attachment" "fn_logs" {
  for_each   = local.functions
  role       = aws_iam_role.fn[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- Rol de analista: consulta Silver/Gold con Athena, sin acceso a Bronze (donde vive el PAN) ------

data "aws_iam_policy_document" "account_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
}

data "aws_iam_policy_document" "analyst" {
  statement {
    actions   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:StopQueryExecution", "athena:GetWorkGroup", "athena:ListNamedQueries", "athena:GetNamedQuery"]
    resources = [aws_athena_workgroup.analytics.arn]
  }
  statement {
    actions = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions"]
    resources = [
      local.glue_catalog,
      local.glue_db_arn["silver"], local.glue_tables["silver"],
      local.glue_db_arn["gold"], local.glue_tables["gold"],
    ]
  }
  statement {
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [local.arn["silver"], "${local.arn["silver"]}/*", local.arn["gold"], "${local.arn["gold"]}/*"]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.arn["athena-results"], "${local.arn["athena-results"]}/*"]
  }
  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.lake.arn]
  }
}

resource "aws_iam_role" "analyst" {
  name               = "${local.name}-analyst"
  assume_role_policy = data.aws_iam_policy_document.account_trust.json
}

resource "aws_iam_role_policy" "analyst" {
  name   = "athena-silver-gold"
  role   = aws_iam_role.analyst.id
  policy = data.aws_iam_policy_document.analyst.json
}
