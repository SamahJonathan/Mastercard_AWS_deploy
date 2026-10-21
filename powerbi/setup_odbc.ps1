<#
.SYNOPSIS
  Prepara la conexión de Power BI a Athena y la prueba (ver docs/powerbi.md):
    1. perfil de AWS "paylake-analyst" (asume el rol de analista: Lake Formation sólo le muestra Gold)
    2. DSN de usuario "PaylakeAthena" con el driver Amazon Athena ODBC 2.x (debe estar instalado)
    3. consulta de prueba por ODBC: si funciona aquí, funciona en Power BI

.EXAMPLE
  ./powerbi/setup_odbc.ps1
#>
param(
    [string]$Dsn = "PaylakeAthena",
    [string]$Profile = "paylake-analyst",
    [string]$Region = "sa-east-1",
    [string]$Workgroup = "paylake-dev-analytics",
    [string]$Database = "paylake_dev_gold"
)
$ErrorActionPreference = "Stop"
$env:Path = $env:Path + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$account = aws sts get-caller-identity --query Account --output text

# 1. Perfil del analista (se agrega sin tocar los demás)
$cfg = Join-Path $HOME ".aws\config"
if (-not (Select-String -Path $cfg -Pattern "\[profile $Profile\]" -Quiet)) {
    Add-Content -Path $cfg -Encoding ascii -Value @"

# Perfil de solo lectura para Power BI / Athena: asume el rol de analista (Lake Formation: solo Gold)
[profile $Profile]
role_arn = arn:aws:iam::${account}:role/paylake-dev-analyst
source_profile = default
region = $Region
"@
}
Write-Host "Perfil '$Profile' -> $(aws sts get-caller-identity --profile $Profile --query Arn --output text)"

# 2. DSN de usuario (no requiere administrador)
$driver = (Get-OdbcDriver -Platform 64-bit | Where-Object Name -match "Athena" | Select-Object -First 1).Name
if (-not $driver) {
    throw "No está instalado el driver Amazon Athena ODBC 2.x: https://docs.aws.amazon.com/athena/latest/ug/odbc-v2-driver.html"
}
Get-OdbcDsn -Name $Dsn -DsnType User -Platform 64-bit -ErrorAction SilentlyContinue | Remove-OdbcDsn
Add-OdbcDsn -Name $Dsn -DriverName $driver -DsnType User -Platform 64-bit -SetPropertyValue @(
    "Description=Payments Lakehouse - Gold (rol analista)",
    "AwsRegion=$Region",
    "Catalog=AwsDataCatalog",
    "Schema=$Database",
    "Workgroup=$Workgroup",
    "S3OutputLocation=s3://paylake-dev-athena-results-$account/results/",
    "AuthenticationType=IAM Profile",
    "AWSProfile=$Profile"
)
Write-Host "DSN '$Dsn' creado con el driver '$driver'"

# 3. Prueba por ODBC (lo mismo que hará Power BI)
$conn = New-Object System.Data.Odbc.OdbcConnection("DSN=$Dsn")
try {
    $conn.Open()
    foreach ($t in "interchange_settlement", "daily_merchant_kpis", "fraud_alerts", "cross_border_corridors") {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT count(*) FROM $Database.$t"
        Write-Host ("  {0,-24} {1,8} filas" -f $t, $cmd.ExecuteScalar())
    }
    # Lake Formation: el analista NO debe poder leer Silver
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT count(*) FROM paylake_dev_silver.transactions"
    try { $cmd.ExecuteScalar() | Out-Null; Write-Host "  silver: LEÍDO (no debería)" -ForegroundColor Red }
    catch { Write-Host "  silver: negado por Lake Formation (correcto)" -ForegroundColor Green }
}
finally { $conn.Close() }
Write-Host "`nListo: en Power BI, Obtener datos -> ODBC -> '$Dsn' (ver docs/powerbi.md)" -ForegroundColor Green
