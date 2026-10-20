"""PAM portal backend.

A request moves PENDING -> APPROVED -> EXPIRED (or -> DENIED). On approval the
portal opens prod access in Boundary and schedules an automatic revoke at the end
of the window. Every transition writes an audit line that Grafana reads and the
per-ticket timeline renders.

State lives in a JSON file so a container restart does not lose open requests, and
on startup the portal reconciles anything whose window already closed.
"""
from __future__ import annotations

import asyncio
import json
import os
import uuid
from datetime import datetime, timezone, timedelta
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from boundary import BoundaryClient, BoundaryError

DATA_DIR = Path(os.environ.get("PAM_DATA_DIR", "/var/log/pam"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
STORE = DATA_DIR / "requests.json"
AUDIT = Path(os.environ.get("PAM_AUDIT_LOG", str(DATA_DIR / "audit.jsonl")))
FRONTEND = Path(__file__).resolve().parent.parent / "frontend"

app = FastAPI(title="ServiceDesk PAM", docs_url=None, redoc_url=None)
boundary = BoundaryClient()
_requests: dict[str, dict] = {}
_lock = asyncio.Lock()


# ------------------------------------------------------------------ helpers
def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def audit(request_id: str, actor: str, action: str, detail: str = "") -> None:
    line = {"ts": now(), "request_id": request_id, "actor": actor,
            "action": action, "detail": detail, "service": "pam-portal"}
    with AUDIT.open("a") as fh:
        fh.write(json.dumps(line) + "\n")


def save() -> None:
    STORE.write_text(json.dumps(list(_requests.values()), indent=2))


def load() -> None:
    if STORE.exists():
        for r in json.loads(STORE.read_text()):
            _requests[r["id"]] = r


# ------------------------------------------------------------------ models
class NewRequest(BaseModel):
    requester: str = "dana"
    target: str = "prod-payments-jump"
    reason: str
    window_minutes: int = 15


class Decision(BaseModel):
    approver: str = "sam (approver)"


# ------------------------------------------------------------------ lifecycle
@app.on_event("startup")
async def startup() -> None:
    load()
    try:
        boundary.resolve()
        audit("-", "pam-portal", "startup", "resolved Boundary role/user/target")
    except BoundaryError as e:
        audit("-", "pam-portal", "startup-warning", str(e))
    # Reconcile windows that closed while we were down, then arm timers for the rest.
    for r in _requests.values():
        if r["status"] == "APPROVED":
            exp = datetime.fromisoformat(r["expires_at"])
            if exp <= datetime.now(timezone.utc):
                await _expire(r["id"], reason="reconcile-on-startup")
            else:
                asyncio.create_task(_revoke_at(r["id"], exp))


# ------------------------------------------------------------------ core transitions
async def _revoke_at(req_id: str, when: datetime) -> None:
    delay = (when - datetime.now(timezone.utc)).total_seconds()
    if delay > 0:
        await asyncio.sleep(delay)
    await _expire(req_id, reason="window-elapsed")


async def _expire(req_id: str, reason: str) -> None:
    async with _lock:
        r = _requests.get(req_id)
        if not r or r["status"] != "APPROVED":
            return
        try:
            result = boundary.revoke()
            r["status"] = "EXPIRED"
            r["revoked_at"] = now()
            n = len(result.get("cancelled_sessions", []))
            detail = f"{reason}; removed {r['requester']} from jit-privileged-access"
            detail += (f"; cancelled {n} live session(s)" if n
                       else "; no live sessions to cancel")
            audit(req_id, "pam-portal", "access-revoked", detail)
        except BoundaryError as e:
            audit(req_id, "pam-portal", "revoke-error", str(e))
        save()


# ------------------------------------------------------------------ API
@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/api/requests")
def list_requests():
    return sorted(_requests.values(), key=lambda r: r["created_at"], reverse=True)


@app.post("/api/requests")
async def create_request(body: NewRequest):
    req_id = "REQ" + uuid.uuid4().hex[:8].upper()
    r = {
        "id": req_id,
        "requester": body.requester,
        "target": body.target,
        "reason": body.reason,
        "window_minutes": body.window_minutes,
        "status": "PENDING",
        "created_at": now(),
        "approver": None,
        "decided_at": None,
        "granted_at": None,
        "expires_at": None,
        "revoked_at": None,
    }
    async with _lock:
        _requests[req_id] = r
        save()
    audit(req_id, body.requester, "request-raised",
          f"target={body.target} window={body.window_minutes}m reason={body.reason}")
    return r


@app.post("/api/requests/{req_id}/approve")
async def approve(req_id: str, body: Decision):
    async with _lock:
        r = _requests.get(req_id)
        if not r:
            raise HTTPException(404, "no such request")
        if r["status"] != "PENDING":
            raise HTTPException(409, f"request is {r['status']}")
        try:
            boundary.grant()
        except BoundaryError as e:
            audit(req_id, body.approver, "grant-error", str(e))
            raise HTTPException(502, f"Boundary grant failed: {e}")
        start = datetime.now(timezone.utc)
        exp = start + timedelta(minutes=r["window_minutes"])
        r.update(status="APPROVED", approver=body.approver, decided_at=now(),
                 granted_at=now(), expires_at=exp.isoformat())
        save()
    audit(req_id, body.approver, "request-approved",
          f"granted {r['requester']} access to {r['target']} until {r['expires_at']}")
    audit(req_id, "pam-portal", "access-granted",
          f"added {r['requester']} to jit-privileged-access in Boundary")
    asyncio.create_task(_revoke_at(req_id, exp))
    return r


@app.post("/api/requests/{req_id}/deny")
async def deny(req_id: str, body: Decision):
    async with _lock:
        r = _requests.get(req_id)
        if not r:
            raise HTTPException(404, "no such request")
        if r["status"] != "PENDING":
            raise HTTPException(409, f"request is {r['status']}")
        r.update(status="DENIED", approver=body.approver, decided_at=now())
        save()
    audit(req_id, body.approver, "request-denied", f"denied access to {r['target']}")
    return r


@app.get("/api/requests/{req_id}/timeline")
def timeline(req_id: str):
    if not AUDIT.exists():
        return []
    events = []
    for line in AUDIT.read_text().splitlines():
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("request_id") == req_id:
            events.append(e)
    return events


@app.get("/api/audit")
def all_audit():
    if not AUDIT.exists():
        return []
    out = []
    for line in AUDIT.read_text().splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out[-200:]


# ------------------------------------------------------------------ frontend
app.mount("/static", StaticFiles(directory=FRONTEND / "static"), name="static")


@app.get("/")
def index():
    return FileResponse(FRONTEND / "index.html")
