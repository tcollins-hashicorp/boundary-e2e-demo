#!/bin/bash
# Wait for Boundary's Postgres to accept connections. podman compose does not
# block on healthchecks, so we poll explicitly before running database init.
set -euo pipefail

echo "[wait-for-db] waiting for boundary-db..."
for _ in $(seq 1 30); do
  if podman exec boundary-db pg_isready -U boundary >/dev/null 2>&1; then
    echo "[wait-for-db] Postgres is ready."
    exit 0
  fi
  sleep 2
done

echo "[wait-for-db] boundary-db did not become ready in time."
exit 1
