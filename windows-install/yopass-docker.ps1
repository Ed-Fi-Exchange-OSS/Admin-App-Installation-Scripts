#Requires -RunAsAdministrator
<#
.SYNOPSIS
Stands up a local Yopass service (Yopass + memcached) via docker compose so the
Admin App can hand out newly-created Ed-Fi API client credentials as
one-time-use, self-destructing links instead of showing them inline.

.DESCRIPTION
Brings up the stack defined in docker\docker-compose.yopass.yml, waits until the
Yopass HTTP endpoint responds, and prints the URL to set as YOPASS_URL in the
API config (install-all.ps1 wires this automatically; 05-deploy-api.ps1 takes
it via -YopassUrl).

Idempotent: re-running just ensures the containers are up. Tear down with
uninstall.ps1, or `docker compose -f docker-compose.yopass.yml down -v` from the
docker folder.

This is the "set up Yopass for me" path. The other two modes need no container:
  - Disabled  -> don't run this; USE_YOPASS ends up false (credentials shown inline).
  - Existing  -> skip this and pass the existing -YopassUrl to 04/install-all.

.PARAMETER YopassPort
Host port to publish the Yopass service on (mapped to container port 80).
Default 8082. The effective URL becomes http://localhost:<YopassPort>.

.PARAMETER DockerDir
Folder containing docker-compose.yopass.yml. Default: the docker\ folder next to
this script.

.PARAMETER TimeoutSeconds
How long to wait for Yopass to start responding. Default 60.

.OUTPUTS
Writes the resolved Yopass URL to the pipeline (last line) so callers can capture
it: $url = .\yopass-docker.ps1 -YopassPort 8082

.EXAMPLE
.\yopass-docker.ps1
.\yopass-docker.ps1 -YopassPort 9000
#>
param(
    [int]$YopassPort = 8082,
    [string]$DockerDir = (Join-Path $PSScriptRoot "docker"),
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

$composeFile = Join-Path $DockerDir "docker-compose.yopass.yml"
if (-not (Test-Path $composeFile)) {
    throw "docker-compose.yopass.yml not found at $DockerDir. Expected it to ship alongside the install scripts."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker is not on PATH. Install Docker Desktop and ensure 'docker compose' works before standing up Yopass (or use an external Yopass via -YopassUrl, or leave Yopass disabled)."
}

# Engine must be RUNNING, not just installed. `docker info` exits non-zero when
# Docker Desktop isn't up; OSType confirms the Linux engine (yopass/memcached
# are Linux images).
$osType = & docker info --format '{{.OSType}}' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Docker engine isn't running. Start Docker Desktop and wait until it reports 'running', then re-run."
}
if ($osType -and $osType -ne 'linux') {
    throw "Docker is in '$osType' container mode. Yopass + memcached are Linux images -- switch Docker Desktop to Linux containers and re-run."
}

# Host port must be free, unless our own yopass container already publishes it
# (idempotent re-run). On Docker Desktop a published port is owned by
# com.docker.backend, so we confirm ownership via docker, not the process name.
$listener = Get-NetTCPConnection -LocalPort $YopassPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    $ourPorts = & docker ps --filter "name=^edfiadminapp-yopass$" --format "{{.Ports}}" 2>$null
    if ($ourPorts -notmatch ":$YopassPort->") {
        $procName = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        throw "Host port $YopassPort is already in use by '$procName'. Re-run with -YopassPort <free-port> (and pass the same -YopassPort to install-all so the API is configured with the matching URL)."
    }
    Write-Host "Port $YopassPort already published by an existing edfiadminapp-yopass container (idempotent re-run)."
}

$yopassUrl = "http://localhost:$YopassPort"

# The compose file reads ${YOPASS_PORT:-8082}; pass it via the environment so we
# don't have to write/clobber a .env (the postgres stack owns docker\.env).
$env:YOPASS_PORT = "$YopassPort"

Push-Location $DockerDir
try {
    Write-Host "Starting docker compose (yopass + memcached) on host port $YopassPort..."
    & docker compose -f $composeFile up -d
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose up failed (exit code $LASTEXITCODE). Check 'docker compose -f docker-compose.yopass.yml logs'."
    }

    Write-Host "Waiting for Yopass to respond at $yopassUrl ..."
    $ready = $false
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            # Any HTTP status (incl. 404) means the server is up and listening.
            Invoke-WebRequest -Uri $yopassUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
            $ready = $true; break
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { $ready = $true; break }  # got an HTTP response
            Start-Sleep -Seconds 2
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $ready) {
        throw "Yopass did not start responding at $yopassUrl within ${TimeoutSeconds}s. Check 'docker compose -f docker-compose.yopass.yml logs yopass'."
    }
    Write-Host "Yopass is up at $yopassUrl" -ForegroundColor Green
} finally {
    Pop-Location
}

# Emit the URL so callers (install-all.ps1) can capture it.
$yopassUrl
