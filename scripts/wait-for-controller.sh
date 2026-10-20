#!/bin/bash
# Wait for the local Boundary controller to answer on its ops/health listener.
# podman compose does not block on healthchecks, so we poll before the worker
# starts and before Terraform runs.
set -euo pipefail

echo "[wait-for-controller] waiting for the controller health endpoint..."
for _ in $(seq 1 40); do
  if curl -sf http://localhost:9203/health >/dev/null 2>&1; then
    echo "[wait-for-controller] controller is healthy."
    exit 0
  fi
  sleep 3
done

echo "[wait-for-controller] controller did not become healthy. Check 'podman logs boundary'."
exit 1
