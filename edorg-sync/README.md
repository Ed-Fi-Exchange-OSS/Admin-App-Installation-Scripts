# Education Organization Sync

Scripts for the one-time bulk import of pre-existing education organizations
from an `EdFi_ODS` database into the Ed-Fi Admin App (v4) database, so they
show up when creating a new Application: an export script that writes the ed
orgs (with their type and hierarchy) to a CSV, and an import script that loads
the CSV into the Admin App's `edorg` table under an existing tenant/ODS
registration.

This is a temporary bridge for deployments whose ODS already contains
education organizations: Admin App v4.1 is slated to sync ed orgs natively,
after which these scripts are unnecessary.

Full walkthrough (prerequisites, verification, troubleshooting):
[Education Organization Sync on docs.ed-fi.org](https://docs.ed-fi.org/reference/admin-app/user-guide/edorg-synchronization).

## Scripts

| Script | Purpose |
| --- | --- |
| `run.ps1` | One-step entry point: loads `.env` and runs `export-edorgs.ps1` then `import-edorgs.ps1`. |
| `export-edorgs.ps1` | Exports every education organization in an `EdFi_ODS` database to a CSV — id, name, short name, type (`discriminator`), and parent — deriving the parent per type (School → LEA, LEA → parent LEA / ESC / SEA, ESC → SEA, department → parent). Read-only. |
| `import-edorgs.ps1` | Loads the CSV into the Admin App database: inserts the missing `edorg` rows under the configured tenant/ODS, wires the parent/child hierarchy, and fills the closure rows the Admin App's tree queries expect. Skips types the Admin App does not support, never touches existing rows, and runs in a single transaction. Idempotent. |
| `cleanup-edorgs.ps1` | Deletes exactly the imported ids (from the same CSV) out of the Admin App database; children not in the CSV are kept and become roots. Idempotent. |
| `load-dotenv.ps1` | Shared `.env` parser dot-sourced by `run.ps1` and `cleanup-edorgs.ps1`. |

## Usage

Requires PowerShell 7+ (plus `sqlcmd` for SQL Server and/or `psql` for
PostgreSQL, matching the engines in play). The Admin App must already be
installed, and the target tenant and ODS instance must already be registered
in it through the Admin App UI. The source ODS and the Admin App database are
configured independently and may use different servers and engines.

```powershell
git clone https://github.com/Ed-Fi-Exchange-OSS/Admin-App-Installation-Scripts.git
cd Admin-App-Installation-Scripts/edorg-sync
Copy-Item .env.example .env   # then edit .env to match your deployment
./run.ps1
```

Every `.env` variable is documented in [.env.example](.env.example). Both
scripts are idempotent, so re-running `run.ps1` is safe. To review (or trim)
the CSV before anything is written to the Admin App, split the run:

```powershell
./run.ps1 -SkipImport    # export only: writes edorgs.csv
# review/edit edorgs.csv ...
./run.ps1 -SkipExport    # import only: loads the reviewed CSV
```

Individual scripts can also be run directly with parameters — see each
script's comment-based help (`Get-Help ./export-edorgs.ps1 -Full`).

## What the import writes

One `edorg` row per CSV row — carrying the education organization id, name,
short name, and type (`discriminator`, e.g. `edfi.School`,
`edfi.LocalEducationAgency`) — stamped with the tenant, environment, and ODS
registration it was attached to, plus the parent link and the
ancestor/self closure rows that back the Admin App's hierarchy views. Ed org
types the Admin App does not model (e.g. `edfi.CommunityOrganization`) are
reported and skipped. Rows that already exist in the scope are left untouched,
so the import never clobbers anything the Admin App wrote itself.

On SQL Server the Admin App schema stores the education organization id as a
32-bit integer: ids above 2,147,483,647 stop the import with a list of the
offending rows (PostgreSQL has no such limit).

Global admins see the imported ed orgs immediately; non-admin teams see them
once they are granted ownership of the tenant, environment, ODS, or the
individual ed orgs.

## Clean up

```powershell
./cleanup-edorgs.ps1
```

Reads the same `.env` for the connection and scope, and deletes exactly the
`educationOrganizationId` values listed in `CSV_PATH` from that scope — so
keep the CSV you imported with. Any parameter passed explicitly overrides the
`.env` value. Re-import at any time with `./run.ps1 -SkipExport`.
