# Ed-Fi Admin App — Windows IIS Installation Scripts

Automates the gaps in the official [Windows IIS Installation docs](https://docs.ed-fi.org/reference/admin-app/getting-started/windows-iis-installation). Designed to run on a clean Windows virtual machine and produce a working Admin App at `https://localhost:4443/` with no manual workarounds.

TLS is on by default. The API and frontend deploy as two independent IIS sites over HTTPS — `https://localhost:3443` (API) and `https://localhost:4443` (web application) — and each keeps an HTTP binding (`3333` / `4200`) that issues a 301 redirect to HTTPS. When no certificate is supplied, a self-signed one is generated and trusted on the local machine automatically. See [TLS / HTTPS](#tls--https) for real-certificate options and the self-signed caveat.

---

## Getting the scripts onto the virtual machine

These scripts live in this repository (`Admin-App-Installation-Scripts`). On a fresh virtual machine, get them there first by either:

- `git clone https://github.com/Ed-Fi-Exchange-OSS/Admin-App-Installation-Scripts.git C:\Ed-Fi\Admin-App-Installation-Scripts` (needs Git — install manually with `winget install --id Git.Git -e`, or use the ZIP option below), **or**
- Download this repository as a ZIP from GitHub and extract to `C:\Ed-Fi\Admin-App-Installation-Scripts`. `setup-vm-prereqs.ps1` will install Git for you afterwards.

Then open an **elevated PowerShell** and `cd C:\Ed-Fi\Admin-App-Installation-Scripts\windows-install`.

You do **not** need to clone the Admin App application repository yourself: `install-all.ps1` fetches the Admin App source automatically (the latest stable release by default), cloning it as a sibling folder (e.g. `C:\Ed-Fi\Ed-Fi-AdminApp`). To use a checkout you already have, pass `-SourcePath`; to pin a specific version, pass `-AdminAppRef <tag>`.

## Before you start

**These scripts install Admin App only.** They assume an Ed-Fi ODS/API is already installed and reachable; they provision only the Admin App database (`sbaa`), **not** `EdFi_Admin` or `EdFi_Security`. You point the Admin App at your existing ODS/API by adding an Environment after sign-in (see [Next steps after install](#next-steps-after-install)). Installing the Admin App database in its own SQL Server instance, separate from the ODS/API databases, is recommended.

- **Windows 10/11 Pro or Windows Server 2016+**, with **administrator rights** (every command runs in an *elevated* PowerShell). The standalone-site environment variables require **IIS 10 or newer**.
- **Windows Package Manager (`winget`).** The scripts use it to install Node.js, OpenJDK, SQL Server, and Git. It ships with Windows 10/11 but **not** with Windows Server 2019/2022. On Windows Server, install winget as a prerequisite first (Microsoft's [App Installer](https://learn.microsoft.com/windows/package-manager/winget/#install-winget), or a community helper such as the PSGallery `winget-install` script, which is third-party, so use it at your own risk), then run the scripts. `00-check-prereqs.ps1` flags when winget is missing.
- **SQL Server default instance (`MSSQLSERVER`).** The quick-start targets the default instance. `02-prereqs-sql.ps1` accepts `-InstanceName`, but the end-to-end path is validated only against the default instance — a named/non-default instance is not covered here.
- **Internet access** — the scripts download Node, Keycloak, and npm packages.
- **~10 GB free disk**.
- **Docker is not required for the default path.** The SQL Server default path needs no Docker at all. **Docker Desktop** is only needed if you opt into `-UsePostgresDocker` or `-SetupYopassDocker`, in which case it must be **installed, running, and in Linux-container mode** (the pre-flight check verifies this when those flags are set).
- **Allow 15–20 minutes** for a fresh end-to-end install (the build phase alone takes several minutes).
- The passwords below are **yours to choose** — wherever you see `'your-…'`, replace it with a password you pick.

## Quick start (local Keycloak)

`install-all.ps1` is the "run everything" path. Pick the identity provider with the mandatory **`-IdpProvider`** (`keycloak` | `microsoft` | `google` | `other`). `keycloak` stands up a local Keycloak as the example identity provider; for an external provider see [Other identity providers](#other-identity-providers).

```powershell
# One-time, current-process-only bypass so the first script can run. It affects only
# this PowerShell session; setup-vm-prereqs.ps1 then Unblock-File's the repo scripts so
# the rest run without changing your machine-wide execution policy.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 1. OS prerequisites (IIS, SQL Server, Git). ONLY on a fresh virtual machine. Scans before it
#    installs, so re-running on a prepared virtual machine is a no-op. Reboot if winget asks.
.\setup-vm-prereqs.ps1

# 2. Full Admin App install (local Keycloak). The pre-flight check tells you if
#    step 1 was actually needed.
.\install-all.ps1 -IdpProvider keycloak `
  -AppDbPassword (Read-Host -AsSecureString 'Admin App DB login password') `
  -KeycloakAdminPassword (Read-Host -AsSecureString 'Keycloak admin password') `
  -OidcClientSecret (Read-Host -AsSecureString 'OIDC client secret') `
  -TestUserPassword (Read-Host -AsSecureString 'Keycloak test user password')
```

When `install-all.ps1` finishes, open `https://localhost:4443/` and sign in with `admin@example.com` (or whatever you passed to `-AdminUsername`) and your `-TestUserPassword`. A green `INSTALL COMPLETE` banner and a written `install-summary.txt` (in the parent of the repository directory, e.g. `C:\Ed-Fi\install-summary.txt`) confirm success.

### Notes on the parameters

- **All password/secret parameters are `[SecureString]`.** Supply each with `(Read-Host -AsSecureString '...')` as shown above, never a plaintext literal — a plaintext string fails parameter binding before the script runs, and a literal on the command line would be captured in your shell history.
- **`-AppDbPassword`** *(mssql)*: password for the dedicated least-privilege login (`edfi_adminapp`) the Admin App connects as (`db_owner` on `sbaa`, non-`sa`). Required in the default `mssql` mode; the app uses it at runtime, so provisioning and deploy must receive the same value. Must satisfy the Windows password policy `CHECK_POLICY` enforces — length ≥ 8 and at least 3 of 4 character categories (uppercase, lowercase, digit, symbol); weak passwords are rejected up front. The same rule applies to every SQL login the scripts create.
- **SQL Server bootstrap runs under Windows Authentication.** Run the install as a Windows account that is a SQL Server sysadmin: `02-prereqs-sql.ps1` creates the database and the `edfi_adminapp` login over Windows authentication and never enables, resets, or uses the `sa` login. There is no `-SaPassword` parameter.
- **`-IdpProvider`** *(mandatory)*: `keycloak` | `microsoft` | `google` | `other`. `keycloak` runs the local example identity provider; the others target an external OIDC provider (see [Other identity providers](#other-identity-providers)).
- **`-OidcClientSecret`** *(all modes)*: the OIDC client secret. For `keycloak` it's the secret set on the `edfiadminapp` client (you pick it, 32+ chars recommended); for external providers it's the secret from your app registration.
- **`-KeycloakAdminPassword`** *(keycloak only)*: Password for the master-realm admin user auto-created when Keycloak first starts.
- **`-TestUserPassword`** *(keycloak only)*: Password for the seeded `admin@example.com` user in the `edfi` realm — what you type on the Keycloak login screen.

#### Database engine selection

- **`-DbEngine`**: `mssql` (default) or `pgsql`. Drives the database prerequisite path and how `production.js` gets patched. Everything else is identical.
- **PostgreSQL (Docker) parameters** *(pgsql only)*: instead of `-AppDbPassword`, pass `-UsePostgresDocker` with `-PostgresSuperuserPassword` (the container superuser) and `-PostgresAppPassword` (the least-privilege app role `edfiadminapp`). Both are `[SecureString]`:

  ```powershell
  .\install-all.ps1 -IdpProvider keycloak -DbEngine pgsql -UsePostgresDocker `
    -PostgresSuperuserPassword (Read-Host -AsSecureString 'Postgres superuser password') `
    -PostgresAppPassword (Read-Host -AsSecureString 'Admin App database role password') `
    -KeycloakAdminPassword (Read-Host -AsSecureString 'Keycloak admin password') `
    -OidcClientSecret (Read-Host -AsSecureString 'OIDC client secret') `
    -TestUserPassword (Read-Host -AsSecureString 'Keycloak test user password')
  ```

---

## The scripts

Numbered scripts map to the official guide's section order. The **generic path** (00–06) is all the Admin App itself needs; the **local identity provider example** (`idp-keycloak-*`) is optional.

### Generic path

| Script | Purpose |
|---|---|
| `00-check-prereqs.ps1` | Read-only diagnostic. `[PASS]`/`[FAIL]`/`[INFO]`/`[RISK]` per prerequisite. `[RISK]` flags collisions with existing software (shared SQL instance, older `java` on PATH, ports 3333/4200/3443/4443 in use). Exit 0 = clean, 1 = blocking, 2 = ready-with-risks. |
| `01-prereqs-iis.ps1` | URL Rewrite Module + the HTTP hosting handler (HttpBridge by default, or HttpPlatformHandler via `-HttpHandler`); unlocks the `handlers` section. HTTPS bindings are added at deploy time by `05`/`06`. |
| `02-prereqs-sql.ps1` | SQL Server config: Mixed Mode + TCP/IP + creates the `sbaa` database + provisions a dedicated least-privilege app login (`edfi_adminapp`, `db_owner` on `sbaa` only, not a server sysadmin) that the app connects as. All server-level work runs under Windows authentication; the `sa` login is never touched. |
| `03-prereqs-node.ps1` | Node.js install (if missing) and nvm-windows remediation of a too-old version. No Java, no Keycloak. |
| `04-build.ps1` | `npm ci --legacy-peer-deps`, then `build:api` and `build:fe`. Seeds `packages\fe\.env` (VITE_*) before building. Skips if artifacts are current (override with `-Force`). |
| `05-deploy-api.ps1` | Deploys the API to the standalone site `EdFi-AdminApp-API` (HTTPS `3443`; HTTP `3333` redirects to it). Seeds/patches `production.js`, writes `web.config`, configures the App Pool, and sets `NPM_CONFIG_CACHE` on the App Pool. |
| `06-deploy-fe.ps1` | Deploys the web application to the standalone site `EdFi-AdminApp-FE` (HTTPS `4443`; HTTP `4200` redirects to it) with a SPA-fallback `web.config`. |

### Local identity provider example (optional — Keycloak)

| Script | Purpose |
|---|---|
| `idp-keycloak-setup.ps1` | One run = a ready local Keycloak: installs a JDK if needed, downloads Keycloak, starts it (via `idp-keycloak-start.ps1`), then provisions the `edfi` realm, `edfiadminapp` client, and test user. |
| `idp-keycloak-start.ps1` | Starts Keycloak in the background (bootstraps the master admin on first run, waits for readiness). Does not require elevation. Use to relaunch Keycloak by hand. |

### Transversal

| Script | Purpose |
|---|---|
| `setup-vm-prereqs.ps1` | OS-level installs only: IIS features, SQL Server Developer, Git. Scans first, installs only what's missing. |
| `install-all.ps1` | Master orchestrator. Pick the identity provider with `-IdpProvider` (keycloak/microsoft/google/other). Pre-flight check + all phases + smoke test. |
| `yopass-docker.ps1` | Optional. Stands up a local Yopass + memcached stack via `docker\docker-compose.yopass.yml`. Only runs with `install-all -SetupYopassDocker` (or directly). |
| `uninstall.ps1` | Reverses the generic install: IIS sites/App Pool/files, the `sbaa` database, docker Postgres + Yopass stacks, `C:\npm-cache`. Detects Keycloak leftovers and suggests `uninstall-keycloak.ps1` (does not touch them). Per-step OK/SKIP/WARN/FAIL ledger. |
| `uninstall-keycloak.ps1` | Tears down the local Keycloak identity provider: stops the process, deletes the install directory, unsets `JAVA_HOME`. Leaves the JDK install in place. |

### Per-section mapping to the official guide

| Guide section/step | Script(s) |
|---|---|
| Prerequisites: IIS + URL Rewrite + hosting handler | `01-prereqs-iis.ps1` |
| Prerequisites: Node.js | `03-prereqs-node.ps1` |
| Prerequisites: SQL Server / PostgreSQL (+ `sbaa`) | `02-prereqs-sql.ps1` |
| Prerequisites: Identity Provider | `idp-keycloak-setup.ps1` (local example) or your own identity provider |
| Backend API → build | `04-build.ps1` (also builds the web application) |
| Backend API → deploy (site, web.config, handler mappings, App Pool, dirs) | `05-deploy-api.ps1` (handler-mapping unlock done by `01-prereqs-iis.ps1`) |
| Frontend → configure `.env` + build | `04-build.ps1` (Vite bakes vars at **build** time, not deploy) |
| Frontend → deploy (site, SPA rewrite) | `06-deploy-fe.ps1` |

> The guide's "configure Handler Mappings manually in IIS Manager" step is automated: `01-prereqs-iis.ps1` unlocks the `handlers` section and `05-deploy-api.ps1` declares the httpPlatform handler in `web.config`.

---

## Other identity providers

The Admin App's authentication engine is provider-agnostic (generic OIDC discovery). Keycloak is only the example identity provider. To use an external provider, run `install-all.ps1` with `-IdpProvider microsoft | google | auth0 | other`: it deploys everything and **skips** the local Keycloak step, configuring the API against your provider instead.

```powershell
.\install-all.ps1 -IdpProvider microsoft `
  -AppDbPassword (Read-Host -AsSecureString 'Admin App DB login password') `
  -OidcIssuer 'https://login.microsoftonline.com/<tenant-id>/v2.0' `
  -OidcClientId '<application-id>' `
  -OidcClientSecret (Read-Host -AsSecureString 'OIDC client secret') `
  -AdminUsername 'you@yourtenant.onmicrosoft.com'
```

- `keycloak`/`google` default `-OidcIssuer`; `microsoft`/`auth0`/`other` require it. `-ViteIdpAccountUrl` is defaulted per provider (`other` requires it; `auth0` defaults it to the tenant URL, since Auth0 has no hosted account page). `-OidcScope` defaults to `openid email profile`.
- **Where to find `-OidcIssuer`:** for Entra, the App Registration → *Endpoints* → "OpenID Connect metadata document" URL, minus the trailing `/.well-known/openid-configuration` (typically `https://login.microsoftonline.com/<tenant-id>/v2.0`). For Google it's `https://accounts.google.com` (the default). For Auth0 it's the tenant **Domain** shown on the application's Settings page, as a URL (e.g. `https://your-tenant.us.auth0.com`).
- `-MachineAudience` (default `edfiadminapp-api`) sets the audience the API expects on machine-to-machine bearer tokens (`AUTH0_CONFIG_SECRET_VALUE.MACHINE_AUDIENCE`) — align it with your provider's API identifier without editing config files on the server.
- **You register the OIDC client yourself** in the provider's portal (no script can provision Entra/Google). `install-all` validates the issuer's discovery endpoint and, at the end of the install, prints the exact URIs to register. The redirect URI is `https://localhost:3443/api/auth/callback/<id>`, where `<id>` is the `oidc` database row id `install-all` resolves and prints ("OIDC redirect callback id resolved to `<id>`") — register `callback/<that id>`, not a hardcoded `callback/1`. Post-logout is `https://localhost:3443/api/auth/post-logout` and the allowed origin is `https://localhost:4443`.
- A user must exist in the provider whose **email/username claim equals `-AdminUsername`** — the script seeds that user in the `[user]` table with the admin role, but the identity lives in your identity provider. For Entra specifically, the app registration must emit an `email` claim; see [Entra: "Invalid email from IdP" after sign-in](#entra-invalid-email-from-idp-after-sign-in).

You can also drive the per-section scripts manually (`00`→`06`), passing `-Oidc*` to `05-deploy-api.ps1` and `-ViteIdpAccountUrl` to `04-build.ps1`. When you do, the OIDC **client secret, issuer, client id, and admin username must match** between the identity-provider step (`idp-keycloak-setup.ps1` or your external provider) and `05-deploy-api.ps1` — a mismatch surfaces as a login failure, not an install error. Open a **fresh** elevated PowerShell after `03-prereqs-node.ps1` installs Node, so the updated `PATH` is in effect before `04-build.ps1` runs.

### Auth0

Human login and machine-to-machine (M2M) access both work with `-IdpProvider auth0`; set up the tenant in the Auth0 dashboard first:

1. **Human login — Applications → Create Application → Single Page Web Application.** Note the **Domain** (→ `-OidcIssuer` as `https://<domain>`), **Client ID** (→ `-OidcClientId`) and **Client Secret** (→ `-OidcClientSecret`). After the install prints the resolved callback id, register in the application's Settings exactly what it printed:
   | Auth0 field | Value (defaults) |
   | --- | --- |
   | Allowed Callback URLs | `https://localhost:3443/api/auth/callback/<id>` |
   | Allowed Logout URLs | `https://localhost:3443/api/auth/post-logout` |
   | Allowed Web Origins | `https://localhost:4443` |
2. **Users need an email.** Every person who will log in must exist as an Auth0 user **with an email address** — the Admin App requires an `email` claim from the IdP, and the default `-OidcScope` (`openid email profile`) is what makes Auth0 emit it; don't change it. `-AdminUsername` must exactly match the initial admin's Auth0 email.
3. **M2M — Applications → APIs → Create API** with **Identifier** equal to `-MachineAudience` (default `edfiadminapp-api`) and its **JSON Web Token (JWT) Profile set to RFC 9068** — the legacy "Auth0" profile omits the `client_id` claim from client-credentials tokens, which only Admin App builds with the `azp` fallback tolerate (v4.0.1 and earlier then fail every bearer call with 401; RFC 9068 works on every version). Add a **`login:app`** permission on the API. Then **Create Application → Machine to Machine**, authorize it for that API with `login:app` granted. Seed the machine user with `quick-start/bootstrap.ps1 -Provider auth0` (it also verifies a real token's claims) or create it in the web app using the M2M application's Client ID.
4. **Trailing slash — handled for you.** Auth0 needs the issuer in two forms: OIDC discovery requires **no** trailing slash (a slash 404s the discovery URL), while M2M verification exact-matches the token's `iss` claim, which Auth0 always emits **with** the slash. `-IdpProvider auth0` derives both forms from `-OidcIssuer` (either form accepted) and writes each to its destination — no post-install `NODE_CONFIG` surgery. With `-IdpProvider other` you get one raw value for both and Auth0 M2M cannot work without that manual fix (which every re-run of the installer reverts) — use `auth0`.

---

## Uninstalling

```powershell
.\uninstall.ps1                                       # prompts before doing anything
.\uninstall.ps1 -Force                                # non-interactive teardown (Windows Authentication)
.\uninstall.ps1 -KeepDatabase -KeepNpmCache           # selective teardown

.\uninstall-keycloak.ps1                              # remove the local Keycloak identity provider (separate)
```

`uninstall.ps1` covers the generic install and, at the end, flags any Keycloak leftovers and points you at `uninstall-keycloak.ps1`. See `Get-Help .\uninstall.ps1 -Full` / `Get-Help .\uninstall-keycloak.ps1 -Full` for all flags.

---

## What `install-all.ps1` does, in order

1. **Node runtime** (`03-prereqs-node.ps1`) — installs/remediates Node up front (idempotent), so a stale Node doesn't fail the pre-flight.
2. **Pre-flight check** (`00-check-prereqs.ps1`) — aborts on FAIL; prompts on RISK (unless `-AcceptRisks`). Skipped with `-SkipPreflightCheck`.
3. **Phase 1 — prerequisites**: database (mssql Mixed Mode + TCP/IP + `sbaa`, or pgsql/docker) and IIS (`01-prereqs-iis.ps1`). Optional Yopass docker with `-SetupYopassDocker`.
4. **Phase 2 — build** (`04-build.ps1`): `npm ci` + `build:api` + `build:fe`.
5. **Phase 3 — deploy**: `idp-keycloak-setup.ps1` (JDK + Keycloak download + start + realm/client/user), then `05-deploy-api.ps1` and `06-deploy-fe.ps1`.
6. **Smoke test**: hits `https://localhost:3443/api/teams` (expects 401), waits for the `[user]` table, and ensures the admin user has `roleId=2`.
7. **Writes** `install-summary.txt` in the parent of the repository directory.

Re-running on a working install is mostly a no-op — most steps detect existing state and skip.

### Re-run flags

- `-OnlyPhase1` — stop after prerequisites
- `-SkipPhase1` — prerequisites already done
- `-SkipPhase2` — build artifacts already present
- `-SkipPreflightCheck` — skip `00-check-prereqs`
- `-AcceptRisks` — bypass the y/N confirmation on `[RISK]` items (non-interactive)
- `-AutoUpgradeNode` — when `03-prereqs-node.ps1` finds a too-old Node, skip its y/N prompt and remediate via nvm-windows automatically

### Advanced flags

- **Yopass** — Yopass creates one-time, self-destructing links for sharing newly-created Ed-Fi API client secrets, so a secret goes over a link that expires on first view instead of being pasted into chat or email. **Disabled** by default; `-YopassUrl '<url>'` to use an existing Yopass; `-SetupYopassDocker` to stand one up locally (`-YopassPort`, default 8082). The two are mutually exclusive. A locally stood-up Yopass is only reachable by people who can reach `-YopassPort` on this host — behind a firewall, the recipient must be on the same network (or the port must be exposed appropriately). See the [Yopass administrator's guide](https://docs.ed-fi.org/reference/admin-app/system-administrators/yopass-administrators-guide/).
- `-IncludeAudienceMapper` — adds a Keycloak audience mapper; only needed for direct bearer-token API access (Postman/curl/CI). The browser login flow doesn't need it.
- `-EnableDirectAccessGrants` — enables the OAuth password grant on the Keycloak client. **Testing only.**
- `-DisableSslVerification` — turns off TLS-certificate verification on the API's outbound calls to the ODS/API and Admin API. **Local dev only** (a networked box is left MITM-exposed). Use it when your ODS/API presents a self-signed or dev certificate; the secure alternative is `NODE_EXTRA_CA_CERTS`. See [What these scripts don't do](#what-these-scripts-dont-do) for the full note.

---

## End-state URLs

- **Admin App (web application)**: `https://localhost:4443/` (HTTP `http://localhost:4200/` redirects here)
- **API**: `https://localhost:3443/` (HTTP `http://localhost:3333/` redirects here)
- **Keycloak admin console**: `http://localhost:8080/admin/`
- **Keycloak `edfi` realm**: `http://localhost:8080/realms/edfi/`

---

## TLS / HTTPS

Both IIS sites are served over HTTPS by default — API on `3443`, web application on `4443` — and each keeps an HTTP binding (`3333` / `4200`) that returns a 301 redirect to its HTTPS URL.

**Certificate resolution** (in order of precedence):

1. `-CertificateThumbprint` — bind an existing certificate already in `LocalMachine\My`.
2. `-CertificatePfxPath` + `-CertificatePassword` — import and bind a PFX you supply.
3. None supplied → a **self-signed** certificate (CN/SAN `localhost` + the machine name) is generated, bound, and added to `LocalMachine\Root` so local browsers trust it. Opt out of the trust step with `-SkipSelfSignedTrust`.

On `install-all.ps1` the ports are `-HttpsApiPort` (default `3443`) and `-HttpsFePort` (default `4443`); the standalone `05-deploy-api.ps1` and `06-deploy-fe.ps1` each take a single `-HttpsPort` (default `3443` and `4443` respectively). The certificate parameters above are shared across all three.

**Self-signed caveat.** A self-signed certificate is auto-trusted only on this machine, so other machines browsing to it still see a trust warning. Supply a real certificate (thumbprint or PFX) for anything beyond this host. A certificate imported into `LocalMachine\Root` by hand (rather than by these scripts) won't carry the friendly name `uninstall.ps1` matches on, so uninstall won't remove it.

**Security headers.** Each site emits a baseline set of response headers. The API sets `X-Content-Type-Options: nosniff` and `X-Frame-Options` in-app (`main.ts`); IIS adds the rest on both sites — `Strict-Transport-Security` (HSTS), `Referrer-Policy`, and a `Content-Security-Policy` (**enforcing**, not report-only) — and removes `X-Powered-By`. The API's CSP is `default-src 'none'` (it serves only JSON in production); the web application's allows its own origin plus the API origin for `connect-src`.

For the outbound direction — the certificate the API expects from the ODS/API and Admin API it calls — see the upstream TLS verification note under [What these scripts don't do](#what-these-scripts-dont-do).

---

## Next steps after install

Signing in gets you an empty Admin App. To make it useful:

1. **Add an Environment** pointing at your Ed-Fi ODS/API (its Discovery URL) and its Admin API. If either presents a self-signed or dev certificate — common for a local ODS/API — see the upstream TLS verification note under [What these scripts don't do](#what-these-scripts-dont-do).
2. **Create API client credentials** for the applications that will call the ODS/API (optionally shared via Yopass — see [Advanced flags](#advanced-flags)).
3. **Assign claim sets and roles** as your deployment requires.

See the [Admin App User's Guide](https://docs.ed-fi.org/reference/admin-app/) for the full first-run walkthrough.

---

## Known issues / things to know

### Keycloak bootstrap admin is first-run only

`KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` are honored only the **first time** Keycloak starts against an empty data directory. Re-running later with a different `-KeycloakAdminPassword` leaves the existing master admin unchanged and provisioning fails to authenticate. `idp-keycloak-setup.ps1` detects this (`invalid_grant`) and prints recovery options:

- **A:** Re-run with the original admin password.
- **B:** Wipe Keycloak state and bootstrap fresh (loses realm/client/user — recreated automatically):

```powershell
.\uninstall-keycloak.ps1 -Force
.\install-all.ps1 ... -KeycloakAdminPassword (Read-Host -AsSecureString 'new Keycloak admin password') -SkipPhase1
```

`-OidcClientSecret` and `-TestUserPassword` are idempotently updatable on every re-run — both the Keycloak client and the `oidc` database row are reconciled (UPSERT) on each run, so a changed secret takes effect without a manual reset.

### Surviving a reboot (local Keycloak)

Keycloak runs as an ordinary background process, so it does not come back on its own after a reboot — and a stopped Keycloak breaks login in a way that is easy to misread. The Admin App API registers its OIDC strategies **once, when it starts, with no retry**. If the API starts before Keycloak is reachable, every login returns a 404 and the API log (`C:\inetpub\EdFi-AdminApp-API\logs\node-stdout*.log`) shows:

```
ERROR Error registering OIDC provider http://localhost:8080/realms/edfi: AggregateError
ERROR Error: Unknown authentication strategy "oidc-1"
```

`idp-keycloak-setup.ps1` handles both halves by registering a Scheduled Task named **`Ed-Fi Admin App Keycloak`**, on by default. At boot, as `SYSTEM`, it runs a generated script (`C:\keycloak\edfi-keycloak-startup.ps1`) that:

1. Sets `JAVA_HOME` to the JDK resolved at install time, so it works regardless of which `PATH` scope the JDK is on (a `SYSTEM` process sees only machine-scope variables).
2. Starts `kc.bat start-dev`.
3. Waits for `http://localhost:8080/realms/edfi/.well-known/openid-configuration` to answer — a realm-level health gate, not just an open port.
4. Recycles the API app pool (`EdFi-AdminApp-API`) so the API re-registers its OIDC strategy against the now-running Keycloak. Skipped, with a log line, when the app pool is absent.

Progress is logged to `C:\keycloak\keycloak-startup-task.log`; Keycloak's own output goes to `keycloak-startup.log`. Inspect or trigger the task with:

```powershell
schtasks /query /tn 'Ed-Fi Admin App Keycloak'          # elevated, for a SYSTEM task
schtasks /run   /tn 'Ed-Fi Admin App Keycloak'
```

Use `schtasks`, not `Get-ScheduledTask`: the CIM cmdlets enumerate the whole task store before filtering, so they fail with `SCHED_E_INVALIDVALUE` (`0x80041318`) when any unrelated task on the machine has XML the CIM provider cannot parse, which is common on a Windows host.

Opt out with `-SkipKeycloakStartupTask` on `install-all.ps1` (or `-SkipStartupTask` on `idp-keycloak-setup.ps1`). Without the task, after every reboot you must start Keycloak yourself and then recycle the app pool:

```powershell
C:\keycloak\bin\kc.bat start-dev          # leave this window open
Restart-WebAppPool -Name 'EdFi-AdminApp-API'   # elevated; only if the API already started
```

Remove an existing task with `schtasks /delete /tn 'Ed-Fi Admin App Keycloak' /f` (`uninstall-keycloak.ps1` does this for you).

### Entra: "Invalid email from IdP" after sign-in

The Admin App requires an `email` claim in the OIDC userinfo/token. If Entra authenticates the user but the app then errors with `Invalid email from IdP`, the app registration isn't emitting an email claim. In the Entra app registration, add an `email` optional claim (Token configuration) or a claim mapper, then sign in again. See the dedicated Entra setup guide for the full configuration rather than treating this as a one-off fix.

### Auth0: login and M2M troubleshooting

- **"It looks like your login was not successful" in the browser** is generic — the real reason is in the API log (`C:\inetpub\EdFi-AdminApp-API\logs\node-stdout*.log`). `Invalid email from IdP` there means the Auth0 user has no email address (or the requested scope was changed from the `openid email profile` default).
- **Callback/logout mismatch errors surface on the Auth0 side** (an Auth0 error page naming the offending URL), not in the app — Auth0 enforces *Allowed Callback URLs* / *Allowed Logout URLs* strictly. Register exactly what the installer printed, including the resolved `<id>` in `callback/<id>`.
- **`Error registering OIDC provider ...` at API startup + `Unknown authentication strategy "oidc-1"` on login** means OIDC discovery failed — usually an issuer problem (typo, or a trailing slash that reached the `oidc` DB row from a manual/`other`-mode install; `-IdpProvider auth0` strips it).
- **M2M bearer calls return 401** even though a token is issued: decode the token (jwt.io) and check, in order — `iss` equals the deployed `AUTH0_CONFIG_SECRET_VALUE.ISSUER` exactly (including Auth0's trailing slash), `aud` equals `-MachineAudience`, the caller id matches a machine user in the Admin App (`client_id` with the RFC 9068 profile; a legacy-profile token carries only `azp`, which requires an Admin App build with the `azp` fallback, available after v4.0.1), and `scope` includes `login:app`. `quick-start/bootstrap.ps1 -Provider auth0` automates these checks.

### Rate limit can trip during heavy debugging

Default in `production.js` is 10 requests / 60s. Recycle the App Pool to clear state, or bump it for dev:

```powershell
$f = "C:\inetpub\EdFi-AdminApp-API\packages\api\config\production.js"
(Get-Content $f -Raw).Replace("RATE_LIMIT_LIMIT: 10,", "RATE_LIMIT_LIMIT: 1000,") | Set-Content $f -Encoding UTF8
Restart-WebAppPool -Name "EdFi-AdminApp-API"
```

### npm cache is scoped to the App Pool

`05-deploy-api.ps1` sets `NPM_CONFIG_CACHE` on the `EdFi-AdminApp-API` App Pool's environment (not machine-wide) and grants that identity write access, so npm run under the App Pool identity has a writable cache without affecting other npm usage on the machine. Requires IIS 10+.

### Node version requirement

`package.json` declares `engines.node: ">=22.0.0"` (practical floor ~22.12+). `03-prereqs-node.ps1` reads `engines.node` at runtime and tracks whatever the repository declares. If a too-old Node is found, it sets up nvm-windows + installs the latest patch on the required major; if antivirus/endpoint protection consumes the nvm-extracted files, it **falls back to a direct download from nodejs.org**.

### What these scripts don't do

- **Upstream TLS verification (adding an Environment)** — the API verifies the TLS certificate of the ODS/API and Admin API it connects to (`SSL_VERIFICATION` is on by default). If those use a self-signed or dev certificate — common for a local ODS/API — adding an Environment fails with a certificate error (`DEPTH_ZERO_SELF_SIGNED_CERT`) in the API log (`logs\node-stdout*.log`). For a local/dev install, either pass `-DisableSslVerification` to `install-all.ps1` / `05-deploy-api.ps1` (turns verification off — local dev only), or keep it on and make Node trust the upstream certificate via `NODE_EXTRA_CA_CERTS` (the certificate's `.pem` path) or `--use-system-ca` (Node 22.15+, honors the Windows certificate store). Leave verification on (no flag) for production, where upstreams should present trusted certificates.
- **Production hardening** — real certificates, secrets management, log rotation, etc. The optional dockerized Yopass runs HTTP-only behind localhost and is not production-hardened.
- **Keycloak in production mode** — the example identity provider runs in `start-dev` (HTTP, embedded H2 database, hostname strictness off) and is for local development only. For anything beyond local dev, run `kc.bat start` with `--hostname`, a real database (e.g. PostgreSQL), and TLS.
- **Keycloak as a Windows service** — Keycloak ships no Windows service wrapper, so reboot survival is handled with a Scheduled Task (see [Surviving a reboot](#surviving-a-reboot-local-keycloak) above) rather than a real service. The task starts Keycloak at boot; it does not restart Keycloak if it stops afterwards.
- **Secret rotation** — not enabled; the AdminApp has no automation to pick up rotated secrets.

---

## Defaults

| Parameter | Default |
| --- | --- |
| `-DbEngine` | `mssql` |
| `-SourcePath` | Auto-resolved: an existing co-located/sibling checkout, else `install-all.ps1` clones `Ed-Fi-AdminApp` to a sibling (e.g. `C:\Ed-Fi\Ed-Fi-AdminApp`) |
| `-AdminAppRef` | `latest` (newest stable `Ed-Fi-AdminApp` release; pass a tag such as `v4.0.1` to pin) |
| `-DatabaseName` | `sbaa` |
| `-AdminUsername` | `admin@example.com` |
| `-MachineAudience` | `edfiadminapp-api` (the audience expected on machine-to-machine bearer tokens) |
| `-PostgresHost` / `-PostgresPort` / `-PostgresAppUser` | `localhost` / `5432` / `edfiadminapp` *(pgsql only)* |

Per-script parameters (ports, OIDC settings, Keycloak install path, etc.) have defaults documented in each script's `param()` block — run `Get-Help .\<script>.ps1 -Full`.
