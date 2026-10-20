# Authenticates to the self-managed controller with the recovery KMS key, so it
# can provision a freshly initialized controller that has no login yet. The key
# matches the recovery block in boundary/controller.hcl (demo key).

provider "boundary" {
  addr = var.boundary_addr

  recovery_kms_hcl = <<-EOT
    kms "aead" {
      purpose   = "recovery"
      aead_type = "aes-gcm"
      key       = "${var.boundary_recovery_key}"
      key_id    = "global_recovery"
    }
  EOT
}
