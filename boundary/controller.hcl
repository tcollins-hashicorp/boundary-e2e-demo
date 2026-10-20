# Self-managed Boundary Enterprise controller.
# Fully local: Postgres for state, static AEAD KMS keys, Enterprise license from
# env. No cloud dependency. The worker authenticates to this controller with the
# shared worker-auth KMS key (no activation token).
#
# DEMO KEYS ONLY. These AEAD keys are committed on purpose so the stack is
# reproducible offline. Never reuse them anywhere real.

disable_mlock = true

controller {
  name        = "demo-controller"
  description = "Self-managed Boundary Enterprise controller for the end-to-end demo"

  # The address workers use to reach this controller's cluster listener AFTER
  # their initial connection. Without it, the controller advertises its bind
  # address (0.0.0.0:9201); the worker authenticates, then adopts 0.0.0.0:9201 as
  # its upstream, can't maintain its session, and self-terminates in a loop
  # (hashicorp/boundary#3845). On the compose network the controller is reachable
  # as "boundary", so advertise that.
  public_cluster_addr = "boundary:9201"

  database {
    url = "env://BOUNDARY_PG_URL"
  }

  # Boundary Enterprise license (session recording, credential injection, storage
  # policies). Supply BOUNDARY_LICENSE in .env (free trial from HashiCorp).
  license = "env://BOUNDARY_LICENSE"
}

# API: boundary CLI, Terraform and the PAM app talk here. http for the demo.
listener "tcp" {
  address     = "0.0.0.0:9200"
  purpose     = "api"
  tls_disable = true
}

# Cluster: workers dial in here. Boundary secures this with its own mTLS.
listener "tcp" {
  address = "0.0.0.0:9201"
  purpose = "cluster"
}

# Ops: health and metrics.
listener "tcp" {
  address     = "0.0.0.0:9203"
  purpose     = "ops"
  tls_disable = true
}

kms "aead" {
  purpose   = "root"
  aead_type = "aes-gcm"
  key       = "45WhlgQJSedjgVe2YC3Aiwk8TOyONwt7MgK5yoVkiCY="
  key_id    = "global_root"
}

kms "aead" {
  purpose   = "worker-auth"
  aead_type = "aes-gcm"
  key       = "3rI9VN2GTvOcDyPfRSfCoukPJsvOXjr/+zfFxyuVVBY="
  key_id    = "global_worker-auth"
}

kms "aead" {
  purpose   = "recovery"
  aead_type = "aes-gcm"
  key       = "d+I6IJhS1mpDEEoKNY/+b28JB2w8q+DDA6ZoQi6kbLk="
  key_id    = "global_recovery"
}

# Session recording data encryption key (BSR).
kms "aead" {
  purpose   = "bsr"
  aead_type = "aes-gcm"
  key       = "WvITA7JuycQcc6QGyuhq8kPPtbNSl2+ItwsKfrLyZMU="
  key_id    = "session_recording"
}
