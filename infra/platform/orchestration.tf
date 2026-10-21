# Step Functions orquesta Ingest -> Bronze->Silver -> Silver->Gold con reintentos; EventBridge Scheduler lo dispara.

locals {
  retry = [{
    ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException", "Lambda.SdkClientException", "States.Timeout"]
    IntervalSeconds = 10
    MaxAttempts     = 3
    BackoffRate     = 2
  }]

  task = { for k in ["ingest", "bronze-to-silver", "silver-to-gold"] : k => {
    Type           = "Task"
    Resource       = "arn:aws:states:::lambda:invoke"
    Parameters     = { FunctionName = aws_lambda_function.fn[k].arn, "Payload.$" = "$" }
    ResultSelector = { "result.$" = "$.Payload" }
    Retry          = local.retry
  } }

  definition = {
    Comment = "Payments lakehouse: medallion pipeline"
    StartAt = "ShouldIngest"
    States = {
      ShouldIngest = {
        Type    = "Choice"
        Default = "BronzeToSilver"
        Choices = [{
          And  = [{ Variable = "$.generate", IsPresent = true }, { Variable = "$.generate", BooleanEquals = true }]
          Next = "IngestBatch"
        }]
      }
      IngestBatch    = merge(local.task["ingest"], { ResultPath = "$.ingest", Next = "BronzeToSilver" })
      BronzeToSilver = merge(local.task["bronze-to-silver"], { ResultPath = "$.silver", Next = "SilverToGold" })
      SilverToGold   = merge(local.task["silver-to-gold"], { ResultPath = "$.gold", End = true })
    }
  }
}

data "aws_iam_policy_document" "sfn_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "sfn" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [for k in ["ingest", "bronze-to-silver", "silver-to-gold"] : aws_lambda_function.fn[k].arn]
  }
  statement {
    # La entrega de logs de Step Functions requiere estos permisos a nivel de cuenta
    actions = [
      "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${local.name}-pipeline-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_trust.json
}

resource "aws_iam_role_policy" "sfn" {
  name   = "invoke-stages"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn.json
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${local.name}-pipeline"
  retention_in_days = 14
}

resource "aws_sfn_state_machine" "pipeline" {
  name       = "${local.name}-pipeline"
  role_arn   = aws_iam_role.sfn.arn
  definition = jsonencode(local.definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }
}

# --- Agenda --------------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.pipeline.arn]
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "start-pipeline"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "pipeline" {
  name                = "${local.name}-hourly"
  schedule_expression = var.schedule_expression
  state               = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_sfn_state_machine.pipeline.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ generate = true })
  }
}

# --- Alarma: el pipeline falló -------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "pipeline_failed" {
  alarm_name          = "${local.name}-pipeline-failed"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.pipeline.arn }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}
