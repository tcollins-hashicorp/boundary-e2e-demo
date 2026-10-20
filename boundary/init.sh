#!/bin/sh
# Initialize the Boundary database. Runs once (Postgres readiness is gated by the
# compose healthcheck + depends_on, so there is no wait loop here). Idempotent:
#   - fresh DB            -> `database init` creates schema + root key + resources
#   - already initialized -> init reports a lock/integrity/"already" condition, so
#                            we fall back to `database migrate` to ensure the schema
#                            is current, then exit 0
#   - dirty / broken DB   -> migrate also fails; we exit 1 with a reset hint rather
#                            than looping forever
set -eu

# Small settle margin after the DB healthcheck flips to healthy.
sleep 2

# If the controller is already running, the schema is live and managed by it;
# re-running init/migrate would only fight its advisory lock (that is the "Unable
# to capture a lock" failure seen when `make up` is re-run against a live stack).
# Detect a healthy controller and skip, so `make up` is safe to re-run.
if wget -q -T 2 -O /dev/null http://boundary:9203/health 2>/dev/null; then
  echo "[boundary-init] controller already running and healthy; schema is live. Skipping init."
  exit 0
fi

echo "[boundary-init] running database init..."
set +e
OUT=$(boundary database init -config /boundary/controller.hcl \
    -skip-auth-method-creation \
    -skip-host-resources-creation \
    -skip-target-creation \
    -skip-scopes-creation \
    -skip-initial-login-role-creation 2>&1)
RC=$?
set -e
echo "$OUT"

if [ "$RC" -eq 0 ]; then
  echo "[boundary-init] database initialized."
  exit 0
fi

# init failed. If it looks already-initialized (or the migration lock/integrity
# path), just bring the schema current and continue.
if echo "$OUT" | grep -qiE "already initialized|already been initialized|capture a lock|integrity violation|migrations are already|no migrations|up to date"; then
  echo "[boundary-init] database appears already initialized; running migrate..."
  set +e
  MOUT=$(boundary database migrate -config /boundary/controller.hcl 2>&1)
  MRC=$?
  set -e
  echo "$MOUT"
  if [ "$MRC" -eq 0 ] || echo "$MOUT" | grep -qiE "no migrations|up to date|already"; then
    echo "[boundary-init] schema is current."
    exit 0
  fi
  echo "[boundary-init] ERROR: database is in an unexpected state."
  echo "[boundary-init] Reset it with:"
  echo "    podman compose rm -sf boundary boundary-init boundary-db"
  echo "    podman volume rm boundary-e2e_boundary-db-data"
  echo "    make up"
  exit 1
fi

echo "[boundary-init] ERROR: database init failed for an unexpected reason (see above)."
exit 1
