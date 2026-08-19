<#
.SYNOPSIS
Optional Identity Provider helper for Microsoft Entra ID. Creates and configures
a single-tenant Entra App Registration via Microsoft Graph so an operator can
stand up the Entra side of an Admin App install without clicking through the
Entra admin center. Outputs the client id and client secret for the OIDC seeding
step (install-all.ps1 -IdpProvider microsoft).

.DESCRIPTION
The Admin App's auth engine is provider-agnostic (generic OIDC discovery), so a
real deployment points it at whatever IdP the organization runs. When that IdP is
Microsoft Entra ID, this script automates the manual App Registration steps
(register the app, set the redirect URI, add the 'email' optional claim, add the
delegated openid/email Graph permissions, create a client secret).

It is separate from and optional to the main install: install-all.ps1 does NOT
call it. Run it first (against your Entra tenant), capture the client id and
secret it returns, then pass them to install-all.ps1 -IdpProvider microsoft.

Steps (each idempotent):
  1. Ensure the Microsoft.Graph.Applications module is available (auto-installs
     for CurrentUser unless -SkipModuleInstall).
  2. Connect-MgGraph with Application.ReadWrite.All (and, unless
     -SkipAdminConsent, DelegatedPermissionGrant.ReadWrite.All for consent; when
     the tenant denies that second scope at sign-in, reconnect without it and fall
     back to the manual consent URL).
  3. Create (or reuse) a single-tenant App Registration (SignInAudience
     AzureADMyOrg) with the Web redirect URI, the 'email' ID-token optional
     claim, and the delegated openid + email Microsoft Graph permissions.
  4. Create a client secret and capture its value (returned only at creation).
  5. Grant admin consent for the delegated permissions when the running identity
     is privileged enough; otherwise surface the exact manual admin-consent URL.

Google Workspace is intentionally NOT covered: Google exposes no supported API to
create the standard Web OAuth client the Admin App needs (only the IAP path, whose
clients cannot set a redirect URI), so for Google the OAuth client stays a manual,
documented step. See the Google guide, Part A.

.PARAMETER DisplayName
Display name for the App Registration. Reused idempotently: a second run with the
same name updates the existing registration instead of creating a duplicate.
Default: "Ed-Fi Admin App".

.PARAMETER TenantId
Entra tenant (GUID or domain) to connect to. Optional; when omitted, Connect-MgGraph
uses the identity's home/default tenant. The issuer in the output is derived from
the tenant resolved at connect time.

.PARAMETER ApiBaseUrl
Base URL of the Admin App API used to build the redirect URI when -RedirectUri is
not supplied. Default: https://localhost:3443 (the windows-install standalone API
site).

.PARAMETER RedirectCallbackId
The oidc row id the app builds its callback from (/api/auth/callback/<id>). On a
clean install that id is 1; install-all reads the real id back after boot. Used
only when -RedirectUri is not supplied. Default: 1.

.PARAMETER RedirectUri
Full Web redirect URI to register, overriding the ApiBaseUrl/RedirectCallbackId
default. Use this for a reverse-proxy layout such as the Confluence guide's
https://<host>/adminapp-api/api/auth/callback/1.

.PARAMETER SecretDisplayName
Friendly name recorded on the client secret. Default: "AdminApp OIDC secret".

.PARAMETER SecretValidMonths
Client-secret lifetime in months, 1 to 24 (the longest the Entra portal offers).
Default: 12.

.PARAMETER ReplaceExistingSecret
Switch -- once the new secret exists, remove the registration's other secrets that
carry the same -SecretDisplayName, i.e. the ones earlier runs of this script left
behind. Off by default, so a re-run keeps them; use it to hold exactly one active
secret per registration. Secrets added by hand, or under a different display name,
are never touched.

.PARAMETER SkipAdminConsent
Switch -- do not attempt to grant admin consent. The delegated openid/email scopes
are user-consentable, so consent can also happen at first sign-in; use this switch
when the running identity lacks the privilege to grant tenant-wide consent.

.PARAMETER SkipModuleInstall
Switch -- do not auto-install Microsoft.Graph.Applications. Fails fast if the
module is missing.

.PARAMETER UseDeviceCode
Switch -- authenticate with the device-code flow instead of the interactive
browser. Use this from an embedded or remote terminal, where the browser (WAM)
flow fails with "A window handle must be configured": the script prints a URL and
a code to enter on another device/browser.

.PARAMETER SecretOutFile
Path of the file the generated client secret is written to. Defaults to
entra-app-registration.txt one level above the repository folder (e.g.
C:\Ed-Fi\entra-app-registration.txt), matching where install-all.ps1 writes
install-summary.txt. The file's ACL is restricted to Administrators and SYSTEM.

.PARAMETER ShowSecret
Switch -- also echo the generated client secret in clear text on the console. Off
by default: the secret is written to the ACL-protected -SecretOutFile and redacted
from the console (the same convention install-all.ps1 uses for its generated
encryption key). The value is always available on the result object as a
SecureString for programmatic (piped) use.

.OUTPUTS
A PSCustomObject with Status, Warnings, ClientId, ClientSecret (a SecureString),
Issuer, RedirectUri, TenantId, SignedInUser, and SuggestedAdminUsername (the
signed-in account's mail, i.e. the source of Entra's email claim, or null when it
has none). Status is 'Ready', or 'PartiallyReady' when the registration exists but
something still needs a manual follow-up (admin consent not granted, or the secret
file not written or not locked down); Warnings lists those items. Capture it
(e.g. $r = .\idp-entra-setup.ps1 ...) and feed $r.ClientId / $r.ClientSecret /
$r.Issuer to install-all.ps1 -IdpProvider microsoft. Because ClientSecret is a
SecureString, it drops straight into install-all's -OidcClientSecret with no
conversion, and an uncaptured result never prints the secret value.

.EXAMPLE
$r = .\idp-entra-setup.ps1 -DisplayName 'Ed-Fi Admin App'
# then (ClientSecret is already a SecureString):
$adminUser = if ($r.SuggestedAdminUsername) { $r.SuggestedAdminUsername } else { 'you@yourtenant.onmicrosoft.com' }
.\install-all.ps1 -IdpProvider microsoft `
  -OidcIssuer $r.Issuer -OidcClientId $r.ClientId `
  -OidcClientSecret $r.ClientSecret `
  -AdminUsername $adminUser `
  -AppDbPassword (Read-Host -AsSecureString 'Admin App DB login password')

.NOTES
Prerequisites for the identity running this script:
  * Microsoft Graph scope Application.ReadWrite.All (to create/configure the app).
  * Entra role Cloud Application Administrator or higher (to create the
    registration), and Privileged Role Administrator / Global Administrator to
    grant admin consent.
Does not require an elevated (RunAsAdministrator) PowerShell.
#>

#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$DisplayName = "Ed-Fi Admin App",
    [string]$TenantId,
    [string]$ApiBaseUrl = "https://localhost:3443",
    [int]$RedirectCallbackId = 1,
    [string]$RedirectUri,
    [string]$SecretDisplayName = "AdminApp OIDC secret",
    [ValidateRange(1, 24)]
    [int]$SecretValidMonths = 12,
    [switch]$ReplaceExistingSecret,
    [switch]$SkipAdminConsent,
    [switch]$SkipModuleInstall,
    [switch]$UseDeviceCode,
    [string]$SecretOutFile,
    [switch]$ShowSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Well-known Microsoft Graph identifiers. The resource app id is constant across
# every tenant; the two scope ids are the stable delegated-permission ids for
# 'openid' and 'email' on Microsoft Graph.
$GraphAppId     = "00000003-0000-0000-c000-000000000000"
$OpenIdScopeId  = "37f7f235-527c-4136-accd-4a02d197296e"
$EmailScopeId   = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0"

# Resolve the redirect URI: an explicit -RedirectUri wins; otherwise build the
# windows-install standalone-site callback from -ApiBaseUrl and -RedirectCallbackId.
if (-not $RedirectUri) {
    $RedirectUri = "$($ApiBaseUrl.TrimEnd('/'))/api/auth/callback/$RedirectCallbackId"
}

Write-Host ""
Write-Host "Entra App Registration setup (Microsoft Graph)" -ForegroundColor Cyan
Write-Host "  App display name : $DisplayName"
Write-Host "  Redirect URI     : $RedirectUri"
Write-Host "  Sign-in audience : AzureADMyOrg (single tenant)"
Write-Host ""
Write-Host "Prerequisites for the identity you sign in as:" -ForegroundColor Yellow
Write-Host "  * Graph scope Application.ReadWrite.All (requested below)."
Write-Host "  * Entra role Cloud Application Administrator or higher to create the app."
Write-Host "  * Privileged Role Administrator / Global Administrator to grant admin consent."
Write-Host ""

# --- 1. Module ---------------------------------------------------------------
# Microsoft.Graph.Applications provides New-MgApplication / Add-MgApplicationPassword
# / New-MgServicePrincipal; it pulls Microsoft.Graph.Authentication (Connect-MgGraph,
# Invoke-MgGraphRequest) as a dependency. Install just this submodule, not the full
# Microsoft.Graph meta-module (which is large and slow).
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    if ($SkipModuleInstall) {
        throw "Microsoft.Graph.Applications is not installed and -SkipModuleInstall was set. Install it with: Install-Module Microsoft.Graph.Applications -Scope CurrentUser"
    }
    Write-Host "Installing Microsoft.Graph.Applications (CurrentUser)..."
    # Windows PowerShell 5.1's default ServicePointManager protocol can exclude
    # TLS 1.2, which the PowerShell Gallery requires -- enable it so Install-Module
    # doesn't fail the TLS handshake. (No-op on PowerShell 7, which already uses it.)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Write-Host "  (PSGallery is untrusted; installing with -Force to proceed non-interactively.)" -ForegroundColor DarkGray
    }
    Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force -AllowClobber
} else {
    Write-Host "Microsoft.Graph.Applications already installed."
}
Import-Module Microsoft.Graph.Applications

# --- 2. Connect --------------------------------------------------------------
# User.Read lets the script read the signed-in identity (/me) afterwards, to
# suggest -AdminUsername from that account's mail (the source of Entra's email claim).
$consentScope = 'DelegatedPermissionGrant.ReadWrite.All'
$scopes = @('Application.ReadWrite.All', 'User.Read')
if (-not $SkipAdminConsent) { $scopes += $consentScope }

$connectArgs = @{ Scopes = $scopes; NoWelcome = $true }
if ($TenantId) { $connectArgs.TenantId = $TenantId }
if ($UseDeviceCode) {
    # Device-code flow: no parent window handle needed, so it works from an
    # embedded/remote terminal where the interactive browser (WAM) fails with
    # "A window handle must be configured". The Graph SDK writes the device-code
    # prompt (URL + code) to the Information stream, which is silenced by default;
    # enable it for this call so the operator can actually see the code.
    $connectArgs.UseDeviceCode = $true
    $prevInformationPreference = $InformationPreference
    $InformationPreference = 'Continue'
    Write-Host "Connecting to Microsoft Graph (device code -- follow the URL and code printed below)..."
} else {
    Write-Host "Connecting to Microsoft Graph (a browser sign-in may open)..."
}
# The consent scope needs tenant admin approval of its own, so a tenant that has
# approved Application.ReadWrite.All for the Graph SDK but not this one fails the
# whole sign-in. That would strand the operator before step 5 ever prints the manual
# consent URL, so drop the scope and reconnect: creating the registration only needs
# Application.ReadWrite.All, and consent then falls back to that URL.
$consentScopeDenied = $false
try {
    try {
        Connect-MgGraph @connectArgs
    } catch {
        if ($SkipAdminConsent) { throw }
        Write-Host ""
        Write-Host "[WARN] Sign-in failed while requesting $($consentScope):" -ForegroundColor Yellow
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "       Retrying without it; admin consent becomes a manual step." -ForegroundColor Yellow
        $consentScopeDenied = $true
        $connectArgs.Scopes = @($scopes | Where-Object { $_ -ne $consentScope })
        Connect-MgGraph @connectArgs
    }
} finally {
    if ($UseDeviceCode) { $InformationPreference = $prevInformationPreference }
}

$context = Get-MgContext
if (-not $context) { throw "Connect-MgGraph did not establish a context. Aborting." }
$resolvedTenantId = $context.TenantId
$issuer = "https://login.microsoftonline.com/$resolvedTenantId/v2.0"

# Read the signed-in identity so we can suggest -AdminUsername. $context.Account is
# unreliable under WAM (often empty), so query /me for the userPrincipalName and,
# crucially, mail -- the attribute Entra's 'email' optional claim is sourced from.
# Best-effort: a failure here must not block the registration.
$signedInUpn = $null
$signedInMail = $null
try {
    $me = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me?`$select=userPrincipalName,mail"
    if ($me -is [System.Collections.IDictionary]) {
        if ($me.Contains('userPrincipalName')) { $signedInUpn  = $me['userPrincipalName'] }
        if ($me.Contains('mail'))              { $signedInMail = $me['mail'] }
    }
} catch {
    Write-Host "  (Could not read the signed-in account via /me: $($_.Exception.Message))" -ForegroundColor DarkGray
}
$signedInLabel = if ($signedInUpn) { $signedInUpn } else { '(unknown)' }
Write-Host "Connected. Tenant: $resolvedTenantId  Signed in as: $signedInLabel" -ForegroundColor Green

# --- 3. App Registration (create or reconcile) -------------------------------
# Desired configuration, shared between the create and update paths.
$optionalClaims = @{
    IdToken     = @(@{ Name = 'email'; Essential = $false; Source = $null; AdditionalProperties = @{} })
    AccessToken = @()
    Saml2Token  = @()
}
$requiredResourceAccess = @(
    @{
        ResourceAppId  = $GraphAppId
        ResourceAccess = @(
            @{ Id = $OpenIdScopeId; Type = 'Scope' },
            @{ Id = $EmailScopeId;  Type = 'Scope' }
        )
    }
)

# displayName is not unique in Entra, but we treat it as the idempotency key for
# this managed registration: reuse the first match rather than create a duplicate.
$escapedName = $DisplayName -replace "'", "''"
$existingApp = Get-MgApplication -Filter "displayName eq '$escapedName'" -All | Select-Object -First 1

if ($existingApp) {
    Write-Host "App Registration '$DisplayName' already exists (appId $($existingApp.AppId)); reconciling configuration..." -ForegroundColor Yellow
    # Merge the desired redirect URI into any already registered, so a re-run with
    # a different host/callback id adds rather than replaces.
    $existingRedirects = @()
    if ($existingApp.Web -and $existingApp.Web.RedirectUris) { $existingRedirects = @($existingApp.Web.RedirectUris) }
    $mergedRedirects = @($existingRedirects + $RedirectUri | Select-Object -Unique)

    Update-MgApplication -ApplicationId $existingApp.Id `
        -SignInAudience 'AzureADMyOrg' `
        -Web @{ RedirectUris = $mergedRedirects } `
        -OptionalClaims $optionalClaims `
        -RequiredResourceAccess $requiredResourceAccess | Out-Null
    $app = Get-MgApplication -ApplicationId $existingApp.Id
    Write-Host "Configuration reconciled."
    if ($ReplaceExistingSecret) {
        Write-Host "NOTE: a NEW secret is created below; earlier ones named '$SecretDisplayName' are then removed (-ReplaceExistingSecret)." -ForegroundColor DarkGray
    } else {
        Write-Host "NOTE: existing client secrets are left in place; a NEW secret is created below. Pass -ReplaceExistingSecret to drop the earlier ones." -ForegroundColor DarkGray
    }
} else {
    Write-Host "Creating App Registration '$DisplayName'..."
    $app = New-MgApplication `
        -DisplayName $DisplayName `
        -SignInAudience 'AzureADMyOrg' `
        -Web @{ RedirectUris = @($RedirectUri) } `
        -OptionalClaims $optionalClaims `
        -RequiredResourceAccess $requiredResourceAccess
    Write-Host "Created. Object id $($app.Id), appId $($app.AppId)." -ForegroundColor Green
}

$clientId = $app.AppId

# --- 4. Client secret --------------------------------------------------------
# The secret value is returned only once, at creation, and cannot be retrieved
# later -- capture it now for the OIDC seeding step.
Write-Host "Creating client secret (valid $SecretValidMonths months)..."
$endDate = (Get-Date).AddMonths($SecretValidMonths)
$passwordCredential = @{
    DisplayName = $SecretDisplayName
    EndDateTime = $endDate
}
$secretResult = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $passwordCredential
$clientSecret = $secretResult.SecretText
Write-Host "Client secret created (id $($secretResult.KeyId), expires $($endDate.ToString('yyyy-MM-dd')))." -ForegroundColor Green

# Every run mints a secret, so repeated runs (a retry, a redirect-uri correction)
# leave credentials behind that still authenticate. -ReplaceExistingSecret removes
# the ones an earlier run of this script left, matched on the display name so a
# secret added by hand is never touched. Best-effort: the new secret already works,
# so a cleanup failure is a warning on the run, not a failure of it.
$staleSecretsRemoved = 0
$secretCleanupWarning = $null
if ($ReplaceExistingSecret) {
    try {
        $staleSecrets = @((Get-MgApplication -ApplicationId $app.Id).PasswordCredentials |
            Where-Object { $_.KeyId -ne $secretResult.KeyId -and $_.DisplayName -eq $SecretDisplayName })
        foreach ($staleSecret in $staleSecrets) {
            Remove-MgApplicationPassword -ApplicationId $app.Id -KeyId $staleSecret.KeyId
            $staleSecretsRemoved++
        }
        if ($staleSecretsRemoved -gt 0) {
            Write-Host "Removed $staleSecretsRemoved earlier secret(s) named '$SecretDisplayName' (-ReplaceExistingSecret)." -ForegroundColor Yellow
        } else {
            Write-Host "No earlier secret named '$SecretDisplayName' to remove." -ForegroundColor DarkGray
        }
    } catch {
        $secretCleanupWarning = "the earlier client secrets could not be removed ($($_.Exception.Message)); delete them in the Entra portal"
        Write-Warning "The new secret was created, but $secretCleanupWarning."
    }
}

# --- 5. Admin consent --------------------------------------------------------
$consentGranted = $false
$adminConsentUrl = "https://login.microsoftonline.com/$resolvedTenantId/adminconsent?client_id=$clientId"

if ($SkipAdminConsent) {
    Write-Host "Skipping admin consent (-SkipAdminConsent). openid/email are user-consentable at first sign-in." -ForegroundColor Yellow
} elseif ($consentScopeDenied) {
    Write-Host ""
    Write-Host "[WARN] Admin consent not attempted: the sign-in could not obtain $($consentScope)." -ForegroundColor Yellow
    Write-Host "       Grant it manually (a privileged admin opens this URL once):" -ForegroundColor Yellow
    Write-Host "         $adminConsentUrl"
    Write-Host "       Alternatively, openid/email are user-consentable at first sign-in." -ForegroundColor DarkGray
} else {
    Write-Host "Granting admin consent for delegated openid + email..."
    try {
        # A service principal in this tenant is the consent target. Create it if the
        # app doesn't have one yet.
        $sp = Get-MgServicePrincipal -Filter "appId eq '$clientId'" -All | Select-Object -First 1
        if (-not $sp) {
            $sp = New-MgServicePrincipal -AppId $clientId
            Write-Host "  Service principal created ($($sp.Id))."
        }
        $graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'" -All | Select-Object -First 1
        if (-not $graphSp) { throw "Microsoft Graph service principal not found in the tenant." }

        # Reconcile a tenant-wide (AllPrincipals) delegated grant for the two scopes.
        # Use Invoke-MgGraphRequest so this doesn't depend on Microsoft.Graph.Identity.SignIns.
        $existingGrants = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($sp.Id)' and resourceId eq '$($graphSp.Id)'"
        $grant = $null
        if ($existingGrants.value) { $grant = $existingGrants.value | Select-Object -First 1 }

        if ($grant) {
            $currentScopes = @(($grant.scope -split ' ') | Where-Object { $_ })
            $mergedScopes = @($currentScopes + 'openid' + 'email' | Select-Object -Unique) -join ' '
            if ($mergedScopes -ne $grant.scope) {
                Invoke-MgGraphRequest -Method PATCH `
                    -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($grant.id)" `
                    -Body @{ scope = $mergedScopes } | Out-Null
            }
        } else {
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" -Body @{
                clientId    = $sp.Id
                consentType = 'AllPrincipals'
                resourceId  = $graphSp.Id
                scope       = 'openid email'
            } | Out-Null
        }
        $consentGranted = $true
        Write-Host "Admin consent granted (tenant-wide)." -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[WARN] Could not grant admin consent automatically: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "       Your identity likely lacks Privileged Role Administrator / Global Administrator." -ForegroundColor Yellow
        Write-Host "       Grant it manually (a privileged admin opens this URL once):" -ForegroundColor Yellow
        Write-Host "         $adminConsentUrl"
        Write-Host "       Alternatively, openid/email are user-consentable at first sign-in." -ForegroundColor DarkGray
    }
}

# --- Output ------------------------------------------------------------------
# The client secret is GENERATED here and cannot be retrieved later. Following the
# same convention install-all.ps1 uses for its generated data-encryption key, the
# secret is written to an ACL-protected file (Administrators + SYSTEM only) and
# REDACTED from the console. -ShowSecret additionally echoes it inline; the returned
# object always carries it as a SecureString for programmatic (piped) use.
if (-not $SecretOutFile) {
    # One level above the repo folder (e.g. C:\Ed-Fi), matching where install-all
    # writes install-summary.txt; it is an install artifact, not a script.
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $SecretOutFile = Join-Path (Split-Path $repoRoot -Parent) 'entra-app-registration.txt'
}

$consentText = if ($consentGranted) { 'granted' } elseif ($SkipAdminConsent) { 'skipped (grant manually or at first sign-in)' } else { 'NOT granted -- see the URL above' }
$fileBody = @"
Ed-Fi Admin App -- Entra App Registration (created by idp-entra-setup.ps1)

  Tenant id            : $resolvedTenantId
  Client id (App ID)   : $clientId
  Client secret        : $clientSecret
  Issuer               : $issuer
  Redirect URI         : $RedirectUri
  Admin consent        : $consentText
  Suggested AdminUsername (signed-in mail) : $signedInMail

Feed these to install-all.ps1 -IdpProvider microsoft:
  -OidcIssuer '$issuer'
  -OidcClientId '$clientId'
  -OidcClientSecret <the client secret above>
  -AdminUsername '$signedInMail'

This file's ACL is restricted to Administrators and SYSTEM because it holds the
client secret, which is shown only once at creation and is not retrievable later.
Copy the secret into your secret store, then you may delete this file.
"@

# Write the secret to the protected file. Distinguish a write failure (fall back to
# showing the secret inline, so it is never lost) from an ACL failure (file written
# but not locked down -- warn, keep the console redacted since the file holds it).
$secretWritten = $false
$secretAclRestricted = $false
$secretFileStatus = "(not written)"
try {
    $secretDir = Split-Path $SecretOutFile -Parent
    if ($secretDir -and -not (Test-Path $secretDir)) { New-Item -ItemType Directory -Path $secretDir -Force | Out-Null }
    Set-Content -Path $SecretOutFile -Value $fileBody -Encoding UTF8
    $secretWritten = $true
    try {
        # Administrators (S-1-5-32-544) + SYSTEM (S-1-5-18); well-known SIDs, so
        # locale-independent. Drop inherited access so C:\Ed-Fi's ACL doesn't apply.
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
            $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
        }
        Set-Acl -Path $SecretOutFile -AclObject $acl
        $secretAclRestricted = $true
        $secretFileStatus = "$SecretOutFile (Administrators-only)"
    } catch {
        Write-Warning "Wrote the secret file but could not restrict its ACL ($($_.Exception.Message)). It holds the client secret -- protect or delete it manually: $SecretOutFile"
        $secretFileStatus = "$SecretOutFile (WARNING: ACL not restricted -- protect it manually)"
    }
} catch {
    Write-Warning "Could not write the secret file ($($_.Exception.Message)); showing the secret inline instead so it is not lost."
}

# Redact unless -ShowSecret; but if the file could not be written, show it inline so
# a standalone operator does not lose the one-time value.
$secretDisplay = if ($ShowSecret -or -not $secretWritten) { $clientSecret } else { '(redacted -- see the protected file below)' }

# The registration can be usable and still need a manual follow-up: consent this
# identity could not grant, a secret file that could not be written or locked down.
# Report that as PartiallyReady rather than SUCCESS, and carry it on the result
# object so a caller can branch on it without scraping the console. An explicit
# -SkipAdminConsent is an operator decision, not an incomplete run.
$warnings = @()
if (-not $consentGranted -and -not $SkipAdminConsent) {
    $warnings += 'admin consent was not granted: open the admin-consent URL above, or let the first sign-in consent openid/email'
}
if (-not $secretWritten) {
    $warnings += 'the client secret file could not be written: copy the secret shown above before closing this window'
} elseif (-not $secretAclRestricted) {
    $warnings += "the client secret file is not ACL-restricted: protect or delete $SecretOutFile by hand"
}
if ($secretCleanupWarning) { $warnings += $secretCleanupWarning }
$status = if ($warnings.Count -eq 0) { 'Ready' } else { 'PartiallyReady' }

Write-Host ""
if ($status -eq 'Ready') {
    Write-Host "SUCCESS: Entra App Registration ready." -ForegroundColor Green
} else {
    Write-Host "PARTIAL SUCCESS: the App Registration exists but needs a manual follow-up:" -ForegroundColor Yellow
    foreach ($warning in $warnings) { Write-Host "  * $warning" -ForegroundColor Yellow }
    Write-Host ""
}
Write-Host "Values below are what install-all.ps1 -IdpProvider microsoft needs:" -ForegroundColor Green
Write-Host "  Status              : $status"
Write-Host "  Tenant id           : $resolvedTenantId"
Write-Host "  Client id (App ID)  : $clientId"
Write-Host "  Client secret       : $secretDisplay"
Write-Host "  Issuer              : $issuer"
Write-Host "  Redirect URI        : $RedirectUri"
Write-Host "  Admin consent       : $consentText"
if ($secretWritten) {
    Write-Host "  Client secret saved to: $secretFileStatus" -ForegroundColor Cyan
    Write-Host "  (Shown only once and not retrievable later; copy it to your secret store, then you may delete the file.)" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "Next: feed these to the OIDC seeding step. If you captured this run's result" -ForegroundColor Cyan
Write-Host "(`$r = .\idp-entra-setup.ps1 ...), the hand-off is copy-paste ready:" -ForegroundColor Cyan
Write-Host "  .\install-all.ps1 -IdpProvider microsoft ``"
Write-Host "    -OidcIssuer `$r.Issuer ``"
Write-Host "    -OidcClientId `$r.ClientId ``"
Write-Host "    -OidcClientSecret `$r.ClientSecret ``"
Write-Host "    -AdminUsername `$r.SuggestedAdminUsername ``"
Write-Host "    -AppDbPassword (Read-Host -AsSecureString 'Admin App DB login password')"
Write-Host ""
Write-Host "  Without a captured result, pass the values printed above and read the secret" -ForegroundColor DarkGray
Write-Host "  back with -OidcClientSecret (Read-Host -AsSecureString 'OIDC client secret')." -ForegroundColor DarkGray
Write-Host "  -AdminUsername must equal the 'email' claim of the Entra user who signs in." -ForegroundColor DarkGray
if ($signedInMail) {
    Write-Host "  You authenticated as $signedInUpn (mail: $signedInMail)." -ForegroundColor DarkGray
    Write-Host "  If you will sign in to the Admin App as that same account, use:" -ForegroundColor DarkGray
    Write-Host "    -AdminUsername '$signedInMail'" -ForegroundColor Green
} elseif ($signedInUpn) {
    Write-Host "  You authenticated as $signedInUpn, which has NO 'mail' attribute set. Entra's" -ForegroundColor Yellow
    Write-Host "  'email' claim is sourced from 'mail', so signing in as this account will fail" -ForegroundColor Yellow
    Write-Host "  with 'Invalid email from IdP'. Sign in as a tenant user that has a mailbox/email." -ForegroundColor Yellow
} else {
    Write-Host "  (Could not detect the signed-in account's email; pick a tenant user that has one.)" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "The redirect URI registered here must match the callback the app sends. On a" -ForegroundColor DarkGray
Write-Host "clean install that is callback/1; if install-all reports a different id, re-run" -ForegroundColor DarkGray
Write-Host "this script with -RedirectCallbackId <id> (or -RedirectUri) to add the match." -ForegroundColor DarkGray

# Emit the machine-readable result last so it is the pipeline output.
# ClientSecret is returned as a SecureString, not plain text: if the caller forgets
# to capture the result, PowerShell's auto-formatting prints the object but shows
# only the SecureString type, never the value (the plain-text value lives only in
# the ACL-protected -SecretOutFile, or inline when -ShowSecret is set). It also
# drops straight into install-all.ps1's [SecureString] -OidcClientSecret unchanged.
# SuggestedAdminUsername is the signed-in account's mail (source of Entra's email
# claim) when available -- a convenience for the caller; it is null when that
# account has no mail, in which case the operator must supply -AdminUsername.
# Status ('Ready' or 'PartiallyReady') and Warnings expose an incomplete run to an
# automated caller, which the console text alone could not.
[PSCustomObject]@{
    Status                 = $status
    ClientId               = $clientId
    ClientSecret           = (ConvertTo-SecureString $clientSecret -AsPlainText -Force)
    Issuer                 = $issuer
    RedirectUri            = $RedirectUri
    TenantId               = $resolvedTenantId
    SignedInUser           = $signedInUpn
    SuggestedAdminUsername = $signedInMail
    Warnings               = $warnings
}
