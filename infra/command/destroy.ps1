<#
.SYNOPSIS
  Apaga el proyecto para no generar costos.
  -PauseOnly sólo desactiva la ejecución horaria; sin él, destruye toda la plataforma
  (el stack bootstrap -estado remoto y OIDC- se conserva).
#>
param([switch]$PauseOnly)
$ErrorActionPreference = "Stop"
# Terminales abiertas antes de instalar el AWS CLI (p.ej. las de VS Code) no ven el PATH nuevo: se agrega
# (sin reemplazar el actual, para no perder el .venv activado).
$env:Path = $env:Path + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$Platform = Join-Path (Resolve-Path "$PSScriptRoot/../..").Path "infra/platform"

terraform "-chdir=$Platform" init -input=false "-backend-config=backend.hcl" | Out-Null
if ($PauseOnly) {
    terraform "-chdir=$Platform" apply "-var=schedule_enabled=false"
} else {
    terraform "-chdir=$Platform" destroy
}
if ($LASTEXITCODE -ne 0) { throw "terraform falló" }
