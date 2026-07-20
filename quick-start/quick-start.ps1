#requires -Version 7.0
<#
.SYNOPSIS
  Global Admin Quick Start via the Admin App REST API (no raw SQL).

.DESCRIPTION
  Provisions an Ed-Fi environment by POSTing to the Admin App API
  (POST /adminapp-api/api/sb-environments) instead of injecting rows into the
  "sbaa" database directly. Letting the API do the work means it runs the real
  create() flow:

    * validates the Admin API URL and the ODS/API discovery URL,
    * auto-detects the version (v1/v2) and tenant mode from ODS metadata,
    * registers OAuth client credentials at the Admin API "/connect/register",
    * AES-ENCRYPTS the per-tenant secret into sb_environment.configPrivate, and
    * syncs the ODS instances / Education Organizations into the local tables.

  The result is a FULLY FUNCTIONAL environment: the Applications and Ed-Org
  pages authenticate against the live Admin API, which a raw SQL seed cannot
  achieve because it cannot encrypt configPrivate.

  AUTHENTICATION
  The /sb-environments endpoints sit behind the Admin App AuthenticatedGuard.
  This script authenticates with an OAuth2 service-account (machine-to-machine)
  token: it fetches one via the client_credentials grant from -TokenUrl using
  -OAuthClientId / -OAuthClientSecret, and sends it as a Bearer token. This works
  against ANY supported provider configured in the Admin App (Keycloak,
  Entra ID), because the API only checks the configured ISSUER / MACHINE_AUDIENCE
  and that the token grants "login:app" -- not a specific vendor. It requires a
  matching "machine" user in the Admin App (see the guide's Prerequisites).

  The provider differences are entirely in the token request, which -Scope
  absorbs (Google Workspace M2M is NOT supported -- its tokens cannot carry
  "login:app"):
    * Keycloak -- request -Scope 'login:app' (the default); the grant
      arrives in the token's `scope` claim.
    * Entra ID -- request -Scope '<resource>/.default' (NOT 'login:app'); the
      `login:app` app role is granted via admin consent and arrives in the
      token's `roles` claim, and the caller id arrives in `azp` (v2) / `appid`
      (v1) rather than `client_id`.

  NOTE: the bootstrap user's username/password CANNOT be passed directly -- the
  Admin App has no password endpoint; all human login goes through the OIDC
  provider's browser flow. This script deliberately uses a service-account
  client, not the human bootstrap account.

  Ownership is NOT seeded manually: create() stamps createdBy with the calling
  user, which is why a global admin sees the environment without an explicit
  ownership row.

.EXAMPLE
  # Fetch a service-account token from the IdP (local Keycloak shown).
  ./quick-start.ps1 `
    -TokenUrl 'https://localhost/auth/realms/edfi/protocol/openid-connect/token' `
    -OAuthClientId 'edfiadminapp-machine' -OAuthClientSecret 'edfi-machine-secret-456'

.EXAMPLE
  ./quick-start.ps1 `
    -TokenUrl 'https://localhost/auth/realms/edfi/protocol/openid-connect/token' `
    -OAuthClientId 'edfiadminapp-machine' -OAuthClientSecret 'edfi-machine-secret-456' `
    -AdminApiUrl 'https://localhost/AdminApi' `
    -OdsApiDiscoveryUrl 'https://localhost/WebApi'

.EXAMPLE
  # Microsoft Entra ID: v2 token endpoint + the resource's .default scope.
  # -OAuthClientId is the Entra machine app's Application (client) ID GUID.
  ./quick-start.ps1 `
    -TokenUrl 'https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token' `
    -OAuthClientId '00000000-0000-0000-0000-000000000000' `
    -OAuthClientSecret '<secret>' `
    -Scope 'api://edfiadminapp-api/.default'

.NOTES
  Requires PowerShell 7+. The ODS instance ids AND names passed in -Odss must
  match real rows in EdFi_Admin.dbo.OdsInstances on the target ODS/API (the
  Admin App later matches by name when creating an application), or the sync will
  not find them.
#>
param(
    # Base URL of the Admin App API (through the reverse proxy).
    [string]$ApiBaseUrl = "https://localhost/adminapp-api/api",

    # Auth: fetch a service-account token via the OAuth2 client_credentials grant
    # from the provider's token endpoint. The token must carry aud =
    # MACHINE_AUDIENCE and grant "login:app" (Keycloak: in `scope`; Entra:
    # in `roles`), and its caller id must match a "machine" user in the Admin App.
    # Local Keycloak defaults are shown in the examples.
    [Parameter(Mandatory = $true)]
    [string]$TokenUrl,                      # e.g. https://localhost/auth/realms/edfi/protocol/openid-connect/token
    [Parameter(Mandatory = $true)]
    [string]$OAuthClientId,                 # e.g. edfiadminapp-machine (Entra: the app client-id GUID)
    [Parameter(Mandatory = $true)]
    [string]$OAuthClientSecret,             # e.g. edfi-machine-secret-456
    # Keycloak: 'login:app' (default). Entra: '<resource>/.default'.
    [string]$Scope = "login:app",

    # Team + membership for the calling (machine) user.
    [string]$TeamName = "Quick Start",
    # Username of the HUMAN bootstrap admin (the Admin App's ADMIN_USERNAME
    # account). When set, that user is also placed in the team with
    # -MembershipRoleId. Without a membership the Applications and Profiles
    # pages return 403 for them: their Global admin role (2) predates the
    # team-scoped profile privileges and was never backfilled, so those
    # privileges only reach them through a team membership. Empty = skip.
    [string]$AdminUsername = "",
    # Role for the team memberships (machine user and, when -AdminUsername is
    # set, the human bootstrap admin). MUST be a UserTenant role.
    # 6 = "Tenant admin": this is the role that carries the team-scoped
    # `team.sb-environment.edfi-tenant.*` privileges (incl. profile:read).
    # Do NOT use 2 ("Global admin"): that UserGlobal role was seeded before the
    # profile privileges existed and never backfilled, so a role-2 membership
    # yields 403 on the Applications/profiles page. (The user is still a global
    # admin via user.roleId; this is only the in-team role.)
    [int]$MembershipRoleId = 6,
    # Role for the team's ownership of the environment + tenant.
    # 5 = "Full ownership" (ResourceOwnership) -- what surfaces team-scoped resources.
    [int]$OwnershipRoleId = 5,

    # Environment definition.
    [string]$EnvironmentName = "Ed-Fi ODS/API v7.3",
    [string]$EnvironmentLabel = "QuickStart",
    [string]$AdminApiUrl = "https://localhost/AdminApi",
    [string]$OdsApiDiscoveryUrl = "https://localhost/WebApi",
    [string]$TenantName = "default",

    # ODS instances to attach to the (single) tenant. Each entry:
    #   @{ id = <odsInstanceId>; name = <display>; dbName = <db>; allowedEdOrgs = "<csv>" }
    # ids and names must match EdFi_Admin.dbo.OdsInstances on the target ODS/API.
    [object[]]$Odss = @(
        @{ id = 5; name = "EdFi_Ods_2026"; dbName = "EdFi_Ods_2026"; allowedEdOrgs = "255901" },
        @{ id = 6; name = "EdFi_Ods_2027"; dbName = "EdFi_Ods_2027"; allowedEdOrgs = "255902" }
    ),

    # Skip TLS validation for the local self-signed cert.
    [switch]$SkipCertificateCheck = $true
)

$ErrorActionPreference = "Stop"

# PowerShell 7.4+ refuses HTTPS->HTTP redirects (the local Keycloak/nginx 302s
# can resolve to an insecure hop) unless -AllowInsecureRedirect is passed. The
# switch does not exist before 7.4, so probe for it.
$script:allowInsecureRedirect = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('AllowInsecureRedirect')

# ---- Obtain a Bearer token via the client_credentials grant ------------------
# Works with any supported provider. The resulting token must satisfy the Admin
# App's bearer checks (aud = MACHINE_AUDIENCE, grants "login:app" via scope or
# roles, and its caller id -- client_id/azp/appid -- maps to a "machine" user),
# which the provider must be configured for.
Write-Host "POST $TokenUrl (grant_type=client_credentials)" -ForegroundColor Cyan
$tokenArgs = @{
    Method = "Post"
    Uri    = $TokenUrl
    Body   = @{
        grant_type    = "client_credentials"
        client_id     = $OAuthClientId
        client_secret = $OAuthClientSecret
        scope         = $Scope
    }
}
if ($SkipCertificateCheck) { $tokenArgs.SkipCertificateCheck = $true }
if ($script:allowInsecureRedirect) { $tokenArgs.AllowInsecureRedirect = $true }
try
{
    $tokenResponse = Invoke-RestMethod @tokenArgs
}
catch
{
    Write-Host "Token request failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
    throw "Could not obtain a token from $TokenUrl. Check -OAuthClientId/-OAuthClientSecret and that the client has the client_credentials grant enabled."
}
$BearerToken = $tokenResponse.access_token
if (-not $BearerToken) { throw "Token endpoint did not return an access_token." }
Write-Host "Obtained service-account access token." -ForegroundColor Green

# ---- Shared auth + request helper --------------------------------------------
# One bearer header, reused for every call so the steps run as the same identity.
$script:authHeader = @{ Authorization = "Bearer $BearerToken" }

function Invoke-Api
{
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body
    )
    $reqArgs = @{
        Method  = $Method
        Uri     = "$ApiBaseUrl$Path"
        Headers = $script:authHeader.Clone()
    }
    if ($null -ne $Body)
    {
        $reqArgs.Body = ($Body | ConvertTo-Json -Depth 10)
        $reqArgs.ContentType = "application/json"
    }
    if ($SkipCertificateCheck) { $reqArgs.SkipCertificateCheck = $true }
    if ($script:allowInsecureRedirect) { $reqArgs.AllowInsecureRedirect = $true }
    return Invoke-RestMethod @reqArgs
}

# ---- Step 1: identify the calling user (GET /auth/me) ------------------------
Write-Host "GET $ApiBaseUrl/auth/me" -ForegroundColor Cyan
try
{
    $me = Invoke-Api -Method Get -Path "/auth/me"
}
catch
{
    Write-Host "Authentication failed calling /auth/me: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
    throw "Authentication was not accepted. Confirm a matching 'machine' user exists in the Admin App (clientId = the token's client_id/azp/appid) and the token carries aud = MACHINE_AUDIENCE and grants 'login:app' (Keycloak: in scope), and that its iss matches the Admin App's AUTH0_CONFIG_SECRET.ISSUER."
}
$userId = $me.id
if (-not $userId) { throw "Could not determine the user id from /auth/me response." }
Write-Host "Signed in as user id $userId ($($me.username))." -ForegroundColor Green

# ---- Step 2: create (or reuse) the team --------------------------------------
$teams = Invoke-Api -Method Get -Path "/teams"
$team = $teams | Where-Object { $_.name -eq $TeamName } | Select-Object -First 1
if ($team)
{
    Write-Host "Team '$TeamName' already exists (id $($team.id))." -ForegroundColor Yellow
}
else
{
    Write-Host "POST /teams { name = '$TeamName' }" -ForegroundColor Cyan
    $team = Invoke-Api -Method Post -Path "/teams" -Body @{ name = $TeamName }
    Write-Host "Created team '$TeamName' (id $($team.id))." -ForegroundColor Green
}
$teamId = $team.id

# ---- Step 3: place the users in the team with the requested role -------------
function Ensure-TeamMembership
{
    param([int]$UserId, [int]$RoleId, [string]$Label)
    $memberships = Invoke-Api -Method Get -Path "/teams/$teamId/user-team-memberships"
    $existing = $memberships | Where-Object { $_.userId -eq $UserId } | Select-Object -First 1
    if ($existing -and [int]$existing.roleId -eq [int]$RoleId)
    {
        Write-Host "$Label (user $UserId) is already a member of team $teamId with roleId $RoleId." -ForegroundColor Yellow
    }
    elseif ($existing)
    {
        # Membership exists but with the wrong role (e.g. a previous run used role 2);
        # fix it to the tenant-scoped role so team privileges resolve.
        Write-Host "PUT /teams/$teamId/user-team-memberships/$($existing.id) { roleId = $RoleId }  (was $($existing.roleId))" -ForegroundColor Cyan
        Invoke-Api -Method Put -Path "/teams/$teamId/user-team-memberships/$($existing.id)" `
            -Body @{ roleId = [int]$RoleId } | Out-Null
        Write-Host "Updated $Label (user $UserId) membership in team $teamId to roleId $RoleId." -ForegroundColor Green
    }
    else
    {
        Write-Host "POST /teams/$teamId/user-team-memberships { userId = $UserId, roleId = $RoleId }" -ForegroundColor Cyan
        Invoke-Api -Method Post -Path "/teams/$teamId/user-team-memberships" `
            -Body @{ teamId = [int]$teamId; userId = [int]$UserId; roleId = [int]$RoleId } | Out-Null
        Write-Host "Added $Label (user $UserId) to team $teamId with roleId $RoleId." -ForegroundColor Green
    }
}

Ensure-TeamMembership -UserId $userId -RoleId $MembershipRoleId -Label "machine user"

# The HUMAN bootstrap admin needs a membership too: their Global admin role (2)
# lacks the team-scoped profile privileges (never backfilled), so without a
# membership carrying them the Applications/Profiles pages return 403.
if ($AdminUsername)
{
    # Assign before piping: Invoke-RestMethod emits a JSON array as a single
    # object, and piping that directly would hand Where-Object the whole array.
    $allUsers = Invoke-Api -Method Get -Path "/users"
    $human = @($allUsers) | Where-Object { $_.username -ieq $AdminUsername } | Select-Object -First 1
    if ($human)
    {
        Ensure-TeamMembership -UserId ([int]$human.id) -RoleId $MembershipRoleId -Label "admin user '$AdminUsername'"
    }
    else
    {
        Write-Host "No Admin App user named '$AdminUsername' was found; skipping their team membership. The Applications/Profiles pages will return 403 for that account until it is added to a team." -ForegroundColor Yellow
    }
}
else
{
    Write-Host "-AdminUsername not set; the human bootstrap admin gets no team membership and the Applications/Profiles pages will return 403 for them. Re-run with ADMIN_USERNAME in .env (or -AdminUsername) to fix this." -ForegroundColor Yellow
}

# ---- Step 4: create (or reuse) the environment --------------------------------
# Idempotent: reuse an existing environment with the same name instead of
# POSTing a duplicate. The API has no uniqueness constraint on the name, so a
# blind POST on re-run would create a second environment.
$envId = $null
# Assign before piping (same Invoke-RestMethod single-object array quirk as above).
$allEnvs = Invoke-Api -Method Get -Path "/sb-environments"
$existingEnv = @($allEnvs) |
    Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
if ($existingEnv)
{
    $envId = $existingEnv.id
    Write-Host "Environment '$EnvironmentName' already exists (id $envId); reusing." -ForegroundColor Yellow
}
else
{
    # version and isMultitenant are intentionally omitted: create() auto-detects them
    # from the ODS/API metadata. configPrivate is produced + encrypted by the API.
    $payload = @{
        name               = $EnvironmentName
        environmentLabel   = $EnvironmentLabel
        adminApiUrl        = $AdminApiUrl
        odsApiDiscoveryUrl = $OdsApiDiscoveryUrl
        startingBlocks     = $false
        tenants            = @(
            @{
                name = $TenantName
                odss = @($Odss | ForEach-Object {
                    @{
                        id            = [int]$_.id
                        name          = [string]$_.name
                        dbName        = [string]$_.dbName
                        allowedEdOrgs = [string]$_.allowedEdOrgs
                    }
                })
            }
        )
    }

    Write-Host "POST /sb-environments" -ForegroundColor Cyan
    Write-Host ($payload | ConvertTo-Json -Depth 10)
    try
    {
        $response = Invoke-Api -Method Post -Path "/sb-environments" -Body $payload
    }
    catch
    {
        Write-Host "Create environment failed: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }

    Write-Host "`nEnvironment created." -ForegroundColor Green
    $response | ConvertTo-Json -Depth 10
    $envId = $response.id
}

# ---- Step 5: grant the team ownership of the environment + tenant(s) ----------
# create() only stamps createdBy; it does NOT write ownership rows, and the
# team-scoped privileges that surface resources read from `ownership`. Grant
# "Full ownership" (roleId 5) to the team for the environment and each tenant.
function Grant-Ownership
{
    param([hashtable]$Body, [string]$Label)
    try
    {
        Invoke-Api -Method Post -Path "/ownerships" -Body $Body | Out-Null
        Write-Host "Granted team $($Body.teamId) ownership of $($Body.type) ($Label), roleId $($Body.roleId)." -ForegroundColor Green
    }
    catch
    {
        $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        # A uniqueness conflict means the team already owns it -- treat as success.
        if ($msg -match '(?i)unique|exist|duplicate|conflict')
        {
            Write-Host "Ownership of $($Body.type) ($Label) already present." -ForegroundColor Yellow
        }
        else
        {
            Write-Host "Could not grant ownership of $($Body.type) ($Label): $msg" -ForegroundColor Red
            throw
        }
    }
}

if ($envId)
{
    # Ownership of the environment.
    Grant-Ownership -Label "$envId" -Body @{
        teamId          = [int]$teamId
        type            = "sbEnvironment"
        sbEnvironmentId = [int]$envId
        roleId          = [int]$OwnershipRoleId
    }

    # Ownership of each tenant under the environment.
    Write-Host "`nTenants under environment ${envId}:" -ForegroundColor Cyan
    $tenants = @()
    try
    {
        # Assign before wrapping (same Invoke-RestMethod single-object array quirk as above).
        $tenantsResponse = Invoke-Api -Method Get -Path "/sb-environments/$envId/edfi-tenants"
        $tenants = @($tenantsResponse)
        $tenants | ConvertTo-Json -Depth 10
    }
    catch
    {
        Write-Host "Could not list tenants: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    foreach ($t in $tenants)
    {
        Grant-Ownership -Label "$($t.id)" -Body @{
            teamId       = [int]$teamId
            type         = "edfiTenant"
            edfiTenantId = [int]$t.id
            roleId       = [int]$OwnershipRoleId
        }
    }
}