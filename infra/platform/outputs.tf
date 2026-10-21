output "buckets" {
  value = { for k, b in aws_s3_bucket.layer : k => b.bucket }
}

output "glue_databases" {
  value = { for k, d in aws_glue_catalog_database.layer : k => d.name }
}

output "athena_workgroup" {
  value = aws_athena_workgroup.analytics.name
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline.arn
}

output "api_url" {
  value = aws_apigatewayv2_api.gold.api_endpoint
}

output "api_key" {
  value     = random_password.api_key.result
  sensitive = true
}

output "analyst_role_arn" {
  value = module.role["analyst"].arn
}

output "partner_roles" {
  description = "Rol y ExternalId que se le entregaría a cada emisor"
  value = { for issuer in var.partner_issuers : issuer => {
    role_arn    = module.role["partner-${lower(issuer)}"].arn
    external_id = random_password.partner_external_id[issuer].result
  } }
  sensitive = true
}

output "risk_analyst_role_arn" {
  value = module.role["risk-analyst"].arn
}

output "cloudwatch_dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.pipeline.dashboard_name}"
}

output "glue_job_name" {
  value = aws_glue_job.gold_card_analytics.name
}

output "core_db_endpoint" {
  description = "PostgreSQL del core bancario (privado; accesible desde la EC2 de carga vía SSM)"
  value       = one(aws_db_instance.core[*].address)
}

output "core_loader_instance_id" {
  description = "Conectarse con: aws ssm start-session --target <id>"
  value       = one(aws_instance.loader[*].id)
}

output "dms_task_arn" {
  value = one(aws_dms_replication_task.core_to_bronze[*].replication_task_arn)
}
