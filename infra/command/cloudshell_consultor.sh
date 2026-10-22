#!/usr/bin/env bash
# Crea consultores (consultan sólo Gold, directo en Athena) desde AWS CloudShell.
# Desde la PC, lo equivalente es: ./infra/command/account.ps1  (mismo Terraform, mismo estado en S3).
#
#   cd ~/Mastercard_AWS_deploy && git pull && bash infra/command/cloudshell_consultor.sh [usuario]
#
# Para sumar a otra persona: agregar su nombre a consultant_users en infra/account/main.tf, push,
# y aquí: git pull && bash infra/command/cloudshell_consultor.sh <nuevo-usuario>
#
# 1. Aplica infra/account (Terraform, estado en S3).
# 2. Crea su contraseña de consola con el CLI (fuera del tfstate), de un solo uso: debe cambiarla al entrar.
set -euo pipefail

USER_NAME="${1:-consultor-joony}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Los plugins de Terraform van a /tmp: CloudShell sólo da 1 GB persistente en $HOME
export TF_DATA_DIR="/tmp/paylake-tf-account"
if ! command -v terraform >/dev/null; then
  echo "Falta Terraform: ejecuta primero cloudshell_admin.sh, que lo instala"
  exit 1
fi

# Estado de infra/account: en S3 (mismo bucket que la plataforma) si ya existe; en una cuenta nueva,
# local hasta el bootstrap (después: infra/command/README.md, "Migrar el estado de la etapa 0").
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_BUCKET="paylake-tfstate-$ACCOUNT_ID"
OVERRIDE="$ROOT/infra/account/backend_override.tf"
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  rm -f "$OVERRIDE"
  # Un estado local viejo nunca debe pisar al de S3: se aparta
  if [ -f "$ROOT/infra/account/terraform.tfstate" ]; then
    mv "$ROOT/infra/account/terraform.tfstate" "$ROOT/infra/account/terraform.tfstate.local-obsoleto"
    echo "Estado local apartado (terraform.tfstate.local-obsoleto): se usa el de S3."
  fi
  BACKEND_ARGS=(-reconfigure -backend-config="bucket=$STATE_BUCKET" -backend-config="region=sa-east-1")
else
  printf 'terraform {
  backend "local" {}
}
' > "$OVERRIDE"
  BACKEND_ARGS=()
  echo "Cuenta nueva: estado local en CloudShell hasta que el bootstrap cree $STATE_BUCKET."
fi
if [ ${#BACKEND_ARGS[@]} -eq 0 ]; then
  echo "Primero el bootstrap: los consultores asumen un rol que crea la plataforma."
  exit 1
fi

# La lista de consultores vive SÓLO en infra/account/main.tf (variable consultant_users). No se pasa con -var:
# reemplazaría la lista completa y Terraform borraría a los consultores que no estén en ella.
if ! grep -q "\"$USER_NAME\"" "$ROOT/infra/account/main.tf"; then
  echo "$USER_NAME no está en consultant_users de infra/account/main.tf: agrégalo ahí, haz push y git pull aquí."
  exit 1
fi

echo "==> Terraform: grupo paylake-consultores + usuarios de consultant_users"
terraform -chdir="$ROOT/infra/account" init -input=false "${BACKEND_ARGS[@]}"
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

  Al entrar consulta directo en Athena: workgroup paylake-dev-analytics, base paylake_dev_gold.
=====================================================================
  No pegues la contraseña en chats. Limpia la pantalla con: clear
EOF
fi
