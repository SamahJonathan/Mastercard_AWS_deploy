# =================================================================================================
#  Etapa 0: la identidad de administrador con la que se opera el proyecto desde tu PC.
#  Se aplica UNA vez desde AWS CloudShell (ya autenticado en la consola): ./infra/command/cloudshell_admin.sh
#  Apuntes: docs/iam.md, sección "Etapa 0".
#
#  Igual que un binding de GCP: el permiso se ata a un GRUPO y las personas son miembros del grupo.
#  Agregar o quitar a alguien no toca permisos; sólo cambia la membresía.
#
#  La access key NO se crea aquí: si la creara Terraform, el secreto quedaría en texto plano en el
#  terraform.tfstate. La crea el script con el CLI y se muestra una sola vez.
# =================================================================================================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
  # Estado local a propósito: esta etapa existe ANTES que el bucket del estado remoto (bootstrap).
  # En CloudShell el directorio $HOME persiste entre sesiones.
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "paylake", ManagedBy = "terraform", Stack = "account" }
  }
}

variable "region" {
  type    = string
  default = "sa-east-1"
}

variable "admin_users" {
  description = "Personas que operan el proyecto (miembros del grupo de administradores)"
  type        = list(string)
  default     = ["admin-joony"]
}

# --- El grupo: aquí vive el permiso --------------------------------------------------------------

resource "aws_iam_group" "admins" {
  name = "paylake-admins"
  path = "/paylake/"
}

# Aditivo: ata UNA política a ESTE grupo. (aws_iam_policy_attachment sería exclusivo: el set-iam-policy)
resource "aws_iam_group_policy_attachment" "admins" {
  group      = aws_iam_group.admins.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- Las personas: sólo membresía, sin permisos propios -------------------------------------------

resource "aws_iam_user" "admin" {
  for_each      = toset(var.admin_users)
  name          = each.value
  path          = "/paylake/"
  force_destroy = true # permite borrar el usuario aunque tenga access keys creadas por el CLI
}

# Aditivo: agrega ESTE usuario a sus grupos, respetando otras membresías.
# (aws_iam_group_membership sería exclusivo: dejaría en el grupo sólo a los que declara)
resource "aws_iam_user_group_membership" "admin" {
  for_each = aws_iam_user.admin
  user     = each.value.name
  groups   = [aws_iam_group.admins.name]
}

output "admin_user_arns" {
  description = "Úsalos como lakeformation_admin_arns (bootstrap.ps1 lo hace solo)"
  value       = { for k, u in aws_iam_user.admin : k => u.arn }
}
