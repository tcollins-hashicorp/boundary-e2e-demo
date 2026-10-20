# Two SSH targets against the same Linux host. The difference between them is
# entirely in Boundary's authorization, which is the point: who can reach prod is
# a Boundary decision, recorded and revocable.
#
#   dev-jump   standing access for the engineers group
#   prod-jump  sensitive; reachable only through a just-in-time PAM grant
#
# Both inject a Vault-signed certificate and record the full session to MinIO.

resource "boundary_host_catalog_static" "ssh" {
  name     = "ssh-hosts"
  scope_id = boundary_scope.core_infra.id
}

resource "boundary_host_static" "linux" {
  name            = "linux-host"
  host_catalog_id = boundary_host_catalog_static.ssh.id
  address         = var.ssh_target_address
}

resource "boundary_host_set_static" "ssh" {
  name            = "ssh-set"
  host_catalog_id = boundary_host_catalog_static.ssh.id
  host_ids        = [boundary_host_static.linux.id]
}

resource "boundary_target" "dev_jump" {
  name        = "dev-jump"
  description = "Development jump host (standing access)"
  type        = "ssh"
  scope_id    = boundary_scope.core_infra.id
  default_port = 22

  host_source_ids = [boundary_host_set_static.ssh.id]

  injected_application_credential_source_ids = [
    boundary_credential_library_vault_ssh_certificate.ssh.id
  ]

  egress_worker_filter = var.filter_openssh

  enable_session_recording = true
  storage_bucket_id        = boundary_storage_bucket.recordings.id
}

resource "boundary_target" "prod_jump" {
  name        = "prod-payments-jump"
  description = "Production payments jump host (PAM-gated, time-bound)"
  type        = "ssh"
  scope_id    = boundary_scope.core_infra.id
  default_port = 22

  host_source_ids = [boundary_host_set_static.ssh.id]

  injected_application_credential_source_ids = [
    boundary_credential_library_vault_ssh_certificate.ssh.id
  ]

  egress_worker_filter = var.filter_openssh

  enable_session_recording = true
  storage_bucket_id        = boundary_storage_bucket.recordings.id

  # A session here is short by policy; the PAM window governs whether you can
  # start one at all.
  session_max_seconds = 1800
}
