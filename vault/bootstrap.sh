#!/bin/sh
# Configure Vault for the demo:
#   1. SSH secrets engine with a signing CA  -> brokered SSH certs for the Linux target
#   2. Kubernetes secrets engine             -> short-lived service-account tokens for k3s
#   3. A policy + token for the Boundary controller to read both
#   4. A file audit device                   -> JSON that Promtail ships to Grafana
set -eu

echo "[vault-bootstrap] waiting for Vault..."
until vault status >/dev/null 2>&1; do sleep 2; done
echo "[vault-bootstrap] Vault is up."

# --- Audit device (who did what in Vault) -----------------------------------
mkdir -p /vault/audit
vault audit list 2>/dev/null | grep -q 'file/' || \
  vault audit enable file file_path=/vault/audit/audit.log || true

# --- 1. SSH certificate signing ---------------------------------------------
vault secrets list | grep -q '^ssh/' || vault secrets enable ssh
vault write -f ssh/config/ca generate_signing_key=true || true

vault write ssh/roles/boundary-client - <<'EOF'
{
  "allow_user_certificates": true,
  "allowed_users": "appuser",
  "default_user": "appuser",
  "key_type": "ca",
  "allowed_extensions": "permit-pty,permit-port-forwarding",
  "default_extensions": { "permit-pty": "" },
  "ttl": "300",
  "max_ttl": "600"
}
EOF

# Export the CA public key so the SSH target can trust it.
vault read -field=public_key ssh/config/ca > /work/trusted-ca.pub
echo "[vault-bootstrap] wrote SSH CA public key to /work/trusted-ca.pub"

# --- 2. Kubernetes secrets engine -------------------------------------------
vault secrets list | grep -q '^kubernetes/' || vault secrets enable kubernetes
# The engine config (host + CA + token) is written by scripts/setup-cluster.sh
# once the k3s service is up, because it needs the cluster's CA.
vault write kubernetes/roles/boundary-k8s \
  allowed_kubernetes_namespaces="*" \
  token_default_ttl="10m" \
  token_max_ttl="20m" \
  generated_role_rules='{"rules":[{"apiGroups":[""],"resources":["pods","services","namespaces","nodes"],"verbs":["get","list","watch"]}]}' \
  || echo "[vault-bootstrap] k8s role deferred until cluster is connected"

# --- 3. Boundary controller policy + token ----------------------------------
cat > /tmp/boundary-controller.hcl <<'EOF'
path "ssh/sign/boundary-client"      { capabilities = ["create","update"] }
path "ssh/issue/boundary-client"     { capabilities = ["create","update"] }
path "kubernetes/creds/boundary-k8s" { capabilities = ["create","update"] }
path "auth/token/lookup-self"        { capabilities = ["read"] }
path "auth/token/renew-self"         { capabilities = ["update"] }
path "auth/token/revoke-self"        { capabilities = ["update"] }
path "sys/leases/renew"              { capabilities = ["update"] }
path "sys/leases/revoke"             { capabilities = ["update"] }
path "sys/capabilities-self"         { capabilities = ["update"] }
EOF
vault policy write boundary-controller /tmp/boundary-controller.hcl

# Periodic, renewable token for Boundary's Vault credential store.
vault token create \
  -policy=boundary-controller \
  -period=24h \
  -no-default-policy \
  -orphan \
  -renewable=true \
  -field=token > /work/boundary-vault-token.txt
echo "[vault-bootstrap] wrote Boundary Vault token to /work/boundary-vault-token.txt"

echo "[vault-bootstrap] done."
