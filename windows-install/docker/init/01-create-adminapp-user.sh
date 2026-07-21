#!/bin/bash
set -e

# First-boot init hook: runs via /docker-entrypoint-initdb.d, and ONLY on a fresh
# data directory (see the compose README's "Stop / reset" note). Creates the
# least-privilege Admin App database user.
#
# Least privilege: the Admin App connects as this user and self-migrates (creates
# its own tables in schema public, the pgboss schema for its job queue, and the
# citext extension). Grant CONNECT + CREATE on the database and ownership of the
# public schema so it can DDL within it and create the schema/extension it needs at
# boot, instead of database-wide ALL PRIVILEGES. citext is a trusted extension
# (PostgreSQL 13+), so CREATE on the database suffices -- no superuser needed. The
# user is a non-superuser and cannot touch other databases -- mirrors the MSSQL
# model (db_owner scoped to the app DB, not a server sysadmin).
# Pass user/password/db as psql variables and quote the heredoc (<<-'EOSQL') so
# bash does NOT expand them into the SQL text. psql's :'pw' / :"user" interpolation
# quotes each value safely, so a password containing a single quote no longer aborts
# the entrypoint on first boot (ON_ERROR_STOP=1 would brick the volume) or opens SQL
# injection. -v interpolation is available in every supported psql version.
psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname  "$POSTGRES_DB" \
     -v app_user="$ADMIN_APP_DB_USER" \
     -v app_pw="$ADMIN_APP_DB_PASSWORD" \
     -v app_db="$POSTGRES_DB" <<-'EOSQL'
  CREATE USER :"app_user" WITH PASSWORD :'app_pw';
  GRANT CONNECT, CREATE ON DATABASE :"app_db" TO :"app_user";
  ALTER SCHEMA public OWNER TO :"app_user";
EOSQL
