# AWS DMS: replica el core bancario (PostgreSQL) a Bronze en Parquet, carga inicial + CDC continuo.
# Cada archivo trae la columna Op (I/U/D) y dms_ts; Silver aplica los cambios (silver.dms_to_snapshot).

# Roles con nombre fijo que DMS exige en la cuenta
# Rol con el que DMS escribe en Bronze: sólo el prefijo dms/
resource "aws_dms_replication_subnet_group" "main" {
  count                                = local.dms_count
  replication_subnet_group_id          = "${local.name}-dms"
  replication_subnet_group_description = "Subredes privadas para DMS"
  subnet_ids                           = aws_subnet.private[*].id
  depends_on                           = [aws_iam_role_policy_attachment.managed]
}

resource "aws_dms_replication_instance" "main" {
  count                       = local.dms_count
  replication_instance_id     = "${local.name}-dms"
  replication_instance_class  = "dms.t3.micro"
  allocated_storage           = 20
  multi_az                    = false
  publicly_accessible         = false
  kms_key_arn                 = aws_kms_key.lake.arn
  replication_subnet_group_id = aws_dms_replication_subnet_group.main[0].id
  vpc_security_group_ids      = [aws_security_group.dms.id]
  apply_immediately           = true
}

resource "aws_dms_endpoint" "core_source" {
  count         = local.dms_count
  endpoint_id   = "${local.name}-core-postgres"
  endpoint_type = "source"
  engine_name   = "postgres"
  server_name   = aws_db_instance.core[0].address
  port          = 5432
  database_name = local.core_db_name
  username      = local.core_db_user
  password      = random_password.core_db[0].result
  ssl_mode      = "require"
  kms_key_arn   = aws_kms_key.lake.arn

  postgres_settings {
    heartbeat_enable = true # evita que el WAL crezca si no hay cambios
  }
}

resource "aws_dms_s3_endpoint" "bronze_target" {
  count                             = local.dms_count
  endpoint_id                       = "${local.name}-bronze-s3"
  endpoint_type                     = "target"
  bucket_name                       = aws_s3_bucket.layer["bronze"].bucket
  bucket_folder                     = "dms"
  service_access_role_arn           = module.role["dms-s3-target"].arn
  data_format                       = "parquet"
  parquet_version                   = "parquet-2-0"
  parquet_timestamp_in_millisecond  = true
  timestamp_column_name             = "dms_ts"
  include_op_for_full_load          = true
  add_column_name                   = true
  cdc_max_batch_interval            = 120
  encryption_mode                   = "SSE_KMS"
  server_side_encryption_kms_key_id = aws_kms_key.lake.arn

  depends_on = [module.role]
}

# Espera a que la EC2 cree el esquema y cargue los datos antes de iniciar la replicación
resource "time_sleep" "wait_core_load" {
  count           = local.dms_count
  create_duration = "4m"
  depends_on      = [aws_instance.loader]
}

resource "aws_dms_replication_task" "core_to_bronze" {
  count                    = local.dms_count
  replication_task_id      = "${local.name}-core-to-bronze"
  migration_type           = "full-load-and-cdc"
  replication_instance_arn = aws_dms_replication_instance.main[0].replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.core_source[0].endpoint_arn
  target_endpoint_arn      = aws_dms_s3_endpoint.bronze_target[0].endpoint_arn
  start_replication_task   = true

  table_mappings = jsonencode({
    rules = [{
      "rule-type"      = "selection"
      "rule-id"        = "1"
      "rule-name"      = "core-schema"
      "object-locator" = { "schema-name" = "core", "table-name" = "%" }
      "rule-action"    = "include"
    }]
  })

  replication_task_settings = jsonencode({
    Logging          = { EnableLogging = true }
    FullLoadSettings = { TargetTablePrepMode = "DO_NOTHING" }
  })

  lifecycle {
    ignore_changes = [replication_task_settings] # DMS completa la configuración con valores por defecto
  }

  depends_on = [time_sleep.wait_core_load, aws_iam_role_policy_attachment.managed]
}
