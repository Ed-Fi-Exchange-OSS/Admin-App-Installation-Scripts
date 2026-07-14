# AdminApp v4.x PostgreSQL — Docker Compose

Standalone PostgreSQL container provisioned for an Ed-Fi **Admin App v4.x** (NestJS/TypeORM) installation, matching the [Database Configuration section](https://docs.ed-fi.org/reference/admin-app/system-administrators/installing/#database-configuration) of the official docs.

On first boot it creates:

- An empty database (default name `sbaa`).
- A dedicated, least-privilege application user (default name `edfiadminapp`): a non-superuser granted `CONNECT` on the database and made owner of the `public` schema, so it can self-migrate its own tables without database-wide privileges.
- A self-signed SSL certificate (CN=`localhost`, SAN includes `localhost`, `127.0.0.1`, `edfiadminapp-postgres`) used to serve TLS connections.

AdminApp's own TypeORM migrations create the schema the first time you start the AdminApp API with `DB_RUN_MIGRATIONS=true`. No SQL preload happens here.

## Prerequisites

- **Docker Desktop** — the only officially supported engine. Other OCI / Compose-v2 engines (e.g. Podman via `podman compose`) may work but are unsupported.
- Host port `5432` available (override `POSTGRES_PORT_EXPOSED` if not).

## Setup

1. Copy the env template and set strong passwords:

   ```powershell
   Copy-Item .env.example .env
   notepad .env
   ```

   At minimum, change `POSTGRES_PASSWORD` and `ADMIN_APP_DB_PASSWORD`.

2. Start the containers:

   ```powershell
   docker compose up -d
   ```

   The `cert-init` service runs first and generates a self-signed cert into the `vol-edfiadminapp-certs` volume; the `postgres` service then starts with SSL enabled.

3. Watch first-boot init logs to confirm the user/grant statements ran:

   ```powershell
   docker compose logs -f postgres
   ```

   You should see lines for `CREATE ROLE` and `GRANT` with no errors, and `LOG:  database system is ready to accept connections`.

## Verification

```powershell
# Postgres is accepting connections to the sbaa database
docker exec edfiadminapp-postgres pg_isready -U postgres -d sbaa

# The dedicated AdminApp user can log in (proves grants worked)
docker exec -it edfiadminapp-postgres psql -U edfiadminapp -d sbaa -c "SELECT current_user, current_database();"

# Confirm SSL is on
docker exec edfiadminapp-postgres psql -U postgres -d sbaa -c "SHOW ssl;"
```

From the host you can also connect with any PG client to `localhost:5432` using the `edfiadminapp` / `sbaa` credentials. With SSL on, your client may need `sslmode=require` (or stricter).

## Network exposure

By default the DB port binds to `127.0.0.1` (loopback only), so the database is reachable only from this host. To expose it for remote access, set `POSTGRES_BIND_HOST=0.0.0.0` in `.env` — only behind a firewall and over TLS (this stack already serves SSL; use `sslmode=verify-full` on remote clients).

## Connecting AdminApp v4.x to this database

| Variable             | Value                                            |
| -------------------- | ------------------------------------------------ |
| `DB_ENGINE`          | `pgsql`                                          |
| `DB_HOST`            | `localhost` (or `host.docker.internal` from another container) |
| `DB_PORT`            | `5432`                                           |
| `DB_DATABASE`        | `sbaa`                                           |
| `DB_USERNAME`        | `edfiadminapp`                                   |
| `DB_PASSWORD`        | value of `ADMIN_APP_DB_PASSWORD` from `.env`     |
| `DB_RUN_MIGRATIONS`  | `true` (lets TypeORM create the schema on first start) |

### `DB_SSL` — pick one

AdminApp builds its connection string as `?sslmode=require` when `DB_SSL=true`. The `pg-connection-string` library treats `require` as `verify-full` — i.e. Node verifies the server's certificate against a trusted CA. With our self-signed cert, that fails unless you tell Node to trust the cert.

**Option 1 (recommended for local) — Disable SSL on the client.** SSL over `localhost` loopback adds no real security; this is the simplest setup.

```js
// production.js
DB_SSL: false,
```

**Option 2 — Keep `DB_SSL: true` and trust the self-signed cert.**

1. Export the cert from the container to a host path:

   ```powershell
   docker cp edfiadminapp-postgres:/etc/postgresql/certs/server.crt C:\inetpub\EdFi-AdminApp-API\ssl\server.crt
   ```

2. Tell Node to trust it via `NODE_EXTRA_CA_CERTS`. In the API's `web.config`, add it inside the `<httpPlatform>` element's `<environmentVariables>`:

   ```xml
   <httpPlatform processPath="C:\Program Files\nodejs\node.exe" arguments="main.js" ...other attrs...>
     <environmentVariables>
       <environmentVariable name="NODE_ENV" value="production" />
       <environmentVariable name="NODE_EXTRA_CA_CERTS" value="C:\inetpub\EdFi-AdminApp-API\ssl\server.crt" />
     </environmentVariables>
   </httpPlatform>
   ```

   `05-deploy-api.ps1` regenerates `web.config` on every deploy, so a hand-edit here is lost on the next run. To make it survive redeploys, set `NODE_EXTRA_CA_CERTS` at the IIS App Pool level instead (Application Pool → Advanced Settings → Environment Variables) and recycle the pool.

3. Recycle the AdminApp App Pool (or `iisreset`).

## Stop / reset

```powershell
docker compose down            # stop, keep data and cert
docker compose down -v         # stop AND delete both volumes (fresh init + new cert)
```

Because init scripts only run on a **fresh** data directory, changes to `init/*.sh` only take effect after `docker compose down -v` (or by removing the `vol-edfiadminapp-db` volume manually). Likewise the cert is regenerated only after the `vol-edfiadminapp-certs` volume is removed.

## Yopass (separate compose file)

`docker-compose.yopass.yml` in this folder is an independent stack (compose project `edfiadminapp-yopass`) that runs [Yopass](https://github.com/jhaals/yopass) + memcached for one-time sharing of newly-created Ed-Fi API client credentials. It is unrelated to the database above and works with either DB engine.

```powershell
# Stand it up on host port 8082 (mapped to the container's port 80, pinned to
# jhaals/yopass:12.5.0 to match the AdminApp project's own compose):
$env:YOPASS_PORT = "8082"; docker compose -f docker-compose.yopass.yml up -d
# or, easier, let the installer do it:
.\..\install-all.ps1 ... -SetupYopassDocker -YopassPort 8082
# tear down (also removes the secret store):
docker compose -f docker-compose.yopass.yml down -v
```

Configure the AdminApp with `USE_YOPASS=true` and `YOPASS_URL=http://localhost:8082` (the installer does this for you). HTTP-only and meant to sit behind localhost / an internal network — front it with TLS for real use.

## Notes and scope

- **Self-signed SSL.** Good enough for local dev, not for production. For production, replace `vol-edfiadminapp-certs` with a bind mount to org-issued CA-signed cert/key, or pre-populate the volume.
- **No pgAdmin.** This compose is Postgres only. For a UI, use your own pgAdmin/psql client, or the pgAdmin service bundled in the full stack under this repo's `compose/` directory (see below).
- **No AdminApp services.** This compose is the database only. The full AdminApp + Keycloak + Yopass stack lives in this repo's `compose/` directory.
- **AdminApp v4.x only.** The legacy .NET AdminApp uses `EdFi_Admin` + `EdFi_Security` and is not provisioned here — see the separate `Ed-Fi-ODS-Implementation` repository (`Docker/ods-api-db-admin/`) for that.
