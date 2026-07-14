<#
.SYNOPSIS
Starts Keycloak in the background and bootstraps the master-realm admin user.

.DESCRIPTION
Sets KC_BOOTSTRAP_ADMIN_USERNAME and KC_BOOTSTRAP_ADMIN_PASSWORD env vars for
the spawned process (Keycloak 26+ uses these on first start to create the master
admin). Launches kc.bat start-dev as a detached background process, then polls
the master realm's OIDC discovery endpoint until Keycloak is ready.

If Keycloak is already running and reachable, the script just verifies and exits.
If Keycloak was previously bootstrapped with a different admin password, the env
vars are ignored (Keycloak only honors them on first start) — use the existing
admin credentials downstream.

Does NOT require elevation, unless -RegisterStartupTask is used (registering a
machine startup task needs an elevated shell).

.PARAMETER KeycloakInstallPath
Where Keycloak is installed. Default: C:\keycloak.

.PARAMETER RegisterStartupTask
Switch -- register a Windows Scheduled Task that relaunches Keycloak (as SYSTEM,
'kc.bat start-dev') at system startup so the example IdP survives a reboot.
Requires elevation. Off by default. Remove with
schtasks /delete /tn 'Ed-Fi Admin App Keycloak' /f.

.PARAMETER AdminUser
Bootstrap admin username (first-run only). Default: admin.

.PARAMETER AdminPassword
Bootstrap admin password (first-run only).

.PARAMETER BaseUrl
URL to probe. Default: http://localhost:8080.

.PARAMETER ReadyTimeoutSeconds
How long to wait for Keycloak to be reachable. Default: 120.

.EXAMPLE
.\idp-keycloak-start.ps1 -AdminPassword 'admin'
#>

param(
    [string]$KeycloakInstallPath = "C:\keycloak",
    [string]$AdminUser = "admin",

    [Parameter(Mandatory = $true)]
    [SecureString]$AdminPassword,

    [string]$BaseUrl = "http://localhost:8080",
    [int]$ReadyTimeoutSeconds = 120,

    # Opt-in: register a Windows Scheduled Task that relaunches Keycloak at system
    # startup so the example IdP survives a reboot (otherwise it must be restarted by
    # re-running this script). Requires an elevated shell. Off by default to keep the
    # local example lightweight.
    [switch]$RegisterStartupTask
)

$ErrorActionPreference = 'Stop'

# Resolve kc.bat under the install path, accepting a flat OR a nested (versioned)
# layout. Throws with actionable guidance when Keycloak has not been downloaded yet.
function Resolve-KcBat {
    param([Parameter(Mandatory)][string]$InstallPath)
    if (Test-Path (Join-Path $InstallPath "bin\kc.bat")) {
        return (Join-Path $InstallPath "bin\kc.bat")
    }
    $sub = Get-ChildItem $InstallPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path "$($_.FullName)\bin\kc.bat" } |
        Select-Object -First 1
    if ($sub) { return "$($sub.FullName)\bin\kc.bat" }
    throw "kc.bat not found under $InstallPath. Run idp-keycloak-setup.ps1 first to download Keycloak."
}

# Register a startup Scheduled Task so Keycloak comes back after a reboot. Runs as
# SYSTEM at boot (survives with no interactive logon; picks up the machine JAVA_HOME
# that idp-keycloak-setup sets). Idempotent via -Force. Requires elevation.
function Register-KeycloakStartupTask {
    param(
        [Parameter(Mandatory)][string]$KcBat,
        [Parameter(Mandatory)][string]$LogPath
    )
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "-RegisterStartupTask requires an elevated (Administrator) PowerShell session to register a machine startup task."
    }
    $taskName = 'Ed-Fi Admin App Keycloak'
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' `
        -Argument "/c `"`"$KcBat`" start-dev >> `"$LogPath`" 2>&1`"" `
        -WorkingDirectory (Split-Path $KcBat -Parent)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # ExecutionTimeLimit = 0 -> no time limit, so Keycloak is not killed after the
    # default 3-day task cap.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Registered startup task '$taskName' (runs 'kc.bat start-dev' as SYSTEM at boot)." -ForegroundColor Green
    Write-Host "  Remove it with: schtasks /delete /tn '$taskName' /f" -ForegroundColor DarkGray
}

# AdminPassword arrives as SecureString (kept off the command line); unwrap to a
# new local (assigning back to the [SecureString]-typed parameter would re-trigger
# its type conversion and fail) for the KC_BOOTSTRAP_ADMIN_* env vars below.
$AdminPasswordPlain = [System.Net.NetworkCredential]::new('', $AdminPassword).Password

# M1 (PR #234 security review): this script runs Keycloak in dev mode. Surface the
# posture prominently on every launch so it is never mistaken for production-ready.
Write-Warning @"
Keycloak will run in 'start-dev' mode: HTTP only, embedded H2 database, hostname
strictness disabled. This is for LOCAL DEVELOPMENT ONLY. For anything beyond local
dev, run 'kc.bat start' with --hostname, a real database (e.g. PostgreSQL), and TLS.
"@

$startupLog = Join-Path $KeycloakInstallPath "keycloak-startup.log"
$startupErr = Join-Path $KeycloakInstallPath "keycloak-startup.err.log"
$discoveryUrl = "$BaseUrl/realms/master/.well-known/openid-configuration"

# 1. Is Keycloak already up?
try {
    $r = Invoke-RestMethod -Uri $discoveryUrl -TimeoutSec 5
    Write-Host "Keycloak already running at $BaseUrl" -ForegroundColor Green
    Write-Host "Issuer: $($r.issuer)"
    if ($RegisterStartupTask) { Register-KeycloakStartupTask -KcBat (Resolve-KcBat $KeycloakInstallPath) -LogPath $startupLog }
    return
} catch {
    Write-Host "Keycloak not responding yet — starting it..."
}

# 2. Verify install -- accept flat OR nested layout
$kcBat = Resolve-KcBat $KeycloakInstallPath

# Keycloak needs a JDK (Java 17+). idp-keycloak-setup installs it and sets
# JAVA_HOME; if neither a usable JAVA_HOME nor java on PATH is present, fail
# early with a clear message instead of a kc.bat error.
$machineJavaHome = [Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
$javaAvailable = $false
if (Get-Command java -ErrorAction SilentlyContinue) { $javaAvailable = $true }
elseif ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\java.exe")) { $javaAvailable = $true }
elseif ($machineJavaHome -and (Test-Path "$machineJavaHome\bin\java.exe")) { $javaAvailable = $true }
if (-not $javaAvailable) {
    throw "No JDK found (java not on PATH and JAVA_HOME unset/invalid). Keycloak needs Java 17+. Run idp-keycloak-setup.ps1 first to install it."
}

# 3. Start Keycloak in the background. The bootstrap env vars are set on THIS
#    process so the spawned kc.bat inherits them (Start-Process has no
#    -Environment parameter in PS 5.1); Keycloak 26+ creates the master admin
#    from KC_BOOTSTRAP_ADMIN_* on first launch and ignores them thereafter.
$env:KC_BOOTSTRAP_ADMIN_USERNAME = $AdminUser
$env:KC_BOOTSTRAP_ADMIN_PASSWORD = $AdminPasswordPlain
# Older aliases still honored by 26.x for backward compat:
$env:KEYCLOAK_ADMIN = $AdminUser
$env:KEYCLOAK_ADMIN_PASSWORD = $AdminPasswordPlain

# Redirect startup output to log files instead of capturing it on pipes we
# never read: an unread redirected pipe can fill its OS buffer (~4 KB) and
# block Keycloak mid-startup, so it never becomes ready. Files have no such
# limit, and they give the "check the logs" guidance below something real to
# point at (start-dev logs to the console, not to data\log, by default).
$proc = Start-Process -FilePath $kcBat -ArgumentList "start-dev" `
    -WorkingDirectory (Split-Path $kcBat -Parent) `
    -RedirectStandardOutput $startupLog -RedirectStandardError $startupErr `
    -WindowStyle Hidden -PassThru

# The child already has its own copy of the env block; don't leave the admin
# password lingering in this process's environment.
Remove-Item Env:KC_BOOTSTRAP_ADMIN_PASSWORD, Env:KEYCLOAK_ADMIN_PASSWORD -ErrorAction SilentlyContinue

Write-Host "Started Keycloak (PID $($proc.Id)). Startup log: $startupLog"

# 4. Poll discovery endpoint until ready (or timeout)
$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
$ready = $false
while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-RestMethod -Uri $discoveryUrl -TimeoutSec 3
        $ready = $true
        break
    } catch {
        Start-Sleep -Seconds 3
    }
}

if (-not $ready) {
    throw "Keycloak did not become ready within $ReadyTimeoutSeconds seconds. Check the startup log at $startupLog (and $startupErr)."
}

if ($RegisterStartupTask) { Register-KeycloakStartupTask -KcBat $kcBat -LogPath $startupLog }

Write-Host ""
Write-Host "SUCCESS: Keycloak running at $BaseUrl" -ForegroundColor Green
Write-Host "Admin user: $AdminUser (password as provided)"
Write-Host "PID: $($proc.Id) — close this terminal or stop the process to shut down."
Write-Host "To relaunch after a reboot: re-run this script, or (if you used -RegisterStartupTask) schtasks /run /tn 'Ed-Fi Admin App Keycloak'." -ForegroundColor DarkGray
