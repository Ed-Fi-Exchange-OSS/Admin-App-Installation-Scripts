#Requires -RunAsAdministrator
<#
.SYNOPSIS
Master installer for the Ed-Fi Admin App on Windows IIS. Fully automated.

Runs in three phases with no manual interaction required.

  Phase 1 — Prereqs
    02-prereqs-sql.ps1        SQL Server Mixed Mode + TCP/IP + sa + app login
    01-prereqs-iis.ps1        URL Rewrite + httpPlatform handler + unlock handlers (HTTPS added at deploy time)
    03-prereqs-node.ps1       Node.js (the npm cache is set later, by 05-deploy-api)

  Phase 2 — Build
    04-build.ps1              npm ci + build:api + build:fe (slow)

  Phase 3 — Deploy
    idp-keycloak-setup.ps1    JDK + Keycloak download + start + realm/client/user
    05-deploy-api.ps1         Deploy API to IIS
    06-deploy-fe.ps1          Deploy FE to IIS

Re-run modes:
  Default               Run all three phases end-to-end
  -SkipPhase1           Skip prereqs (already done)
  -SkipPhase2           Skip build (artifacts already present)
  -OnlyPhase1           Run prereqs only

If you'd rather build manually, use -SkipPhase2 and run the build yourself
before re-running.

.PARAMETER DbEngine
'mssql' (default) or 'pgsql'. Drives which DB prereq path runs and how
production.js gets patched. 'mssql' requires -SaPassword and -AppDbPassword.
'pgsql' requires -PostgresAppPassword.

.PARAMETER UsePostgresDocker
Switch. When -DbEngine is 'pgsql', also start the docker-compose Postgres in
windows-install\docker\ before deploying. Generates a docker .env from the
postgres defaults in production.js-edfi + the passwords you provide.

.PARAMETER PostgresAppPassword
Required when -DbEngine is 'pgsql'. Becomes ADMIN_APP_DB_PASSWORD in the
docker .env (when -UsePostgresDocker) and DB_PASSWORD in production.js.

.PARAMETER PostgresSuperuserPassword
Required when -UsePostgresDocker is set. Becomes POSTGRES_PASSWORD in the
docker .env -- used only by docker-entrypoint and the init script that
provisions the dedicated app user.

.PARAMETER PostgresHost / -PostgresPort / -PostgresAppUser
PostgreSQL connection details written into production.js. Defaults match the
docker-compose setup ('localhost', 5432, 'edfiadminapp').

.PARAMETER SaPassword
SQL Server sa password. Required when -DbEngine is 'mssql' (the default). Used
only for server-level bootstrap and the installer's own admin queries; the Admin
App does not connect as sa.

.PARAMETER AppDbUsername / -AppDbPassword
The dedicated least-privilege SQL login the Admin App connects as at runtime
(db_owner on the app DB, not a server sysadmin). -AppDbPassword is required when
-DbEngine is 'mssql'. -AppDbUsername defaults to 'edfi_adminapp'. Written into
production.js as MSSQL_DB_USERNAME / MSSQL_DB_PASSWORD.

.PARAMETER IdpProvider
Identity provider (mandatory): keycloak | microsoft | google | other. 'keycloak'
stands up the local example IdP and provisions the realm/client/user. The others
target an external OIDC provider you register yourself; the AdminApp's auth engine
is provider-agnostic (OIDC discovery).

.PARAMETER OidcClientSecret
OIDC client secret (mandatory, all modes): the secret of the AdminApp's OIDC client
-- the one Keycloak sets on the edfiadminapp client, or the one from your external
provider.

.PARAMETER OidcIssuer
OIDC issuer URL. Defaulted for keycloak and google; required for microsoft and other.

.PARAMETER OidcClientId
OIDC client id. Defaulted for keycloak (edfiadminapp); required for the external modes.

.PARAMETER OidcScope
OIDC scopes requested at login. Default: 'openid email profile'.

.PARAMETER ViteIdpAccountUrl
The IdP account-management URL the FE links to. Defaulted per provider (keycloak,
microsoft, google); required for 'other'.

.PARAMETER KeycloakAdminPassword
(keycloak mode only) Password for the master-realm Keycloak admin, bootstrapped on
first start. Subsequent runs ignore it — make sure it matches an existing admin.

.PARAMETER TestUserPassword
(keycloak mode only) Password for the seeded test user that Keycloak creates.

.PARAMETER SourcePath
Path to the cloned Ed-Fi-AdminApp repo. Defaults to the parent of the script
directory — i.e., the scripts live in <repo>\windows-install\ and the repo
root is one level up. Override only if your layout differs.

.PARAMETER DatabaseName
SQL Server database name. Default: sbaa. Propagated to 02 (creates the DB) and
05 (patches MSSQL_DB_DATABASE in production.js).

.PARAMETER AdminUsername
Email seeded as the admin user. Default: admin@example.com.

.PARAMETER JdkDownloadUrl
Optional HTTPS URL to an OpenJDK zip; idp-keycloak-setup.ps1 will install + set
JAVA_HOME. Requires -JdkSha256.

.PARAMETER JdkSha256
Expected SHA-256 of the JDK zip named by -JdkDownloadUrl. Required whenever
-JdkDownloadUrl is supplied so the download can be integrity-verified.

.PARAMETER IncludeAudienceMapper
Switch — add the Keycloak audience mapper (needed for bearer-token API access).

.PARAMETER EnableDirectAccessGrants
Switch — enable password grant on the Keycloak client (testing only).

.PARAMETER AcceptRisks
Switch — bypass the y/N confirmation when 00-check-prereqs flags collision
risks (e.g., another app sharing the SQL instance, a non-OpenJDK-21 'java' on
PATH, ports 3333/4200/3443/4443 already in use). Use for non-interactive runs only after
reviewing the [RISK] items.

.PARAMETER AutoUpgradeNode
Switch — when 03-prereqs-node.ps1 detects a too-old Node on PATH, skip the y/N
confirmation and proceed with nvm-windows + Node LTS setup automatically.
For non-interactive runs. Passed through as -AssumeYes to 03-prereqs-node.ps1.

.PARAMETER YopassUrl
URL of an EXISTING Yopass service to use for sharing newly-created Ed-Fi API
client credentials. Default empty — Yopass is disabled and the AdminApp falls
back to displaying credentials inline (a supported AdminApp configuration).
Pass e.g. -YopassUrl 'http://yopass.internal:8082' to enable it against a
pre-existing deployment. Mutually exclusive with -SetupYopassDocker.

.PARAMETER SetupYopassDocker
Switch — stand up a local Yopass service (Yopass + memcached) via the bundled
docker\docker-compose.yopass.yml during phase 1, then point the AdminApp at it
(USE_YOPASS=true, YOPASS_URL=http://localhost:<YopassPort>). Requires Docker
Desktop. Mutually exclusive with -YopassUrl. This is the "set up Yopass for me"
path; without either flag Yopass stays disabled.

.PARAMETER YopassPort
Host port to publish the dockerized Yopass on when -SetupYopassDocker is set.
Default 8082. Becomes the YOPASS_URL the API is configured with.

.EXAMPLE
# Local Keycloak (MSSQL). Password/secret params are [SecureString]: omit any to
# be prompted securely, or pass them inline as shown -- never a plaintext literal.
.\install-all.ps1 -IdpProvider keycloak `
  -SaPassword (Read-Host -AsSecureString 'sa password') `
  -AppDbPassword (Read-Host -AsSecureString 'Admin App DB password') `
  -KeycloakAdminPassword (Read-Host -AsSecureString 'Keycloak admin password') `
  -OidcClientSecret (Read-Host -AsSecureString 'OIDC client secret') `
  -TestUserPassword (Read-Host -AsSecureString 'test user password')

.EXAMPLE
# Local Keycloak (PostgreSQL via the bundled docker-compose)
.\install-all.ps1 -IdpProvider keycloak `
  -DbEngine pgsql -UsePostgresDocker `
  -PostgresSuperuserPassword (Read-Host -AsSecureString 'Postgres superuser password') `
  -PostgresAppPassword (Read-Host -AsSecureString 'Postgres app password') `
  -KeycloakAdminPassword (Read-Host -AsSecureString 'Keycloak admin password') `
  -OidcClientSecret (Read-Host -AsSecureString 'OIDC client secret') `
  -TestUserPassword (Read-Host -AsSecureString 'test user password')

.EXAMPLE
# Local Keycloak + a local dockerized Yopass for one-time credential links
.\install-all.ps1 -IdpProvider keycloak `
  -SaPassword (Read-Host -AsSecureString 'sa password') `
  -AppDbPassword (Read-Host -AsSecureString 'Admin App DB password') `
  -KeycloakAdminPassword (Read-Host -AsSecureString 'Keycloak admin password') `
  -OidcClientSecret (Read-Host -AsSecureString 'OIDC client secret') `
  -TestUserPassword (Read-Host -AsSecureString 'test user password') `
  -SetupYopassDocker

.EXAMPLE
# External OIDC (Microsoft Entra). Register the app + redirect URIs in Entra first,
# and make sure a user exists there whose email matches -AdminUsername.
.\install-all.ps1 -IdpProvider microsoft `
  -SaPassword (Read-Host -AsSecureString 'sa password') `
  -AppDbPassword (Read-Host -AsSecureString 'Admin App DB password') `
  -OidcIssuer 'https://login.microsoftonline.com/<tenant-id>/v2.0' `
  -OidcClientId '<application-id>' `
  -OidcClientSecret (Read-Host -AsSecureString 'Entra client secret') `
  -AdminUsername 'you@yourtenant.onmicrosoft.com'
#>

param(
    [ValidateSet('mssql','pgsql')]
    [string]$DbEngine = 'mssql',
    [switch]$UsePostgresDocker,

    # sa is used only for server-level bootstrap (Mixed Mode, DB creation, and
    # the installer's own admin queries). The Admin App itself connects as the
    # dedicated least-privilege login below, not sa.
    [SecureString]$SaPassword,
    [string]$AppDbUsername = "edfi_adminapp",
    [SecureString]$AppDbPassword,
    [SecureString]$PostgresAppPassword,
    [SecureString]$PostgresSuperuserPassword,
    [string]$PostgresHost = "localhost",
    [int]$PostgresPort = 5432,
    [string]$PostgresAppUser = "edfiadminapp",

    # Identity provider. Mandatory -- choose consciously. 'keycloak' stands up a
    # local Keycloak (the example IdP); the others deploy against an external OIDC
    # provider you register yourself (the client + user live in that provider).
    [Parameter(Mandatory = $true)]
    [ValidateSet('keycloak','microsoft','google','other')]
    [string]$IdpProvider,

    # OIDC client secret -- required in every mode (the secret of the AdminApp's
    # OIDC client, whether in Keycloak or in your external provider).
    [Parameter(Mandatory = $true)]
    [SecureString]$OidcClientSecret,

    # OIDC settings for external providers. Defaults are filled per -IdpProvider;
    # supply -OidcIssuer / -OidcClientId for microsoft and other.
    [string]$OidcIssuer = "",
    [string]$OidcClientId = "",
    [string]$OidcScope = "openid email profile",
    [string]$ViteIdpAccountUrl = "",

    # Keycloak-only (required when -IdpProvider is 'keycloak'): the master-realm
    # admin password and the seeded test user's password.
    [SecureString]$KeycloakAdminPassword,
    [SecureString]$TestUserPassword,

    [string]$SourcePath = (Split-Path $PSScriptRoot -Parent),
    [string]$DatabaseName = "sbaa",
    [string]$AdminUsername = "admin@example.com",
    [string]$JdkDownloadUrl,
    [string]$JdkSha256,

    [switch]$IncludeAudienceMapper,
    [switch]$EnableDirectAccessGrants,

    [switch]$SkipPhase1,
    [switch]$SkipPhase2,
    [switch]$OnlyPhase1,
    [switch]$SkipPreflightCheck,
    [switch]$AcceptRisks,
    [switch]$AutoUpgradeNode,

    # Yopass: three modes.
    #   (neither flag)        -> disabled, USE_YOPASS=false (credentials inline)
    #   -YopassUrl <url>      -> enable against an existing Yopass
    #   -SetupYopassDocker    -> stand up a local Yopass via docker, auto-URL
    [string]$YopassUrl = "",
    [switch]$SetupYopassDocker,
    [int]$YopassPort = 8082,

    # TLS (always-on). HTTPS ports for the two sites (mirror the HTTP 3333/4200).
    # The certificate is resolved by 05-deploy-api.ps1 and reused by 06-deploy-fe.ps1
    # (self-signed fallback keyed on FriendlyName), so both sites share one cert.
    # Supply a real cert via -CertificateThumbprint or -CertificatePfxPath
    # (+ -CertificatePassword); omit both to auto-generate a self-signed cert.
    [int]$HttpsApiPort = 3443,
    [int]$HttpsFePort = 4443,
    [string]$CertificateThumbprint = "",
    [string]$CertificatePfxPath = "",
    [SecureString]$CertificatePassword,

    # By default an auto-generated self-signed cert is added to LocalMachine\Root so
    # local browsers trust it. Set this to skip that (browser shows "Not Secure");
    # only affects the self-signed path, not a supplied real cert.
    [switch]$SkipSelfSignedTrust,

    # Disable SSL verification for the API's outbound HTTPS calls (ODS/API, AdminApi,
    # Yopass). Secure by default; set only for self-signed upstreams in non-production.
    [switch]$DisableSslVerification,

    # Keycloak only: register a startup Scheduled Task so the example IdP survives a
    # reboot (otherwise it must be restarted by re-running idp-keycloak-start.ps1).
    # Requires an elevated shell. Off by default.
    [switch]$RegisterKeycloakStartupTask
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

# Reject a weak DB-login password the moment each is resolved (whether passed as a
# param or prompted), before any phase runs, so a weak password fails immediately
# and next to the prompt that set it -- not later, after an unrelated prompt, as an
# opaque CHECK_POLICY rejection during MSSQL login provisioning. Mirrors the Windows
# policy CHECK_POLICY enforces: length >= 8 and at least 3 of the 4 character
# categories (uppercase/lowercase/digit/symbol). Postgres enforces no such policy,
# but its logins are held to the same bar for consistency. -cmatch keeps the
# upper/lower test case-sensitive; AllowEmptyString lets an empty password reach the
# length check with a clear message instead of a parameter-binding error.
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

# Engine-specific required-arg resolution. SaPassword was previously a top-level
# Mandatory parameter; it's now conditionally required so the same script can drive
# either engine without prompting for irrelevant credentials. Each secret is
# prompted (if omitted), unwrapped, and strength-checked together, so validation is
# tied to its own prompt. Plaintext is unavoidable at the point of use -- sqlcmd -P,
# the docker-compose .env, PGPASSWORD -- so it lives in locals, never on a command
# line or in the param history. Child scripts still receive the SecureStrings
# unchanged. Locals are initialized so later references hold $null under either engine.
$SaPasswordPlain                = $null
$AppDbPasswordPlain             = $null
$PostgresAppPasswordPlain       = $null
$PostgresSuperuserPasswordPlain = $null

if ($DbEngine -eq 'mssql') {
    if (-not $SaPassword)    { $SaPassword = Read-Host -AsSecureString "SQL Server 'sa' password (server bootstrap only)" }
    $SaPasswordPlain = [System.Net.NetworkCredential]::new('', $SaPassword).Password
    Test-SqlPasswordComplexity -Password $SaPasswordPlain -Label "sa (-SaPassword)"

    if (-not $AppDbPassword) { $AppDbPassword = Read-Host -AsSecureString "Admin App DB login '$AppDbUsername' password" }
    $AppDbPasswordPlain = [System.Net.NetworkCredential]::new('', $AppDbPassword).Password
    Test-SqlPasswordComplexity -Password $AppDbPasswordPlain -Label "Admin App DB login (-AppDbPassword)"
}
if ($DbEngine -eq 'pgsql') {
    if (-not $PostgresAppPassword) { $PostgresAppPassword = Read-Host -AsSecureString "Postgres app user '$PostgresAppUser' password" }
    $PostgresAppPasswordPlain = [System.Net.NetworkCredential]::new('', $PostgresAppPassword).Password
    Test-SqlPasswordComplexity -Password $PostgresAppPasswordPlain -Label "Postgres app user (-PostgresAppPassword)"
}
if ($UsePostgresDocker -and $DbEngine -ne 'pgsql') {
    throw "-UsePostgresDocker only applies when -DbEngine is 'pgsql'."
}
if ($UsePostgresDocker) {
    if (-not $PostgresSuperuserPassword) { $PostgresSuperuserPassword = Read-Host -AsSecureString "Postgres superuser password" }
    $PostgresSuperuserPasswordPlain = [System.Net.NetworkCredential]::new('', $PostgresSuperuserPassword).Password
    Test-SqlPasswordComplexity -Password $PostgresSuperuserPasswordPlain -Label "Postgres superuser (-PostgresSuperuserPassword)"
}

# Yopass: -SetupYopassDocker (stand one up) and -YopassUrl (use an existing one)
# are two ways to set the same YOPASS_URL, so they can't both be given.
if ($SetupYopassDocker -and $YopassUrl) {
    throw "-SetupYopassDocker and -YopassUrl are mutually exclusive: the first stands up a Yopass and derives its URL, the second points at an existing one. Pass at most one (or neither, to leave Yopass disabled)."
}
# Resolve the effective YOPASS_URL up front so phase 3 can configure the API
# regardless of which phases run. -SetupYopassDocker implies http://localhost:<port>;
# the actual container is brought up in phase 1 below.
$EffectiveYopassUrl = if ($SetupYopassDocker) { "http://localhost:$YopassPort" } else { $YopassUrl }

# IdP provider resolution. 'keycloak' uses the local example IdP (it provisions
# the realm/client/user); the others target an external OIDC provider you
# register yourself. Fill per-provider defaults and validate required values.
$idpIsKeycloak = ($IdpProvider -eq 'keycloak')
if ($idpIsKeycloak) {
    if (-not $KeycloakAdminPassword) { $KeycloakAdminPassword = Read-Host -AsSecureString "Keycloak master-realm admin password" }
    if (-not $TestUserPassword)      { $TestUserPassword = Read-Host -AsSecureString "Keycloak test user password" }
    if (-not $OidcIssuer)        { $OidcIssuer = "http://localhost:8080/realms/edfi" }
    if (-not $OidcClientId)      { $OidcClientId = "edfiadminapp" }
    if (-not $ViteIdpAccountUrl) { $ViteIdpAccountUrl = "http://localhost:8080/realms/edfi/account/" }
} else {
    switch ($IdpProvider) {
        'microsoft' { if (-not $ViteIdpAccountUrl) { $ViteIdpAccountUrl = "https://myaccount.microsoft.com/" } }
        'google'    {
            if (-not $OidcIssuer)        { $OidcIssuer = "https://accounts.google.com" }
            if (-not $ViteIdpAccountUrl) { $ViteIdpAccountUrl = "https://myaccount.google.com/" }
        }
    }
    if (-not $OidcIssuer)        { throw "-OidcIssuer is required when -IdpProvider is '$IdpProvider'." }
    if (-not $OidcClientId)      { throw "-OidcClientId is required when -IdpProvider is '$IdpProvider'." }
    if (-not $ViteIdpAccountUrl) { throw "-ViteIdpAccountUrl is required when -IdpProvider is '$IdpProvider' (the IdP account-management URL the FE links to)." }
}

# TLS (always-on): the FE bundle bakes the API URL at build time, and 05/06 read
# their URLs from these too, so derive both as https on the mirror ports.
$ApiUrl = "https://localhost:$HttpsApiPort"
$FeUrl  = "https://localhost:$HttpsFePort"

function Write-Phase {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

# Sanity-check that $SourcePath looks like an AdminApp repo before we try to
# build / deploy from it. The user got the scripts by cloning (or unzipping)
# the repo, so this should always pass on the default; only fires if someone
# overrode -SourcePath to a wrong directory.
if (-not (Test-Path "$SourcePath\package.json")) {
    throw "Expected AdminApp repo at '$SourcePath' but no package.json found. Pass -SourcePath if the repo is elsewhere."
}

# Node runtime: install Node (or remediate a too-old version via nvm) and set the
# npm cache override. Runs unconditionally and BEFORE the pre-flight check so a
# missing or stale Node doesn't fail the diagnostic. Idempotent: a no-op when
# Node is already current and the cache is set.
Write-Phase "Node runtime (03-prereqs-node.ps1)"
$nodeArgs = @{ SourcePath = $SourcePath }
if ($AutoUpgradeNode) { $nodeArgs.AssumeYes = $true }
& "$scriptDir\03-prereqs-node.ps1" @nodeArgs

# Pre-flight: run 00-check-prereqs.ps1 to validate manual prereqs are in place.
# Exit codes from 00:
#   0 = clean
#   1 = blocking FAIL items, install must not proceed
#   2 = ready, but [RISK] items present (collisions with existing software);
#       prompt the user to confirm unless -AcceptRisks was passed
if (-not $SkipPreflightCheck) {
    Write-Phase "Pre-flight check (00-check-prereqs.ps1)"
    & "$scriptDir\00-check-prereqs.ps1" -SourcePath $SourcePath -DatabaseName $DatabaseName -DbEngine $DbEngine -SetupYopassDocker:$SetupYopassDocker -YopassPort $YopassPort
    $preflightExit = $LASTEXITCODE
    if ($preflightExit -eq 1) {
        throw "Pre-flight check failed. Fix the [FAIL] items above and re-run, or pass -SkipPreflightCheck to bypass (not recommended)."
    } elseif ($preflightExit -eq 2) {
        if ($AcceptRisks) {
            Write-Host ""
            Write-Host "Collision risks acknowledged via -AcceptRisks. Proceeding." -ForegroundColor Magenta
        } else {
            Write-Host ""
            Write-Host "The pre-flight flagged [RISK] items above -- the install will modify state" -ForegroundColor Magenta
            Write-Host "that another app on this machine may depend on (SQL instance config, PATH" -ForegroundColor Magenta
            Write-Host "ordering of 'java', ports 3333/4200/3443/4443, etc.)." -ForegroundColor Magenta
            $reply = Read-Host "Continue anyway? (y/N)"
            if ($reply -notmatch '^[Yy]') {
                throw "Aborted by user. Re-run with -AcceptRisks to skip this prompt next time."
            }
        }
    } elseif ($preflightExit -ne 0) {
        throw "Pre-flight check returned unexpected exit code $preflightExit."
    }
}

# ---------- Phase 1 — Prereqs ----------
if (-not $SkipPhase1) {
    if ($DbEngine -eq 'mssql') {
        Write-Phase "Phase 1.1: SQL Server prereqs (02-prereqs-sql.ps1)"
        & "$scriptDir\02-prereqs-sql.ps1" -SaPassword $SaPassword -AppDbUsername $AppDbUsername -AppDbPassword $AppDbPassword -DatabaseName $DatabaseName
    } else {
        Write-Phase "Phase 1.1: PostgreSQL prereqs"
        if ($UsePostgresDocker) {
            # Generate windows-install\docker\.env from the postgres defaults of
            # production.js-edfi (so the docker container, the app config, and
            # the documented defaults all agree on user/db/port), then bring
            # the container up and wait for it to accept connections.
            $dockerDir = Join-Path $scriptDir "docker"
            if (-not (Test-Path "$dockerDir\docker-compose.yml")) {
                throw "docker-compose.yml not found at $dockerDir. Expected the docker folder to ship alongside the install scripts."
            }
            if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
                throw "docker is not on PATH. Install Docker Desktop and ensure 'docker compose' works before re-running with -UsePostgresDocker."
            }

            $envPath = Join-Path $dockerDir ".env"
            $envBody = @"
# Generated by install-all.ps1 -- do not edit by hand. Values mirror
# DB_SECRET_VALUE postgres defaults in production.js-edfi and the args
# passed to install-all.
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$PostgresSuperuserPasswordPlain
ADMIN_APP_DB_NAME=$DatabaseName
ADMIN_APP_DB_USER=$PostgresAppUser
ADMIN_APP_DB_PASSWORD=$PostgresAppPasswordPlain
POSTGRES_PORT_EXPOSED=$PostgresPort
"@
            Set-Content -Path $envPath -Value $envBody -Encoding UTF8
            Write-Host "Wrote $envPath"

            # The .env holds the Postgres passwords in plaintext -- it's the
            # mechanism docker-compose reads them from, so the file has to exist,
            # but restrict it to Administrators + SYSTEM (well-known SIDs) so it
            # isn't world-readable. docker compose runs elevated and can still
            # read it. Warn rather than abort on failure.
            try {
                $envAcl = New-Object System.Security.AccessControl.FileSecurity
                $envAcl.SetAccessRuleProtection($true, $false)
                foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
                    $envId = New-Object System.Security.Principal.SecurityIdentifier($sid)
                    $envAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($envId, 'FullControl', 'Allow')))
                }
                Set-Acl -Path $envPath -AclObject $envAcl
            } catch {
                Write-Warning "Could not restrict the ACL on $envPath ($($_.Exception.Message)). It holds the Postgres passwords -- protect it manually."
            }

            Push-Location $dockerDir
            try {
                Write-Host "Starting docker compose (postgres)..."
                & docker compose up -d
                if ($LASTEXITCODE -ne 0) {
                    throw "docker compose up failed (exit code $LASTEXITCODE)."
                }

                Write-Host "Waiting for postgres to accept connections..."
                $ready = $false
                for ($i = 0; $i -lt 30; $i++) {
                    & docker exec edfiadminapp-postgres pg_isready -U postgres -d $DatabaseName 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
                    Start-Sleep -Seconds 2
                }
                if (-not $ready) {
                    throw "postgres container did not become ready within ~60 seconds. Check 'docker compose logs postgres'."
                }
                Write-Host "Postgres is ready." -ForegroundColor Green

                # Idempotent re-run safety: docker compose only runs init/*.sh on a
                # FRESH data volume, so a persistent volume from an earlier install
                # keeps the old edfiadminapp password (and, on a pre-hardening
                # volume, the old schema ownership). Re-align both to the SAME
                # least-privilege model init/01-create-adminapp-user.sh applies on a
                # fresh volume: the app user CONNECTs, has CREATE on the database
                # (for the citext extension and the pgboss job-queue schema it
                # creates at boot), and OWNS the public schema, so it can self-migrate
                # its own tables -- it stays a non-superuser and needs no database-wide
                # GRANT ALL. Tables/sequences created by earlier TypeORM runs are
                # already owned by this user (the app connects as itself), so schema
                # ownership is sufficient. Run as the postgres superuser.
                Write-Host "Synchronizing $PostgresAppUser password + privileges (idempotent, least-privilege)..."
                $syncSql = @"
ALTER USER "$PostgresAppUser" WITH PASSWORD '$PostgresAppPasswordPlain';
GRANT CONNECT, CREATE ON DATABASE "$DatabaseName" TO "$PostgresAppUser";
ALTER SCHEMA public OWNER TO "$PostgresAppUser";
"@
                # Pass the password through the environment, never on the command
                # line: `docker exec -e PGPASSWORD` (no value) forwards it from
                # this process, so the secret stays out of the docker argv.
                $env:PGPASSWORD = $PostgresSuperuserPasswordPlain
                try {
                    $syncSql | & docker exec -i -e PGPASSWORD edfiadminapp-postgres psql -U postgres -d $DatabaseName 2>&1 | Out-Null
                } finally {
                    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to sync $PostgresAppUser credentials/privileges (psql exit $LASTEXITCODE). Check that -PostgresSuperuserPassword matches the superuser password the docker container was first initialized with."
                }
                Write-Host "$PostgresAppUser password and privileges synced." -ForegroundColor Green
            } finally {
                Pop-Location
            }
        } else {
            Write-Host "Skipping docker bring-up (-UsePostgresDocker not set). Ensure an external Postgres is reachable at ${PostgresHost}:${PostgresPort} with user '$PostgresAppUser' and the password you passed via -PostgresAppPassword." -ForegroundColor Yellow
        }
    }

    Write-Phase "Phase 1.2: IIS prereqs (01-prereqs-iis.ps1)"
    & "$scriptDir\01-prereqs-iis.ps1"

    # Phase 1.3: stand up Yopass (only when asked). The derived URL was already
    # computed into $EffectiveYopassUrl; this just brings the container up so it
    # is ready by the time phase 3 configures and smoke-tests the API.
    if ($SetupYopassDocker) {
        Write-Phase "Phase 1.3: Yopass via docker (yopass-docker.ps1)"
        & "$scriptDir\yopass-docker.ps1" -YopassPort $YopassPort | Out-Null
    }

    Write-Host ""
    Write-Host "Phase 1 complete." -ForegroundColor Green

    # Refresh the current process's PATH from the registry so subsequent child
    # processes (notably 04-build running npm) inherit Node's bin
    # directory even if winget just installed Node a moment ago in this same shell.
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

if ($OnlyPhase1) {
    Write-Host "Exiting after phase 1 (-OnlyPhase1)." -ForegroundColor Yellow
    return
}

# ---------- Phase 2 — Build ----------
if (-not $SkipPhase2) {
    Write-Phase "Phase 2: Build the project (04-build.ps1)"
    Write-Host "This takes several minutes. Output streams below."
    & "$scriptDir\04-build.ps1" -SourcePath $SourcePath -ViteIdpAccountUrl $ViteIdpAccountUrl -ViteApiUrl $ApiUrl
}

# Sanity checks before phase 3 -- build artifacts must exist. Keycloak is started
# by idp-keycloak-setup.ps1 in Phase 3.1, so it isn't checked here.
if (-not (Test-Path "$SourcePath\dist\packages\api\main.js")) {
    throw "$SourcePath\dist\packages\api\main.js missing. Build step skipped or failed."
}
if (-not (Test-Path "$SourcePath\dist\packages\fe\index.html")) {
    throw "$SourcePath\dist\packages\fe\index.html missing. Build step skipped or failed."
}

# ---------- Phase 3 — Deploy ----------
if ($idpIsKeycloak) {
    Write-Phase "Phase 3.1: Keycloak setup (idp-keycloak-setup.ps1)"
    $kcArgs = @{
        AdminPassword = $KeycloakAdminPassword
        ClientSecret = $OidcClientSecret
        TestUserPassword = $TestUserPassword
        TestUserEmail = $AdminUsername
        ApiBaseUrl = $ApiUrl
        FeBaseUrl = $FeUrl
    }
    if ($JdkDownloadUrl) { $kcArgs.JdkDownloadUrl = $JdkDownloadUrl }
    if ($JdkSha256) { $kcArgs.JdkSha256 = $JdkSha256 }
    if ($IncludeAudienceMapper) { $kcArgs.IncludeAudienceMapper = $true }
    if ($EnableDirectAccessGrants) { $kcArgs.EnableDirectAccessGrants = $true }
    if ($RegisterKeycloakStartupTask) { $kcArgs.RegisterStartupTask = $true }
    & "$scriptDir\idp-keycloak-setup.ps1" @kcArgs
} else {
    Write-Phase "Phase 3.1: External OIDC provider ($IdpProvider)"
    Write-Host "Skipping local IdP setup -- using external provider '$IdpProvider'." -ForegroundColor Cyan
    $disco = "$($OidcIssuer.TrimEnd('/'))/.well-known/openid-configuration"
    Write-Host "Validating OIDC discovery at $disco ..."
    # PS 5.1's default ServicePointManager protocol can exclude TLS 1.2, which fails
    # the handshake to an external provider's discovery endpoint (Entra/Google all
    # require TLS 1.2+). Enable it for this call. (The local self-signed https smoke
    # test uses curl.exe instead, which sidesteps this .NET Framework limitation.)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        Invoke-RestMethod -Uri $disco -TimeoutSec 10 | Out-Null
        Write-Host "OIDC discovery reachable." -ForegroundColor Green
    } catch {
        throw "Could not reach the OIDC discovery endpoint at $disco. Check -OidcIssuer and connectivity. Original: $($_.Exception.Message)"
    }
    Write-Host ""
    Write-Host "Register these in your '$IdpProvider' OIDC client before logging in:" -ForegroundColor Yellow
    Write-Host "  Redirect URI:  $ApiUrl/api/auth/callback/<id>  (exact id confirmed at the end of this install)"
    Write-Host "  Post-logout:   $ApiUrl/api/auth/post-logout"
    Write-Host "  Web origin:    $FeUrl"
    Write-Host "  And a user whose email/username claim equals '$AdminUsername' (seeded as admin below)."
}

Write-Phase "Phase 3.2: Deploy API (05-deploy-api.ps1)"
$apiDestPath = "C:\inetpub\EdFi-AdminApp-API"
$apiArgs = @{
    SourcePath           = $SourcePath
    DestPath             = $apiDestPath
    DatabaseName         = $DatabaseName
    OidcIssuer           = $OidcIssuer
    OidcClientId         = $OidcClientId
    OidcClientSecret     = $OidcClientSecret
    OidcScope            = $OidcScope
    AdminUsername        = $AdminUsername
    DbEngine             = $DbEngine
    # Yopass: empty string -> 04 sets USE_YOPASS=false; a URL -> USE_YOPASS=true.
    # (Previously this wasn't forwarded, so -YopassUrl on install-all was a no-op.)
    YopassUrl            = $EffectiveYopassUrl
}
# TLS: https URLs + HTTPS port + cert. ApiUrl/FeUrl flow into production.js
# (MY_URL/FE_URL/WHITELISTED_REDIRECTS via NODE_CONFIG) so the OIDC callback is https.
# 05 resolves the cert (self-signed if none supplied) and 06 reuses it, so both
# sites share one certificate.
$apiArgs.ApiUrl = $ApiUrl
$apiArgs.FeUrl  = $FeUrl
$apiArgs.HttpsPort = $HttpsApiPort
if ($CertificateThumbprint) { $apiArgs.CertificateThumbprint = $CertificateThumbprint }
if ($CertificatePfxPath)    { $apiArgs.CertificatePfxPath    = $CertificatePfxPath }
if ($CertificatePassword)   { $apiArgs.CertificatePassword   = $CertificatePassword }
if ($SkipSelfSignedTrust)   { $apiArgs.SkipSelfSignedTrust   = $true }
if ($DisableSslVerification) { $apiArgs.DisableSslVerification = $true }
if ($DbEngine -eq 'mssql') {
    $apiArgs.AppDbUsername = $AppDbUsername
    $apiArgs.AppDbPassword = $AppDbPassword
} else {
    $apiArgs.PgDbHost     = $PostgresHost
    $apiArgs.PgDbPort     = $PostgresPort
    $apiArgs.PgDbUsername = $PostgresAppUser
    $apiArgs.PgDbPassword = $PostgresAppPassword
}
& "$scriptDir\05-deploy-api.ps1" @apiArgs

# Read back the resolved per-install encryption key (05 preserves an existing one
# or generates a fresh one) so the summary can record it for backup.
$DbEncryptionKey = ''
$deployedProdJs = "$apiDestPath\packages\api\config\production.js"
if ((Test-Path $deployedProdJs) -and ((Get-Content $deployedProdJs -Raw) -match "KEY: '([0-9a-f]{64})'")) {
    $DbEncryptionKey = $Matches[1]
}

Write-Phase "Phase 3.3: Deploy FE (06-deploy-fe.ps1)"
$feArgs = @{
    SourcePath = "$SourcePath\dist\packages\fe"
    ApiUrl     = $ApiUrl
    HttpsPort  = $HttpsFePort
}
if ($CertificateThumbprint) { $feArgs.CertificateThumbprint = $CertificateThumbprint }
if ($CertificatePfxPath)    { $feArgs.CertificatePfxPath    = $CertificatePfxPath }
if ($CertificatePassword)   { $feArgs.CertificatePassword   = $CertificatePassword }
if ($SkipSelfSignedTrust)   { $feArgs.SkipSelfSignedTrust   = $true }
& "$scriptDir\06-deploy-fe.ps1" @feArgs

# ---------- Smoke test ----------
Write-Phase "Smoke test: hitting the API"

# The API (node, launched by httpPlatform) lazy-starts on first request, so the first hit can be slow. Retry briefly.
# Smoke test via curl.exe. PS 5.1's Invoke-WebRequest can't reliably complete the
# TLS handshake to the self-signed https binding ("unexpected error on send"), even
# with a cert-validation bypass and Tls12 forced; curl.exe (bundled since Win10 1803
# / Server 2019) handles it. -k accepts the self-signed cert. ~3 minutes of retries:
# a fresh cold start runs migrations + catalog sync, which can exceed a minute on a
# slow box. The post-boot steps below are gated on this. A non-5xx (and non-000)
# status means node is up (401 without a token).
$apiOk = $false
for ($i = 0; $i -lt 36; $i++) {
    $code = & curl.exe -sk -o NUL -w "%{http_code}" "$ApiUrl/api/teams" 2>$null
    if ($code -match '^\d+$' -and [int]$code -ge 100 -and [int]$code -lt 500) { $apiOk = $true; break }
    Start-Sleep -Seconds 5
}

if ($apiOk) {
    Write-Host "API is responding at $ApiUrl/" -ForegroundColor Green

    # Wait for the [user] table to exist. TypeORM migrations run during Nest
    # bootstrap, which is triggered by the smoke test, but the smoke test gets
    # its 401 response before TypeORM necessarily finishes the seed migration.
    # Poll for the table for up to 30 seconds. Probe via the engine that
    # production.js is actually pointing at.
    Write-Host "Waiting for migrations to finish creating the [user] table..."
    $userTableReady = $false
    for ($i = 0; $i -lt 15; $i++) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($DbEngine -eq 'mssql') {
                # SQLCMDPASSWORD instead of -P keeps the password off the sqlcmd
                # process command line; cleared in the finally below.
                $env:SQLCMDPASSWORD = $SaPasswordPlain
                & sqlcmd -S "tcp:localhost,1433" -U sa -d $DatabaseName -Q "SET NOCOUNT ON; SELECT TOP 1 1 FROM [user];" 2>&1 | Out-Null
            } else {
                # Probe via the container's psql (postgres-only -- avoids
                # requiring psql.exe on the host) when docker is in play;
                # otherwise rely on psql being on PATH.
                # Pipe SQL via stdin instead of using -c, because PowerShell's
                # native-arg passing eats the double quotes around "user" (a
                # reserved word in postgres that has to stay quoted).
                $probeSql = 'SELECT 1 FROM "user" LIMIT 1;'
                # Pass the password through the environment (both branches read
                # it), never on the docker/psql command line; cleared in finally.
                $env:PGPASSWORD = $PostgresAppPasswordPlain
                if ($UsePostgresDocker) {
                    $probeSql | & docker exec -i -e PGPASSWORD edfiadminapp-postgres psql -U $PostgresAppUser -d $DatabaseName 2>&1 | Out-Null
                } elseif (Get-Command psql -ErrorAction SilentlyContinue) {
                    $probeSql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $DatabaseName 2>&1 | Out-Null
                } else {
                    # No way to probe -- assume ready and fall through to the upsert,
                    # which will surface any real failure.
                    $LASTEXITCODE = 0
                }
            }
        } finally {
            $ErrorActionPreference = $prev
            Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
            Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
        }
        if ($LASTEXITCODE -eq 0) { $userTableReady = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $userTableReady) {
        Write-Host "[user] table didn't appear within 30s. Migrations may have failed -- check the API log (logs\node-stdout.log)." -ForegroundColor Yellow
    }

    # Ensure the admin user exists with roleId=2. Three scenarios this handles:
    #   1. Seed migration ran and inserted the user with roleId=2 -- both
    #      statements below are no-ops.
    #   2. Migrations created the [user] table but the seed didn't fire (we
    #      observed this on a clean VM run) -- INSERT runs, user gets roleId=2.
    #   3. The user exists but with NULL roleId (auth-flow auto-create path) --
    #      UPDATE corrects it.
    Write-Host "Ensuring '$AdminUsername' exists with admin role..."
    if ($DbEngine -eq 'mssql') {
        $upsertQuery = @"
IF NOT EXISTS (SELECT 1 FROM [user] WHERE username = '$AdminUsername')
    INSERT INTO [user] (username, roleId, isActive) VALUES ('$AdminUsername', 2, 1);
UPDATE [user] SET roleId = 2, isActive = 1
    WHERE username = '$AdminUsername' AND (roleId IS NULL OR isActive = 0);
"@
        $env:SQLCMDPASSWORD = $SaPasswordPlain
        try {
            & sqlcmd -S "tcp:localhost,1433" -U sa -d $DatabaseName -Q $upsertQuery 1>$null 2>$null
            $upsertExit = $LASTEXITCODE
        } finally {
            Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
        }
    } else {
        # Postgres equivalent. The "user" identifier is a reserved word, so it
        # has to stay quoted; the column names "roleId"/"isActive" are
        # case-sensitive because TypeORM creates them with double quotes.
        $upsertQuery = @"
INSERT INTO "user" (username, "roleId", "isActive")
    VALUES ('$AdminUsername', 2, true)
    ON CONFLICT (username) DO NOTHING;
UPDATE "user" SET "roleId" = 2, "isActive" = true
    WHERE username = '$AdminUsername' AND ("roleId" IS NULL OR "isActive" = false);
"@
        # Pipe SQL via stdin: PowerShell's native-arg passing strips the
        # inner double quotes around "user" / "roleId" / "isActive" when they
        # ride along on `-c`, which makes psql see `user` (a reserved word)
        # and fail with a syntax error.
        # Pass the password through the environment (both branches read it),
        # never on the docker/psql command line; cleared in the finally.
        $env:PGPASSWORD = $PostgresAppPasswordPlain
        try {
            if ($UsePostgresDocker) {
                $upsertQuery | & docker exec -i -e PGPASSWORD edfiadminapp-postgres psql -U $PostgresAppUser -d $DatabaseName 1>$null 2>$null
                $upsertExit = $LASTEXITCODE
            } elseif (Get-Command psql -ErrorAction SilentlyContinue) {
                $upsertQuery | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $DatabaseName 1>$null 2>$null
                $upsertExit = $LASTEXITCODE
            } else {
                Write-Host "No psql available (and -UsePostgresDocker not set). Skipping admin-user upsert -- run it manually if login loops." -ForegroundColor Yellow
                $upsertExit = -1
            }
        } finally {
            Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        }
    }
    if ($upsertExit -eq 0) {
        Write-Host "Admin user present with roleId=2." -ForegroundColor Green
    } elseif ($upsertExit -gt 0) {
        Write-Host "Couldn't ensure admin user automatically (exit $upsertExit)." -ForegroundColor Yellow
        Write-Host "If login loops, run an INSERT into the [user] / `"user`" table manually with roleId=2 for '$AdminUsername'." -ForegroundColor Yellow
    }

    # Gap B (PR #234 Functionality review): the app builds each OIDC callback as
    # /api/auth/callback/<id> from the oidc row's auto-generated id
    # (oidc.strategy.ts), but the scripts assumed the seeded row is always id=1.
    # If a prior oidc row existed the new id != 1 and the registered redirect URI
    # no longer matches what the app sends -> login fails. Read the real id of the
    # row we manage (seeded/upserted for $OidcClientId) and use it for the redirect
    # URI. Runs for every provider; the id is a DB-row property, not provider-specific.
    $oidcRowId = 1
    $oidcClientIdSql = $OidcClientId -replace "'", "''"
    if ($DbEngine -eq 'mssql') {
        $env:SQLCMDPASSWORD = $SaPasswordPlain
        try {
            $idOut = & sqlcmd -S "tcp:localhost,1433" -U sa -d $DatabaseName -h -1 -W -Q "SET NOCOUNT ON; SELECT TOP 1 id FROM [oidc] WHERE clientId = '$oidcClientIdSql';" 2>$null
            if ($LASTEXITCODE -eq 0 -and "$idOut" -match '(\d+)') { $oidcRowId = [int]$Matches[1] }
        } finally { Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue }
    } else {
        $idSql = "SELECT id FROM ""oidc"" WHERE ""clientId"" = '$oidcClientIdSql' LIMIT 1;"
        $env:PGPASSWORD = $PostgresAppPasswordPlain
        try {
            if ($UsePostgresDocker) {
                $idOut = $idSql | & docker exec -i -e PGPASSWORD edfiadminapp-postgres psql -U $PostgresAppUser -d $DatabaseName -tA 2>$null
            } elseif (Get-Command psql -ErrorAction SilentlyContinue) {
                $idOut = $idSql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $DatabaseName -tA 2>$null
            } else {
                $idOut = $null
            }
            if ($LASTEXITCODE -eq 0 -and "$idOut" -match '(\d+)') { $oidcRowId = [int]$Matches[1] }
        } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
    }
    Write-Host "OIDC redirect callback id resolved to $oidcRowId."

    if ($IdpProvider -eq 'keycloak') {
        # Script-provisioned client: correct its redirect URI automatically. Only
        # needed when the id != 1, since Phase 3.1 already registered the default id.
        # Re-running idp-keycloak-setup is idempotent -- only the client's
        # redirectUris change; realm/user/mappers are no-ops.
        if ($oidcRowId -ne 1) {
            Write-Host "Reconciling the Keycloak client redirect URI to callback/$oidcRowId..."
            $kcArgs.RedirectCallbackId = $oidcRowId
            & "$scriptDir\idp-keycloak-setup.ps1" @kcArgs
        }
    } else {
        # Entra/Google/other: no script can provision the provider's client, so
        # surface the exact redirect URI the app will send for manual registration.
        Write-Host ""
        Write-Host "IMPORTANT -- register this EXACT redirect URI in your $IdpProvider client before logging in:" -ForegroundColor Yellow
        Write-Host "  $ApiUrl/api/auth/callback/$oidcRowId"
    }
} else {
    Write-Host "API is NOT responding after ~60s of retries." -ForegroundColor Red
    Write-Host "Check the API stdout log:" -ForegroundColor Yellow
    Write-Host "  Get-Content C:\inetpub\EdFi-AdminApp-API\logs\node-stdout.log -Tail 30"
    Write-Host "And the IIS app pool state:" -ForegroundColor Yellow
    Write-Host "  Get-WebAppPoolState -Name EdFi-AdminApp-API"
    Write-Host ""
    throw "Install completed but the API smoke test failed. Fix the underlying issue and re-run install-all (idempotent), or run 05-deploy-api.ps1 directly to redeploy."
}

# ---------- Done ----------
Write-Phase "INSTALL COMPLETE"

# Build the DB-specific section of the summary first so the main here-string
# below stays simple.
if ($DbEngine -eq 'mssql') {
    $dbSummary = @"
SQL Server
  Server:             (local) / tcp:localhost,1433
  App login:          $AppDbUsername (db_owner on $DatabaseName, non-sysadmin -- the API connects as this)
  App password:       (the value you supplied via -AppDbPassword)
  Bootstrap login:    sa (server setup only; not used by the app)
  sa password:        (the value you supplied via -SaPassword)
  Database:           $DatabaseName
"@
} else {
    $dockerLines = if ($UsePostgresDocker) {
@"

  Container:          edfiadminapp-postgres (docker compose at $scriptDir\docker)
  Superuser password: (the value you supplied via -PostgresSuperuserPassword)
"@
    } else { "" }
    $dbSummary = @"
PostgreSQL
  Host:               ${PostgresHost}:${PostgresPort}
  Database:           $DatabaseName
  App user:           $PostgresAppUser
  App password:       (the value you supplied via -PostgresAppPassword)$dockerLines
"@
}

# Yopass section: reflect which of the three modes was configured.
if ($SetupYopassDocker) {
    $yopassSummary = @"

Yopass (one-time credential links)
  Mode:               Dockerized (docker compose at $scriptDir\docker, file docker-compose.yopass.yml)
  URL:                $EffectiveYopassUrl
  Container:          edfiadminapp-yopass (+ edfiadminapp-yopass-memcached)
"@
} elseif ($EffectiveYopassUrl) {
    $yopassSummary = @"

Yopass (one-time credential links)
  Mode:               External (pre-existing deployment)
  URL:                $EffectiveYopassUrl
"@
} else {
    $yopassSummary = @"

Yopass (one-time credential links)
  Mode:               Disabled (USE_YOPASS=false) -- credentials shown inline in the UI
"@
}

# Identity-provider section of the summary + the sign-in password line, both
# depend on the mode (Keycloak vs external).
if ($idpIsKeycloak) {
    $signInPassword = "(the value you supplied via -TestUserPassword)"
    $idpSummary = @"
Keycloak (Identity Provider)
  Admin console:      http://localhost:8080/admin/
  Sign in with:
    Username:         admin
    Password:         (the value you supplied via -KeycloakAdminPassword)
  edfi realm:         http://localhost:8080/realms/edfi/
  Client secret:      (the value you supplied via -OidcClientSecret)
"@
} else {
    $signInPassword = "(managed by your $IdpProvider account)"
    $idpSummary = @"
Identity Provider (external: $IdpProvider)
  Issuer:             $OidcIssuer
  Client ID:          $OidcClientId
  Account URL:        $ViteIdpAccountUrl
  Register in your IdP: redirect $ApiUrl/api/auth/callback/$oidcRowId, origin $FeUrl
  Sign in as the IdP user whose email/username = $AdminUsername
"@
}

# The encryption key is generated by the installer (the user never supplied it),
# so it must be persisted for backup. It is the one secret kept in the summary
# FILE -- which is ACL-locked below -- but redacted from the console copy.
$encryptionSummary = @"

Data encryption key (aes-256-cbc, ODS/API environment secrets)
  Key:                $DbEncryptionKey
  IMPORTANT: Back this up. Losing or changing it makes every ODS/API
  environment secret stored in the Admin App permanently unrecoverable.
"@

$summary = @"
Ed-Fi Admin App -- Install Summary
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Admin App
  URL:                $FeUrl/
  Sign in with:
    Email:            $AdminUsername
    Password:         $signInPassword

API
  URL:                $ApiUrl/

$idpSummary

$dbSummary
$yopassSummary
$encryptionSummary

Notes
  - TLS is on by default. The FE and API are served over HTTPS from standalone IIS
    sites on ports 4443 and 3443; the HTTP ports 4200 and 3333 redirect to HTTPS.
  - User-supplied secrets are NOT stored here -- re-enter the values you passed.
  - This file's ACL is restricted to Administrators and SYSTEM because it holds the
    generated data-encryption key. Back the key up securely, then you may delete this file.
"@

# Persist alongside the source tree (one level above the scripts folder by
# default) so the user can recover the generated key later. Lives outside the
# scripts folder because it's an install artifact, not a script. The console copy
# redacts the generated key (the file is the ACL-protected place it lives).
$summaryConsole = $summary.Replace($DbEncryptionKey, "(written to the protected install-summary.txt -- Administrators only)")
Write-Host $summaryConsole -ForegroundColor Green
$summaryDir = Split-Path $SourcePath -Parent   # e.g., C:\Ed-Fi
if (-not (Test-Path $summaryDir)) { New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null }
$summaryPath = Join-Path $summaryDir "install-summary.txt"
Set-Content -Path $summaryPath -Value $summary -Encoding UTF8

# The summary holds the generated encryption key; C:\Ed-Fi is otherwise
# world-readable. Restrict the file to Administrators + SYSTEM (well-known SIDs,
# so this is locale-independent) and drop inherited access. The install is already
# complete here, so an ACL failure warns rather than aborting the whole run.
try {
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
    }
    Set-Acl -Path $summaryPath -AclObject $acl
    $summaryAccess = "Administrators-only"
} catch {
    Write-Warning "Could not restrict the ACL on $summaryPath ($($_.Exception.Message)). It holds the encryption key -- protect or delete it manually."
    $summaryAccess = "WARNING: ACL not restricted -- protect it manually"
}

Write-Host ""
Write-Host "Saved to: $summaryPath ($summaryAccess)" -ForegroundColor Cyan
if ($summaryAccess -eq "Administrators-only") {
    Write-Host "  Open it from an ELEVATED editor to read the encryption key (a non-elevated session is denied by UAC)." -ForegroundColor DarkGray
}

# Upstream-TLS heads-up: with SSL_VERIFICATION on (the default), adding an
# Environment against a self-signed/dev ODS/API or Admin API is rejected. Surface
# the remedies here so the user isn't left debugging a cert error in the API log.
if (-not $DisableSslVerification) {
    Write-Host ""
    Write-Host "Note: the API verifies upstream TLS certificates (SSL_VERIFICATION is on)." -ForegroundColor Yellow
    Write-Host "  If your ODS/API or Admin API uses a self-signed/dev certificate, adding an" -ForegroundColor Yellow
    Write-Host "  Environment will fail with a certificate error. For local dev, re-run with" -ForegroundColor Yellow
    Write-Host "  -DisableSslVerification, or keep verification on and set NODE_EXTRA_CA_CERTS" -ForegroundColor Yellow
    Write-Host "  (or --use-system-ca). See the README (Upstream TLS verification)." -ForegroundColor Yellow
}
