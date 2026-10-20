# Boundary End-to-End Demo — Architecture & Design

**Audience:** HashiCorp SE team demoing to a highly regulated bank.
**Status:** Stage 1 design + scaffold. Read the "Assumptions you can correct" section first.

---

## 1. What this demo proves

A single `make up` stands up a controlled-access plane where every path to a
sensitive system runs through Boundary, every credential is brokered by Vault,
and every action lands in an audit trail the bank can inspect. The storyline runs
top to bottom:

1. An engineer authenticates to Boundary and gets a passwordless SSH session to a
   Linux host. The full session is recorded and replayable.
2. The same engineer reaches a Kubernetes cluster through Boundary using
   `boundary connect kube`, with a short-lived service-account token minted by Vault.
3. The engineer needs elevated access they do not hold. They raise a request in a
   ServiceNow-style PAM portal. An approver signs off. Boundary grants the target
   for a fixed change window, then revokes it automatically when the window closes.
4. Throughout, three audit surfaces answer "who did what, when": Boundary session
   recording playback, a Grafana dashboard of access events, and a per-ticket
   timeline inside the PAM portal.

## 2. Why these choices

The bank cares about audit before anything else, and wants to spin the demo up and
tear it down on a laptop. Those two needs drove every decision below.

| Decision | Choice | Reason |
|----------|--------|--------|
| Container runtime | **podman** via `podman compose` | Daemonless, no root daemon. On macOS it runs in the podman machine VM; on Linux directly. Same compose file both ways. |
| Boundary deployment | **Self-managed Boundary Enterprise** controller in a container, on Postgres | Fully self-contained, no cloud dependency. Enterprise carries SSH targets, credential injection and session recording. Needs a license (free trial), read from `BOUNDARY_LICENSE`. |
| Worker join | **KMS worker auth** (shared worker-auth key) | The worker authenticates to the controller with a shared AEAD key. No activation token, no PKI handshake, deterministic for a demo. |
| Terraform bootstrap | **Recovery KMS** | TF authenticates to a freshly initialized controller with the recovery key, so it can provision everything with no pre-existing login. |
| Tear-down model | `terraform destroy` + `make clean` | Removes the provisioned Boundary resources and every container and volume, controller and its Postgres included. Nothing persists off the machine. |
| Credential broker | Vault in podman | SSH certificate signing for Linux, Kubernetes secrets engine for the cluster. Matches the on-site assumption that Vault is already in play. |
| Kubernetes | **k3s as a compose service** | Runs on the same network as everything else, reachable at `k3s:6443` by name. No cluster tool, no network join, no host kubectl. Identical on macOS and Linux, up and down with `podman compose`. Boundary workflow unchanged: `boundary connect kube` with a Vault-minted token. |
| Session recording store | MinIO (S3-compatible) in podman | Boundary records to MinIO; recordings replay in the Boundary admin UI. No cloud bucket to provision. |
| PAM portal | Custom FastAPI + HTML app, ServiceNow-styled | No external SaaS dependency. Tears down with the stack. Drives real Boundary grants through the API. |
| Audit dashboard | Grafana + Loki + Promtail (file tailing) | Promtail tails three structured log files (Vault audit, Boundary worker events, PAM audit) into one "who/what/when" view. No container socket, so it behaves the same on macOS and Linux. |

## 3. Component map

```
  ┌────────────── podman compose (one project; podman machine VM on macOS) ────────────────────────────┐
  │                                                                                                     │
  │   ┌──────────────────────┐   ┌─────────────────────┐   ┌──────────────────────┐                    │
  │   │ Boundary controller  │◄──│ boundary-db         │   │ Observability        │                    │
  │   │ Enterprise + KMS     │   │ (Postgres state)    │   │ Grafana / Loki /     │                    │
  │   │ api/cluster/ops      │   └─────────────────────┘   │ Promtail (tails logs)│                    │
  │   └───┬──────────────┬───┘                             └──────────▲───────────┘                    │
  │       │ cluster      │ api (9200)                                 │ log files                       │
  │       │ (KMS join)   ├───────────────┬─────────────────┐         │ (vault, worker, pam)            │
  │   ┌───▼──────────────▼─┐   ┌──────────▼──────────┐   ┌──┴────────────────────┐                      │
  │   │ Self-managed worker│   │ PAM portal          │   │ (worker events sink) │                      │
  │   │ egress+inject+rec  │   │ request→approve→    │   └──────────────────────┘                      │
  │   │ BSR → MinIO        │   │ grant→auto-revoke   │                                                  │
  │   └───┬───────────┬────┘   └─────────────────────┘                                                  │
  │       │ ssh       │ k8s (k3s:6443)                                                                   │
  │   ┌───▼────┐  ┌───▼────────┐   ┌────────────────────┐   ┌──────────────────────┐                    │
  │   │ ssh    │  │ k3s        │   │ Vault              │   │ MinIO (S3)           │                    │
  │   │ target │  │ service    │◄──┤ ssh + kubernetes   │   │ boundary-recordings  │                    │
  │   │ (sshd) │  │ (k8s API)  │   │ secrets engines    │   │ bucket               │                    │
  │   └────────┘  └────────────┘   └────────────────────┘   └──────────────────────┘                    │
  │                                                                                                     │
  └─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 4. Data flows

### 4.1 SSH with recording
1. Engineer runs `boundary connect ssh -target-id <ssh target>`.
2. The self-managed controller authorizes the session and routes it to the worker.
3. Worker asks Vault's SSH secrets engine to sign a short-lived certificate.
4. Worker injects the certificate, opens the session to the sshd container, and
   records the session to local disk in BSR format.
5. On disconnect the worker syncs the recording to the MinIO bucket.
6. An auditor replays the session in the Boundary admin UI.

### 4.2 Kubernetes
1. Engineer runs `boundary connect kube -target-id <k8s target> -- get pods`.
2. The controller authorizes and routes to the worker.
3. Vault's Kubernetes secrets engine mints a short-lived service-account token scoped
   to the requested role.
4. Worker proxies kubectl to the k3s service (`k3s:6443`) using the injected token.
5. The session and the Vault lease both expire on a short TTL.

### 4.3 Just-in-time PAM
1. Engineer opens the PAM portal and raises a request: target, reason, window length.
2. The request sits in an approval queue. The portal records who asked and when.
3. An approver signs off. The portal records who approved and when.
4. On approval the portal calls the Boundary API to add the engineer to the role that
   grants the target, and schedules a revoke job for the end of the window.
5. When the window closes the portal **cancels the engineer's live sessions on the target
   and then removes the grant**, and records the revoke (including how many sessions were
   cancelled). Removing the grant alone would only block new sessions — see 4.4.
6. Every state change writes a structured audit line that Grafana picks up, and the
   per-ticket timeline in the portal shows the full chain.

### 4.4 Ending a window: grant removal vs. session teardown

This is the subtlety the bank will probe, and the part they must wire into their own
PAM/ITSM integration — it is not free out of the box.

- **Boundary authorizes a session at connect time.** Removing the principal from the
  `jit-privileged-access` role stops the engineer starting *new* sessions, but does not
  reach into a session already open. An engineer who stays in their shell would keep
  working past the window.
- **So the revoke path does two things, in order:** list the engineer's non-terminated
  sessions against the prod target and `cancel` each (`POST /v1/sessions/{id}:cancel`, or
  `boundary sessions cancel`), then remove the grant. See
  `BoundaryClient.cancel_engineer_sessions()` in `pam-app/backend/boundary.py`, called from
  `revoke()`.
- **The automation identity needs the rights.** Cancelling someone else's session requires
  `type=session;actions=list,read,cancel` (not `cancel:self`) on the account the automation
  runs as — added to the `pam-operator` role in `terraform/auth.tf`. Without it the cancel
  returns 403 and the window closes on paper only.
- **A target max-duration is the backstop.** `prod-payments-jump` sets
  `session_max_seconds = 1800` (`terraform/targets-ssh.tf`): even if the revoke automation
  never fires, no session on that target outlives 30 minutes. The active cancel is the
  precise cut at window close; the max-duration is the guardrail that holds when the cut
  doesn't. Set it at or below the longest window ever granted.

The runbook (Act 3a) states this as a customer-wiring callout for the live demo.

## 5. Repository layout

```
boundary-e2e-demo/
├── README.md                 Runbook: prerequisites, up, demo, down
├── ARCHITECTURE.md           This file
├── Makefile                  up / down / demo / clean / logs
├── .env.example              License + demo drop-ins (copy to .env)
├── compose.yml               The whole stack incl. controller + k3s (podman compose)
├── boundary/                 Controller HCL, KMS keys, database-init script
├── worker/                   Self-managed worker HCL (KMS join + events file sink)
├── vault/                    Bootstrap + policies (ssh + kubernetes engines)
├── minio/                    Recording bucket bootstrap (boto3)
├── targets/ssh/              Linux sshd target image
├── terraform/                Boundary provisioning (recovery-KMS bootstrap)
├── pam-app/                  ServiceNow-styled portal (backend + frontend)
├── observability/            Loki, Promtail, Grafana dashboards
├── scripts/                  setup, preflight, setup-cluster, wait-for-controller, demo
└── docs/                     DEMO_RUNBOOK.md presenter script
```

## 6. Assumptions you can correct

I made these calls to keep moving. Each one is cheap to change. Tell me if any is wrong.

- **Self-managed Boundary Enterprise** controller runs in a container on Postgres.
  Terraform provisions it through the recovery KMS key; nothing is created in the cloud.
  You supply a Boundary Enterprise license (free trial) in `.env`.
- **PAM backend is Python / FastAPI.** Easy to read, easy to swap. It authenticates to
  the local controller as a scoped `pam-operator` account and drives grants over the API.
- **SSH credential injection uses Vault SSH certificates**, not static keys. Closer to
  what the bank should run.
- **k3s runs as a compose service**, not via a cluster tool (kind/k3d/minikube). This
  sidesteps podman-machine networking on macOS entirely: Vault and the worker reach it
  at `k3s:6443` on the compose network. Same Boundary workflow either way.
- **Audit dashboard aggregates structured log files** (Vault audit device, Boundary
  worker events, PAM audit), tailed by Promtail with no container socket. A production
  deployment would also stream controller audit events to a SIEM; the runbook notes that.
- **One org, two projects** in Boundary: `core-infrastructure` (SSH + K8s) and a scope
  the PAM flow grants into. Adjustable.

## 7. What you need to provide

- A **Boundary Enterprise license** (free trial from HashiCorp) in `.env`. That is the
  only input; everything else runs locally and offline.
- HashiCorp logo SVGs are already included under `assets/logos/`.

## 8. Built, beyond the first scaffold

- **Presentation deck** at `presentation/boundary-e2e.html`: dark theme, animated flow
  diagrams, real HashiCorp logos. Covers the full self-managed arc including the
  Kubernetes and PAM chapters. Download and run locally.
- **Self-managed controller + KMS worker join**: controller on Postgres, worker joins
  with a shared worker-auth KMS key, Terraform bootstraps via recovery KMS. No HCP.
- **Postgres brokering target** for the brokering-vs-injection contrast, and a
  **storage-retention policy** on recordings.

## Still out of scope

- Real ServiceNow integration. The portal mimics the look and the flow.
- Production hardening (TLS everywhere, secret rotation, HA workers). The demo favours
  readability over production posture, and the runbook says so.
