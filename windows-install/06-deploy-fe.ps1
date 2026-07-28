#Requires -RunAsAdministrator
<#
.SYNOPSIS
Deploys the Ed-Fi Admin App frontend to IIS.

.DESCRIPTION
- Copies built web application files (index.html + assets\) to the IIS folder
- Creates or updates the IIS site under a dedicated App Pool (started explicitly)
- Writes web.config with the React Router SPA rewrite rule + security headers

Run AFTER `npm run build:fe` produces dist\packages\fe\ in the source repository.

.PARAMETER SourcePath
Path to the Vite build output, e.g. C:\Ed-Fi\Ed-Fi-AdminApp\dist\packages\fe.

.PARAMETER DestPath
Where to deploy. Default: C:\inetpub\EdFi-AdminApp-FE (a dedicated directory,
not nested under another site's root).

.PARAMETER SiteName
IIS site name. Default: EdFi-AdminApp-FE.

.PARAMETER Port
HTTP port. Default: 4200.

.PARAMETER ApiUrl
Base URL of the API the web application bundle calls. Only its origin (scheme://host:port) is
used, to populate the Content-Security-Policy connect-src. Must match the
VITE_API_URL baked into the bundle at build time. Default: https://localhost:3443.

.PARAMETER AppPoolName
Dedicated IIS App Pool for the web application site, created and started here so the SPA does
not depend on DefaultAppPool (which is often Stopped after a reboot). Default:
EdFi-AdminApp-FE.

.EXAMPLE
.\06-deploy-fe.ps1 -SourcePath C:\Ed-Fi\Ed-Fi-AdminApp\dist\packages\fe
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [string]$DestPath = "C:\inetpub\EdFi-AdminApp-FE",
    [string]$SiteName = "EdFi-AdminApp-FE",
    [int]$Port = 4200,
    [string]$ApiUrl = "https://localhost:3443",
    [string]$AppPoolName = "EdFi-AdminApp-FE",

    # TLS (see 05-deploy-api.ps1 for the certificate model). HTTPS always-on on
    # -HttpsPort; self-signed fallback for local. HTTP stays only to 301-redirect.
    [int]$HttpsPort = 4443,
    [string]$CertificateThumbprint = "",
    [string]$CertificatePfxPath = "",
    [SecureString]$CertificatePassword,

    # By default the auto-generated self-signed certificate is added to LocalMachine\Root so
    # local browsers trust it (no "Not Secure" warning). Set this to skip that where
    # policy forbids adding trusted roots; the browser will then warn. Only affects the
    # self-signed path -- a supplied real certificate is never added to Root.
    [switch]$SkipSelfSignedTrust
)

$ErrorActionPreference = 'Stop'

# IIS is managed through the Microsoft.Web.Administration ServerManager API, loaded
# directly from inetsrv. Neither PowerShell module works across both editions:
# WebAdministration's IIS:\ provider drive does not exist under PowerShell 7 (and
# Test-Path against a missing drive returns $false rather than failing, so checks
# silently report the wrong answer), while IISAdministration fails to import under
# PowerShell 7 with an assembly conflict unless a Windows PowerShell compatibility
# session happens to exist already. This assembly behaves identically in Windows
# PowerShell 5.1 and PowerShell 7. WET-duplicated in 05-deploy-api.ps1.
#
# Every mutation below must end in CommitChanges(): ServerManager buffers changes and
# drops them silently if they are never committed.
function New-IisServerManager {
    if (-not ('Microsoft.Web.Administration.ServerManager' -as [type])) {
        Add-Type -Path "$env:SystemRoot\System32\inetsrv\Microsoft.Web.Administration.dll" -ErrorAction Stop
    }
    New-Object Microsoft.Web.Administration.ServerManager
}

# Precondition: IIS must be available (01-prereqs-iis.ps1 installs the IIS pieces).
try {
    $preflightManager = New-IisServerManager
    $preflightManager.Dispose()
} catch {
    throw "IIS isn't available (the IIS management API could not be loaded). Ensure IIS is installed (setup-vm-prereqs.ps1) and run 01-prereqs-iis.ps1 before deploying. Original: $($_.Exception.Message)"
}

if (-not (Test-Path "$SourcePath\index.html")) {
    throw "index.html not found at $SourcePath. Did you run 'npm run build:fe'?"
}

Write-Host "Copying web application files to $DestPath..."
New-Item -ItemType Directory -Path $DestPath -Force | Out-Null
& robocopy $SourcePath $DestPath /MIR /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

# Dedicated App Pool for the FE. Without one, a new site lands in DefaultAppPool,
# which is often Stopped after a reboot or recycle -> the SPA 503s until it is started
# by hand. A dedicated pool (autoStart on by default) started explicitly here keeps the
# FE reachable on its own.
$appPoolManager = $null
try {
    $appPoolManager = New-IisServerManager
    $appPool = $appPoolManager.ApplicationPools[$AppPoolName]
    if (-not $appPool) {
        Write-Host "Creating App Pool '$AppPoolName'..."
        $appPool = $appPoolManager.ApplicationPools.Add($AppPoolName)
    }
    # Static content -- no managed runtime needed.
    $appPool.ManagedRuntimeVersion = ''
    $appPoolManager.CommitChanges()
    Write-Host "App Pool '$AppPoolName' configured."
} catch {
    throw "Failed to create/configure the IIS App Pool '$AppPoolName'. Is IIS running and the WAS service started? Original: $($_.Exception.Message)"
} finally {
    if ($appPoolManager) { $appPoolManager.Dispose() }
}

# Sites.Add starts the site on commit, matching the previous New-Website behaviour.
$siteManager = $null
try {
    $siteManager = New-IisServerManager
    $site = $siteManager.Sites[$SiteName]
    if ($site) {
        Write-Host "Site '$SiteName' exists. Updating physical path and app pool..."
        $site.Applications['/'].VirtualDirectories['/'].PhysicalPath = $DestPath
        $site.Applications['/'].ApplicationPoolName = $AppPoolName
    } else {
        $site = $siteManager.Sites.Add($SiteName, 'http', "*:${Port}:", $DestPath)
        $site.Applications['/'].ApplicationPoolName = $AppPoolName
        Write-Host "Site '$SiteName' created on HTTP port $Port (App Pool '$AppPoolName')."
    }
    $siteManager.CommitChanges()
} finally {
    if ($siteManager) { $siteManager.Dispose() }
}

# Ensure the pool is running so the site serves immediately. Start() is a runtime
# operation on an already-committed pool, not a configuration change, so it is not
# part of a CommitChanges batch.
$poolStateManager = $null
try {
    $poolStateManager = New-IisServerManager
    $statePool = $poolStateManager.ApplicationPools[$AppPoolName]
    if ($statePool -and $statePool.State -ne 'Started') {
        $statePool.Start()
        Write-Host "Started App Pool '$AppPoolName'."
    }
} finally {
    if ($poolStateManager) { $poolStateManager.Dispose() }
}

# Resolve the TLS certificate for the HTTPS binding. Precedence: an explicit
# thumbprint (already in LocalMachine\My) -> an imported PFX -> a self-signed certificate
# generated for localhost + this host. The self-signed path keeps the local
# quick-start working with zero certificate setup (an untrusted-certificate browser warning is
# expected). Returns the resolved certificate thumbprint. WET-duplicated in
# 05-deploy-api.ps1 (windows-install has no shared module); when install-all runs
# 05 first, this reuses the self-signed certificate 05 created (matched by FriendlyName).
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
    # (and the other site's deploy) share a single certificate; else generate a fresh one.
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
    # Trust the self-signed certificate on this machine (add the public certificate to
    # LocalMachine\Root) so local browsers don't show "Not Secure". Only the
    # self-signed path does this -- a supplied real certificate is already CA-trusted. Skip
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

# Add (idempotently) an HTTPS binding on the site and attach the certificate. Mirror-port
# model: API and web application each have their own HTTPS port, so no SNI/hostname is needed
# (SslFlags 0). The certificate is (re)bound every run so a replaced/rotated certificate takes
# effect. WET-duplicated in 05-deploy-api.ps1.
function Set-HttpsBinding {
    param(
        [Parameter(Mandatory)][string]$SiteName,
        [Parameter(Mandatory)][int]$HttpsPort,
        [Parameter(Mandatory)][string]$Thumbprint
    )
    $certificate = Get-Item "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop
    $bindingInformation = "*:${HttpsPort}:"
    $bindingManager = $null
    try {
        $bindingManager = New-IisServerManager
        $site = $bindingManager.Sites[$SiteName]
        if (-not $site) { throw "site '$SiteName' does not exist." }
        # Removed and re-added rather than reassigning the hash on an existing binding, so
        # a replaced or rotated certificate always takes effect. Adding a binding with a
        # certificate hash also registers it with HTTP.sys, which the IIS:\SslBindings
        # path had to do as a separate step.
        foreach ($stale in @($site.Bindings | Where-Object { $_.Protocol -eq 'https' -and $_.BindingInformation -eq $bindingInformation })) {
            $site.Bindings.Remove($stale)
        }
        $site.Bindings.Add($bindingInformation, $certificate.GetCertHash(), 'My') | Out-Null
        $bindingManager.CommitChanges()
    } finally {
        if ($bindingManager) { $bindingManager.Dispose() }
    }
    Write-Host "Bound certificate $Thumbprint to the HTTPS binding on port $HttpsPort for site '$SiteName'."
}

# TLS (always-on): resolve the certificate and add the HTTPS binding. The HTTP site created
# above stays only to 301-redirect to HTTPS (redirect rule added to web.config in T3.2).
$certThumbprint = Resolve-HttpsCertificate -Thumbprint $CertificateThumbprint -PfxPath $CertificatePfxPath -PfxPassword $CertificatePassword -SkipTrust:$SkipSelfSignedTrust
Set-HttpsBinding -SiteName $SiteName -HttpsPort $HttpsPort -Thumbprint $certThumbprint

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
        <rule name="React Routes" stopProcessing="true">
          <match url=".*" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_FILENAME}" matchType="IsFile" negate="true" />
            <add input="{REQUEST_FILENAME}" matchType="IsDirectory" negate="true" />
          </conditions>
          <action type="Rewrite" url="index.html" />
        </rule>
      </rules>
    </rewrite>
    <!-- Baseline security headers. The CSP is enforcing (flipped from Report-Only
         once TLS was always-on; validated in a browser with no violations). connect-src
         must match the API origin the FE bundle calls (VITE_API_URL). style-src allows
         'unsafe-inline' because MUI / emotion inject styles at runtime. -->
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
        __HSTS_HEADER__
        <add name="X-Content-Type-Options" value="nosniff" />
        <add name="X-Frame-Options" value="DENY" />
        <add name="Referrer-Policy" value="no-referrer" />
        <add name="Content-Security-Policy" value="default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; img-src 'self' data:; font-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self' __API_ORIGIN__; form-action 'self'" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
'@

# The CSP connect-src must name the exact API origin (scheme://host:port), so the
# browser allows the FE's XHR calls to the API. Strip any path/query from -ApiUrl.
$apiOrigin = ([Uri]$ApiUrl).GetLeftPart([System.UriPartial]::Authority)
$webConfig = $webConfig.Replace('__API_ORIGIN__', $apiOrigin)
$webConfig = $webConfig.Replace('__HTTPS_PORT__', "$HttpsPort")

# HSTS only on a real hostname / CA-issued certificate. On the default self-signed localhost
# path, an HSTS pin would apply to the WHOLE 'localhost' host for a year (HSTS is
# port-agnostic), silently rewriting other localhost HTTP services -- e.g. Keycloak
# dev on :8080 -- to https and breaking the default login flow. Emit it only when the
# operator supplied their own certificate (which implies a real deployment behind a real name).
if ($CertificateThumbprint -or $CertificatePfxPath) {
    $webConfig = $webConfig.Replace('__HSTS_HEADER__', '<add name="Strict-Transport-Security" value="max-age=31536000; includeSubDomains" />')
} else {
    $webConfig = $webConfig -replace '(?m)^\s*__HSTS_HEADER__\r?\n', ''
}

$webConfigPath = "$DestPath\web.config"
if ((Test-Path $webConfigPath) -and ((Get-Content $webConfigPath -Raw) -eq $webConfig)) {
    Write-Host "web.config already matches — not rewriting."
} else {
    Set-Content -Path $webConfigPath -Value $webConfig -Encoding UTF8
    Write-Host "web.config written."
}

Write-Host ""
Write-Host "SUCCESS: Web application deployed at https://localhost:$HttpsPort/ (HTTP :$Port redirects here)." -ForegroundColor Green
