#Requires -RunAsAdministrator
<#
.SYNOPSIS
Read-only pre-flight check. Reports the state of every prerequisite the install
scripts touch, without changing anything.

.DESCRIPTION
Groups checks into three categories:

  Manual prereqs   — must be installed before any install script can run
  Auto-installed   — scripts install these if missing (informational)
  Already configured — scripts will (re)apply these even if present

Output uses [PASS] / [FAIL] / [INFO] markers. Run this once before kicking off
install-all.ps1 to see what's already in place and what needs attention.

.PARAMETER SourcePath
Path to the cloned Ed-Fi-AdminApp repo. Defaults to the parent of the script
directory (this script lives in <repo>\windows-install\).

.PARAMETER DatabaseName
Default: sbaa.

.EXAMPLE
.\00-check-prereqs.ps1
.\00-check-prereqs.ps1 -SourcePath D:\projects\Ed-Fi-AdminApp
#>

param(
    [string]$SourcePath = (Split-Path $PSScriptRoot -Parent),
    [string]$DatabaseName = "sbaa",
    # Which DB engine the install will target. 'mssql' enables the SQL Server
    # checks below; 'pgsql' replaces them with a docker-availability check.
    [ValidateSet('mssql','pgsql')]
    [string]$DbEngine = 'mssql',

    # Yopass docker mode. When the install will run with -SetupYopassDocker,
    # also verify Docker is RUNNING (not just installed) and the publish port
    # is free, since the Yopass + memcached containers can't otherwise start.
    [switch]$SetupYopassDocker,
    [int]$YopassPort = 8082
)

$ErrorActionPreference = 'Continue'

# Minimum versions enforced by the install scripts. The Node floor is
# auto-detected from $SourcePath\package.json (engines.node) below when the
# repo is cloned; the constant here is the fallback when it isn't.
$MinNodeMajor = 22  # fallback if package.json detection fails

# Auto-detect the Node floor from the repo's engines.node when available. Keeps
# the check in sync if the AdminApp bumps its requirement (e.g., 22 -> 24).
$pkgJsonPath = Join-Path $SourcePath 'package.json'
if (Test-Path $pkgJsonPath) {
    try {
        $engineSpec = (Get-Content $pkgJsonPath -Raw | ConvertFrom-Json).engines.node
        if ($engineSpec -and $engineSpec -match '(\d+)') {
            $detected = [int]$Matches[1]
            if ($detected -ne $MinNodeMajor) {
                Write-Host "(Node floor set from package.json engines.node='$engineSpec': $MinNodeMajor -> $detected)" -ForegroundColor DarkGray
            }
            $MinNodeMajor = $detected
        }
    } catch {
        # Parsing failed; keep the hardcoded fallback
    }
}

$failures = 0
$warnings = 0
$risks    = 0

function Write-Check {
    param(
        [string]$Level,     # PASS | FAIL | INFO | RISK
        [string]$Name,
        [string]$Detail
    )
    $color = switch ($Level) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'INFO' { 'Yellow' }
        'RISK' { 'Magenta' }
        default { 'White' }
    }
    $marker = "[$Level]".PadRight(7)
    Write-Host $marker -ForegroundColor $color -NoNewline
    Write-Host " $Name" -NoNewline
    if ($Detail) { Write-Host "  -- $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
    if ($Level -eq 'FAIL') { $script:failures++ }
    if ($Level -eq 'INFO') { $script:warnings++ }
    if ($Level -eq 'RISK') { $script:risks++ }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("-" * $Title.Length) -ForegroundColor Cyan
}

# ============================================================
Write-Section "MANUAL PREREQUISITES (must be in place before scripts run)"
# ============================================================

# Admin elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Check PASS "Running as Administrator"
} else {
    Write-Check FAIL "Running as Administrator" "Open PowerShell as administrator before running install scripts"
}

# Windows version (informational; scripts target any modern Windows + IIS)
$os = (Get-CimInstance Win32_OperatingSystem).Caption
Write-Check PASS "OS: $os"

# IIS installed (W3SVC service exists)
$w3svc = Get-Service W3SVC -ErrorAction SilentlyContinue
if ($w3svc) {
    Write-Check PASS "IIS installed" "W3SVC status: $($w3svc.Status)"
} else {
    Write-Check FAIL "IIS not installed" "Run: Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-WebServerManagementTools -All"
}

# IIS version -- 10+ required (05-deploy-api sets App Pool environmentVariables,
# an IIS 10 feature, to scope the npm cache).
if ($w3svc) {
    $iisMajor = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -Name MajorVersion -ErrorAction SilentlyContinue).MajorVersion
    if ($iisMajor -ge 10) {
        Write-Check PASS "IIS version $iisMajor"
    } elseif ($iisMajor) {
        Write-Check FAIL "IIS $iisMajor is too old" "Requires IIS 10+ (App Pool environment variables for the npm cache). Use Windows 10/11 or Windows Server 2016+."
    } else {
        Write-Check INFO "IIS version unknown" "Could not read HKLM:\SOFTWARE\Microsoft\InetStp\MajorVersion"
    }
}

# SQL Server engine installed -- only required when -DbEngine is 'mssql'.
# When the target is 'pgsql' instead, check for Docker so the docker-compose
# postgres can come up.
$sqlService = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
if ($DbEngine -eq 'mssql') {
    if ($sqlService) {
        $verKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "MSSQL*.MSSQLSERVER" } | Select-Object -First 1
        Write-Check PASS "SQL Server installed" "$($verKey.PSChildName), service status: $($sqlService.Status)"
    } else {
        Write-Check FAIL "SQL Server not installed" "Run: winget install Microsoft.SQLServer.2022.Developer (or pass -DbEngine pgsql to use Postgres instead)"
    }
} else {
    if ($sqlService) {
        Write-Check INFO "SQL Server present but unused (-DbEngine pgsql)" "Service status: $($sqlService.Status). No SQL Server config will be touched."
    } else {
        Write-Check PASS "SQL Server skipped (-DbEngine pgsql)"
    }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Check PASS "Docker on PATH" "Required for -UsePostgresDocker"
    } else {
        Write-Check INFO "Docker not on PATH" "Required only if running install-all with -UsePostgresDocker; for an external Postgres, ignore this"
    }
}

# Yopass docker mode -- only checked when the install will run with
# -SetupYopassDocker. Standing up Yopass needs a RUNNING Linux Docker engine and
# a free host port to publish on; both are blocking for this mode (FAIL), but
# only fire when the mode is requested so default installs are unaffected.
if ($SetupYopassDocker) {
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-Check FAIL "Docker not on PATH (needed for -SetupYopassDocker)" "Install Docker Desktop, or drop -SetupYopassDocker (use -YopassUrl for an existing Yopass, or leave Yopass disabled)"
    } else {
        # `docker info` exits non-zero when the engine isn't running. OSType
        # confirms the Linux engine is active (yopass/memcached are Linux images).
        $osType = & docker info --format '{{.OSType}}' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Check FAIL "Docker engine not running (needed for -SetupYopassDocker)" "Start Docker Desktop, wait until it reports 'running', then re-run"
        } else {
            Write-Check PASS "Docker engine running" "OSType: $osType"
            if ($osType -and $osType -ne 'linux') {
                Write-Check FAIL "Docker is in '$osType' container mode" "Yopass + memcached are Linux images -- switch Docker Desktop to Linux containers"
            }
            # Publish port free? Allow the case where OUR yopass container is
            # already publishing it (idempotent re-run). Note: on Docker Desktop
            # a published port shows as owned by com.docker.backend, so we can't
            # tell ours apart by process name -- ask docker which ports our
            # container actually publishes.
            $listener = Get-NetTCPConnection -LocalPort $YopassPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $listener) {
                Write-Check PASS "Yopass port $YopassPort is free"
            } else {
                $ourPorts = & docker ps --filter "name=^edfiadminapp-yopass$" --format "{{.Ports}}" 2>$null
                if ($ourPorts -match ":$YopassPort->") {
                    Write-Check PASS "Yopass port $YopassPort in use by existing edfiadminapp-yopass" "Idempotent re-run -- compose up will reuse it"
                } else {
                    $procName = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
                    Write-Check FAIL "Yopass port $YopassPort already in use ($procName)" "Pass a free port: install-all ... -SetupYopassDocker -YopassPort <port>"
                }
            }
        }
    }
}

# Git installed
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    Write-Check PASS "Git on PATH" "$($git.Source)"
} else {
    Write-Check INFO "Git not on PATH" "Optional. Used to clone the repo. winget install Git.Git"
}

# Source repo present
if (Test-Path "$SourcePath\package.json") {
    Write-Check PASS "Source repo cloned" "$SourcePath"
} else {
    Write-Check FAIL "Source repo not found at $SourcePath" "Clone before running install scripts"
}

# ============================================================
Write-Section "AUTO-INSTALLED COMPONENTS (scripts will install if missing)"
# ============================================================

# URL Rewrite Module
$rewrite = Test-Path "$env:SystemRoot\System32\inetsrv\rewrite.dll"
if ($rewrite) {
    Write-Check PASS "URL Rewrite Module"
} else {
    Write-Check INFO "URL Rewrite Module not installed" "01-prereqs-iis.ps1 will install"
}

# httpPlatform handler (HttpBridge or Microsoft HttpPlatformHandler). Registered
# as the global module 'httpPlatformHandler'. 01-prereqs-iis.ps1 installs it.
$httpPlatform = $false
try {
    Import-Module WebAdministration -ErrorAction Stop
    if (Get-WebGlobalModule -Name 'httpPlatformHandler' -ErrorAction SilentlyContinue) { $httpPlatform = $true }
} catch { }
if ($httpPlatform) {
    Write-Check PASS "httpPlatform handler"
} else {
    Write-Check INFO "httpPlatform handler not installed" "01-prereqs-iis.ps1 will install"
}

# Node.js -- presence AND version (>= $MinNodeMajor). Both missing and too-old
# are INFO: 03-prereqs-node.ps1 installs LTS when missing and remediates a stale
# version via nvm-windows.
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    # Refresh PATH from registry in case it was just installed in another shell
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $node = Get-Command node -ErrorAction SilentlyContinue
}
if ($node) {
    $nodeVer = & node --version 2>$null
    if ($nodeVer -match '^v(\d+)\.') {
        $nodeMajor = [int]$Matches[1]
        if ($nodeMajor -ge $MinNodeMajor) {
            Write-Check PASS "Node.js" "$nodeVer at $($node.Source)"
        } else {
            Write-Check INFO "Node.js $nodeVer is too old" "03-prereqs-node.ps1 will remediate via nvm-windows (keeps the old version installable)"
        }
    } else {
        Write-Check INFO "Node.js version unparsable" "Output was: $nodeVer"
    }
} else {
    Write-Check INFO "Node.js not on PATH" "03-prereqs-node.ps1 will install LTS via winget"
}

# ============================================================
Write-Section "CONFIGURED STATE (scripts will (re)apply these)"
# ============================================================

if ($DbEngine -eq 'mssql' -and $sqlService -and $sqlService.Status -eq 'Running') {
    # SQL Mixed Mode
    $verKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "MSSQL*.MSSQLSERVER" } | Select-Object -First 1
    if ($verKey) {
        $loginMode = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($verKey.PSChildName)\MSSQLServer" -Name LoginMode -ErrorAction SilentlyContinue).LoginMode
        if ($loginMode -eq 2) {
            Write-Check PASS "SQL Server Mixed Mode auth enabled"
        } elseif ($loginMode -eq 1) {
            Write-Check INFO "SQL Server is Windows-auth only" "02-prereqs-sql.ps1 will switch to Mixed Mode"
        } else {
            Write-Check INFO "SQL Server LoginMode = $loginMode (unknown)"
        }
    }

    # SQL TCP listener on 1433
    $tcpListener = Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue
    if ($tcpListener) {
        Write-Check PASS "TCP listener on port 1433"
    } else {
        Write-Check INFO "Nothing listening on TCP 1433" "02-prereqs-sql.ps1 will enable TCP/IP"
    }

    # sbaa database
    $dbCheck = & sqlcmd -S "(local)" -E -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name = N'$DatabaseName'" -h-1 2>&1
    if ($LASTEXITCODE -eq 0 -and $dbCheck -match $DatabaseName) {
        Write-Check PASS "Database '$DatabaseName' exists"
    } else {
        Write-Check INFO "Database '$DatabaseName' not found" "02-prereqs-sql.ps1 will create"
    }
} else {
    Write-Check INFO "SQL Server checks skipped" "Service not running"
}

# npm cache folder (05-deploy-api sets NPM_CONFIG_CACHE on the App Pool, not machine-wide)
$npmCache = "C:\npm-cache"
if (Test-Path $npmCache) {
    Write-Check PASS "npm cache folder present" "$npmCache"
} else {
    Write-Check INFO "npm cache folder not present" "05-deploy-api.ps1 will create it and set NPM_CONFIG_CACHE on the App Pool"
}

# Build artifacts present? Nx outputs to dist\packages\<project>\, not the repo root.
$apiMainJs = "$SourcePath\dist\packages\api\main.js"
if (Test-Path $apiMainJs) {
    Write-Check PASS "API build artifact present" $apiMainJs
} else {
    Write-Check INFO "API not built yet" "04-build.ps1 will run npm ci + build:api"
}
$feIndex = "$SourcePath\dist\packages\fe\index.html"
if (Test-Path $feIndex) {
    Write-Check PASS "FE build artifact present" "$SourcePath\dist\packages\fe\"
} else {
    Write-Check INFO "FE not built yet" "04-build.ps1 will run build:fe"
}

# IIS state
try {
    Import-Module WebAdministration -ErrorAction Stop
    $apiSite = Get-Website -Name "EdFi-AdminApp-API" -ErrorAction SilentlyContinue
    if ($apiSite) {
        Write-Check PASS "IIS site 'EdFi-AdminApp-API' present" "State: $($apiSite.State)"
    } else {
        Write-Check INFO "IIS site 'EdFi-AdminApp-API' not present" "05-deploy-api.ps1 will create (HTTP :3333 -> HTTPS :3443)"
    }
    $feSite = Get-Website -Name "EdFi-AdminApp-FE" -ErrorAction SilentlyContinue
    if ($feSite) {
        Write-Check PASS "IIS site 'EdFi-AdminApp-FE' present"
    } else {
        Write-Check INFO "IIS site 'EdFi-AdminApp-FE' not present" "06-deploy-fe.ps1 will create (HTTP :4200 -> HTTPS :4443)"
    }
    $apiPool = Get-Item "IIS:\AppPools\EdFi-AdminApp-API" -ErrorAction SilentlyContinue
    if ($apiPool) {
        $loadProfile = (Get-ItemProperty "IIS:\AppPools\EdFi-AdminApp-API" -Name "processModel.loadUserProfile").Value
        Write-Check PASS "App Pool 'EdFi-AdminApp-API' present" "LoadUserProfile: $loadProfile"
    } else {
        Write-Check INFO "App Pool 'EdFi-AdminApp-API' not present" "05-deploy-api.ps1 will create"
    }
} catch {
    Write-Check INFO "IIS checks skipped" "WebAdministration module unavailable (is IIS installed?)"
}

# ============================================================
Write-Section "EXISTING STATE THAT WILL BE MODIFIED (collision risk check)"
# ============================================================
# These checks flag things that already exist on this machine that the install
# scripts WILL change. On a clean dev VM, nothing here should fire. On a
# workstation that already runs other software, each RISK is a heads-up that
# another app on the box may be affected.

# SQL Server instance is shared with other databases?
# 02-prereqs-sql.ps1 flips Mixed Mode, enables sa, forces TCP/IP on 1433, and
# restarts the MSSQLSERVER service. If the instance is hosting other apps,
# they'll feel all three. Skip the entire RISK probe when -DbEngine pgsql --
# the SQL Server install won't be touched at all in that mode.
if ($DbEngine -eq 'mssql' -and $sqlService) {
    $userDbs = & sqlcmd -S "(local)" -E -h-1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND name <> N'$DatabaseName'" 2>$null |
        Where-Object { $_ -and $_.Trim() -ne '' -and $_ -notmatch '^\(' }
    if ($userDbs -and $userDbs.Count -gt 0) {
        $preview = ($userDbs | Select-Object -First 3) -join ', '
        if ($userDbs.Count -gt 3) { $preview += ", +$($userDbs.Count - 3) more" }
        Write-Check RISK "SQL instance hosts other databases" "02 will flip Mixed Mode, reset sa, force TCP:1433, restart service. Other DBs: $preview"
    }

    # sa already enabled and password unknown to us? We can't know the password
    # without trying it, but if sa is enabled at all on a shared instance the
    # 01 script will overwrite it.
    $saState = & sqlcmd -S "(local)" -E -h-1 -W -Q "SET NOCOUNT ON; SELECT CASE WHEN is_disabled = 0 THEN 'enabled' ELSE 'disabled' END FROM sys.sql_logins WHERE name = 'sa'" 2>$null |
        Where-Object { $_ -and $_.Trim() -ne '' -and $_ -notmatch '^\(' } | Select-Object -First 1
    if ($saState -and $saState.Trim() -eq 'enabled' -and $userDbs -and $userDbs.Count -gt 0) {
        Write-Check RISK "sa login is already enabled on a shared instance" "02 will reset sa's password to -SaPassword if the current password doesn't match"
    }
}

# Ports 3333/4200 (HTTP) and 3443/4443 (HTTPS) free? The two standalone sites bind
# these (HTTP redirects to HTTPS). If another process already owns one, New-Website
# fails. Our own AdminApp sites owning the port is fine (idempotent re-run) -- flag
# only a foreign owner.
$portChecks = @(
    @{ Port = 3333; Site = 'EdFi-AdminApp-API'; Role = 'API (HTTP)' },
    @{ Port = 4200; Site = 'EdFi-AdminApp-FE';  Role = 'FE (HTTP)'  },
    @{ Port = 3443; Site = 'EdFi-AdminApp-API'; Role = 'API (HTTPS)' },
    @{ Port = 4443; Site = 'EdFi-AdminApp-FE';  Role = 'FE (HTTPS)'  }
)
foreach ($pc in $portChecks) {
    $listener = Get-NetTCPConnection -LocalPort $pc.Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listener) { continue }
    $ours = $false
    try {
        Import-Module WebAdministration -ErrorAction Stop
        if (Get-Website -Name $pc.Site -ErrorAction SilentlyContinue) { $ours = $true }
    } catch { }
    if (-not $ours) {
        $procName = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Write-Check RISK "Port $($pc.Port) ($($pc.Role)) already in use ($procName)" "05/06-deploy will fail to bind the '$($pc.Site)' site -- free the port first"
    }
}

if ($risks -eq 0) {
    Write-Host "[PASS]  No collision risks detected." -ForegroundColor Green
}

# ============================================================
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
if ($failures -gt 0) {
    Write-Host "NOT READY -- $failures blocking issue(s)" -ForegroundColor Red
    Write-Host "Fix the FAIL items above before running install-all.ps1." -ForegroundColor Red
    Write-Host ("=" * 60) -ForegroundColor Cyan
    exit 1
} elseif ($risks -gt 0) {
    Write-Host "READY TO INSTALL -- with $risks collision risk(s)" -ForegroundColor Magenta
    Write-Host "Review the [RISK] items above. install-all.ps1 will prompt before proceeding" -ForegroundColor Magenta
    Write-Host "unless -AcceptRisks is passed." -ForegroundColor Magenta
    if ($warnings -gt 0) {
        Write-Host "$warnings item(s) flagged INFO -- those are things the scripts will install or configure." -ForegroundColor Yellow
    }
    Write-Host ("=" * 60) -ForegroundColor Cyan
    exit 2
} else {
    Write-Host "READY TO INSTALL" -ForegroundColor Green
    Write-Host "All manual prerequisites are in place." -ForegroundColor Green
    if ($warnings -gt 0) {
        Write-Host "$warnings item(s) flagged INFO -- those are things the scripts will install or configure." -ForegroundColor Yellow
    }
    exit 0
}
