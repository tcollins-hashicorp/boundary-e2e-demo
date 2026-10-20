#!/bin/bash
# Block until the one-shot bootstrap containers finish. Terraform depends on their
# output: vault-bootstrap writes the Boundary Vault token file and enables the SSH
# and Kubernetes engines; minio-bootstrap creates the recording bucket and service
# account. podman compose does not block on completion, so we wait explicitly.
set -uo pipefail

for svc in vault-bootstrap minio-bootstrap; do
  echo "[wait-for-bootstraps] waiting for $svc..."
  podman wait "$svc" >/dev/null 2>&1 || true
  code=$(podman inspect -f '{{.State.ExitCode}}' "$svc" 2>/dev/null || echo "?")
  if [ "$code" = "0" ]; then
    echo "[wait-for-bootstraps] $svc completed."
  else
    echo "[wait-for-bootstraps] WARNING: $svc exit code $code. Check 'podman logs $svc'."
  fi
done
