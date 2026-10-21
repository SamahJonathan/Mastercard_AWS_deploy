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
