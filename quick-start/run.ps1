<#
.SYNOPSIS
  One-step Global Admin Quick Start: loads .env and runs bootstrap.ps1,
  quick-start.ps1, and copy-claimsets.ps1.

.DESCRIPTION
  Copy .env.example to .env, edit the values to match your deployment, then run
  ./run.ps1. The variables map 1:1 onto the parameters of bootstrap.ps1 (IdP
  machine client + machine-user seed), quick-start.ps1 (team / environment /
  ODS provisioning through the Admin App API), and copy-claimsets.ps1
  (built-in claimset copies in the ODS/API's EdFi_Security database, so they
  can be assigned to applications). All the scripts are idempotent, so
  re-running is safe.

  The ODS instances in ODSS_JSON are NOT created by these scripts: their ids
  and names must match real rows in EdFi_Admin.dbo.OdsInstances on the target
  ODS/API. Check the table (and create any missing rows) before running --
  see 'Global Admin Quick Start' on docs.ed-fi.org.

.EXAMPLE
  ./run.ps1

.EXAMPLE
  # Machine client + machine user already in place; only provision the environment.
  ./run.ps1 -SkipBootstrap

.EXAMPLE
  # EdFi_Security not reachable from here (or copies already made).
  ./run.ps1 -SkipClaimsets

.EXAMPLE
  ./run.ps1 -EnvFile ./my-deployment.env
#>
#requires -Version 5.1
param(
    # Path to the .env file (copy .env.example and edit it).
    [string]$EnvFile = "$PSScriptRoot/.env",
    # Skip bootstrap.ps1 (IdP client + machine-user seed) and only run quick-start.ps1.
    [switch]$SkipBootstrap,
    # Skip copy-claimsets.ps1 (built-in claimset copies in EdFi_Security).
    [switch]$SkipClaimsets
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/load-dotenv.ps1"
. "$PSScriptRoot/compat.ps1"

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

$provider = Get-EnvValue 'PROVIDER' 'keycloak'
$dbEngine = Get-EnvValue 'DB_ENGINE' 'mssql'
# EdFi_Security lives on the ODS/API side, so it may use a different engine
# (and, for pgsql, a different server) than the Admin App database.
$securityDbEngine = Get-EnvValue 'SECURITY_DB_ENGINE' $dbEngine
$copyClaimsets = -not $SkipClaimsets -and (Get-EnvValue 'COPY_CLAIMSETS' 'true') -in @('true', 'True', 'TRUE', '1', 'yes')
$odss = @()
$odssJson = Get-EnvValue 'ODSS_JSON'
if ($odssJson)
{
    # -AsHashtable is PS6+ only; parse to PSCustomObjects instead (consumers
    # use dot-access, which works for both). Assign before @(): on Windows
    # PowerShell 5.1 ConvertFrom-Json emits the parsed array as a SINGLE
    # pipeline object, so @() directly around the pipeline would wrap the
    # whole array as one element.
    $parsedOdss = $odssJson | ConvertFrom-Json
    $odss = @($parsedOdss)
}

# ---- Up-front validation of the provider/engine-specific required values -----
# Non-password values fail fast here; the passwords below are prompted for
# instead, so nobody is asked to type a secret only to then hit an error.
$missing = @()
foreach ($name in 'MACHINE_CLIENT_SECRET', 'TOKEN_URL')
{
    if (-not (Get-EnvValue $name)) { $missing += $name }
}
if ($copyClaimsets -and $securityDbEngine -eq 'mssql' -and -not (Test-EnvTrue 'SECURITY_USE_INTEGRATED_SECURITY') -and
    -not (Get-EnvValue 'SECURITY_DB_USERNAME'))
{
    # EdFi_Security is a different database (ODS/API side), so it has its own
    # SECURITY_DB_* credentials -- the APP_DB_* login is scoped to the Admin App
    # database. SECURITY_USE_INTEGRATED_SECURITY=true bypasses both.
    $missing += 'SECURITY_DB_USERNAME'
}
$missing = @($missing | Select-Object -Unique)
if ($missing.Count -gt 0)
{
    throw "Missing required value(s) in ${EnvFile}: $($missing -join ', '). Edit the file and try again."
}

# ---- Prompt for any password not provided in the .env -------------------------
function Read-EnvSecret
{
    # If $Name has no value in the .env, ask for it interactively (masked, via
    # compat.ps1's Read-Secret) and cache it in $script:dotenv so every later
    # Get-EnvValue read reuses it.
    param([string]$Name, [string]$Prompt)
    if (Get-EnvValue $Name) { return }
    $script:dotenv[$Name] = Read-Secret -Name $Name -Prompt $Prompt
}

if (-not $SkipBootstrap)
{
    if ($provider -eq 'keycloak') { Read-EnvSecret 'KEYCLOAK_ADMIN_PASSWORD' 'Keycloak admin password' }
    if ($dbEngine -eq 'mssql') { Read-EnvSecret 'APP_DB_PASSWORD' 'Admin App database password (the APP_DB_USERNAME login)' }
    if ($dbEngine -eq 'pgsql') { Read-EnvSecret 'POSTGRES_APP_PASSWORD' 'PostgreSQL app password' }
}
if ($copyClaimsets)
{
    if ($securityDbEngine -eq 'mssql' -and -not (Test-EnvTrue 'SECURITY_USE_INTEGRATED_SECURITY'))
    {
        Read-EnvSecret 'SECURITY_DB_PASSWORD' 'EdFi_Security database password (the SECURITY_DB_USERNAME login)'
    }
    # POSTGRES_SECURITY_PASSWORD falls back to POSTGRES_APP_PASSWORD, so only
    # prompt when neither is set.
    if ($securityDbEngine -eq 'pgsql' -and -not (Get-EnvValue 'POSTGRES_APP_PASSWORD'))
    {
        Read-EnvSecret 'POSTGRES_SECURITY_PASSWORD' 'EdFi_Security PostgreSQL password'
    }
}

# ---- Step 1: bootstrap.ps1 (IdP machine client + machine-user seed) ----------
if ($SkipBootstrap)
{
    Write-Host "Skipping bootstrap.ps1 (-SkipBootstrap)." -ForegroundColor Yellow
}
else
{
    $bootstrapArgs = @{
        Provider            = $provider
        MachineClientId     = Get-EnvValue 'MACHINE_CLIENT_ID' 'edfiadminapp-machine'
        MachineClientSecret = Get-EnvValue 'MACHINE_CLIENT_SECRET'
        MachineAudience     = Get-EnvValue 'MACHINE_AUDIENCE' 'edfiadminapp-api'
        DbEngine            = $dbEngine
        DatabaseName        = Get-EnvValue 'DATABASE_NAME' 'sbaa'
        AdminAppUsername    = Get-EnvValue 'MACHINE_USERNAME' 'quick-start-machine'
    }
    if ($provider -eq 'keycloak')
    {
        $bootstrapArgs.KeycloakBaseUrl = Get-EnvValue 'KEYCLOAK_BASE_URL' 'http://localhost:8080'
        $bootstrapArgs.AdminUser = Get-EnvValue 'KEYCLOAK_ADMIN_USER' 'admin'
        $bootstrapArgs.AdminPassword = Get-EnvValue 'KEYCLOAK_ADMIN_PASSWORD'
        $bootstrapArgs.RealmName = Get-EnvValue 'KEYCLOAK_REALM' 'edfi'
    }
    if ($dbEngine -eq 'mssql')
    {
        # The least-privilege app login; 'sa' is deliberately not used (EDFI-2776).
        $bootstrapArgs.AppDbUsername = Get-EnvValue 'APP_DB_USERNAME' 'edfi_adminapp'
        $bootstrapArgs.AppDbPassword = Get-EnvValue 'APP_DB_PASSWORD'
    }
    else
    {
        $bootstrapArgs.PostgresAppPassword = Get-EnvValue 'POSTGRES_APP_PASSWORD'
        $bootstrapArgs.PostgresHost = Get-EnvValue 'POSTGRES_HOST' 'localhost'
        $bootstrapArgs.PostgresPort = [int](Get-EnvValue 'POSTGRES_PORT' '5432')
        $bootstrapArgs.PostgresAppUser = Get-EnvValue 'POSTGRES_APP_USER' 'edfiadminapp'
        if (Test-EnvTrue 'USE_POSTGRES_DOCKER') { $bootstrapArgs.UsePostgresDocker = $true }
    }
    if (Test-EnvTrue 'SKIP_CERTIFICATE_CHECK') { $bootstrapArgs.SkipCertificateCheck = $true }

    Write-Host "==> bootstrap.ps1 (provider=$provider, engine=$dbEngine)" -ForegroundColor Cyan
    & "$PSScriptRoot/bootstrap.ps1" @bootstrapArgs
}

# ---- Step 2: quick-start.ps1 (team + environment via the Admin App API) ------
$quickStartArgs = @{
    ApiBaseUrl           = Get-EnvValue 'API_BASE_URL' 'https://localhost/adminapp-api/api'
    TokenUrl             = Get-EnvValue 'TOKEN_URL'
    OAuthClientId        = Get-EnvValue 'MACHINE_CLIENT_ID' 'edfiadminapp-machine'
    OAuthClientSecret    = Get-EnvValue 'MACHINE_CLIENT_SECRET'
    Scope                = Get-EnvValue 'OAUTH_SCOPE' 'login:app'
    TeamName             = Get-EnvValue 'TEAM_NAME' 'Quick Start'
    EnvironmentName      = Get-EnvValue 'ENVIRONMENT_NAME' 'Ed-Fi ODS/API v7.3'
    EnvironmentLabel     = Get-EnvValue 'ENVIRONMENT_LABEL' 'QuickStart'
    AdminApiUrl          = Get-EnvValue 'ADMIN_API_URL' 'https://localhost/AdminApi'
    OdsApiDiscoveryUrl   = Get-EnvValue 'ODS_API_DISCOVERY_URL' 'https://localhost/WebApi'
    TenantName           = Get-EnvValue 'TENANT_NAME' 'default'
    AdminUsername        = Get-EnvValue 'ADMIN_USERNAME'
    SkipCertificateCheck = Test-EnvTrue 'SKIP_CERTIFICATE_CHECK'
}
if ($odss.Count -gt 0)
{
    $quickStartArgs.Odss = $odss
}

Write-Host "==> quick-start.ps1" -ForegroundColor Cyan
& "$PSScriptRoot/quick-start.ps1" @quickStartArgs

# ---- Step 3: copy-claimsets.ps1 (built-in claimset copies in EdFi_Security) --
if (-not $copyClaimsets)
{
    Write-Host "`nSkipping copy-claimsets.ps1 ($(if ($SkipClaimsets) { '-SkipClaimsets' } else { 'COPY_CLAIMSETS=false' }))." -ForegroundColor Yellow
}
else
{
    $claimsetArgs = @{
        DbEngine     = $securityDbEngine
        DatabaseName = Get-EnvValue 'SECURITY_DATABASE_NAME' 'EdFi_Security'
    }
    $claimsetNames = Get-EnvValue 'CLAIMSET_NAMES'
    if ($claimsetNames)
    {
        $claimsetArgs.ClaimSetNames = @($claimsetNames -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $claimsetPrefix = Get-EnvValue 'CLAIMSET_PREFIX'
    if ($claimsetPrefix) { $claimsetArgs.Prefix = $claimsetPrefix }
    # EdFi_Security is a different database (ODS/API side), so mssql uses its
    # own SECURITY_DB_* credentials -- not the Admin App's APP_DB_* login. Set
    # SECURITY_USE_INTEGRATED_SECURITY=true to use Windows authentication
    # instead.
    if ($securityDbEngine -eq 'mssql')
    {
        $claimsetArgs.SqlServer = Get-EnvValue 'SECURITY_SQL_SERVER' 'tcp:localhost,1433'
        # Only needed for a REMOTE server with a self-signed certificate: a
        # loopback target already trusts it without this (see compat.ps1).
        if (Test-EnvTrue 'SQL_TRUST_SERVER_CERTIFICATE') { $claimsetArgs.TrustServerCertificate = $true }
        if (Test-EnvTrue 'SECURITY_USE_INTEGRATED_SECURITY')
        {
            $claimsetArgs.UseIntegratedSecurity = $true
        }
        else
        {
            $claimsetArgs.SqlUser = Get-EnvValue 'SECURITY_DB_USERNAME'
            $claimsetArgs.SqlPassword = Get-EnvValue 'SECURITY_DB_PASSWORD'
        }
    }
    else
    {
        # POSTGRES_SECURITY_* when EdFi_Security is on a different PostgreSQL
        # server than the Admin App database; each falls back to the app value.
        $claimsetArgs.PostgresPassword = Get-EnvValue 'POSTGRES_SECURITY_PASSWORD' (Get-EnvValue 'POSTGRES_APP_PASSWORD')
        $claimsetArgs.PostgresHost = Get-EnvValue 'POSTGRES_SECURITY_HOST' (Get-EnvValue 'POSTGRES_HOST' 'localhost')
        $claimsetArgs.PostgresPort = [int](Get-EnvValue 'POSTGRES_SECURITY_PORT' (Get-EnvValue 'POSTGRES_PORT' '5432'))
        $claimsetArgs.PostgresUser = Get-EnvValue 'POSTGRES_SECURITY_USER' (Get-EnvValue 'POSTGRES_APP_USER' 'edfiadminapp')
        $securityUsePostgresDocker = if (Get-EnvValue 'SECURITY_USE_POSTGRES_DOCKER') { Test-EnvTrue 'SECURITY_USE_POSTGRES_DOCKER' } else { Test-EnvTrue 'USE_POSTGRES_DOCKER' }
        if ($securityUsePostgresDocker)
        {
            $claimsetArgs.UsePostgresDocker = $true
            $claimsetArgs.PostgresContainerName = Get-EnvValue 'SECURITY_POSTGRES_CONTAINER' 'ed-fi-db-admin'
        }
    }

    Write-Host "`n==> copy-claimsets.ps1 (engine=$securityDbEngine)" -ForegroundColor Cyan
    & "$PSScriptRoot/copy-claimsets.ps1" @claimsetArgs
}
