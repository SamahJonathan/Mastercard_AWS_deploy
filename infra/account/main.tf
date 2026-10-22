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
  # Estado en el mismo bucket que la plataforma (lo crea el bootstrap), así se administra desde la PC
  # (infra/command/account.ps1) o desde CloudShell con el mismo estado. Configuración parcial: el bucket
  # se pasa con -backend-config=../platform/backend.hcl.
  # En una cuenta NUEVA el bucket aún no existe: cloudshell_admin.sh usa estado local con un archivo
  # backend_override.tf y, después del bootstrap, se migra con `terraform init -migrate-state`.
  backend "s3" {
    key          = "account/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
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
  for_each = toset(var.admin_users) # claves estáticas: conocidas antes de crear nada (import y primer plan)
  user     = aws_iam_user.admin[each.key].name
  groups   = [aws_iam_group.admins.name]
}

output "admin_user_arns" {
  description = "Úsalos como lakeformation_admin_arns (bootstrap.ps1 lo hace solo)"
  value       = { for k, u in aws_iam_user.admin : k => u.arn }
}

# =================================================================================================
#  Consultores: sólo consultan tablas. Una identidad por propósito: el administrador despliega,
#  el consultor consulta.
#
#  El consultor NO recibe permisos sobre datos. Su única llave es ponerse el rol de analista
#  (paylake-dev-analyst, definido en infra/platform/iam.tf), y es ese rol el que Lake Formation deja
#  leer: sólo Gold, nunca Silver ni Bronze. Más las llaves mínimas para cuidar su propia cuenta
#  (cambiar su contraseña y configurar su MFA).
# =================================================================================================

# Para dar acceso a otra persona, se agrega aquí (se le entrega el llavero); para quitarlo, se borra.
# Es el ÚNICO lugar donde está esta lista: los scripts de CloudShell no la reemplazan.
variable "consultant_users" {
  description = "Personas que sólo consultan tablas de Gold (Athena / Power BI) asumiendo el rol de analista"
  type        = list(string)
  default     = ["consultor-joony", "consultor-juan", "consultor-maria"]
}

variable "analyst_role_name" {
  description = "Rol de consulta creado por infra/platform (Lake Formation: sólo Gold)"
  type        = string
  default     = "paylake-dev-analyst"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_iam_group" "consultants" {
  name = "paylake-consultores"
  path = "/paylake/"
}

resource "aws_iam_group_policy" "consultants" {
  name  = "solo-consultar-gold"
  group = aws_iam_group.consultants.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PonerseElRolDeAnalista"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::${local.account_id}:role/${var.analyst_role_name}"
      },
      {
        # Sólo sobre su propio usuario (${aws:username}): cambiar su contraseña y gestionar su MFA
        Sid    = "CuidarSuPropiaCuenta"
        Effect = "Allow"
        Action = [
          "iam:GetUser", "iam:ChangePassword", "iam:GetLoginProfile",
          "iam:ListMFADevices", "iam:EnableMFADevice", "iam:ResyncMFADevice", "iam:DeactivateMFADevice",
        ]
        Resource = "arn:aws:iam::${local.account_id}:user/paylake/$${aws:username}"
      },
      {
        Sid      = "CrearSuPropioMfaVirtual"
        Effect   = "Allow"
        Action   = ["iam:CreateVirtualMFADevice", "iam:DeleteVirtualMFADevice"]
        Resource = "arn:aws:iam::${local.account_id}:mfa/$${aws:username}"
      },
      {
        Sid      = "LeerPoliticaDeContrasenas"
        Effect   = "Allow"
        Action   = ["iam:GetAccountPasswordPolicy", "iam:ListVirtualMFADevices"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_user" "consultant" {
  for_each      = toset(var.consultant_users)
  name          = each.value
  path          = "/paylake/"
  force_destroy = true # la contraseña de consola la crea el CLI (cloudshell_consultor.sh), fuera del tfstate
}

resource "aws_iam_user_group_membership" "consultant" {
  for_each = toset(var.consultant_users)
  user     = aws_iam_user.consultant[each.key].name
  groups   = [aws_iam_group.consultants.name]
}

output "consultant_user_arns" {
  value = { for k, u in aws_iam_user.consultant : k => u.arn }
}

output "consultant_switch_role_url" {
  description = "Enlace para que el consultor, ya con sesión iniciada, se ponga el rol de analista en la consola"
  value       = "https://signin.aws.amazon.com/switchrole?account=${local.account_id}&roleName=${var.analyst_role_name}&displayName=Analista%20Gold"
}
