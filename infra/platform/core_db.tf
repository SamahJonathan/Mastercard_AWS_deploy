# "Core bancario" de origen: PostgreSQL en RDS (subred privada) cargado con sample_data por una EC2.
# La EC2 además simula actividad cada 15 minutos (INSERT/UPDATE) para que DMS la capture como CDC.

locals {
  dms_count        = var.enable_dms ? 1 : 0
  core_db_name     = "corebank"
  core_db_user     = "core_admin"
  core_loader_key  = "core_db/load_core_db.py"
  core_snapshot_s3 = aws_s3_object.core_snapshot.key
}

resource "random_password" "core_db" {
  count   = local.dms_count
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "core_db_password" {
  count  = local.dms_count
  name   = "/${local.name}/core-db/password"
  type   = "SecureString"
  key_id = aws_kms_key.lake.arn
  value  = random_password.core_db[0].result
}

resource "aws_db_subnet_group" "core" {
  count      = local.dms_count
  name       = "${local.name}-core"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_parameter_group" "core" {
  count  = local.dms_count
  name   = "${local.name}-core-pg16"
  family = "postgres16"

  # Replicación lógica: requisito de DMS para CDC desde PostgreSQL
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "core" {
  count                           = local.dms_count
  identifier                      = "${local.name}-core"
  engine                          = "postgres"
  engine_version                  = "16"
  instance_class                  = "db.t4g.micro"
  allocated_storage               = 20
  storage_type                    = "gp3"
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.lake.arn
  db_name                         = local.core_db_name
  username                        = local.core_db_user
  password                        = random_password.core_db[0].result
  db_subnet_group_name            = aws_db_subnet_group.core[0].name
  parameter_group_name            = aws_db_parameter_group.core[0].name
  vpc_security_group_ids          = [aws_security_group.rds.id]
  publicly_accessible             = false
  backup_retention_period         = 1
  skip_final_snapshot             = true
  deletion_protection             = false
  apply_immediately               = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
}

# --- EC2 de carga (Amazon Linux 2023, ARM, sin llaves SSH: acceso por SSM Session Manager) ---------

data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_s3_object" "core_loader" {
  bucket = aws_s3_bucket.layer["artifacts"].id
  key    = local.core_loader_key
  source = "${path.module}/../../scripts/core_db/load_core_db.py"
  etag   = filemd5("${path.module}/../../scripts/core_db/load_core_db.py")
}

resource "aws_instance" "loader" {
  count                  = local.dms_count
  ami                    = data.aws_ssm_parameter.al2023_arm.value
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.loader.id]
  iam_instance_profile   = module.role["core-loader"].instance_profile_name

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
    kms_key_id  = aws_kms_key.lake.arn
  }

  user_data = templatefile("${path.module}/templates/core_loader_user_data.sh.tftpl", {
    region            = var.region
    artifacts_bucket  = aws_s3_bucket.layer["artifacts"].bucket
    loader_key        = local.core_loader_key
    bronze_bucket     = aws_s3_bucket.layer["bronze"].bucket
    snapshot_key      = local.core_snapshot_s3
    db_host           = aws_db_instance.core[0].address
    db_name           = local.core_db_name
    db_user           = local.core_db_user
    db_password_param = aws_ssm_parameter.core_db_password[0].name
  })
  user_data_replace_on_change = true

  tags = { Name = "${local.name}-core-loader" }

  depends_on = [aws_s3_object.core_loader]
}
