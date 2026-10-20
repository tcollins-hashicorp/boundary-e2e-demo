# Self-managed worker. Registers with the controller via PKI worker-led
# registration: on first boot it generates a node key, persists it to
# auth_storage_path, and prints a worker-generated auth token. `make up` runs
# scripts/register-worker.sh, which approves that token with the recovery KMS
# (`boundary workers create worker-led`). Records SSH sessions to local disk,
# then syncs BSR files to MinIO.
#
# Session recording needs a worker with a STABLE, on-disk identity, so this
# worker uses PKI auth (auth_storage_path), not KMS worker-auth. A KMS worker is
# deliberately storage-less and re-derives throwaway credentials each boot, which
# never completes registration for a recording worker.
#
# Four jobs, pinned by tags: proxy to SSH/Postgres (openssh), proxy to the k3s
# service (k8s), relay Vault credential requests (vault), and record sessions
# (session-recording).

disable_mlock = true

listener "tcp" {
  address = "0.0.0.0:9202"
  purpose = "proxy"
}

worker {
  # name/description are intentionally NOT set here. With PKI worker-led
  # (activation-token) auth, Boundary forbids name/description in the worker
  # config — they must be set via the API when the worker is approved.
  # scripts/register-worker.sh passes them to `boundary workers create worker-led`.

  # Dial the controller's cluster listener on the compose network.
  initial_upstreams = ["boundary:9201"]

  public_addr = "env://WORKER_PUBLIC_ADDR"

  # PKI worker-led registration. The worker persists its node credentials here,
  # giving it a stable identity across restarts (required for session recording)
  # and a stable registration token for scripts/register-worker.sh to approve.
  # Do NOT add a kms "worker-auth" block alongside this: Boundary refuses to start
  # a worker that declares both KMS worker-auth and an auth storage path.
  auth_storage_path      = "/boundary/auth"
  recording_storage_path = "/boundary/recordings"

  tags {
    type = ["worker", "vault", "openssh", "k8s", "session-recording"]
  }
}

# Structured events to a file so Promtail can ship worker activity to Grafana
# without a container socket. The volume is mounted at /boundary/logs.
events {
  audit_enabled        = true
  observations_enabled = true
  sysevents_enabled    = true
  telemetry_enabled    = false

  sink {
    name        = "file-sink"
    event_types = ["*"]
    format      = "cloudevents-json"
    file {
      path      = "/boundary/logs"
      file_name = "worker-events.ndjson"
    }
  }
}
