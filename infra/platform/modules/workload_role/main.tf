# Una identidad de carga de trabajo (el equivalente a una service account de GCP):
#   - un rol con su relación de confianza (quién puede usarlo)
#   - una política propia, acción por acción (el "rol personalizado": sólo las llaves que necesita)
#   - siempre con el permissions boundary del proyecto como techo, aunque alguien le agregue permisos de más

variable "name" {
  type = string
}

variable "description" {
  type = string
}

variable "assume_role_policy" {
  description = "Política de confianza (JSON): quién puede asumir el rol"
  type        = string
}

variable "policy" {
  description = "Política propia (JSON). Vacío si el rol sólo usa políticas administradas exigidas por el servicio"
  type        = string
  default     = ""
}

variable "permissions_boundary" {
  description = "ARN del límite máximo de permisos del proyecto"
  type        = string
}

variable "instance_profile" {
  description = "Crear un instance profile (para roles de EC2)"
  type        = bool
  default     = false
}

resource "aws_iam_role" "this" {
  name                  = var.name
  description           = var.description
  assume_role_policy    = var.assume_role_policy
  permissions_boundary  = var.permissions_boundary
  max_session_duration  = 3600
  force_detach_policies = true
}

resource "aws_iam_role_policy" "this" {
  count  = var.policy != "" ? 1 : 0
  name   = "least-privilege"
  role   = aws_iam_role.this.id
  policy = var.policy
}

resource "aws_iam_instance_profile" "this" {
  count = var.instance_profile ? 1 : 0
  name  = var.name
  role  = aws_iam_role.this.name
}

output "arn" {
  value = aws_iam_role.this.arn
}

output "name" {
  value = aws_iam_role.this.name
}

output "instance_profile_name" {
  value = one(aws_iam_instance_profile.this[*].name)
}

# Para que quien dependa del rol espere también a su política (p.ej. servicios que validan permisos al crearse)
output "policy_ready" {
  value = one(aws_iam_role_policy.this[*].id)
}
