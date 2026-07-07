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
# Where the bundled DB's generated password is stored. The DB is loopback-only
# (listen_addresses=127.0.0.1, no port published), so this password is never
# reachable from outside the container. We generate a random one on first boot
# and persist it in the DB data dir alongside the cluster it protects — it is
# only meaningful together with that on-disk cluster.
PG_PASSWORD_FILE="${PGDATA}/.spliit_db_password"

APP_PORT=3000
PROXY_PORT=8080

mkdir -p "${DATA_DIR}" "${PGSOCKET_DIR}"

# postgres refuses to run as root; use the alpine 'postgres' user.
chown -R postgres:postgres "${DATA_DIR}" "${PGSOCKET_DIR}"

# --- DB password (random, generated once, persisted with the cluster) ------
provision_db_password() {
  if [ -s "${PG_PASSWORD_FILE}" ]; then
    PG_PASSWORD="$(cat "${PG_PASSWORD_FILE}")"
    return
  fi
  # 32 hex chars: url-safe and quote-safe, so no SQL/URL escaping surprises.
  PG_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  ( umask 077; printf '%s' "${PG_PASSWORD}" > "${PG_PASSWORD_FILE}" )
  chown postgres:postgres "${PG_PASSWORD_FILE}"
  chmod 0600 "${PG_PASSWORD_FILE}"
}

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
  # Run the postgres server as a direct background child (not via pg_ctl's
  # detached daemon) so it is a real shell child that `wait -n` supervises:
  # if the DB dies, the whole container exits and OpenHost restarts it.
  log "Starting PostgreSQL"
  su-exec postgres postgres -D "${PGDATA}" \
    -c unix_socket_directories="${PGSOCKET_DIR}" &
  PG_PID=$!
}

wait_for_db() {
  # Wait for readiness; fail loudly (and exit) if the DB never comes up so
  # OpenHost restarts the container instead of us proceeding into confusing
  # psql connection errors.
  for _ in $(seq 1 60); do
    if su-exec postgres pg_isready -h "${PGSOCKET_DIR}" -p "${PG_PORT}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  log "FATAL: PostgreSQL did not become ready within 60s"
  exit 1
}

bootstrap_role_and_db() {
  # Create role + database idempotently. The password is passed via a psql
  # variable and quoted with :'name', so no value can break out of the SQL
  # string; the generated password is hex-only anyway.
  su-exec postgres psql -h "${PGSOCKET_DIR}" -p "${PG_PORT}" -d postgres \
    -v ON_ERROR_STOP=1 -v pw="${PG_PASSWORD}" -v role="${PG_USER}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role')
\gexec
SELECT format('ALTER ROLE %I WITH PASSWORD %L', :'role', :'pw')
WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = :'role')
\gexec
SQL
  if ! su-exec postgres psql -h "${PGSOCKET_DIR}" -p "${PG_PORT}" -d postgres -tAc \
       "SELECT 1 FROM pg_database WHERE datname = '${PG_DB}'" | grep -q 1; then
    su-exec postgres createdb -h "${PGSOCKET_DIR}" -p "${PG_PORT}" -O "${PG_USER}" "${PG_DB}"
  fi
}

init_db
provision_db_password
start_db
wait_for_db
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
  # Ask postgres to shut down cleanly (fast mode) and reap it.
  kill -INT "${PG_PID}" 2>/dev/null || true
  wait "${PG_PID}" 2>/dev/null || true
  exit 0
}
trap terminate TERM INT

# Exit as soon as ANY critical child dies (Postgres, Next.js, or the proxy).
wait -n "${PG_PID}" "${NEXT_PID}" "${PROXY_PID}"
log "A supervised process exited; tearing down"
terminate
