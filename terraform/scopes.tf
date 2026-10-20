# Org and project structure.
#   bank-demo (org)
#     └── core-infra (project)   SSH + Kubernetes targets live here

resource "boundary_scope" "org" {
  scope_id                 = "global"
  name                     = "bank-demo"
  description              = "Regulated-bank end-to-end demo"
  auto_create_admin_role   = true
  auto_create_default_role = true
}

resource "boundary_scope" "core_infra" {
  scope_id                 = boundary_scope.org.id
  name                     = "core-infra"
  description              = "SSH and Kubernetes targets gated by Boundary"
  auto_create_admin_role   = true
  auto_create_default_role = true
}
