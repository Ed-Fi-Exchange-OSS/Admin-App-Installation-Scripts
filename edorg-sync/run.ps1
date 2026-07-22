#requires -Version 7.0
<#
.SYNOPSIS
  One-step education organization sync: loads .env and runs export-edorgs.ps1
  (EdFi_ODS -> CSV) then import-edorgs.ps1 (CSV -> Admin App database).

.DESCRIPTION
  Copy .env.example to .env, edit the values to match your deployment, then
  run ./run.ps1. The variables map 1:1 onto the parameters of
  export-edorgs.ps1 (which reads the ODS) and import-edorgs.ps1 (which writes
  the Admin App database). Both scripts are idempotent, so re-running is safe.

  The source ODS and the target Admin App database are configured
  independently (ODS_* variables vs the unprefixed ones): they can live on
  different servers and even different engines -- e.g. an ODS on SQL Server
  feeding an Admin App on PostgreSQL.

  The import attaches the ed orgs to an EXISTING tenant + ODS registration in
  the Admin App database. Register the environment, tenant, and ODS instances
  first through the Admin App UI.

.EXAMPLE
  ./run.ps1

.EXAMPLE
  # CSV already exported (or hand-edited): only load it.
  ./run.ps1 -SkipExport

.EXAMPLE
  # Only produce the CSV, e.g. to review it before importing.
  ./run.ps1 -SkipImport

.EXAMPLE
  ./run.ps1 -EnvFile ./my-deployment.env
#>
param(
    # Path to the .env file (copy .env.example and edit it).
    [string]$EnvFile = "$PSScriptRoot/.env",
    # Skip export-edorgs.ps1 and import an existing CSV_PATH.
    [switch]$SkipExport,
    # Skip import-edorgs.ps1 and only export the CSV.
    [switch]$SkipImport
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/load-dotenv.ps1"

if ($SkipExport -and $SkipImport) { throw 'Nothing to do: -SkipExport and -SkipImport exclude each other.' }
if (-not (Test-Path $EnvFile))
{
    throw "Env file not found: $EnvFile. Copy .env.example to .env and fill in the values for your deployment."
}
$script:dotenv = Read-DotEnv -Path $EnvFile

function Get-EnvValue
{
    param([string]$Name, [string]$Default = '')
    if ($script:dotenv.ContainsKey($Name) -and $script:dotenv[$Name] -ne '') { return $script:dotenv[$Name] }
    return $Default
}
function Test-EnvTrue
{
    param([string]$Name)
    (Get-EnvValue $Name) -in @('true', 'True', 'TRUE', '1', 'yes')
}

$odsEngine = Get-EnvValue 'ODS_DB_ENGINE' 'mssql'
$dbEngine = Get-EnvValue 'DB_ENGINE' 'mssql'
$csvPath = Get-EnvValue 'CSV_PATH' "$PSScriptRoot/edorgs.csv"

# ---- Up-front validation of the engine-specific required values --------------
$missing = @()
if (-not $SkipExport)
{
    if (-not (Get-EnvValue 'ODS_DATABASE_NAME')) { $missing += 'ODS_DATABASE_NAME' }
    if ($odsEngine -eq 'mssql' -and -not (Test-EnvTrue 'ODS_USE_INTEGRATED_SECURITY') -and
        -not (Get-EnvValue 'ODS_DB_PASSWORD')) { $missing += 'ODS_DB_PASSWORD' }
    if ($odsEngine -eq 'pgsql' -and -not (Get-EnvValue 'ODS_POSTGRES_PASSWORD')) { $missing += 'ODS_POSTGRES_PASSWORD' }
}
if (-not $SkipImport)
{
    if ($dbEngine -eq 'mssql' -and -not (Test-EnvTrue 'USE_INTEGRATED_SECURITY') -and
        -not (Get-EnvValue 'ADMIN_APP_DB_PASSWORD')) { $missing += 'ADMIN_APP_DB_PASSWORD' }
    if ($dbEngine -eq 'pgsql' -and -not (Get-EnvValue 'POSTGRES_APP_PASSWORD')) { $missing += 'POSTGRES_APP_PASSWORD' }
}
if ($missing.Count -gt 0)
{
    throw "Missing required value(s) in ${EnvFile}: $($missing -join ', '). Edit the file and try again."
}

# ---- Step 1: export-edorgs.ps1 (EdFi_ODS -> CSV) ------------------------------
if ($SkipExport)
{
    Write-Host "Skipping export-edorgs.ps1 (-SkipExport); importing $csvPath." -ForegroundColor Yellow
}
else
{
    $exportArgs = @{
        OdsDatabaseName = Get-EnvValue 'ODS_DATABASE_NAME'
        OutputPath      = $csvPath
        DbEngine        = $odsEngine
    }
    if ($odsEngine -eq 'mssql')
    {
        $exportArgs.SqlServer = Get-EnvValue 'ODS_SQL_SERVER' 'tcp:localhost,1433'
        $exportArgs.DbUsername = Get-EnvValue 'ODS_DB_USERNAME' 'sa'
        if (Test-EnvTrue 'ODS_USE_INTEGRATED_SECURITY')
        {
            $exportArgs.UseIntegratedSecurity = $true
        }
        else
        {
            $exportArgs.DbPassword = Get-EnvValue 'ODS_DB_PASSWORD'
        }
    }
    else
    {
        $exportArgs.PostgresPassword = Get-EnvValue 'ODS_POSTGRES_PASSWORD'
        $exportArgs.PostgresHost = Get-EnvValue 'ODS_POSTGRES_HOST' 'localhost'
        $exportArgs.PostgresPort = [int](Get-EnvValue 'ODS_POSTGRES_PORT' '5432')
        $exportArgs.PostgresUser = Get-EnvValue 'ODS_POSTGRES_USER' 'postgres'
        if (Test-EnvTrue 'ODS_USE_POSTGRES_DOCKER')
        {
            $exportArgs.UsePostgresDocker = $true
            $exportArgs.PostgresContainerName = Get-EnvValue 'ODS_POSTGRES_CONTAINER' 'ed-fi-db-ods'
        }
    }

    Write-Host "==> export-edorgs.ps1 (engine=$odsEngine, db=$($exportArgs.OdsDatabaseName))" -ForegroundColor Cyan
    & "$PSScriptRoot/export-edorgs.ps1" @exportArgs
}

# ---- Step 2: import-edorgs.ps1 (CSV -> Admin App database) --------------------
if ($SkipImport)
{
    Write-Host "`nSkipping import-edorgs.ps1 (-SkipImport). Review $csvPath, then run ./run.ps1 -SkipExport to load it." -ForegroundColor Yellow
    return
}

$importArgs = @{
    CsvPath      = $csvPath
    TenantName   = Get-EnvValue 'TENANT_NAME' 'default'
    DbEngine     = $dbEngine
    DatabaseName = Get-EnvValue 'DATABASE_NAME' 'sbaa'
}
$environmentName = Get-EnvValue 'ENVIRONMENT_NAME'
if ($environmentName) { $importArgs.EnvironmentName = $environmentName }
# The registered ODS to attach to; defaults to the database the CSV came from.
$odsDbName = Get-EnvValue 'ODS_DB_NAME' (Get-EnvValue 'ODS_DATABASE_NAME')
if ($odsDbName) { $importArgs.OdsDbName = $odsDbName }
if ($dbEngine -eq 'mssql')
{
    $importArgs.SqlServer = Get-EnvValue 'SQL_SERVER' 'tcp:localhost,1433'
    $importArgs.DbUsername = Get-EnvValue 'ADMIN_APP_DB_USER' 'sa'
    if (Test-EnvTrue 'USE_INTEGRATED_SECURITY')
    {
        $importArgs.UseIntegratedSecurity = $true
    }
    else
    {
        $importArgs.DbPassword = Get-EnvValue 'ADMIN_APP_DB_PASSWORD'
    }
}
else
{
    $importArgs.PostgresAppPassword = Get-EnvValue 'POSTGRES_APP_PASSWORD'
    $importArgs.PostgresHost = Get-EnvValue 'POSTGRES_HOST' 'localhost'
    $importArgs.PostgresPort = [int](Get-EnvValue 'POSTGRES_PORT' '5432')
    $importArgs.PostgresAppUser = Get-EnvValue 'POSTGRES_APP_USER' 'edfiadminapp'
    if (Test-EnvTrue 'USE_POSTGRES_DOCKER')
    {
        $importArgs.UsePostgresDocker = $true
        $importArgs.PostgresContainerName = Get-EnvValue 'POSTGRES_CONTAINER' 'edfiadminapp-postgres'
    }
}

Write-Host "`n==> import-edorgs.ps1 (engine=$dbEngine)" -ForegroundColor Cyan
& "$PSScriptRoot/import-edorgs.ps1" @importArgs
