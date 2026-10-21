#!/usr/bin/env bash
# Etapa 0 — se ejecuta UNA vez en AWS CloudShell (consola de AWS, icono >_ arriba a la derecha).
# CloudShell ya está autenticado con tu sesión de la consola, así que no necesita claves.
#
#   git clone https://github.com/SamahJonathan/Mastercard_AWS_deploy.git
#   cd Mastercard_AWS_deploy && bash infra/command/cloudshell_admin.sh
#
# 1. Instala Terraform en CloudShell si falta.
# 2. Aplica infra/account: grupo paylake-admins (AdministratorAccess) + usuario admin-joony.
# 3. Crea UNA access key con el CLI (fuera de Terraform) y la muestra una sola vez.
set -euo pipefail

USER_NAME="${1:-admin-joony}"
TF_VERSION="1.15.8"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "==> Identidad actual de CloudShell"
aws sts get-caller-identity --output table

if ! command -v terraform >/dev/null; then
  echo "==> Instalando Terraform $TF_VERSION en ~/bin"
  case "$(uname -m)" in
    aarch64) ARCH=arm64 ;;
    *) ARCH=amd64 ;;
  esac
  mkdir -p "$HOME/bin"
  curl -sSLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${ARCH}.zip"
  unzip -oq /tmp/terraform.zip -d "$HOME/bin"
  export PATH="$HOME/bin:$PATH"
fi
terraform version -json | grep -o '"terraform_version":"[^"]*"' || true

# CloudShell sólo da 1 GB persistente en $HOME y el provider de AWS pesa ~800 MB descomprimido.
# Los plugins van a /tmp (disco temporal más grande); el terraform.tfstate sigue en $HOME y persiste.
export TF_DATA_DIR="/tmp/paylake-tf-account"
rm -rf "$ROOT/infra/account/.terraform"   # restos de un intento anterior en $HOME
echo "==> Espacio disponible: $(df -h /tmp | awk 'NR==2 {print $4}') en /tmp, $(df -h "$HOME" | awk 'NR==2 {print $4}') en \$HOME"

echo "==> Terraform: grupo paylake-admins + usuario $USER_NAME"
terraform -chdir="$ROOT/infra/account" init -input=false
terraform -chdir="$ROOT/infra/account" apply -var="admin_users=[\"$USER_NAME\"]"

echo "==> Access key (CLI, fuera de Terraform)"
EXISTING=$(aws iam list-access-keys --user-name "$USER_NAME" --query 'length(AccessKeyMetadata)' --output text)
if [ "$EXISTING" -gt 0 ]; then
  echo "El usuario ya tiene $EXISTING access key(s); no se crea otra."
  echo "Para rotarla: aws iam delete-access-key --user-name $USER_NAME --access-key-id <id> y vuelve a ejecutar."
  exit 0
fi

read -r KEY_ID SECRET < <(aws iam create-access-key --user-name "$USER_NAME" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)

cat <<EOF

=====================================================================
  Copia estos dos valores AHORA: el secreto no se vuelve a mostrar.
  Luego, en tu PC:  aws configure   (región sa-east-1, salida json)

  AWS Access Key ID     : $KEY_ID
  AWS Secret Access Key : $SECRET
=====================================================================
  No los pegues en chats ni en el repositorio.
  Cierra esta pestaña de CloudShell cuando termines (limpia la pantalla con: clear)
EOF
