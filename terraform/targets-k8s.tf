# Kubernetes target. The engineer runs:
#   boundary connect kube -target-id <id> -- get pods -n payments
# Boundary proxies kubectl to the k3s service and brokers a short-lived
# service-account token minted by Vault. No standing kubeconfig on the laptop.

resource "boundary_host_catalog_static" "k8s" {
  name     = "k8s-hosts"
  scope_id = boundary_scope.core_infra.id
}

resource "boundary_host_static" "k8s_api" {
  name            = "k3s-api"
  host_catalog_id = boundary_host_catalog_static.k8s.id
  address         = var.k8s_api_address
}

resource "boundary_host_set_static" "k8s" {
  name            = "k8s-set"
  host_catalog_id = boundary_host_catalog_static.k8s.id
  host_ids        = [boundary_host_static.k8s_api.id]
}

resource "boundary_target" "k8s" {
  name         = "payments-cluster"
  description  = "k3s cluster API, Vault-brokered SA token"
  type         = "tcp"
  scope_id     = boundary_scope.core_infra.id
  default_port = var.k8s_api_port

  host_source_ids = [boundary_host_set_static.k8s.id]

  brokered_credential_source_ids = [
    boundary_credential_library_vault.k8s.id
  ]

  egress_worker_filter = var.filter_k8s
}
