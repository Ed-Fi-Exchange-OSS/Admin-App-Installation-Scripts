#requires -Version 7.0
<#
.SYNOPSIS
  Tears down everything the quick start created in the Admin App application
  database: the environment (with its ownership, ODS instances, Ed-Orgs, and
  tenant), the team and its memberships, and the machine user seeded by
  bootstrap.ps1. The human bootstrap user is left in place.

.DESCRIPTION
  Runs against the Admin App application database (default "sbaa") -- NOT
  EdFi_Admin or an ODS database. Defaults are read from the .env file next to
  this script when present; any parameter passed explicitly wins.

  Deletes, in order: ownership rows (by environment / tenant / ods / edorg /
  team), edorg, ods, edfi_tenant, sb_environment, user_team_membership, team,
  and finally the machine user (guarded by userType = 'machine').

.EXAMPLE
  # Interactive: shows what will be deleted and asks for confirmation.
  ./cleanup.ps1

.EXAMPLE
  # Non-interactive (automation): skip the confirmation prompt.
  ./cleanup.ps1 -Force

.EXAMPLE
  # Override .env values per-parameter:
  ./cleanup.ps1 -DbEngine pgsql -PostgresAppPassword 'edfi' -EnvironmentName 'Ed-Fi ODS/API v7.3'
#>
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

    # Skip the confirmation prompt.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/load-dotenv.ps1"

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
if (-not $PSBoundParameters.ContainsKey('AppDbUsername')) { $AppDbUsername = Get-EnvValue 'APP_DB_USERNAME' 'edfiadminapp' }
if (-not $PSBoundParameters.ContainsKey('AppDbPassword')) { $AppDbPassword = Get-EnvValue 'APP_DB_PASSWORD' }
if (-not $PSBoundParameters.ContainsKey('PostgresAppPassword')) { $PostgresAppPassword = Get-EnvValue 'POSTGRES_APP_PASSWORD' }
if (-not $PSBoundParameters.ContainsKey('PostgresHost')) { $PostgresHost = Get-EnvValue 'POSTGRES_HOST' 'localhost' }
if (-not $PSBoundParameters.ContainsKey('PostgresPort')) { $PostgresPort = [int](Get-EnvValue 'POSTGRES_PORT' '5432') }
if (-not $PSBoundParameters.ContainsKey('PostgresAppUser')) { $PostgresAppUser = Get-EnvValue 'POSTGRES_APP_USER' 'edfiadminapp' }
if (-not $PSBoundParameters.ContainsKey('UsePostgresDocker')) { $UsePostgresDocker = (Get-EnvValue 'USE_POSTGRES_DOCKER') -in @('true', 'True', 'TRUE', '1', 'yes') }
if (-not $PSBoundParameters.ContainsKey('EnvironmentName')) { $EnvironmentName = Get-EnvValue 'ENVIRONMENT_NAME' 'Ed-Fi ODS/API v7.3' }
if (-not $PSBoundParameters.ContainsKey('TeamName')) { $TeamName = Get-EnvValue 'TEAM_NAME' 'Quick Start' }
if (-not $PSBoundParameters.ContainsKey('MachineUsername')) { $MachineUsername = Get-EnvValue 'MACHINE_USERNAME' 'quick-start-machine' }

if ($DbEngine -eq 'mssql' -and -not $AppDbPassword) { throw "-AppDbPassword (or APP_DB_PASSWORD in .env) is required when the engine is 'mssql'." }
if ($DbEngine -eq 'pgsql' -and -not $PostgresAppPassword) { throw "-PostgresAppPassword (or POSTGRES_APP_PASSWORD in .env) is required when the engine is 'pgsql'." }
if ($UsePostgresDocker -and $DbEngine -ne 'pgsql') { throw "-UsePostgresDocker only applies when the engine is 'pgsql'." }

Write-Host "About to delete from the '$DatabaseName' ($DbEngine) Admin App database:" -ForegroundColor Yellow
Write-Host "  * environment '$EnvironmentName' (with its ownership, ODS instances, Ed-Orgs, and tenants)"
Write-Host "  * team '$TeamName' (with its memberships and ownerships)"
Write-Host "  * machine user '$MachineUsername'"
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

Write-Host "Cleanup complete." -ForegroundColor Green
