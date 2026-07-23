<#
.SYNOPSIS
  Tears down everything the quick start created in the Admin App application
  database: the environment (with its ownership, ODS instances, Ed-Orgs, and
  tenant), the team and its memberships, and the machine user seeded by
  bootstrap.ps1 -- plus the claimset copies made by copy-claimsets.ps1 in the
  EdFi_Security database. The human bootstrap user is left in place.

.DESCRIPTION
  Runs against the Admin App application database (default "sbaa") -- NOT
  EdFi_Admin or an ODS database. Defaults are read from the .env file next to
  this script when present; any parameter passed explicitly wins.

  Deletes, in order: ownership rows (by environment / tenant / ods / edorg /
  team), edorg, ods, edfi_tenant, sb_environment, user_team_membership, team,
  and finally the machine user (guarded by userType = 'machine').

  Then removes the claimset copies made by copy-claimsets.ps1 from the
  EdFi_Security database: every non-preset claimset starting with the prefix
  (default 'AA ') or, when -ClaimSetNames / CLAIMSET_NAMES is set, only those
  prefixed names. EdFi_Security is a different database (ODS/API side), so the
  mssql connection uses its own SECURITY_DB_USERNAME / SECURITY_DB_PASSWORD
  login (or SECURITY_USE_INTEGRATED_SECURITY=true); pgsql reuses POSTGRES_*.
  Only non-preset claimsets are ever deleted, so the built-in originals are
  safe. Skip this phase with -SkipClaimsets (or COPY_CLAIMSETS=false in .env)
  -- for example when EdFi_Security is not reachable from this machine, or when
  an application still uses a copy (delete that application first).

.EXAMPLE
  # Interactive: shows what will be deleted and asks for confirmation.
  ./cleanup.ps1

.EXAMPLE
  # Non-interactive (automation): skip the confirmation prompt.
  ./cleanup.ps1 -Force

.EXAMPLE
  # Override .env values per-parameter:
  ./cleanup.ps1 -DbEngine pgsql -PostgresAppPassword 'edfi' -EnvironmentName 'Ed-Fi ODS/API v7.3'

.EXAMPLE
  # Leave the claimset copies in place:
  ./cleanup.ps1 -SkipClaimsets
#>
#requires -Version 5.1
param(
    # Path to the .env file supplying defaults (optional).
    [string]$EnvFile = "$PSScriptRoot/.env",

    # Database connection (mirrors bootstrap.ps1). For mssql this is the
    # least-privilege app login created by windows-install/install-all.ps1;
    # 'sa' is deliberately not used (EDFI-2776).
    [ValidateSet('mssql', 'pgsql')][string]$DbEngine,
    [string]$DatabaseName,
    [string]$AppDbUsername,
    [string]$AppDbPassword,
    [string]$PostgresAppPassword,
    [string]$PostgresHost,
    [int]$PostgresPort,
    [string]$PostgresAppUser,
    [switch]$UsePostgresDocker,

    # What to delete (must match what the quick start created).
    [string]$EnvironmentName,
    [string]$TeamName,
    [string]$MachineUsername,

    # Claimset copies to remove from EdFi_Security (mirrors copy-claimsets.ps1).
    # Empty (the default) = every non-preset claimset starting with the prefix.
    [string[]]$ClaimSetNames,
    [string]$ClaimSetPrefix,
    [string]$SecuritySqlServer,
    # EdFi_Security is a different database (ODS/API side), so it has its own
    # mssql login -- the app login above is scoped to the Admin App database.
    # Not needed when SECURITY_USE_INTEGRATED_SECURITY=true.
    [string]$SecurityDbUsername,
    [string]$SecurityDbPassword,
    # Skip removing the claimset copies from EdFi_Security.
    [switch]$SkipClaimsets,

    # Skip the confirmation prompt.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/load-dotenv.ps1"
. "$PSScriptRoot/compat.ps1"

$script:dotenv = @{}
if (Test-Path $EnvFile) { $script:dotenv = Read-DotEnv -Path $EnvFile }

function Get-EnvValue
{
    param([string]$Name, [string]$Default = '')
    if ($script:dotenv.ContainsKey($Name) -and $script:dotenv[$Name] -ne '') { return $script:dotenv[$Name] }
    return $Default
}

# Explicit parameters win; otherwise fall back to .env, then to the defaults.
if (-not $PSBoundParameters.ContainsKey('DbEngine')) { $DbEngine = Get-EnvValue 'DB_ENGINE' 'mssql' }
if (-not $PSBoundParameters.ContainsKey('DatabaseName')) { $DatabaseName = Get-EnvValue 'DATABASE_NAME' 'sbaa' }
if (-not $PSBoundParameters.ContainsKey('AppDbUsername')) { $AppDbUsername = Get-EnvValue 'APP_DB_USERNAME' 'edfi_adminapp' }
if (-not $PSBoundParameters.ContainsKey('AppDbPassword')) { $AppDbPassword = Get-EnvValue 'APP_DB_PASSWORD' }
if (-not $PSBoundParameters.ContainsKey('PostgresAppPassword')) { $PostgresAppPassword = Get-EnvValue 'POSTGRES_APP_PASSWORD' }
if (-not $PSBoundParameters.ContainsKey('PostgresHost')) { $PostgresHost = Get-EnvValue 'POSTGRES_HOST' 'localhost' }
if (-not $PSBoundParameters.ContainsKey('PostgresPort')) { $PostgresPort = [int](Get-EnvValue 'POSTGRES_PORT' '5432') }
if (-not $PSBoundParameters.ContainsKey('PostgresAppUser')) { $PostgresAppUser = Get-EnvValue 'POSTGRES_APP_USER' 'edfiadminapp' }
if (-not $PSBoundParameters.ContainsKey('UsePostgresDocker')) { $UsePostgresDocker = (Get-EnvValue 'USE_POSTGRES_DOCKER') -in @('true', 'True', 'TRUE', '1', 'yes') }
if (-not $PSBoundParameters.ContainsKey('EnvironmentName')) { $EnvironmentName = Get-EnvValue 'ENVIRONMENT_NAME' 'Ed-Fi ODS/API v7.3' }
if (-not $PSBoundParameters.ContainsKey('TeamName')) { $TeamName = Get-EnvValue 'TEAM_NAME' 'Quick Start' }
if (-not $PSBoundParameters.ContainsKey('MachineUsername')) { $MachineUsername = Get-EnvValue 'MACHINE_USERNAME' 'quick-start-machine' }

# Claimset-copy removal (mssql uses the SECURITY_DB_* login; pgsql reuses PostgresApp*, like run.ps1).
$removeClaimsets = -not $SkipClaimsets -and (Get-EnvValue 'COPY_CLAIMSETS' 'true') -in @('true', 'True', 'TRUE', '1', 'yes')
if (-not $PSBoundParameters.ContainsKey('ClaimSetNames'))
{
    $ClaimSetNames = @((Get-EnvValue 'CLAIMSET_NAMES') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $PSBoundParameters.ContainsKey('ClaimSetPrefix')) { $ClaimSetPrefix = Get-EnvValue 'CLAIMSET_PREFIX' 'AA ' }
if (-not $PSBoundParameters.ContainsKey('SecuritySqlServer')) { $SecuritySqlServer = Get-EnvValue 'SECURITY_SQL_SERVER' 'tcp:localhost,1433' }
if (-not $PSBoundParameters.ContainsKey('SecurityDbUsername')) { $SecurityDbUsername = Get-EnvValue 'SECURITY_DB_USERNAME' }
if (-not $PSBoundParameters.ContainsKey('SecurityDbPassword')) { $SecurityDbPassword = Get-EnvValue 'SECURITY_DB_PASSWORD' }
$securityDatabaseName = Get-EnvValue 'SECURITY_DATABASE_NAME' 'EdFi_Security'
$securityUseIntegratedSecurity = (Get-EnvValue 'SECURITY_USE_INTEGRATED_SECURITY') -in @('true', 'True', 'TRUE', '1', 'yes')
$securityPostgresContainer = Get-EnvValue 'SECURITY_POSTGRES_CONTAINER' 'ed-fi-db-admin'
$claimsetTargets = @($ClaimSetNames | ForEach-Object { "$ClaimSetPrefix$_" })
$claimsetSkipReason = if ($SkipClaimsets) { '-SkipClaimsets' } else { 'COPY_CLAIMSETS=false' }
# No names = remove every non-preset claimset starting with the prefix -- but
# never with an empty prefix, which would match every custom claimset.
if ($claimsetTargets.Count -eq 0 -and -not $ClaimSetPrefix)
{
    $removeClaimsets = $false
    $claimsetSkipReason = 'no claimset names and an empty prefix'
}

if ($DbEngine -eq 'mssql' -and -not $AppDbPassword) { throw "-AppDbPassword (or APP_DB_PASSWORD in .env) is required when the engine is 'mssql'." }
if ($removeClaimsets -and $DbEngine -eq 'mssql' -and -not $securityUseIntegratedSecurity -and (-not $SecurityDbUsername -or -not $SecurityDbPassword)) { throw "-SecurityDbUsername and -SecurityDbPassword (or SECURITY_DB_USERNAME / SECURITY_DB_PASSWORD in .env; a login with rights on EdFi_Security) are required to remove the claimset copies, or set SECURITY_USE_INTEGRATED_SECURITY=true, or skip with -SkipClaimsets." }
if ($DbEngine -eq 'pgsql' -and -not $PostgresAppPassword) { throw "-PostgresAppPassword (or POSTGRES_APP_PASSWORD in .env) is required when the engine is 'pgsql'." }
if ($UsePostgresDocker -and $DbEngine -ne 'pgsql') { throw "-UsePostgresDocker only applies when the engine is 'pgsql'." }

Write-Host "About to delete from the '$DatabaseName' ($DbEngine) Admin App database:" -ForegroundColor Yellow
Write-Host "  * environment '$EnvironmentName' (with its ownership, ODS instances, Ed-Orgs, and tenants)"
Write-Host "  * team '$TeamName' (with its memberships and ownerships)"
Write-Host "  * machine user '$MachineUsername'"
if ($removeClaimsets)
{
    Write-Host "And from the '$securityDatabaseName' database:" -ForegroundColor Yellow
    $targetDisplay = if ($claimsetTargets.Count -gt 0) { $claimsetTargets -join ', ' } else { "every claimset copy starting with '$ClaimSetPrefix'" }
    Write-Host "  * claimset copies: $targetDisplay (make sure no application still uses them)"
}
Write-Host "The human bootstrap user is NOT touched."
if (-not $Force)
{
    $answer = Read-Host "Type 'yes' to continue"
    if ($answer -ne 'yes') { Write-Host "Aborted."; exit 1 }
}

# Escape single quotes for safe embedding in the SQL literals.
$envName = $EnvironmentName.Replace("'", "''")
$teamNameSql = $TeamName.Replace("'", "''")
$machineUser = $MachineUsername.Replace("'", "''")

if ($DbEngine -eq 'mssql')
{
    # QUOTED_IDENTIFIER must be ON for writes to [user] (it has a filtered
    # unique index on clientId); sqlcmd defaults it OFF.
    $cleanupSql = @"
SET QUOTED_IDENTIFIER ON;

DELETE FROM [ownership]
 WHERE [sbEnvironmentId] IN (SELECT [id] FROM [sb_environment] WHERE [name] = N'$envName')
    OR [edfiTenantId] IN (SELECT [id] FROM [edfi_tenant]
        WHERE [sbEnvironmentId] IN (SELECT [id] FROM [sb_environment] WHERE [name] = N'$envName'))
    OR [odsId] IN (SELECT [id] FROM [ods]
        WHERE [sbEnvironmentId] IN (SELECT [id] FROM [sb_environment] WHERE [name] = N'$envName'))
    OR [edorgId] IN (SELECT [id] FROM [edorg]
        WHERE [sbEnvironmentId] IN (SELECT [id] FROM [sb_environment] WHERE [name] = N'$envName'))
    OR [teamId] IN (SELECT [id] FROM [team] WHERE [name] = N'$teamNameSql');
DELETE FROM [edorg]
 WHERE [sbEnvironmentId] IN (SELECT [id] FROM [sb_environment] WHERE [name] = N'$envName');
DELETE FROM [ods]
 WHERE [sbEnvironmentId] IN (SELECT [id] FROM [sb_environment] WHERE [name] = N'$envName');
DELETE FROM [edfi_tenant]
 WHERE [sbEnvironmentId] IN (SELECT [id] FROM [sb_environment] WHERE [name] = N'$envName');
DELETE FROM [sb_environment] WHERE [name] = N'$envName';
DELETE FROM [user_team_membership]
 WHERE [teamId] IN (SELECT [id] FROM [team] WHERE [name] = N'$teamNameSql');
DELETE FROM [team] WHERE [name] = N'$teamNameSql';
DELETE FROM [user]
 WHERE [username] = N'$machineUser' AND [userType] = N'machine';
"@
    & sqlcmd -S "tcp:localhost,1433" -U $AppDbUsername -P $AppDbPassword -d $DatabaseName -Q $cleanupSql
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE) as login '$AppDbUsername'. Check -AppDbUsername / -AppDbPassword / -DatabaseName." }
}
else
{
    # "user" is a reserved word and the camelCase columns are case-sensitive, so
    # everything stays double-quoted; pipe via stdin so the quotes survive.
    $cleanupSql = @"
DELETE FROM ownership
 WHERE "sbEnvironmentId" IN (SELECT id FROM sb_environment WHERE name = '$envName')
    OR "edfiTenantId" IN (SELECT id FROM edfi_tenant
        WHERE "sbEnvironmentId" IN (SELECT id FROM sb_environment WHERE name = '$envName'))
    OR "odsId" IN (SELECT id FROM ods
        WHERE "sbEnvironmentId" IN (SELECT id FROM sb_environment WHERE name = '$envName'))
    OR "edorgId" IN (SELECT id FROM edorg
        WHERE "sbEnvironmentId" IN (SELECT id FROM sb_environment WHERE name = '$envName'))
    OR "teamId" IN (SELECT id FROM team WHERE name = '$teamNameSql');
DELETE FROM edorg
 WHERE "sbEnvironmentId" IN (SELECT id FROM sb_environment WHERE name = '$envName');
DELETE FROM ods
 WHERE "sbEnvironmentId" IN (SELECT id FROM sb_environment WHERE name = '$envName');
DELETE FROM edfi_tenant
 WHERE "sbEnvironmentId" IN (SELECT id FROM sb_environment WHERE name = '$envName');
DELETE FROM sb_environment WHERE name = '$envName';
DELETE FROM user_team_membership
 WHERE "teamId" IN (SELECT id FROM team WHERE name = '$teamNameSql');
DELETE FROM team WHERE name = '$teamNameSql';
DELETE FROM "user"
 WHERE username = '$machineUser' AND "userType" = 'machine';
"@
    if ($UsePostgresDocker)
    {
        $cleanupSql | & docker exec -i -e "PGPASSWORD=$PostgresAppPassword" edfiadminapp-postgres psql -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1
    }
    else
    {
        $env:PGPASSWORD = $PostgresAppPassword
        $cleanupSql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1
    }
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE). Check -PostgresAppPassword / -PostgresHost / -PostgresPort / -PostgresAppUser / -DatabaseName." }
}

# ---- Claimset copies (EdFi_Security) ------------------------------------------
if (-not $removeClaimsets)
{
    Write-Host "Skipping claimset-copy removal ($claimsetSkipReason)." -ForegroundColor Yellow
}
elseif ($DbEngine -eq 'mssql')
{
    # IsEdfiPreset = 0 guards the built-in originals even if the prefix is
    # misconfigured; delete order is child tables first (see copy-claimsets.ps1).
    if ($claimsetTargets.Count -gt 0)
    {
        $targetList = ($claimsetTargets | ForEach-Object { "N'" + $_.Replace("'", "''") + "'" }) -join ', '
        $claimsetFilter = "cs.ClaimSetName IN ($targetList)"
    }
    else
    {
        # Escape LIKE wildcards in the prefix, then quote it for the literal.
        $prefixLike = $ClaimSetPrefix.Replace('\', '\\').Replace('%', '\%').Replace('_', '\_').Replace('[', '\[').Replace("'", "''")
        $claimsetFilter = "cs.ClaimSetName LIKE N'$prefixLike%' ESCAPE '\'"
    }
    $claimsetSql = @"
DELETE ov
FROM dbo.ClaimSetResourceClaimActionAuthorizationStrategyOverrides ov
    INNER JOIN dbo.ClaimSetResourceClaimActions a
        ON a.ClaimSetResourceClaimActionId = ov.ClaimSetResourceClaimActionId
    INNER JOIN dbo.ClaimSets cs ON cs.ClaimSetId = a.ClaimSetId
WHERE $claimsetFilter AND cs.IsEdfiPreset = 0;
DELETE a
FROM dbo.ClaimSetResourceClaimActions a
    INNER JOIN dbo.ClaimSets cs ON cs.ClaimSetId = a.ClaimSetId
WHERE $claimsetFilter AND cs.IsEdfiPreset = 0;
DELETE cs
FROM dbo.ClaimSets cs
WHERE $claimsetFilter AND cs.IsEdfiPreset = 0;
"@
    # @(...) wrap is load-bearing: a one-element if-expression result is a scalar
    # string, and splatting a scalar garbles the native argument list.
    $secAuthArgs = @(if ($securityUseIntegratedSecurity) { '-E' } else { '-U', $SecurityDbUsername, '-P', $SecurityDbPassword })
    # Count first so the outcome is honest: a blanket "removed" message when
    # nothing matched reads as a successful delete of copies that were never there.
    $countSql = "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.ClaimSets cs WHERE $claimsetFilter AND cs.IsEdfiPreset = 0;"
    $matched = @(& sqlcmd -S $SecuritySqlServer @secAuthArgs -d $securityDatabaseName -b -h -1 -W -Q $countSql | Where-Object { "$_".Trim() })[0]
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed counting the claimset copies (exit $LASTEXITCODE). Check -SecuritySqlServer / -SecurityDbUsername / -SecurityDbPassword / SECURITY_DATABASE_NAME." }
    if ([int]"$matched" -eq 0)
    {
        Write-Host "No claimset copies matched in '$securityDatabaseName' (nothing to remove -- were they created?)." -ForegroundColor Yellow
    }
    else
    {
        & sqlcmd -S $SecuritySqlServer @secAuthArgs -d $securityDatabaseName -b -Q $claimsetSql
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed removing the claimset copies (exit $LASTEXITCODE). Check -SecuritySqlServer / -SecurityDbUsername / -SecurityDbPassword / SECURITY_DATABASE_NAME." }
        Write-Host "Removed $matched claimset copies from '$securityDatabaseName'." -ForegroundColor Green
    }
}
else
{
    if ($claimsetTargets.Count -gt 0)
    {
        $targetList = ($claimsetTargets | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
        $claimsetFilter = "cs.claimsetname IN ($targetList)"
    }
    else
    {
        $prefixLike = $ClaimSetPrefix.Replace('\', '\\').Replace('%', '\%').Replace('_', '\_').Replace("'", "''")
        $claimsetFilter = "cs.claimsetname LIKE '$prefixLike%'"
    }
    $claimsetSql = @"
DELETE FROM dbo.claimsetresourceclaimactionauthorizationstrategyoverrides ov
USING dbo.claimsetresourceclaimactions a, dbo.claimsets cs
WHERE ov.claimsetresourceclaimactionid = a.claimsetresourceclaimactionid
  AND a.claimsetid = cs.claimsetid
  AND $claimsetFilter AND cs.isedfipreset = FALSE;
DELETE FROM dbo.claimsetresourceclaimactions a
USING dbo.claimsets cs
WHERE a.claimsetid = cs.claimsetid
  AND $claimsetFilter AND cs.isedfipreset = FALSE;
DELETE FROM dbo.claimsets cs
WHERE $claimsetFilter AND cs.isedfipreset = FALSE;
"@
    # Count first so the outcome is honest (same reason as the mssql branch).
    $countSql = "SELECT COUNT(*) FROM dbo.claimsets cs WHERE $claimsetFilter AND cs.isedfipreset = FALSE;"
    if ($UsePostgresDocker)
    {
        $matched = "$($countSql | & docker exec -i -e "PGPASSWORD=$PostgresAppPassword" $securityPostgresContainer psql -U $PostgresAppUser -d $securityDatabaseName -v ON_ERROR_STOP=1 -t -A)".Trim()
    }
    else
    {
        $env:PGPASSWORD = $PostgresAppPassword
        $matched = "$($countSql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $securityDatabaseName -v ON_ERROR_STOP=1 -t -A)".Trim()
    }
    if ($LASTEXITCODE -ne 0) { throw "psql failed counting the claimset copies (exit $LASTEXITCODE). Check -PostgresAppPassword / -PostgresHost / -PostgresPort / -PostgresAppUser / SECURITY_DATABASE_NAME." }
    if ([int]$matched -eq 0)
    {
        Write-Host "No claimset copies matched in '$securityDatabaseName' (nothing to remove -- were they created?)." -ForegroundColor Yellow
    }
    else
    {
        if ($UsePostgresDocker)
        {
            $claimsetSql | & docker exec -i -e "PGPASSWORD=$PostgresAppPassword" $securityPostgresContainer psql -U $PostgresAppUser -d $securityDatabaseName -v ON_ERROR_STOP=1
        }
        else
        {
            $env:PGPASSWORD = $PostgresAppPassword
            $claimsetSql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $securityDatabaseName -v ON_ERROR_STOP=1
        }
        if ($LASTEXITCODE -ne 0) { throw "psql failed removing the claimset copies (exit $LASTEXITCODE). Check -PostgresAppPassword / -PostgresHost / -PostgresPort / -PostgresAppUser / SECURITY_DATABASE_NAME." }
        Write-Host "Removed $matched claimset copies from '$securityDatabaseName'." -ForegroundColor Green
    }
}

Write-Host "Cleanup complete." -ForegroundColor Green
