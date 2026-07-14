#Requires -RunAsAdministrator
<#
.SYNOPSIS
Deploys the Ed-Fi Admin App API to IIS via the httpPlatform handler.

.DESCRIPTION
- Copies built API files from source to destination
- Creates/configures the IIS App Pool (LoadUserProfile=true, no managed runtime)
- Creates or updates the IIS application (under a parent site) or standalone site
- Writes the httpPlatform web.config (handler + <httpPlatform> block)
- Patches production.js with bare-metal values (DB, API/FE URLs, OIDC)
- Sets icacls permissions for the App Pool user

Run AFTER:
  - 02-prereqs-sql.ps1 (SQL ready)
  - 01-prereqs-iis.ps1 (IIS + httpPlatform handler ready)
  - 03-prereqs-node.ps1 (Node, npm cache ready)
  - `npm ci --legacy-peer-deps` and `npm run build:api` in the source repo

.PARAMETER SourcePath
The built API output folder. Typically the repo root, containing main.js +
packages\ + node_modules\.

.PARAMETER DestPath
Where to deploy. Default: C:\inetpub\EdFi-AdminApp-API (a dedicated directory,
not nested under another site's root).

.PARAMETER AppPoolName
Name of the IIS App Pool. Default: EdFi-AdminApp-API.

.PARAMETER StandalonePort
HTTP port for the standalone API site (EdFi-AdminApp-API). Default: 3333.

.PARAMETER AppDbUsername
The dedicated least-privilege SQL login the Admin App connects as, provisioned by
02-prereqs-sql.ps1 (db_owner on the app DB, not sa). Written into production.js as
MSSQL_DB_USERNAME. Default: edfi_adminapp.

.PARAMETER AppDbPassword
Password for the dedicated Admin App login (set in 02-prereqs-sql.ps1). Written
into production.js as MSSQL_DB_PASSWORD.

.PARAMETER DatabaseName
SQL Server database name. Default: sbaa. Must match what 02-prereqs-sql.ps1 created.

.PARAMETER OidcIssuer
OIDC issuer URL. Default (Keycloak example): http://localhost:8080/realms/edfi.

.PARAMETER OidcClientId
OIDC client id. Default (Keycloak example): edfiadminapp.

.PARAMETER OidcClientSecret
OIDC client secret (the secret configured on the client in your IdP).

.PARAMETER OidcScope
OIDC scopes requested at login. Default: 'openid email profile'.

.PARAMETER AdminUsername
Email seeded as the admin user. Default: admin@example.com.

.PARAMETER DevErrors
Expose detailed IIS error responses to every client. Off by default (remote
clients get generic errors; local requests still see detail). Enable only to
troubleshoot a remote issue.

.EXAMPLE
.\05-deploy-api.ps1 -SourcePath C:\Ed-Fi\Ed-Fi-AdminApp -AppDbPassword 'EdFi-App-Local!2026' -OidcClientSecret 'RBsHTSb...'
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$DestPath = "C:\inetpub\EdFi-AdminApp-API",
    [string]$AppPoolName = "EdFi-AdminApp-API",
    # The API deploys as a standalone HTTP site named $AppPoolName on this port.
    [int]$StandalonePort = 3333,
    # npm cache folder, granted to the App Pool identity and set as the pool's
    # NPM_CONFIG_CACHE so npm under the App Pool writes there (not the unwritable profile).
    [string]$NpmCachePath = "C:\npm-cache",

    # Which database engine production.js should be configured for.
    # 'mssql' -> requires -AppDbPassword.
    # 'pgsql' -> requires -PgDbPassword (host/port/user/db default to the
    # docker-compose setup under windows-install\docker\). Engine-specific
    # password validation is enforced in the body of the script; -DbEngine
    # itself has a default, so it should not be Mandatory.
    [ValidateSet('mssql','pgsql')]
    [string]$DbEngine = 'mssql',

    # SQL Server credentials the Admin App connects as at runtime. Required only
    # when -DbEngine is 'mssql'. This is the dedicated least-privilege login
    # provisioned by 02-prereqs-sql.ps1 (db_owner on the app DB, not sa).
    [string]$AppDbUsername = "edfi_adminapp",
    [SecureString]$AppDbPassword,

    [string]$DatabaseName = "sbaa",

    # PostgreSQL connection details. Required only when -DbEngine is 'pgsql'.
    # Defaults match the docker-compose setup at windows-install\docker\ where
    # the dedicated app user 'edfiadminapp' is provisioned by init/01-...sh.
    [string]$PgDbHost = "localhost",
    [int]$PgDbPort = 5432,
    [string]$PgDbUsername = "edfiadminapp",
    [SecureString]$PgDbPassword,

    # OIDC settings written into production.js. Defaults are the local-Keycloak
    # example; override for any other provider (Entra, Google, Auth0, ...).
    [string]$OidcIssuer = "http://localhost:8080/realms/edfi",
    [string]$OidcClientId = "edfiadminapp",

    [Parameter(Mandatory = $true)]
    [SecureString]$OidcClientSecret,

    [string]$OidcScope = "openid email profile",

    # URLs baked into production.js (MY_URL/FE_URL). Defaults are https on the
    # mirror ports; TLS is always-on (see -HttpsPort and the cert params).
    [string]$ApiUrl = "https://localhost:3443",
    [string]$FeUrl = "https://localhost:4443",
    [string]$AdminUsername = "admin@example.com",

    # Yopass: pass a non-empty URL to enable Yopass (one-time-share for newly-
    # created Ed-Fi API client credentials). Default is empty -> Yopass is
    # disabled and the AdminApp falls back to displaying credentials inline,
    # which is a documented and supported mode (USE_YOPASS=false).
    [string]$YopassUrl = "",

    # Data-at-rest encryption key (64 hex chars / 32 bytes) the AdminApp uses to
    # encrypt stored ODS/API environment secrets (aes-256-cbc). Empty -> reuse an
    # already-deployed non-default key, or generate a fresh one on a clean box. A
    # post-patch guard rejects the shipped default. Losing or changing this key
    # makes previously-encrypted environment secrets unrecoverable.
    [string]$DbEncryptionKey = "",

    # Escape hatch for the key-rotation guard: proceed even when a freshly
    # generated key would orphan existing encrypted environments (accepts data loss).
    [switch]$ForceKeyRotation,

    # Expose detailed IIS error responses to every client. Off by default: remote
    # clients get generic errors while local requests still see detail
    # (errorMode="DetailedLocalOnly"). Set only for troubleshooting a remote issue.
    [switch]$DevErrors,

    # TLS. HTTPS is always-on: the site gets an https binding on -HttpsPort.
    # Certificate precedence: -CertificateThumbprint (an existing LocalMachine\My
    # cert) -> -CertificatePfxPath (+ -CertificatePassword; imported) -> a self-signed
    # cert auto-generated for localhost (keeps the local quick-start working; browsers
    # warn on the untrusted cert). The HTTP site stays bound only to 301-redirect to HTTPS.
    [int]$HttpsPort = 3443,
    [string]$CertificateThumbprint = "",
    [string]$CertificatePfxPath = "",
    [SecureString]$CertificatePassword,

    # By default the auto-generated self-signed cert is added to LocalMachine\Root so
    # local browsers trust it (no "Not Secure" warning). Set this to skip that where
    # policy forbids adding trusted roots; the browser will then warn. Only affects the
    # self-signed path -- a supplied real cert is never added to Root.
    [switch]$SkipSelfSignedTrust,

    # SSL verification for the API's OUTBOUND HTTPS calls (to the ODS/API, AdminApi,
    # and Yopass). Secure by default (verification on). Set this to disable it when an
    # upstream uses a self-signed/dev certificate that Node's CA store won't trust
    # (Node ignores the Windows cert store); prefer NODE_EXTRA_CA_CERTS over this
    # where possible. Do not disable in production.
    [switch]$DisableSslVerification
)

$ErrorActionPreference = 'Stop'

# Precondition: IIS + the WebAdministration module must be available
# (01-prereqs-iis.ps1 installs the IIS pieces). Fail early with an actionable
# message instead of a cryptic Import-Module error.
try {
    Import-Module WebAdministration -ErrorAction Stop
} catch {
    throw "IIS / the WebAdministration module isn't available. Ensure IIS is installed (setup-vm-prereqs.ps1) and run 01-prereqs-iis.ps1 before deploying."
}

# Engine-specific required arg validation. Each engine needs its own password
# parameter; the other one is irrelevant and ignored.
if ($DbEngine -eq 'mssql' -and -not $AppDbPassword) {
    throw "-AppDbPassword is required when -DbEngine is 'mssql'."
}
if ($DbEngine -eq 'pgsql' -and -not $PgDbPassword) {
    throw "-PgDbPassword is required when -DbEngine is 'pgsql'."
}

# Secrets arrive as SecureString (kept off the command line); unwrap the ones
# supplied to plaintext locals for sqlcmd -P and the production.js patch.
# Point-of-use plaintext is unavoidable. DbEncryptionKey stays a plain string:
# it's generated/reused internally, not a caller-supplied credential.
# Use new locals -- assigning back to the [SecureString]-typed parameters would
# re-trigger their type conversion and fail.
$AppDbPasswordPlain    = if ($AppDbPassword)    { [System.Net.NetworkCredential]::new('', $AppDbPassword).Password } else { $null }
$PgDbPasswordPlain     = if ($PgDbPassword)     { [System.Net.NetworkCredential]::new('', $PgDbPassword).Password } else { $null }
$OidcClientSecretPlain = if ($OidcClientSecret) { [System.Net.NetworkCredential]::new('', $OidcClientSecret).Password } else { $null }

$apiBuildDir = "$SourcePath\dist\packages\api"
if (-not (Test-Path "$apiBuildDir\main.js")) {
    throw "Build output not found at $apiBuildDir\main.js. Did you run 'npm run build:api'?"
}

# Selective copy. The deployment needs three pieces, NOT a full source-tree mirror:
#   1. Built API output (main.js + assets\)             from dist\packages\api\
#   2. Config files (production.js etc.)                from packages\api\config\
#   3. node_modules (runtime deps)                      from repo root
# Each piece is mirrored independently so /MIR doesn't wipe sibling content
# (web.config, logs\, the other source piece).
# Capture any already-deployed non-default encryption key BEFORE the file-copy
# phase below overwrites production.js. The source ships a stub production.js that
# the config copy would otherwise clobber, defeating key reuse and silently
# rotating the key on every re-run. Reusing it keeps previously-encrypted ODS/API
# environment secrets decryptable across a reinstall.
$defaultKey = 'bbeadc2d4d15f5c9cfc2239b682cca392b233ee6979b6b9578d256aa01a7c565'
$existingDeployedKey = ''
$deployedProdJs = "$DestPath\packages\api\config\production.js"
if (Test-Path $deployedProdJs) {
    if ((Get-Content $deployedProdJs -Raw) -match "KEY: '([0-9a-f]{64})'" -and $Matches[1] -ne $defaultKey) {
        $existingDeployedKey = $Matches[1]
    }
}

New-Item -ItemType Directory -Path $DestPath -Force | Out-Null

Write-Host "Copying built API output..."
& robocopy $apiBuildDir $DestPath /E /NFL /NDL /NJH /NJS /XF web.config /XD logs packages node_modules | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Failed to copy the built API output from $apiBuildDir to $DestPath (robocopy exit $LASTEXITCODE). Check free disk space and that the destination isn't locked by a running app pool." }

Write-Host "Copying api/config..."
New-Item -ItemType Directory -Path "$DestPath\packages\api" -Force | Out-Null
& robocopy "$SourcePath\packages\api\config" "$DestPath\packages\api\config" /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Failed to copy api/config from $SourcePath\packages\api\config to $DestPath\packages\api\config (robocopy exit $LASTEXITCODE)." }

Write-Host "Copying node_modules (this takes a minute)..."
& robocopy "$SourcePath\node_modules" "$DestPath\node_modules" /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Failed to copy node_modules from $SourcePath\node_modules to $DestPath\node_modules (robocopy exit $LASTEXITCODE). Check free disk space." }

# App Pool
try {
    if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
        Write-Host "Creating App Pool '$AppPoolName'..."
        New-WebAppPool -Name $AppPoolName | Out-Null
    }
    Set-ItemProperty -Path "IIS:\AppPools\$AppPoolName" -Name "processModel.loadUserProfile" -Value $true
    Set-ItemProperty -Path "IIS:\AppPools\$AppPoolName" -Name "managedRuntimeVersion" -Value ""
    Write-Host "App Pool '$AppPoolName' configured (LoadUserProfile=true)."
} catch {
    throw "Failed to create/configure the IIS App Pool '$AppPoolName'. Is IIS running and the WAS service started? Original: $($_.Exception.Message)"
}

# IIS standalone HTTP site (named after the App Pool, e.g. EdFi-AdminApp-API)
try {
    if (Get-Website -Name $AppPoolName -ErrorAction SilentlyContinue) {
        Write-Host "Site '$AppPoolName' exists. Updating physical path..."
        Set-ItemProperty -Path "IIS:\Sites\$AppPoolName" -Name "physicalPath" -Value $DestPath
        Set-ItemProperty -Path "IIS:\Sites\$AppPoolName" -Name "applicationPool" -Value $AppPoolName
    } else {
        New-Website -Name $AppPoolName -Port $StandalonePort -PhysicalPath $DestPath -ApplicationPool $AppPoolName | Out-Null
        Write-Host "Standalone site '$AppPoolName' created on HTTP port $StandalonePort."
    }
} catch {
    throw "Failed to create/update the IIS site '$AppPoolName' on port $StandalonePort. Is the port already in use by another site (check 00-check-prereqs.ps1)? Original: $($_.Exception.Message)"
}

# Resolve the TLS certificate for the HTTPS binding. Precedence: an explicit
# thumbprint (already in LocalMachine\My) -> an imported PFX -> a self-signed cert
# generated for localhost + this host. The self-signed path keeps the local
# quick-start working with zero cert setup (an untrusted-cert browser warning is
# expected). Returns the resolved certificate thumbprint. WET-duplicated in
# 06-deploy-fe.ps1 (windows-install has no shared module).
function Resolve-HttpsCertificate {
    param(
        [string]$Thumbprint,
        [string]$PfxPath,
        [SecureString]$PfxPassword,
        [switch]$SkipTrust
    )
    $storePath = 'Cert:\LocalMachine\My'
    $friendlyName = 'Ed-Fi Admin App self-signed'

    if ($Thumbprint) {
        $clean = ($Thumbprint -replace '[^0-9A-Fa-f]', '')
        $cert = Get-Item "$storePath\$clean" -ErrorAction SilentlyContinue
        if (-not $cert) {
            throw "No certificate with thumbprint '$clean' found in $storePath. Import it into LocalMachine\My first, or omit -CertificateThumbprint to auto-generate a self-signed cert."
        }
        Write-Host "Using the supplied certificate ($($cert.Thumbprint))."
        return $cert.Thumbprint
    }

    if ($PfxPath) {
        if (-not (Test-Path $PfxPath)) { throw "PFX file not found at '$PfxPath'." }
        $importParams = @{ FilePath = $PfxPath; CertStoreLocation = $storePath }
        if ($PfxPassword) { $importParams.Password = $PfxPassword }
        $cert = Import-PfxCertificate @importParams
        Write-Host "Imported the supplied PFX ($($cert.Thumbprint))."
        return $cert.Thumbprint
    }

    # Self-signed fallback. Reuse a still-valid one we created before so re-runs
    # (and the other site's deploy) share a single cert; else generate a fresh one.
    $cert = Get-ChildItem $storePath |
        Where-Object { $_.FriendlyName -eq $friendlyName -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($cert) {
        Write-Host "Reusing the existing self-signed certificate ($($cert.Thumbprint))."
    } else {
        Write-Host "Generating a self-signed certificate for HTTPS (localhost + $env:COMPUTERNAME)..."
        $cert = New-SelfSignedCertificate -DnsName 'localhost', $env:COMPUTERNAME `
            -CertStoreLocation $storePath -FriendlyName $friendlyName -NotAfter (Get-Date).AddYears(5)
    }
    # Trust the self-signed cert on this machine (add the public cert to
    # LocalMachine\Root) so local browsers don't show "Not Secure". Only the
    # self-signed path does this -- a supplied real cert is already CA-trusted. Skip
    # with -SkipTrust where policy forbids adding trusted roots. Idempotent; a
    # public-only copy carrying the same FriendlyName is stored so uninstall finds it.
    if (-not $SkipTrust) {
        $rootStore = [System.Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
        $rootStore.Open('ReadWrite')
        try {
            $found = $rootStore.Certificates.Find(
                [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $cert.Thumbprint, $false)
            if ($found.Count -eq 0) {
                $pub = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cert.RawData)
                $pub.FriendlyName = $friendlyName
                $rootStore.Add($pub)
                Write-Host "Trusted the self-signed certificate (added to LocalMachine\Root)."
            }
        } finally {
            $rootStore.Close()
        }
    }
    return $cert.Thumbprint
}

# Add (idempotently) an HTTPS binding on the site and attach the cert. Mirror-port
# model: API and FE each have their own HTTPS port, so no SNI/hostname is needed
# (SslFlags 0). The cert is (re)bound every run so a replaced/rotated cert takes
# effect. WET-duplicated in 06-deploy-fe.ps1.
function Set-HttpsBinding {
    param(
        [Parameter(Mandatory)][string]$SiteName,
        [Parameter(Mandatory)][int]$HttpsPort,
        [Parameter(Mandatory)][string]$Thumbprint
    )
    if (-not (Get-WebBinding -Name $SiteName -Protocol https -Port $HttpsPort -ErrorAction SilentlyContinue)) {
        New-WebBinding -Name $SiteName -Protocol https -Port $HttpsPort -SslFlags 0 | Out-Null
        Write-Host "Added HTTPS binding on port $HttpsPort to site '$SiteName'."
    }
    $sslPath = "IIS:\SslBindings\0.0.0.0!$HttpsPort"
    if (Test-Path $sslPath) { Remove-Item $sslPath -ErrorAction SilentlyContinue }
    Get-Item "Cert:\LocalMachine\My\$Thumbprint" | New-Item -Path $sslPath | Out-Null
    Write-Host "Bound certificate $Thumbprint to 0.0.0.0:$HttpsPort."
}

# TLS (always-on): resolve the cert and add the HTTPS binding. The HTTP site created
# above stays only to 301-redirect to HTTPS (redirect rule added to web.config in T3.2).
$certThumbprint = Resolve-HttpsCertificate -Thumbprint $CertificateThumbprint -PfxPath $CertificatePfxPath -PfxPassword $CertificatePassword -SkipTrust:$SkipSelfSignedTrust
Set-HttpsBinding -SiteName $AppPoolName -HttpsPort $HttpsPort -Thumbprint $certThumbprint

# web.config -- IIS hosts Node via the httpPlatform handler (reverse proxy to a
# loopback port IIS assigns through HTTP_PLATFORM_PORT). httpPlatform launches node
# AS the App Pool virtual account, so node must live where that identity can execute
# it: a machine-wide location, NOT under a user profile. nvm-windows points
# <root>\nodejs at the active version via a symlink and can resolve into
# C:\Users\<user>\... -- which the App Pool can't traverse, failing with Access
# Denied / HTTP 502.5. Resolve the PATH node, follow its symlink to the real target,
# reject a user-profile path, and fall back to a machine-wide install.
$nodeExe = $null
$nodeCandidates = @()
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) { $nodeCandidates += $nodeCmd.Source }
$nodeCandidates += "C:\Program Files\nodejs\node.exe"
foreach ($candidate in ($nodeCandidates | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not (Test-Path $candidate)) { continue }
    $link = (Get-Item $candidate -ErrorAction SilentlyContinue).Target
    $real = if ($link) { @($link)[0] } else { $candidate }
    if ($real -like "$env:SystemDrive\Users\*") {
        Write-Host "Skipping node at $real (under a user profile; the IIS App Pool can't execute it)." -ForegroundColor DarkGray
        continue
    }
    $nodeExe = $real
    break
}
if (-not $nodeExe) {
    throw "No IIS-accessible node.exe found. Install Node machine-wide (e.g. winget OpenJS.NodeJS.LTS -> C:\Program Files\nodejs) so the IIS App Pool identity can execute it. Node under a user profile (an nvm-windows default) is not hostable by IIS. Re-run 03-prereqs-node.ps1 if needed."
}
Write-Host "httpPlatform will launch node at: $nodeExe"

$webConfig = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="HTTP to HTTPS redirect" stopProcessing="true">
          <match url="(.*)" />
          <conditions>
            <add input="{HTTPS}" pattern="off" />
            <add input="{HTTP_HOST}" pattern="^([^:]+)(:\d+)?$" />
          </conditions>
          <action type="Redirect" url="https://{C:1}:__HTTPS_PORT__/{R:1}" redirectType="Permanent" appendQueryString="true" />
        </rule>
      </rules>
    </rewrite>
    <handlers>
      <add name="httpPlatformHandler" path="*" verb="*" modules="httpPlatformHandler" resourceType="Unspecified" />
    </handlers>
    <httpPlatform processPath="__NODE_EXE__" arguments="main.js" stdoutLogEnabled="true" stdoutLogFile=".\logs\node-stdout.log" startupTimeLimit="60">
      <environmentVariables>
        <environmentVariable name="NODE_ENV" value="production" />
      </environmentVariables>
    </httpPlatform>
    <!-- Baseline security headers. Node already sets X-Content-Type-Options and
         X-Frame-Options in main.ts, so only the headers it does not emit are added
         here to avoid duplicates on the proxied response. The CSP is enforcing
         (flipped from Report-Only once TLS was always-on); the API serves only JSON
         in production (Swagger UI is disabled there), so default-src 'none' is safe. -->
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
        <add name="Strict-Transport-Security" value="max-age=31536000; includeSubDomains" />
        <add name="Referrer-Policy" value="no-referrer" />
        <add name="Content-Security-Policy" value="default-src 'none'; frame-ancestors 'none'; base-uri 'none'" />
      </customHeaders>
    </httpProtocol>
    <httpErrors errorMode="__ERROR_MODE__" />
  </system.webServer>
</configuration>
'@
$webConfig = $webConfig.Replace('__NODE_EXE__', $nodeExe)
$webConfig = $webConfig.Replace('__HTTPS_PORT__', "$HttpsPort")

# Detailed IIS errors are off for remote clients by default (DetailedLocalOnly:
# local requests still see detail, which keeps on-box debugging usable). -DevErrors
# opts into full detail for every client when troubleshooting a remote issue.
$errorMode = if ($DevErrors) { 'Detailed' } else { 'DetailedLocalOnly' }
$webConfig = $webConfig.Replace('__ERROR_MODE__', $errorMode)

$webConfigPath = "$DestPath\web.config"
$webConfigChanged = $true
if (Test-Path $webConfigPath) {
    $existing = Get-Content $webConfigPath -Raw
    if ($existing -eq $webConfig) {
        $webConfigChanged = $false
        Write-Host "web.config already matches — not rewriting."
    }
}
if ($webConfigChanged) {
    try {
        Set-Content -Path $webConfigPath -Value $webConfig -Encoding UTF8
    } catch {
        throw "Failed to write web.config at $webConfigPath. Check the destination is writable. Original: $($_.Exception.Message)"
    }
    Write-Host "web.config written."
}

# The source repo ships production.js as a thin stub (only FE_URL, DB_SSL,
# ENABLE_OPEN_API, WHITELISTED_REDIRECTS) and production.js-edfi as the full
# Ed-Fi template (DB_SECRET_VALUE, OIDC config, etc.). The full template is
# what the API actually needs; always overwrite from it before patching.
$prodJs = "$DestPath\packages\api\config\production.js"
$prodJsTemplate = "$DestPath\packages\api\config\production.js-edfi"

# Resolve the data-at-rest encryption key. Precedence: an explicit -DbEncryptionKey
# wins; else reuse the key captured from the previously-deployed production.js
# (grabbed before the copy phase clobbered it); a clean box with no prior key
# generates a fresh one. Rotating this key makes previously-encrypted ODS/API
# environment secrets unrecoverable, which the guard below defends against.
$freshKeyGenerated = $false
if (-not $DbEncryptionKey -and $existingDeployedKey) {
    $DbEncryptionKey = $existingDeployedKey
    Write-Host "Reusing the existing per-install data-encryption key."
}
if (-not $DbEncryptionKey) {
    $keyBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($keyBytes)
    $DbEncryptionKey = ($keyBytes | ForEach-Object { $_.ToString('x2') }) -join ''
    $freshKeyGenerated = $true
    Write-Host "Generated a per-install data-encryption key."
}

# Guard (defense-in-depth): a freshly generated key cannot decrypt environment
# secrets written under a prior install's key. If we're deploying a NEW key but
# the DB already holds environment rows, fail loudly instead of letting the app
# break with a generic "unexpected error". MSSQL only (the engine tested here);
# a pgsql guard is a follow-up. Best-effort: an unreachable DB / missing table is
# treated as "no data at risk".
if ($freshKeyGenerated -and $DbEngine -eq 'mssql' -and -not $ForceKeyRotation) {
    $envCount = 0
    # Pass the password via SQLCMDPASSWORD instead of -P so it stays off the
    # sqlcmd process command line; cleared in the finally.
    $env:SQLCMDPASSWORD = $AppDbPasswordPlain
    try {
        $out = & sqlcmd -S "tcp:localhost,1433" -U $AppDbUsername -d $DatabaseName -C -h -1 -W -t 10 `
            -Q "SET NOCOUNT ON; IF OBJECT_ID('sb_environment','U') IS NOT NULL SELECT COUNT(*) FROM sb_environment ELSE SELECT 0;" 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { $envCount = [int]("$($out | Select-Object -First 1)").Trim() }
    } catch {
        Write-Warning "Could not verify existing encrypted environments before deploying a new key: $($_.Exception.Message)"
    } finally {
        Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
    }
    if ($envCount -gt 0) {
        throw @"
A new data-at-rest encryption key was generated, but database '$DatabaseName' already
holds $envCount encrypted environment(s) from a previous install. The new key CANNOT
decrypt them -- the Admin App would fail with a generic error. Choose one:
  * Run uninstall.ps1 (drops '$DatabaseName'), then reinstall -- clean slate.
  * Pass the ORIGINAL key via -DbEncryptionKey to keep the existing environments.
  * Pass -ForceKeyRotation to proceed anyway and abandon the existing encrypted data.
"@
    }
}

if (Test-Path $prodJsTemplate) {
    try {
        Copy-Item $prodJsTemplate $prodJs -Force
    } catch {
        throw "Failed to seed production.js from the -edfi template at $prodJsTemplate. Check the config folder is writable. Original: $($_.Exception.Message)"
    }
    Write-Host "Seeded production.js from production.js-edfi template."
} elseif (-not (Test-Path $prodJs)) {
    throw "Neither production.js nor production.js-edfi found in deployed config folder."
}

# Configure the deployed API. Two delivery paths:
#   1. NODE_CONFIG (built here, injected on the App Pool env below): a JSON
#      document node-config deep-merges OVER production.js at load time. It
#      carries every value that is plain data -- DB creds, URLs, OIDC, yopass,
#      admin user -- so those need no fragile text patching.
#   2. Two residual production.js text patches that can't be expressed as JSON
#      data: the per-install encryption KEY (install-all reads it back for the
#      summary) and API_PORT (a JS expression reading a runtime env var). Both
#      are guarded so a template-formatting change fails loudly instead of
#      silently shipping a default (PR #234 Architecture concern #4 / T2.8).

# Guard helper: apply a regex replacement, aborting if the anchor is absent.
# Anchors key on the config NAME (not the default value), so they survive value
# drift -- detecting the silent no-op that is the whole point of the guard.
function Set-ConfigAnchor {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Replacement,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Text -notmatch $Pattern) {
        throw "production.js patch '$Label' matched no anchor. The template (production.js-edfi) formatting likely changed, so this patch would silently no-op and could ship a default. Pattern: $Pattern"
    }
    return [regex]::Replace($Text, $Pattern, $Replacement)
}

# Build the NODE_CONFIG document from the resolved values. node-config deep-merges
# objects, so partial DB_SECRET_VALUE / AUTH0_CONFIG_SECRET_VALUE objects keep
# their untouched siblings (unused engine keys, MACHINE_AUDIENCE). A single-element
# WHITELISTED_REDIRECTS array serializes correctly here (nested arrays don't
# collapse in ConvertTo-Json; verified on PS 5.1).
$nodeConfig = @{
    MY_URL                    = $ApiUrl
    FE_URL                    = $FeUrl
    WHITELISTED_REDIRECTS     = @($FeUrl)
    ADMIN_USERNAME            = $AdminUsername
    USE_YOPASS                = [bool]$YopassUrl
    YOPASS_URL                = $YopassUrl
    SSL_VERIFICATION          = -not $DisableSslVerification
    SAMPLE_OIDC_CONFIG        = @{
        issuer       = $OidcIssuer
        clientId     = $OidcClientId
        clientSecret = $OidcClientSecretPlain
        scope        = $OidcScope
    }
    AUTH0_CONFIG_SECRET_VALUE = @{
        ISSUER        = $OidcIssuer
        CLIENT_ID     = $OidcClientId
        CLIENT_SECRET = $OidcClientSecretPlain
    }
}
if ($DbEngine -eq 'mssql') {
    $nodeConfig.DB_ENGINE            = 'mssql'
    $nodeConfig.DB_TRUST_CERTIFICATE = $true
    $nodeConfig.DB_SECRET_VALUE      = @{
        MSSQL_DB_HOST     = 'localhost'
        MSSQL_DB_DATABASE = $DatabaseName
        MSSQL_DB_USERNAME = $AppDbUsername
        MSSQL_DB_PASSWORD = $AppDbPasswordPlain
    }
} else {
    $nodeConfig.DB_ENGINE       = 'pgsql'
    $nodeConfig.DB_SSL          = $false
    $nodeConfig.DB_SECRET_VALUE = @{
        DB_HOST     = $PgDbHost
        DB_PORT     = $PgDbPort
        DB_USERNAME = $PgDbUsername
        DB_DATABASE = $DatabaseName
        DB_PASSWORD = $PgDbPasswordPlain
    }
}
$nodeConfigJson = $nodeConfig | ConvertTo-Json -Depth 5 -Compress
if ($DisableSslVerification) {
    Write-Warning "SSL_VERIFICATION is DISABLED: the API will NOT verify TLS certificates on outbound HTTPS calls (ODS/API, AdminApi, Yopass). Use only for self-signed upstreams in non-production; prefer NODE_EXTRA_CA_CERTS."
}

# Patch + scrub production.js. NODE_CONFIG overrides these at runtime, but the
# moved secrets still sit at their template defaults on disk; scrub them so a
# NODE_CONFIG load failure fails SAFE (bad creds -> loud error) rather than
# falling back to a well-known default. Only write if something changed.
$prodJsChanged = $false
if (Test-Path $prodJs) {
    $original = Get-Content $prodJs -Raw
    $c = $original
    $scrubMarker = 'set-via-NODE_CONFIG'

    # Residual patch 1: API_PORT must read the IIS-assigned loopback port at
    # runtime -- a JS expression, so it can't live in NODE_CONFIG (data only).
    # Match any current value so a re-run (already patched) stays idempotent;
    # the guard fires only if the API_PORT key vanished entirely.
    $c = Set-ConfigAnchor $c "API_PORT:\s*[^,\r\n]+," "API_PORT: process.env.HTTP_PLATFORM_PORT || 3333," 'API_PORT'

    # Residual patch 2: per-install encryption key. Kept in production.js because
    # install-all.ps1 reads it back for the (ACL-locked) install summary. The
    # existing default-key check below is its silent-no-op guard.
    $c = $c.Replace("KEY: '$defaultKey',", "KEY: '$DbEncryptionKey',")
    if ($c -match $defaultKey) {
        throw "The default DB_ENCRYPTION_SECRET_VALUE.KEY is still present in $prodJs after patching. Refusing to deploy with the well-known default key."
    }

    # Scrub the default secrets for values now delivered via NODE_CONFIG. Each
    # regex keys on the name and matches ANY value, so it neutralizes the default
    # AND stays idempotent on re-run. Both engines' password defaults are scrubbed
    # regardless of the active engine, so no default secret is left in the file.
    $c = Set-ConfigAnchor $c "(clientSecret:\s*')[^']*(')"              ('${1}' + $scrubMarker + '${2}') 'clientSecret'
    $c = Set-ConfigAnchor $c "(CLIENT_SECRET:\s*')[^']*(')"             ('${1}' + $scrubMarker + '${2}') 'CLIENT_SECRET'
    $c = Set-ConfigAnchor $c "(MSSQL_DB_PASSWORD:\s*')[^']*(')"         ('${1}' + $scrubMarker + '${2}') 'MSSQL_DB_PASSWORD'
    $c = Set-ConfigAnchor $c "(?<![A-Za-z_])(DB_PASSWORD:\s*')[^']*(')" ('${1}' + $scrubMarker + '${2}') 'DB_PASSWORD'

    if ($c -ne $original) {
        try {
            Set-Content -Path $prodJs -Value $c -Encoding UTF8
        } catch {
            throw "Failed to write the patched production.js at $prodJs. Check the config folder is writable. Original: $($_.Exception.Message)"
        }
        Write-Host "production.js patched (API_PORT + encryption key; default secrets scrubbed; app config delivered via NODE_CONFIG)."
        $prodJsChanged = $true
    } else {
        Write-Host "production.js already has the desired values — not rewriting."
    }
} else {
    Write-Warning "production.js not found at $prodJs — skipping patch."
}

# Permissions for the App Pool virtual account. Done here (not earlier) because
# the pool now actually exists.
$appPoolIdentity = "IIS APPPOOL\$AppPoolName"
& icacls "$DestPath\packages" /grant "${appPoolIdentity}:(OI)(CI)M" /T | Out-Null
# httpPlatform writes Node stdout to .\logs (per web.config stdoutLogFile).
$logsDir = "$DestPath\logs"
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
& icacls $logsDir /grant "${appPoolIdentity}:(OI)(CI)M" /T | Out-Null

# Grant the App Pool identity read+execute on the node directory so httpPlatform can
# launch node as that identity. Machine-wide installs (C:\Program Files\nodejs)
# already allow Authenticated Users; this is defensive for custom node locations.
$nodeDir = Split-Path $nodeExe -Parent
& icacls $nodeDir /grant "${appPoolIdentity}:(OI)(CI)(RX)" | Out-Null

# npm cache override, scoped to THIS App Pool (not machine-wide, so the user's
# other npm usage is unaffected). Create the cache folder, grant the App Pool
# identity Modify, and set NPM_CONFIG_CACHE on the pool's environment so npm
# under the App Pool writes there instead of the (unwritable) profile cache.
if (-not (Test-Path $NpmCachePath)) {
    New-Item -ItemType Directory -Path $NpmCachePath -Force | Out-Null
}
& icacls $NpmCachePath /grant "${appPoolIdentity}:(OI)(CI)M" /T | Out-Null
$envVarsFilter = "system.applicationHost/applicationPools/add[@name='$AppPoolName']/environmentVariables"
Remove-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $envVarsFilter -Name "." -AtElement @{ name = 'NPM_CONFIG_CACHE' } -ErrorAction SilentlyContinue
Remove-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $envVarsFilter -Name "." -AtElement @{ name = 'NODE_CONFIG' } -ErrorAction SilentlyContinue
try {
    Add-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $envVarsFilter -Name "." -Value @{ name = 'NPM_CONFIG_CACHE'; value = $NpmCachePath }
} catch {
    throw "Failed to set NPM_CONFIG_CACHE on the App Pool '$AppPoolName'. App Pool environment variables require IIS 10 or newer. Original: $($_.Exception.Message)"
}
# NODE_CONFIG carries the structured app configuration (DB creds, URLs, OIDC,
# yopass, admin user); node-config deep-merges it over production.js at boot.
# Lives in the admin-only applicationHost.config, not the site's production.js.
try {
    Add-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $envVarsFilter -Name "." -Value @{ name = 'NODE_CONFIG'; value = $nodeConfigJson }
} catch {
    throw "Failed to set NODE_CONFIG on the App Pool '$AppPoolName'. App Pool environment variables require IIS 10 or newer. Original: $($_.Exception.Message)"
}
Write-Host "Permissions granted to $appPoolIdentity; NPM_CONFIG_CACHE and NODE_CONFIG set on App Pool."

# ---------- OIDC connection row reconciliation (Gap A) ----------
# The seed migration inserts the [oidc]/"oidc" row only when the table is empty
# (COUNT(*)=0), so correcting an issuer or client secret and re-deploying never
# reaches the DB -- login keeps using the stale values (PR #234 Functionality
# review, Gap A). UPSERT the row this installer manages (keyed on its clientId)
# so a re-deploy of corrected OIDC settings takes effect at the next login.
# Guarded on the table existing: on a first install the app hasn't booted yet, so
# the table is absent and the boot-time seed inserts it from NODE_CONFIG instead.
# Skipped when no client secret was supplied, to avoid clobbering a good row with
# an empty one. Runs before the recycle below so the reboot re-reads it.
if ($OidcClientSecretPlain) {
    $oidcIssuerSql   = $OidcIssuer            -replace "'", "''"
    $oidcClientIdSql = $OidcClientId          -replace "'", "''"
    $oidcSecretSql   = $OidcClientSecretPlain -replace "'", "''"
    $oidcScopeSql    = $OidcScope             -replace "'", "''"
    if ($DbEngine -eq 'mssql') {
        $oidcUpsert = @"
SET NOCOUNT ON;
IF OBJECT_ID('oidc','U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM [oidc] WHERE [clientId] = '$oidcClientIdSql')
        INSERT INTO [oidc] ([issuer], [clientId], [clientSecret], [scope])
            VALUES ('$oidcIssuerSql', '$oidcClientIdSql', '$oidcSecretSql', '$oidcScopeSql');
    UPDATE [oidc] SET [issuer] = '$oidcIssuerSql', [clientSecret] = '$oidcSecretSql', [scope] = '$oidcScopeSql'
        WHERE [clientId] = '$oidcClientIdSql';
END
"@
        $env:SQLCMDPASSWORD = $AppDbPasswordPlain
        # This reconciliation is best-effort: on a first install the [oidc] table
        # does not exist yet (the guard above is a no-op), and a transient sqlcmd
        # timeout must not abort the whole install. A -b native error surfaces as a
        # terminating NativeCommandError under $ErrorActionPreference='Stop', so
        # catch it and fall through to the warning. -l 30 gives the login headroom
        # under load.
        $oidcUpsertExit = 1
        try {
            & sqlcmd -S "tcp:localhost,1433" -U $AppDbUsername -d $DatabaseName -C -b -l 30 -Q $oidcUpsert 1>$null 2>$null
            $oidcUpsertExit = $LASTEXITCODE
        } catch {
            $oidcUpsertExit = 1
        } finally {
            Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
        }
        if ($oidcUpsertExit -eq 0) {
            Write-Host "OIDC connection row reconciled with the supplied settings."
        } else {
            Write-Host "Could not reconcile the OIDC connection row (sqlcmd exit $oidcUpsertExit). If login uses stale OIDC settings, update the [oidc] row manually." -ForegroundColor Yellow
        }
    } else {
        # PG best-effort: 05 has no docker awareness, so reach the DB via psql on
        # PATH. Probe for the table first (absent on a pre-boot first install) so
        # the UPDATE can't error on a missing table -- the boot seed covers that.
        if (Get-Command psql -ErrorAction SilentlyContinue) {
            $env:PGPASSWORD = $PgDbPasswordPlain
            try {
                $reg = 'SELECT to_regclass(''oidc'');' | & psql -h $PgDbHost -p $PgDbPort -U $PgDbUsername -d $DatabaseName -tA 2>$null
                if ($LASTEXITCODE -eq 0 -and "$reg".Trim() -ne '') {
                    $oidcUpsert = @"
INSERT INTO "oidc" ("issuer", "clientId", "clientSecret", "scope")
    SELECT '$oidcIssuerSql', '$oidcClientIdSql', '$oidcSecretSql', '$oidcScopeSql'
    WHERE NOT EXISTS (SELECT 1 FROM "oidc" WHERE "clientId" = '$oidcClientIdSql');
UPDATE "oidc" SET "issuer" = '$oidcIssuerSql', "clientSecret" = '$oidcSecretSql', "scope" = '$oidcScopeSql'
    WHERE "clientId" = '$oidcClientIdSql';
"@
                    $oidcUpsert | & psql -h $PgDbHost -p $PgDbPort -U $PgDbUsername -d $DatabaseName -v ON_ERROR_STOP=1 1>$null 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "OIDC connection row reconciled with the supplied settings."
                    } else {
                        Write-Host "Could not reconcile the OIDC connection row (psql exit $LASTEXITCODE). Update the `"oidc`" row manually if login uses stale settings." -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "OIDC table not present yet; the boot-time seed will create it from NODE_CONFIG." -ForegroundColor DarkGray
                }
            } finally {
                Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host "psql not on PATH; skipping OIDC-row reconciliation. If you re-deployed corrected OIDC settings on Postgres, update the `"oidc`" row manually." -ForegroundColor Yellow
        }
    }
}

# Trigger startup only if something actually changed
if ($webConfigChanged -or $prodJsChanged) {
    (Get-Item "$DestPath\web.config").LastWriteTime = Get-Date
    Write-Host "Touched web.config to recycle the app pool."
} else {
    Write-Host "No file changes — skipping app pool recycle."
}

Write-Host ""
Write-Host "SUCCESS: Admin App API deployed." -ForegroundColor Green
Write-Host "URL: https://localhost:${HttpsPort}/api/teams (expect 401 without a bearer token; HTTP :${StandalonePort} redirects to HTTPS)."
