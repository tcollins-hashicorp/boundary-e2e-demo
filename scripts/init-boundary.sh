#!/bin/bash
# Run `boundary database init` to completion BEFORE the controller starts.
# This is the critical ordering: if the controller is running it holds the schema
# advisory lock while checking the version, and init's lock attempt fails. We run
# init as an isolated one-shot (--no-deps so compose does not drag the controller
# up alongside it) and block on its exit code.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[init-boundary] running one-shot database init (controller not yet started)..."
podman compose up -d --no-deps --force-recreate boundary-init

RC="$(podman wait boundary-init)"
echo "---- boundary-init logs ----"
podman logs boundary-init 2>&1 | tail -20
echo "----------------------------"
podman rm boundary-init >/dev/null 2>&1 || true

if [ "$RC" != "0" ]; then
  echo "[init-boundary] database init failed (exit $RC). See logs above."
  exit 1
fi
echo "[init-boundary] database ready."
