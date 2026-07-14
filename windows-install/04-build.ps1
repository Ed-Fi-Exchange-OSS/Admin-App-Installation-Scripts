<#
.SYNOPSIS
Runs `npm ci --legacy-peer-deps`, `npm run build:api`, and `npm run build:fe`
in the Ed-Fi-AdminApp repo.

.DESCRIPTION
Wraps the slow / chatty manual build step so the install can be one-shot.
Output streams to the console as it runs (no log capture), so failures are
visible immediately.

The `--legacy-peer-deps` flag is a workaround for the Storybook 8 vs 10 peer
conflict in the repo (see project tickets). When the upstream conflict is
resolved, this flag can be removed.

Does NOT require elevation, but does require Node + npm on PATH. If you just
installed Node via script 03, open a fresh PowerShell window before running this.

.PARAMETER SourcePath
The cloned Ed-Fi-AdminApp repo. Defaults to the parent of the script
directory (this script lives in <repo>\windows-install\).

.PARAMETER SkipInstall
Switch — skip `npm ci`. Useful if node_modules is already populated and you
only need to rebuild.

.PARAMETER Force
Switch -- always run npm ci + builds even if artifacts already exist.
By default, the script skips the build when main.js and dist\packages\fe\index.html
are already present and newer than package.json (heuristic for "build is current").

.PARAMETER ViteApiUrl
URL the FE will call for API requests. Written into packages\fe\.env as
VITE_API_URL before building. Default: http://localhost:3333.

.PARAMETER ViteBasePath
URL path the FE is served from. Written into packages\fe\.env as
VITE_BASE_PATH before building. Default: "/" (the FE is served from the root
of its own HTTP site).

.PARAMETER ViteIdpAccountUrl
The IdP account-management URL the FE links to. Default (Keycloak example):
http://localhost:8080/realms/edfi/account/.

.EXAMPLE
.\04-build.ps1
.\04-build.ps1 -SourcePath C:\Ed-Fi\Ed-Fi-AdminApp
.\04-build.ps1 -SkipInstall
.\04-build.ps1 -Force
#>

param(
    [string]$SourcePath = (Split-Path $PSScriptRoot -Parent),
    [switch]$SkipInstall,
    [switch]$Force,
    [string]$ViteApiUrl = "http://localhost:3333",
    [string]$ViteBasePath = "/",
    [string]$ViteIdpAccountUrl = "http://localhost:8080/realms/edfi/account/"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path "$SourcePath\package.json")) {
    throw "package.json not found at $SourcePath. Is this the right path?"
}

# Refresh PATH from registry in case Node was installed in this shell session
# (the current process's $env:Path is set at shell startup and doesn't auto-refresh).
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

# Verify Node is on PATH
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "node is not on PATH. Run script 03-prereqs-node.ps1 first, or open a fresh PowerShell window."
}

$apiMainJs = "$SourcePath\dist\packages\api\main.js"
$feIndex   = "$SourcePath\dist\packages\fe\index.html"
$apiBuilt = Test-Path $apiMainJs
$feBuilt  = Test-Path $feIndex
$pkgJson  = Get-Item "$SourcePath\package.json"

$buildIsCurrent = $false
if ($apiBuilt -and $feBuilt) {
    $mainJs = Get-Item $apiMainJs
    if ($mainJs.LastWriteTime -gt $pkgJson.LastWriteTime) {
        $buildIsCurrent = $true
    }
}

# The timestamp heuristic above does not know whether the existing FE bundle was
# built for the requested VITE_API_URL. A stale bundle built for a different API
# URL/scheme breaks at runtime under the enforcing CSP (connect-src), so only
# treat the build as current when the last-built .env matches the requested URL.
$envFile = "$SourcePath\packages\fe\.env"
$feConfigCurrent = $false
if (Test-Path $envFile) {
    $m = Select-String -Path $envFile -Pattern '^VITE_API_URL=(.*)$' | Select-Object -First 1
    if ($m -and $m.Matches.Groups[1].Value -eq $ViteApiUrl) { $feConfigCurrent = $true }
}

if ($buildIsCurrent -and $feConfigCurrent -and -not $Force) {
    Write-Host "Build artifacts present, current, and built for $ViteApiUrl -- skipping build." -ForegroundColor Green
    Write-Host "  API entry:  $apiMainJs"
    Write-Host "  FE output:  $SourcePath\dist\packages\fe\"
    Write-Host "Pass -Force to rebuild anyway." -ForegroundColor DarkGray
    return
}
if ($buildIsCurrent -and -not $feConfigCurrent -and -not $Force) {
    Write-Host "FE build config changed (VITE_API_URL now $ViteApiUrl) -- rebuilding the frontend bundle." -ForegroundColor Cyan
}

# Ensure packages\fe\.env exists with the right Vite values before building.
# Vite reads these at build time and bakes paths/URLs into the bundle, so
# updating .env after build has no effect.
$template = "$SourcePath\packages\fe\.copyme.env.local"
try {
    if (-not (Test-Path $envFile) -and (Test-Path $template)) {
        Copy-Item $template $envFile
        Write-Host "Seeded packages\fe\.env from .copyme.env.local"
    }
    if (Test-Path $envFile) {
        $envText = Get-Content $envFile -Raw
        $envText = $envText -replace 'VITE_API_URL=.*',         "VITE_API_URL=$ViteApiUrl"
        $envText = $envText -replace 'VITE_BASE_PATH=.*',        "VITE_BASE_PATH=`"$ViteBasePath`""
        $envText = $envText -replace 'VITE_IDP_ACCOUNT_URL=.*',  "VITE_IDP_ACCOUNT_URL=$ViteIdpAccountUrl"
        Set-Content $envFile -Value $envText -Encoding UTF8
        Write-Host "Updated packages\fe\.env (VITE_API_URL=$ViteApiUrl, VITE_BASE_PATH=$ViteBasePath)"
    }
} catch {
    throw "Failed to write the frontend build config at $envFile. Check the path is writable. Original: $($_.Exception.Message)"
}

Push-Location $SourcePath
try {
    if (-not $SkipInstall) {
        Write-Host "Running: npm ci --legacy-peer-deps" -ForegroundColor Cyan
        & npm ci --legacy-peer-deps
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE" }
    } else {
        Write-Host "Skipping npm ci (-SkipInstall)."
    }

    Write-Host ""
    Write-Host "Running: npm run build:api" -ForegroundColor Cyan
    & npm run build:api
    if ($LASTEXITCODE -ne 0) { throw "build:api failed with exit code $LASTEXITCODE" }

    Write-Host ""
    # nx caches fe:build and does not hash .env, so a changed VITE_API_URL alone
    # would otherwise serve a stale cached bundle. Clear the cache when the FE
    # config is not current so the bundle is genuinely rebuilt for the new URL.
    if (-not $feConfigCurrent) {
        Write-Host "Clearing the nx cache (FE config changed)..." -ForegroundColor Cyan
        & npx nx reset
    }
    Write-Host "Running: npm run build:fe" -ForegroundColor Cyan
    & npm run build:fe
    if ($LASTEXITCODE -ne 0) { throw "build:fe failed with exit code $LASTEXITCODE" }

    Write-Host ""
    Write-Host "SUCCESS: Build complete." -ForegroundColor Green
    Write-Host "  API entry:  $apiMainJs"
    Write-Host "  FE output:  $SourcePath\dist\packages\fe\"
} finally {
    Pop-Location
}
