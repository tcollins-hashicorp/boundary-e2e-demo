#!/bin/bash
# After terraform apply, write the generated password auth-method id into .env so
# the PAM portal can authenticate, then recreate the PAM container to pick it up.
set -euo pipefail
cd "$(dirname "$0")/.."

AM_ID="$(terraform -chdir=terraform output -raw auth_method_id)"
if [ -z "$AM_ID" ]; then
  echo "[set-pam-env] no auth_method_id in terraform output"; exit 1
fi

if grep -q '^BOUNDARY_AUTH_METHOD_ID=' .env; then
  sed -i.bak "s#^BOUNDARY_AUTH_METHOD_ID=.*#BOUNDARY_AUTH_METHOD_ID=${AM_ID}#" .env && rm -f .env.bak
else
  echo "BOUNDARY_AUTH_METHOD_ID=${AM_ID}" >> .env
fi
echo "[set-pam-env] auth method ${AM_ID} written to .env"

echo "[set-pam-env] recreating pam-app with the new value..."
# --no-deps: don't let compose re-walk the dependency chain to the one-shot
# boundary-init (which fails against the already-running controller's DB lock).
podman compose up -d --no-deps --force-recreate pam-app
