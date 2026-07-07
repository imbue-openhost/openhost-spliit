#!/bin/bash
# ---------------------------------------------------------------------------
# OpenHost supervisor for Spliit.
#
# Boots (in order):
#   1. PostgreSQL on loopback, data dir on the OpenHost persistent volume.
#   2. Prisma migrations against that DB.
#   3. The Next.js standalone server on 127.0.0.1:3000.
#   4. The Python auth-proxy on 0.0.0.0:8080 (the OpenHost-routed port).
#
# Supervision: Next.js and the proxy run as shell children; Postgres is
# daemonized by pg_ctl (not a shell child), so a background liveness monitor
# stands in for it. `wait -n` watches Next, the proxy, and that monitor — if
# any of the three exits, the whole container exits so OpenHost restarts it
# cleanly.
# ---------------------------------------------------------------------------
set -euo pipefail

log() { echo "[start.sh] $*"; }

# --- Paths -----------------------------------------------------------------
DATA_DIR="${OPENHOST_APP_DATA_DIR:-/data/app_data/spliit}"
PGDATA="${DATA_DIR}/pgdata"
PGSOCKET_DIR="/tmp/pg-spliit"
PG_PORT=5432
PG_USER="spliit"
PG_DB="spliit"
# The bundled DB is loopback-only (never reachable from outside the
# container), so its password is not a meaningful external secret. We
# generate a fresh RANDOM HEX password on every boot and (re)apply it to the
# role below. Hex (0-9a-f) is guaranteed safe to embed in both the SQL role
# definition and the Prisma connection URL without any quoting/escaping —
# avoiding the SQL-syntax / URL-parse breakage (and crash-loops) that a
# password with special characters would cause. Nothing is persisted to disk.
PG_PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

APP_PORT=3000
# The OpenHost-routed port (see openhost.toml). Overridable only to ease
# local testing; production always uses 8080.
PROXY_PORT="${OPENHOST_PROXY_PORT:-8080}"

mkdir -p "${DATA_DIR}" "${PGSOCKET_DIR}"

# postgres refuses to run as root; everything DB-related runs as the alpine
# 'postgres' user via su-exec, and the persistent dirs must be owned by it.
chown -R postgres:postgres "${DATA_DIR}" "${PGSOCKET_DIR}"

# --- 1. PostgreSQL ---------------------------------------------------------
init_db() {
  if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    log "Initializing PostgreSQL cluster at ${PGDATA}"
    su-exec postgres initdb -D "${PGDATA}" \
      --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 >/dev/null
    # Loopback + unix socket only.
    {
      echo "listen_addresses = '127.0.0.1'"
      echo "port = ${PG_PORT}"
      echo "unix_socket_directories = '${PGSOCKET_DIR}'"
    } >> "${PGDATA}/postgresql.conf"
  fi
}

start_db() {
  log "Starting PostgreSQL"
  su-exec postgres pg_ctl -D "${PGDATA}" \
    -o "-c unix_socket_directories='${PGSOCKET_DIR}'" \
    -w -t 60 start
}

bootstrap_role_and_db() {
  # Wait for readiness; fail hard (and let the container restart) if the DB
  # never comes up, rather than proceeding into cryptic psql errors.
  local ready=""
  for i in $(seq 1 30); do
    if su-exec postgres pg_isready -h "${PGSOCKET_DIR}" -p "${PG_PORT}" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ -z "${ready}" ]; then
    log "FATAL: PostgreSQL did not become ready within 30s"
    exit 1
  fi

  # Create role + database idempotently.
  su-exec postgres psql -h "${PGSOCKET_DIR}" -p "${PG_PORT}" -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PG_USER}') THEN
    CREATE ROLE ${PG_USER} LOGIN PASSWORD '${PG_PASSWORD}';
  ELSE
    ALTER ROLE ${PG_USER} WITH PASSWORD '${PG_PASSWORD}';
  END IF;
END
\$\$;
SQL
  if ! su-exec postgres psql -h "${PGSOCKET_DIR}" -p "${PG_PORT}" -d postgres -tAc \
       "SELECT 1 FROM pg_database WHERE datname = '${PG_DB}'" | grep -q 1; then
    su-exec postgres createdb -h "${PGSOCKET_DIR}" -p "${PG_PORT}" -O "${PG_USER}" "${PG_DB}"
  fi
}

init_db
start_db
bootstrap_role_and_db

# Connection string for Prisma + the app. Loopback TCP so both the CLI and
# the standalone server (which use libpq / pg) connect the same way.
export POSTGRES_PRISMA_URL="postgresql://${PG_USER}:${PG_PASSWORD}@127.0.0.1:${PG_PORT}/${PG_DB}?schema=public"
export POSTGRES_URL_NON_POOLING="${POSTGRES_PRISMA_URL}"

# --- 2. Prisma migrations --------------------------------------------------
# Run the Prisma CLI from the dedicated full-node_modules dir (see Dockerfile).
log "Applying Prisma migrations"
( cd /usr/app/migrate && node node_modules/prisma/build/index.js migrate deploy )

# --- 3. Next.js standalone -------------------------------------------------
export PORT="${APP_PORT}"
export HOSTNAME="127.0.0.1"
export NODE_ENV=production
export NEXT_TELEMETRY_DISABLED=1
# The public base URL used for absolute links / metadata.
if [ -n "${OPENHOST_ZONE_DOMAIN:-}" ]; then
  export NEXT_PUBLIC_BASE_URL="https://${OPENHOST_APP_NAME:-spliit}.${OPENHOST_ZONE_DOMAIN}"
fi

log "Starting Next.js on 127.0.0.1:${APP_PORT}"
node server.js &
NEXT_PID=$!

# --- 4. Auth-proxy ---------------------------------------------------------
log "Starting auth-proxy on 0.0.0.0:${PROXY_PORT}"
UPSTREAM_HOST=127.0.0.1 UPSTREAM_PORT="${APP_PORT}" LISTEN_PORT="${PROXY_PORT}" \
  OPENHOST_ZONE_DOMAIN="${OPENHOST_ZONE_DOMAIN:-}" \
  python3 /usr/app/openhost/auth_proxy.py &
PROXY_PID=$!

# --- 5. PostgreSQL liveness monitor ---------------------------------------
# pg_ctl daemonizes the postmaster, so Postgres is NOT a child of this script
# and `wait -n` cannot see it. This background loop polls the DB and exits
# (becoming the child that `wait -n` observes) if Postgres ever stops
# responding — so a dead DB tears the whole container down for OpenHost to
# restart, instead of leaving Next.js serving errors behind a green health
# check.
(
  while su-exec postgres pg_isready -h "${PGSOCKET_DIR}" -p "${PG_PORT}" >/dev/null 2>&1; do
    sleep 10
  done
  echo "[start.sh] PostgreSQL stopped responding"
) &
PG_MONITOR_PID=$!

log "All services started (next=${NEXT_PID} proxy=${PROXY_PID} pg-monitor=${PG_MONITOR_PID})"

# --- Supervision -----------------------------------------------------------
terminate() {
  log "Shutting down"
  kill "${NEXT_PID}" "${PROXY_PID}" "${PG_MONITOR_PID}" 2>/dev/null || true
  su-exec postgres pg_ctl -D "${PGDATA}" -m fast -w stop 2>/dev/null || true
  exit "${1:-0}"
}
trap 'terminate 0' TERM INT

# Exit as soon as any supervised process (Next, the proxy, or the Postgres
# monitor) dies. `|| true` keeps `set -e` from short-circuiting past the
# teardown when the exiting child had a non-zero status.
wait -n "${NEXT_PID}" "${PROXY_PID}" "${PG_MONITOR_PID}" || true
log "A supervised process exited; tearing down"
terminate 1
