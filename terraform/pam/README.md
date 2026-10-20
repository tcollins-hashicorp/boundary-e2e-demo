# Why there is no Terraform here

Just-in-time membership is a runtime concern, not a provisioning one. The PAM
portal adds and removes the engineer from the `jit-privileged-access` role through
the Boundary API as requests are approved and windows expire. Terraform creates
the role (empty) and then stays out of its membership via `ignore_changes`
(see `../roles.tf`).

If you would rather drive grants through Terraform instead of the portal API, a
module here could manage `boundary_role.jit_privileged.principal_ids` and you would
`terraform apply` on approval and `terraform apply` again on expiry. That couples
the demo to Terraform's state locking and is slower to show live, so the portal
owns it instead.
