#!/bin/bash
# Fail fast if a tool is missing, podman cannot run containers, or .env is
# incomplete. Fully self-contained demo: the only external input is a Boundary
# Enterprise license. Works on macOS (podman machine) and Linux.
set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

missing=0
# kubectl not required: k3s is driven via `podman exec`.
for bin in podman terraform boundary jq curl; do
  if command -v "$bin" >/dev/null 2>&1; then
    green "found   $bin"
  else
    red   "missing $bin"
    missing=1
  fi
done

if podman compose version >/dev/null 2>&1; then
  green "found   podman compose"
elif command -v podman-compose >/dev/null 2>&1; then
  green "found   podman-compose (set COMPOSE in the Makefile if you prefer it)"
else
  red "missing podman compose / podman-compose"; missing=1
fi

if podman info >/dev/null 2>&1; then
  green "podman engine reachable"
else
  red "podman cannot reach an engine."
  [ "$(uname -s)" = "Darwin" ] && red "  start the machine: podman machine start   (or 'make setup')"
  missing=1
fi

# macOS: the podman machine must be rootful or k3s cannot get the cpuset cgroup.
if [ "$(uname -s)" = "Darwin" ]; then
  ROOTFUL=$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null | head -1 || echo "")
  if echo "$ROOTFUL" | grep -qi true; then
    green "podman machine is rootful"
  else
    red "podman machine is NOT rootful. k3s needs the cpuset cgroup, so switch it:"
    red "    podman machine stop && podman machine set --rootful && podman machine start"
    missing=1
  fi
fi

if [ ! -f .env ]; then
  red "no .env file. Copy .env.example to .env and set BOUNDARY_LICENSE."
  missing=1
else
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
  if [ -z "${BOUNDARY_LICENSE:-}" ]; then
    red "BOUNDARY_LICENSE is unset. Paste your Boundary Enterprise license into .env."
    red "  Get a free trial license from HashiCorp."
    missing=1
  else
    green "BOUNDARY_LICENSE is set"
  fi
fi

if [ "$missing" -ne 0 ]; then
  red "preflight failed."; exit 1
fi
green "preflight ok."
