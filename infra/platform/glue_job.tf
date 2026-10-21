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
    "--enable-glue-datacatalog"          = "true"
    "--enable-metrics"                   = "true"
    "--enable-observability-metrics"     = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--continuous-log-logGroup"          = aws_cloudwatch_log_group.glue.name
    "--TempDir"                          = "s3://${aws_s3_bucket.layer["artifacts"].bucket}/glue-temp/"
    "--SILVER_PATH"                      = "s3://${aws_s3_bucket.layer["silver"].bucket}/transactions/"
    "--GOLD_PATH"                        = "s3://${aws_s3_bucket.layer["gold"].bucket}"
    "--GOLD_DB"                          = aws_glue_catalog_database.layer["gold"].name
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
