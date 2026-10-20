# Two roles carry the whole access story.
#
#   engineers-standing   the engineers group can reach dev-jump and the cluster,
#                        any time, for routine work.
#   jit-privileged       grants prod-payments-jump. Starts with NO principals.
#                        The PAM portal adds the engineer on approval and removes
#                        them when the window closes. Terraform does not manage
#                        its membership, so the portal and TF never fight.

resource "boundary_role" "engineers_standing" {
  name            = "engineers-standing"
  description     = "Standing access to dev jump host and the cluster"
  scope_id        = boundary_scope.core_infra.id
  grant_scope_ids = [boundary_scope.core_infra.id]

  principal_ids = [boundary_group.engineers.id]

  grant_strings = [
    "ids=*;type=target;actions=list,read",
    "ids=${boundary_target.dev_jump.id};actions=authorize-session",
    "ids=${boundary_target.k8s.id};actions=authorize-session",
  ]
}

resource "boundary_role" "jit_privileged" {
  name            = "jit-privileged-access"
  description     = "Time-bound access to prod-payments-jump, granted via PAM"
  scope_id        = boundary_scope.core_infra.id
  grant_scope_ids = [boundary_scope.core_infra.id]

  grant_strings = [
    "ids=${boundary_target.prod_jump.id};actions=authorize-session,read",
  ]

  # The PAM portal owns membership at runtime.
  lifecycle {
    ignore_changes = [principal_ids]
  }
}
