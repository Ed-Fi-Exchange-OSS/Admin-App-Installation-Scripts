#Requires -RunAsAdministrator
<#
.SYNOPSIS
Configures SQL Server for the Ed-Fi Admin App: enables Mixed Mode auth, TCP/IP
protocol, and the `sa` login with a known password.

.DESCRIPTION
Addresses two SQL Server defaults that block the Admin App API from connecting:
- Mixed Mode disabled (Windows-only auth) — fails because the app uses SQL Auth
- TCP/IP disabled — fails because the `mssql` Node driver requires TCP

Auto-detects the installed SQL Server major version from the registry.
Restarts the MSSQLSERVER service once at the end. Idempotent — safe to re-run.

.PARAMETER SaPassword
The password to assign to the sa login. Used only for server-level bootstrap
(Mixed Mode verification and database creation); the Admin App itself does NOT
connect as sa -- see AppDbUsername/AppDbPassword.

.PARAMETER AppDbUsername
The dedicated, least-privilege SQL login the Admin App connects as at runtime.
It is made db_owner of the Admin App database only (not a server sysadmin like
sa). Referenced later in production.js as MSSQL_DB_USERNAME. Default: edfi_adminapp.

.PARAMETER AppDbPassword
The password for the dedicated Admin App login. Referenced later in production.js
as MSSQL_DB_PASSWORD. CHECK_POLICY is enforced on this login, so a weak password
is rejected at creation time.

.PARAMETER InstanceName
SQL Server instance name. Defaults to MSSQLSERVER (the default instance).

.PARAMETER DatabaseName
Name of the Admin App database to create (if it doesn't already exist).
Default: sbaa (the name the Admin App expects out of the box).

.EXAMPLE
.\02-prereqs-sql.ps1 -SaPassword 'EdFi-AdminApp-Local!2026' -AppDbPassword 'EdFi-App-Local!2026'
.\02-prereqs-sql.ps1 -SaPassword 'EdFi-AdminApp-Local!2026' -AppDbPassword 'EdFi-App-Local!2026' -DatabaseName 'myadminapp'
#>

param(
    # Not Mandatory: PowerShell auto-prompts all Mandatory params before the body
    # runs, so a weak sa password would only be rejected after the app-DB prompt.
    # Instead they're prompted, unwrapped, and strength-checked one at a time below.
    [SecureString]$SaPassword,
    [SecureString]$AppDbPassword,

    [string]$AppDbUsername = "edfi_adminapp",
    [string]$InstanceName = "MSSQLSERVER",
    [string]$DatabaseName = "sbaa"
)

$ErrorActionPreference = 'Stop'

# Reject a weak SQL login password the moment each is resolved (whether passed as a
# param or prompted), before any registry or SQL work, so a weak password fails
# immediately and next to the prompt that set it -- not later, after an unrelated
# prompt, as an opaque CHECK_POLICY rejection during CREATE/ALTER LOGIN. Mirrors the
# Windows policy CHECK_POLICY enforces: length >= 8 and at least 3 of the 4 character
# categories (uppercase/lowercase/digit/symbol). -cmatch keeps the upper/lower test
# case-sensitive; AllowEmptyString lets an empty password reach the length check with
# a clear message instead of a parameter-binding error.
function Test-SqlPasswordComplexity {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $categories = 0
    if ($Password -cmatch '[A-Z]')        { $categories++ }
    if ($Password -cmatch '[a-z]')        { $categories++ }
    if ($Password -match  '[0-9]')        { $categories++ }
    if ($Password -match  '[^A-Za-z0-9]') { $categories++ }
    if ($Password.Length -lt 8 -or $categories -lt 3) {
        throw "The $Label password does not meet the SQL Server password policy (CHECK_POLICY): use at least 8 characters and at least 3 of uppercase, lowercase, digit, and symbol."
    }
}

# Prompt (if omitted), unwrap, and strength-check each secret in turn. Unwrap to new
# locals -- assigning back to the [SecureString]-typed parameters would re-trigger
# their type conversion and fail. Point-of-use plaintext (SQLCMDPASSWORD, the inline
# T-SQL) is unavoidable, so it lives in locals, never on a command line.
if (-not $SaPassword)    { $SaPassword = Read-Host -AsSecureString "SQL Server 'sa' password" }
$SaPasswordPlain = [System.Net.NetworkCredential]::new('', $SaPassword).Password
Test-SqlPasswordComplexity -Password $SaPasswordPlain -Label "sa (-SaPassword)"

if (-not $AppDbPassword) { $AppDbPassword = Read-Host -AsSecureString "Admin App DB login '$AppDbUsername' password" }
$AppDbPasswordPlain = [System.Net.NetworkCredential]::new('', $AppDbPassword).Password
Test-SqlPasswordComplexity -Password $AppDbPasswordPlain -Label "Admin App DB login (-AppDbPassword)"

# Find the SQL Server version-specific registry key
$verKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like "MSSQL*.$InstanceName" } |
    Select-Object -First 1

if (-not $verKey) {
    throw "Could not find a SQL Server install for instance '$InstanceName'. Is SQL Server installed?"
}

# Precondition: sqlcmd is used throughout to configure and verify the instance.
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "sqlcmd is not on PATH. Install the SQL Server command-line tools before running this script."
}

$verName = $verKey.PSChildName
Write-Host "Detected SQL Server version key: $verName"

$registryChanged = $false

# Mixed Mode + TCP/IP registry writes. Wrapped so a permissions/instance error
# surfaces an actionable message instead of a raw registry exception.
try {
    # Mixed Mode authentication — only set if not already 2
    $lmPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$verName\MSSQLServer"
    $currentMode = (Get-ItemProperty -Path $lmPath -Name "LoginMode" -ErrorAction SilentlyContinue).LoginMode
    if ($currentMode -eq 2) {
        Write-Host "Mixed Mode already enabled (LoginMode=2)."
    } else {
        Set-ItemProperty -Path $lmPath -Name "LoginMode" -Value 2
        Write-Host "Mixed Mode authentication enabled (LoginMode was $currentMode)."
        $registryChanged = $true
    }

    # TCP/IP protocol — only set values that aren't already correct
    $tcpBase = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$verName\MSSQLServer\SuperSocketNetLib\Tcp"
    $rootEnabled = (Get-ItemProperty -Path $tcpBase -Name "Enabled" -ErrorAction SilentlyContinue).Enabled
    if ($rootEnabled -ne 1) {
        Set-ItemProperty -Path $tcpBase -Name "Enabled" -Value 1
        $registryChanged = $true
    }
    Get-ChildItem $tcpBase | ForEach-Object {
        $cur = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        if ($cur.Enabled -ne 1)         { Set-ItemProperty -Path $_.PSPath -Name "Enabled"         -Value 1      -ErrorAction SilentlyContinue; $script:registryChanged = $true }
        if ($cur.Active -ne 1)          { Set-ItemProperty -Path $_.PSPath -Name "Active"          -Value 1      -ErrorAction SilentlyContinue; $script:registryChanged = $true }
        if ($cur.TcpDynamicPorts -ne "") { Set-ItemProperty -Path $_.PSPath -Name "TcpDynamicPorts" -Value ""     -ErrorAction SilentlyContinue; $script:registryChanged = $true }
        if ($cur.TcpPort -ne "1433")    { Set-ItemProperty -Path $_.PSPath -Name "TcpPort"         -Value "1433" -ErrorAction SilentlyContinue; $script:registryChanged = $true }
    }
    Write-Host "TCP/IP settings checked/applied."
} catch {
    throw "Failed to update SQL Server registry for instance '$InstanceName'. Ensure you're running as administrator and the instance name is correct. Original: $($_.Exception.Message)"
}

# Restart only if registry changes happened
if ($registryChanged) {
    Write-Host "Restarting SQL Server to apply registry changes..."
    try {
        Restart-Service -Name $InstanceName -Force
    } catch {
        throw "Failed to restart the '$InstanceName' service. Check the service exists and isn't blocked by dependent services. Original: $($_.Exception.Message)"
    }
} else {
    Write-Host "No registry changes -- skipping service restart."
}

# Helper: run sqlcmd, return exit code, swallow stderr without tripping
# $ErrorActionPreference=Stop. PS 5.1 wraps native command stderr in
# NativeCommandError records and the script-wide Stop preference treats those
# as terminating, so we temporarily relax the preference around the call.
# Every call gets a query timeout (-t) so we never hang on a partially-up
# server.
function Invoke-Sqlcmd-Quiet {
    param(
        [string[]]$SqlArgs,
        [string]$Password,
        [switch]$FailOnSqlError
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # Pass the password via SQLCMDPASSWORD instead of -P so it never lands on the
    # sqlcmd process command line (visible in the process list); cleared right
    # after the call. Windows-auth (-E) callers pass no -Password.
    if ($Password) { $env:SQLCMDPASSWORD = $Password }
    # -b makes sqlcmd return a non-zero exit code on a SQL error (severity >= 11),
    # so a policy rejection (e.g. a weak password failing CHECK_POLICY) fails
    # loudly instead of silently returning 0. Set only on the DDL/provisioning
    # calls; the readiness and connection probes below intentionally read exit
    # codes and must not treat an expected failure as fatal.
    if ($FailOnSqlError) { $SqlArgs += "-b" }
    try {
        & sqlcmd @SqlArgs -t 10 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $prev
        if ($Password) { Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue }
    }
    return $LASTEXITCODE
}

# After a service restart, SQL Server's status goes Running before it's
# actually accepting queries. Loop with Windows-auth probes (sa may not be
# enabled yet) until a SELECT 1 succeeds or we time out.
Write-Host "Waiting for SQL Server to accept queries..."
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    $ec = Invoke-Sqlcmd-Quiet @("-S", "(local)", "-E", "-Q", "SELECT 1", "-l", "3")
    if ($ec -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $ready) {
    throw "SQL Server did not become ready within ~60 seconds. Check the service is running."
}
Write-Host "SQL Server is responding."

# Enable sa, set password -- only ALTER LOGIN if current password doesn't work
Write-Host "Checking sa login..."
$ec = Invoke-Sqlcmd-Quiet -SqlArgs @("-S", "tcp:localhost,1433", "-U", "sa", "-Q", "SELECT 1", "-l", "3") -Password $SaPasswordPlain
$saLoginWorks = ($ec -eq 0)

if ($saLoginWorks) {
    Write-Host "sa login already accepts the provided password -- skipping ALTER LOGIN."
} else {
    Write-Host "sa login doesn't accept the password -- running ALTER LOGIN..."
    $escapedPw = $SaPasswordPlain -replace "'", "''"
    $saQuery = "ALTER LOGIN sa WITH PASSWORD = '$escapedPw'; ALTER LOGIN sa ENABLE;"
    $ec = Invoke-Sqlcmd-Quiet -SqlArgs @("-S", "(local)", "-E", "-Q", $saQuery) -FailOnSqlError
    if ($ec -ne 0) {
        throw "Failed to configure sa login (sqlcmd exit code $ec). Verify your Windows user has SQL sysadmin."
    }
}

# Verify TCP listener + SQL Auth
$listener = Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue
if (-not $listener) {
    throw "No listener on TCP 1433 after restart. Check Windows Firewall."
}

$ec = Invoke-Sqlcmd-Quiet -SqlArgs @("-S", "tcp:localhost,1433", "-U", "sa", "-Q", "SELECT @@VERSION") -Password $SaPasswordPlain
if ($ec -ne 0) {
    throw "SQL Auth over TCP failed (sqlcmd exit code $ec)."
}

# Create the Admin App database if it doesn't already exist
Write-Host "Ensuring database '$DatabaseName' exists..."
$dbQuery = "IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$DatabaseName') CREATE DATABASE [$DatabaseName];"
$ec = Invoke-Sqlcmd-Quiet -SqlArgs @("-S", "tcp:localhost,1433", "-U", "sa", "-Q", $dbQuery) -Password $SaPasswordPlain -FailOnSqlError
if ($ec -ne 0) {
    throw "Failed to create/verify database '$DatabaseName' (sqlcmd exit code $ec)."
}

Write-Host "Database '$DatabaseName' is present."

# Provision the dedicated, least-privilege login the Admin App connects as. It is
# made db_owner of the Admin App database ONLY -- it holds no server-level role,
# so unlike sa it cannot touch other databases, create logins, or drop the server.
# db_owner (rather than datareader/datawriter/EXECUTE) is required because the app
# self-migrates on boot (DB_RUN_MIGRATIONS) and the job queue creates tables at
# runtime, both of which need DDL on this database. Idempotent: creates the login
# on first run, re-syncs the password on re-run. Bracket-quoted identifiers are
# escaped to keep a ']' in a custom name from breaking the batch.
Write-Host "Provisioning the Admin App login '$AppDbUsername'..."
$safeUser = $AppDbUsername -replace ']', ']]'
$escapedAppPw = $AppDbPasswordPlain -replace "'", "''"
$provisionQuery = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$AppDbUsername')
    CREATE LOGIN [$safeUser] WITH PASSWORD = N'$escapedAppPw', CHECK_POLICY = ON;
ELSE
    ALTER LOGIN [$safeUser] WITH PASSWORD = N'$escapedAppPw';
ALTER LOGIN [$safeUser] ENABLE;
USE [$DatabaseName];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$AppDbUsername')
    CREATE USER [$safeUser] FOR LOGIN [$safeUser];
ALTER ROLE db_owner ADD MEMBER [$safeUser];
"@
$ec = Invoke-Sqlcmd-Quiet -SqlArgs @("-S", "(local)", "-E", "-Q", $provisionQuery) -FailOnSqlError
if ($ec -ne 0) {
    throw "Failed to provision the Admin App login '$AppDbUsername' (sqlcmd exit code $ec). A CHECK_POLICY failure here means the password is too weak; supply a stronger -AppDbPassword."
}

# Verify the app login can connect over TCP with SQL Auth (how the app connects).
$ec = Invoke-Sqlcmd-Quiet -SqlArgs @("-S", "tcp:localhost,1433", "-U", $AppDbUsername, "-d", $DatabaseName, "-Q", "SELECT 1") -Password $AppDbPasswordPlain
if ($ec -ne 0) {
    throw "The Admin App login '$AppDbUsername' could not connect over TCP to '$DatabaseName' (sqlcmd exit code $ec)."
}
Write-Host "Admin App login '$AppDbUsername' is provisioned (db_owner on '$DatabaseName', non-sysadmin) and verified."

Write-Host ""
Write-Host "SUCCESS: SQL Server is configured for Mixed Mode + TCP/IP." -ForegroundColor Green
Write-Host "The Admin App connects as '$AppDbUsername' (MSSQL_DB_USERNAME) -- a non-sysadmin login, not sa." -ForegroundColor Yellow
