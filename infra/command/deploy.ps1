<#
.SYNOPSIS
  Comandos que se ejecutan cada vez que se actualiza un cambio.
  Es el equivalente local de .github/workflows/deploy.yml (tests -> validate -> plan -> apply -> smoke test).

.EXAMPLE
  ./infra/command/deploy.ps1                  # tests + validate + plan + apply (pide confirmación)
  ./infra/command/deploy.ps1 -PlanOnly        # sólo muestra qué cambiaría
  ./infra/command/deploy.ps1 -RunPipeline     # además ejecuta el pipeline en AWS y espera el resultado
#>
param(
    [switch]$PlanOnly,
    [switch]$AutoApprove,
    [switch]$RunPipeline,
    [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
# Terminales abiertas antes de instalar el AWS CLI (p.ej. las de VS Code) no ven el PATH nuevo: se agrega
# (sin reemplazar el actual, para no perder el .venv activado).
$env:Path = $env:Path + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$Root = (Resolve-Path "$PSScriptRoot/../..").Path
$Platform = Join-Path $Root "infra/platform"

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Invoke-Checked([scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "Falló: $cmd" }
}

Step "1/6 Herramientas y credenciales AWS"
foreach ($tool in "python", "terraform", "aws") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Falta '$tool' en el PATH" }
}
Invoke-Checked { aws sts get-caller-identity --output table }

if (-not $SkipTests) {
    Step "2/6 Tests de Python (bronze / silver / gold)"
    Invoke-Checked { python -m pip install -q -r "$Root/requirements-dev.txt" }
    Push-Location $Root
    try { Invoke-Checked { python -m pytest -q } } finally { Pop-Location }
}

Step "3/6 Formato de Terraform"
Invoke-Checked { terraform fmt -check -recursive "$Root/infra" }

Step "4/6 Init + validate (estado remoto en S3)"
if (-not (Test-Path "$Platform/backend.hcl")) {
    throw "No existe infra/platform/backend.hcl. Ejecuta primero ./infra/command/bootstrap.ps1"
}
Invoke-Checked { terraform "-chdir=$Platform" init -input=false "-backend-config=backend.hcl" }
Invoke-Checked { terraform "-chdir=$Platform" validate }

Step "5/6 Plan"
terraform "-chdir=$Platform" plan -input=false -detailed-exitcode -out=tfplan
$planExit = $LASTEXITCODE  # 0 = sin cambios, 1 = error, 2 = hay cambios
if ($planExit -eq 1) { throw "terraform plan falló" }

if ($PlanOnly) { Write-Host "`nModo -PlanOnly: no se aplica nada." -ForegroundColor Yellow; exit 0 }

if ($planExit -eq 2) {
    Step "6/6 Apply"
    if (-not $AutoApprove) {
        $answer = Read-Host "¿Aplicar estos cambios en AWS? (s/N)"
        if ($answer -notin "s", "S", "si", "sí") { Write-Host "Cancelado."; exit 0 }
    }
    Invoke-Checked { terraform "-chdir=$Platform" apply -input=false tfplan }
} else {
    Write-Host "`nSin cambios de infraestructura." -ForegroundColor Green
}

if ($RunPipeline) {
    Step "Smoke test: ejecutando el pipeline en Step Functions"
    $arn = terraform "-chdir=$Platform" output -raw state_machine_arn
    $inputFile = New-TemporaryFile
    '{"generate": true}' | Set-Content -Path $inputFile -Encoding ascii
    $exec = aws stepfunctions start-execution --state-machine-arn $arn --input "file://$inputFile" --query executionArn --output text
    Remove-Item $inputFile
    do {
        Start-Sleep -Seconds 10
        $status = aws stepfunctions describe-execution --execution-arn $exec --query status --output text
        Write-Host "  estado: $status"
    } while ($status -eq "RUNNING")
    aws stepfunctions describe-execution --execution-arn $exec --query output --output text
    if ($status -ne "SUCCEEDED") { throw "El pipeline terminó en $status" }
}

Step "Comprobaciones de IAM (lo permitido y lo que debe quedar denegado)"
& "$PSScriptRoot/check_iam.ps1"
if ($LASTEXITCODE -ne 0) { throw "Las comprobaciones de IAM no coinciden con lo esperado" }

Write-Host "`nListo. API: $(terraform "-chdir=$Platform" output -raw api_url)" -ForegroundColor Green
