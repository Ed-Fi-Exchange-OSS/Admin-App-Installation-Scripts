<#
.SYNOPSIS
  Remove education organizations previously imported by import-edorgs.ps1 from
  the Admin App application database. Idempotent.

.DESCRIPTION
  Deletes, from the tenant/ODS scope resolved the same way import-edorgs.ps1
  resolves it, the edorg rows that import-edorgs.ps1 INSERTED there: by
  default the victims come from the imported-ids.csv manifest the import
  writes (filtered to the resolved scope), so rows the Admin App created
  itself -- e.g. the 'Institution #<id>' placeholders written when an ODS is
  registered with allowed ed orgs -- are never deleted. On success the
  manifest entries for the scope are removed, so re-runs are no-ops.

  Passing -CsvPath explicitly overrides the manifest with any CSV that has an
  educationOrganizationId column (e.g. the export CSV). In that mode there is
  no record of which rows this tooling created, so every listed id in the
  scope is deleted, including rows the Admin App wrote; a warning says so.

  Children of a deleted row that are not themselves victims are kept and
  become roots, and the closure rows linking their subtree to surviving
  ancestors are removed so the hierarchy the Admin App displays stays
  consistent. Team access (ownership) rows referencing a victim are deleted
  in the same transaction -- the ownership -> edorg foreign key would
  otherwise block the delete -- and each removed grant is reported.

  Ed orgs referenced by an Application keep their Admin API association; the
  Admin App only loses the row it displays. Re-import with import-edorgs.ps1
  to restore.

  Defaults are read from the .env file next to this script when present; any
  parameter passed explicitly wins.

.PARAMETER EnvFile
  Path to the .env file used for defaults (copy .env.example and edit it).

.PARAMETER CsvPath
  Victim list. Default: the imported-ids.csv manifest import-edorgs.ps1 writes
  next to its CSV, so only rows the import inserted are deleted. Pass
  explicitly to delete every id listed in an arbitrary CSV instead (any file
  with an educationOrganizationId column) -- including rows the Admin App
  created itself.

.PARAMETER TenantName
  Admin App tenant to delete from (edfi_tenant.name); .env TENANT_NAME, else
  'default'.

.PARAMETER EnvironmentName
  Environment name (sb_environment.name); only needed when the same tenant
  name exists in more than one environment. .env ENVIRONMENT_NAME.

.PARAMETER OdsDbName
  Which registered ODS scope to delete from (ods.dbName); only needed when the
  tenant has more than one ODS registered. .env ODS_DB_NAME.

.PARAMETER DbEngine
  Admin App database engine: 'mssql' or 'pgsql'. .env DB_ENGINE, else 'mssql'.

.PARAMETER DatabaseName
  The Admin App application database. .env DATABASE_NAME, else 'sbaa'.

.PARAMETER SqlServer
  mssql only: the SQL Server to connect to. .env SQL_SERVER, else
  'tcp:localhost,1433'.

.PARAMETER DbUsername
  mssql only: SQL login. .env ADMIN_APP_DB_USER, else 'edfi_adminapp'.

.PARAMETER DbPassword
  mssql only: password for -DbUsername; prompted for (masked) when neither the
  parameter nor .env ADMIN_APP_DB_PASSWORD is set. Passed to sqlcmd through
  the SQLCMDPASSWORD environment variable, never on a command line.

.PARAMETER UseIntegratedSecurity
  mssql only: connect with Windows integrated authentication instead of
  -DbUsername/-DbPassword. .env USE_INTEGRATED_SECURITY.

.PARAMETER PostgresAppPassword
  pgsql only: password for -PostgresAppUser; prompted for (masked) when
  neither the parameter nor .env POSTGRES_APP_PASSWORD is set. Passed to psql
  through the PGPASSWORD environment variable, never on a command line.

.PARAMETER PostgresHost
  pgsql only: PostgreSQL host. .env POSTGRES_HOST, else 'localhost'.

.PARAMETER PostgresPort
  pgsql only: PostgreSQL port. .env POSTGRES_PORT, else 5432.

.PARAMETER PostgresAppUser
  pgsql only: PostgreSQL login. .env POSTGRES_APP_USER, else 'edfiadminapp'.

.PARAMETER UsePostgresDocker
  pgsql only: run psql inside the Admin App Docker stack's database container
  instead of a host psql. .env USE_POSTGRES_DOCKER.

.PARAMETER PostgresContainerName
  pgsql only: the Docker database container name. .env POSTGRES_CONTAINER,
  else 'edfiadminapp-postgres'.

.EXAMPLE
  ./cleanup-edorgs.ps1

.EXAMPLE
  # Show what would be deleted without touching anything:
  ./cleanup-edorgs.ps1 -WhatIf

.EXAMPLE
  # Unattended run (skips the confirmation prompt):
  ./cleanup-edorgs.ps1 -Confirm:$false

.EXAMPLE
  ./cleanup-edorgs.ps1 -CsvPath ./edorgs.csv -DbPassword '...' -OdsDbName 'EdFi_Ods_2026'
#>
#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # Path to the .env file used for defaults (copy .env.example and edit it).
    [string]$EnvFile = "$PSScriptRoot/.env",
    # Victim list. Default: the imported-ids.csv manifest import-edorgs.ps1
    # writes next to its CSV (only rows the import inserted are deleted).
    # Pass explicitly to delete every listed id instead (raw CSV mode).
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

# Without an explicit -CsvPath the victims come from the imported-ids.csv
# manifest import-edorgs.ps1 writes next to its CSV (CSV_PATH from the .env,
# or this folder). CSV_PATH itself is deliberately NOT used as a victim list:
# it names the export CSV, which can list rows the Admin App created itself.
$explicitCsvPath = $PSBoundParameters.ContainsKey('CsvPath') -and $CsvPath
if (-not $explicitCsvPath)
{
    $importCsv = Get-EnvValue 'CSV_PATH' "$PSScriptRoot/edorgs.csv"
    $CsvPath = Join-Path (Split-Path -Parent $importCsv) 'imported-ids.csv'
}
if (-not $TenantName) { $TenantName = Get-EnvValue 'TENANT_NAME' 'default' }
if (-not $EnvironmentName) { $EnvironmentName = Get-EnvValue 'ENVIRONMENT_NAME' }
if (-not $OdsDbName) { $OdsDbName = Get-EnvValue 'ODS_DB_NAME' (Get-EnvValue 'ODS_DATABASE_NAME') }
if (-not $DbEngine) { $DbEngine = Get-EnvValue 'DB_ENGINE' 'mssql' }
if (-not $DatabaseName) { $DatabaseName = Get-EnvValue 'DATABASE_NAME' 'sbaa' }
if (-not $SqlServer) { $SqlServer = Get-EnvValue 'SQL_SERVER' 'tcp:localhost,1433' }
if (-not $DbUsername) { $DbUsername = Get-EnvValue 'ADMIN_APP_DB_USER' 'edfi_adminapp' }
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
if (-not (Test-Path $CsvPath))
{
    if ($explicitCsvPath) { throw "CSV not found: $CsvPath." }
    Write-Host "Nothing to do: no import manifest at $CsvPath (import-edorgs.ps1 writes it when it inserts rows)." -ForegroundColor Yellow
    Write-Host "To delete ids from an arbitrary CSV instead, pass -CsvPath explicitly." -ForegroundColor Yellow
    return
}

if ($DbEngine -eq 'mssql')
{
    # The @(...) wrap is load-bearing: assignment from an if-expression unrolls
    # a one-element array to a scalar string, and splatting a scalar to a
    # native command garbles the argument list. The password travels via
    # SQLCMDPASSWORD (set around each call), never as -P, so it stays off
    # the sqlcmd process command line (visible in the process list).
    $authArgs = @(if ($UseIntegratedSecurity) { '-E' } else { '-U', $DbUsername })
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
            if (-not $UseIntegratedSecurity) { $env:SQLCMDPASSWORD = $DbPassword }
            $out = & sqlcmd -S $SqlServer @authArgs -d $DatabaseName -b -h -1 -W -s '|' -i $tempFile
            if ($LASTEXITCODE -ne 0)
            {
                $out | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
                throw "sqlcmd failed (exit $LASTEXITCODE). $FailHint"
            }
            return $out
        }
        finally
        {
            # -WhatIf:$false -Confirm:$false: housekeeping must always run --
            # the script's own SupportsShouldProcess would otherwise propagate
            # -WhatIf here and leave the password in the environment.
            Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
        }
    }

    # Pass the password through the environment, never on the command line:
    # `docker exec -e PGPASSWORD` (no value) forwards it from this process, so
    # the secret stays out of the docker argv; cleared in the finally.
    $env:PGPASSWORD = $PostgresAppPassword
    try
    {
        if ($UsePostgresDocker)
        {
            $out = $Sql | & docker exec -i -e PGPASSWORD $PostgresContainerName psql -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1 -t -A -F '|'
        }
        else
        {
            $out = $Sql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1 -t -A -F '|'
        }
    }
    finally
    {
        # Always runs (see the SQLCMDPASSWORD note above).
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
    if ($LASTEXITCODE -ne 0)
    {
        $out | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "psql failed (exit $LASTEXITCODE). $FailHint"
    }
    return $out
}

# ---- Step 1: the victim list --------------------------------------------------
$victimCsv = @(Import-Csv -Path $CsvPath -Encoding UTF8)
# A manifest row carries the tenant/ods scope the import inserted into; a raw
# CSV (explicit -CsvPath) has no scope columns and no record of what this
# tooling inserted, so every listed id becomes a victim.
$isManifest = ($victimCsv.Count -gt 0 -and
    'tenantId' -in $victimCsv[0].PSObject.Properties.Name -and
    'odsId' -in $victimCsv[0].PSObject.Properties.Name)
if (-not $isManifest)
{
    Write-Host "WARNING: $CsvPath is not an import manifest. Every listed id in the scope will be deleted, including rows the Admin App created itself (e.g. at ODS registration)." -ForegroundColor Yellow
}

# ---- Step 2: resolve the tenant / ODS scope (same rules as import) -----------
$tenantNameSql = $TenantName.Replace("'", "''")
$envNameSql = $EnvironmentName.Replace("'", "''")
$odsDbNameSql = $OdsDbName.Replace("'", "''")

# The scope row comes back as ONE concatenated column with a multi-character
# delimiter, so an environment or ODS name that itself contains '|' (the
# sqlcmd/psql field separator) cannot shift the fields.
$scopeDelim = '|~|'
if ($DbEngine -eq 'mssql')
{
    $envFilter = if ($EnvironmentName) { "AND e.[name] = N'$envNameSql'" } else { '' }
    $odsFilter = if ($OdsDbName) { "AND o.[dbName] = N'$odsDbNameSql'" } else { '' }
    $scopeSql = @"
SET NOCOUNT ON;
SELECT CONCAT(t.[id], '$scopeDelim', o.[id], '$scopeDelim', o.[dbName], '$scopeDelim', e.[name])
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
SELECT CONCAT(t.id, '$scopeDelim', o.id, '$scopeDelim', o."dbName", '$scopeDelim', e.name)
FROM edfi_tenant t
    JOIN sb_environment e ON e.id = t."sbEnvironmentId"
    JOIN ods o ON o."edfiTenantId" = t.id
WHERE t.name = '$tenantNameSql'
    $envFilter
    $odsFilter;
"@
}

$scopeRows = @(Invoke-AdminAppSql -Sql $scopeSql -FailHint 'Check the connection parameters and -DatabaseName.' |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_.Contains($scopeDelim) })
if ($scopeRows.Count -eq 0)
{
    Write-Host "Nothing to do: no registered ODS found for tenant '$TenantName'$(if ($OdsDbName) { " with dbName '$OdsDbName'" })." -ForegroundColor Yellow
    return
}
if ($scopeRows.Count -gt 1)
{
    $candidates = ($scopeRows | ForEach-Object { $p = $_ -split [regex]::Escape($scopeDelim); "environment '$($p[3])' / ods dbName '$($p[2])'" }) -join '; '
    throw "Tenant '$TenantName' matches more than one scope: $candidates. Disambiguate with -OdsDbName (and -EnvironmentName if needed)."
}
$parts = $scopeRows[0] -split [regex]::Escape($scopeDelim)
$tenantId = [int]$parts[0]
$odsId = [int]$parts[1]
Write-Host "  Scope: tenant id $tenantId, ODS '$($parts[2])' (id $odsId)."

# The ids to delete. Manifest mode: only the ids the import inserted into THIS
# scope; other scopes' entries stay in the manifest for their own cleanup.
if ($isManifest)
{
    $ids = @($victimCsv | Where-Object { "$($_.tenantId)" -eq "$tenantId" -and "$($_.odsId)" -eq "$odsId" } |
            ForEach-Object { "$($_.educationOrganizationId)".Trim() } | Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique)
    if ($ids.Count -eq 0)
    {
        Write-Host "Nothing to do: the manifest has no entries for this scope (nothing was imported, or it was already cleaned up)." -ForegroundColor Yellow
        return
    }
}
else
{
    $ids = @($victimCsv | ForEach-Object { "$($_.educationOrganizationId)".Trim() } |
            Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique)
    if ($ids.Count -eq 0) { throw "No educationOrganizationId values found in $CsvPath." }
}
Write-Host "Deleting up to $($ids.Count) education organizations listed in $CsvPath..."

# -WhatIf reports the intent and stops here; the default interactive run asks
# for confirmation first (ConfirmImpact High). Pass -Confirm:$false to skip
# the prompt in unattended runs.
if (-not $PSCmdlet.ShouldProcess("tenant '$TenantName', ODS '$($parts[2])' in $DbEngine db '$DatabaseName'", "Delete $($ids.Count) education organization(s) and their team-access rows"))
{
    return
}

# ---- Step 3: delete -----------------------------------------------------------
# Order of operations, all in one transaction:
#   1. stage the victim ids (batched inserts: one flat IN (...) list hits SQL
#      Server's expression-services limit, Msg 8632, around 40k ids);
#   2. report and delete the team-access (ownership) rows referencing victims
#      -- the ownership -> edorg foreign key is ON DELETE NO ACTION on both
#      engines and would block the delete;
#   3. re-root surviving children (parentId = NULL) so the self-referencing
#      foreign key never blocks the delete, and remove the closure pairs that
#      link their subtrees to surviving ancestors -- the schema's own cascade
#      (foreign keys on PostgreSQL, the closure trigger on SQL Server) only
#      removes pairs touching a DELETED row, and would leave those behind;
#   4. delete the victims.
function Get-VictimIdBatches
{
    $batchSize = 500
    $batches = @()
    for ($i = 0; $i -lt $ids.Count; $i += $batchSize)
    {
        $batches += (($ids[$i..([Math]::Min($i + $batchSize, $ids.Count) - 1)] | ForEach-Object { "($_)" }) -join ",`n")
    }
    return $batches
}

if ($DbEngine -eq 'mssql')
{
    $victimInserts = (Get-VictimIdBatches | ForEach-Object { "INSERT INTO #victim_ids (edOrgId) VALUES`n$_;" }) -join "`n"
    $sql = @"
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
SET NOCOUNT ON;

CREATE TABLE #victim_ids (edOrgId bigint NOT NULL PRIMARY KEY);
$victimInserts

BEGIN TRANSACTION;

SELECT e.[id] INTO #victims
FROM [edorg] e
WHERE e.[edfiTenantId] = $tenantId AND e.[odsId] = $odsId
    AND e.[educationOrganizationId] IN (SELECT edOrgId FROM #victim_ids);

SELECT CONCAT('OWNERSHIP$scopeDelim', COALESCE(t.[name], '(unknown team)'), '$scopeDelim', e.[educationOrganizationId], '$scopeDelim', e.[nameOfInstitution])
FROM [ownership] o
    INNER JOIN #victims v ON v.[id] = o.[edorgId]
    INNER JOIN [edorg] e ON e.[id] = o.[edorgId]
    LEFT JOIN [team] t ON t.[id] = o.[teamId]
ORDER BY 1;

DECLARE @ownershipCount int;
DELETE FROM [ownership] WHERE [edorgId] IN (SELECT [id] FROM #victims);
SET @ownershipCount = @@ROWCOUNT;
IF @ownershipCount > 0 PRINT CONCAT('Removed ', @ownershipCount, ' team-access (ownership) row(s) that referenced deleted ed orgs.');

-- Surviving children, captured before the re-root so their subtrees' stale
-- closure pairs can be computed while parentId and the closure rows are intact.
SELECT e.[id] INTO #rerooted
FROM [edorg] e
WHERE e.[parentId] IN (SELECT [id] FROM #victims)
    AND e.[id] NOT IN (SELECT [id] FROM #victims);

UPDATE [edorg] SET [parentId] = NULL
WHERE [id] IN (SELECT [id] FROM #rerooted);

SELECT c.[id_descendant] AS [id] INTO #rerooted_subtree
FROM [edorg_closure] c
WHERE c.[id_ancestor] IN (SELECT [id] FROM #rerooted);

DELETE FROM [edorg_closure]
WHERE [id_descendant] IN (SELECT [id] FROM #rerooted_subtree)
    AND [id_ancestor] NOT IN (SELECT [id] FROM #rerooted_subtree);

DELETE FROM [edorg] WHERE [id] IN (SELECT [id] FROM #victims);
PRINT CONCAT('Deleted ', @@ROWCOUNT, ' edorg row(s).');

COMMIT TRANSACTION;
"@
}
else
{
    $victimInserts = (Get-VictimIdBatches | ForEach-Object { "INSERT INTO victim_ids (edorgid) VALUES`n$_;" }) -join "`n"
    $sql = @"
BEGIN;

CREATE TEMP TABLE victim_ids (edorgid bigint NOT NULL PRIMARY KEY) ON COMMIT DROP;
$victimInserts

CREATE TEMP TABLE victims ON COMMIT DROP AS
SELECT e.id
FROM edorg e
WHERE e."edfiTenantId" = $tenantId AND e."odsId" = $odsId
    AND e."educationOrganizationId" IN (SELECT edorgid FROM victim_ids);

SELECT CONCAT('OWNERSHIP$scopeDelim', COALESCE(t.name, '(unknown team)'), '$scopeDelim', e."educationOrganizationId", '$scopeDelim', e."nameOfInstitution")
FROM ownership o
    JOIN victims v ON v.id = o."edorgId"
    JOIN edorg e ON e.id = o."edorgId"
    LEFT JOIN team t ON t.id = o."teamId"
ORDER BY 1;

CREATE TEMP TABLE victim_ownerships ON COMMIT DROP AS
SELECT o.id FROM ownership o JOIN victims v ON v.id = o."edorgId";
DELETE FROM ownership WHERE id IN (SELECT id FROM victim_ownerships);
SELECT CONCAT('MSG|Removed ', COUNT(*), ' team-access (ownership) row(s) that referenced deleted ed orgs.')
FROM victim_ownerships HAVING COUNT(*) > 0;

-- Surviving children, captured before the re-root so their subtrees' stale
-- closure pairs can be computed while parentId and the closure rows are intact.
CREATE TEMP TABLE rerooted ON COMMIT DROP AS
SELECT e.id
FROM edorg e
WHERE e."parentId" IN (SELECT id FROM victims)
    AND e.id NOT IN (SELECT id FROM victims);

UPDATE edorg SET "parentId" = NULL
WHERE id IN (SELECT id FROM rerooted);

CREATE TEMP TABLE rerooted_subtree ON COMMIT DROP AS
SELECT c.id_descendant AS id
FROM edorg_closure c
WHERE c.id_ancestor IN (SELECT id FROM rerooted);

DELETE FROM edorg_closure
WHERE id_descendant IN (SELECT id FROM rerooted_subtree)
    AND id_ancestor NOT IN (SELECT id FROM rerooted_subtree);

DELETE FROM edorg WHERE id IN (SELECT id FROM victims);
SELECT CONCAT('MSG|Deleted ', COUNT(*), ' edorg row(s).') FROM victims;

COMMIT;
"@
}

$output = Invoke-AdminAppSql -Sql $sql -FailHint 'Nothing was deleted (the cleanup is transactional).'
$owned = @($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -like "OWNERSHIP$scopeDelim*" })
if ($owned.Count -gt 0)
{
    Write-Host "WARNING: team access was removed for $($owned.Count) grant(s) (grant it again in Admin App > team access if re-importing):" -ForegroundColor Yellow
    $owned | ForEach-Object { $p = $_ -split [regex]::Escape($scopeDelim); Write-Host "  team '$($p[1])' lost access to $($p[3]) ($($p[2]))" -ForegroundColor Yellow }
}
$output | Where-Object { "$_".Trim() -and "$_" -match '^(MSG\|)?(Deleted|Removed)' } |
    ForEach-Object { Write-Host "  $("$_" -replace '^MSG\|', '')" }

# Manifest mode: this scope's entries are consumed; other scopes keep theirs.
if ($isManifest)
{
    $deletedIds = [System.Collections.Generic.HashSet[string]]::new([string[]]$ids)
    $remaining = @($victimCsv | Where-Object {
            -not ("$($_.tenantId)" -eq "$tenantId" -and "$($_.odsId)" -eq "$odsId" -and
                $deletedIds.Contains("$($_.educationOrganizationId)".Trim()))
        })
    if ($remaining.Count -gt 0)
    {
        $remaining | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
        Write-Host "  Manifest updated: $($remaining.Count) entry(ies) for other scopes kept in $CsvPath."
    }
    else
    {
        # Part of the operation the user already confirmed via ShouldProcess.
        Remove-Item -Path $CsvPath -Force -WhatIf:$false -Confirm:$false
        Write-Host "  Manifest removed: $CsvPath (all entries consumed)."
    }
}

Write-Host "`nSUCCESS: cleanup complete (re-runs are no-ops)." -ForegroundColor Green
Write-Host "Re-import at any time with ./import-edorgs.ps1." -ForegroundColor Green
