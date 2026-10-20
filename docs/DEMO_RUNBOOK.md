# Presenter Runbook — Boundary End to End

Four acts, roughly 20 minutes. The through-line for the bank: every path to a
sensitive system runs through Boundary, every credential is short-lived and
brokered by Vault, and every action is recorded. Nobody holds a standing key to
production.

Open these tabs before you start:

| Surface | URL | Login |
|---------|-----|-------|
| PAM portal | http://localhost:8080 | none (demo) |
| Grafana audit dashboard | http://localhost:3000 | anonymous viewer |
| Boundary UI / CLI / Desktop | http://localhost:9200 | admin / BoundaryDemo123! (global scope); dana, pam-operator (bank-demo org) |
| MinIO console | http://localhost:9001 | minioadmin |

Authenticate your CLI as the engineer first. The auth method id and target ids come
from `terraform output`:

```bash
export BOUNDARY_ADDR=http://localhost:9200
boundary authenticate password \
  -auth-method-id $(terraform -chdir=terraform output -raw auth_method_id) \
  -login-name dana
```

Session recordings replay in the Boundary admin UI (`http://localhost:9200`, log in
at the global scope as `admin` / `BoundaryDemo123!`) or in the Boundary Desktop app
pointed at the same address, and they list from the CLI with
`boundary session-recordings` / `make recordings`. This is a self-managed controller,
so the UI is the embedded one it serves itself, not a hosted HCP console.

---

## Act 1 — Identity-based SSH, fully recorded

**Point:** the engineer never has a key, a password, or the host's address.

```bash
boundary connect ssh -target-id $(cd terraform && terraform output -raw dev_jump_target_id)
```

Talk track while the session is live:
- No credential was typed. Boundary asked Vault to sign a certificate good for five
  minutes and injected it. The engineer authenticated as a person, not a shared account.
- Run a couple of commands in the session (`hostname`, `cat /etc/motd`, `ls /`) so the
  recording has something to show.
- Close the session (`exit`).

Now open the recording in the Boundary admin UI (`http://localhost:9200`, log in as
`admin` at the global scope) or in Boundary Desktop pointed at the same address and
play it back, or list it with `make recordings`. The whole session replays, keystrokes
and output. That is the control a bank's auditors ask for.

**Name the human, from Boundary alone.** This is the customer's CyberArk-plus-host-log
problem solved:

```bash
make recordings
```

Each recording carries the user and target captured when the session opened. The host
only ever saw `appuser`, but Boundary's record names `dana`, because `dana` is who
authenticated. No timestamp join, no inference. Read one recording and resolve the user:

```bash
boundary session-recordings read -id <sr_...>
boundary users read -id <u_...>
```

**Brokering vs injection.** Connect to Postgres to show the other mode:

```bash
boundary connect postgres -target-id $(cd terraform && terraform output -raw postgres_target_id) -dbname demo
```

Boundary hands the credential to the client and drops you into `psql`. The user sees it.
That is brokering, which Community Edition can do. The SSH target injected instead, and
the user never saw the secret. That gap is the enterprise line.

---

## Act 2 — Kubernetes through Boundary

**Point:** same model for the cluster. No kubeconfig on the laptop, token lasts minutes.

```bash
make kube
# or explicitly:  scripts/connect-kube.sh <k8s-target-id> get pods -n payments
```

`make kube` authorizes the session (Boundary brokers a Vault-minted token), opens the
proxy, and runs `kubectl get pods -n payments` with that token. (The wrapper hands the
token to kubectl itself — plain `boundary connect kube` doesn't extract it from a generic
Vault credential, so it would connect unauthenticated.)

Talk track:
- Boundary proxied kubectl to the cluster API. Vault minted a service-account token
  scoped to get/list/watch in the `payments` namespace, good for ten minutes.
- Try something out of scope to show the guardrail:
  ```bash
  make kube ARGS="$(cd terraform && terraform output -raw k8s_target_id) delete pods --all -n payments"
  ```
  The token's RBAC denies it. Least privilege, enforced by the cluster, brokered by Vault.

---

## Act 3 — Just-in-time privileged access

**Point:** when the engineer needs production, they ask, someone approves, access opens
for a fixed window, and it closes on its own.

1. In the CLI, try production. It is denied, because `dana` holds no grant for it:
   ```bash
   boundary connect ssh -target-id $(cd terraform && terraform output -raw prod_jump_target_id)
   # -> error: you are not authorized
   ```
2. Open the **PAM portal**. Click **New request**. Target `prod-payments-jump`, paste a
   change-ticket number as the justification, pick a short window (5 minutes shows well).
   Submit. The request lands in **Pending approval**.
3. Switch hats to the approver. Open the request, read the justification, click **Approve**.
   Behind that click the portal calls Boundary and adds `dana` to the
   `jit-privileged-access` role. The drawer starts a live countdown.
4. Back in the CLI, the same command now works — and **leave the session open** on screen
   (sit in a shell on the prod host). This is the moment that sells the next step.
   ```bash
   boundary connect ssh -target-id <prod id>
   # now sitting at a prompt on prod-payments-jump — leave it here
   ```
   This session is also recorded.
5. Let the window elapse (or narrate it). When the countdown hits zero the portal does two
   things, in order: it **cancels Dana's live session** — the open shell from step 4 drops
   right in front of the audience, mid-keystroke — and then removes `dana` from the role so
   no new session can start. Try production again: denied. No one touched it by hand; the
   change window closed itself, and it took the in-flight session with it.

Open the request's **Audit timeline** in the drawer: raised, approved, Boundary access
granted, Boundary access revoked — the revoke line names how many live sessions were
cancelled ("cancelled 1 live session(s)") — each with who and when.

> **Why this matters, and why it is not automatic out of the box.** Removing the grant only
> stops *new* sessions; Boundary authorizes a session at connect time and does not retroact
> on one already open. Closing that gap is a deliberate step the customer wires into their
> own PAM automation — see the callout below.

---

## Act 3a — What the customer must wire up (say this out loud)

The self-closing window is two mechanisms working together, and a bank replacing this demo
portal with their real PAM/ITSM integration has to reproduce **both**. Call it out so no one
leaves thinking "remove the role" is sufficient.

1. **Cancel sessions on revoke, don't just drop the grant.** The revoke path must list the
   principal's live sessions on the target and `cancel` each one, then remove the grant. In
   this demo that is `BoundaryClient.cancel_engineer_sessions()` in
   `pam-app/backend/boundary.py`, called from `revoke()`. In the field it is the equivalent
   call from whatever runs the revoke — a ServiceNow workflow, a scheduled job, a Terraform
   step. The raw API is `GET /v1/sessions` (filter to the user + target, non-terminated) then
   `POST /v1/sessions/{id}:cancel` with the session `version`; on the CLI,
   `boundary sessions cancel -id <id>`.
2. **Grant the automation identity the rights to do it.** Cancelling someone else's session
   needs `type=session;actions=list,read,cancel` (not `cancel:self`) on the identity the
   automation authenticates as. This demo adds it to the `pam-operator` role in
   `terraform/auth.tf`. Without this grant the cancel call returns 403 and the window closes
   on paper only.
3. **Keep the target max-duration as a backstop.** `prod-payments-jump` sets
   `session_max_seconds = 1800` (`terraform/targets-ssh.tf`). Even if the revoke automation
   never fires — portal down, workflow stuck — no session on that target can outlive 30
   minutes. Set this at or below the longest window the customer will ever grant; it is the
   guardrail that holds when the active cancel does not. HashiCorp's own guidance is to
   always set a maximum session duration to cap how long a compromised session can live.

The distinction to land: **the backstop (#3) is a Boundary target setting; the precise
cut at window close (#1 + #2) is customer automation.** The demo shows both so the bank
sees the difference between "access expires eventually" and "access ends now."

---

## Act 4 — The audit picture

Three surfaces, one question answered three ways: who did what, when.

1. **Session recording** (Act 1 and the prod session): the literal record of what was
   typed on the host. Replayable in Boundary Desktop, stored in MinIO.
2. **Grafana dashboard** (http://localhost:3000, "Who Did What, When"): the PAM event
   stream, grant-vs-revoke over time, Vault's credential brokering, and the worker's
   session activity, all in one place. This is the feed a SOC watches.
3. **Per-ticket timeline** (PAM portal): the request-to-revoke chain for a single change.

**Retention.** The recordings carry a storage policy (`make up` sets a seven-day window
by default, `recording_retention_days` in Terraform). Boundary resolves policies top down
from global through orgs, so a bank can mandate a floor that a lower scope cannot loosen.

Closing line for the bank: standing access to production is gone. Access is an event
with a name on it, a reason, an approval, a clock, and a recording. That is what
"who is doing what, and when" looks like when you can actually answer it.

---

## Reset between runs

```bash
# soft reset: clear PAM requests only
rm -f pam-app/data/requests.json pam-app/data/audit.jsonl && podman compose restart pam-app

# full teardown
make clean
```

---

## Operational notes (host vs container, re-runs)

- **Host CLI vs containers use different addresses for the same services.** On your Mac,
  `export BOUNDARY_ADDR=http://localhost:9200` for the `boundary` CLI. Inside the compose
  network the controller is `boundary:9200` and the worker proxy is published to the host
  at `localhost:9202` (set as the worker's `public_addr`). The PAM app's controller address
  is fixed to `http://boundary:9200` in compose, independent of your shell's `BOUNDARY_ADDR`.
- **Bringing the stack up fresh is the happy path:** `make up` from a clean state does
  everything (DB init, controller, worker PKI enrollment + auto-approval, k3s, Vault, MinIO,
  Terraform, PAM wiring). `boundary-init` now detects an already-running controller and skips,
  so re-running `make up` against a live stack is safe.
- **Changing code against a running stack:** recreate only the affected service, e.g.
  `podman compose up -d --no-deps --force-recreate worker`. Avoid recreating the controller
  and worker together while the DB holds their enrolled identities; prefer `make clean && make up`
  for a clean slate.
- **Unpacking a new build:** extract into a fresh directory (copy your `.env` across) rather
  than over a running tree — podman bind-mounts files by inode, so overwriting a mounted file
  in place leaves running containers pointing at the old one until they're recreated.
