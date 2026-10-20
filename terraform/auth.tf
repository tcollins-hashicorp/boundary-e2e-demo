# A password auth method in the org, plus the engineer who will drive the demo.
# The engineer starts with NO access to the sensitive target. They earn it, for
# a fixed window, through the PAM flow.

resource "boundary_auth_method_password" "org" {
  scope_id    = boundary_scope.org.id
  name        = "bank-demo-password"
  description = "Password auth for demo users"
}

resource "boundary_account_password" "engineer" {
  auth_method_id = boundary_auth_method_password.org.id
  login_name     = var.engineer_login_name
  password       = var.engineer_password
  name           = var.engineer_login_name
}

resource "boundary_user" "engineer" {
  scope_id    = boundary_scope.org.id
  name        = var.engineer_login_name
  description = "Platform engineer"
  account_ids = [boundary_account_password.engineer.id]
}

# Group that always holds standing SSH + K8s access (the baseline the engineer
# has for routine work). The sensitive target is deliberately excluded.
resource "boundary_group" "engineers" {
  scope_id    = boundary_scope.org.id
  name        = "engineers"
  description = "Standing access group"
  member_ids  = [boundary_user.engineer.id]
}

# --- PAM operator -----------------------------------------------------------
# The account the PAM portal authenticates as to add and remove the engineer
# from the JIT role. Scoped to exactly that: manage role principals and read the
# users, roles and targets it needs to resolve names.
resource "boundary_account_password" "pam_operator" {
  auth_method_id = boundary_auth_method_password.org.id
  login_name     = var.pam_operator_login
  password       = var.pam_operator_password
  name           = var.pam_operator_login
}

resource "boundary_user" "pam_operator" {
  scope_id    = boundary_scope.org.id
  name        = var.pam_operator_login
  description = "Service account for the PAM portal"
  account_ids = [boundary_account_password.pam_operator.id]
}

resource "boundary_role" "pam_operator" {
  name        = "pam-operator"
  description = "Lets the PAM portal grant and revoke JIT access"
  scope_id    = "global"

  # The portal lists users (org), the JIT role and targets (project) recursively
  # from global, so the role grants across global and every descendant scope.
  grant_scope_ids = ["this", "descendants"]

  principal_ids = [boundary_user.pam_operator.id]

  grant_strings = [
    "ids=*;type=role;actions=list,read,add-principals,remove-principals",
    "ids=*;type=user;actions=list,read",
    "ids=*;type=target;actions=list,read",
    "ids=*;type=scope;actions=list,read",
    # Ending the window has to tear down sessions already in flight, not just
    # remove the grant. The portal lists the engineer's live sessions and cancels
    # them, so the operator needs list + cancel on sessions (not cancel:self —
    # these are someone else's sessions). This is the grant a customer must add
    # to whatever identity their real PAM automation runs as.
    "ids=*;type=session;actions=list,read,cancel",
  ]
}
