<#
.SYNOPSIS
  Se ejecuta UNA sola vez, con credenciales de administrador.
  Despliega con AWS CloudFormation el bucket del estado remoto, la confianza OIDC GitHub -> AWS y el rol
  de despliegue; luego genera la configuración local de Terraform y las variables del repositorio en GitHub.

.EXAMPLE
  ./infra/command/bootstrap.ps1
  ./infra/command/bootstrap.ps1 -AlertEmail tu@correo.com
#>
param(
    [string]$GithubRepo = "SamahJonathan/Mastercard_AWS_deploy",
    [string]$Region = "sa-east-1",
    [string]$StackName = "paylake-bootstrap",
    [string]$AlertEmail = ""
)
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path "$PSScriptRoot/../..").Path
$Platform = Join-Path $Root "infra/platform"

function Invoke-Checked([scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "Falló: $cmd" }
}

$caller = aws sts get-caller-identity --query Arn --output text
if ($LASTEXITCODE -ne 0) { throw "AWS CLI sin credenciales: ejecuta 'aws configure' primero" }
Write-Host "Identidad: $caller"

# El proveedor OIDC de GitHub es único por cuenta: si ya existe, se reutiliza
$providers = aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output text
$createOidc = if ($providers -match "token.actions.githubusercontent.com") { "false" } else { "true" }

Invoke-Checked {
    aws cloudformation deploy --region $Region --stack-name $StackName `
        --template-file "$Root/infra/bootstrap/bootstrap.yaml" `
        --capabilities CAPABILITY_NAMED_IAM `
        --parameter-overrides "GithubRepo=$GithubRepo" "CreateOidcProvider=$createOidc" `
        --no-fail-on-empty-changeset
}

$bucket = aws cloudformation describe-stacks --region $Region --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='StateBucket'].OutputValue" --output text
$role = aws cloudformation describe-stacks --region $Region --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='GithubDeployRoleArn'].OutputValue" --output text

# Lake Formation necesita el ARN del usuario/rol (no el de la sesión asumida)
$adminArn = $caller -replace "^arn:aws:sts::(\d+):assumed-role/([^/]+)/.*$", 'arn:aws:iam::$1:role/$2'
$lfAdmins = "[`"$adminArn`"]"

# Configuración local (en .gitignore: no se sube al repo)
@"
bucket = "$bucket"
region = "$Region"
"@ | Set-Content -Path "$Platform/backend.hcl" -Encoding utf8
@"
lakeformation_admin_arns = $lfAdmins
alert_email              = "$AlertEmail"
"@ | Set-Content -Path "$Platform/local.auto.tfvars" -Encoding utf8
Write-Host "Creados infra/platform/backend.hcl y local.auto.tfvars" -ForegroundColor Green

if (Get-Command gh -ErrorAction SilentlyContinue) {
    Invoke-Checked { gh variable set AWS_DEPLOY_ROLE_ARN --repo $GithubRepo --body $role }
    Invoke-Checked { gh variable set TF_STATE_BUCKET --repo $GithubRepo --body $bucket }
    Invoke-Checked { gh variable set LF_ADMIN_ARNS --repo $GithubRepo --body $lfAdmins }
    if ($AlertEmail) { Invoke-Checked { gh variable set ALERT_EMAIL --repo $GithubRepo --body $AlertEmail } }
    Invoke-Checked { gh api -X PUT "repos/$GithubRepo/environments/prod" --silent }
    Write-Host "Variables y environment 'prod' configurados en GitHub ($GithubRepo)" -ForegroundColor Green
} else {
    Write-Host "Configura en GitHub > Settings > Secrets and variables > Actions > Variables:"
    Write-Host "  AWS_DEPLOY_ROLE_ARN = $role"
    Write-Host "  TF_STATE_BUCKET     = $bucket"
    Write-Host "  LF_ADMIN_ARNS       = $lfAdmins"
}
Write-Host "`nSiguiente paso: ./infra/command/deploy.ps1 -RunPipeline" -ForegroundColor Cyan
