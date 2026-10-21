# Un bucket por capa: permite políticas IAM, retención y cifrado independientes por nivel de madurez del dato.
resource "aws_s3_bucket" "layer" {
  for_each      = toset(local.layers)
  bucket        = "${local.name}-${each.key}-${local.account_id}"
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_ownership_controls" "layer" {
  for_each = aws_s3_bucket.layer
  bucket   = each.value.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "layer" {
  for_each                = aws_s3_bucket.layer
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "layer" {
  for_each = aws_s3_bucket.layer
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.lake.arn
    }
    bucket_key_enabled = true
  }
}

# Bronze (fuente de verdad, inmutable) y Exchange (archivos entregados a terceros) quedan versionados
resource "aws_s3_bucket_versioning" "versioned" {
  for_each = { for k, v in aws_s3_bucket.layer : k => v if contains(["bronze", "exchange"], k) }
  bucket   = each.value.id
  versioning_configuration { status = "Enabled" }
}

data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.layer
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "layer" {
  for_each   = aws_s3_bucket.layer
  bucket     = each.value.id
  policy     = data.aws_iam_policy_document.tls_only[each.key].json
  depends_on = [aws_s3_bucket_public_access_block.layer]
}

resource "aws_s3_bucket_lifecycle_configuration" "bronze" {
  bucket = aws_s3_bucket.layer["bronze"].id
  rule {
    id     = "tiering"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.layer["athena-results"].id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration { days = 7 }
  }
}

# Extracto del sistema core (sample_data) aterrizado tal cual en Bronze: segunda fuente de ingesta
resource "aws_s3_object" "core_snapshot" {
  bucket = aws_s3_bucket.layer["bronze"].id
  key    = "core_snapshot/ingest_date=${var.core_snapshot_ingest_date}/mastercard_db_ficticia.json"
  source = "${path.module}/../../sample_data/mastercard_db_ficticia.json"
  etag   = filemd5("${path.module}/../../sample_data/mastercard_db_ficticia.json")

  content_type = "application/json"
}
