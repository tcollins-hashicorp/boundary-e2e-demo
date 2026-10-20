# Retention policy for session recordings. A bank has a mandate for how long
# access evidence is kept and when it is deleted. Storage policies resolve top
# down from global through orgs: longest retention wins, shortest deletion wins.
# Toggle with enable_storage_policy.

resource "boundary_policy_storage" "recordings" {
  count = var.enable_storage_policy ? 1 : 0

  name        = "recording-retention"
  description = "Keep SSH session recordings for the compliance window"
  scope_id    = boundary_scope.org.id

  retain_for_days   = var.recording_retention_days
  delete_after_days = var.recording_retention_days + 1
}

# Attaching the policy to a scope is done by setting storage_policy_id on the
# scope. Provider attribute names for this have shifted across versions, so
# confirm against your pinned provider and attach in the console if needed.
# Reference the policy id from outputs.tf for the attach step.
