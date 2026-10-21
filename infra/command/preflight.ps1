<#
.SYNOPSIS
  Chequeo previo al primer despliegue: revisa lo que suele bloquear (sin crear nada en AWS).
  Ejecutar antes de bootstrap.ps1. Cada fila dice OK, AVISO o FALTA y qué hacer.

.EXAMPLE
  ./infra/command/preflight.ps1
#>
param(
    [string]$Region = "sa-east-1",
    [string]$PandasLayerVersion = "3.16.1",
    [string]$GithubRepo = "SamahJonathan/Mastercard_AWS_deploy"
)
$results = [System.Collections.Generic.List[object]]::new()
function Check([string]$item, [string]$status, [string]$todo) {
    $results.Add([pscustomobject]@{ Estado = $status; Chequeo = $item; QueHacer = $todo })
}
function Has([string]$cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# Terminales abiertas antes de instalar algo (p.ej. las integradas de VS Code) no ven el PATH nuevo:
# se recarga desde el registro para esta sesión.
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

# --- Herramientas locales ---
foreach ($t in @(
        @{ c = "python"; fix = "instalar Python 3.12" },
        @{ c = "terraform"; fix = "winget install -e --id Hashicorp.Terraform" },
        @{ c = "aws"; fix = "winget install -e --id Amazon.AWSCLI  (y abrir una terminal nueva)" },
        @{ c = "gh"; fix = "winget install -e --id GitHub.cli ; gh auth login" })) {
    if (Has $t.c) { Check "Herramienta: $($t.c)" "OK" "" } else { Check "Herramienta: $($t.c)" "FALTA" $t.fix }
}

if (-not (Has "aws")) {
    $results | Format-Table -AutoSize -Wrap
    Write-Host "Instala el AWS CLI y vuelve a ejecutar este chequeo." -ForegroundColor Yellow
    exit 1
}

# --- Credenciales ---
$identity = aws sts get-caller-identity --output json 2>$null | ConvertFrom-Json
if (-not $identity) {
    Check "Credenciales AWS" "FALTA" "crear usuario IAM admin + access key y ejecutar 'aws configure' (región $Region)"
    $results | Format-Table -AutoSize -Wrap
    exit 1
}
if ($identity.Arn -match ":root$") {
    Check "Credenciales AWS" "FALTA" "estás usando el usuario ROOT: crea un usuario IAM administrador y usa sus credenciales"
} else {
    Check "Credenciales AWS" "OK" "$($identity.Arn)"
}
$account = $identity.Account

# --- Capa de pandas para Lambda (si no existe, terraform apply falla) ---
$layerParam = "/aws/service/aws-sdk-pandas/$PandasLayerVersion/py3.12/x86_64/layer-arn"
$layer = aws ssm get-parameter --name $layerParam --region $Region --query Parameter.Value --output text 2>$null
if ($LASTEXITCODE -eq 0 -and $layer) {
    Check "Layer AWS SDK for pandas $PandasLayerVersion" "OK" $layer
} else {
    $available = aws ssm get-parameters-by-path --path "/aws/service/aws-sdk-pandas" --recursive --region $Region `
        --query "Parameters[?contains(Name, 'py3.12/x86_64')].Name" --output text 2>$null
    $latest = ($available -split "\s+" | Where-Object { $_ } | ForEach-Object { ($_ -split "/")[4] } | Sort-Object { [version]$_ } | Select-Object -Last 1)
    Check "Layer AWS SDK for pandas $PandasLayerVersion" "FALTA" "no existe en $Region. Usar la versión $latest : agregar aws_sdk_pandas_version = `"$latest`" en infra/platform/local.auto.tfvars"
}

# --- Cosas que pueden existir de antes en la cuenta ---
$oidc = aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output text 2>$null
if ($oidc -match "token.actions.githubusercontent.com") {
    Check "Proveedor OIDC de GitHub" "AVISO" "ya existe: bootstrap.ps1 lo detecta y lo reutiliza"
} else {
    Check "Proveedor OIDC de GitHub" "OK" "lo creará el bootstrap"
}

$dmsRoles = @("dms-vpc-role", "dms-cloudwatch-logs-role") | Where-Object {
    aws iam get-role --role-name $_ --query Role.Arn --output text 2>$null | Out-Null; $LASTEXITCODE -eq 0
}
if ($dmsRoles) {
    Check "Roles de servicio de DMS" "AVISO" "ya existen ($($dmsRoles -join ', ')): agregar create_dms_service_roles = false en local.auto.tfvars"
} else {
    Check "Roles de servicio de DMS" "OK" "los creará Terraform"
}

$stack = aws cloudformation describe-stacks --stack-name paylake-bootstrap --region $Region --query "Stacks[0].StackStatus" --output text 2>$null
if ($LASTEXITCODE -eq 0) { Check "Bootstrap (CloudFormation)" "OK" "ya desplegado: $stack" } else { Check "Bootstrap (CloudFormation)" "AVISO" "pendiente: ./infra/command/bootstrap.ps1" }

# --- Lake Formation: avisa si ya hay administradores que el despliegue reemplazaría ---
$lfAdmins = aws lakeformation get-data-lake-settings --region $Region --query "DataLakeSettings.DataLakeAdmins[].DataLakePrincipalIdentifier" --output text 2>$null
if ($lfAdmins) {
    Check "Administradores de Lake Formation" "AVISO" "ya hay: $lfAdmins. Terraform reemplaza la lista: agrégalos a lakeformation_admin_arns si deben seguir"
} else {
    Check "Administradores de Lake Formation" "OK" "sin administradores previos"
}

# --- Presupuesto / plan de la cuenta ---
$budgets = aws budgets describe-budgets --account-id $account --query "Budgets[].BudgetName" --output text 2>$null
Check "Plan de la cuenta (prueba)" "AVISO" "revisar en Billing > Free Tier / Credits que haya saldo. Si un servicio responde 'not available on the Free plan', pasar a plan pagado conserva los créditos"
if ($budgets) { Check "Presupuestos existentes" "OK" "$budgets" }

# --- GitHub ---
if (Has "gh") {
    gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $vars = gh variable list --repo $GithubRepo 2>$null
        if ($vars -match "AWS_DEPLOY_ROLE_ARN") { Check "Variables del repo en GitHub" "OK" "configuradas" }
        else { Check "Variables del repo en GitHub" "AVISO" "las crea bootstrap.ps1" }
    } else {
        Check "Sesión de GitHub CLI" "FALTA" "gh auth login"
    }
}

$results | Format-Table -AutoSize -Wrap
$missing = @($results | Where-Object Estado -eq "FALTA").Count
if ($missing) {
    Write-Host "$missing punto(s) por resolver antes de desplegar." -ForegroundColor Red
    exit 1
}
Write-Host "Sin bloqueos. Siguiente: ./infra/command/bootstrap.ps1 -AlertEmail tu@correo.com" -ForegroundColor Green
