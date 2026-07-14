#Requires -RunAsAdministrator
<#
.SYNOPSIS
Reverses the Ed-Fi Admin App install. Leaves Node.js, JDK, SQL Server, and IIS
engines installed; removes only the AdminApp's own state.

.DESCRIPTION
Steps (each best-effort, continues past individual failures):

  1. IIS teardown:
     - Remove the standalone sites 'EdFi-AdminApp-API' and 'EdFi-AdminApp-FE'.
     - Remove the HTTPS SSL bindings and delete the auto-generated self-signed cert.
     - Revoke the App Pool's read+execute grant on the node directory.
     - Stop+remove App Pool 'EdFi-AdminApp-API'.
     - Delete the deployed dirs C:\inetpub\EdFi-AdminApp-API and
       C:\inetpub\EdFi-AdminApp-FE.
  2. Database teardown (both engines, best-effort per engine):
     - MSSQL: DROP DATABASE [sbaa] and DROP LOGIN [edfi_adminapp] using SQL Auth
       (sa + -SaPassword) if provided, else Windows Auth. Skipped when
       MSSQLSERVER isn't running. Leaves Mixed Mode / sa / TCP:1433 alone
       (instance-wide settings other apps may rely on).
     - PGSQL (docker): `docker compose down -v` from windows-install\docker so
       the data + cert volumes are removed. Skipped when no
       edfiadminapp-postgres container exists. Without the -v, the volume
       persists with the OLD edfiadminapp password and TypeORM-created
       tables, which causes auth/permission failures on the next install.
  2b. Yopass docker teardown (best-effort): `docker compose -f
     docker-compose.yopass.yml down -v` so the Yopass + memcached containers and
     their volumes are removed. Skipped when docker is absent or the
     edfiadminapp-yopass container was never created. Not gated by
     -KeepDatabase.
  3. Filesystem teardown:
     - Delete C:\npm-cache (unless -KeepNpmCache). The NPM_CONFIG_CACHE override
       is set on the App Pool by 05-deploy-api and is removed with the pool.
  4. Detect Keycloak leftovers (C:\keycloak, JAVA_HOME, a running Keycloak
     process) and, if any are found, suggest running uninstall-keycloak.ps1.
     Informational only -- this step does not stop or delete anything.
  5. Print a summary of what succeeded and what didn't.

The local Keycloak IdP (process, C:\keycloak, JAVA_HOME) is NOT touched here.
Use uninstall-keycloak.ps1 for that.

Does NOT touch:
  - Node.js, JDK, SQL Server, IIS engine installs.
  - URL Rewrite Module, httpPlatform handler (system-level MSIs).
  - The cloned source repo (wherever this script lives — the repo root is the
    parent of windows-install\).
  - install-summary.txt next to the repo (run with -RemoveSummary to delete).

Prompts for confirmation by default. Pass -Force for non-interactive runs.

.PARAMETER DatabaseName
Database to drop. Default: sbaa. Must match what 02-prereqs-sql.ps1 created.

.PARAMETER AppDbUsername
Server-level login to drop alongside the database. Default: edfi_adminapp. Must
match what 02-prereqs-sql.ps1 provisioned.

.PARAMETER SaPassword
SQL sa password. If provided, the DB drop uses SQL Auth over TCP. If omitted,
the script falls back to Windows Auth via (local).

.PARAMETER KeycloakInstallPath
Path checked for Keycloak leftovers (informational only; this script does not
delete it). Default: C:\keycloak.

.PARAMETER NpmCachePath
Default: C:\npm-cache.

.PARAMETER AppPoolName
Default: EdFi-AdminApp-API.

.PARAMETER StandaloneFeSiteName
Name of the FE site created by 06-deploy-fe.ps1. Default: EdFi-AdminApp-FE.
(The API site name is the App Pool name, $AppPoolName.)

.PARAMETER StandaloneFeAppPoolName
Name of the dedicated FE App Pool created by 06-deploy-fe.ps1. Default:
EdFi-AdminApp-FE.

.PARAMETER ApiDestPath
The deployed API directory to delete. Default: C:\inetpub\EdFi-AdminApp-API.

.PARAMETER FeDestPath
The deployed FE directory to delete. Default: C:\inetpub\EdFi-AdminApp-FE.

.PARAMETER KeepDatabase
Switch — skip the DROP DATABASE step.

.PARAMETER KeepNpmCache
Switch — leave C:\npm-cache in place.

.PARAMETER RemoveSummary
Switch — also delete the install-summary.txt next to the repo (the file
install-all.ps1 wrote at the parent of the repo directory).

.PARAMETER Force
Switch — skip the confirmation prompt.

.EXAMPLE
.\uninstall.ps1
.\uninstall.ps1 -SaPassword 'EdFi-Local!2026' -Force
.\uninstall.ps1 -KeepDatabase -KeepNpmCache
#>

param(
    [string]$DatabaseName = "sbaa",
    [string]$AppDbUsername = "edfi_adminapp",
    [SecureString]$SaPassword,
    [string]$KeycloakInstallPath = "C:\keycloak",
    [string]$NpmCachePath = "C:\npm-cache",
    [string]$AppPoolName = "EdFi-AdminApp-API",
    [string]$StandaloneFeSiteName = "EdFi-AdminApp-FE",
    [string]$StandaloneFeAppPoolName = "EdFi-AdminApp-FE",
    [string]$ApiDestPath = "C:\inetpub\EdFi-AdminApp-API",
    [string]$FeDestPath = "C:\inetpub\EdFi-AdminApp-FE",
    [int]$HttpsApiPort = 3443,
    [int]$HttpsFePort = 4443,
    # Summary is written by install-all.ps1 to the parent of the repo dir
    # (i.e. grandparent of windows-install\). Auto-resolve the same way.
    [string]$SummaryPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "install-summary.txt"),

    [switch]$KeepDatabase,
    [switch]$KeepNpmCache,
    [switch]$RemoveSummary,
    [switch]$Force
)

# Don't bail on the first non-terminating error -- this is a teardown, we want
# to push through and report at the end.
$ErrorActionPreference = 'Continue'

# -SaPassword is optional: omit it to drop the database via Windows Auth. When
# given it arrives as SecureString (kept off the command line); unwrap to a new
# local (assigning back to the [SecureString]-typed parameter would re-trigger
# its type conversion and fail).
$SaPasswordPlain = if ($SaPassword) { [System.Net.NetworkCredential]::new('', $SaPassword).Password } else { $null }

$results = [System.Collections.Generic.List[object]]::new()
function Record {
    param([string]$Step, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail })
    $color = switch ($Status) {
        'OK'    { 'Green' }
        'SKIP'  { 'DarkGray' }
        'WARN'  { 'Yellow' }
        'FAIL'  { 'Red' }
        default { 'White' }
    }
    Write-Host ("[{0,-4}] {1}" -f $Status, $Step) -ForegroundColor $color -NoNewline
    if ($Detail) { Write-Host "  -- $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("-" * $Title.Length) -ForegroundColor Cyan
}

# Confirmation
Write-Host ""
Write-Host "Ed-Fi Admin App -- UNINSTALL" -ForegroundColor Magenta
Write-Host "This will remove:"
Write-Host "  - Standalone IIS sites '$AppPoolName' (API) and '$StandaloneFeSiteName' (FE)"
Write-Host "  - IIS App Pools '$AppPoolName' (API) and '$StandaloneFeAppPoolName' (FE)"
Write-Host "  - HTTPS SSL bindings + the auto-generated self-signed certificate"
Write-Host "  - Deployed dirs: $ApiDestPath and $FeDestPath"
if (-not $KeepDatabase)         {
    Write-Host "  - SQL database [$DatabaseName] + login [$AppDbUsername] (if MSSQLSERVER is running)"
    Write-Host "  - Docker postgres container + volumes (if edfiadminapp-postgres exists)"
}
Write-Host "  - Docker Yopass stack (edfiadminapp-yopass + memcached) and its volumes (if present)"
if (-not $KeepNpmCache)         { Write-Host "  - $NpmCachePath (npm cache dir)" }
if ($RemoveSummary)             { Write-Host "  - $SummaryPath" }
Write-Host ""
Write-Host "Leaves alone: Node.js, JDK, SQL Server, IIS, URL Rewrite, httpPlatform handler, source repo." -ForegroundColor DarkGray
Write-Host ""

if (-not $Force) {
    $reply = Read-Host "Proceed? (y/N)"
    if ($reply -notmatch '^[Yy]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }
}

# ========================================================
Write-Section "1. IIS teardown"
# ========================================================
$iisAvailable = $false
try {
    Import-Module WebAdministration -ErrorAction Stop
    $iisAvailable = $true
} catch {
    Record "Load WebAdministration" "WARN" "IIS module unavailable -- skipping IIS steps"
}

if ($iisAvailable) {
    # Remove the two standalone AdminApp sites (API named after the App Pool, FE).
    foreach ($siteName in @($AppPoolName, $StandaloneFeSiteName)) {
        try {
            $site = Get-Website -Name $siteName -ErrorAction SilentlyContinue
            if ($site) {
                if ($site.State -eq 'Started') {
                    Stop-Website -Name $siteName -ErrorAction SilentlyContinue
                }
                Remove-Website -Name $siteName -ErrorAction Stop
                Record "Remove IIS site '$siteName'" "OK"
            } else {
                Record "IIS site '$siteName'" "SKIP" "Not present"
            }
        } catch {
            Record "Remove IIS site '$siteName'" "FAIL" $_.Exception.Message
        }
    }

    # TLS teardown: Remove-Website above dropped each site's https binding, but the
    # HTTP.sys SSL certificate registration (IIS:\SslBindings) persists separately --
    # remove it so a reinstall rebinds cleanly. Then delete the self-signed cert we
    # generated (matched by FriendlyName); a user-supplied cert is left untouched.
    foreach ($httpsPort in @($HttpsApiPort, $HttpsFePort)) {
        $sslPath = "IIS:\SslBindings\0.0.0.0!$httpsPort"
        try {
            if (Test-Path $sslPath) {
                Remove-Item $sslPath -Force -ErrorAction Stop
                Record "Remove SSL binding 0.0.0.0:$httpsPort" "OK"
            } else {
                Record "SSL binding 0.0.0.0:$httpsPort" "SKIP" "Not present"
            }
        } catch {
            Record "Remove SSL binding 0.0.0.0:$httpsPort" "FAIL" $_.Exception.Message
        }
    }
    # Remove our self-signed cert from BOTH the personal store (My, where it's
    # generated) and the trusted root store (Root, where 05/06 add it so local
    # browsers trust it). Match only OUR FriendlyName so unrelated localhost roots
    # (dotnet dev-certs, IIS Express, ...) are never touched.
    $selfSignedFriendlyName = 'Ed-Fi Admin App self-signed'
    foreach ($store in @('My', 'Root')) {
        try {
            $certs = Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -eq $selfSignedFriendlyName }
            if ($certs) {
                $certs | ForEach-Object { Remove-Item "Cert:\LocalMachine\$store\$($_.Thumbprint)" -Force -ErrorAction Stop }
                Record "Remove self-signed TLS certificate ($store)" "OK" "$($certs.Count) removed"
            } else {
                Record "Self-signed TLS certificate ($store)" "SKIP" "Not present (or a user-supplied cert was used)"
            }
        } catch {
            Record "Remove self-signed TLS certificate ($store)" "FAIL" $_.Exception.Message
        }
    }

    # Revoke the App Pool's read+execute grant on the node directory that
    # 05-deploy-api.ps1 added so httpPlatform could launch node as this identity.
    # Done before the App Pool is removed, while 'IIS APPPOOL\<pool>' still
    # resolves. Mirrors 05's node resolution (follow the PATH node's symlink, skip
    # a user-profile path, fall back to a machine-wide install).
    $nodeDir = $null
    foreach ($candidate in @((Get-Command node -ErrorAction SilentlyContinue).Source, "C:\Program Files\nodejs\node.exe")) {
        if (-not $candidate -or -not (Test-Path $candidate)) { continue }
        $link = (Get-Item $candidate -ErrorAction SilentlyContinue).Target
        $real = if ($link) { @($link)[0] } else { $candidate }
        if ($real -like "$env:SystemDrive\Users\*") { continue }
        $nodeDir = Split-Path $real -Parent
        break
    }
    if ($nodeDir -and (Test-Path $nodeDir)) {
        try {
            & icacls $nodeDir /remove:g "IIS APPPOOL\$AppPoolName" | Out-Null
            Record "Revoke App Pool grant on node dir" "OK" $nodeDir
        } catch {
            Record "Revoke App Pool grant on node dir" "WARN" $_.Exception.Message
        }
    } else {
        Record "Revoke App Pool grant on node dir" "SKIP" "node dir not resolved"
    }

    # Stop + remove App Pool
    try {
        if (Test-Path "IIS:\AppPools\$AppPoolName") {
            $state = (Get-WebAppPoolState -Name $AppPoolName -ErrorAction SilentlyContinue).Value
            if ($state -eq 'Started') {
                Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
            }
            Remove-WebAppPool -Name $AppPoolName -ErrorAction Stop
            Record "Remove App Pool '$AppPoolName'" "OK"
        } else {
            Record "App Pool '$AppPoolName'" "SKIP" "Not present"
        }
    } catch {
        Record "Remove App Pool '$AppPoolName'" "FAIL" $_.Exception.Message
    }

    # Stop + remove the dedicated FE App Pool (06-deploy-fe.ps1 creates it so the
    # SPA no longer rides DefaultAppPool). Guarded so we never touch DefaultAppPool.
    try {
        if ($StandaloneFeAppPoolName -eq 'DefaultAppPool') {
            Record "Remove FE App Pool" "SKIP" "Refusing to remove DefaultAppPool"
        } elseif (Test-Path "IIS:\AppPools\$StandaloneFeAppPoolName") {
            $feState = (Get-WebAppPoolState -Name $StandaloneFeAppPoolName -ErrorAction SilentlyContinue).Value
            if ($feState -eq 'Started') {
                Stop-WebAppPool -Name $StandaloneFeAppPoolName -ErrorAction SilentlyContinue
            }
            Remove-WebAppPool -Name $StandaloneFeAppPoolName -ErrorAction Stop
            Record "Remove App Pool '$StandaloneFeAppPoolName'" "OK"
        } else {
            Record "App Pool '$StandaloneFeAppPoolName'" "SKIP" "Not present"
        }
    } catch {
        Record "Remove App Pool '$StandaloneFeAppPoolName'" "FAIL" $_.Exception.Message
    }
}

# Deployed file trees -- the two dedicated standalone-site directories.
# httpPlatform runs node as a child process; removing the App Pool above should
# terminate it, but it can briefly outlive the pool and keep its stdout log open,
# which blocks the directory delete. Kill any node process whose command line
# references this deployment directory (parsing the PID out of the stdout-log
# filename is fragile -- LeXtudio HttpBridge and Microsoft HttpPlatformHandler
# name those logs differently), then retry the delete a few times.
foreach ($dir in @($ApiDestPath, $FeDestPath)) {
    if (-not (Test-Path $dir)) {
        Record "Delete $dir" "SKIP" "Not present"
        continue
    }
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$dir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $deleted = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
            $deleted = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if ($deleted) {
        Record "Delete $dir" "OK"
    } else {
        Record "Delete $dir" "FAIL" "files still locked after retries (a node process may still be running)"
    }
}

# ========================================================
Write-Section "2. Database (mssql and/or pgsql docker)"
# ========================================================
# Try SQL Server first (drop the AdminApp DB if present), then the docker
# postgres compose down. Both branches are best-effort and idempotent -- they
# SKIP cleanly when their respective engine isn't actually in use on this box.
# -KeepDatabase short-circuits both.
if ($KeepDatabase) {
    Record "Drop database [$DatabaseName]" "SKIP" "-KeepDatabase"
    Record "Docker postgres down -v" "SKIP" "-KeepDatabase"
} else {
    # --- mssql ----------------------------------------------------------------
    $sqlcmdAvailable = $null -ne (Get-Command sqlcmd -ErrorAction SilentlyContinue)
    $msSqlRunning = $null -ne (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    if (-not $sqlcmdAvailable -or -not $msSqlRunning) {
        Record "Drop database [$DatabaseName] + login [$AppDbUsername] (mssql)" "SKIP" $(if (-not $msSqlRunning) { "MSSQLSERVER not running" } else { "sqlcmd not on PATH" })
    } else {
        # SET SINGLE_USER ROLLBACK IMMEDIATE forces existing connections off
        # before the DROP. Without it the drop fails when the API's node process
        # (launched by httpPlatform) still has a pool open (e.g., if the App Pool
        # removal above didn't terminate the node process cleanly).
        # Also drop the server-level app login. 02-prereqs-sql creates it once and
        # only re-syncs the password on re-run, so without this it survives an
        # uninstall and a later reinstall silently keeps the old password. Bracket-
        # and literal-escape the name in case a custom -AppDbUsername contains ] or '.
        $safeUser        = $AppDbUsername -replace ']', ']]'
        $safeUserLiteral = $AppDbUsername -replace "'", "''"
        $dropQuery = @"
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$DatabaseName')
BEGIN
    ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$DatabaseName];
END
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$safeUserLiteral' AND type = 'S')
    DROP LOGIN [$safeUser];
"@
        # SQLCMDPASSWORD instead of -P keeps the password off the sqlcmd process
        # command line; cleared in the finally.
        $authArgs = if ($SaPasswordPlain) {
            @("-S", "tcp:localhost,1433", "-U", "sa")
        } else {
            @("-S", "(local)", "-E")
        }
        if ($SaPasswordPlain) { $env:SQLCMDPASSWORD = $SaPasswordPlain }
        try {
            & sqlcmd @authArgs -Q $dropQuery -t 30 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $authMode = if ($SaPasswordPlain) { "SQL Auth" } else { "Windows Auth" }
                Record "Drop database [$DatabaseName] + login [$AppDbUsername] (mssql)" "OK" $authMode
            } else {
                Record "Drop database [$DatabaseName] + login [$AppDbUsername] (mssql)" "FAIL" "sqlcmd exit $LASTEXITCODE"
            }
        } catch {
            Record "Drop database [$DatabaseName] + login [$AppDbUsername] (mssql)" "FAIL" $_.Exception.Message
        } finally {
            if ($SaPasswordPlain) { Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue }
        }
    }

    # --- pgsql docker ---------------------------------------------------------
    # Run `docker compose down -v` from windows-install\docker so the persisted
    # data + cert volumes are removed. Without -v the volume keeps the OLD
    # edfiadminapp password and any tables created by an earlier TypeORM run,
    # which causes auth/permission failures on the next install.
    $dockerDir = Join-Path $PSScriptRoot "docker"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Record "Docker postgres down -v" "SKIP" "docker not on PATH"
    } elseif (-not (Test-Path "$dockerDir\docker-compose.yml")) {
        Record "Docker postgres down -v" "SKIP" "docker-compose.yml not found at $dockerDir"
    } else {
        # Only act if the compose stack has actually been brought up before
        # (container exists, even if stopped). Otherwise SKIP cleanly.
        $containerExists = $false
        try {
            $found = & docker ps -a --filter "name=^edfiadminapp-postgres$" --format "{{.Names}}" 2>$null
            if ($found -match 'edfiadminapp-postgres') { $containerExists = $true }
        } catch { }
        if (-not $containerExists) {
            Record "Docker postgres down -v" "SKIP" "edfiadminapp-postgres container not present"
        } else {
            Push-Location $dockerDir
            try {
                & docker compose down -v 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Record "Docker postgres down -v" "OK" "Container + data/cert volumes removed"
                } else {
                    Record "Docker postgres down -v" "FAIL" "docker compose exit $LASTEXITCODE"
                }
            } catch {
                Record "Docker postgres down -v" "FAIL" $_.Exception.Message
            } finally {
                Pop-Location
            }
        }
    }
}

# ========================================================
Write-Section "2b. Yopass (docker stack)"
# ========================================================
# Tear down the dockerized Yopass stack if it was ever brought up (by
# yopass-docker.ps1 / install-all -SetupYopassDocker). Best-effort and
# idempotent: SKIPs cleanly when docker is absent or the container was never
# created. Not gated by -KeepDatabase -- Yopass is not the AdminApp database.
# `down -v` also removes the memcached-backed secret store volume(s).
$yopassCompose = Join-Path (Join-Path $PSScriptRoot "docker") "docker-compose.yopass.yml"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Record "Docker yopass down -v" "SKIP" "docker not on PATH"
} elseif (-not (Test-Path $yopassCompose)) {
    Record "Docker yopass down -v" "SKIP" "docker-compose.yopass.yml not found"
} else {
    $yopassExists = $false
    try {
        $found = & docker ps -a --filter "name=^edfiadminapp-yopass$" --format "{{.Names}}" 2>$null
        if ($found -match 'edfiadminapp-yopass') { $yopassExists = $true }
    } catch { }
    if (-not $yopassExists) {
        Record "Docker yopass down -v" "SKIP" "edfiadminapp-yopass container not present"
    } else {
        Push-Location (Split-Path $yopassCompose -Parent)
        try {
            & docker compose -f $yopassCompose down -v 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Record "Docker yopass down -v" "OK" "Yopass + memcached containers/volumes removed"
            } else {
                Record "Docker yopass down -v" "FAIL" "docker compose exit $LASTEXITCODE"
            }
        } catch {
            Record "Docker yopass down -v" "FAIL" $_.Exception.Message
        } finally {
            Pop-Location
        }
    }
}

# ========================================================
Write-Section "3. Filesystem"
# ========================================================
# npm cache. The NPM_CONFIG_CACHE override is set on the App Pool by
# 05-deploy-api and is removed with the App Pool above; nothing machine-wide
# to unset here.
if ($KeepNpmCache) {
    Record "Delete $NpmCachePath" "SKIP" "-KeepNpmCache"
} elseif (Test-Path $NpmCachePath) {
    try {
        Remove-Item -Path $NpmCachePath -Recurse -Force -ErrorAction Stop
        Record "Delete $NpmCachePath" "OK"
    } catch {
        Record "Delete $NpmCachePath" "FAIL" $_.Exception.Message
    }
} else {
    Record "Delete $NpmCachePath" "SKIP" "Not present"
}

# Optional: install-summary.txt
if ($RemoveSummary) {
    if (Test-Path $SummaryPath) {
        try {
            Remove-Item -Path $SummaryPath -Force -ErrorAction Stop
            Record "Delete $SummaryPath" "OK"
        } catch {
            Record "Delete $SummaryPath" "FAIL" $_.Exception.Message
        }
    } else {
        Record "Delete $SummaryPath" "SKIP" "Not present"
    }
}

# ========================================================
Write-Section "4. Keycloak leftovers (informational)"
# ========================================================
# This script does not touch the local Keycloak IdP. If leftovers from
# idp-keycloak-setup.ps1 are present, point the user at uninstall-keycloak.ps1.
# Informational only -- nothing here is stopped or deleted.
$kcLeftovers = @()
if (Test-Path $KeycloakInstallPath) { $kcLeftovers += "install dir $KeycloakInstallPath" }
if ([Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")) { $kcLeftovers += "Machine JAVA_HOME" }
try {
    $kcProc = Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'kc\.bat|keycloak|quarkus' }
    if ($kcProc) { $kcLeftovers += "running Keycloak process" }
} catch { }
if ($kcLeftovers.Count -gt 0) {
    Write-Host "Keycloak leftovers detected: $($kcLeftovers -join '; ')" -ForegroundColor Yellow
    Write-Host "These were NOT removed. Run uninstall-keycloak.ps1 to remove the local Keycloak IdP." -ForegroundColor Yellow
} else {
    Write-Host "No Keycloak leftovers detected." -ForegroundColor DarkGray
}

# ========================================================
Write-Section "Summary"
# ========================================================
$ok    = ($results | Where-Object { $_.Status -eq 'OK' }).Count
$skip  = ($results | Where-Object { $_.Status -eq 'SKIP' }).Count
$warn  = ($results | Where-Object { $_.Status -eq 'WARN' }).Count
$fail  = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Host "OK: $ok   SKIP: $skip   WARN: $warn   FAIL: $fail"
Write-Host ""

if ($fail -gt 0) {
    Write-Host "Some steps failed. Re-run the script to retry, or address the underlying issue:" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
        Write-Host "  - $($_.Step): $($_.Detail)" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "Uninstall complete." -ForegroundColor Green
    exit 0
}
