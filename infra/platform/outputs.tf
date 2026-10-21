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
  value = aws_iam_role.analyst.arn
}

output "partner_roles" {
  description = "Rol y ExternalId que se le entregaría a cada emisor"
  value = { for k, r in aws_iam_role.partner : k => {
    role_arn    = r.arn
    external_id = random_password.partner_external_id[k].result
  } }
  sensitive = true
}
