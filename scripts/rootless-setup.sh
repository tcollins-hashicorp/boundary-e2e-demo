#!/bin/bash
# One-time host prep for podman. Detects macOS (podman machine) vs Linux.
# The cluster is k3s-in-a-container, so none of the kind-era host tuning
# (cgroup delegation, iptables modules, inotify) is needed any more.
set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$1"; }

OS="$(uname -s)"

if [ "$OS" = "Darwin" ]; then
  echo "== macOS: podman machine setup =="

  if ! command -v podman >/dev/null 2>&1; then
    yellow "podman not installed. Install it: brew install podman"
    exit 1
  fi

  if podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
    green "a podman machine already exists"
  else
    yellow "no podman machine yet. Create one with enough headroom for k3s:"
    echo "    podman machine init --cpus 4 --memory 8192 --disk-size 50"
  fi

  if podman machine inspect --format '{{.State}}' 2>/dev/null | grep -qi running; then
    green "podman machine is running"
  else
    yellow "start the machine: podman machine start"
  fi

  # The machine MUST be rootful. k3s runs a kubelet in-container, which needs the
  # cpuset cgroup controller; a rootless podman machine does not delegate it, and
  # k3s dies with "failed to find cpuset cgroup (v2)".
  ROOTFUL=$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null | head -1 || echo "")
  if echo "$ROOTFUL" | grep -qi true; then
    green "podman machine is rootful (required for k3s)"
  else
    yellow "podman machine is NOT rootful. k3s needs this. Switch it:"
    echo "    podman machine stop"
    echo "    podman machine set --rootful"
    echo "    podman machine start"
  fi

  green "macOS setup check complete. Then: make preflight"
  exit 0
fi

echo "== Linux: rootless podman setup =="

# User podman socket is only needed if you later re-enable container-socket log
# discovery. The demo ships file-based logging, so this is optional.
if systemctl --user enable --now podman.socket 2>/dev/null; then
  green "podman user socket enabled (optional)"
else
  yellow "could not enable podman.socket (optional; file-based logging needs no socket)"
fi

if podman info 2>/dev/null | grep -q 'cgroupVersion: v2'; then
  green "cgroup v2 present"
else
  yellow "cgroup v2 not detected. k3s-in-container needs it; boot with"
  yellow "  systemd.unified_cgroup_hierarchy=1 on most distros."
fi

# k3s in a privileged rootless container needs these kernel modules on the host.
yellow "if k3s networking fails, load kernel modules (sudo):"
cat <<'EOF'
    printf 'overlay\nbr_netfilter\niptable_nat\nip6table_nat\n' | sudo tee /etc/modules-load.d/k3s.conf
    sudo modprobe overlay br_netfilter iptable_nat ip6table_nat
EOF

green "Linux setup check complete. Then: make preflight"
