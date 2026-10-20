#!/bin/bash
# Wait for the self-managed worker to register with the controller before
# Terraform creates worker-routed resources (the Vault credential store and the
# recording storage bucket). Uses the recovery KMS config to list workers.
set -euo pipefail

echo "[wait-for-worker] waiting for the worker to register..."
for _ in $(seq 1 30); do
  # Only count a worker that is actually reporting status. A worker that failed
  # to start (e.g. a bad config) can leave a dead row with last_status_time=null;
  # that row must NOT satisfy the wait, or Terraform runs before any worker can
  # take routed commands (Vault cred store, storage bucket) and fails.
  COUNT=$(podman exec boundary boundary workers list \
      -recovery-config /boundary/controller.hcl -format json 2>/dev/null \
      | jq '[.items[]? | select(.last_status_time != null)] | length' 2>/dev/null || echo 0)
  if [ "${COUNT:-0}" -ge 1 ]; then
    echo "[wait-for-worker] worker registered and reporting status."
    # Reporting status (the control connection) comes up a few seconds before the
    # reverse data-plane connection that controller->worker command routing (the
    # storage-bucket plugin) travels over. Give that a moment to establish so the
    # first terraform apply doesn't race it. The apply also retries as a backstop.
    echo "[wait-for-worker] letting the worker's command-routing connection settle..."
    sleep 20
    exit 0
  fi
  sleep 3
done

echo "[wait-for-worker] worker not visible yet; continuing (check 'podman logs boundary-worker')."
