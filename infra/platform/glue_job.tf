# Job de AWS Glue (PySpark 5.0): Glue Data Quality sobre Silver + analítica Gold con Spark SQL. Diario.

resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.layer["artifacts"].id
  key    = "glue/gold_card_analytics.py"
  source = "${path.module}/../../glue/jobs/gold_card_analytics.py"
  etag   = filemd5("${path.module}/../../glue/jobs/gold_card_analytics.py")
}

resource "aws_cloudwatch_log_group" "glue" {
  name              = "/aws-glue/jobs/${local.name}"
  retention_in_days = 14
}

resource "aws_glue_job" "gold_card_analytics" {
  name              = "${local.name}-gold-card-analytics"
  role_arn          = module.role["glue-gold-analytics"].arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 20
  max_retries       = 0

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.layer["artifacts"].bucket}/${aws_s3_object.glue_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-observability-metrics"     = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--continuous-log-logGroup"          = aws_cloudwatch_log_group.glue.name
    "--TempDir"                          = "s3://${aws_s3_bucket.layer["artifacts"].bucket}/glue-temp/"
    "--SILVER_PATH"                      = "s3://${aws_s3_bucket.layer["silver"].bucket}/transactions/"
    "--GOLD_PATH"                        = "s3://${aws_s3_bucket.layer["gold"].bucket}"
    "--DQ_RESULTS_PATH"                  = "s3://${aws_s3_bucket.layer["artifacts"].bucket}/dq-results/silver_transactions/"
  }

  execution_property {
    max_concurrent_runs = 1
  }
}

resource "aws_glue_trigger" "daily" {
  name     = "${local.name}-gold-card-analytics-daily"
  type     = "SCHEDULED"
  schedule = var.glue_schedule
  enabled  = var.schedule_enabled

  actions {
    job_name = aws_glue_job.gold_card_analytics.name
  }
}

# --- Tablas de salida del job: el esquema vive aquí, el job sólo escribe Parquet --------------------
# Partition projection: Athena calcula las particiones (month / txn_date) sin crawlers ni MSCK REPAIR.

locals {
  glue_gold_tables = {
    card_monthly_segments = {
      partition = { name = "month", format = "yyyy-MM", range = "2026-01,NOW", unit = "MONTHS" }
      columns = {
        pan_token                = "string", issuer_id = "string", txn_count = "bigint", approved_count = "bigint",
        spend_usd                = "double", distinct_merchants = "bigint", active_days = "bigint",
        cross_border_share       = "double", ecommerce_share = "double", spend_quartile = "int",
        spend_pct_rank_in_issuer = "double", segment = "string"
      }
    }
    merchant_daily_trends = {
      partition = { name = "txn_date", format = "yyyy-MM-dd", range = "2026-01-01,NOW", unit = "DAYS" }
      columns = {
        merchant_id       = "string", merchant_name = "string", mcc_category = "string", txn_count = "bigint",
        gross_usd         = "double", gross_usd_7d_avg = "double", rank_in_category = "int",
        share_of_category = "double", delta_vs_prev_day = "double"
      }
    }
  }
}

resource "aws_glue_catalog_table" "glue_gold" {
  for_each      = local.glue_gold_tables
  name          = each.key
  database_name = aws_glue_catalog_database.layer["gold"].name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification                                          = "parquet"
    "projection.enabled"                                    = "true"
    "projection.${each.value.partition.name}.type"          = "date"
    "projection.${each.value.partition.name}.format"        = each.value.partition.format
    "projection.${each.value.partition.name}.range"         = each.value.partition.range
    "projection.${each.value.partition.name}.interval"      = "1"
    "projection.${each.value.partition.name}.interval.unit" = each.value.partition.unit
    "storage.location.template"                             = "s3://${aws_s3_bucket.layer["gold"].bucket}/${each.key}/${each.value.partition.name}=$${${each.value.partition.name}}/"
  }

  partition_keys {
    name = each.value.partition.name
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.layer["gold"].bucket}/${each.key}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = each.value.columns
      content {
        name = columns.key
        type = columns.value
      }
    }
  }
}
