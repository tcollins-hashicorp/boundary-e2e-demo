#!/bin/bash
# Approve the self-managed worker's PKI worker-led registration.
#
# A PKI worker boots, persists its node key to auth_storage_path, prints a
# "Worker Auth Registration Request" token, and waits to be approved. We read
# that token from the worker's logs and approve it with the recovery KMS
# (`boundary workers create worker-led`). Because the worker persists its key,
# the token is stable across restarts, so this is safe to retry.
#
# Idempotent: if an active worker is already registered, it does nothing.
set -euo pipefail

echo "[register-worker] checking whether a worker is already registered..."
ACTIVE=$(podman exec boundary boundary workers list \
    -recovery-config /boundary/controller.hcl -format json 2>/dev/null \
    | jq '[.items[]? | select(.last_status_time != null)] | length' 2>/dev/null || echo 0)
if [ "${ACTIVE:-0}" -ge 1 ]; then
  echo "[register-worker] an active worker is already registered; nothing to do."
  exit 0
fi

echo "[register-worker] waiting for the worker to emit its registration token..."
TOKEN=""
for _ in $(seq 1 30); do
  # The worker logs a line: "Worker Auth Registration Request: <token>".
  # Take everything after the colon, use the most recent line, strip whitespace.
  TOKEN=$(podman logs boundary-worker 2>&1 \
      | sed -n 's/.*Worker Auth Registration Request: *//p' \
      | tail -1 | tr -d '[:space:]')
  if [ -n "$TOKEN" ]; then
    break
  fi
  sleep 3
done

if [ -z "$TOKEN" ]; then
  echo "[register-worker] no registration token found in the worker log."
  echo "  Inspect it with: podman logs boundary-worker"
  exit 1
fi

echo "[register-worker] approving worker (token ${TOKEN:0:12}...)"
# Recovery KMS grants admin for this one call. name/description are set here (the
# API) because PKI worker-led auth forbids them in the worker config. If the
# worker was already created but is not yet reporting, a duplicate create is
# harmless to retry once.
podman exec boundary boundary workers create worker-led \
  -worker-generated-auth-token="$TOKEN" \
  -name demo-worker \
  -description "Self-managed worker: SSH/Postgres/K8s egress, Vault relay, session recording" \
  -recovery-config /boundary/controller.hcl \
  || echo "[register-worker] create returned non-zero (worker may already be approved); continuing."

echo "[register-worker] done. The worker should report status within a few seconds."
