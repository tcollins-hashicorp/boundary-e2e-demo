#!/bin/bash
# Connect to the Kubernetes target through Boundary with a Vault-minted,
# short-lived service-account token.
#
# Why this wrapper exists: `boundary connect kube` does not reliably pull the
# service_account_token out of a *generic* Vault credential library, so kubectl
# ends up unauthenticated (401). Here we authorize the session, pull the brokered
# token ourselves, and hand it to kubectl over the Boundary proxy. The token is
# minted fresh per session and is RBAC-scoped to get/list/watch in the namespace.
#
# Usage:
#   scripts/connect-kube.sh [k8s-target-id] [kubectl args...]
#   scripts/connect-kube.sh                         # defaults: get pods -n payments
#   scripts/connect-kube.sh ttcp_XXXX get ns
set -euo pipefail

: "${BOUNDARY_ADDR:=http://localhost:9200}"
export BOUNDARY_ADDR

# Default to the k8s target id from terraform output if none is passed.
TARGET_ID="${1:-}"
if [ -z "$TARGET_ID" ]; then
  TARGET_ID="$(terraform -chdir="$(dirname "$0")/../terraform" output -raw k8s_target_id 2>/dev/null || true)"
fi
[ -n "$TARGET_ID" ] || { echo "usage: connect-kube.sh <k8s-target-id> [kubectl args...]"; exit 1; }
[ $# -gt 0 ] && shift || true

KUBECTL_ARGS=("$@")
[ ${#KUBECTL_ARGS[@]} -eq 0 ] && KUBECTL_ARGS=(get pods -n payments)

echo "[connect-kube] authorizing session to $TARGET_ID (Boundary brokers a Vault-minted token)..."
S=$(boundary targets authorize-session -id "$TARGET_ID" -format json)
TOKEN=$(printf '%s' "$S" | jq -r '.item.credentials[0].secret.decoded.service_account_token')
AUTHZ=$(printf '%s' "$S" | jq -r '.item.authorization_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "[connect-kube] could not find service_account_token in the brokered credential:"
  printf '%s' "$S" | jq '.item.credentials'
  exit 1
fi

# --insecure-skip-tls-verify: the dev k3s API uses a self-signed cluster CA. In
# production you would pin that CA instead; the Boundary + Vault brokering is the
# part that matters and is unchanged.
exec boundary connect -authz-token="$AUTHZ" -exec kubectl -- \
  --server="https://{{boundary.addr}}" --insecure-skip-tls-verify --token="$TOKEN" \
  "${KUBECTL_ARGS[@]}"
