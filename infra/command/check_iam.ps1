<#
.SYNOPSIS
  Comprobación de IAM: simula, con el simulador de políticas de AWS, lo que cada identidad PUEDE
  y lo que NO PUEDE hacer. No ejecuta nada real; sólo pregunta "¿esto estaría permitido?".
  Apuntes: docs/iam.md

  Sale con código 0 si todas las respuestas coinciden con lo esperado, 1 si alguna no.

.EXAMPLE
  ./infra/command/check_iam.ps1
#>
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

$account = aws sts get-caller-identity --query Account --output text
$buckets = terraform "-chdir=$Platform" output -json buckets | ConvertFrom-Json
$sfnArn = terraform "-chdir=$Platform" output -raw state_machine_arn
$name = "paylake-dev"
$boundary = "arn:aws:iam::${account}:policy/paylake-workload-boundary"

function S3([string]$layer, [string]$key) { "arn:aws:s3:::$($buckets.$layer)/$key" }
function Role([string]$suffix) { "arn:aws:iam::${account}:role/$suffix" }

# Identidad, acción, recurso, resultado esperado, por qué importa
$checks = @(
    @{ id = "$name-ingest"; action = "s3:PutObject"; res = (S3 bronze "transactions/x.jsonl"); expect = "allowed"; why = "aterriza lotes en Bronze" }
    @{ id = "$name-ingest"; action = "s3:GetObject"; res = (S3 bronze "transactions/x.jsonl"); expect = "implicitDeny"; why = "escribe, pero no lee datos con PAN" }
    @{ id = "$name-ingest"; action = "s3:PutObject"; res = (S3 silver "transactions/x"); expect = "implicitDeny"; why = "no salta capas" }
    @{ id = "$name-bronze-to-silver"; action = "s3:GetObject"; res = (S3 bronze "transactions/x.jsonl"); expect = "allowed"; why = "lee la capa anterior" }
    @{ id = "$name-bronze-to-silver"; action = "s3:PutObject"; res = (S3 gold "x"); expect = "implicitDeny"; why = "sólo escribe Silver" }
    @{ id = "$name-silver-to-gold"; action = "s3:GetObject"; res = (S3 bronze "transactions/x.jsonl"); expect = "implicitDeny"; why = "Gold nunca toca datos con PAN" }
    @{ id = "$name-silver-to-gold"; action = "s3:PutObject"; res = (S3 exchange "outbound/issuer_id=EM001/x.csv"); expect = "allowed"; why = "publica liquidaciones" }
    @{ id = "$name-api"; action = "s3:GetObject"; res = (S3 gold "x"); expect = "allowed"; why = "sirve Gold" }
    @{ id = "$name-api"; action = "s3:GetObject"; res = (S3 silver "x"); expect = "implicitDeny"; why = "la API no expone detalle transaccional" }
    @{ id = "$name-api"; action = "s3:PutObject"; res = (S3 gold "x"); expect = "implicitDeny"; why = "la API es de sólo lectura" }
    @{ id = "$name-glue-gold-analytics"; action = "s3:GetObject"; res = (S3 bronze "x"); expect = "implicitDeny"; why = "Glue parte desde Silver" }
    @{ id = "$name-analyst"; action = "s3:GetObject"; res = (S3 gold "x"); expect = "implicitDeny"; why = "los datos sólo llegan vía Lake Formation" }
    @{ id = "$name-analyst"; action = "lakeformation:GetDataAccess"; res = "*"; expect = "allowed"; why = "credenciales temporales por tabla concedida" }
    @{ id = "$name-analyst"; action = "s3:GetObject"; res = (S3 bronze "x"); expect = "implicitDeny"; why = "ningún humano lee Bronze" }
    @{ id = "$name-analyst"; action = "iam:CreateUser"; res = "*"; expect = "explicitDeny"; why = "el boundary niega todo IAM (prueba que el techo está aplicado)" }
    @{ id = "$name-partner-em001"; action = "s3:GetObject"; res = (S3 exchange "outbound/issuer_id=EM001/settlement_date=2026-10-21/settlement.csv"); expect = "allowed"; why = "lee SUS liquidaciones" }
    @{ id = "$name-partner-em001"; action = "s3:GetObject"; res = (S3 exchange "outbound/issuer_id=EM005/settlement_date=2026-10-21/settlement.csv"); expect = "implicitDeny"; why = "no ve las de otro banco" }
    @{ id = "$name-scheduler"; action = "states:StartExecution"; res = $sfnArn; expect = "allowed"; why = "dispara el pipeline" }
    @{ id = "$name-scheduler"; action = "lambda:InvokeFunction"; res = "*"; expect = "implicitDeny"; why = "no invoca etapas sueltas" }
    # El rol de despliegue de GitHub: puede crear roles, pero sólo con el boundary puesto
    @{ id = "paylake-github-deploy"; action = "iam:CreateRole"; res = (Role "$name-nuevo"); expect = "allowed"; why = "crea roles CON boundary"; context = $boundary }
    @{ id = "paylake-github-deploy"; action = "iam:CreateRole"; res = (Role "$name-nuevo"); expect = "implicitDeny"; why = "sin boundary no puede (no fabrica un admin)" }
    @{ id = "paylake-github-deploy"; action = "iam:CreateRole"; res = (Role "otro-proyecto-rol"); expect = "implicitDeny"; why = "sólo roles del proyecto"; context = $boundary }
    @{ id = "paylake-github-deploy"; action = "iam:UpdateAssumeRolePolicy"; res = (Role "paylake-github-deploy"); expect = "explicitDeny"; why = "no puede modificarse a sí mismo" }
    @{ id = "paylake-github-deploy"; action = "iam:DeleteRolePermissionsBoundary"; res = (Role "$name-api"); expect = "explicitDeny"; why = "no puede quitar el techo" }
    @{ id = "paylake-github-deploy"; action = "iam:CreateUser"; res = "*"; expect = "implicitDeny"; why = "no crea usuarios ni access keys" }
)

# Consultores (infra/account): cada miembro de paylake-consultores consulta Gold directo y nada más.
$workgroup = "arn:aws:athena:sa-east-1:${account}:workgroup/$name-analytics"
$goldTable = "arn:aws:glue:sa-east-1:${account}:table/paylake_dev_gold/interchange_settlement"
$silverTable = "arn:aws:glue:sa-east-1:${account}:table/paylake_dev_silver/transactions"
$members = aws iam get-group --group-name paylake-consultores --query "Users[].[UserName,Arn]" --output json 2>$null | ConvertFrom-Json
foreach ($m in @($members)) {
    if (-not $m) { continue }
    $u, $uArn = $m[0], $m[1]
    $checks += @(
        @{ arn = $uArn; id = $u; action = "athena:StartQueryExecution"; res = $workgroup; expect = "allowed"; why = "consulta directo en el workgroup" }
        @{ arn = $uArn; id = $u; action = "glue:GetTable"; res = $goldTable; expect = "allowed"; why = "ve las tablas de Gold" }
        @{ arn = $uArn; id = $u; action = "glue:GetTable"; res = $silverTable; expect = "implicitDeny"; why = "Silver ni siquiera aparece" }
        @{ arn = $uArn; id = $u; action = "s3:GetObject"; res = (S3 gold "x"); expect = "implicitDeny"; why = "los datos sólo llegan vía Lake Formation" }
        @{ arn = $uArn; id = $u; action = "sts:AssumeRole"; res = (Role "$name-analyst"); expect = "implicitDeny"; why = "ya no necesita cambiar de rol" }
        @{ arn = $uArn; id = $u; action = "iam:CreateUser"; res = "*"; expect = "implicitDeny"; why = "no crea identidades" }
    )
}

$failed = 0
$rows = foreach ($c in $checks) {
    $cliArgs = @("iam", "simulate-principal-policy", "--policy-source-arn", ($c.arn ? $c.arn : (Role $c.id)), "--action-names", $c.action,
        "--resource-arns", $c.res, "--query", "EvaluationResults[0].EvalDecision", "--output", "text")
    if ($c.context) {
        $cliArgs += @("--context-entries", "ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=$($c.context),ContextKeyType=string")
    }
    $got = (& aws @cliArgs 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { $got = "ERROR: $got" }
    $ok = $got -eq $c.expect
    if (-not $ok) { $failed++ }
    [pscustomobject]@{
        OK        = if ($ok) { "OK" } else { "FALLA" }
        Identidad = $c.id -replace "^$name-", ""
        Accion    = $c.action
        Esperado  = $c.expect
        Obtenido  = $got
        Porque    = $c.why
    }
}
$rows | Format-Table -AutoSize -Wrap

if ($failed) {
    Write-Host "$failed comprobación(es) no coinciden con lo esperado" -ForegroundColor Red
    exit 1
}
Write-Host "Las $($checks.Count) comprobaciones de IAM coinciden con lo esperado." -ForegroundColor Green
