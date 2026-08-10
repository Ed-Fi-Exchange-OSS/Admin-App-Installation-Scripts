#Requires -RunAsAdministrator
#requires -Version 5.1
<#
.SYNOPSIS
Configures the SQL target for the Ed-Fi Admin App and provisions the least-privilege
app login. Supports two targets:
- A LOCAL SQL Server instance (default): enables Mixed Mode authentication and the
  TCP/IP protocol, all under Windows Authentication; the sa login is never enabled
  or modified.
- A REMOTE/managed SQL target such as an Azure SQL Database: skips the local-only
  instance configuration (registry, service restart) and provisions a contained
  database user, connecting as a SQL admin login.

.DESCRIPTION
LOCAL target. Addresses two SQL Server defaults that block the Admin App API from
connecting:
- Mixed Mode disabled (Windows-only authentication) — fails because the app uses SQL authentication
- TCP/IP disabled — fails because the `mssql` Node driver requires TCP

Auto-detects the installed SQL Server major version from the registry.
Restarts the MSSQLSERVER service once at the end. Idempotent — safe to re-run.
Must run under a Windows account that is a SQL Server sysadmin: all server-level
actions (database creation and login provisioning) use Windows Authentication.

REMOTE target (-SqlServerHost is not a loopback name, e.g. an Azure SQL Database).
Azure SQL PaaS supports none of the local-only steps (registry Mixed Mode/TCP,
service restart) and does not accept Windows Authentication, `CREATE LOGIN`, or a
`USE [db]` context switch. This script therefore:
- skips the registry/service configuration entirely;
- connects as the SQL admin login supplied via -SqlAdminUsername/-SqlAdminPassword
  (the logical server's admin) over an encrypted, certificate-validated connection;
- provisions a CONTAINED database user (`CREATE USER ... WITH PASSWORD`) directly in
  the target database and makes it db_owner (no server login, no `USE`);
- assumes the target database already exists (create it, its logical server, and the
  client firewall rule through the Azure control plane before running this).

.PARAMETER AppDbUsername
The dedicated, least-privilege login the Admin App connects as at runtime. It is
made db_owner of the Admin App database only (not a server sysadmin like sa).
Referenced later in production.js as MSSQL_DB_USERNAME. Default: edfi_adminapp.

.PARAMETER AppDbPassword
The password for the dedicated Admin App login. Referenced later in production.js
as MSSQL_DB_PASSWORD. CHECK_POLICY is enforced on this login (local instance) and
the equivalent Azure password policy applies to the contained user, so a weak
password is rejected at creation time.

.PARAMETER InstanceName
Local SQL Server instance name. Defaults to MSSQLSERVER (the default instance).
Used only for the local registry key and service to restart; ignored for a remote
target.

.PARAMETER DatabaseName
Name of the Admin App database. On a local instance it is created if it does not
exist. On a remote target it must already exist (see -SqlServerHost). Default: sbaa
(the name the Admin App expects out of the box).

.PARAMETER SqlServerHost
The SQL host the Admin App connects to. Default 'localhost' (a local instance). Set
to a remote FQDN (for example an Azure SQL Database, myserver.database.windows.net)
to provision against a managed target; any non-loopback value switches this script
into remote mode.

.PARAMETER SqlServerPort
TCP port of the SQL target. Default 1433.

.PARAMETER SqlAdminUsername
SQL admin login used to provision the contained user on a REMOTE target (for Azure
SQL, the logical server's admin login). Required when -SqlServerHost is remote;
ignored for a local instance (which uses Windows Authentication). This credential is
used only for provisioning; the app connects at runtime as -AppDbUsername.

.PARAMETER SqlAdminPassword
Password for -SqlAdminUsername. Prompted securely if omitted on a remote target.

.PARAMETER TrustServerCertificate
Trust the SQL server certificate instead of validating it (adds sqlcmd -C). A local
loopback target always trusts (its auto-generated certificate is not CA-issued). A
remote target validates by default (Azure presents a valid CA certificate); set this
only for a remote server that presents a self-signed/dev certificate.

.EXAMPLE
.\02-prereqs-sql.ps1 -AppDbPassword (Read-Host -AsSecureString 'Admin App DB password')
.\02-prereqs-sql.ps1 -AppDbPassword (Read-Host -AsSecureString 'Admin App DB password') -DatabaseName 'myadminapp'

.EXAMPLE
# Azure SQL Database (server, firewall rule, and empty database pre-created)
.\02-prereqs-sql.ps1 -SqlServerHost 'myserver.database.windows.net' `
  -SqlAdminUsername 'sqladmin' `
  -SqlAdminPassword (Read-Host -AsSecureString 'SQL admin password') `
  -AppDbPassword (Read-Host -AsSecureString 'Admin App DB password')
#>

param(
    # Not Mandatory: a Mandatory [SecureString] would prompt before the body runs,
    # so a weak password would only surface later as an opaque CHECK_POLICY failure.
    # Instead it's prompted, unwrapped, and strength-checked below, next to its prompt.
    [SecureString]$AppDbPassword,

    [string]$AppDbUsername = "edfi_adminapp",
    [string]$InstanceName = "MSSQLSERVER",
    [string]$DatabaseName = "sbaa",

    # Remote/Azure target. Default 'localhost' keeps the local-instance path; any
    # non-loopback host switches to remote mode (see .DESCRIPTION).
    [string]$SqlServerHost = "localhost",
    [int]$SqlServerPort = 1433,
    [string]$SqlAdminUsername = "",
    [SecureString]$SqlAdminPassword,
    [switch]$TrustServerCertificate
)

$ErrorActionPreference = 'Stop'

# Decide whether the SQL target is a local instance (loopback) or a remote server
# such as a managed Azure SQL Database. A local target gets Windows Authentication
# and the registry/service setup; a remote target is provisioned with a SQL admin
# login over an encrypted, certificate-validated connection. Mirrors the loopback
# normalization in Get-SqlcmdTrustArgs (quick-start/ and edorg-sync/ compat.ps1).
function Test-IsRemoteSqlTarget {
    param([string]$SqlServerHost)
    if ([string]::IsNullOrWhiteSpace($SqlServerHost)) { return $false }
    $value = $SqlServerHost.Trim()
    # Local named pipes (\\.\pipe\..., optionally np:-prefixed) are loopback by
    # definition and would otherwise normalize to an empty host below.
    if ($value -match '^(np:)?\\\\(\.|localhost|127\.0\.0\.1)\\') { return $false }
    $target = ($value -replace '^(tcp|np|lpc|admin):', '') -split '[,\\]' | Select-Object -First 1
    $target = $target.Trim().Trim('(', ')')
    $loopback = @('local', 'localhost', '.', '127.0.0.1', '::1', '[::1]')
    if ($env:COMPUTERNAME) { $loopback += $env:COMPUTERNAME }
    return ($target -notin $loopback)
}

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

# The Admin App builds its database connection string as a URL and interpolates the database
# credentials WITHOUT URL-encoding them (packages/api/config/default.js). Characters
# that are structural in a URL (or need percent-encoding) corrupt the parsed password,
# so the API fails to connect with an opaque "Login failed for user". Until the Admin
# App URL-encodes its credentials (the real fix), restrict the database password to characters
# that are safe unencoded in a URL. This does NOT weaken the password: CHECK_POLICY needs
# 3 of 4 categories and upper+lower+digit alone satisfies it (symbols stay optional).
# Example passwords such as 'YourStrong!Passw0rd' and 'EdFi-App-Local!2026' remain valid.
function Test-DbPasswordUrlSafe {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Password -match '[^A-Za-z0-9!$()*,._~-]') {
        throw "The $Label contains a character that is unsafe in the Admin App's URL-form database connection string. Use only letters, digits, and these symbols: ! `$ ( ) * , - . _ ~  This is a temporary installer restriction until the Admin App URL-encodes its database credentials. For passwords, a compliant strong value is still possible: SQL's policy only needs any 3 of uppercase, lowercase, digit, and symbol."
    }
}

# A managed Azure SQL target rejects a database password that contains the login name
# -- or any 3+ character alphanumeric part of it -- failing CREATE USER with an opaque
# "Msg 40632 ... not complex enough". Local SQL Server's CHECK_POLICY does not enforce
# this (so it is applied only for a remote target; the caller gates it), which keeps
# example passwords like 'EdFi-App-Local!2026' valid on a local instance. Split the
# username on non-alphanumeric delimiters -- the Windows/Azure tokenization -- and
# reject the password if it contains the whole name or any such token, case-insensitive.
function Test-DbPasswordNotUsername {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory = $true)][string]$Username
    )
    foreach ($token in @($Username) + ($Username -split '[^A-Za-z0-9]+')) {
        if ($token.Length -ge 3 -and $Password -match [regex]::Escape($token)) {
            throw "The Admin App DB password must not contain the login name or a part of it ('$token'): a managed Azure SQL target rejects such a password (Msg 40632, 'not complex enough'). Choose a password with no 3+ character part of the username '$Username'."
        }
    }
}

$isRemote = Test-IsRemoteSqlTarget -SqlServerHost $SqlServerHost
if ($isRemote) {
    Write-Host "Remote SQL target detected: $SqlServerHost,$SqlServerPort (local instance configuration skipped)."
}

# Prompt (if omitted), unwrap, and strength-check the app-login password. Unwrap to a
# new local -- assigning back to the [SecureString]-typed parameter would re-trigger
# its type conversion and fail. Point-of-use plaintext (SQLCMDPASSWORD, the inline
# T-SQL) is unavoidable, so it lives in a local, never on a command line.
if (-not $AppDbPassword) { $AppDbPassword = Read-Host -AsSecureString "Admin App database login '$AppDbUsername' password" }
$AppDbPasswordPlain = [System.Net.NetworkCredential]::new('', $AppDbPassword).Password
Test-SqlPasswordComplexity -Password $AppDbPasswordPlain -Label "Admin App DB login (-AppDbPassword)"
Test-DbPasswordUrlSafe -Password $AppDbPasswordPlain -Label "Admin App DB login (-AppDbPassword)"
Test-DbPasswordUrlSafe -Password $AppDbUsername -Label "Admin App DB username (-AppDbUsername)"

# Remote targets are provisioned as a SQL admin (Windows Authentication is not
# available on Azure SQL). Require the admin login and prompt for its password if
# omitted. The admin password is used only for sqlcmd (never interpolated into the
# app's URL connection string), so it is not held to the URL-safe restriction.
$SqlAdminPasswordPlain = $null
if ($isRemote) {
    # Fail fast (before touching the server) if the app password would be rejected by
    # Azure's login-name-containment rule, instead of surfacing an opaque Msg 40632 at
    # CREATE USER.
    Test-DbPasswordNotUsername -Password $AppDbPasswordPlain -Username $AppDbUsername
    if (-not $SqlAdminUsername) {
        throw "-SqlAdminUsername is required for a remote SQL target ('$SqlServerHost'). Pass the logical server's SQL admin login; it is used only to provision the '$AppDbUsername' contained user."
    }
    if (-not $SqlAdminPassword) { $SqlAdminPassword = Read-Host -AsSecureString "SQL admin '$SqlAdminUsername' password" }
    $SqlAdminPasswordPlain = [System.Net.NetworkCredential]::new('', $SqlAdminPassword).Password
    if (-not $SqlAdminPasswordPlain) { throw "The SQL admin password (-SqlAdminPassword) is empty." }
}

# sqlcmd server certificate trust. -C trusts the certificate without validating it,
# which is safe only for a loopback target (an auto-generated self-signed certificate,
# no machine-in-the-middle surface) or when the operator explicitly opts in with
# -TrustServerCertificate. A remote target validates by default so the SQL login
# password is never presented to a forged endpoint. Appended to every sqlcmd call
# through Invoke-Sqlcmd-Quiet below.
# NOTE the @(...) wrapper: `if (...) { @() } else { @('-C') }` unwraps the single-
# element array to the bare string '-C', and splatting a STRING (@script:SqlTrustArgs)
# iterates its characters -> '-','C', so sqlcmd sees a bogus '-' option. Wrapping the
# whole conditional in @(...) forces a real array (empty or one element) that splats
# as a single token.
$script:SqlTrustArgs = @(if ($isRemote -and -not $TrustServerCertificate) { } else { '-C' })

# Admin connection used for provisioning: local uses Windows Authentication against
# the local instance; remote uses the SQL admin login against the target host.
if ($isRemote) {
    $adminConnArgs = @('-S', "tcp:$SqlServerHost,$SqlServerPort", '-U', $SqlAdminUsername)
    $adminConnPassword = $SqlAdminPasswordPlain
} else {
    $adminConnArgs = @('-S', '(local)', '-E')
    $adminConnPassword = $null
}
# The app login always connects over TCP with SQL authentication (how the app
# connects at runtime). For a local target this is the loopback the app uses.
$appServer = "tcp:$SqlServerHost,$SqlServerPort"

# Precondition: sqlcmd is used throughout to configure and verify the instance.
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "sqlcmd is not on PATH. Install the SQL Server command-line tools before running this script."
}

# ---------- Local instance configuration (registry Mixed Mode/TCP + restart) ----------
# All of this is local-only: registry keys, the SuperSocketNetLib TCP settings, and the
# MSSQLSERVER service have no equivalent on a managed remote target such as Azure SQL.
if (-not $isRemote) {
    # Find the SQL Server version-specific registry key
    $verKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "MSSQL*.$InstanceName" } |
        Select-Object -First 1

    if (-not $verKey) {
        throw "Could not find a SQL Server install for instance '$InstanceName'. Is SQL Server installed?"
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
}

# Helper: run sqlcmd, return exit code, swallow stderr without tripping
# $ErrorActionPreference=Stop. PS 5.1 wraps native command stderr in
# NativeCommandError records and the script-wide Stop preference treats those
# as terminating, so we temporarily relax the preference around the call.
# Every call gets a query timeout (-t) so we never hang on a partially-up
# server. Server-certificate trust ($script:SqlTrustArgs) is decided once from the
# target: a loopback (or an explicit -TrustServerCertificate) trusts with -C; a
# remote target validates the certificate (no -C) so the login password is never
# presented to a forged endpoint.
function Invoke-Sqlcmd-Quiet {
    param(
        [string[]]$SqlArgs,
        [string]$Password,
        # T-SQL to run. When it embeds a secret (a password in ALTER/CREATE LOGIN),
        # pass it here rather than as `-Q` in $SqlArgs: it is written to an
        # Administrators-only temp file and run via `-i`, so the statement text
        # never lands on the sqlcmd process command line (visible in the process
        # list / auditable via event 4688 / Sysmon). The file is deleted in finally.
        [string]$QueryText,
        [switch]$FailOnSqlError
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # Pass the password via SQLCMDPASSWORD instead of -P so it never lands on the
    # sqlcmd process command line (visible in the process list); cleared right
    # after the call. Windows-authentication (-E) callers pass no -Password.
    if ($Password) { $env:SQLCMDPASSWORD = $Password }
    # -b makes sqlcmd return a non-zero exit code on a SQL error (severity >= 11),
    # so a policy rejection (e.g. a weak password failing CHECK_POLICY) fails
    # loudly instead of silently returning 0. Set only on the DDL/provisioning
    # calls; the readiness and connection probes below intentionally read exit
    # codes and must not treat an expected failure as fatal.
    if ($FailOnSqlError) { $SqlArgs += "-b" }
    $queryFile = $null
    if ($QueryText) {
        # Create the temp file, lock its access control list down to Administrators + SYSTEM (no
        # inheritance) BEFORE writing the secret, then hand it to sqlcmd via -i.
        $queryFile = [System.IO.Path]::GetTempFileName()
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
            $account = New-Object System.Security.Principal.SecurityIdentifier $sid
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($account, 'FullControl', 'Allow')))
        }
        Set-Acl -Path $queryFile -AclObject $acl
        Set-Content -Path $queryFile -Value $QueryText -Encoding UTF8
        $SqlArgs += @('-i', $queryFile)
    }
    try {
        # Keep the output (stderr folded in) so a failing caller can show WHY
        # sqlcmd failed. SQL error messages never echo the statement text, so
        # secrets in $QueryText don't leak through it.
        $script:LastSqlcmdOutput = (& sqlcmd @SqlArgs @script:SqlTrustArgs -t 10 2>&1 | ForEach-Object { "$_" }) -join [Environment]::NewLine
    } finally {
        $ErrorActionPreference = $prev
        if ($Password) { Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue }
        if ($queryFile) { Remove-Item $queryFile -Force -ErrorAction SilentlyContinue }
    }
    return $LASTEXITCODE
}

if ($isRemote) {
    # Remote target: no service to wait on. Confirm the SQL admin can reach the
    # (pre-created) target database before provisioning, so a missing database,
    # a blocked firewall, or a bad admin credential fails here with an actionable
    # message rather than mid-provision.
    Write-Host "Verifying SQL admin connectivity to '$DatabaseName' on $SqlServerHost..."
    $ec = Invoke-Sqlcmd-Quiet -SqlArgs ($adminConnArgs + @('-d', $DatabaseName, '-Q', 'SELECT 1', '-l', '15')) -Password $adminConnPassword
    if ($ec -ne 0) {
        throw @"
Could not connect to database '$DatabaseName' on '$SqlServerHost' as '$SqlAdminUsername' (sqlcmd exit code $ec).
On a managed target (e.g. Azure SQL) this script does NOT create the database; provision it first:
  * the logical SQL server with SQL authentication enabled and an admin login,
  * a firewall rule allowing this client's public IP,
  * an empty database named '$DatabaseName'.
Also verify -SqlAdminUsername/-SqlAdminPassword. sqlcmd output: $script:LastSqlcmdOutput
"@
    }
    Write-Host "SQL admin connectivity confirmed."
} else {
    # After a service restart, SQL Server's status goes Running before it's
    # actually accepting queries. Loop with Windows-authentication probes until a SELECT 1
    # succeeds or we time out.
    Write-Host "Waiting for SQL Server to accept queries..."
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        $ec = Invoke-Sqlcmd-Quiet @("-S", "(local)", "-E", "-Q", "SELECT 1", "-l", "3")
        if ($ec -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        throw "SQL Server did not become ready within ~60 seconds. Check the service is running. Last sqlcmd output: $script:LastSqlcmdOutput"
    }
    Write-Host "SQL Server is responding."

    # Verify the TCP listener is up. SQL authentication over TCP is validated later as the app
    # login (the final connection check), so no sa round-trip is needed here.
    $listener = Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue
    if (-not $listener) {
        throw "No listener on TCP 1433 after restart. Check Windows Firewall."
    }

    # Create the Admin App database if it doesn't already exist. Remote targets skip
    # this: the managed database is created out of band through the Azure control plane.
    Write-Host "Ensuring database '$DatabaseName' exists..."
    $dbQuery = "IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$DatabaseName') CREATE DATABASE [$DatabaseName];"
    $ec = Invoke-Sqlcmd-Quiet -SqlArgs @("-S", "(local)", "-E", "-Q", $dbQuery) -FailOnSqlError
    if ($ec -ne 0) {
        throw "Failed to create/verify database '$DatabaseName' (sqlcmd exit code $ec). sqlcmd output: $script:LastSqlcmdOutput"
    }
    Write-Host "Database '$DatabaseName' is present."
}

# Provision the dedicated, least-privilege login the Admin App connects as. It is
# made db_owner of the Admin App database ONLY -- it holds no server-level role,
# so unlike sa it cannot touch other databases, create logins, or drop the server.
# db_owner (rather than datareader/datawriter/EXECUTE) is required because the app
# self-migrates on boot (DB_RUN_MIGRATIONS) and the job queue creates tables at
# runtime, both of which need DDL on this database. Idempotent: creates the principal
# on first run, re-syncs the password on re-run. Bracket-quoted identifiers are
# escaped to keep a ']' in a custom name from breaking the batch.
#
# The shape differs by target because Azure SQL supports neither a server `CREATE
# LOGIN` nor a `USE [db]` context switch:
# - local: server LOGIN + database USER mapped to it, via a `USE [db]` batch;
# - remote: a CONTAINED database user (`CREATE USER ... WITH PASSWORD`) created
#   directly in the target database (the admin connection is already scoped to it).
Write-Host "Provisioning the Admin App login '$AppDbUsername'..."
$safeUser = $AppDbUsername -replace ']', ']]'
$escapedAppPw = $AppDbPasswordPlain -replace "'", "''"
if ($isRemote) {
    $provisionQuery = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$AppDbUsername')
    CREATE USER [$safeUser] WITH PASSWORD = N'$escapedAppPw';
ELSE
    ALTER USER [$safeUser] WITH PASSWORD = N'$escapedAppPw';
ALTER ROLE db_owner ADD MEMBER [$safeUser];
"@
    $ec = Invoke-Sqlcmd-Quiet -SqlArgs ($adminConnArgs + @('-d', $DatabaseName)) -QueryText $provisionQuery -Password $adminConnPassword -FailOnSqlError
} else {
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
    $ec = Invoke-Sqlcmd-Quiet -SqlArgs $adminConnArgs -QueryText $provisionQuery -Password $adminConnPassword -FailOnSqlError
}
if ($ec -ne 0) {
    throw "Failed to provision the Admin App login '$AppDbUsername' (sqlcmd exit code $ec). A password-policy failure here means the password is too weak; supply a stronger -AppDbPassword. sqlcmd output: $script:LastSqlcmdOutput"
}

# Verify the app login can connect over TCP with SQL authentication (how the app connects).
$ec = Invoke-Sqlcmd-Quiet -SqlArgs @("-S", $appServer, "-U", $AppDbUsername, "-d", $DatabaseName, "-Q", "SELECT 1") -Password $AppDbPasswordPlain
if ($ec -ne 0) {
    throw "The Admin App login '$AppDbUsername' could not connect over TCP to '$DatabaseName' on '$SqlServerHost' (sqlcmd exit code $ec). sqlcmd output: $script:LastSqlcmdOutput"
}
Write-Host "Admin App login '$AppDbUsername' is provisioned (db_owner on '$DatabaseName', non-sysadmin) and verified."

Write-Host ""
if ($isRemote) {
    Write-Host "SUCCESS: remote SQL target '$SqlServerHost' is ready for the Admin App." -ForegroundColor Green
} else {
    Write-Host "SUCCESS: SQL Server is configured for Mixed Mode + TCP/IP." -ForegroundColor Green
}
Write-Host "The Admin App connects as '$AppDbUsername' (MSSQL_DB_USERNAME) -- a non-sysadmin login, not sa." -ForegroundColor Yellow
