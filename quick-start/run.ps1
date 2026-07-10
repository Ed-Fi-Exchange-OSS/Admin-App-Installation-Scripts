#requires -Version 7.0
<#
.SYNOPSIS
  One-step Global Admin Quick Start: loads .env and runs bootstrap.ps1
  followed by quick-start.ps1.

.DESCRIPTION
  Copy .env.example to .env, edit the values to match your deployment, then run
  ./run.ps1. The variables map 1:1 onto the parameters of bootstrap.ps1 (IdP
  machine client + machine-user seed) and quick-start.ps1 (team / environment /
  ODS provisioning through the Admin App API). Both scripts are idempotent, so
  re-running is safe.

.EXAMPLE
  ./run.ps1

.EXAMPLE
  # Machine client + machine user already in place; only provision the environment.
  ./run.ps1 -SkipBootstrap

.EXAMPLE
  ./run.ps1 -EnvFile ./my-deployment.env
#>
param(
    # Path to the .env file (copy .env.example and edit it).
    [string]$EnvFile = "$PSScriptRoot/.env",
    # Skip bootstrap.ps1 (IdP client + machine-user seed) and only run quick-start.ps1.
    [switch]$SkipBootstrap
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/load-dotenv.ps1"

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

# ---- Up-front validation of the provider/engine-specific required values -----
$missing = @()
foreach ($name in 'MACHINE_CLIENT_SECRET', 'TOKEN_URL')
{
    if (-not (Get-EnvValue $name)) { $missing += $name }
}
if (-not $SkipBootstrap)
{
    if ($provider -eq 'keycloak' -and -not (Get-EnvValue 'KEYCLOAK_ADMIN_PASSWORD')) { $missing += 'KEYCLOAK_ADMIN_PASSWORD' }
    if ($dbEngine -eq 'mssql' -and -not (Get-EnvValue 'SA_PASSWORD')) { $missing += 'SA_PASSWORD' }
    if ($dbEngine -eq 'pgsql' -and -not (Get-EnvValue 'POSTGRES_APP_PASSWORD')) { $missing += 'POSTGRES_APP_PASSWORD' }
}
if ($missing.Count -gt 0)
{
    throw "Missing required value(s) in ${EnvFile}: $($missing -join ', '). Edit the file and try again."
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
        $bootstrapArgs.SaPassword = Get-EnvValue 'SA_PASSWORD'
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
    SkipCertificateCheck = Test-EnvTrue 'SKIP_CERTIFICATE_CHECK'
}
$odssJson = Get-EnvValue 'ODSS_JSON'
if ($odssJson)
{
    $quickStartArgs.Odss = @($odssJson | ConvertFrom-Json -AsHashtable)
}

Write-Host "==> quick-start.ps1" -ForegroundColor Cyan
& "$PSScriptRoot/quick-start.ps1" @quickStartArgs
