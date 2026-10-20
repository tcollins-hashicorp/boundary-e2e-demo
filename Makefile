# Boundary end-to-end demo control surface. Fully self-contained: a self-managed
# Boundary Enterprise controller runs in a container, no cloud dependency.
# Runtime is podman (podman compose); the cluster is k3s as a compose service.

SHELL := /bin/bash
COMPOSE := podman compose
TF := terraform -chdir=terraform

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Boundary E2E demo (self-managed, podman)"
	@echo "  make setup       One-time podman host prep (podman machine on macOS)"
	@echo "  make preflight   Check prerequisites and .env (incl. license)"
	@echo "  make up          Full bring-up (controller, worker, k3s, terraform)"
	@echo "  make demo        Print the presenter runbook"
	@echo "  make recordings  List session recordings and the human behind each"
	@echo "  make logs        Tail all container logs"
	@echo "  make down        Stop containers (keep data)"
	@echo "  make clean       Remove containers, volumes, and provisioned resources"

.PHONY: setup
setup:
	@bash scripts/rootless-setup.sh

.PHONY: preflight
preflight:
	@bash scripts/preflight.sh

.PHONY: up
up: preflight
	@echo "==> 1/6 Boundary database"
	$(COMPOSE) up -d --no-deps boundary-db
	@bash scripts/wait-for-db.sh
	@echo "==> 2/6 Initialize the schema (must finish before the controller starts)"
	@bash scripts/init-boundary.sh
	@echo "==> 3/6 Controller"
	$(COMPOSE) up -d --no-deps --build boundary
	@bash scripts/wait-for-controller.sh
	@echo "==> 4/6 Vault, MinIO, k3s, worker, targets, PAM, observability"
	$(COMPOSE) up -d --no-deps --build \
	    vault vault-bootstrap minio minio-bootstrap k3s \
	    worker pam-app ssh-target postgres-target loki promtail grafana
	@bash scripts/wait-for-bootstraps.sh
	@bash scripts/setup-cluster.sh
	@bash scripts/register-worker.sh
	@bash scripts/wait-for-worker.sh
	@echo "==> 5/6 Provisioning Boundary (recovery KMS): scopes, targets, creds, roles"
	$(TF) init -input=false
	@# Retry apply: the storage bucket is created via controller->worker command
	@# routing, and the worker's reverse connection can still be settling on the
	@# first attempt. terraform is idempotent, so a retry only creates what's left.
	@for i in 1 2 3; do \
	  echo "[terraform] apply attempt $$i of 3..."; \
	  if $(TF) apply -auto-approve; then echo "[terraform] apply complete."; break; fi; \
	  if [ $$i -eq 3 ]; then echo "[terraform] apply still failing after 3 attempts."; exit 1; fi; \
	  echo "[terraform] retrying in 25s (worker command-routing may still be settling)..."; \
	  sleep 25; \
	done
	@echo "==> 6/6 Wiring the PAM portal"
	@bash scripts/set-pam-env.sh
	@echo ""
	@echo "Up. Run 'make demo' for the walkthrough."
	@echo "  PAM portal       http://localhost:8080"
	@echo "  Boundary API     http://localhost:9200"
	@echo "  Grafana          http://localhost:3000"
	@echo "  MinIO console    http://localhost:9001"
	@echo "  Vault UI         http://localhost:8200"

.PHONY: demo
demo:
	@cat docs/DEMO_RUNBOOK.md

.PHONY: kube
kube:
	@bash scripts/connect-kube.sh $(ARGS)

.PHONY: recordings
recordings:
	@podman exec boundary boundary session-recordings list \
	    -recovery-config /boundary/controller.hcl -scope-id global -recursive || true
	@echo ""
	@echo "Read one:   boundary session-recordings read -id <sr_...>"
	@echo "Replay:     Boundary Desktop/Admin UI against http://localhost:9200"

.PHONY: logs
logs:
	$(COMPOSE) logs -f

.PHONY: down
down:
	$(COMPOSE) down

.PHONY: destroy
destroy:
	$(TF) destroy -auto-approve || true

.PHONY: clean
clean: destroy
	$(COMPOSE) down -v
	@echo "Clean. Containers, volumes and provisioned resources gone."
