<#
.SYNOPSIS
  Remove education organizations previously imported by import-edorgs.ps1 from
  the Admin App application database. Idempotent.

.DESCRIPTION
  Deletes, from the tenant/ODS scope resolved the same way import-edorgs.ps1
  resolves it, every edorg row whose educationOrganizationId appears in the
  CSV. Rows NOT in the CSV are never deleted -- children of a deleted row that
  are not themselves in the CSV are kept and become roots. The related
  edorg_closure rows are removed by the schema itself (cascading foreign keys
  on PostgreSQL, the closure trigger on SQL Server).

  Ed orgs referenced by an Application keep their Admin API association; the
  Admin App only loses the row it displays. Re-import with import-edorgs.ps1
  to restore.

  Defaults are read from the .env file next to this script when present; any
  parameter passed explicitly wins.

.EXAMPLE
  ./cleanup-edorgs.ps1

.EXAMPLE
  ./cleanup-edorgs.ps1 -CsvPath ./edorgs.csv -DbPassword '...' -OdsDbName 'EdFi_Ods_2026'
#>
#requires -Version 5.1
param(
    # Path to the .env file used for defaults (copy .env.example and edit it).
    [string]$EnvFile = "$PSScriptRoot/.env",
    # CSV whose educationOrganizationId values will be deleted from the scope.
    [string]$CsvPath,

    [string]$TenantName,
    [string]$EnvironmentName,
    [string]$OdsDbName,

    [ValidateSet('mssql', 'pgsql')][string]$DbEngine,
    [string]$DatabaseName,

    # --- mssql -----------------------------------------------------------------
    [string]$SqlServer,
    [string]$DbUsername,
    [string]$DbPassword,
    [switch]$UseIntegratedSecurity,

    # --- pgsql -----------------------------------------------------------------
    [string]$PostgresAppPassword,
    [string]$PostgresHost,
    [int]$PostgresPort,
    [string]$PostgresAppUser,
    [switch]$UsePostgresDocker,
    [string]$PostgresContainerName
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/load-dotenv.ps1"
. "$PSScriptRoot/compat.ps1"

# ---- Defaults: explicit parameter > .env value > built-in --------------------
$dotenv = if (Test-Path $EnvFile) { Read-DotEnv -Path $EnvFile } else { @{} }
function Get-EnvValue
{
    param([string]$Name, [string]$Default = '')
    if ($dotenv.ContainsKey($Name) -and $dotenv[$Name] -ne '') { return $dotenv[$Name] }
    return $Default
}
function Test-EnvTrue
{
    param([string]$Name)
    (Get-EnvValue $Name) -in @('true', 'True', 'TRUE', '1', 'yes')
}

if (-not $PSBoundParameters.ContainsKey('CsvPath') -or -not $CsvPath) { $CsvPath = Get-EnvValue 'CSV_PATH' "$PSScriptRoot/edorgs.csv" }
if (-not $TenantName) { $TenantName = Get-EnvValue 'TENANT_NAME' 'default' }
if (-not $EnvironmentName) { $EnvironmentName = Get-EnvValue 'ENVIRONMENT_NAME' }
if (-not $OdsDbName) { $OdsDbName = Get-EnvValue 'ODS_DB_NAME' (Get-EnvValue 'ODS_DATABASE_NAME') }
if (-not $DbEngine) { $DbEngine = Get-EnvValue 'DB_ENGINE' 'mssql' }
if (-not $DatabaseName) { $DatabaseName = Get-EnvValue 'DATABASE_NAME' 'sbaa' }
if (-not $SqlServer) { $SqlServer = Get-EnvValue 'SQL_SERVER' 'tcp:localhost,1433' }
if (-not $DbUsername) { $DbUsername = Get-EnvValue 'ADMIN_APP_DB_USER' 'sa' }
if (-not $DbPassword) { $DbPassword = Get-EnvValue 'ADMIN_APP_DB_PASSWORD' }
if (-not $UseIntegratedSecurity -and (Test-EnvTrue 'USE_INTEGRATED_SECURITY')) { $UseIntegratedSecurity = $true }
if (-not $PostgresAppPassword) { $PostgresAppPassword = Get-EnvValue 'POSTGRES_APP_PASSWORD' }
if (-not $PostgresHost) { $PostgresHost = Get-EnvValue 'POSTGRES_HOST' 'localhost' }
if (-not $PostgresPort) { $PostgresPort = [int](Get-EnvValue 'POSTGRES_PORT' '5432') }
if (-not $PostgresAppUser) { $PostgresAppUser = Get-EnvValue 'POSTGRES_APP_USER' 'edfiadminapp' }
if (-not $UsePostgresDocker -and (Test-EnvTrue 'USE_POSTGRES_DOCKER')) { $UsePostgresDocker = $true }
if (-not $PostgresContainerName) { $PostgresContainerName = Get-EnvValue 'POSTGRES_CONTAINER' 'edfiadminapp-postgres' }

# Passwords not passed as a parameter or set in the .env are prompted for
# (masked), like run.ps1.
if ($DbEngine -eq 'mssql' -and -not $UseIntegratedSecurity -and -not $DbPassword)
{
    $DbPassword = Read-Secret 'ADMIN_APP_DB_PASSWORD' 'Admin App database password (the ADMIN_APP_DB_USER login)'
}
if ($DbEngine -eq 'pgsql' -and -not $PostgresAppPassword)
{
    $PostgresAppPassword = Read-Secret 'POSTGRES_APP_PASSWORD' 'Admin App PostgreSQL password'
}
if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath. The cleanup deletes exactly the ids listed in the CSV used for the import." }

if ($DbEngine -eq 'mssql')
{
    # The @(...) wrap is load-bearing: assignment from an if-expression unrolls
    # a one-element array to a scalar string, and splatting a scalar to a
    # native command garbles the argument list.
    $authArgs = @(if ($UseIntegratedSecurity) { '-E' } else { '-U', $DbUsername, '-P', $DbPassword })
}

function Invoke-AdminAppSql
{
    param([Parameter(Mandatory = $true)][string]$Sql, [string]$FailHint)

    if ($DbEngine -eq 'mssql')
    {
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("edorg-cleanup-{0}.sql" -f [guid]::NewGuid())
        try
        {
            # UTF-8 with BOM so sqlcmd decodes non-ASCII input correctly
            # ('utf8BOM' is not a valid encoding name on 5.1).
            Write-Utf8BomFile -Path $tempFile -Content $Sql
            $out = & sqlcmd -S $SqlServer @authArgs -d $DatabaseName -b -h -1 -W -s '|' -i $tempFile
            if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE). $FailHint" }
            return $out
        }
        finally
        {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    if ($UsePostgresDocker)
    {
        $out = $Sql | & docker exec -i -e "PGPASSWORD=$PostgresAppPassword" $PostgresContainerName psql -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1 -t -A -F '|'
    }
    else
    {
        $env:PGPASSWORD = $PostgresAppPassword
        $out = $Sql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1 -t -A -F '|'
    }
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE). $FailHint" }
    return $out
}

# ---- Step 1: the ids to delete ------------------------------------------------
$ids = @(Import-Csv -Path $CsvPath -Encoding UTF8 | ForEach-Object { "$($_.educationOrganizationId)".Trim() } |
        Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique)
if ($ids.Count -eq 0) { throw "No educationOrganizationId values found in $CsvPath." }
Write-Host "Deleting up to $($ids.Count) education organizations listed in $CsvPath..."

# ---- Step 2: resolve the tenant / ODS scope (same rules as import) -----------
$tenantNameSql = $TenantName.Replace("'", "''")
$envNameSql = $EnvironmentName.Replace("'", "''")
$odsDbNameSql = $OdsDbName.Replace("'", "''")

if ($DbEngine -eq 'mssql')
{
    $envFilter = if ($EnvironmentName) { "AND e.[name] = N'$envNameSql'" } else { '' }
    $odsFilter = if ($OdsDbName) { "AND o.[dbName] = N'$odsDbNameSql'" } else { '' }
    $scopeSql = @"
SET NOCOUNT ON;
SELECT t.[id], o.[id], o.[dbName], e.[name]
FROM [edfi_tenant] t
    INNER JOIN [sb_environment] e ON e.[id] = t.[sbEnvironmentId]
    INNER JOIN [ods] o ON o.[edfiTenantId] = t.[id]
WHERE t.[name] = N'$tenantNameSql'
    $envFilter
    $odsFilter;
"@
}
else
{
    $envFilter = if ($EnvironmentName) { "AND e.name = '$envNameSql'" } else { '' }
    $odsFilter = if ($OdsDbName) { 'AND o."dbName" = ' + "'$odsDbNameSql'" } else { '' }
    $scopeSql = @"
SELECT t.id, o.id, o."dbName", e.name
FROM edfi_tenant t
    JOIN sb_environment e ON e.id = t."sbEnvironmentId"
    JOIN ods o ON o."edfiTenantId" = t.id
WHERE t.name = '$tenantNameSql'
    $envFilter
    $odsFilter;
"@
}

$scopeRows = @(Invoke-AdminAppSql -Sql $scopeSql -FailHint 'Check the connection parameters and -DatabaseName.' |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -match '\|' })
if ($scopeRows.Count -eq 0)
{
    Write-Host "Nothing to do: no registered ODS found for tenant '$TenantName'$(if ($OdsDbName) { " with dbName '$OdsDbName'" })." -ForegroundColor Yellow
    return
}
if ($scopeRows.Count -gt 1)
{
    $candidates = ($scopeRows | ForEach-Object { $p = $_ -split '\|'; "environment '$($p[3])' / ods dbName '$($p[2])'" }) -join '; '
    throw "Tenant '$TenantName' matches more than one scope: $candidates. Disambiguate with -OdsDbName (and -EnvironmentName if needed)."
}
$parts = $scopeRows[0] -split '\|'
$tenantId = [int]$parts[0]
$odsId = [int]$parts[1]
Write-Host "  Scope: tenant id $tenantId, ODS '$($parts[2])' (id $odsId)."

# ---- Step 3: delete -----------------------------------------------------------
# Children outside the CSV are re-rooted (parentId = NULL) before the delete
# so the self-referencing foreign key never blocks it; edorg_closure rows are
# cascaded by the schema itself on both engines.
$idList = $ids -join ', '

if ($DbEngine -eq 'mssql')
{
    $sql = @"
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
SET NOCOUNT ON;

BEGIN TRANSACTION;

SELECT e.[id] INTO #victims
FROM [edorg] e
WHERE e.[edfiTenantId] = $tenantId AND e.[odsId] = $odsId
    AND e.[educationOrganizationId] IN ($idList);

UPDATE [edorg] SET [parentId] = NULL
WHERE [parentId] IN (SELECT [id] FROM #victims)
    AND [id] NOT IN (SELECT [id] FROM #victims);

DELETE FROM [edorg] WHERE [id] IN (SELECT [id] FROM #victims);
PRINT CONCAT('Deleted ', @@ROWCOUNT, ' edorg row(s).');

COMMIT TRANSACTION;
"@
}
else
{
    $sql = @"
BEGIN;

CREATE TEMP TABLE victims ON COMMIT DROP AS
SELECT e.id
FROM edorg e
WHERE e."edfiTenantId" = $tenantId AND e."odsId" = $odsId
    AND e."educationOrganizationId" IN ($idList);

UPDATE edorg SET "parentId" = NULL
WHERE "parentId" IN (SELECT id FROM victims)
    AND id NOT IN (SELECT id FROM victims);

DELETE FROM edorg WHERE id IN (SELECT id FROM victims);

COMMIT;
"@
}

$output = Invoke-AdminAppSql -Sql $sql -FailHint 'Nothing was deleted (the cleanup is transactional).'
$output | Where-Object { "$_".Trim() -and "$_" -match 'Deleted|DELETE' } | ForEach-Object { Write-Host "  $_" }

Write-Host "`nSUCCESS: cleanup complete (re-runs are no-ops)." -ForegroundColor Green
Write-Host "Re-import at any time with ./import-edorgs.ps1." -ForegroundColor Green
