#!/bin/sh
# Start the self-managed worker as root, after guaranteeing its recording and log
# paths exist and are writable. This runs no matter how podman/compose created the
# mounted volumes, so the worker can always write session recordings (BSR) and its
# event log. disable_mlock=true in the config handles the IPC_LOCK capability.
set -e

mkdir -p /boundary/auth /boundary/recordings /boundary/logs
chmod 0777 /boundary/recordings /boundary/logs 2>/dev/null || true
chmod 0700 /boundary/auth 2>/dev/null || true

exec boundary server -config /boundary/boundary-worker.hcl
