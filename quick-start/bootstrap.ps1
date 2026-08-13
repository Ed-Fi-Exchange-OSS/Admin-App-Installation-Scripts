<#
.SYNOPSIS
  (Optional) Bootstrap the service-account (machine-to-machine) client used for
  access to the Admin App API, and seed the matching machine USER row. Idempotent.

  Three providers are supported via -Provider:
    * keycloak (default) -- provisions the Keycloak client + mappers + scopes,
      then seeds the machine USER row.
    * microsoft          -- SKIPS all Keycloak admin calls (the Entra app
      registration is done in the Microsoft Entra portal / Graph) and only seeds
      the machine USER row, keyed on the Entra app (client) GUID. ('entra' is
      still accepted as a deprecated alias; the name now matches
      windows-install/install-all.ps1 -IdpProvider microsoft.)
    * auth0              -- SKIPS all Keycloak admin calls (the Auth0 API +
      Machine to Machine application are created in the Auth0 dashboard), seeds
      the machine USER row keyed on the M2M application's Client ID, and -- when
      -MachineClientSecret is supplied -- mints a client_credentials token and
      FAILS LOUDLY if its claims don't match what the Admin App verifies.

.DESCRIPTION
  KEYCLOAK provider
  Talks only to the Keycloak admin REST API (no elevation). In the target realm
  it creates/repairs:
    * a `login:app` client scope (Default, included in token scope),
    * a confidential `edfiadminapp-machine` client with Service Accounts enabled
      (Standard / Direct access / Implicit flows off),
    * an audience mapper emitting `aud = edfiadminapp-api` (Included *Custom*
      Audience, so it works without a client of that name),
    * a `client_id` claim mapper (so the Admin App can resolve the machine user),
    * `login:app` assigned as a Default client scope, and
    * the default `roles` scope moved to Optional -- this stops Keycloak's
      Audience Resolve mapper from adding a second `account` audience, which would
      make `aud` an array and be rejected by the Admin App.

  MICROSOFT (Entra ID) provider
  There are no admin calls to make from here: the API app registration
  (Expose an API + `login:app` app role + requestedAccessTokenVersion=2) and the
  machine client app (secret + `login:app` application permission with admin
  consent) are created in the Entra portal / Graph. This script only performs the
  SQL seed, using the machine client app's Application (client) ID GUID for the
  `clientId` column (it must equal the token's `azp` (v2) / `appid` (v1) claim).

  AUTH0 provider
  Provider setup happens in the Auth0 dashboard, out-of-band:
    * an API whose Identifier equals the Admin App's MACHINE_AUDIENCE (default
      `edfiadminapp-api`), with its JSON Web Token (JWT) Profile set to RFC 9068
      (the legacy "Auth0" profile omits the `client_id` claim from
      client_credentials tokens and the Admin App then rejects them) and a
      `login:app` permission defined,
    * a Machine to Machine application authorized for that API with the
      `login:app` permission granted.
  This script seeds the machine USER row (clientId = the M2M application's
  Client ID) and, when -MachineClientSecret is supplied, verifies an actual
  token from `{-Auth0Issuer}/oauth/token`: iss must equal the issuer WITH a
  trailing slash (how Auth0 always emits it -- and how the Admin App's
  AUTH0_CONFIG_SECRET.ISSUER must be configured), aud must include the machine
  audience, scope must include `login:app`, and the caller id must match --
  client_id (RFC 9068), or azp alone (legacy profile), which passes with a
  WARNING because only Admin App builds with the azp fallback (after v4.0.1)
  accept it. Any mismatch throws with the exact fix.

  BOTH providers seed the matching machine USER row directly in the Admin App
  database -- required because a client_credentials token is only accepted once
  that user exists, so it cannot be created through the API. After this, run
  quick-start.ps1 with -TokenUrl / -OAuthClientId / -OAuthClientSecret
  (and, for microsoft/Entra, -Scope '<resource>/.default').

.EXAMPLE
  # Keycloak (default). Default engine is mssql; -AppDbPassword connects to
  # localhost,1433 as the least-privilege app login created by
  # windows-install/install-all.ps1 (default name 'edfi_adminapp').
  ./bootstrap.ps1 -AdminPassword 'admin' -AppDbPassword 'EdFi-App!2026'

.EXAMPLE
  # Keycloak against Postgres instead:
  ./bootstrap.ps1 -AdminPassword 'admin' `
    -DbEngine pgsql -PostgresAppPassword 'edfi'

.EXAMPLE
  # Microsoft Entra ID. No Keycloak calls; only the SQL seed runs. -MachineClientId
  # is the Entra machine client app's Application (client) ID GUID (= token 'azp'/'appid').
  ./bootstrap.ps1 -Provider microsoft `
    -MachineClientId '00000000-0000-0000-0000-000000000000' `
    -AppDbPassword 'EdFi-App!2026'

  # Then fetch a token with the resource's .default scope (NOT 'login:app'):
  #   POST https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token
  #     grant_type=client_credentials
  #     client_id={machineAppGuid}&client_secret={secret}
  #     scope={api-app-id-uri-or-guid}/.default

.EXAMPLE
  # Auth0. No Keycloak calls; seeds the user and (because -MachineClientSecret is
  # given) verifies a real client_credentials token's iss/aud/scope/client_id.
  # -MachineClientId/-MachineClientSecret are the Auth0 MACHINE TO MACHINE
  # application's credentials (not the Single Page Application used for human login).
  ./bootstrap.ps1 -Provider auth0 `
    -Auth0Issuer 'https://your-tenant.us.auth0.com' `
    -MachineClientId '<M2M-application-Client-ID>' `
    -MachineClientSecret '<M2M-application-Client-Secret>' `
    -AppDbPassword 'EdFi-App!2026'
#>
#requires -Version 5.1
param(
    # keycloak (default): provision the Keycloak client + seed the user.
    # microsoft: skip all Keycloak calls; only seed the user (app reg is done in
    #            the Microsoft Entra portal). 'entra' is a deprecated alias.
    # auth0: skip all Keycloak calls; seed the user and, when -MachineClientSecret
    #        is supplied, verify a real client_credentials token's claims.
    [ValidateSet('keycloak', 'microsoft', 'entra', 'auth0')][string]$Provider = 'keycloak',

    # --- Keycloak provisioning (only used when -Provider keycloak) -------------
    [string]$KeycloakBaseUrl = "http://localhost:8080",
    [string]$AdminUser = "admin",
    [string]$AdminPassword,                      # required for -Provider keycloak
    [string]$RealmName = "edfi",
    # Machine client identifier written to the user's clientId column.
    #   keycloak  -> the Keycloak client id (default below).
    #   microsoft -> the Entra machine app's Application (client) ID GUID.
    #   auth0     -> the Auth0 Machine to Machine application's Client ID.
    [string]$MachineClientId = "edfiadminapp-machine",
    [string]$MachineClientSecret = "edfi-machine-secret-456",
    # Must equal the Admin App's AUTH0_CONFIG_SECRET.MACHINE_AUDIENCE.
    # For auth0 it is also the Auth0 API's Identifier (the token-request audience).
    [string]$MachineAudience = "edfiadminapp-api",
    # auth0 only: the tenant issuer URL (e.g. https://your-tenant.us.auth0.com).
    # Either slash form is accepted; token claims are checked against the
    # trailing-slash form because that is how Auth0 emits iss.
    [string]$Auth0Issuer = "",
    [string]$LoginScopeName = "login:app",
    [switch]$SkipCertificateCheck,

    # --- Admin App machine USER (seeded by SQL; always performed) -------------
    # A client_credentials token is only accepted once the machine user exists,
    # so it must be seeded by SQL (the same way the Admin App installer seeds the
    # human admin). Connection parameters mirror windows-install/install-all.ps1.
    [ValidateSet('mssql', 'pgsql')][string]$DbEngine = 'mssql',
    [switch]$UsePostgresDocker,
    # mssql login: the dedicated least-privilege app login created by
    # windows-install/install-all.ps1 (-AppDbPassword there). It is db_owner on
    # the app database, which is all this seed needs -- 'sa' is deliberately
    # not used (EDFI-2776).
    [string]$AppDbUsername = 'edfi_adminapp',
    [string]$AppDbPassword,                      # required for -DbEngine mssql
    [string]$PostgresAppPassword,                # required for -DbEngine pgsql
    [string]$PostgresHost = "localhost",
    [int]$PostgresPort = 5432,
    [string]$PostgresAppUser = "edfiadminapp",
    [string]$DatabaseName = "sbaa",
    [string]$AdminAppUsername = 'quick-start-machine',
    [int]$AdminAppRoleId = 2,    # Global admin
    [string]$AdminAppUserDescription = 'Quick Start machine-to-machine user'
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/compat.ps1"

# 'entra' was the original name of the Microsoft provider. Normalize it to
# 'microsoft' (matching windows-install/install-all.ps1 -IdpProvider) so the
# rest of the script branches on one value; existing .env files keep working.
if ($Provider -eq 'entra')
{
    Write-Host "Provider 'entra' is a deprecated alias -- use 'microsoft'." -ForegroundColor Yellow
    $Provider = 'microsoft'
}

# Provider-specific required-arg validation.
if ($Provider -eq 'keycloak' -and -not $AdminPassword) { throw "-AdminPassword is required when -Provider is 'keycloak' (the default)." }
if ($Provider -eq 'microsoft' -and $MachineClientId -eq 'edfiadminapp-machine') { throw "-MachineClientId must be the Entra machine app's Application (client) ID GUID when -Provider is 'microsoft' (it must match the token's azp/appid claim)." }
if ($Provider -eq 'auth0' -and $MachineClientId -eq 'edfiadminapp-machine') { throw "-MachineClientId must be the Auth0 Machine to Machine application's Client ID when -Provider is 'auth0' (it must match the token's client_id claim)." }
if ($Provider -eq 'auth0' -and -not $Auth0Issuer) { throw "-Auth0Issuer (the tenant URL, e.g. https://your-tenant.us.auth0.com) is required when -Provider is 'auth0'." }

# Engine-specific required-arg validation (mirrors install-all.ps1).
if ($DbEngine -eq 'mssql' -and -not $AppDbPassword) { throw "-AppDbPassword (the install-all.ps1 app login's password) is required when -DbEngine is 'mssql' (the default)." }
if ($DbEngine -eq 'pgsql' -and -not $PostgresAppPassword) { throw "-PostgresAppPassword is required when -DbEngine is 'pgsql'." }
if ($UsePostgresDocker -and $DbEngine -ne 'pgsql') { throw "-UsePostgresDocker only applies when -DbEngine is 'pgsql'." }

$script:rest = @{}
if ($SkipCertificateCheck)
{
    # -SkipCertificateCheck exists only on PS 6+; on Windows PowerShell 5.1
    # fall back to a process-wide validation override.
    if ($script:webCmdletsSupportSkipCertCheck) { $script:rest.SkipCertificateCheck = $true }
    else { Enable-TrustAllCertificates }
}

function Invoke-KcApi
{
    param([string]$Method, [string]$Path, [object]$Body)
    $params = $script:rest.Clone()
    $params.Uri = "$KeycloakBaseUrl/admin$Path"
    $params.Method = $Method
    $params.Headers = @{ Authorization = "Bearer $script:token" }
    if ($null -ne $Body)
    {
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $params.ContentType = "application/json"
    }
    Invoke-RestMethod @params
}

# ==== Keycloak provisioning (skipped entirely for the external providers) =====
if ($Provider -eq 'keycloak')
{
    # ---- Admin token ---------------------------------------------------------
    Write-Host "Authenticating to Keycloak admin API ($KeycloakBaseUrl)..."
    try
    {
        $tokenResp = Invoke-RestMethod @script:rest `
            -Uri "$KeycloakBaseUrl/realms/master/protocol/openid-connect/token" `
            -Method Post -ContentType "application/x-www-form-urlencoded" `
            -Body "grant_type=password&client_id=admin-cli&username=$AdminUser&password=$AdminPassword"
    }
    catch
    {
        throw "Keycloak admin auth failed. Check -KeycloakBaseUrl / -AdminUser / -AdminPassword (the master admin password is set on Keycloak's first boot)."
    }
    $script:token = $tokenResp.access_token
    Write-Host "Authenticated."

    # ---- login:app client scope ----------------------------------------------
    $scopes = Invoke-KcApi -Method Get -Path "/realms/$RealmName/client-scopes"
    $loginScope = $scopes | Where-Object { $_.name -eq $LoginScopeName } | Select-Object -First 1
    if (-not $loginScope)
    {
        Write-Host "Creating client scope '$LoginScopeName'..."
        Invoke-KcApi -Method Post -Path "/realms/$RealmName/client-scopes" -Body @{
            name        = $LoginScopeName
            description = "Access to Ed-Fi Admin App API"
            protocol    = "openid-connect"
            attributes  = @{ "include.in.token.scope" = "true"; "display.on.consent.screen" = "false" }
        } | Out-Null
        $scopes = Invoke-KcApi -Method Get -Path "/realms/$RealmName/client-scopes"
        $loginScope = $scopes | Where-Object { $_.name -eq $LoginScopeName } | Select-Object -First 1
    }
    else
    {
        Write-Host "Client scope '$LoginScopeName' already exists."
    }
    $rolesScope = $scopes | Where-Object { $_.name -eq "roles" } | Select-Object -First 1

    # ---- Machine client ------------------------------------------------------
    $clientPayload = @{
        clientId                     = $MachineClientId
        name                         = "Ed-Fi Machine Client"
        description                  = "Ed-Fi Admin App Machine-to-Machine Authentication Client"
        secret                       = $MachineClientSecret
        publicClient                 = $false
        serviceAccountsEnabled       = $true
        standardFlowEnabled          = $false
        directAccessGrantsEnabled    = $false
        implicitFlowEnabled          = $false
        authorizationServicesEnabled = $false
        protocol                     = "openid-connect"
    }
    $clients = Invoke-KcApi -Method Get -Path "/realms/$RealmName/clients?clientId=$MachineClientId"
    if ($clients.Count -gt 0)
    {
        $clientUuid = $clients[0].id
        Write-Host "Client '$MachineClientId' exists (uuid $clientUuid); updating..."
        $clientPayload.id = $clientUuid
        Invoke-KcApi -Method Put -Path "/realms/$RealmName/clients/$clientUuid" -Body $clientPayload | Out-Null
    }
    else
    {
        Write-Host "Creating client '$MachineClientId'..."
        Invoke-KcApi -Method Post -Path "/realms/$RealmName/clients" -Body $clientPayload | Out-Null
        $clients = Invoke-KcApi -Method Get -Path "/realms/$RealmName/clients?clientId=$MachineClientId"
        $clientUuid = $clients[0].id
    }
    Write-Host "Client UUID: $clientUuid"

    # ---- Protocol mappers (audience + client_id) -----------------------------
    $mappers = Invoke-KcApi -Method Get -Path "/realms/$RealmName/clients/$clientUuid/protocol-mappers/models"
    function Ensure-Mapper
    {
        param([string]$Name, [hashtable]$Mapper)
        if ($mappers | Where-Object { $_.name -eq $Name })
        {
            Write-Host "Mapper '$Name' already present."
        }
        else
        {
            Write-Host "Adding mapper '$Name'..."
            Invoke-KcApi -Method Post -Path "/realms/$RealmName/clients/$clientUuid/protocol-mappers/models" -Body $Mapper | Out-Null
        }
    }
    Ensure-Mapper -Name "machine-client-audience" -Mapper @{
        name           = "machine-client-audience"
        protocol       = "openid-connect"
        protocolMapper = "oidc-audience-mapper"
        config         = @{
            "included.custom.audience" = $MachineAudience
            "id.token.claim"           = "false"
            "access.token.claim"       = "true"
            "userinfo.token.claim"     = "false"
        }
    }
    Ensure-Mapper -Name "client-id-mapper" -Mapper @{
        name           = "client-id-mapper"
        protocol       = "openid-connect"
        protocolMapper = "oidc-usersessionmodel-note-mapper"
        config         = @{
            "user.session.note"  = "clientId"
            "claim.name"         = "client_id"
            "jsonType.label"     = "String"
            "id.token.claim"     = "true"
            "access.token.claim" = "true"
        }
    }

    # ---- Client scope assignments --------------------------------------------
    # login:app as DEFAULT (puts scope=login:app in the token).
    if ($loginScope)
    {
        Invoke-KcApi -Method Put -Path "/realms/$RealmName/clients/$clientUuid/default-client-scopes/$($loginScope.id)" | Out-Null
        Write-Host "Assigned '$LoginScopeName' as a default client scope."
    }
    # roles -> OPTIONAL. The 'roles' scope carries the Audience Resolve mapper that
    # adds the extra 'account' audience; moving it off the defaults keeps aud as the
    # single value the Admin App requires.
    if ($rolesScope)
    {
        try { Invoke-KcApi -Method Delete -Path "/realms/$RealmName/clients/$clientUuid/default-client-scopes/$($rolesScope.id)" | Out-Null } catch {}
        try { Invoke-KcApi -Method Put -Path "/realms/$RealmName/clients/$clientUuid/optional-client-scopes/$($rolesScope.id)" | Out-Null } catch {}
        Write-Host "Moved 'roles' scope to Optional (keeps aud single-valued)."
    }
}
elseif ($Provider -eq 'microsoft')
{
    Write-Host "Provider 'microsoft': no local identity provider to provision (the app registration is done in the Microsoft Entra portal / Graph). Seeding the machine user." -ForegroundColor Yellow
}
else
{
    Write-Host "Provider 'auth0': no local identity provider to provision (the API and Machine to Machine application are created in the Auth0 dashboard). Seeding the machine user." -ForegroundColor Yellow
}

# ---- Seed the Admin App machine USER -----------------------------------------
# A client_credentials token is only accepted once a matching machine user
# exists, so it cannot be created through the API -- seed it by SQL, mirroring
# windows-install/install-all.ps1. clientId must equal the token's caller-id
# claim:
#   keycloak -> client_id ; Entra v2 -> azp ; Entra v1 -> appid
# For both providers this is the value passed in -MachineClientId.
Write-Host "`nSeeding Admin App machine user '$AdminAppUsername' (clientId='$MachineClientId', roleId=$AdminAppRoleId) in $DbEngine db '$DatabaseName'..."

# Escape single quotes for safe embedding in the SQL literals (mirrors cleanup.ps1).
$userNameSql = $AdminAppUsername.Replace("'", "''")
$clientIdSql = $MachineClientId.Replace("'", "''")
$descriptionSql = $AdminAppUserDescription.Replace("'", "''")

if ($DbEngine -eq 'mssql')
{
    # QUOTED_IDENTIFIER must be ON for writes to [user] (it has a filtered unique
    # index on clientId); sqlcmd defaults it OFF, so set it for this batch.
    $userSql = @"
SET QUOTED_IDENTIFIER ON;
IF NOT EXISTS (SELECT 1 FROM [user] WHERE username = '$userNameSql' OR clientId = '$clientIdSql')
    INSERT INTO [user] (username, clientId, userType, description, roleId, isActive)
    VALUES ('$userNameSql', '$clientIdSql', 'machine', '$descriptionSql', $AdminAppRoleId, 1);
UPDATE [user] SET roleId = $AdminAppRoleId, isActive = 1, userType = 'machine', clientId = '$clientIdSql'
    WHERE username = '$userNameSql';
"@
    # -C (trust server certificate) is safe unconditionally: -S is the hardcoded
    # loopback, never a parameterized remote host (contrast copy-claimsets.ps1,
    # which takes -SqlServer and decides via Get-SqlcmdTrustArgs).
    & sqlcmd -S "tcp:localhost,1433" -U $AppDbUsername -P $AppDbPassword -d $DatabaseName -C -Q $userSql
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE) as login '$AppDbUsername'. Check -AppDbUsername / -AppDbPassword / -DatabaseName." }
}
else
{
    # "user" is a reserved word and the camelCase columns are case-sensitive, so
    # everything stays double-quoted; pipe via stdin so the quotes survive.
    $userSql = @"
INSERT INTO "user" (username, "clientId", "userType", description, "roleId", "isActive")
    VALUES ('$userNameSql', '$clientIdSql', 'machine', '$descriptionSql', $AdminAppRoleId, true)
    ON CONFLICT (username) DO NOTHING;
UPDATE "user" SET "roleId" = $AdminAppRoleId, "isActive" = true, "userType" = 'machine', "clientId" = '$clientIdSql'
    WHERE username = '$userNameSql';
"@
    if ($UsePostgresDocker)
    {
        $userSql | & docker exec -i -e "PGPASSWORD=$PostgresAppPassword" edfiadminapp-postgres psql -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1
    }
    else
    {
        $env:PGPASSWORD = $PostgresAppPassword
        $userSql | & psql -h $PostgresHost -p $PostgresPort -U $PostgresAppUser -d $DatabaseName -v ON_ERROR_STOP=1
    }
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE). Check -PostgresAppPassword / -PostgresHost / -PostgresPort / -PostgresAppUser / -DatabaseName." }
}
Write-Host "Admin App machine user ready." -ForegroundColor Green

# ---- Keycloak smoke test: mint a token and show the claims the Admin App checks
# Entra tokens are minted from the Entra token endpoint with a '<resource>/.default'
# scope, so there is nothing to smoke-test from here for that provider.
if ($Provider -eq 'keycloak')
{
    Write-Host "`nVerifying client_credentials token..."
    $tok = Invoke-RestMethod @script:rest `
        -Uri "$KeycloakBaseUrl/realms/$RealmName/protocol/openid-connect/token" `
        -Method Post -ContentType "application/x-www-form-urlencoded" `
        -Body "grant_type=client_credentials&client_id=$MachineClientId&client_secret=$MachineClientSecret&scope=$LoginScopeName"
    $p = $tok.access_token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    Write-Host ("  iss       : {0}" -f $claims.iss)
    Write-Host ("  aud       : {0}" -f ($claims.aud -join ', '))
    Write-Host ("  scope     : {0}" -f $claims.scope)
    Write-Host ("  client_id : {0}" -f $claims.client_id)

    Write-Host "`nSUCCESS: machine client ready." -ForegroundColor Green
    Write-Host "Next:" -ForegroundColor Green
    Write-Host "  1. Confirm 'aud' above is exactly '$MachineAudience' (no 'account')."
    Write-Host "  2. Confirm the Admin App's AUTH0_CONFIG_SECRET.ISSUER == '$($claims.iss)'."
    Write-Host "  3. Machine USER '$AdminAppUsername' seeded in the Admin App db (clientId='$MachineClientId', roleId=$AdminAppRoleId)."
    Write-Host "  4. ./quick-start.ps1 -TokenUrl '$KeycloakBaseUrl/realms/$RealmName/protocol/openid-connect/token' -OAuthClientId '$MachineClientId' -OAuthClientSecret '<secret>'"
}
elseif ($Provider -eq 'auth0')
{
    # Auth0 mints client_credentials tokens from {tenant}/oauth/token with an
    # explicit audience. The assertions below mirror exactly what the Admin App
    # verifies (iss exact match, aud = MACHINE_AUDIENCE, 'login:app' in scope,
    # machine user resolved from client_id), so a mismatch here is the same
    # mismatch that would 401 the real API call -- fail loudly with the fix.
    $auth0Base = $Auth0Issuer.TrimEnd('/')
    if ($PSBoundParameters.ContainsKey('MachineClientSecret'))
    {
        Write-Host "`nVerifying client_credentials token from $auth0Base/oauth/token..."
        $tok = Invoke-RestMethod @script:rest -Uri "$auth0Base/oauth/token" `
            -Method Post -ContentType "application/json" -Body (@{
                grant_type    = "client_credentials"
                client_id     = $MachineClientId
                client_secret = $MachineClientSecret
                audience      = $MachineAudience
            } | ConvertTo-Json)
        $p = $tok.access_token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
        Write-Host ("  iss       : {0}" -f $claims.iss)
        Write-Host ("  aud       : {0}" -f (@($claims.aud) -join ', '))
        Write-Host ("  scope     : {0}" -f $claims.scope)
        Write-Host ("  client_id : {0}" -f $claims.client_id)
        Write-Host ("  azp       : {0}" -f $claims.azp)
        Write-Host ("  appid     : {0}" -f $claims.appid)

        $problems = @()
        $azpFallbackInUse = $false
        if ($claims.iss -ne "$auth0Base/")
        {
            $problems += "iss is '$($claims.iss)' but must equal '$auth0Base/' (WITH the trailing slash -- how Auth0 emits it, and how the Admin App's AUTH0_CONFIG_SECRET.ISSUER must be configured)."
        }
        if (@($claims.aud) -notcontains $MachineAudience)
        {
            $problems += "aud '$(@($claims.aud) -join ', ')' does not include '$MachineAudience'. The Auth0 API's Identifier must be exactly the Admin App's MACHINE_AUDIENCE."
        }
        if ((" " + "$($claims.scope)" + " ") -notlike "* $LoginScopeName *")
        {
            $problems += "scope '$($claims.scope)' does not include '$LoginScopeName'. Define the permission on the Auth0 API and grant it to the Machine to Machine application."
        }
        # Mirror the Admin App's caller-id resolution: client_id, falling back to
        # azp on builds that include the fallback. A token that only
        # carries azp (the legacy 'Auth0' JWT profile) therefore passes, but with
        # a warning -- Admin App versions WITHOUT that fallback (v4.0.1 and
        # earlier) still 401 it, and RFC 9068 works on every version.
        $callerId = if ($claims.client_id) { $claims.client_id } else { $claims.azp }
        if (-not $callerId)
        {
            $problems += "the token carries neither a client_id nor an azp claim, so the Admin App cannot resolve the machine user. Set the Auth0 API's JSON Web Token (JWT) Profile to RFC 9068."
        }
        elseif ($callerId -ne $MachineClientId)
        {
            $problems += "the token's caller id is '$callerId' (from $(if ($claims.client_id) { 'client_id' } else { 'azp' })) but the machine user was seeded with clientId '$MachineClientId' -- they must match."
        }
        elseif (-not $claims.client_id)
        {
            $azpFallbackInUse = $true
        }
        if ($problems.Count -gt 0)
        {
            $problems | ForEach-Object { Write-Host "  PROBLEM: $_" -ForegroundColor Red }
            throw "Auth0 token verification failed ($($problems.Count) problem(s) above). Fix them in the Auth0 dashboard and re-run."
        }
        Write-Host "`nSUCCESS: Auth0 token claims match what the Admin App verifies." -ForegroundColor Green
        if ($azpFallbackInUse)
        {
            Write-Host "WARNING: the token has no client_id claim (legacy 'Auth0' JWT profile); the caller id was matched via the azp fallback." -ForegroundColor Yellow
            Write-Host "         This only authenticates against Admin App builds that include the azp fallback (after v4.0.1) -- earlier versions 401 it." -ForegroundColor Yellow
            Write-Host "         Setting the Auth0 API's JSON Web Token (JWT) Profile to RFC 9068 works on every Admin App version." -ForegroundColor Yellow
        }
    }
    else
    {
        Write-Host "`nMachine user seeded. -MachineClientSecret was not supplied, so the Auth0 token check was SKIPPED -- verify the claims manually (decode a test token)." -ForegroundColor Yellow
    }
    Write-Host "Next:" -ForegroundColor Green
    Write-Host "  1. Confirm the Admin App's AUTH0_CONFIG_SECRET.ISSUER == '$auth0Base/' (WITH the trailing slash; install-all.ps1 -IdpProvider auth0 writes this form)."
    Write-Host "  2. Confirm the Auth0 API's Identifier == MACHINE_AUDIENCE ('$MachineAudience') and its JSON Web Token (JWT) Profile is RFC 9068 (or the Admin App includes the azp fallback, after v4.0.1)."
    Write-Host "  3. Machine USER '$AdminAppUsername' seeded (clientId='$MachineClientId'; must equal the token's client_id, or azp on the legacy profile)."
    Write-Host "  4. ./quick-start.ps1 -TokenUrl '$auth0Base/oauth/token' -OAuthClientId '$MachineClientId' -OAuthClientSecret '<secret>' -Audience '$MachineAudience'"
}
else
{
    Write-Host "`nSUCCESS: machine user seeded for Entra." -ForegroundColor Green
    Write-Host "Next:" -ForegroundColor Green
    Write-Host "  1. In Entra, confirm the API app exposes the 'login:app' app role and issues v2 tokens (requestedAccessTokenVersion=2)."
    Write-Host "  2. Confirm the machine client app has the 'login:app' application permission with admin consent granted."
    Write-Host "  3. Set the Admin App's AUTH0_CONFIG_SECRET.ISSUER = 'https://login.microsoftonline.com/{tenantId}/v2.0'"
    Write-Host "     and MACHINE_AUDIENCE = the token 'aud' (v2 default = the API app's client-id GUID; confirm by decoding a test token)."
    Write-Host "  4. Machine USER '$AdminAppUsername' seeded (clientId='$MachineClientId'; must equal the token's azp/appid)."
    Write-Host "  5. ./quick-start.ps1 -TokenUrl 'https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token' -OAuthClientId '$MachineClientId' -OAuthClientSecret '<secret>' -Scope '<resource>/.default'"
}