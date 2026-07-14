#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs the OS-level prerequisites that the Admin App install scripts assume
are already in place: IIS (with the right features), SQL Server Developer
Edition, and Git.

.DESCRIPTION
Runs in two phases:
  1. SCAN -- reports the current state of each prereq (PASS or MISSING)
  2. INSTALL -- installs only the items flagged MISSING

Intended for use on a fresh Windows VM or workstation before running
00-check-prereqs.ps1 / install-all.ps1.

Uses --source winget on the winget commands to avoid msstore certificate
validation errors that occur on fresh dev-environment VMs.

A reboot may be required after this script completes -- if so, the script
prints a notice but does not reboot automatically.

.PARAMETER SkipIIS
Switch -- skip the IIS feature install (useful if IIS is already configured
the way you want).

.PARAMETER SkipSqlServer
Switch -- skip SQL Server install (e.g., you have a remote SQL Server or a
different edition).

.PARAMETER SkipGit
Switch -- skip Git install.

.EXAMPLE
.\setup-vm-prereqs.ps1
.\setup-vm-prereqs.ps1 -SkipSqlServer
#>

param(
    [switch]$SkipIIS,
    [switch]$SkipSqlServer,
    [switch]$SkipGit
)

$ErrorActionPreference = 'Stop'

# Enable script execution for this user (RemoteSigned: local scripts run freely,
# downloaded scripts need a signature). Persists across sessions so install-all
# and friends don't need any per-shell bypass.
$currentPolicy = Get-ExecutionPolicy -Scope CurrentUser
if ($currentPolicy -ne 'RemoteSigned' -and $currentPolicy -ne 'Unrestricted' -and $currentPolicy -ne 'Bypass') {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    Write-Host "Set CurrentUser execution policy to RemoteSigned." -ForegroundColor Green
} else {
    Write-Host "CurrentUser execution policy already permissive ($currentPolicy)." -ForegroundColor Green
}

# Strip the zone-of-origin marker from the scripts we ship, so PowerShell doesn't
# treat them as "downloaded from the internet" and refuse to run them. Only the
# known repo scripts are unblocked -- we don't vouch for arbitrary .ps1 files that
# happen to be in this folder.
$scriptDir = $PSScriptRoot
$knownScripts = @(
    '00-check-prereqs.ps1', '01-prereqs-iis.ps1', '02-prereqs-sql.ps1',
    '03-prereqs-node.ps1', '04-build.ps1', '05-deploy-api.ps1', '06-deploy-fe.ps1',
    'install-all.ps1', 'setup-vm-prereqs.ps1', 'uninstall.ps1',
    'idp-keycloak-setup.ps1', 'idp-keycloak-start.ps1', 'uninstall-keycloak.ps1',
    'yopass-docker.ps1'
)
if ($scriptDir) {
    foreach ($name in $knownScripts) {
        $path = Join-Path $scriptDir $name
        if (Test-Path $path) { Unblock-File $path }
    }
    Write-Host "Unblocked the known Ed-Fi install scripts in $scriptDir." -ForegroundColor Green

    $unexpected = Get-ChildItem "$scriptDir\*.ps1" -ErrorAction SilentlyContinue |
        Where-Object { $knownScripts -notcontains $_.Name }
    if ($unexpected) {
        Write-Warning ("Left these unrecognized .ps1 file(s) blocked (not part of this repo): " +
            ($unexpected.Name -join ', '))
    }
}

function Write-Phase {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-Status {
    param([string]$Level, [string]$Name, [string]$Detail)
    $color = switch ($Level) { 'PASS' { 'Green' }; 'MISSING' { 'Yellow' }; 'SKIPPED' { 'DarkGray' }; default { 'White' } }
    $marker = "[$Level]".PadRight(10)
    Write-Host $marker -ForegroundColor $color -NoNewline
    Write-Host " $Name" -NoNewline
    if ($Detail) { Write-Host "  -- $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
}

# Sanity: clock drift breaks winget's cert validation on fresh VMs
$beforeSync = Get-Date
try { w32tm /resync /force 2>&1 | Out-Null } catch {}
$afterSync = Get-Date
$drift = [Math]::Abs(($afterSync - $beforeSync).TotalSeconds)
if ($drift -gt 30) {
    Write-Host "System clock drifted $([int]$drift)s on resync -- this can break SSL validation. Re-synced now." -ForegroundColor Yellow
}

# ============================================================
# PHASE 1 -- SCAN
# ============================================================
Write-Phase "Phase 1: Scanning prereqs"

# IIS
$iisFeatures = @(
    'IIS-WebServerRole', 'IIS-WebServer', 'IIS-CommonHttpFeatures',
    'IIS-StaticContent', 'IIS-DefaultDocument', 'IIS-HttpErrors',
    'IIS-HttpRedirect', 'IIS-ApplicationDevelopment', 'IIS-NetFxExtensibility45',
    'IIS-ISAPIExtensions', 'IIS-ISAPIFilter', 'IIS-HealthAndDiagnostics',
    'IIS-HttpLogging', 'IIS-Security', 'IIS-RequestFiltering',
    'IIS-Performance', 'IIS-WebServerManagementTools',
    'IIS-IIS6ManagementCompatibility', 'IIS-Metabase', 'IIS-ManagementConsole'
)
$iisMissing = @()
if (-not $SkipIIS) {
    foreach ($f in $iisFeatures) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
        if ($state -ne 'Enabled') { $iisMissing += $f }
    }
    if ($iisMissing.Count -eq 0) {
        Write-Status PASS "IIS" "all $($iisFeatures.Count) features enabled"
        $iisAction = 'pass'
    } else {
        Write-Status MISSING "IIS" "$($iisMissing.Count) of $($iisFeatures.Count) features need enabling"
        $iisAction = 'install'
    }
} else {
    Write-Status SKIPPED "IIS" "-SkipIIS passed"
    $iisAction = 'skip'
}

# SQL Server
if (-not $SkipSqlServer) {
    $sqlService = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
    if ($sqlService) {
        Write-Status PASS "SQL Server" "MSSQLSERVER service exists (status: $($sqlService.Status))"
        $sqlAction = 'pass'
    } else {
        Write-Status MISSING "SQL Server" "MSSQLSERVER service not found"
        $sqlAction = 'install'
    }
} else {
    Write-Status SKIPPED "SQL Server" "-SkipSqlServer passed"
    $sqlAction = 'skip'
}

# Git
if (-not $SkipGit) {
    # Refresh PATH so a just-installed git in another shell is visible
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        Write-Status PASS "Git" $git.Source
        $gitAction = 'pass'
    } else {
        Write-Status MISSING "Git" "not on PATH"
        $gitAction = 'install'
    }
} else {
    Write-Status SKIPPED "Git" "-SkipGit passed"
    $gitAction = 'skip'
}

$toInstall = @()
if ($iisAction -eq 'install') { $toInstall += 'IIS' }
if ($sqlAction -eq 'install') { $toInstall += 'SQL Server' }
if ($gitAction -eq 'install') { $toInstall += 'Git' }

if ($toInstall.Count -eq 0) {
    Write-Host ""
    Write-Host "All prereqs already in place. Nothing to install." -ForegroundColor Green
    Write-Host ""
    Write-Host "Next step: run .\install-all.ps1 to install the Admin App."
    return
}

# ============================================================
# PHASE 2 -- INSTALL
# ============================================================
Write-Phase "Phase 2: Installing $($toInstall -join ', ')"

if ($iisAction -eq 'install') {
    Write-Host "Enabling $($iisMissing.Count) IIS feature(s)..."
    Enable-WindowsOptionalFeature -Online -FeatureName $iisMissing -All -NoRestart | Out-Null
    Write-Host "IIS features enabled." -ForegroundColor Green
}

if ($sqlAction -eq 'install') {
    Write-Host "Installing SQL Server 2022 Developer (~2 GB, a few minutes)..."
    & winget install Microsoft.SQLServer.2022.Developer --source winget --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "winget install for SQL Server failed (exit $LASTEXITCODE). Try the direct installer from https://www.microsoft.com/sql-server/sql-server-downloads."
    }
    Start-Sleep -Seconds 3
    $sqlService = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
    if ($sqlService) {
        Write-Host "SQL Server installed (service status: $($sqlService.Status))." -ForegroundColor Green
    } else {
        Write-Host "winget reported success but MSSQLSERVER service not found. A reboot may be required." -ForegroundColor Yellow
    }
}

if ($gitAction -eq 'install') {
    Write-Host "Installing Git..."
    & winget install Git.Git --source winget --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "winget install for Git failed (exit $LASTEXITCODE)."
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    Write-Host "Git installed." -ForegroundColor Green
}

# ============================================================
Write-Phase "VM PREREQS COMPLETE"
Write-Host "Next steps:"
Write-Host "  1. If any install above said a reboot may be required, reboot now."
Write-Host "  2. Run .\install-all.ps1 from this folder -- it runs the pre-flight check and the full install."
