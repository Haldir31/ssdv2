#!/bin/bash
###############################################################################
# start_cmd helper for the native `slicksync` app (vars/slicksync.yml).
#
# SlickSync ships as ONE oven/bun image that internally runs TWO processes
# (scripts/start.sh upstream): an Express API and a Next.js frontend. The
# frontend is the only public surface — its next.config.ts rewrites /api,
# /proxy, /trax, /uploads, /invite to http://localhost:<BACKEND_PORT>, so the
# backend only needs to be reachable on loopback.
#
# This is the native port of scripts/start.sh: pick the SQLite (private) schema,
# push it, launch both processes, and exit as soon as either dies so launchd
# (KeepAlive) restarts the pair. bash 3.2 safe — no `wait -n`.
#
# Usage (from vars/slicksync.yml start_cmd):
#   run_slicksync.sh <src_dir> <data_dir>
# Env (from the LaunchAgent): FRONTEND_PORT, BACKEND_PORT, plus the app env.
###############################################################################
set -u

SRC="${1:?usage: run_slicksync.sh <src_dir> <data_dir>}"
DATA="${2:?usage: run_slicksync.sh <src_dir> <data_dir>}"
FRONTEND_PORT="${FRONTEND_PORT:-3060}"
BACKEND_PORT="${BACKEND_PORT:-4000}"

export INSTANCE="private"
export INSTANCE_TYPE="private"
export NEXT_PUBLIC_INSTANCE_TYPE="private"
export NODE_ENV="production"
export NODE_OPTIONS="--dns-result-order=ipv4first"
export JWT_SECRET="${JWT_SECRET:-$(cat "${DATA}/secret_key" 2>/dev/null)}"

mkdir -p "${DATA}/data"
DB_URL="file://${DATA}/data/sqlite.db"
export DATABASE_URL="${DB_URL}"

cd "${SRC}" || exit 1

# --- Prisma: SQLite schema + apply (idempotent, mirrors scripts/start.sh) -----
cp -f prisma/schema.sqlite.prisma prisma/schema.prisma
rm -f prisma/migration_lock.toml
rm -rf prisma/migrations
bunx prisma db push --schema prisma/schema.prisma --accept-data-loss || true

# --- backend (loopback only; cwd = DATA so data/ + the auto-generated --------
#     ENCRYPTION_KEY in data/ survive a `git reset --hard` source update) ------
(
  cd "${DATA}" || exit 1
  HOST=127.0.0.1 PORT="${BACKEND_PORT}" \
    exec bun "${SRC}/server/index.js"
) &
BACKEND_PID=$!

# --- frontend (the routed surface) ------------------------------------------
(
  cd "${SRC}/client" || exit 1
  HOSTNAME=127.0.0.1 exec bunx next start -H 127.0.0.1 -p "${FRONTEND_PORT}"
) &
FRONTEND_PID=$!

cleanup() {
  kill "${BACKEND_PID}" "${FRONTEND_PID}" 2>/dev/null
  wait 2>/dev/null
  exit 0
}
trap cleanup INT TERM

# exit (non-zero) the moment either process is gone -> launchd restarts us
while kill -0 "${BACKEND_PID}" 2>/dev/null && kill -0 "${FRONTEND_PID}" 2>/dev/null; do
  sleep 5
done
echo "slicksync: a child process exited (backend=${BACKEND_PID} frontend=${FRONTEND_PID}) — stopping the pair" >&2
kill "${BACKEND_PID}" "${FRONTEND_PID}" 2>/dev/null
wait 2>/dev/null
exit 1
