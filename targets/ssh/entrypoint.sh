#!/bin/bash
# Fetch the Vault SSH CA public key and configure sshd to trust certificates
# signed by it. No static keys, no passwords: access comes only via a Boundary
# session that carries a Vault-signed, short-lived certificate.
set -euo pipefail

echo "[ssh-target] fetching Vault SSH CA..."
until curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/ssh/config/ca" \
      | jq -r '.data.public_key' > /etc/ssh/trusted-user-ca-keys.pem \
      && [ -s /etc/ssh/trusted-user-ca-keys.pem ]; do
  echo "[ssh-target] CA not ready, retrying..."
  sleep 3
done
echo "[ssh-target] trusting Vault SSH CA."

cat >> /etc/ssh/sshd_config <<'EOF'

# --- Boundary demo: trust Vault-signed certificates only ---
TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
EOF

# Seed a file so the recorded session has something to show.
echo "Welcome to the regulated-bank jump host. This session is being recorded." \
  > /etc/motd

echo "[ssh-target] starting sshd on :22"
exec /usr/sbin/sshd -D -e
