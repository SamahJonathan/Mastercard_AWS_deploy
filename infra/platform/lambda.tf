# Layer administrado por AWS con pandas + pyarrow + awswrangler (se resuelve vía parámetro público de SSM)
data "aws_ssm_parameter" "aws_sdk_pandas_layer" {
  name = "/aws/service/aws-sdk-pandas/${var.aws_sdk_pandas_version}/py3.12/x86_64/layer-arn"
}

data "archive_file" "src" {
  type        = "zip"
  source_dir  = "${path.module}/../../src"
  output_path = "${path.module}/.build/payments_lake.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
}

locals {
  bucket_uri = { for k, b in aws_s3_bucket.layer : k => "s3://${b.bucket}" }

  common_env = {
    BRONZE_ROOT    = local.bucket_uri["bronze"]
    SILVER_ROOT    = local.bucket_uri["silver"]
    GOLD_ROOT      = local.bucket_uri["gold"]
    EXCHANGE_ROOT  = local.bucket_uri["exchange"]
    GLUE_DB_SILVER = aws_glue_catalog_database.layer["silver"].name
    GLUE_DB_GOLD   = aws_glue_catalog_database.layer["gold"].name
    LOOKBACK_DAYS  = tostring(var.lookback_days)
  }

  functions = {
    ingest = {
      handler = "payments_lake.handlers.ingest_handler"
      memory  = 512
      timeout = 60
      env     = { BATCH_SIZE = tostring(var.batch_size) }
    }
    bronze-to-silver = {
      handler = "payments_lake.handlers.bronze_to_silver_handler"
      memory  = 2048
      timeout = 300
      env     = { PAN_TOKEN_SECRET_PARAM = aws_ssm_parameter.pan_token_secret.name }
    }
    silver-to-gold = {
      handler = "payments_lake.handlers.silver_to_gold_handler"
      memory  = 2048
      timeout = 300
      env     = {}
    }
    api = {
      handler = "payments_lake.handlers.api_handler"
      memory  = 1024
      timeout = 29
      env     = { API_KEY_PARAM = aws_ssm_parameter.api_key.name }
    }
  }
}

resource "aws_cloudwatch_log_group" "fn" {
  for_each          = local.functions
  name              = "/aws/lambda/${local.name}-${each.key}"
  retention_in_days = 14
}

resource "aws_lambda_function" "fn" {
  for_each         = local.functions
  function_name    = "${local.name}-${each.key}"
  role             = aws_iam_role.fn[each.key].arn
  runtime          = "python3.12"
  architectures    = ["x86_64"]
  handler          = each.value.handler
  memory_size      = each.value.memory
  timeout          = each.value.timeout
  filename         = data.archive_file.src.output_path
  source_code_hash = data.archive_file.src.output_base64sha256
  layers           = [data.aws_ssm_parameter.aws_sdk_pandas_layer.value]

  environment {
    variables = merge(local.common_env, each.value.env)
  }

  tracing_config { mode = "Active" }
  depends_on = [aws_cloudwatch_log_group.fn]
}
