variable "region" {
  type    = string
  default = "sa-east-1"
}

variable "project" {
  type    = string
  default = "paylake"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "schedule_expression" {
  description = "Frecuencia con que llega un lote nuevo y se ejecuta el pipeline"
  type        = string
  default     = "rate(1 hour)"
}

variable "schedule_enabled" {
  description = "Apagar (false) para no generar costos cuando no se está mostrando el proyecto"
  type        = bool
  default     = true
}

variable "batch_size" {
  type    = number
  default = 2000
}

variable "lookback_days" {
  type    = number
  default = 3
}

variable "aws_sdk_pandas_version" {
  description = "Versión del layer administrado AWS SDK for pandas (awswrangler)"
  type        = string
  default     = "3.16.1"
}

variable "partner_issuers" {
  description = "Emisores que reciben sus archivos de liquidación vía un rol IAM propio (intercambio de datos)"
  type        = list(string)
  default     = ["EM001", "EM005"]
}

variable "partner_principal_arn" {
  description = "Principal (cuenta AWS del socio) que puede asumir los roles de emisor. Por defecto, la propia cuenta."
  type        = string
  default     = null
}

variable "core_snapshot_ingest_date" {
  description = "Partición ingest_date con que se aterriza el extracto core de sample_data en Bronze"
  type        = string
  default     = "2026-10-21"
}

# --- Piezas opcionales (con costo por hora) ---------------------------------------------------

variable "enable_dms" {
  description = "Core bancario en RDS PostgreSQL + EC2 de carga + replicación AWS DMS (full load + CDC) hacia Bronze"
  type        = bool
  default     = true
}

variable "create_dms_service_roles" {
  description = "Crear los roles de servicio dms-vpc-role y dms-cloudwatch-logs-role (false si la cuenta ya los tiene)"
  type        = bool
  default     = true
}

variable "enable_quicksight" {
  description = "Crea data source y datasets de QuickSight (requiere suscripción a QuickSight y quicksight_user_arn)"
  type        = bool
  default     = false
}

variable "quicksight_user_arn" {
  description = "ARN del usuario QuickSight dueño de los recursos, p.ej. arn:aws:quicksight:sa-east-1:123456789012:user/default/admin"
  type        = string
  default     = ""
}

variable "enable_cloudtrail" {
  type    = bool
  default = true
}

# --- Gobierno y observabilidad -----------------------------------------------------------------

variable "lakeformation_admin_arns" {
  description = "Principales IAM (además del rol de despliegue de GitHub) que administran Lake Formation"
  type        = list(string)
  default     = []
}

variable "alert_email" {
  description = "Correo que recibe alarmas y alertas de presupuesto (vacío = sin suscripción)"
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Presupuesto mensual; avisa al 80 % real y al 100 % pronosticado"
  type        = number
  default     = 25
}

variable "glue_schedule" {
  description = "Cron del job de Glue (UTC)"
  type        = string
  default     = "cron(0 6 * * ? *)"
}

variable "loader_instance_type" {
  description = "EC2 de carga del core. Debe ser elegible para Free Tier en cuentas con plan gratuito (ARM: t4g.micro)"
  type        = string
  default     = "t4g.micro"
}

variable "dms_instance_class" {
  description = "Clase de la instancia de replicación DMS. dms.t3.micro no existe en sa-east-1; la menor es dms.t3.small"
  type        = string
  default     = "dms.t3.small"
}
