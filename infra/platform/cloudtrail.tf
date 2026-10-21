# AWS CloudTrail: auditoría de la cuenta + eventos de datos sobre Bronze (quién lee/escribe datos con PAN).
# Los eventos van a un bucket de auditoría y a CloudWatch Logs, donde filtros de métricas disparan alarmas.

locals {
  trail_count = var.enable_cloudtrail ? 1 : 0
  trail_name  = "${local.name}-audit"
  trail_arn   = "arn:aws:cloudtrail:${var.region}:${local.account_id}:trail/${local.trail_name}"
}

resource "aws_s3_bucket" "audit" {
  count         = local.trail_count
  bucket        = "${local.name}-audit-${local.account_id}"
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_public_access_block" "audit" {
  count                   = local.trail_count
  bucket                  = aws_s3_bucket.audit[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  count  = local.trail_count
  bucket = aws_s3_bucket.audit[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  count  = local.trail_count
  bucket = aws_s3_bucket.audit[0].id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
  }
}

data "aws_iam_policy_document" "audit_bucket" {
  count = local.trail_count
  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit[0].arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit[0].arn, "${aws_s3_bucket.audit[0].arn}/*"]
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

resource "aws_s3_bucket_policy" "audit" {
  count  = local.trail_count
  bucket = aws_s3_bucket.audit[0].id
  policy = data.aws_iam_policy_document.audit_bucket[0].json
}

resource "aws_cloudwatch_log_group" "trail" {
  count             = local.trail_count
  name              = "/aws/cloudtrail/${local.name}"
  retention_in_days = 30
}

resource "aws_cloudtrail" "audit" {
  count                         = local.trail_count
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.audit[0].id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.trail[0].arn}:*"
  cloud_watch_logs_role_arn     = module.role["cloudtrail-logs"].arn

  advanced_event_selector {
    name = "Eventos de administracion"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  advanced_event_selector {
    name = "Acceso a objetos de Bronze (datos con PAN)"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = ["${local.arn["bronze"]}/"]
    }
  }

  depends_on = [aws_s3_bucket_policy.audit, module.role]
}

# --- Alertas de seguridad a partir del trail ---------------------------------------------------

locals {
  security_filters = {
    UnauthorizedApiCalls = "{ ($.errorCode = \"AccessDenied\") || ($.errorCode = \"*UnauthorizedOperation\") }"
    IamPolicyChanges     = "{ ($.eventSource = \"iam.amazonaws.com\") && (($.eventName = \"PutRolePolicy\") || ($.eventName = \"AttachRolePolicy\") || ($.eventName = \"DeleteRolePolicy\") || ($.eventName = \"DetachRolePolicy\") || ($.eventName = \"UpdateAssumeRolePolicy\")) }"
    LakeFormationGrants  = "{ ($.eventSource = \"lakeformation.amazonaws.com\") && (($.eventName = \"GrantPermissions\") || ($.eventName = \"RevokePermissions\") || ($.eventName = \"PutDataLakeSettings\")) }"
  }
}

resource "aws_cloudwatch_log_metric_filter" "security" {
  for_each       = var.enable_cloudtrail ? local.security_filters : {}
  name           = "${local.name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.trail[0].name
  pattern        = each.value

  metric_transformation {
    name          = each.key
    namespace     = "${local.metrics_namespace}/Security"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "security" {
  for_each            = var.enable_cloudtrail ? local.security_filters : {}
  alarm_name          = "${local.name}-security-${each.key}"
  alarm_description   = "Evento de seguridad detectado por CloudTrail: ${each.key}"
  namespace           = "${local.metrics_namespace}/Security"
  metric_name         = each.key
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.key == "UnauthorizedApiCalls" ? 5 : 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  depends_on = [aws_cloudwatch_log_metric_filter.security]
}
