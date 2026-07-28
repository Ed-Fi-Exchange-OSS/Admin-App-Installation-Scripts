#Requires -RunAsAdministrator
<#
.SYNOPSIS
Optional local Identity Provider example. Installs a JDK if needed, downloads
Keycloak, starts it, and provisions the edfi realm, edfiadminapp client, and
test user. One run leaves a fully-ready local Keycloak for the Admin App.

.DESCRIPTION
The Admin App's authentication engine is provider-agnostic (generic OIDC discovery), so a
real deployment points it at whatever identity provider the organization runs. This script is
only the convenience path for a local dev install that wants Keycloak as the
example identity provider.

Steps (each idempotent):
  1. JDK: reuse an existing Java >= 17 already on PATH, otherwise install
     Microsoft OpenJDK 21 (Keycloak 26.6 supports Java 17, 21, or 25) and set
     JAVA_HOME / PATH. -JdkDownloadUrl forces an offline zip install instead.
  2. Download + extract Keycloak to -KeycloakInstallPath.
  3. Start Keycloak by delegating to idp-keycloak-start.ps1 (bootstraps the
     master admin on first start, waits for the discovery endpoint).
  4. Provision the realm, client (with redirect/origin URIs), optional audience
     mapper, and the test user via the Keycloak admin REST API.

.PARAMETER KeycloakInstallPath
Where Keycloak is installed. Default: C:\keycloak.

.PARAMETER KeycloakVersion
Keycloak release to download if not already present. Default: 26.6.1.

.PARAMETER KeycloakSha256
Expected SHA-256 of the Keycloak zip. The default version has a pinned hash, so
this is only needed when -KeycloakVersion is changed. Keycloak does not publish a
.sha256 sidecar; obtain the hash by verifying keycloak-<ver>.zip against the
official .zip.asc GPG signature or .zip.sha1 sidecar first.

.PARAMETER JdkDownloadUrl
Optional HTTPS URL to an OpenJDK zip. If provided, downloads/extracts it and sets
JAVA_HOME instead of using winget / an existing JDK. Requires -JdkSha256.

.PARAMETER JdkSha256
Expected SHA-256 of the JDK zip named by -JdkDownloadUrl. Required whenever
-JdkDownloadUrl is supplied so the download can be integrity-verified; get it from
the JDK vendor's checksum page.

.PARAMETER AdminUser
Master-realm admin username (bootstrapped on first start only). Default: admin.

.PARAMETER AdminPassword
Master-realm admin password.

.PARAMETER KeycloakBaseUrl
URL to probe and provision against. Default: http://localhost:8080.

.PARAMETER ReadyTimeoutSeconds
How long to wait for Keycloak to be reachable. Default: 120.

.PARAMETER RealmName
Default: edfi.

.PARAMETER ClientId
Default: edfiadminapp.

.PARAMETER ClientSecret
The secret to set on the client. Save it; you pass the same value to 05-deploy-api.ps1.

.PARAMETER FeBaseUrl / -ApiBaseUrl
Base URLs used to build the client's redirect/origin URIs. Default to the
standalone HTTPS sites (web application https://localhost:4443, API https://localhost:3443).

.PARAMETER TestUserEmail / -TestUserFirstName / -TestUserLastName / -TestUserPassword
The seeded test user. TestUserEmail must match the AdminApp database's seeded user.

.PARAMETER IncludeAudienceMapper
Switch -- add the audience mapper (only needed for bearer-token API access).

.PARAMETER EnableDirectAccessGrants
Switch -- enable the password grant (OAuth ROPC) on the client. Testing only;
sends user credentials straight to the token endpoint. The script warns if this
is combined with a non-localhost -KeycloakBaseUrl (a production/remote identity provider).

.PARAMETER SkipStartupTask
Switch -- do NOT register the Windows Scheduled Task that brings Keycloak back after a
reboot. The task is registered by default: without it Keycloak does not restart, and
the API (which registers its OIDC strategies once at startup and never retries) rejects
every login with 'Unknown authentication strategy'. Pass this to opt out. Remove an
already-registered task with schtasks /delete /tn 'Ed-Fi Admin App Keycloak' /f.

.PARAMETER ApiAppPoolName
IIS app pool the startup task recycles once Keycloak is ready, so the API re-registers
its OIDC strategy against a running identity provider. Default: EdFi-AdminApp-API (the
name 05-deploy-api.ps1 uses). When the app pool is absent the task logs it and skips
the recycle.

.EXAMPLE
.\idp-keycloak-setup.ps1 -AdminPassword 'admin' -ClientSecret 'mysecret123' -TestUserPassword 'TestUser123!'
#>

param(
    # --- JDK + Keycloak download/runtime ---
    [string]$KeycloakInstallPath = "C:\keycloak",
    [string]$KeycloakVersion = "26.6.1",
    [string]$KeycloakSha256,
    [string]$JdkDownloadUrl,
    [string]$JdkSha256,

    # --- Keycloak start + admin bootstrap ---
    [string]$AdminUser = "admin",

    [Parameter(Mandatory = $true)]
    [SecureString]$AdminPassword,

    [string]$KeycloakBaseUrl = "http://localhost:8080",
    [int]$ReadyTimeoutSeconds = 120,

    # --- Realm / client / user provisioning ---
    [string]$RealmName = "edfi",
    [string]$ClientId = "edfiadminapp",

    [Parameter(Mandatory = $true)]
    [SecureString]$ClientSecret,

    # Defaults match the always-on-TLS standalone sites (web application on 4443, API on 3443).
    # The client's redirect and web-origin URIs are built from these.
    [string]$FeBaseUrl = "https://localhost:4443",
    [string]$ApiBaseUrl = "https://localhost:3443",

    # The app builds its OIDC callback as /api/auth/callback/<oidc-row-id> from the
    # auto-generated id of the seeded oidc row (oidc.strategy.ts). On a clean install
    # that id is 1; install-all reads the real id back after boot and re-runs this
    # script with -RedirectCallbackId when it differs, so the client's redirect URI
    # matches what the app actually sends (PR #234 Functionality review, Gap B).
    [int]$RedirectCallbackId = 1,
    [string]$TestUserEmail = "admin@example.com",
    [string]$TestUserFirstName = "Admin",
    [string]$TestUserLastName  = "User",

    [Parameter(Mandatory = $true)]
    [SecureString]$TestUserPassword,

    # Realm display + session settings (Ed-Fi docs defaults). Tune per environment if
    # needed. Offline session max requires offlineSessionMaxLifespanEnabled.
    [string]$RealmDisplayName     = "Ed-Fi",
    [string]$RealmDisplayNameHtml = "Ed-Fi Technology Suite",
    [int]$SsoSessionIdleSeconds     = 7200,        # 2h
    [int]$SsoSessionMaxSeconds      = 7200,        # 2h
    [int]$ClientSessionIdleSeconds  = 7200,        # 2h
    [int]$ClientSessionMaxSeconds   = 7200,        # 2h
    [int]$OfflineSessionIdleSeconds = 2592000,     # 30d
    [int]$OfflineSessionMaxSeconds  = 5184000,     # 60d

    [switch]$IncludeAudienceMapper,
    [switch]$EnableDirectAccessGrants,

    # Opt OUT of the startup Scheduled Task. Registering it is the default: this script
    # already requires elevation, and without the task Keycloak does not come back after
    # a reboot, which leaves the Admin App unable to authenticate anyone.
    [switch]$SkipStartupTask,

    # The IIS app pool the startup task recycles once Keycloak is ready, so the API
    # re-registers its OIDC strategy against a live identity provider. Default matches
    # 05-deploy-api.ps1 (-AppPoolName).
    [string]$ApiAppPoolName = "EdFi-AdminApp-API"
)

$ErrorActionPreference = 'Stop'

# Direct Access Grants (OAuth password/ROPC grant) is a testing convenience only:
# it sends user credentials straight to the token endpoint. Warn loudly if it is
# enabled against a non-loopback Keycloak, which signals a real/remote deployment.
if ($EnableDirectAccessGrants) {
    $kcHost = ([Uri]$KeycloakBaseUrl).Host.Trim('[', ']')
    $ip = $null
    $isLoopback = ($kcHost -eq 'localhost') -or
        ([System.Net.IPAddress]::TryParse($kcHost, [ref]$ip) -and [System.Net.IPAddress]::IsLoopback($ip))
    if (-not $isLoopback) {
        Write-Warning "Direct Access Grants (OAuth password grant) is enabled on a non-localhost Keycloak ($KeycloakBaseUrl). This flow sends user credentials directly to the token endpoint and is intended for local testing only -- do not enable it against a production or remote identity provider (IdP)."
    }
}

# --- Verified download helpers -------------------------------------------------
# Duplicated across the windows-install scripts (no shared module in this folder,
# matching the existing WET pattern). Mirrors Install-VerifiedMsi in
# 01-prereqs-iis.ps1: reuse an already-downloaded file only when its SHA-256
# matches, otherwise (re)download and verify, aborting on a mismatch.
function Save-VerifiedDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$OutFile
    )
    $needsDownload = $true
    if (Test-Path $OutFile) {
        if ((Get-FileHash -Path $OutFile -Algorithm SHA256).Hash -ieq $Sha256) {
            Write-Host "$Name already downloaded and verified -- reusing $OutFile."
            $needsDownload = $false
        } else {
            Write-Host "$Name at $OutFile failed the expected hash (corrupt/partial/stale?); re-downloading." -ForegroundColor Yellow
            Remove-Item $OutFile -Force
        }
    }
    if ($needsDownload) {
        Write-Host "Downloading $Name from $Url ..."
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        } catch {
            throw "Failed to download $Name from $Url. Check internet connectivity and that the URL is reachable. Original: $($_.Exception.Message)"
        }
        $actual = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
        if ($actual -ine $Sha256) {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            throw "$Name failed SHA-256 verification.`n  Expected: $Sha256`n  Actual:   $actual`nThe download may be corrupt or tampered with; aborting."
        }
        Write-Host "$Name verified (SHA-256 match)."
    }
}

# Pinned SHA-256 per Keycloak release. Keycloak does not publish a .sha256 sidecar,
# so the default version is pinned here (verified against the official .zip.sha1
# sidecar). Other versions require -KeycloakSha256.
$KnownKeycloakSha256 = @{
    '26.6.1' = '30224D2B3A0F13562CB01F92207338AFB5BAD9D6F1495EC1C182F8B72D82342E'
}
function Resolve-KeycloakSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$Override
    )
    if ($Override) { return $Override }
    if ($KnownKeycloakSha256.ContainsKey($Version)) { return $KnownKeycloakSha256[$Version] }
    throw "No pinned SHA-256 for Keycloak $Version. Keycloak publishes no .sha256 sidecar, so pass -KeycloakSha256 with the SHA-256 of keycloak-$Version.zip (verify it against the official keycloak-$Version.zip.asc GPG signature or .zip.sha1 sidecar first)."
}

# Resolve kc.bat under the install path, accepting a flat OR a nested (versioned)
# layout. Returns $null when Keycloak has not been extracted yet.
function Resolve-KcBat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallPath)
    if (Test-Path (Join-Path $InstallPath 'bin\kc.bat')) {
        return (Join-Path $InstallPath 'bin\kc.bat')
    }
    $sub = Get-ChildItem $InstallPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path "$($_.FullName)\bin\kc.bat" } |
        Select-Object -First 1
    if ($sub) { return "$($sub.FullName)\bin\kc.bat" }
    return $null
}

# --- Startup task ---------------------------------------------------------------
# Registering the boot task lives here rather than in idp-keycloak-start.ps1 for two
# reasons: this script already requires elevation, and the task needs the realm and API
# app pool names, which are provisioning concerns this script owns. idp-keycloak-start
# stays a plain "launch Keycloak" script that runs unelevated.

# Resolve a concrete JDK home to bake into the generated startup script. A task running
# as SYSTEM sees only machine-scope environment variables, and kc.bat falls back to bare
# 'java' from PATH when JAVA_HOME is unset -- which fails on a host where the JDK is only
# on the interactive user's PATH. The JDK step above writes machine JAVA_HOME only when
# it installs OpenJDK itself, so it cannot be relied on. Returns $null when nothing
# usable is found; the caller degrades to the PATH fallback with a warning.
function Resolve-JavaHome {
    [CmdletBinding()]
    param()
    foreach ($candidate in @([Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine'), $env:JAVA_HOME)) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'bin\java.exe'))) { return $candidate }
    }
    $javaCommand = Get-Command java -ErrorAction SilentlyContinue
    if ($javaCommand) {
        # <jdk>\bin\java.exe -> <jdk>
        $candidate = Split-Path (Split-Path $javaCommand.Source -Parent) -Parent
        if ($candidate -and (Test-Path (Join-Path $candidate 'bin\java.exe'))) { return $candidate }
    }
    return $null
}

# Write the script the startup task executes. Kept as a generated file rather than
# inlined into the task's Arguments for two reasons: the readiness poll and the app pool
# recycle need real PowerShell, and a quoted command line nested inside cmd.exe quoting
# is fragile. The file is also runnable by hand, which makes a failed boot diagnosable.
#
# The script deliberately outlives the readiness gate: it waits on the Keycloak process,
# so the task stays running for as long as Keycloak does (which is what
# ExecutionTimeLimit PT0S allows) and the task result reflects whether Keycloak is
# still up, not just whether it launched.
function Write-KeycloakStartupScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$KcBat,
        [Parameter(Mandatory)][string]$KeycloakLogPath,
        [Parameter(Mandatory)][string]$TaskLogPath,
        [Parameter(Mandatory)][string]$DiscoveryUrl,
        [Parameter(Mandatory)][string]$ApiAppPoolName,
        [Parameter(Mandatory)][int]$ReadyTimeoutSeconds,
        [AllowEmptyString()][string]$JavaHome
    )
    # Single-quoted here-string: every $ below belongs to the generated script, not to
    # this one. Values are injected with String.Replace so a '$' or a regex
    # metacharacter in a path cannot corrupt the result.
    $template = @'
# Generated by idp-keycloak-setup.ps1. Re-run that script to regenerate; edits made
# here are overwritten.
#
# Runs at system startup as SYSTEM. Starts Keycloak, waits until the realm's OIDC
# discovery endpoint answers, then recycles the Admin App API app pool so the API
# registers its OIDC strategy against a live Keycloak -- the API registers strategies
# once at startup and never retries, so an API that started first would reject every
# login with 'Unknown authentication strategy'.

# Continue past non-terminating errors: a boot script that aborts silently is worse
# than one that logs and carries on to the next step.
$ErrorActionPreference = 'Continue'

$kcBat               = '__KC_BAT__'
$javaHome            = '__JAVA_HOME__'
$keycloakLogPath     = '__KEYCLOAK_LOG__'
$taskLogPath         = '__TASK_LOG__'
$discoveryUrl        = '__DISCOVERY_URL__'
$apiAppPoolName      = '__API_APP_POOL__'
$readyTimeoutSeconds = __READY_TIMEOUT__

function Write-TaskLog {
    param([Parameter(Mandatory)][string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" | Add-Content -LiteralPath $taskLogPath
}

Write-TaskLog "Startup task begin."

# kc.bat prefers JAVA_HOME over the PATH lookup, so setting it here makes the task
# independent of which PATH scope the JDK happens to be on.
if ($javaHome) {
    $env:JAVA_HOME = $javaHome
    Write-TaskLog "JAVA_HOME set to $javaHome"
} else {
    Write-TaskLog "No JDK path was resolved at registration time; kc.bat will fall back to 'java' on the machine PATH."
}

$keycloak = Start-Process -FilePath $kcBat -ArgumentList 'start-dev' `
    -WorkingDirectory (Split-Path $kcBat -Parent) `
    -RedirectStandardOutput $keycloakLogPath -RedirectStandardError "$keycloakLogPath.err" `
    -WindowStyle Hidden -PassThru
# Start-Process does not retain the process handle when output is redirected, so
# ExitCode reads back as $null once the process ends. Touching .Handle caches it.
# Without this the task always exits 0 and the log records an empty exit code, so a
# dead Keycloak is indistinguishable from a clean shutdown.
$null = $keycloak.Handle
Write-TaskLog "Launched '$kcBat start-dev' (process ID $($keycloak.Id))."

# Health gate: wait for the realm the Admin App actually authenticates against, not
# just an open port. Mirrors the realm-level healthcheck the Ed-Fi Docker reference
# uses before it starts the API.
$deadline = (Get-Date).AddSeconds($readyTimeoutSeconds)
$ready = $false
while ((Get-Date) -lt $deadline) {
    if ($keycloak.HasExited) {
        Write-TaskLog "Keycloak exited during startup with code $($keycloak.ExitCode); see $keycloakLogPath."
        exit 1
    }
    try {
        Invoke-RestMethod -Uri $discoveryUrl -TimeoutSec 5 | Out-Null
        $ready = $true
        break
    } catch {
        Start-Sleep -Seconds 5
    }
}

if ($ready) {
    Write-TaskLog "Keycloak ready at $discoveryUrl"
    # Recycling kills any Node process that started before Keycloak was reachable; the
    # next request spawns one that discovers the realm successfully.
    try {
        Import-Module WebAdministration -ErrorAction Stop
        if (Test-Path "IIS:\AppPools\$apiAppPoolName") {
            Restart-WebAppPool -Name $apiAppPoolName
            Write-TaskLog "Recycled app pool '$apiAppPoolName'."
        } else {
            Write-TaskLog "App pool '$apiAppPoolName' not found; skipping the recycle (Keycloak-only install)."
        }
    } catch {
        Write-TaskLog "Could not recycle app pool '$apiAppPoolName': $($_.Exception.Message)"
    }
} else {
    Write-TaskLog "Keycloak did not answer $discoveryUrl within $readyTimeoutSeconds seconds; skipping the API app pool recycle. Keycloak is left running."
}

# Stay alive for Keycloak's lifetime so the task represents the running server.
$keycloak.WaitForExit()
$exitCode = $keycloak.ExitCode
if ($null -eq $exitCode) {
    Write-TaskLog "Keycloak stopped without reporting an exit code; treating it as a failure so the task does not record a false success."
    $exitCode = 1
} else {
    Write-TaskLog "Keycloak exited with code $exitCode."
}
exit $exitCode
'@
    $rendered = $template.
        Replace('__KC_BAT__',        $KcBat).
        Replace('__JAVA_HOME__',     $JavaHome).
        Replace('__KEYCLOAK_LOG__',  $KeycloakLogPath).
        Replace('__TASK_LOG__',      $TaskLogPath).
        Replace('__DISCOVERY_URL__', $DiscoveryUrl).
        Replace('__API_APP_POOL__',  $ApiAppPoolName).
        Replace('__READY_TIMEOUT__', $ReadyTimeoutSeconds.ToString())
    Set-Content -LiteralPath $ScriptPath -Value $rendered -Encoding UTF8
}

# Register the startup Scheduled Task. Idempotent -- TASK_CREATE_OR_UPDATE overwrites any
# existing task of the same name.
function Register-KeycloakStartupTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KcBat,
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][string]$DiscoveryUrl,
        [Parameter(Mandatory)][string]$ApiAppPoolName,
        [Parameter(Mandatory)][int]$ReadyTimeoutSeconds
    )
    $taskName = 'Ed-Fi Admin App Keycloak'
    $startupScriptPath = Join-Path $InstallPath 'edfi-keycloak-startup.ps1'
    $keycloakLogPath = Join-Path $InstallPath 'keycloak-startup.log'
    $taskLogPath = Join-Path $InstallPath 'keycloak-startup-task.log'

    $javaHome = Resolve-JavaHome
    Write-KeycloakStartupScript -ScriptPath $startupScriptPath -KcBat $KcBat `
        -KeycloakLogPath $keycloakLogPath -TaskLogPath $taskLogPath -DiscoveryUrl $DiscoveryUrl `
        -ApiAppPoolName $ApiAppPoolName -ReadyTimeoutSeconds $ReadyTimeoutSeconds `
        -JavaHome ([string]$javaHome)
    if ($javaHome) {
        Write-Host "Startup script will run Keycloak with JAVA_HOME=$javaHome"
    } else {
        Write-Warning "No JDK path could be resolved for the startup task; it will rely on 'java' being on the machine PATH."
    }

    # Register through the Task Scheduler COM API. Neither Register-ScheduledTask (the
    # ScheduledTasks CIM module) nor schtasks.exe /create /xml can persist a SYSTEM
    # service-account principal: both store
    # <LogonType>InteractiveToken</LogonType> next to the SYSTEM SID, and omitting the
    # element from the XML does not help because the service normalizes it to
    # InteractiveToken on save. That pairing is self-contradictory -- SYSTEM has no
    # interactive token -- so the task cannot be read back by the CIM provider
    # (Get-ScheduledTask fails with SCHED_E_INVALIDVALUE, 0x80041318) and has no valid
    # token to run with at boot, where no interactive session exists.
    #
    # RegisterTask takes the logon type as an explicit argument, which is the only way to
    # persist TASK_LOGON_SERVICE_ACCOUNT. <LogonType> stays out of the XML because the
    # schema's enumeration has no 'ServiceAccount' member -- the argument supplies it.
    # The S-1-5-18 SID rather than the 'SYSTEM' account name also keeps registration
    # working on non-English Windows.
    #
    # Schema 1.2 (Windows 8 / Server 2012+) rather than 1.3: only 1.2-era elements are
    # used, so the lower version widens the supported OS range at no cost.
    # ExecutionTimeLimit PT0S -> no time limit, so the task is not killed after the
    # default 3-day cap; it runs for as long as Keycloak does.
    # RestartOnFailure is kept as a best-effort safety net on the boot path. Do not rely
    # on it: Task Scheduler was measured not to act on a non-zero action result.
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $escapedCommand = [System.Security.SecurityElement]::Escape($powerShellPath)
    $escapedArguments = [System.Security.SecurityElement]::Escape(
        "-NoProfile -ExecutionPolicy Bypass -File `"$startupScriptPath`"")
    $escapedWorkingDirectory = [System.Security.SecurityElement]::Escape($InstallPath)
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Starts the Ed-Fi Admin App example Keycloak identity provider at system startup, then recycles the Admin App API app pool so the API registers its OIDC strategy against a running Keycloak.</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedCommand</Command>
      <Arguments>$escapedArguments</Arguments>
      <WorkingDirectory>$escapedWorkingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
    # TASK_CREATE_OR_UPDATE makes re-registration idempotent; the password argument is
    # unused for a service account.
    $taskCreateOrUpdate = 6
    $taskLogonServiceAccount = 5
    $scheduler = New-Object -ComObject Schedule.Service
    try {
        $scheduler.Connect()
        $scheduler.GetFolder('\').RegisterTask(
            $taskName, $taskXml, $taskCreateOrUpdate, 'S-1-5-18', $null, $taskLogonServiceAccount, $null) | Out-Null
    } catch {
        throw "Failed to register the startup task '$taskName': $($_.Exception.Message)"
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($scheduler)
    }

    # Confirm the logon type actually persisted -- this is the exact value the CIM
    # provider rejects when it is wrong, and a silent regression here would only show up
    # as a failed boot.
    $persisted = ([xml](Get-Content -LiteralPath "$env:SystemRoot\System32\Tasks\$taskName" -Raw)).Task.Principals.Principal
    if ($persisted.PSObject.Properties['LogonType'] -and $persisted.LogonType -ne 'ServiceAccount') {
        Write-Warning "The startup task registered with LogonType '$($persisted.LogonType)' instead of ServiceAccount. It may fail to start at boot; check Task Scheduler history for '$taskName'."
    }

    Write-Host "Registered startup task '$taskName' (runs as SYSTEM at boot)." -ForegroundColor Green
    Write-Host "  Startup script: $startupScriptPath" -ForegroundColor DarkGray
    Write-Host "  Task log:       $taskLogPath" -ForegroundColor DarkGray
    Write-Host "  At boot it starts Keycloak, waits for $DiscoveryUrl, then recycles app pool '$ApiAppPoolName'." -ForegroundColor DarkGray
    Write-Host "  Remove it with: schtasks /delete /tn '$taskName' /f" -ForegroundColor DarkGray
}

# Secrets arrive as SecureString (kept off the command line); unwrap to plaintext
# locals for the Keycloak admin REST calls and client/user provisioning.
# AdminPassword stays a SecureString because it is delegated on to
# idp-keycloak-start.ps1 (also SecureString); only the local REST body uses the
# unwrapped copy.
$AdminPasswordPlain = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
$ClientSecretPlain     = [System.Net.NetworkCredential]::new('', $ClientSecret).Password
$TestUserPasswordPlain = [System.Net.NetworkCredential]::new('', $TestUserPassword).Password

# JDK -- Keycloak 26.6 officially supports Java 17, 21, or 25. Behavior in order:
#   1. If `java` >=17 is already on PATH, USE IT. Skip the OpenJDK 21 install
#      and the PATH/JAVA_HOME overrides -- respects users who keep a newer JDK
#      (25, 26, ...) for other dev work. Keycloak runs at JVM level, so any
#      modern JDK works in practice even if not officially supported.
#   2. Otherwise install Microsoft OpenJDK 21 via winget and prepend its bin
#      to Machine PATH so Keycloak has a working JDK.
#   3. -JdkDownloadUrl overrides everything: skips both checks and downloads
#      a zip (offline scenarios).

# Step 1: detect existing usable Java
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$existingJava = Get-Command java -ErrorAction SilentlyContinue
$existingJavaMajor = 0
if ($existingJava) {
    # `java -version` writes to stderr. Route the merge through cmd.exe rather
    # than PowerShell's `2>&1`, because in Windows PowerShell 5.1 redirecting a
    # native command's stderr inside PS wraps each line as a NativeCommandError
    # ErrorRecord, which is fatal under the parent script's
    # $ErrorActionPreference='Stop'. cmd /c merges the streams before PS ever
    # sees them, so the output arrives as plain strings.
    $javaVerLine = (& cmd /c "java -version 2>&1") | Select-Object -First 1
    if ($javaVerLine -match 'version "(\d+)') {
        $existingJavaMajor = [int]$Matches[1]
    } elseif ($javaVerLine -match 'version "1\.(\d+)') {
        $existingJavaMajor = [int]$Matches[1]   # 1.8.0_xxx style
    }
}

$openJdk21Root = $null
if ($existingJavaMajor -ge 17 -and -not $JdkDownloadUrl) {
    Write-Host "Java $existingJavaMajor already on PATH at $($existingJava.Source) -- skipping OpenJDK 21 install."
    Write-Host "Keycloak will run on the existing JDK. (To force install OpenJDK 21 anyway,"
    Write-Host "remove your current Java from PATH before re-running, or pass -JdkDownloadUrl.)"
} else {
    # Heads-up before mutating the machine's Java: installing/prepending OpenJDK 21
    # changes what `java` resolves to and overwrites Machine JAVA_HOME. (This moved
    # here from 00-check-prereqs.ps1, which is now generic and Keycloak-free.)
    if ($existingJava) {
        Write-Host "NOTE: Java $existingJavaMajor is on PATH at $($existingJava.Source); OpenJDK 21 will be prepended so 'java' resolves to it." -ForegroundColor Yellow
    }
    $existingJavaHome = [Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
    if ($existingJavaHome -and ($existingJavaHome -notlike "*Microsoft\jdk-21*")) {
        Write-Host "NOTE: Machine JAVA_HOME ($existingJavaHome) will be overwritten with the OpenJDK 21 path." -ForegroundColor Yellow
    }

    # Step 2: install / locate OpenJDK 21. Match jdk-21* directories that actually
    # contain a runnable java.exe -- a leftover half-install can't fool us.
    $existing21 = Get-ChildItem "C:\Program Files\Microsoft" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "jdk-21*" -and (Test-Path "$($_.FullName)\bin\java.exe") } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($existing21) {
        $openJdk21Root = $existing21.FullName
        Write-Host "OpenJDK 21 already installed at $openJdk21Root"
    } elseif (-not $JdkDownloadUrl) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw "winget (the Windows Package Manager) is required to install OpenJDK 21, but it is not on PATH. Windows 10/11 include it; on Windows Server 2019/2022 install it first (see the prerequisites) and re-run, or pass -JdkDownloadUrl to install from a zip instead."
        }
        Write-Host "Installing OpenJDK 21 via winget (Keycloak runtime)..."
        & winget install Microsoft.OpenJDK.21 --source winget --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -ne 0) {
            throw "OpenJDK install failed (winget exit code $LASTEXITCODE). Pass -JdkDownloadUrl to install from a zip instead."
        }
        $existing21 = Get-ChildItem "C:\Program Files\Microsoft" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "jdk-21*" -and (Test-Path "$($_.FullName)\bin\java.exe") } |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($existing21) { $openJdk21Root = $existing21.FullName }
        if (-not $openJdk21Root) {
            throw "winget reported success but no jdk-21*\bin\java.exe found under C:\Program Files\Microsoft. Pass -JdkDownloadUrl or install OpenJDK 21 manually."
        }
        Write-Host "OpenJDK 21 installed at $openJdk21Root"
    }
}

# Step 3: PATH prepend + JAVA_HOME -- only when we installed/located OpenJDK 21
# (i.e., we did NOT take the "existing Java is fine" early-out).
if ($openJdk21Root) {
    $newJdkBin = "$openJdk21Root\bin"
    $mp = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $entries = $mp -split ';' | Where-Object { $_ -and $_ -ne $newJdkBin }
    $newPath = (@($newJdkBin) + $entries) -join ';'
    if ($mp -ne $newPath) {
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        Write-Host "Prepended $newJdkBin to Machine PATH."
    }
    [Environment]::SetEnvironmentVariable("JAVA_HOME", $openJdk21Root, "Machine")
    # Refresh in current process so idp-keycloak-start can spawn Keycloak with the right java
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $env:JAVA_HOME = $openJdk21Root
}

# Keycloak -- accept flat OR nested (BasePath\keycloak-<ver>\bin\kc.bat) layout
$existingKcBat = Resolve-KcBat -InstallPath $KeycloakInstallPath
if ($existingKcBat) {
    Write-Host "Keycloak already installed at $existingKcBat"
} else {
    $kcZip = "$env:TEMP\keycloak-$KeycloakVersion.zip"
    $kcUrl = "https://github.com/keycloak/keycloak/releases/download/$KeycloakVersion/keycloak-$KeycloakVersion.zip"
    $kcSha = Resolve-KeycloakSha256 -Version $KeycloakVersion -Override $KeycloakSha256
    Save-VerifiedDownload -Name "Keycloak $KeycloakVersion" -Url $kcUrl -Sha256 $kcSha -OutFile $kcZip
    $parent = Split-Path $KeycloakInstallPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Write-Host "Extracting to $KeycloakInstallPath..."
    Expand-Archive -Path $kcZip -DestinationPath $parent -Force
    $extracted = Join-Path $parent "keycloak-$KeycloakVersion"
    if ((Test-Path $extracted) -and ($extracted -ne $KeycloakInstallPath)) {
        Move-Item -Path $extracted -Destination $KeycloakInstallPath
    }
    Write-Host "Keycloak ready at $KeycloakInstallPath"
}

# Optional JDK
if ($JdkDownloadUrl) {
    if ($JdkDownloadUrl -notmatch '^https://') {
        throw "-JdkDownloadUrl must be an HTTPS URL (got '$JdkDownloadUrl'); refusing to fetch a JDK over an unencrypted channel."
    }
    if (-not $JdkSha256) {
        throw "-JdkDownloadUrl requires -JdkSha256 (the expected SHA-256 of the JDK zip) so the download can be integrity-verified. Get it from the JDK vendor's checksum page."
    }
    $jdkZip = "$env:TEMP\jdk-download.zip"
    Save-VerifiedDownload -Name "JDK" -Url $JdkDownloadUrl -Sha256 $JdkSha256 -OutFile $jdkZip
    $jdkParent = "C:\Program Files\Java"
    New-Item -ItemType Directory -Path $jdkParent -Force | Out-Null
    Expand-Archive -Path $jdkZip -DestinationPath $jdkParent -Force
    $jdkDir = Get-ChildItem $jdkParent -Directory | Where-Object { $_.Name -like "jdk-*" } | Sort-Object Name -Descending | Select-Object -First 1
    if ($jdkDir) {
        [Environment]::SetEnvironmentVariable("JAVA_HOME", $jdkDir.FullName, "Machine")
        $mp = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $newBin = "$($jdkDir.FullName)\bin"
        if ($mp -notlike "*$newBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$newBin;$mp", "Machine")
        }
        Write-Host "JAVA_HOME = $($jdkDir.FullName)"
    }
}

# ---------------------------------------------------------------------------
# Start Keycloak (delegates to idp-keycloak-start.ps1) and wait until the admin
# REST API is reachable, then provision the realm/client/user below.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Starting Keycloak via idp-keycloak-start.ps1..."
& "$PSScriptRoot\idp-keycloak-start.ps1" `
    -KeycloakInstallPath $KeycloakInstallPath `
    -AdminUser $AdminUser `
    -AdminPassword $AdminPassword `
    -BaseUrl $KeycloakBaseUrl `
    -ReadyTimeoutSeconds $ReadyTimeoutSeconds

function Invoke-KcApi {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body
    )
    $h = @{ Authorization = "Bearer $script:token" }
    $params = @{
        Uri = "$KeycloakBaseUrl/admin$Path"
        Method = $Method
        Headers = $h
    }
    if ($Body) {
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $params.ContentType = "application/json"
    }
    Invoke-RestMethod @params
}

# Get admin token. Catch invalid_grant specifically (401 from Keycloak) so the
# user gets actionable recovery steps instead of a raw WebException. This is
# the most common 06 failure mode -- the master admin was bootstrapped with a
# different password than what -KeycloakAdminPassword now carries, because
# KC_BOOTSTRAP_ADMIN_* environment variables are first-run-only.
Write-Host "Authenticating to Keycloak admin API..."
try {
    # Pass the form as a hashtable so Invoke-RestMethod URL-encodes each field:
    # a &, =, +, %, or # in the admin password would otherwise corrupt a
    # hand-built body and surface as a misleading invalid_grant.
    $tokenResp = Invoke-RestMethod -Uri "$KeycloakBaseUrl/realms/master/protocol/openid-connect/token" `
        -Method Post `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{
            grant_type = "password"
            client_id  = "admin-cli"
            username   = $AdminUser
            password   = $AdminPasswordPlain
        } `
        -ErrorAction Stop
} catch {
    # Untyped catch -- PS 5.1's Invoke-RestMethod wraps HTTP errors variably
    # (WebException, HttpResponseException, CmdletInvocationException, etc.).
    # Pull the response off whichever shape the exception came in, and prefer
    # $_.ErrorDetails.Message for the body since PS auto-populates it.
    $resp = $null
    if ($_.Exception.Response) {
        $resp = $_.Exception.Response
    } elseif ($_.Exception.InnerException -and $_.Exception.InnerException.Response) {
        $resp = $_.Exception.InnerException.Response
    }
    $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
    $body = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
    if (-not $body -and $resp) {
        try {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd()
        } catch {}
    }

    if ($code -eq 401 -or $body -match 'invalid_grant') {
        Write-Host ""
        Write-Host "[ERROR] Keycloak admin auth failed (HTTP $code, invalid_grant)." -ForegroundColor Red
        Write-Host "        The master admin was bootstrapped with a different password than the"
        Write-Host "        one passed via -KeycloakAdminPassword. Keycloak 26's KC_BOOTSTRAP_ADMIN_*"
        Write-Host "        environment variables only apply on first run against an empty data directory."
        Write-Host ""
        Write-Host "        Recovery options:" -ForegroundColor Yellow
        Write-Host "          A) Re-run install-all with the ORIGINAL admin password."
        Write-Host "          B) Wipe Keycloak data and bootstrap fresh (loses realm/client/user --"
        Write-Host "             install-all recreates them automatically):"
        Write-Host "               Stop-Process -Name java -Force -ErrorAction SilentlyContinue"
        Write-Host "               Remove-Item -Recurse -Force C:\keycloak\data"
        Write-Host "               .\install-all.ps1 ... -KeycloakAdminPassword '<new-pw>' -SkipPhase1"
        Write-Host ""
        throw "Keycloak admin auth failed -- see recovery options above."
    }
    # Any other web error: re-throw with the body for diagnostics
    if ($body) { Write-Host "Response body: $body" -ForegroundColor DarkGray }
    throw
}
$script:token = $tokenResp.access_token
Write-Host "Authenticated."

# Realm
$realms = Invoke-KcApi -Method Get -Path "/realms"
if (($realms | ForEach-Object { $_.realm }) -contains $RealmName) {
    Write-Host "Realm '$RealmName' already exists."
} else {
    Write-Host "Creating realm '$RealmName'..."
    Invoke-KcApi -Method Post -Path "/realms" -Body @{ realm = $RealmName; enabled = $true } | Out-Null
}

# Apply realm display + session settings idempotently. Fetch current values,
# compare against desired, PUT only on drift. Matches the doc-recommended
# Ed-Fi realm configuration (display name, 2h SSO + client sessions, 30d/60d
# offline). Override individual values via the corresponding script params.
$currentRealm = Invoke-KcApi -Method Get -Path "/realms/$RealmName"
$realmDesired = [ordered]@{
    realm                            = $RealmName
    enabled                          = $true
    displayName                      = $RealmDisplayName
    displayNameHtml                  = $RealmDisplayNameHtml
    ssoSessionIdleTimeout            = $SsoSessionIdleSeconds
    ssoSessionMaxLifespan            = $SsoSessionMaxSeconds
    clientSessionIdleTimeout         = $ClientSessionIdleSeconds
    clientSessionMaxLifespan         = $ClientSessionMaxSeconds
    offlineSessionIdleTimeout        = $OfflineSessionIdleSeconds
    offlineSessionMaxLifespan        = $OfflineSessionMaxSeconds
    offlineSessionMaxLifespanEnabled = $true
}
$realmNeedsUpdate = $false
foreach ($key in $realmDesired.Keys) {
    if ($key -eq 'realm') { continue }  # immutable; included in payload for shape
    $current = $currentRealm.$key
    $want    = $realmDesired[$key]
    if ($current -ne $want) {
        $realmNeedsUpdate = $true
        break
    }
}
if ($realmNeedsUpdate) {
    Write-Host "Applying Ed-Fi realm settings (display + session timeouts)..."
    Invoke-KcApi -Method Put -Path "/realms/$RealmName" -Body $realmDesired | Out-Null
    Write-Host "Realm settings applied."
} else {
    Write-Host "Realm settings already match desired values -- skipping update."
}

# Client
$clients = Invoke-KcApi -Method Get -Path "/realms/$RealmName/clients?clientId=$ClientId"

# Build the JSON payload manually (PS 5.1 ConvertTo-Json unwraps single-element
# arrays inside hashtables, which silently breaks redirectUris and webOrigins).
# Values match the Ed-Fi docs:
#   Root URL                  = the origin
#   Admin URL                 = web application base
#   Valid Redirect URIs       = API callback + web application callback + API post-logout (no wildcard)
#   Valid Post Logout URIs    = API post-logout endpoint only. The app always sends
#                               MY_URL/api/auth/post-logout as its post_logout_redirect_uri
#                               (auth.controller.ts), then forwards to the web application itself, so no
#                               web application URI needs to be pre-registered. (Keycloak 26 separates
#                               these from Valid Redirect URIs; multiple URIs joined "##".)
#   Web Origins               = API base (for CORS on the OIDC endpoints)
$fe  = $FeBaseUrl  -replace '/$', ''
$api = $ApiBaseUrl -replace '/$', ''

$dagJson = if ($EnableDirectAccessGrants) { 'true' } else { 'false' }

$clientPayloadJson = @"
{
  "clientId": "$ClientId",
  "secret": "$ClientSecretPlain",
  "rootUrl": "$fe/",
  "baseUrl": "",
  "adminUrl": "$fe",
  "redirectUris": [
    "$api/api/auth/callback/$RedirectCallbackId",
    "$fe/auth/callback",
    "$api/api/auth/post-logout"
  ],
  "webOrigins": ["$api"],
  "attributes": {
    "post.logout.redirect.uris": "$api/api/auth/post-logout"
  },
  "publicClient": false,
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": $dagJson,
  "serviceAccountsEnabled": false,
  "implicitFlowEnabled": false,
  "authorizationServicesEnabled": false,
  "protocol": "openid-connect"
}
"@

# Keycloak omits boolean/array client properties from the client JSON when they
# are false/empty, so a direct `$client.<prop>` read throws under
# Set-StrictMode -Version Latest. Read optional properties through this guard so
# the client-diff below stays StrictMode-safe (a missing property reads as $null,
# which the comparisons already treat as "off"/"empty").
function Get-KcClientProp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Client.PSObject.Properties[$Name]) { return $Client.$Name }
    return $null
}

if ($clients.Count -gt 0) {
    $clientUuid = $clients[0].id
    $existing = $clients[0]
    # Compare key fields; skip the PUT if nothing meaningful differs.
    $expectedRedirect = "$api/api/auth/callback/$RedirectCallbackId"
    $redirectUris = Get-KcClientProp $existing 'redirectUris'
    $webOrigins   = Get-KcClientProp $existing 'webOrigins'
    $needsUpdate = $false
    if (-not $redirectUris -or ($redirectUris -notcontains $expectedRedirect)) { $needsUpdate = $true }
    if (-not $webOrigins -or ($webOrigins -notcontains $api)) { $needsUpdate = $true }
    # Force a rewrite if a wildcard redirect from an earlier install survives, so the
    # PUT strips it (redirectUris and the post-logout attribute are both re-sent). M3c.
    if ($redirectUris -contains "$fe/*") { $needsUpdate = $true }
    if ([bool](Get-KcClientProp $existing 'directAccessGrantsEnabled') -ne [bool]$EnableDirectAccessGrants) { $needsUpdate = $true }
    if (-not (Get-KcClientProp $existing 'standardFlowEnabled')) { $needsUpdate = $true }
    if (-not (Get-KcClientProp $existing 'rootUrl')) { $needsUpdate = $true }
    if (-not (Get-KcClientProp $existing 'adminUrl')) { $needsUpdate = $true }
    # Doc says these must be off; catch drift if someone toggles them in the UI.
    if (Get-KcClientProp $existing 'implicitFlowEnabled') { $needsUpdate = $true }
    if (Get-KcClientProp $existing 'authorizationServicesEnabled') { $needsUpdate = $true }

    if ($needsUpdate) {
        Write-Host "Client '$ClientId' exists but needs updating..."
        # Inject the existing id into the JSON so the PUT addresses the right record
        $payloadWithId = $clientPayloadJson -replace '^\{', "{`n  `"id`": `"$clientUuid`","
        Invoke-KcApi -Method Put -Path "/realms/$RealmName/clients/$clientUuid" -Body $payloadWithId | Out-Null
    } else {
        Write-Host "Client '$ClientId' already matches -- skipping update."
        Write-Host "(Note: secret may still be reset if you've passed a new value; this script doesn't verify.)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "Creating client '$ClientId'..."
    Invoke-KcApi -Method Post -Path "/realms/$RealmName/clients" -Body $clientPayloadJson | Out-Null
    $created = Invoke-KcApi -Method Get -Path "/realms/$RealmName/clients?clientId=$ClientId"
    $clientUuid = $created[0].id
}
Write-Host "Client UUID: $clientUuid"

# Audience mapper
if ($IncludeAudienceMapper) {
    $existing = Invoke-KcApi -Method Get -Path "/realms/$RealmName/clients/$clientUuid/protocol-mappers/models"
    $hasMapper = $existing | Where-Object { $_.name -eq "edfiadminapp-api-audience" }
    if ($hasMapper) {
        Write-Host "Audience mapper already exists."
    } else {
        Write-Host "Adding audience mapper (aud=edfiadminapp-api)..."
        $mapper = @{
            name = "edfiadminapp-api-audience"
            protocol = "openid-connect"
            protocolMapper = "oidc-audience-mapper"
            consentRequired = $false
            config = @{
                "included.custom.audience" = "edfiadminapp-api"
                "id.token.claim" = "false"
                "access.token.claim" = "true"
                "userinfo.token.claim" = "false"
            }
        }
        Invoke-KcApi -Method Post -Path "/realms/$RealmName/clients/$clientUuid/protocol-mappers/models" -Body $mapper | Out-Null
    }
}

# Test user. Username intentionally matches email -- the AdminApp's [user]
# table is seeded with username=admin@example.com, so the preferred_username
# claim from Keycloak needs to match that key for the local user lookup.
$users = Invoke-KcApi -Method Get -Path "/realms/$RealmName/users?email=$TestUserEmail&exact=true"
if ($users.Count -gt 0) {
    Write-Host "User '$TestUserEmail' already exists."
    $existingUser = $users[0]
    $userId = $existingUser.id

    # Sync firstName / lastName / emailVerified / enabled on existing users so
    # re-runs apply the doc-recommended profile fields without recreating.
    $userNeedsUpdate = $false
    if ($existingUser.firstName -ne $TestUserFirstName) { $userNeedsUpdate = $true }
    if ($existingUser.lastName  -ne $TestUserLastName)  { $userNeedsUpdate = $true }
    if (-not $existingUser.emailVerified)               { $userNeedsUpdate = $true }
    if (-not $existingUser.enabled)                     { $userNeedsUpdate = $true }
    if ($userNeedsUpdate) {
        $userUpdate = @{
            username      = $TestUserEmail
            email         = $TestUserEmail
            firstName     = $TestUserFirstName
            lastName      = $TestUserLastName
            emailVerified = $true
            enabled       = $true
        }
        Invoke-KcApi -Method Put -Path "/realms/$RealmName/users/$userId" -Body $userUpdate | Out-Null
        Write-Host "Updated profile fields for '$TestUserEmail'."
    }
} else {
    Write-Host "Creating user '$TestUserEmail'..."
    $userBody = @{
        username      = $TestUserEmail
        email         = $TestUserEmail
        firstName     = $TestUserFirstName
        lastName      = $TestUserLastName
        emailVerified = $true
        enabled       = $true
    }
    Invoke-KcApi -Method Post -Path "/realms/$RealmName/users" -Body $userBody | Out-Null
    $newUsers = Invoke-KcApi -Method Get -Path "/realms/$RealmName/users?email=$TestUserEmail&exact=true"
    $userId = $newUsers[0].id
}

# Reset password — only if the current password doesn't already work.
# We probe by trying password grant. Requires Direct Access Grants enabled on
# the client; if not, we always reset since we can't verify.
$passwordWorks = $false
$dagEnabled = $EnableDirectAccessGrants.IsPresent -or ($clients.Count -gt 0 -and (Get-KcClientProp $clients[0] 'directAccessGrantsEnabled'))
if ($dagEnabled) {
    try {
        # Hashtable body so Invoke-RestMethod URL-encodes the client secret and
        # password; a special character in either would otherwise corrupt the form.
        $body = @{
            grant_type    = "password"
            client_id     = $ClientId
            client_secret = $ClientSecretPlain
            username      = $TestUserEmail
            password      = $TestUserPasswordPlain
            scope         = "openid"
        }
        $probe = Invoke-RestMethod -Uri "$KeycloakBaseUrl/realms/$RealmName/protocol/openid-connect/token" `
            -Method Post -ContentType "application/x-www-form-urlencoded" -Body $body -TimeoutSec 5 -ErrorAction Stop
        if ($probe.access_token) { $passwordWorks = $true }
    } catch {
        $passwordWorks = $false
    }
}

if ($passwordWorks) {
    Write-Host "Password for '$TestUserEmail' already works — skipping reset."
} else {
    $pwBody = @{ type = "password"; value = $TestUserPasswordPlain; temporary = $false }
    Invoke-KcApi -Method Put -Path "/realms/$RealmName/users/$userId/reset-password" -Body $pwBody
    Write-Host "Password set for '$TestUserEmail'."
}

# Startup task -- registered last, once the realm exists, so the task's health gate has
# something real to wait on. Opt out with -SkipStartupTask.
if ($SkipStartupTask) {
    Write-Host ""
    Write-Warning "Skipping the startup task (-SkipStartupTask). Keycloak will NOT restart after a reboot, and the Admin App will reject logins until Keycloak is started and the API app pool '$ApiAppPoolName' is recycled."
} else {
    Write-Host ""
    Write-Host "Registering the Keycloak startup task..."
    $kcBatForTask = Resolve-KcBat -InstallPath $KeycloakInstallPath
    if (-not $kcBatForTask) {
        throw "kc.bat not found under $KeycloakInstallPath, so the startup task cannot be registered. Re-run this script, or pass -SkipStartupTask to continue without reboot survival."
    }
    Register-KeycloakStartupTask -KcBat $kcBatForTask -InstallPath $KeycloakInstallPath `
        -DiscoveryUrl "$KeycloakBaseUrl/realms/$RealmName/.well-known/openid-configuration" `
        -ApiAppPoolName $ApiAppPoolName -ReadyTimeoutSeconds $ReadyTimeoutSeconds
}

Write-Host ""
Write-Host "SUCCESS: Keycloak bootstrap complete." -ForegroundColor Green
Write-Host "  Realm:        $RealmName"
Write-Host "  Client:       $ClientId  (secret you passed in)"
Write-Host "  User:         $TestUserEmail"
Write-Host "  Redirect URIs:"
Write-Host "    $api/api/auth/callback/$RedirectCallbackId"
Write-Host "    $fe/auth/callback"
Write-Host "    $api/api/auth/post-logout"
Write-Host "  Post-logout:  $api/api/auth/post-logout"
Write-Host "  Web Origin:   $api"
if ($IncludeAudienceMapper) { Write-Host "  Audience mapper: edfiadminapp-api" }
if ($EnableDirectAccessGrants) { Write-Host "  Direct access grants: enabled" }
