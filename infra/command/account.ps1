<#
.SYNOPSIS
  Administra las personas del proyecto (infra/account) desde la PC: llaveros paylake-admins y
  paylake-consultores. Para dar o quitar acceso se edita la lista en infra/account/main.tf y se ejecuta esto.

  - Estado de Terraform en S3 (el mismo bucket que la plataforma).
  - Muestra el plan y pide confirmación; NUNCA debería haber "to destroy" salvo que quitaste a alguien.
  - A cada consultor sin contraseña de consola le crea una TEMPORAL (debe cambiarla al entrar) y la guarda
    en logs/credenciales-consultores.txt (fuera de git). No la muestra en pantalla.

.EXAMPLE
  ./infra/command/account.ps1 -PlanOnly
  ./infra/command/account.ps1
#>
param(
    [switch]$PlanOnly,
    [switch]$AutoApprove
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:Path = $env:Path + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
foreach ($c in "init", "plan", "apply") { Set-Item "env:TF_CLI_ARGS_$c" "-no-color" }
$Root = (Resolve-Path "$PSScriptRoot/../..").Path
$Account = Join-Path $Root "infra/account"
$Backend = Join-Path $Root "infra/platform/backend.hcl"
if (-not (Test-Path $Backend)) { throw "Falta infra/platform/backend.hcl: ejecuta primero bootstrap.ps1" }

terraform "-chdir=$Account" init -input=false "-backend-config=$Backend" | Out-Host
if ($LASTEXITCODE -ne 0) { throw "terraform init falló" }

terraform "-chdir=$Account" plan -input=false -detailed-exitcode "-out=account.tfplan" | Out-Host
$planExit = $LASTEXITCODE  # 0 = sin cambios, 1 = error, 2 = hay cambios
if ($planExit -eq 1) { throw "terraform plan falló" }
if ($PlanOnly) { return }

if ($planExit -eq 2) {
    if (-not $AutoApprove) {
        $answer = Read-Host "¿Aplicar estos cambios de IAM? Revisa que '0 to destroy' salvo que quitaste a alguien (s/N)"
        if ($answer -notin "s", "S", "si", "sí") { Write-Host "Cancelado."; return }
    }
    terraform "-chdir=$Account" apply -input=false account.tfplan | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "terraform apply falló" }
}
Remove-Item (Join-Path $Account "account.tfplan") -ErrorAction SilentlyContinue

# Contraseñas temporales de consola para los consultores que aún no tienen (CLI: fuera del tfstate)
$account = aws sts get-caller-identity --query Account --output text
$users = (aws iam get-group --group-name paylake-consultores --query "Users[].UserName" --output text) -split "\s+" | Where-Object { $_ }
$credFile = Join-Path $Root "logs/credenciales-consultores.txt"
$created = @()
foreach ($u in $users) {
    aws iam get-login-profile --user-name $u 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { continue }
    $bytes = New-Object byte[] 12
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $password = ([Convert]::ToBase64String($bytes) -replace "[/+=]", "") + "Aa1!"
    aws iam create-login-profile --user-name $u --password $password --password-reset-required | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear la contraseña de $u" }
    New-Item -ItemType Directory -Force -Path (Split-Path $credFile) | Out-Null
    Add-Content -Path $credFile -Encoding utf8 -Value ("{0:yyyy-MM-dd HH:mm}  {1,-20} contraseña temporal: {2}" -f (Get-Date), $u, $password)
    $created += $u
}

Write-Host "`nConsultores: $($users -join ', ')" -ForegroundColor Green
if ($created) {
    Write-Host "Contraseñas temporales creadas para: $($created -join ', ')"
    Write-Host "Guardadas en logs/credenciales-consultores.txt (no se muestran aquí; entrégalas por un canal privado)."
}
Write-Host "URL de acceso : https://$account.signin.aws.amazon.com/console"
Write-Host "Cambiar de rol: https://signin.aws.amazon.com/switchrole?account=$account&roleName=paylake-dev-analyst&displayName=Analista%20Gold"
