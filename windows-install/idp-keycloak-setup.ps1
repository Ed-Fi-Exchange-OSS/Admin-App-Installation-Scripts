#Requires -RunAsAdministrator
<#
.SYNOPSIS
Optional local Identity Provider example. Installs a JDK if needed, downloads
Keycloak, starts it, and provisions the edfi realm, edfiadminapp client, and
test user. One run leaves a fully-ready local Keycloak for the Admin App.

.DESCRIPTION
The Admin App's auth engine is provider-agnostic (generic OIDC discovery), so a
real deployment points it at whatever IdP the organization runs. This script is
only the convenience path for a local dev install that wants Keycloak as the
example IdP.

Steps (each idempotent):
  1. JDK: reuse an existing Java >= 17 already on PATH, otherwise install
     Microsoft OpenJDK 21 (Keycloak 26 requires Java 17 or 21) and set
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
standalone HTTPS sites (FE https://localhost:4443, API https://localhost:3443).

.PARAMETER TestUserEmail / -TestUserFirstName / -TestUserLastName / -TestUserPassword
The seeded test user. TestUserEmail must match the AdminApp DB's seeded user.

.PARAMETER IncludeAudienceMapper
Switch -- add the audience mapper (only needed for bearer-token API access).

.PARAMETER EnableDirectAccessGrants
Switch -- enable the password grant (OAuth ROPC) on the client. Testing only;
sends user credentials straight to the token endpoint. The script warns if this
is combined with a non-localhost -KeycloakBaseUrl (a production/remote IdP).

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

    # Defaults match the always-on-TLS standalone sites (FE on 4443, API on 3443).
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

    # Realm display + session settings (Ed-Fi docs defaults). Tune per env if
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

    # Forwarded to idp-keycloak-start.ps1: register a startup Scheduled Task so
    # Keycloak survives a reboot. Requires elevation. Off by default.
    [switch]$RegisterStartupTask
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
        Write-Warning "Direct Access Grants (OAuth password grant) is enabled on a non-localhost Keycloak ($KeycloakBaseUrl). This flow sends user credentials directly to the token endpoint and is intended for local testing only -- do not enable it against a production or remote IdP."
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

# Secrets arrive as SecureString (kept off the command line); unwrap to plaintext
# locals for the Keycloak admin REST calls and client/user provisioning.
# AdminPassword stays a SecureString because it is delegated on to
# idp-keycloak-start.ps1 (also SecureString); only the local REST body uses the
# unwrapped copy.
$AdminPasswordPlain = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
$ClientSecretPlain     = [System.Net.NetworkCredential]::new('', $ClientSecret).Password
$TestUserPasswordPlain = [System.Net.NetworkCredential]::new('', $TestUserPassword).Password

# JDK -- Keycloak 26 officially requires Java 17 or 21. Behavior in order:
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

    # Step 2: install / locate OpenJDK 21. Match jdk-21* dirs that actually
    # contain a runnable java.exe -- a leftover half-install can't fool us.
    $existing21 = Get-ChildItem "C:\Program Files\Microsoft" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "jdk-21*" -and (Test-Path "$($_.FullName)\bin\java.exe") } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($existing21) {
        $openJdk21Root = $existing21.FullName
        Write-Host "OpenJDK 21 already installed at $openJdk21Root"
    } elseif (-not $JdkDownloadUrl) {
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
$existingKcBat = $null
if (Test-Path "$KeycloakInstallPath\bin\kc.bat") {
    $existingKcBat = "$KeycloakInstallPath\bin\kc.bat"
} else {
    $sub = Get-ChildItem $KeycloakInstallPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path "$($_.FullName)\bin\kc.bat" } |
        Select-Object -First 1
    if ($sub) { $existingKcBat = "$($sub.FullName)\bin\kc.bat" }
}
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
    -ReadyTimeoutSeconds $ReadyTimeoutSeconds `
    -RegisterStartupTask:$RegisterStartupTask

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
# KC_BOOTSTRAP_ADMIN_* env vars are first-run-only.
Write-Host "Authenticating to Keycloak admin API..."
try {
    $tokenResp = Invoke-RestMethod -Uri "$KeycloakBaseUrl/realms/master/protocol/openid-connect/token" `
        -Method Post `
        -ContentType "application/x-www-form-urlencoded" `
        -Body "grant_type=password&client_id=admin-cli&username=$AdminUser&password=$AdminPasswordPlain" `
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
        Write-Host "        env vars only apply on first run against an empty data dir."
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
#   Admin URL                 = FE base
#   Valid Redirect URIs       = API callback + FE callback + API post-logout (no wildcard)
#   Valid Post Logout URIs    = API post-logout endpoint only. The app always sends
#                               MY_URL/api/auth/post-logout as its post_logout_redirect_uri
#                               (auth.controller.ts), then forwards to the FE itself, so no
#                               FE URI needs to be pre-registered. (Keycloak 26 separates
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
        $body = "grant_type=password&client_id=$ClientId&client_secret=$ClientSecretPlain&username=$TestUserEmail&password=$TestUserPasswordPlain&scope=openid"
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
