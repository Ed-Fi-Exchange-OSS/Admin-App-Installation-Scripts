#Requires -RunAsAdministrator
#requires -Version 5.1
<#
.SYNOPSIS
Tears down the optional local Keycloak identity provider that idp-keycloak-setup.ps1 stands up:
stops the Keycloak process, deletes the Keycloak install directory, and unsets the
Machine JAVA_HOME. The JDK install itself is left in place.

.DESCRIPTION
Steps (each best-effort, continues past individual failures):
  1. Stop any running Keycloak process (java.exe whose command line matches
     kc.bat / keycloak / quarkus, plus a java.exe listening on :8080).
  2. Delete the Keycloak install directory (unless -KeepKeycloakDownload).
  3. Unset the Machine environment variable JAVA_HOME.

Does NOT touch the JDK install, Node.js, SQL Server, IIS, or the AdminApp's own
state. Use uninstall.ps1 for the generic AdminApp teardown.

Prompts for confirmation by default. Pass -Force for non-interactive runs.

.PARAMETER KeycloakInstallPath
Default: C:\keycloak.

.PARAMETER KeepKeycloakDownload
Switch -- leave the Keycloak install directory in place (just stop the process and
unset JAVA_HOME).

.PARAMETER Force
Switch -- skip the confirmation prompt.

.EXAMPLE
.\uninstall-keycloak.ps1
.\uninstall-keycloak.ps1 -Force
.\uninstall-keycloak.ps1 -KeepKeycloakDownload
#>

param(
    [string]$KeycloakInstallPath = "C:\keycloak",
    [switch]$KeepKeycloakDownload,
    [switch]$Force
)

# Don't bail on the first non-terminating error -- this is a teardown, we want
# to push through and report at the end.
$ErrorActionPreference = 'Continue'
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
Write-Host "Keycloak (local identity provider) -- UNINSTALL" -ForegroundColor Magenta
Write-Host "This will remove:"
Write-Host "  - Running Keycloak process (java.exe matching kc.bat/keycloak/quarkus, plus the :8080 listener)"
Write-Host "  - Startup Scheduled Task 'Ed-Fi Admin App Keycloak' (if registered)"
if (-not $KeepKeycloakDownload) { Write-Host "  - $KeycloakInstallPath (Keycloak install directory)" }
Write-Host "  - Machine environment variable JAVA_HOME"
Write-Host ""
Write-Host "Leaves alone: the JDK install, Node.js, SQL Server, IIS, and the AdminApp's own state (use uninstall.ps1 for those)." -ForegroundColor DarkGray
Write-Host ""

if (-not $Force) {
    $reply = Read-Host "Proceed? (y/N)"
    if ($reply -notmatch '^[Yy]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }
}

# ========================================================
Write-Section "1. Stop Keycloak"
# ========================================================
$kcStopped = $false
$killedPids = @{}

# Find Keycloak by command line: java.exe whose args reference kc.bat / quarkus / keycloak.
# Doing this first (rather than the :8080 listener) avoids killing some unrelated
# app that happens to be bound to 8080.
try {
    $kcJava = Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'kc\.bat|keycloak|quarkus' }
    foreach ($p in $kcJava) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        $killedPids[$p.ProcessId] = $true
        Record "Stop java.exe process ID $($p.ProcessId)" "OK" "Keycloak match in command line"
        $kcStopped = $true
    }
} catch {
    Record "Stop java.exe (Keycloak)" "WARN" $_.Exception.Message
}

# Belt and braces: anything still listening on :8080 that's a java.exe gets stopped too.
# Other processes on :8080 are left alone (could be unrelated -- not ours to kill).
try {
    $listenerPid = (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
    if ($listenerPid -and -not $killedPids.ContainsKey($listenerPid)) {
        $proc = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'java') {
            Stop-Process -Id $listenerPid -Force -ErrorAction Stop
            Record "Stop java.exe listener on :8080 (process ID $listenerPid)" "OK"
            $kcStopped = $true
        } elseif ($proc) {
            Record "Listener on :8080 is $($proc.ProcessName) (process ID $listenerPid)" "SKIP" "Not java.exe -- leaving alone"
        }
    }
} catch {
    Record "Stop :8080 listener" "WARN" $_.Exception.Message
}

if (-not $kcStopped) {
    Record "Stop Keycloak" "SKIP" "No matching java.exe process found"
}

# ========================================================
Write-Section "1b. Startup task"
# ========================================================
# Remove the reboot-survival task registered by idp-keycloak-setup.ps1 (unless it ran
# with -SkipStartupTask). The startup script the task runs lives in the Keycloak install
# directory, which section 2 deletes. Use schtasks.exe rather than the
# Get/Unregister-ScheduledTask CIM cmdlets: those enumerate the whole task store and
# throw (0x80041318) if ANY unrelated task on the machine has XML the CIM provider
# can't parse, which would silently skip our teardown. schtasks targets the task by
# name and is unaffected.
try {
    $taskName = 'Ed-Fi Admin App Keycloak'
    & schtasks.exe /query /tn $taskName *> $null
    if ($LASTEXITCODE -eq 0) {
        & schtasks.exe /delete /tn $taskName /f *> $null
        if ($LASTEXITCODE -eq 0) {
            Record "Remove startup task '$taskName'" "OK"
        } else {
            Record "Remove startup task '$taskName'" "FAIL" "schtasks /delete exit $LASTEXITCODE"
        }
    } else {
        Record "Remove startup task '$taskName'" "SKIP" "Not registered"
    }
} catch {
    Record "Remove startup task" "WARN" $_.Exception.Message
}

# ========================================================
Write-Section "2. Keycloak install directory"
# ========================================================
if ($KeepKeycloakDownload) {
    Record "Delete $KeycloakInstallPath" "SKIP" "-KeepKeycloakDownload"
} elseif (Test-Path $KeycloakInstallPath) {
    try {
        Remove-Item -Path $KeycloakInstallPath -Recurse -Force -ErrorAction Stop
        Record "Delete $KeycloakInstallPath" "OK"
    } catch {
        Record "Delete $KeycloakInstallPath" "FAIL" $_.Exception.Message
    }
} else {
    Record "Delete $KeycloakInstallPath" "SKIP" "Not present"
}

# ========================================================
Write-Section "3. Environment"
# ========================================================
try {
    $cur = [Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
    if ($cur) {
        [Environment]::SetEnvironmentVariable("JAVA_HOME", $null, "Machine")
        Record "Unset Machine environment variable JAVA_HOME" "OK" "Was: $cur"
    } else {
        Record "Unset Machine environment variable JAVA_HOME" "SKIP" "Not set"
    }
} catch {
    Record "Unset Machine environment variable JAVA_HOME" "FAIL" $_.Exception.Message
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
    Write-Host "Open a fresh PowerShell window to pick up the cleared environment variables before re-installing." -ForegroundColor Yellow
    exit 0
}
