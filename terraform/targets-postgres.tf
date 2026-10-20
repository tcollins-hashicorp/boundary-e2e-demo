# Postgres target for the brokering-vs-injection contrast. Boundary hands the
# credential to the user's client (brokering), so the user sees it. Community
# Edition can do this. The SSH target injects instead, and the user never sees
# the secret. Showing both side by side draws the enterprise line.

resource "boundary_credential_store_static" "postgres" {
  name     = "postgres-static"
  scope_id = boundary_scope.core_infra.id
}

resource "boundary_credential_username_password" "postgres" {
  name                = "postgres-demo"
  credential_store_id = boundary_credential_store_static.postgres.id
  username            = "demo"
  password            = var.postgres_password
}

resource "boundary_host_catalog_static" "pg" {
  name     = "pg-hosts"
  scope_id = boundary_scope.core_infra.id
}

resource "boundary_host_static" "pg" {
  name            = "pg-host"
  host_catalog_id = boundary_host_catalog_static.pg.id
  address         = var.postgres_target_address
}

resource "boundary_host_set_static" "pg" {
  name            = "pg-set"
  host_catalog_id = boundary_host_catalog_static.pg.id
  host_ids        = [boundary_host_static.pg.id]
}

resource "boundary_target" "postgres" {
  name         = "payments-db"
  description  = "Postgres, credential brokered (user sees the secret)"
  type         = "tcp"
  scope_id     = boundary_scope.core_infra.id
  default_port = 5432

  host_source_ids = [boundary_host_set_static.pg.id]

  brokered_credential_source_ids = [
    boundary_credential_username_password.postgres.id
  ]

  egress_worker_filter = var.filter_openssh
}
