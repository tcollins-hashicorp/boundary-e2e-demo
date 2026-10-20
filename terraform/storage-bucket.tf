# MinIO bucket Boundary writes session recordings to. The worker (which has the
# recording_storage_path) reaches MinIO on the compose network, so the bucket is
# pinned to the worker with a filter. Credential rotation is off for the demo to
# keep the moving parts down; the runbook notes how to turn it on.

resource "boundary_storage_bucket" "recordings" {
  name            = "session-recordings"
  description     = "MinIO bucket for BSR session recordings"
  scope_id        = boundary_scope.org.id
  plugin_name     = "minio"
  bucket_name     = var.minio_bucket
  worker_filter   = var.filter_recording

  attributes_json = jsonencode({
    endpoint_url                = var.minio_endpoint
    region                      = "us-east-1"
    disable_credential_rotation = true
  })

  secrets_json = jsonencode({
    access_key_id     = var.minio_access_key
    secret_access_key = var.minio_secret_key
  })
}
