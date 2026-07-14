#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs the IIS URL Rewrite Module and an httpPlatform handler (HttpBridge or
Microsoft HttpPlatformHandler), and unlocks the IIS config the Admin App's
web.config files need.

.DESCRIPTION
- Downloads + installs the IIS URL Rewrite Module MSI (verifying a pinned SHA-256)
- Downloads + installs the chosen httpPlatform handler MSI (verifying a pinned SHA-256)
- Unlocks system.webServer/handlers so app-level web.config can register the handler

The API is hosted by IIS via the httpPlatform handler: IIS launches node.exe as a
child process, hands it a loopback port through HTTP_PLATFORM_PORT, and reverse-
proxies requests to it.

Idempotent -- safe to re-run.

This sets up the IIS engine prerequisites only. The API and FE are deployed as
two standalone sites by 05-deploy-api.ps1 and 06-deploy-fe.ps1.

.PARAMETER HttpHandler
Which httpPlatform handler to install:
  HttpBridge          (default) -- LeXtudio fork (MIT), actively maintained,
                      drop-in compatible with the httpPlatform schema. Currently
                      shipped as a release candidate.
  HttpPlatformHandler -- Microsoft's original v1.2 (signed, stable, frozen ~2016).
Both register the same 'httpPlatformHandler' global module, so the API web.config
is identical either way.

.EXAMPLE
.\01-prereqs-iis.ps1
.\01-prereqs-iis.ps1 -HttpHandler HttpPlatformHandler
#>

param(
    [ValidateSet('HttpBridge','HttpPlatformHandler')]
    [string]$HttpHandler = 'HttpBridge'
)

$ErrorActionPreference = 'Stop'

# Pinned downloads. Each MSI is verified against a SHA-256 captured from the
# published artifact before install (defends against corrupt/partial downloads and
# a tampered mirror). Mirrors the CERT_BRUNO_SRC_CHECKSUM pattern in the codebase.
$UrlRewrite = @{
    Url    = 'https://download.microsoft.com/download/D/D/E/DDE57C26-C62C-4C59-A1BB-31D58B36ADA2/rewrite_amd64_en-US.msi'
    Sha256 = '7B327108055C4B5BA9445E3B1AFCC4DC5EDD373BAA83EBE6DCB0B1CE57EE3FC2'
    File   = 'rewrite_amd64_en-US.msi'
}
$Handlers = @{
    HttpBridge = @{
        Url    = 'https://github.com/lextudio/httpbridge/releases/download/httpbridge_v10.0.0-rc.1/httpbridge_x64_en_10.0.0-dev.msi'
        Sha256 = '35E06DC2EEBBDA4C6756787FA6650B56504684907242ED760B855D1D0248709F'
        File   = 'httpbridge_x64_en_10.0.0-dev.msi'
    }
    HttpPlatformHandler = @{
        Url    = 'https://download.microsoft.com/download/8/1/3/813AC4E6-9203-4F7A-8DD5-F3D54D10C5CD/httpPlatformHandler_amd64.msi'
        Sha256 = '90F8D4905A0AB4F2C95223B3C79E2807A0B74507747D240E43C4302E8DB4B5EF'
        File   = 'httpPlatformHandler_amd64.msi'
    }
}

function Install-VerifiedMsi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$FileName
    )
    $msi = Join-Path $env:TEMP $FileName

    # Reuse an already-downloaded MSI only if its hash matches; otherwise
    # (missing, or mismatch -> possibly corrupt/partial/tampered) (re)download.
    $needsDownload = $true
    if (Test-Path $msi) {
        if ((Get-FileHash -Path $msi -Algorithm SHA256).Hash -ieq $Sha256) {
            Write-Host "$Name MSI already downloaded and verified -- reusing $msi."
            $needsDownload = $false
        } else {
            Write-Host "$Name MSI at $msi failed the pinned hash (corrupt/partial?); re-downloading." -ForegroundColor Yellow
            Remove-Item $msi -Force
        }
    }
    if ($needsDownload) {
        Write-Host "Downloading $Name from $Url ..."
        try {
            Invoke-WebRequest -Uri $Url -OutFile $msi -UseBasicParsing
        } catch {
            throw "Failed to download $Name from $Url. Check internet connectivity and that the URL is reachable. Original: $($_.Exception.Message)"
        }
        $actual = (Get-FileHash -Path $msi -Algorithm SHA256).Hash
        if ($actual -ine $Sha256) {
            Remove-Item $msi -Force -ErrorAction SilentlyContinue
            throw "$Name failed SHA-256 verification.`n  Expected: $Sha256`n  Actual:   $actual`nThe download may be corrupt or tampered with; aborting."
        }
        Write-Host "$Name verified (SHA-256 match)."
    }

    Write-Host "Installing $Name ..."
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
}

# Precondition: the IIS web server role must already be installed
# (setup-vm-prereqs.ps1 does that). This script only adds URL Rewrite + the httpPlatform handler.
if (-not (Get-Service W3SVC -ErrorAction SilentlyContinue)) {
    throw "IIS (W3SVC) is not installed. Run setup-vm-prereqs.ps1 first, or enable the IIS role via Enable-WindowsOptionalFeature."
}

# Precondition: IIS 10+ is required. 05-deploy-api.ps1 sets NPM_CONFIG_CACHE on
# the App Pool's environmentVariables, a collection added in IIS 10.0.
$iisMajor = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -Name MajorVersion -ErrorAction SilentlyContinue).MajorVersion
if ($iisMajor -and $iisMajor -lt 10) {
    throw "IIS $iisMajor detected; this install requires IIS 10 or newer (App Pool environment variables, used to scope the npm cache, were added in IIS 10). Use Windows 10/11 or Windows Server 2016+."
}
Import-Module WebAdministration

# IIS URL Rewrite Module.
# Still required by the FE web.config SPA fallback (06-deploy-fe.ps1 rewrites to
# index.html). The API no longer uses a rewrite rule under httpPlatform.
$rewriteDll = "$env:SystemRoot\System32\inetsrv\rewrite.dll"
if (Test-Path $rewriteDll) {
    Write-Host "URL Rewrite Module already installed."
} else {
    Install-VerifiedMsi -Name 'IIS URL Rewrite Module' -Url $UrlRewrite.Url -Sha256 $UrlRewrite.Sha256 -FileName $UrlRewrite.File
    if (-not (Test-Path $rewriteDll)) {
        throw "URL Rewrite Module install failed (rewrite.dll not present)."
    }
}

# Unlock system.webServer/handlers so app-level web.configs can register the
# httpPlatform handler. IIS locks this by default; without it, the API returns
# HTTP 500.19 (0x80070021).
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" unlock config -section:system.webServer/handlers | Out-Null
Write-Host "Unlocked system.webServer/handlers section."

# httpPlatform handler. Both HttpBridge and Microsoft HttpPlatformHandler register
# a global module named 'httpPlatformHandler'. Skip if already present (re-run safe;
# switching handlers needs a manual uninstall first).
if (Get-WebGlobalModule -Name 'httpPlatformHandler' -ErrorAction SilentlyContinue) {
    # Both handlers register the same module name, so detect which MSI is installed
    # to tell whether it matches the requested -HttpHandler and warn if it does not
    # (switching handlers needs a manual uninstall of the current MSI first).
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installedName = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'HTTP\s*Bridge|HTTP\s*Platform\s*Handler' } |
        Select-Object -First 1 -ExpandProperty DisplayName
    $installedHandler =
        if     ($installedName -match 'Bridge')             { 'HttpBridge' }
        elseif ($installedName -match 'Platform\s*Handler') { 'HttpPlatformHandler' }
        else                                                { $null }
    if ($installedHandler -and $installedHandler -ne $HttpHandler) {
        Write-Warning "The 'httpPlatformHandler' module is already registered from '$installedName' (-HttpHandler $installedHandler), but -HttpHandler $HttpHandler was requested. Keeping the installed handler. To switch, uninstall the current handler MSI first (Programs and Features, or msiexec /x), then re-run."
    } else {
        Write-Host "httpPlatform handler already registered (global module 'httpPlatformHandler')."
    }
} else {
    $h = $Handlers[$HttpHandler]
    Install-VerifiedMsi -Name $HttpHandler -Url $h.Url -Sha256 $h.Sha256 -FileName $h.File
    if (-not (Get-WebGlobalModule -Name 'httpPlatformHandler' -ErrorAction SilentlyContinue)) {
        throw "$HttpHandler install completed but the 'httpPlatformHandler' global module is not registered. Check the MSI installed correctly."
    }
}

Write-Host ""
Write-Host "SUCCESS: URL Rewrite + $HttpHandler installed; IIS config unlocked." -ForegroundColor Green
Write-Host "The API and FE deploy as standalone sites (05-deploy-api.ps1, 06-deploy-fe.ps1)."
