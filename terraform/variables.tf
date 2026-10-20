# --- Self-managed Boundary controller ---------------------------------------
# API address of the local controller. Terraform runs on the host, so localhost.
variable "boundary_addr" {
  type    = string
  default = "http://localhost:9200"
}
# Recovery AEAD key, matching boundary/controller.hcl (demo key).
variable "boundary_recovery_key" {
  type      = string
  default   = "d+I6IJhS1mpDEEoKNY/+b28JB2w8q+DDA6ZoQi6kbLk="
  sensitive = true
}

# --- Global admin (Boundary UI login) ---------------------------------------
variable "admin_login" {
  type    = string
  default = "admin"
}
variable "admin_password" {
  type      = string
  default   = "BoundaryDemo123!" # demo only
  sensitive = true
}

# --- Engineer demo account --------------------------------------------------
variable "engineer_login_name" {
  type    = string
  default = "dana"
}
variable "engineer_password" {
  type      = string
  default   = "Password123!" # demo only
  sensitive = true
}

# --- PAM operator (the account the portal uses to drive grants) -------------
variable "pam_operator_login" {
  type    = string
  default = "pam-operator"
}
variable "pam_operator_password" {
  type      = string
  default   = "pam-operator-pw" # demo only
  sensitive = true
}

# --- Vault (reachable from the worker on the compose network) ---------------
variable "vault_addr" {
  type    = string
  default = "http://vault:8200"
}
# Boundary's Vault token, written by vault/bootstrap.sh.
variable "vault_boundary_token" {
  type      = string
  sensitive = true
  default   = "" # falls back to the file() read in credential-stores.tf
}

# --- MinIO storage bucket for session recordings ----------------------------
variable "minio_endpoint" {
  type    = string
  default = "http://minio:9000"
}
variable "minio_bucket" {
  type    = string
  default = "boundary-session-recordings"
}
# Boundary accesses the bucket with MinIO's root credentials (credential rotation
# is disabled), so these default to the MinIO root user/password.
variable "minio_access_key" {
  type    = string
  default = "minioadmin"
}
variable "minio_secret_key" {
  type      = string
  default   = "minioadmin"
  sensitive = true
}

# --- Target addresses on the compose network --------------------------------
variable "ssh_target_address" {
  type    = string
  default = "ssh-target"
}
variable "ssh_target_user" {
  type    = string
  default = "appuser"
}
variable "postgres_target_address" {
  type    = string
  default = "postgres-target"
}
variable "postgres_password" {
  type      = string
  default   = "postgres-demo-pw"
  sensitive = true
}

# --- Session recording retention (compliance) -------------------------------
variable "enable_storage_policy" {
  type    = bool
  default = true
}
variable "recording_retention_days" {
  type    = number
  default = 7
}
variable "k8s_api_address" {
  type    = string
  default = "k3s" # k3s compose service on the boundary-demo network
}
variable "k8s_api_port" {
  type    = number
  default = 6443
}

# Worker tag filters. One worker carries several tags; each resource pins to the
# tag that matches its job.
variable "filter_openssh" {
  type    = string
  default = "\"openssh\" in \"/tags/type\""
}
variable "filter_k8s" {
  type    = string
  default = "\"k8s\" in \"/tags/type\""
}
variable "filter_recording" {
  type    = string
  default = "\"session-recording\" in \"/tags/type\""
}
