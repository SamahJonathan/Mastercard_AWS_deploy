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

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${local.name}-pipeline"
  retention_in_days = 14
}

# Step Functions valida al crearse que su rol pueda entregar logs: hay que esperar a que la política
# exista y a que IAM la propague (consistencia eventual, unos segundos).
resource "time_sleep" "sfn_policy_propagation" {
  create_duration = "20s"
  triggers        = { policy = aws_iam_role_policy.pipeline_sfn.policy }
}

resource "aws_sfn_state_machine" "pipeline" {
  name       = "${local.name}-pipeline"
  role_arn   = module.role["pipeline-sfn"].arn
  definition = jsonencode(local.definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }

  depends_on = [time_sleep.sfn_policy_propagation]
}

# --- Agenda --------------------------------------------------------------------------------

resource "aws_scheduler_schedule" "pipeline" {
  name                = "${local.name}-hourly"
  schedule_expression = var.schedule_expression
  state               = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_sfn_state_machine.pipeline.arn
    role_arn = module.role["scheduler"].arn
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
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
