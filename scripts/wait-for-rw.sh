#!/usr/bin/env bash
# Wait until RisingWave accepts SQL on PGHOST:PGPORT (defaults: localhost:4566).
set -euo pipefail

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-4566}"
export PGDATABASE="${PGDATABASE:-dev}"
export PGUSER="${PGUSER:-root}"
# RisingWave root has no password; avoid psql prompting in CI.
export PGPASSWORD="${PGPASSWORD:-}"

attempts="${RW_WAIT_ATTEMPTS:-60}"
sleep_s="${RW_WAIT_SLEEP:-2}"

echo "Waiting for RisingWave at ${PGHOST}:${PGPORT} (db=${PGDATABASE} user=${PGUSER}) ..."

for i in $(seq 1 "${attempts}"); do
  if psql -X -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
    echo "RisingWave is ready (attempt ${i})."
    exit 0
  fi
  sleep "${sleep_s}"
done

echo "ERROR: RisingWave did not become ready after ${attempts} attempts." >&2
exit 2
