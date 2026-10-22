#!/usr/bin/env bash
# Crea el usuario consultor (sólo consulta Gold asumiendo el rol de analista). Se ejecuta en AWS CloudShell,
# en la MISMA carpeta donde se corrió cloudshell_admin.sh: ahí vive el terraform.tfstate de infra/account.
#
#   cd ~/Mastercard_AWS_deploy && git pull && bash infra/command/cloudshell_consultor.sh [usuario]
#
# Para sumar a otra persona: agregar su nombre a consultant_users en infra/account/main.tf, push,
# y aquí: git pull && bash infra/command/cloudshell_consultor.sh <nuevo-usuario>
#
# 1. Aplica infra/account: grupo paylake-consultores + usuario consultor-joony (Terraform).
# 2. Crea su contraseña de consola con el CLI (fuera del tfstate), de un solo uso: debe cambiarla al entrar.
set -euo pipefail

USER_NAME="${1:-consultor-joony}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="$ROOT/infra/account/terraform.tfstate"

if [ ! -f "$STATE" ]; then
  echo "No encuentro $STATE."
  echo "Este script debe correr en la misma carpeta de CloudShell donde se ejecutó cloudshell_admin.sh"
  echo "(si se volvió a clonar el repo, el estado de la etapa 0 se perdió)."
  exit 1
fi

# Los plugins de Terraform van a /tmp: CloudShell sólo da 1 GB persistente en $HOME
export TF_DATA_DIR="/tmp/paylake-tf-account"
if ! command -v terraform >/dev/null; then
  echo "Falta Terraform: ejecuta primero cloudshell_admin.sh, que lo instala"
  exit 1
fi

# La lista de consultores vive SÓLO en infra/account/main.tf (variable consultant_users). No se pasa con -var:
# reemplazaría la lista completa y Terraform borraría a los consultores que no estén en ella.
if ! grep -q "\"$USER_NAME\"" "$ROOT/infra/account/main.tf"; then
  echo "$USER_NAME no está en consultant_users de infra/account/main.tf: agrégalo ahí, haz push y git pull aquí."
  exit 1
fi

echo "==> Terraform: grupo paylake-consultores + usuarios de consultant_users"
terraform -chdir="$ROOT/infra/account" init -input=false
terraform -chdir="$ROOT/infra/account" apply

echo "==> Contraseña de consola (CLI, fuera de Terraform)"
if aws iam get-login-profile --user-name "$USER_NAME" >/dev/null 2>&1; then
  echo "El usuario ya tiene contraseña de consola; no se crea otra."
else
  PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)Aa1!"
  aws iam create-login-profile --user-name "$USER_NAME" --password "$PASSWORD" --password-reset-required >/dev/null
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
  cat <<EOF

=====================================================================
  Usuario consultor creado. Contraseña TEMPORAL (se cambia al entrar):

  URL de acceso : https://${ACCOUNT}.signin.aws.amazon.com/console
  Usuario       : ${USER_NAME}
  Contraseña    : ${PASSWORD}

  Después de entrar, ponerse el rol de analista:
  $(terraform -chdir="$ROOT/infra/account" output -raw consultant_switch_role_url)
=====================================================================
  No pegues la contraseña en chats. Limpia la pantalla con: clear
EOF
fi
