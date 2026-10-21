<#
.SYNOPSIS
  Apaga el proyecto para no generar costos.
  -PauseOnly sólo desactiva la ejecución horaria; sin él, destruye toda la plataforma
  (el stack bootstrap -estado remoto, OIDC e historial de despliegues- se conserva).

  Igual que deploy.ps1: muestra el plan, pide confirmación y deja registro
  (logs/destroy-<id>.log + CloudWatch /paylake/deployments + S3).
#>
param([switch]$PauseOnly)
$ErrorActionPreference = "Stop"
# Terraform y Python escriben UTF-8; si la consola usa la página de códigos de Windows (CP850), al pasar
# su salida por PowerShell (| Out-Host, para el log) los caracteres se corrompen: "─" se ve como "ÔöÇ".
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
# Terminales abiertas antes de instalar el AWS CLI (p.ej. las de VS Code) no ven el PATH nuevo: se agrega
# (sin reemplazar el actual, para no perder el .venv activado).
$env:Path = $env:Path + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$Root = (Resolve-Path "$PSScriptRoot/../..").Path
$Platform = Join-Path $Root "infra/platform"

$Kind = if ($PauseOnly) { "pause" } else { "destroy" }
$Started = (Get-Date).ToUniversalTime()
$Sha = (git -C $Root rev-parse --short HEAD 2>$null)
$DeployId = "{0:yyyyMMdd-HHmmss}-{1}-{2}" -f $Started, ($Sha ? $Sha : "nogit"), $Kind
New-Item -ItemType Directory -Force -Path (Join-Path $Root "logs") | Out-Null
$LogFile = Join-Path $Root "logs/$Kind-$DeployId.log"
foreach ($c in "init", "plan", "apply", "show") { Set-Item "env:TF_CLI_ARGS_$c" "-no-color" }

$outcome = "failed"
$step = ""
$planFile = ""
$failure = $null
Start-Transcript -Path $LogFile | Out-Null
try {
    $step = "init"
    terraform "-chdir=$Platform" init -input=false "-backend-config=backend.hcl" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "terraform init falló" }

    $step = "plan"
    if ($PauseOnly) {
        terraform "-chdir=$Platform" plan -input=false "-var=schedule_enabled=false" -out=tfplan-stop | Out-Host
    } else {
        terraform "-chdir=$Platform" plan -input=false -destroy -out=tfplan-stop | Out-Host
    }
    if ($LASTEXITCODE -ne 0) { throw "terraform plan falló" }
    $planFile = "tfplan-stop"

    $what = if ($PauseOnly) { "desactivar la ejecución horaria" } else { "DESTRUIR la plataforma" }
    $answer = Read-Host "¿Confirmas $what? (s/N)"
    if ($answer -notin "s", "S", "si", "sí") {
        Write-Host "Cancelado."
        $outcome = "cancelled"
        return
    }

    $step = "apply"
    terraform "-chdir=$Platform" apply -input=false tfplan-stop | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "terraform apply falló" }
    $outcome = "success"
}
catch {
    $failure = $_
    $outcome = "failed"
    Write-Host "`nERROR en '$step': $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
    $recordArgs = @(
        "$Root/scripts/deploy_record.py",
        "--deployment-id", $DeployId,
        "--kind", $Kind,
        "--status", $outcome,
        "--started-at", $Started.ToString("o"),
        "--tf-dir", $Platform,
        "--log-file", $LogFile
    )
    if ($planFile) { $recordArgs += @("--plan-file", $planFile) }
    if ($outcome -eq "failed") { $recordArgs += @("--failed-step", $step, "--error", "$($failure.Exception.Message)") }
    python @recordArgs
}
if ($failure) { throw $failure }
