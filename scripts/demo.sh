#!/bin/bash
# Guided walkthrough. Pauses between steps so you can narrate. Reads target ids
# from terraform outputs. Run after `make up`.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; . ./.env; set +a
export BOUNDARY_ADDR="${BOUNDARY_ADDR_HOST:-http://localhost:9200}"

tf() { terraform -chdir=terraform output -raw "$1"; }
pause() { printf '\n\033[33m-- %s --\033[0m\n' "$1"; read -r -p "   press enter to run..." _; }

DEV=$(tf dev_jump_target_id)
PROD=$(tf prod_jump_target_id)
K8S=$(tf k8s_target_id)
PG=$(tf postgres_target_id)
AM=$(tf auth_method_id)

echo "Authenticate as the engineer (dana) when prompted."
boundary authenticate password -auth-method-id "$AM" -login-name "${ENGINEER_LOGIN:-dana}" || true

pause "Act 1: SSH to the dev jump host (no key, Vault-signed cert, recorded)"
boundary connect ssh -target-id "$DEV" || true

pause "Act 1b: name the human behind the session (attribution)"
make recordings || true

pause "Act 1c: brokering contrast — Postgres hands you the credential"
boundary connect postgres -target-id "$PG" -dbname demo -- -c "select 1;" || true

pause "Act 2: Kubernetes via Boundary (Vault-minted SA token)"
boundary connect kube -target-id "$K8S" -- get pods -n payments || true

pause "Act 3a: Production is denied before approval"
boundary connect ssh -target-id "$PROD" || echo "   (expected: not authorized)"

echo ""
echo "Now raise and approve a request in the PAM portal: http://localhost:8080"
read -r -p "   press enter once approved..." _

pause "Act 3b: Production now works, for the length of the window"
boundary connect ssh -target-id "$PROD" || true

echo ""
echo "Watch the window close in the portal, then production denies again."
echo "Audit: Grafana http://localhost:3000  ·  Recordings: Boundary console / MinIO."
