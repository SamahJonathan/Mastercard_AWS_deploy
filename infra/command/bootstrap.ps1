<#
.SYNOPSIS
  Se ejecuta UNA sola vez, con credenciales de administrador.
  Crea el bucket del estado remoto, la confianza OIDC GitHub -> AWS y el rol de despliegue;
  luego genera infra/platform/backend.hcl y configura las variables del repositorio en GitHub.

.EXAMPLE
  ./infra/command/bootstrap.ps1
  ./infra/command/bootstrap.ps1 -GithubRepo "otro-usuario/otro-repo"
#>
param(
    [string]$GithubRepo = "SamahJonathan/Mastercard_AWS_deploy",
    [string]$Region = "sa-east-1"
)
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path "$PSScriptRoot/../..").Path
$Bootstrap = Join-Path $Root "infra/bootstrap"

function Invoke-Checked([scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "Falló: $cmd" }
}

Invoke-Checked { aws sts get-caller-identity --output table }
Invoke-Checked { terraform "-chdir=$Bootstrap" init -input=false }
Invoke-Checked { terraform "-chdir=$Bootstrap" apply "-var=github_repo=$GithubRepo" "-var=region=$Region" }

$bucket = terraform "-chdir=$Bootstrap" output -raw state_bucket
$role = terraform "-chdir=$Bootstrap" output -raw github_deploy_role_arn

# backend.hcl está en .gitignore: es configuración local, no se sube al repo
@"
bucket = "$bucket"
region = "$Region"
"@ | Set-Content -Path "$Root/infra/platform/backend.hcl" -Encoding utf8
Write-Host "Creado infra/platform/backend.hcl" -ForegroundColor Green

if (Get-Command gh -ErrorAction SilentlyContinue) {
    Invoke-Checked { gh variable set AWS_DEPLOY_ROLE_ARN --repo $GithubRepo --body $role }
    Invoke-Checked { gh variable set TF_STATE_BUCKET --repo $GithubRepo --body $bucket }
    Invoke-Checked { gh api -X PUT "repos/$GithubRepo/environments/prod" --silent }
    Write-Host "Variables y environment 'prod' configurados en GitHub ($GithubRepo)" -ForegroundColor Green
} else {
    Write-Host "Configura en GitHub > Settings > Secrets and variables > Actions > Variables:"
    Write-Host "  AWS_DEPLOY_ROLE_ARN = $role"
    Write-Host "  TF_STATE_BUCKET     = $bucket"
}
Write-Host "`nSiguiente paso: ./infra/command/deploy.ps1 -RunPipeline" -ForegroundColor Cyan
