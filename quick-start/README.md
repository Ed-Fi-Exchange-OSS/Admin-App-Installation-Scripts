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
| `run.ps1` | One-step entry point: loads `.env` and runs `bootstrap.ps1` then `quick-start.ps1`. |
| `bootstrap.ps1` | Provisions the IdP machine client (Keycloak) or, for Entra ID, skips provider calls; seeds the matching machine user row in the Admin App database. Idempotent. |
| `quick-start.ps1` | Provisions the team, environment, tenant, ODS instances, and ownerships through the Admin App REST API. Idempotent. |
| `cleanup.ps1` | Tears down everything the quick start created (environment, team, machine user). The human bootstrap user is left in place. |
| `load-dotenv.ps1` | Shared `.env` parser dot-sourced by `run.ps1` and `cleanup.ps1`. |

## Usage

Requires PowerShell 7+. The Ed-Fi ODS/API, ODS Admin API, and Admin App (with
its identity provider) must already be installed and reachable.

```powershell
git clone https://github.com/Ed-Fi-Exchange-OSS/Admin-App-Installation-Scripts.git
cd Admin-App-Installation-Scripts/quick-start
Copy-Item .env.example .env   # then edit .env to match your deployment
./run.ps1
```

Every `.env` variable is documented in [.env.example](.env.example). Both
scripts are idempotent, so re-running `run.ps1` is safe; if the machine client
and machine user are already in place, re-run only the provisioning half with
`./run.ps1 -SkipBootstrap`.

Individual scripts can also be run directly with parameters — see each
script's comment-based help (`Get-Help ./bootstrap.ps1 -Full`).

## Clean up

```powershell
./cleanup.ps1          # prompts for confirmation
./cleanup.ps1 -Force   # no prompt (automation)
```

Reads the same `.env` for the database connection and the names to delete;
any parameter passed explicitly overrides the `.env` value. Supports SQL
Server (`DB_ENGINE=mssql`) and PostgreSQL (`DB_ENGINE=pgsql`, optionally
`USE_POSTGRES_DOCKER=true`).
