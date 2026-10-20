# Boundary End-to-End Demo

A fully self-contained, containerised demo for a regulated bank. A self-managed
**Boundary Enterprise** controller runs in a container (no cloud dependency), with
identity-based access to SSH hosts and Kubernetes, credential brokering with Vault,
full SSH session recording, and a just-in-time privileged-access workflow driven
from a ServiceNow-style portal. Audit runs through everything.

Read `ARCHITECTURE.md` for the design and the decisions behind it.
Read `docs/DEMO_RUNBOOK.md` for the presenter walkthrough.

## What you get

- **SSH** to a Linux host with no key and no password. Boundary injects a
  Vault-signed certificate that lives for five minutes. The session is recorded and
  replayable.
- **Kubernetes** access with `make kube`, which authorizes a Boundary session and
  hands kubectl a short-lived, Vault-minted service-account token. No kubeconfig on
  the laptop. (The wrapper exists because plain `boundary connect kube` does not pull
  the token out of a generic Vault credential; the wiring through Boundary and Vault
  is identical.)
- **Just-in-time PAM**: an engineer requests production access, an approver signs
  off, Boundary opens the target for a fixed window, and the grant removes itself
  when the window closes.
- **Attribution**: `make recordings` names the human behind each session straight
  from Boundary, replacing the CyberArk-plus-host-log stitching a bank does by hand.
- **Brokering contrast**: a Postgres target brokers its credential (the user sees it)
  next to the SSH target that injects (the user never does). That gap is the
  enterprise line.
- **Three audit surfaces**: Boundary session-recording playback, a Grafana
  dashboard of access events, and a per-ticket audit timeline in the portal, plus a
  retention policy on the recordings.

## Prerequisites

The runtime is **podman** (`podman compose`), the same on macOS and Linux. The
Kubernetes cluster is **k3s running as a compose service**, so there is no separate
cluster tool to install and nothing to wire by hand. On the host you need `podman`
(4.1+, for the `podman compose` subcommand), `terraform`, the `boundary` CLI, `jq`,
and `curl`. `kubectl` is not required; the demo drives k3s through `podman exec`.

**macOS.** podman runs inside a Linux VM (the podman machine). Create one with
enough headroom for k3s, and make it **rootful** — k3s runs a kubelet in-container
that needs the cpuset cgroup controller, which a rootless machine does not delegate
(k3s dies with `failed to find cpuset cgroup (v2)` otherwise):

```bash
brew install podman
podman machine init --cpus 4 --memory 8192 --disk-size 50
podman machine set --rootful
podman machine start
make setup       # checks the machine and prints anything still needed
```

On a Mac this is a negligible security change: podman is already a VM with no daemon
on your host, and nothing on the host runs the containers. If you created the machine
without `--rootful`, switch it with `podman machine stop && podman machine set
--rootful && podman machine start`.

Run the demo from a path under your home directory, which the podman machine shares
into the VM, so the compose bind mounts resolve.

**Linux.** `make setup` checks cgroup v2 and prints the one or two kernel modules
k3s may need. On SELinux-enforcing hosts the compose file already tags writable
binds with `:z`.

You need a **Boundary Enterprise license** (free trial from HashiCorp). Session
recording and credential injection are Enterprise features; the controller reads
the license from `BOUNDARY_LICENSE` in `.env`. That one string is the only input
the demo needs — everything else runs locally and offline.

## Quick start

```bash
make setup     # one-time host prep (see Prerequisites)
cp .env.example .env
# paste your Boundary Enterprise license into BOUNDARY_LICENSE
# (the other defaults work as-is for a local demo)

make up        # see the bring-up below
make demo      # print the presenter runbook
```

`make up` runs the bring-up in order: Postgres, `boundary database init`, the
self-managed controller, then Vault, MinIO, k3s, the worker and the targets. The
worker registers by **PKI worker-led registration**: it boots, persists its node key
to disk, and prints an auth token that `scripts/register-worker.sh` approves with the
recovery KMS key. A recording worker needs a stable on-disk identity, which a KMS
worker cannot give it, so the demo uses PKI here rather than a shared worker-auth key.
Terraform then authenticates to the fresh controller through the same **recovery KMS
key** and provisions the scopes, auth method, accounts, credential stores, targets,
storage bucket and roles. Creating the storage bucket runs through
controller-to-worker command routing, so `make up` retries `terraform apply` up to
three times while the worker's reverse connection settles. Last, `make up` writes the
generated auth-method id into `.env` and recreates the PAM app so it can sign in.

Then open:

- PAM portal: http://localhost:8080
- Boundary UI / API: http://localhost:9200 — log in at the **global** scope as `admin` / `BoundaryDemo123!` (the demo accounts `dana` and `pam-operator` live in the `bank-demo` org, so pick that scope to sign in as them)
- Grafana: http://localhost:3000
- MinIO console: http://localhost:9001
- Vault UI: http://localhost:8200 (token: `root` in demo mode)

## Commands

| Command | What it does |
|---------|--------------|
| `make setup` | One-time podman host prep (the podman machine on macOS) |
| `make preflight` | Check the tools, the podman engine and `.env`, including the license |
| `make up` | Full bring-up: controller, worker, k3s, Vault, MinIO, targets, Terraform |
| `make demo` | Print the presenter runbook |
| `make kube` | Reach the Kubernetes target through Boundary with a Vault-minted token. Pass other kubectl verbs as `make kube ARGS="get ns"` |
| `make recordings` | List session recordings and the human behind each |
| `make logs` | Tail every container log |
| `make down` | Stop containers, keep the data |
| `make clean` | `terraform destroy`, then remove every container and volume |

`make up` is re-runnable against a live stack: `boundary-init` no-ops once the
controller is healthy, and the compose steps use `--no-deps` so a partial bring-up
picks up where it stopped.

## Teardown

```bash
make down      # stop containers, keep volumes
make clean     # terraform destroy + remove containers and volumes (everything)
```

`make clean` removes the entire stack, including the Boundary controller and its
Postgres state. Nothing persists outside your machine.

## How the pieces fit

```
   ┌──────────────────────────── one podman compose project ────────────────────────────┐
   │  Boundary controller (Enterprise)  ──state──▶  Postgres (boundary-db)               │
   │        │  authorizes + brokers                                                       │
   │   self-managed worker  ──records──▶  MinIO (S3)                                      │
   │        │  proxies + injects (PKI worker-led join)                                    │
   │   ┌────┴─────────────┬──────────────┐                                               │
   │  SSH host          k3s service     Vault (SSH + K8s secrets engines)                │
   │                                     │                                               │
   │   PAM portal ──Boundary API──▶ jit-privileged-access role                           │
   │        │                                                                             │
   │   Grafana / Loki / Promtail  ◀── structured log files (Vault, worker, PAM)          │
   └──────────────────────────────────────────────────────────────────────────────────┘
```

## Known demo-grade shortcuts

These favour a clean spin-up over production posture. The runbook and
`ARCHITECTURE.md` call them out:

- The controller runs with static AEAD KMS keys committed in `boundary/controller.hcl`
  (clearly marked demo-only) and its API listener has TLS disabled. In production the
  keys live in a real KMS and the API runs on TLS.
- Vault runs in dev mode with a known root token.
- MinIO credential rotation is disabled on the storage bucket.
- The demo uses one worker and one controller. No HA.
- k3s runs as a single privileged container, not a multi-node cluster. Fine for the
  access demo; not a production cluster shape. It needs a rootful podman machine on
  macOS (see Prerequisites) because the kubelet requires the cpuset cgroup.

## Layout

```
ARCHITECTURE.md   design + decisions
docs/             presenter runbook
Makefile          setup / up / down / demo / clean
compose.yml       the whole stack incl. controller + k3s (podman compose)
boundary/         controller HCL, KMS keys, database-init script
worker/           self-managed worker HCL (PKI worker-led join + events file sink)
vault/            secrets-engine + policy bootstrap
minio/            bucket bootstrap (boto3)
targets/ssh/      Linux sshd target image
terraform/        Boundary provisioning (recovery-KMS bootstrap)
pam-app/          ServiceNow-styled portal (FastAPI + HTML)
observability/    Loki, Promtail (file tailing), Grafana dashboard
scripts/          setup, preflight, setup-cluster, register-worker, wait-for-*, connect-kube, set-pam-env, demo
presentation/     boundary-e2e.html — the dark deck (open in a browser)
assets/logos/     HashiCorp, Vault, Terraform, Boundary marks
```

## Presentation

`presentation/boundary-e2e.html` is a self-contained dark deck: what/why/concepts/
architecture, the Community-vs-Enterprise table, the audit & compliance chapter, and the
Kubernetes and PAM chapters, closing on the demo map. Open it in any browser. Arrow
keys or click to navigate, `n` for speaker notes, `f` for fullscreen. Fonts load from
Google Fonts when online, with system fallbacks offline.
