data "aws_caller_identity" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  db_prefix  = replace(local.name, "-", "_")

  layers = ["bronze", "silver", "gold", "exchange", "athena-results", "artifacts"]
}

# --- Cifrado ---------------------------------------------------------------------------------
# Una CMK para todo el lake: S3, parámetros SSM y resultados de Athena.
resource "aws_kms_key" "lake" {
  description             = "${local.name} data lake"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "lake" {
  name          = "alias/${local.name}-lake"
  target_key_id = aws_kms_key.lake.key_id
}

# --- Secretos --------------------------------------------------------------------------------
resource "random_password" "pan_token_secret" {
  length  = 48
  special = false
}

resource "random_password" "api_key" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "pan_token_secret" {
  name   = "/${local.name}/pan-token-secret"
  type   = "SecureString"
  key_id = aws_kms_key.lake.arn
  value  = random_password.pan_token_secret.result
}

resource "aws_ssm_parameter" "api_key" {
  name   = "/${local.name}/api-key"
  type   = "SecureString"
  key_id = aws_kms_key.lake.arn
  value  = random_password.api_key.result
}
