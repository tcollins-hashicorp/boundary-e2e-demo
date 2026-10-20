# Global admin login for the Boundary UI.
#
# The demo's user accounts (dana, pam-operator) live in the bank-demo org, but
# the Boundary admin UI opens its login against the GLOBAL scope. With no auth
# method at global, the login page shows "No auth methods were found for this
# scope." This file adds a password auth method and an admin account at global,
# so opening http://localhost:9200 lands on a working login.
#
# The admin holds full rights across global and every child scope, which is what
# lets an auditor replay session recordings in the UI (Act 4 of the runbook).
# This is additive: dana and pam-operator in the org (auth.tf) are unchanged, and
# the PAM portal still authenticates against the org auth method.
#
# Two pieces are needed, not one. boundary/init.sh runs `database init` with
# -skip-initial-login-role-creation, so the anonymous user u_anon has no grants.
# The browser login page calls the API as u_anon, so without a login grant it
# cannot even list the auth method below — the UI shows "No auth methods were
# found for this scope" regardless. boundary_role.global_login restores exactly
# the grants that flag skipped.

resource "boundary_auth_method_password" "global" {
  scope_id    = "global"
  name        = "global-admin-password"
  description = "Admin login for the Boundary UI (demo)"
}

resource "boundary_account_password" "admin" {
  auth_method_id = boundary_auth_method_password.global.id
  login_name     = var.admin_login
  password       = var.admin_password
  name           = var.admin_login
}

resource "boundary_user" "admin" {
  scope_id    = "global"
  name        = var.admin_login
  description = "Demo administrator / auditor (Boundary UI login)"
  account_ids = [boundary_account_password.admin.id]
}

resource "boundary_role" "admin" {
  name        = "global-admin"
  description = "Full administration across global and all scopes (demo)"
  scope_id    = "global"

  # Apply in global and recurse into the org and project, so the admin can read
  # session recordings and everything else from the UI without scope-hopping.
  grant_scope_ids = ["this", "descendants"]

  principal_ids = [boundary_user.admin.id]

  grant_strings = [
    "ids=*;type=*;actions=*",
  ]
}

# Anonymous login grants, scoped to global. These are what
# -skip-initial-login-role-creation left out: u_anon must be able to list scopes
# and to list + authenticate auth methods, or the login page (which runs as
# u_anon) renders empty. The account/auth-token self grants let a user read and
# manage their own session right after they authenticate.
resource "boundary_role" "global_login" {
  name        = "global-login"
  description = "Anonymous login: list scopes, list + authenticate auth methods (demo)"
  scope_id    = "global"

  grant_scope_ids = ["this"]

  principal_ids = ["u_anon"]

  grant_strings = [
    # ids=* is required: a `type=...` grant with no id only permits create/list,
    # so `no-op` is rejected without it (perms.Parse error #100).
    "ids=*;type=scope;actions=list,no-op",
    "ids=*;type=auth-method;actions=list,authenticate",
    "ids={{.Account.Id}};actions=read:self,change-password",
    "ids=*;type=auth-token;actions=read:self,delete:self",
  ]
}
