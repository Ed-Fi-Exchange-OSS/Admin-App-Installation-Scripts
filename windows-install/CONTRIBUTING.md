# Contributing — Windows Install scripts

Guidance for working on the `windows-install/` method: a PowerShell suite that performs an
end-to-end **Windows / IIS** installation of the Ed-Fi Admin App, with either **SQL Server** or
a **Dockerized PostgreSQL** backing store, and **Keycloak**, **Entra ID**, or **Google
Workspace** as the OIDC identity provider.

For organization-wide contribution norms, see the repository `CONTRIBUTORS.md` and the Ed-Fi
contributor guidelines.

---

## Prerequisites

- **Windows** with the **IIS** role, and an **elevated (Administrator) PowerShell** — IIS, SQL,
  uninstall, and scheduled-task steps require elevation. `docker compose` must also run elevated
  because the generated `docker/.env` is access control list-restricted to Administrators.
- **PowerShell 5.1 or later.**
- **Docker Desktop** (Linux containers) — only for the PostgreSQL and Yopass paths.
- **Node.js** — installed and managed by `03-prereqs-node.ps1`.
- A local checkout of the **Ed-Fi Admin App source at the supported release tag**. The scripts
  build and deploy from `-SourcePath`, so the source you point at determines the version
  actually installed. Target the release named in the current README; re-validate when a new
  Admin App version ships.

---

## Layout

```
windows-install/
├─ install-all.ps1        # master installer (3 phases) — main entry point
├─ 00-check-prereqs.ps1   # preflight: ports, OS, tooling
├─ 01-prereqs-iis.ps1     # IIS + URL Rewrite + httpPlatform handler  (-HttpHandler here)
├─ 02-prereqs-sql.ps1     # SQL Server mixed mode + TCP + least-privilege app login (Windows Authentication)
├─ 03-prereqs-node.ps1    # Node.js install / npm cache
├─ 04-build.ps1           # npm ci + build:api (webpack) + build:fe (vite)
├─ 05-deploy-api.ps1      # deploy API site, NODE_CONFIG, TLS, OIDC row, encryption key
├─ 06-deploy-fe.ps1       # deploy web application site + SPA fallback
├─ idp-keycloak-setup.ps1 # provision local Keycloak realm/client/user
├─ idp-keycloak-start.ps1 # start Keycloak (optional reboot-survival scheduled task)
├─ uninstall.ps1          # tear down sites, pools, database, login, certificates, npm cache
├─ uninstall-keycloak.ps1 # tear down Keycloak
├─ setup-vm-prereqs.ps1   # fresh virtual machine bootstrap
├─ yopass-docker.ps1      # optional one-time-credential-link stack
├─ README.md              # user install guide
└─ docker/                # PostgreSQL + optional Yopass compose stack; init/ creates the PostgreSQL role
```

Scripts refer to their own location as `<repo>\windows-install\` in docstrings; functional
paths resolve from `$PSScriptRoot`. Keep the folder name so the documentation stays accurate.

---

## Running an install (for testing a change)

Capture every secret as a `SecureString` — never pass a plaintext literal:
```powershell
$secret = Read-Host 'client secret' -AsSecureString
```
SQL logins must satisfy CHECK_POLICY (≥8 characters, ≥3 of 4 categories). Always pass
`-SourcePath` pointing at the supported Admin App source checkout.

**SQL Server + Keycloak:**
```powershell
$p = @{
  SourcePath = '<path-to-admin-app-source>'
  DbEngine = 'mssql'; AppDbPassword = $appdb
  IdpProvider = 'keycloak'; OidcClientSecret = $oidc
  KeycloakAdminPassword = $kcadmin; TestUserPassword = $kcuser
  AcceptRisks = $true
}
.\install-all.ps1 @p
```

**PostgreSQL + Docker + Keycloak:**
```powershell
$pg = @{
  SourcePath = '<path-to-admin-app-source>'
  DbEngine = 'pgsql'; UsePostgresDocker = $true
  PostgresSuperuserPassword = $pgsuper; PostgresAppPassword = $pgapp
  IdpProvider = 'keycloak'; OidcClientSecret = $oidc
  KeycloakAdminPassword = $kcadmin; TestUserPassword = $kcuser
  AcceptRisks = $true
}
.\install-all.ps1 @pg
```

**External identity provider (Entra ID / Google):** set `-IdpProvider microsoft|google`,
`-OidcClientId`, `-OidcClientSecret`, and `-AdminUsername <idp-user-email>`. Entra also requires
`-OidcIssuer 'https://login.microsoftonline.com/<tenant-id>/v2.0'`; Google defaults the issuer
to `accounts.google.com`. Register the redirect URI the installer prints:
`https://localhost:3443/api/auth/callback/<id>`.

### Selected parameters (`install-all.ps1`)

| Parameter | Notes |
|---|---|
| `-SourcePath` | Admin App source to build/deploy. Point at the supported release checkout. |
| `-DbEngine mssql\|pgsql` | Default `mssql`. |
| `-AppDbPassword` | MSSQL (SecureString). App login is a non-sysadmin `db_owner` on `sbaa`. Server setup uses Windows authentication (no `sa`; run as a SQL sysadmin). |
| `-UsePostgresDocker` + `-PostgresSuperuserPassword` / `-PostgresAppPassword` | PostgreSQL via Docker. App user is a non-superuser owning `public` with CONNECT + CREATE. |
| `-IdpProvider keycloak\|microsoft\|google\|other` | **Mandatory.** `microsoft` requires `-OidcIssuer`. |
| `-OidcClientSecret` | **Mandatory** (SecureString). |
| `-AdminUsername` | Seeded admin; must equal the identity provider user's email claim. |
| `-SkipPhase1` / `-SkipPhase2` / `-OnlyPhase1` | Phase control. |
| `-DisableSslVerification` | Disable upstream TLS verification (local self-signed upstreams). On by default. |
| `-HttpsApiPort` / `-HttpsFePort` | HTTPS ports (default 3443 / 4443). |
| `-CertificateThumbprint` / `-CertificatePfxPath` / `-CertificatePassword` | Supply a real certificate instead of self-signed. |
| `-SkipKeycloakStartupTask` | Opt out of the Keycloak reboot-survival scheduled task. Registered by default. |
| `-AcceptRisks` | Proceed past 00-check port RISK warnings. |

`-HttpHandler` (`HttpBridge` default, or `HttpPlatformHandler`) lives on `01-prereqs-iis.ps1`
and is not forwarded by install-all. To switch handlers, run `install-all -OnlyPhase1`, then
`01-prereqs-iis.ps1 -HttpHandler <value>`, then `install-all -SkipPhase1`. Because the handler
MSI is left in place on uninstall, switching may require removing the current handler MSI first;
`01` warns when the installed handler differs from the one requested.

### Ports & smoke tests

| Port | Purpose |
|---|---|
| 3333 / **3443** | API HTTP → redirects to HTTPS |
| 4200 / **4443** | Web application HTTP → redirects to HTTPS |
| 5432 | PostgreSQL (loopback-bound by default) |
| 8080 | Keycloak (local dev) |

Use `curl.exe` for HTTPS smoke checks — `Invoke-WebRequest` on PS 5.1 cannot handshake the
self-signed binding:
```powershell
curl.exe -sk -o NUL -w "%{http_code}" https://localhost:3443/api/teams   # 401 = API up
curl.exe -sk -o NUL -w "%{http_code}" https://localhost:4443/            # 200 = web application up
```

---

## Coding conventions

- **PowerShell:** approved verbs, `[CmdletBinding()]`, `Set-StrictMode -Version Latest`,
  `$ErrorActionPreference = 'Stop'`, `Write-Verbose` over `Write-Host` for diagnostics, named
  parameters. No commented-out code, no `TODO` comments.
- **SQL:** no `SELECT *` in scripts, parameterized queries, explicit constraint names. Never
  edit an already-applied migration.
- **Docker Compose:** no `:latest` tags, secrets in `.env` (not committed), named volumes,
  explicit healthchecks.
- Match the style of the surrounding script (naming, comment density, structure).

---

## Invariants to preserve

Changes must not weaken these properties (each is exercised by the E2E suite):

- **Least-privilege database access** — the app connects as a non-`sa` / non-superuser login
  (SQL Server: `db_owner` of `sbaa`, `sysadmin = 0`; PostgreSQL: non-superuser owning `public`
  with `CONNECT` + `CREATE`, never a database-wide `GRANT ALL`). PostgreSQL needs `CREATE` on the
  database to build the `citext` extension and the `pgboss` schema at first boot.
- **Per-install data-encryption key** — generated per install, recorded only in the
  Administrators-only summary, reused (not rotated) on idempotent re-runs.
- **TLS always-on** — HTTPS bindings on both sites, HTTP ports redirect, self-signed certificate
  auto-trusted when none is supplied, enforcing (not Report-Only) CSP.
- **Upstream TLS verification on by default** (`-DisableSslVerification` is an explicit opt-out).
- **PostgreSQL bound to loopback** by default; remote exposure is opt-in.
- **No plaintext user secrets** in the install summary, console, or history; `docker/.env` is
  generated at install time, access control list-restricted, and git-ignored.

---

## Environment notes

- **`docker/.env` is generated by `install-all`** from the supplied passwords and is
  git-ignored. Never commit it; only `docker/.env.example` is versioned. Standalone
  `docker compose` (without `install-all`) needs a `.env` — copy `.env.example` and fill it.
- **Fresh vs existing volume:** Docker init scripts run only on a fresh volume. Use
  `docker compose down -v` to re-run `init/`; plain `docker compose down` preserves the volume.
- **Web application build memory:** free RAM and run `npx nx reset` before rebuilding (nx caches `fe:build`
  and ignores `.env`); prefer `-SkipInstall` on iterative runs.
- **PowerShell line continuation:** a comment after a backtick breaks the parse — prefer
  splatting (`@{ }`) for multi-argument calls.
- **psql from PowerShell:** pipe SQL via stdin to avoid native-argument quote mangling, e.g.
  `'SELECT ...;' | docker exec -i <container> psql -U postgres -d sbaa`.

---

## Testing

These are deployment/orchestration scripts with no unit-testable surface. Before opening a PR,
validate the affected paths end to end on a clean box:

- Install completes and the app boots; API returns 401 and the web application returns 200 with SPA fallback.
- Exercise both database engines when a change touches the database path, and both `-HttpHandler`
  values when a change touches hosting.
- For PostgreSQL, test both a fresh volume and an existing-volume re-run.
- Confirm the security invariants above still hold.
- `uninstall.ps1` returns a clean box (zero failures).

---

## Submitting a pull request

- Use a focused branch and put the ticket ID in every commit
  (`EDFI-1234 Short imperative summary`).
- **Sign your commits** (GPG). On Windows, commit from a PowerShell session; if the first
  signature of a session fails, re-prime the GPG agent once and retry.
- Keep the PR focused on one change; isolate whitespace-only edits from functional ones.
- In the PR description, state what changed and how you validated it (the engines, identity providers, and
  handlers you exercised).
