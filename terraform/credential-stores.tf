# Vault credential store and libraries.
#
# No worker_filter: the controller is on the same compose network as Vault and
# reaches http://vault:8200 directly, so the Vault token lookup does NOT need to
# be routed through a worker. Pinning it to the worker only forced command
# routing (and failed with "no path to worker") for no benefit here. Credential
# INJECTION into sessions still happens on the worker — this only controls who
# performs the Vault API calls, which the controller does directly.

locals {
  vault_token = var.vault_boundary_token != "" ? var.vault_boundary_token : trimspace(file("${path.module}/../vault/boundary-vault-token.txt"))
}

resource "boundary_credential_store_vault" "vault" {
  name        = "vault"
  description = "Brokers SSH certificates and Kubernetes tokens"
  scope_id    = boundary_scope.core_infra.id
  address     = var.vault_addr
  token       = local.vault_token
}

# Signs a short-lived SSH certificate for the appuser on the Linux target.
resource "boundary_credential_library_vault_ssh_certificate" "ssh" {
  name                = "ssh-cert"
  description         = "Vault-signed SSH certificate, 5m TTL"
  credential_store_id = boundary_credential_store_vault.vault.id
  path                = "ssh/sign/boundary-client"
  username            = var.ssh_target_user
  key_type            = "ed25519"
  extensions = {
    permit-pty = ""
  }
}

# Mints a short-lived Kubernetes service-account token for the k3s cluster.
resource "boundary_credential_library_vault" "k8s" {
  name                = "k8s-token"
  description         = "Vault-minted Kubernetes SA token, 10m TTL"
  credential_store_id = boundary_credential_store_vault.vault.id
  path                = "kubernetes/creds/boundary-k8s"
  http_method         = "POST"
  http_request_body = jsonencode({
    kubernetes_namespace = "payments"
    ttl                  = "10m"
  })
}
