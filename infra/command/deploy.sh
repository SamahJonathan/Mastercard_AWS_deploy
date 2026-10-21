#!/usr/bin/env bash
# Comandos que se ejecutan cada vez que se actualiza un cambio (Linux / macOS / Git Bash).
# Equivalente a deploy.ps1 y a .github/workflows/deploy.yml.
#
#   ./infra/command/deploy.sh                 # tests + validate + plan + apply (pide confirmación)
#   ./infra/command/deploy.sh --plan-only
#   ./infra/command/deploy.sh --run-pipeline
set -euo pipefail

PLAN_ONLY=false; RUN_PIPELINE=false; AUTO_APPROVE=false
for arg in "$@"; do
  case "$arg" in
    --plan-only) PLAN_ONLY=true ;;
    --run-pipeline) RUN_PIPELINE=true ;;
    --auto-approve) AUTO_APPROVE=true ;;
    *) echo "Argumento desconocido: $arg"; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLATFORM="$ROOT/infra/platform"
step() { printf '\n==> %s\n' "$1"; }

step "1/6 Herramientas y credenciales AWS"
for tool in python terraform aws; do command -v "$tool" >/dev/null || { echo "Falta $tool"; exit 1; }; done
aws sts get-caller-identity --output table

step "2/6 Tests de Python"
python -m pip install -q -r "$ROOT/requirements-dev.txt"
(cd "$ROOT" && python -m pytest -q)

step "3/6 Formato de Terraform"
terraform fmt -check -recursive "$ROOT/infra"

step "4/6 Init + validate"
[ -f "$PLATFORM/backend.hcl" ] || { echo "Falta infra/platform/backend.hcl: ejecuta bootstrap.ps1 primero"; exit 1; }
terraform -chdir="$PLATFORM" init -input=false -backend-config=backend.hcl
terraform -chdir="$PLATFORM" validate

step "5/6 Plan"
set +e
terraform -chdir="$PLATFORM" plan -input=false -detailed-exitcode -out=tfplan
PLAN_EXIT=$?
set -e
[ "$PLAN_EXIT" -eq 1 ] && { echo "terraform plan falló"; exit 1; }
$PLAN_ONLY && exit 0

if [ "$PLAN_EXIT" -eq 2 ]; then
  step "6/6 Apply"
  if ! $AUTO_APPROVE; then
    read -r -p "¿Aplicar estos cambios en AWS? (s/N) " answer
    [[ "$answer" =~ ^[sS] ]] || { echo "Cancelado."; exit 0; }
  fi
  terraform -chdir="$PLATFORM" apply -input=false tfplan
else
  echo "Sin cambios de infraestructura."
fi

if $RUN_PIPELINE; then
  step "Smoke test: pipeline en Step Functions"
  ARN=$(terraform -chdir="$PLATFORM" output -raw state_machine_arn)
  EXEC=$(aws stepfunctions start-execution --state-machine-arn "$ARN" --input '{"generate": true}' --query executionArn --output text)
  while :; do
    sleep 10
    STATUS=$(aws stepfunctions describe-execution --execution-arn "$EXEC" --query status --output text)
    echo "  estado: $STATUS"
    [ "$STATUS" != "RUNNING" ] && break
  done
  aws stepfunctions describe-execution --execution-arn "$EXEC" --query output --output text
  [ "$STATUS" = "SUCCEEDED" ]
fi

echo "Listo. API: $(terraform -chdir="$PLATFORM" output -raw api_url)"
