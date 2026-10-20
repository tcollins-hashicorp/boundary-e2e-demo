output "org_scope_id" { value = boundary_scope.org.id }
output "project_scope_id" { value = boundary_scope.core_infra.id }

output "dev_jump_target_id" { value = boundary_target.dev_jump.id }
output "prod_jump_target_id" { value = boundary_target.prod_jump.id }
output "k8s_target_id" { value = boundary_target.k8s.id }
output "postgres_target_id" { value = boundary_target.postgres.id }

output "storage_policy_id" {
  value = var.enable_storage_policy ? boundary_policy_storage.recordings[0].id : "disabled"
}

output "auth_method_id" { value = boundary_auth_method_password.org.id }
output "jit_role_id" { value = boundary_role.jit_privileged.id }
output "engineer_user_id" { value = boundary_user.engineer.id }
output "engineer_login" { value = var.engineer_login_name }

output "admin_login" { value = var.admin_login }
output "boundary_ui" {
  value = "http://localhost:9200 — log in at the global scope as ${var.admin_login}"
}

output "next_steps" {
  value = <<-EOT
    Provisioned on the local controller. Try the flow:
      export BOUNDARY_ADDR=${var.boundary_addr}
      boundary authenticate password -auth-method-id ${boundary_auth_method_password.org.id} -login-name ${var.engineer_login_name}
      boundary connect ssh  -target-id ${boundary_target.dev_jump.id}
      boundary connect kube -target-id ${boundary_target.k8s.id} -- get pods -n payments
    prod-payments-jump (${boundary_target.prod_jump.id}) is denied until you request it in the PAM portal.
  EOT
}
