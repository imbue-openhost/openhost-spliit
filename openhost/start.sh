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
# All long-lived children are supervised with `wait -n`; if any exits the
# whole container exits so OpenHost restarts it cleanly.
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
# Bundled DB is loopback-only, so the password never leaves the container.
# It is derived from the OpenHost app token if present, else a fixed local
# value (the DB is not reachable from outside the container in any case).
PG_PASSWORD="${OPENHOST_APP_TOKEN:-spliit_local_only}"

APP_PORT=3000
PROXY_PORT=8080

mkdir -p "${DATA_DIR}" "${PGSOCKET_DIR}"

# postgres refuses to run as root; use the alpine 'postgres' user.
PG_UID="$(id -u postgres)"
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
  # Wait for readiness.
  for i in $(seq 1 30); do
    if su-exec postgres pg_isready -h "${PGSOCKET_DIR}" -p "${PG_PORT}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

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

log "All services started (next=${NEXT_PID} proxy=${PROXY_PID})"

# --- Supervision -----------------------------------------------------------
terminate() {
  log "Shutting down"
  kill "${NEXT_PID}" "${PROXY_PID}" 2>/dev/null || true
  su-exec postgres pg_ctl -D "${PGDATA}" -m fast -w stop 2>/dev/null || true
  exit 0
}
trap terminate TERM INT

# Exit as soon as any critical child dies.
wait -n "${NEXT_PID}" "${PROXY_PID}"
log "A supervised process exited; tearing down"
terminate
