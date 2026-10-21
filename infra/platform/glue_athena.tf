# Catálogo: una base por capa. Las tablas Silver/Gold las registra el pipeline (awswrangler) al escribir;
# la tabla Bronze se define aquí sobre los JSON crudos usando partition projection (sin crawlers).
resource "aws_glue_catalog_database" "layer" {
  for_each = toset(["bronze", "silver", "gold"])
  name     = "${local.db_prefix}_${each.key}"
}

resource "aws_glue_catalog_table" "bronze_transactions" {
  name          = "transactions"
  database_name = aws_glue_catalog_database.layer["bronze"].name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification                  = "json"
    "projection.enabled"            = "true"
    "projection.ingest_date.type"   = "date"
    "projection.ingest_date.format" = "yyyy-MM-dd"
    "projection.ingest_date.range"  = "2026-01-01,NOW"
    "storage.location.template"     = "s3://${aws_s3_bucket.layer["bronze"].bucket}/transactions/ingest_date=$${ingest_date}/"
  }

  partition_keys {
    name = "ingest_date"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.layer["bronze"].bucket}/transactions/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters            = { "ignore.malformed.json" = "true" }
    }

    # En Bronze todo es string: se conserva el dato tal como llegó; el tipado ocurre en Silver
    dynamic "columns" {
      for_each = [
        "transaction_id", "event_ts", "acquirer_id", "pan", "card_product", "card_country", "merchant_id",
        "mcc", "merchant_country", "amount", "currency", "entry_mode", "response_code", "schema_version",
        "_batch_id", "_ingest_ts", "_source",
      ]
      content {
        name = columns.value
        type = "string"
      }
    }
  }
}

resource "aws_athena_workgroup" "analytics" {
  name          = "${local.name}-analytics"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 1073741824 # 1 GB: tope de costo por consulta

    result_configuration {
      output_location = "s3://${aws_s3_bucket.layer["athena-results"].bucket}/results/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.lake.arn
      }
    }
  }
}

resource "aws_athena_named_query" "query" {
  for_each  = fileset("${path.module}/../../sql", "*.sql")
  name      = trimsuffix(each.value, ".sql")
  workgroup = aws_athena_workgroup.analytics.id
  database  = aws_glue_catalog_database.layer["gold"].name
  query = templatefile("${path.module}/../../sql/${each.value}", {
    bronze_db = aws_glue_catalog_database.layer["bronze"].name
    silver_db = aws_glue_catalog_database.layer["silver"].name
    gold_db   = aws_glue_catalog_database.layer["gold"].name
  })
}
