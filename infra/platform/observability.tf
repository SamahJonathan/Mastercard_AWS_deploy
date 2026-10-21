# Observabilidad: métricas propias del pipeline (EMF), alarmas técnicas y de calidad de datos,
# alertas por email (SNS), dashboard de CloudWatch y presupuesto de AWS Budgets.

locals {
  metrics_namespace = "PaymentsLakehouse/${var.environment}"
}

# --- Canal de alertas ----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowAlarmsAndEvents"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com", "budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Presupuesto (protege el periodo de prueba) ------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.alerts]
}

# --- Alarmas técnicas ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each            = local.functions
  alarm_name          = "${local.name}-lambda-${each.key}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.fn[each.key].function_name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dms_cdc_latency" {
  count             = local.dms_count
  alarm_name        = "${local.name}-dms-cdc-latency"
  alarm_description = "La réplica CDC del core lleva más de 10 minutos de atraso"
  namespace         = "AWS/DMS"
  metric_name       = "CDCLatencySource"
  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.main[0].replication_instance_id
    ReplicationTaskIdentifier     = element(split(":", aws_dms_replication_task.core_to_bronze[0].replication_task_arn), 6)
  }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 600
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Fallas del job de Glue llegan por EventBridge
resource "aws_cloudwatch_event_rule" "glue_failed" {
  name        = "${local.name}-glue-job-failed"
  description = "El job de Glue terminó en FAILED/TIMEOUT"
  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.gold_card_analytics.name]
      state   = ["FAILED", "TIMEOUT", "ERROR"]
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_failed" {
  rule = aws_cloudwatch_event_rule.glue_failed.name
  arn  = aws_sns_topic.alerts.arn
}

# --- Alarmas de calidad de datos (métricas EMF emitidas por las Lambdas) -------------------------

resource "aws_cloudwatch_metric_alarm" "rejection_rate" {
  alarm_name          = "${local.name}-dq-rejection-rate"
  alarm_description   = "Más del 8 % de los registros del simulador fue a cuarentena en la última hora"
  evaluation_periods  = 1
  threshold           = 0.08
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "rate"
    expression  = "rejected / bronze"
    label       = "Tasa de rechazo"
    return_data = true
  }

  metric_query {
    id = "rejected"
    metric {
      namespace   = local.metrics_namespace
      metric_name = "RejectedRecords"
      dimensions  = { Stage = "bronze_to_silver", Source = "simulator" }
      stat        = "Sum"
      period      = 3600
    }
  }

  metric_query {
    id = "bronze"
    metric {
      namespace   = local.metrics_namespace
      metric_name = "BronzeRecords"
      dimensions  = { Stage = "bronze_to_silver", Source = "simulator" }
      stat        = "Sum"
      period      = 3600
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "reconciliation" {
  alarm_name          = "${local.name}-dq-reconciliation-mismatch"
  alarm_description   = "Los totales del core no cuadran con Silver"
  namespace           = local.metrics_namespace
  metric_name         = "ReconciliationMismatches"
  dimensions          = { Stage = "bronze_to_silver", Source = "core" }
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# --- Dashboard ----------------------------------------------------------------------------------

locals {
  ns = local.metrics_namespace

  dashboard_widgets = concat(
    [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2
        properties = { markdown = "# Payments Lakehouse (${var.environment})\nPipeline medallion: ingesta → Bronze → Silver → Gold. Datos sintéticos." }
      },
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6
        properties = {
          title  = "Step Functions: ejecuciones"
          region = var.region
          stat   = "Sum"
          period = 3600
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.pipeline.arn],
            [".", "ExecutionsFailed", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6
        properties = {
          title   = "Registros por capa (simulador)"
          region  = var.region
          stat    = "Sum"
          period  = 3600
          metrics = [for m in ["BronzeRecords", "SilverRecords", "RejectedRecords", "DuplicatesRemoved"] : [local.ns, m, "Stage", "bronze_to_silver", "Source", "simulator"]]
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6
        properties = {
          title   = "Fuente core (archivo o DMS)"
          region  = var.region
          stat    = "Maximum"
          period  = 3600
          metrics = [for m in ["SilverRecords", "RejectedRecords", "ReconciliationMismatches"] : [local.ns, m, "Stage", "bronze_to_silver", "Source", "core"]]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 8, height = 6
        properties = {
          title  = "Gold: alertas de fraude e intercambio (USD)"
          region = var.region
          stat   = "Maximum"
          period = 3600
          metrics = [
            [local.ns, "FraudAlerts", "Stage", "silver_to_gold", "Source", "all"],
            [local.ns, "InterchangeUsd", "Stage", "silver_to_gold", "Source", "all", { yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 8, width = 8, height = 6
        properties = {
          title   = "Lambda: duración p95 (ms)"
          region  = var.region
          stat    = "p95"
          period  = 3600
          metrics = [for k in keys(local.functions) : ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.fn[k].function_name]]
        }
      },
      {
        type = "metric", x = 16, y = 8, width = 8, height = 6
        properties = {
          title   = "Lambda: errores"
          region  = var.region
          stat    = "Sum"
          period  = 3600
          metrics = [for k in keys(local.functions) : ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.fn[k].function_name]]
        }
      },
      {
        type = "log", x = 0, y = 14, width = 24, height = 6
        properties = {
          title  = "Últimos errores del pipeline"
          region = var.region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.fn["bronze-to-silver"].name}' | SOURCE '${aws_cloudwatch_log_group.fn["silver-to-gold"].name}' | SOURCE '${aws_cloudwatch_log_group.fn["ingest"].name}' | fields @timestamp, @log, @message | filter @message like /(?i)(error|exception|traceback)/ | sort @timestamp desc | limit 20"
        }
      },
    ],
    [for w in [
      {
        type = "metric", x = 0, y = 20, width = 12, height = 6
        properties = {
          title  = "DMS: latencia CDC (s)"
          region = var.region
          stat   = "Maximum"
          period = 300
          metrics = [
            ["AWS/DMS", "CDCLatencySource", "ReplicationInstanceIdentifier", one(aws_dms_replication_instance.main[*].replication_instance_id), "ReplicationTaskIdentifier", element(split(":", try(aws_dms_replication_task.core_to_bronze[0].replication_task_arn, "::::::-")), 6)],
            [".", "CDCLatencyTarget", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 20, width = 12, height = 6
        properties = {
          title  = "RDS core: CPU y conexiones"
          region = var.region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", one(aws_db_instance.core[*].identifier)],
            [".", "DatabaseConnections", ".", ".", { yAxis = "right" }],
          ]
        }
      },
    ] : w if var.enable_dms],
  )
}

resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${local.name}-pipeline"
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
