#!/bin/bash
# Wire Vault to the k3s service. k3s runs as a compose container on the
# boundary-demo network, so there is no network join and no host kubectl: we drive
# the cluster with `podman exec k3s kubectl`.
#   1. Wait for k3s to be ready.
#   2. Seed the payments workload.
#   3. Create a Vault service account + token in the cluster.
#   4. Point Vault's kubernetes secrets engine at https://k3s:6443.
set -euo pipefail

# Use the image's `kubectl` command directly. `k3s kubectl` double-wraps in this
# image (the binary runs as kubectl and then sees "kubectl" as a bad subcommand).
# KUBECONFIG is set explicitly for the exec context.
#   K  : read-only calls (no stdin needed).
#   KI : calls that read a manifest from stdin (`apply -f -`). `podman exec` only
#        forwards stdin into the container with `-i`; without it kubectl sees empty
#        input and fails with "no objects passed to apply".
K="podman exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl"
KI="podman exec -i -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl"

# Fail clearly if the k3s container isn't even running (common on a rootless
# podman machine, where k3s can't get the privileges it needs).
state=$(podman inspect -f '{{.State.Status}}' k3s 2>/dev/null || echo missing)
if [ "$state" != "running" ]; then
  echo "[setup-cluster] k3s container is not running (state: $state)."
  echo ""
  echo "  k3s needs more privilege than a rootless podman machine provides."
  echo "  On macOS, make the machine rootful and re-run:"
  echo "      podman machine stop"
  echo "      podman machine set --rootful"
  echo "      podman machine start"
  echo "      make up"
  echo ""
  echo "  To see why k3s exited:  podman logs k3s"
  exit 1
fi

echo "[setup-cluster] waiting for k3s to be ready..."
ready=""
for _ in $(seq 1 36); do
  # If the container stopped mid-wait, stop waiting and report.
  if [ "$(podman inspect -f '{{.State.Status}}' k3s 2>/dev/null)" != "running" ]; then
    echo "[setup-cluster] k3s container stopped while starting. Check 'podman logs k3s'."
    echo "  On macOS this usually means the machine must be rootful (see above)."
    exit 1
  fi
  # Ready when a plain API call via the in-container kubectl succeeds. We use
  # `get --raw=/version` (always allowed, no node/RBAC dependency) as the gate.
  if $K get --raw=/version >/dev/null 2>&1; then
    ready=1
    echo "[setup-cluster] k3s API reachable."
    break
  fi
  sleep 5
done
if [ -z "$ready" ]; then
  echo "[setup-cluster] k3s did not become ready in time."
  echo "---- diagnostics: the exact command that kept failing, with its error ----"
  echo "\$ podman exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl get nodes"
  $K get nodes || true
  echo "-------------------------------------------------------------------------"
  echo "(k3s itself may be healthy; this is about reaching it from the host.)"
  echo "Full server log: podman logs k3s"
  exit 1
fi

echo "[setup-cluster] seeding payments workload..."
$KI apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: payments
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger
  namespace: payments
spec:
  replicas: 2
  selector: { matchLabels: { app: ledger } }
  template:
    metadata: { labels: { app: ledger } }
    spec:
      containers:
        - name: ledger
          image: docker.io/library/nginx:1.27-alpine
          ports: [{ containerPort: 80 }]
EOF

echo "[setup-cluster] creating Vault service account in cluster..."
$KI apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-k8s-secrets
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-k8s-secrets
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: vault-k8s-secrets
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-k8s-secrets-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-k8s-secrets
type: kubernetes.io/service-account-token
EOF

sleep 3
# Decode with kubectl's go-template base64decode (inside the container), so this
# does not depend on a host `base64` flag that differs between Linux and macOS.
SA_JWT=$($K -n kube-system get secret vault-k8s-secrets-token -o go-template='{{.data.token | base64decode}}')
CA_CRT=$($K -n kube-system get secret vault-k8s-secrets-token -o go-template='{{index .data "ca.crt" | base64decode}}')

echo "[setup-cluster] writing kubernetes/config to Vault (https://k3s:6443)..."
# The CA covers k3s via --tls-san=k3s on the server, so TLS validates over the
# compose network.
podman exec -e VAULT_TOKEN="${VAULT_TOKEN:-root}" vault sh -c "
  printf '%s' '${CA_CRT}' > /tmp/k8s-ca.crt
  vault write kubernetes/config \
    kubernetes_host='https://k3s:6443' \
    kubernetes_ca_cert=@/tmp/k8s-ca.crt \
    service_account_jwt='${SA_JWT}' \
    disable_local_ca_jwt=true
"

echo "[setup-cluster] done. Vault can now mint k8s tokens for Boundary."
