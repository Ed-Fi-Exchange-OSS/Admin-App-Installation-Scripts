# Global Admin Quick Start

Scripts that stand up a starter configuration in the Ed-Fi Admin App (v4+) so a
global administrator can sign in and go straight to managing ODS instances:
a machine (service-account) client in the identity provider, a machine user, a
team, an environment, a default tenant, ODS instances, and the team ownerships
that tie them together.

Full walkthrough (prerequisites, provider setup for Keycloak / Entra ID,
troubleshooting): [Global Admin Quick Start on docs.ed-fi.org](https://docs.ed-fi.org/reference/admin-app/user-guide/global-admin-quick-start).

## Scripts

| Script | Purpose |
| --- | --- |
| `run.ps1` | One-step entry point: loads `.env` and runs `bootstrap.ps1`, `quick-start.ps1`, and `copy-claimsets.ps1`. |
| `bootstrap.ps1` | Provisions the IdP machine client (Keycloak) or, for Entra ID, skips provider calls; seeds the matching machine user row in the Admin App database. Idempotent. |
| `quick-start.ps1` | Provisions the team, environment, tenant, ODS instances, and ownerships through the Admin App REST API, and adds the machine user — plus the human bootstrap admin when `ADMIN_USERNAME` is set — to the team. Idempotent. |
| `copy-claimsets.ps1` | Copies every built-in claimset under an `AA` prefix in the ODS/API's EdFi_Security database so they can be assigned to applications in the Admin App (or only the ones in `CLAIMSET_NAMES`). Idempotent. |
| `cleanup.ps1` | Tears down everything the quick start created (environment, team, machine user). The human bootstrap user is left in place. |
| `load-dotenv.ps1` | Shared `.env` parser dot-sourced by `run.ps1` and `cleanup.ps1`. |
| `compat.ps1` | Shared Windows PowerShell 5.1 / PowerShell 7+ compatibility helpers dot-sourced by the other scripts. |

## Usage

Requires Windows PowerShell 5.1 or PowerShell 7+. The Ed-Fi ODS/API, ODS Admin
API, and Admin App (with
its identity provider) must already be installed and reachable. The Admin API
must also have client registration enabled
(`Authentication:AllowRegistration=true` in its `appsettings.json`) while the
quick start runs: when the environment is created, the Admin App registers its
own client credentials at the Admin API's `POST /connect/register` endpoint.
If you followed the Admin API first-time setup and disabled registration after
creating your first client, re-enable it for the quick start run (it can be
turned off again afterwards) — with registration disabled, environment
creation fails (a 403 on `Create environment failed`, or a failed sync with no
clear error for Admin API v2 environments).

Before running the scripts, verify registration works end to end by manually
registering a first client against the Admin API (the secret must be 32–128
characters and contain an uppercase letter, a lowercase letter, a digit, and a
special character):

```powershell
curl.exe -k -X POST https://localhost/AdminApi/connect/register `
  -d "ClientId=bootstrap-client" `
  -d "ClientSecret=<32-128 chars, upper+lower+digit+special>" `
  -d "DisplayName=Bootstrap"
```

A `200` response (`Registered client bootstrap-client successfully.`) confirms
the Admin API is ready. A `403` means registration is disabled (see above); a
`500` means the Admin API itself failed server-side — check its log file and
confirm its database tables were installed (the `adminapi` schema in
`EdFi_Admin`).

The ODS
instances listed in `ODSS_JSON` must already exist in the target ODS/API's
`EdFi_Admin.dbo.OdsInstances` table — the ids **and names** must match those
rows exactly. How to check the table (and create missing rows) is covered in
the
[Global Admin Quick Start on docs.ed-fi.org](https://docs.ed-fi.org/reference/admin-app/user-guide/global-admin-quick-start).

```powershell
git clone https://github.com/Ed-Fi-Exchange-OSS/Admin-App-Installation-Scripts.git
cd Admin-App-Installation-Scripts/quick-start
Copy-Item .env.example .env   # then edit .env to match your deployment
./run.ps1
```

Every `.env` variable is documented in [.env.example](.env.example). Passwords
(`KEYCLOAK_ADMIN_PASSWORD`, `APP_DB_PASSWORD`, `POSTGRES_APP_PASSWORD`,
`SECURITY_DB_PASSWORD`) may be left out of `.env` — `run.ps1` prompts for the
ones it needs, with the input masked; set them in the file only for unattended
runs. All the scripts are idempotent, so re-running `run.ps1` is safe; if the machine client
and machine user are already in place, re-run only the provisioning half with
`./run.ps1 -SkipBootstrap`.

Individual scripts can also be run directly with parameters — see each
script's comment-based help (`Get-Help ./bootstrap.ps1 -Full`).

## Claim set copies

The Admin App hides built-in (Ed-Fi preset) claimsets from the application
claimset dropdown, so `run.ps1` finishes by running `copy-claimsets.ps1`, which
recreates every built-in claimset under an `AA` prefix (e.g. `SIS Vendor` →
`AA SIS Vendor`) directly in the **EdFi_Security** database — a database on
the ODS/API side, not the Admin App's. Internal-use claimsets (e.g.
`Bootstrap Descriptors and EdOrgs`) are excluded; set `CLAIMSET_NAMES` to copy
a specific list instead. Because `EdFi_Security` is a different database from
the Admin App's, it has its own connection settings — it can even run on a
different engine (`SECURITY_DB_ENGINE`, defaulting to `DB_ENGINE`). For SQL
Server the connection uses its own `SECURITY_DB_USERNAME` /
`SECURITY_DB_PASSWORD` login (or `SECURITY_USE_INTEGRATED_SECURITY=true` for
Windows authentication); for PostgreSQL it uses the `POSTGRES_SECURITY_*`
values, each falling back to the app-side `POSTGRES_*` value when empty.
Server, database name, and container come from the other `SECURITY_*`
variables. Skip the step with `./run.ps1 -SkipClaimsets` or
`COPY_CLAIMSETS=false`.

The copies are snapshots: an ODS/API upgrade that changes a built-in claimset
does not propagate to them. `cleanup.ps1` removes them (pass `-SkipClaimsets`
to keep them); to remove a single copy by hand instead — only if no
application still uses it — delete its rows child-tables-first:

```sql
DELETE ov
FROM dbo.ClaimSetResourceClaimActionAuthorizationStrategyOverrides ov
    INNER JOIN dbo.ClaimSetResourceClaimActions a
        ON a.ClaimSetResourceClaimActionId = ov.ClaimSetResourceClaimActionId
    INNER JOIN dbo.ClaimSets cs ON cs.ClaimSetId = a.ClaimSetId
WHERE cs.ClaimSetName = 'AA SIS Vendor';

DELETE a
FROM dbo.ClaimSetResourceClaimActions a
    INNER JOIN dbo.ClaimSets cs ON cs.ClaimSetId = a.ClaimSetId
WHERE cs.ClaimSetName = 'AA SIS Vendor';

DELETE FROM dbo.ClaimSets WHERE ClaimSetName = 'AA SIS Vendor';
```

(For PostgreSQL use the same three deletes with lowercase identifiers and
`DELETE FROM ... USING` joins.)

## Clean up

```powershell
./cleanup.ps1          # prompts for confirmation
./cleanup.ps1 -Force   # no prompt (automation)
```

Reads the same `.env` for the database connection and the names to delete;
any parameter passed explicitly overrides the `.env` value, and passwords
missing from both are prompted for (masked), like `run.ps1`. Supports SQL
Server (`DB_ENGINE=mssql`) and PostgreSQL (`DB_ENGINE=pgsql`, optionally
`USE_POSTGRES_DOCKER=true`). Also removes the claimset copies from
EdFi_Security (via the `SECURITY_*` values) — pass `-SkipClaimsets` to leave
them in place, e.g. when an application still uses one.
`USE_POSTGRES_DOCKER=true`).

Cleanup is scoped to the Admin App database. The Keycloak artifacts
`bootstrap.ps1` created (the machine client, the `login:app` client scope, and
its mappers) are deliberately left in the realm so re-runs reuse them; remove
them manually in the Keycloak admin console if they are no longer wanted.
