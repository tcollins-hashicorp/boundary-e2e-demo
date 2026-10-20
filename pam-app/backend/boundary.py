"""Thin Boundary API client for the PAM portal.

The portal holds no standing Boundary rights of its own beyond an admin token it
uses to add and remove one principal from one role. Everything it does is an
auditable Boundary API call.
"""
from __future__ import annotations

import os
import httpx


class BoundaryError(RuntimeError):
    pass


class BoundaryClient:
    def __init__(self) -> None:
        self.addr = os.environ["BOUNDARY_ADDR"].rstrip("/")
        self.auth_method_id = os.environ["BOUNDARY_AUTH_METHOD_ID"]
        self.login_name = os.environ.get("BOUNDARY_ADMIN_LOGIN_NAME", "admin")
        self.password = os.environ["BOUNDARY_ADMIN_PASSWORD"]
        self._token: str | None = None
        self._client = httpx.Client(base_url=self.addr, timeout=20.0)

        # Resolved once, lazily, by name so the portal is decoupled from Terraform
        # output ordering.
        self.jit_role_id: str | None = None
        self.engineer_user_id: str | None = None
        self.prod_target_id: str | None = None

    # -- auth -----------------------------------------------------------------
    def authenticate(self) -> None:
        r = self._client.post(
            f"/v1/auth-methods/{self.auth_method_id}:authenticate",
            json={"attributes": {"login_name": self.login_name, "password": self.password}},
        )
        if r.status_code != 200:
            raise BoundaryError(f"auth failed: {r.status_code} {r.text}")
        body = r.json()
        token = body.get("attributes", {}).get("token") or body.get("token")
        if not token:
            raise BoundaryError(f"no token in auth response: {body}")
        self._token = token
        self._client.headers["Authorization"] = f"Bearer {token}"

    def _ensure_auth(self) -> None:
        if not self._token:
            self.authenticate()

    def _get(self, path: str, **params):
        self._ensure_auth()
        r = self._client.get(path, params=params)
        if r.status_code == 401:
            self.authenticate()
            r = self._client.get(path, params=params)
        r.raise_for_status()
        return r.json()

    def _post(self, path: str, payload: dict):
        self._ensure_auth()
        r = self._client.post(path, json=payload)
        if r.status_code == 401:
            self.authenticate()
            r = self._client.post(path, json=payload)
        if r.status_code >= 400:
            raise BoundaryError(f"{path} -> {r.status_code} {r.text}")
        return r.json()

    # -- discovery ------------------------------------------------------------
    def resolve(self) -> dict:
        """Find the JIT role, engineer user and prod target by name."""
        roles = self._get("/v1/roles", scope_id="global", recursive="true").get("items", [])
        users = self._get("/v1/users", scope_id="global", recursive="true").get("items", [])
        targets = self._get("/v1/targets", scope_id="global", recursive="true").get("items", [])

        self.jit_role_id = _find(roles, "jit-privileged-access")
        self.engineer_user_id = _find(users, os.environ.get("ENGINEER_LOGIN", "dana"))
        self.prod_target_id = _find(targets, "prod-payments-jump")

        missing = [k for k, v in {
            "jit role": self.jit_role_id,
            "engineer user": self.engineer_user_id,
            "prod target": self.prod_target_id,
        }.items() if not v]
        if missing:
            raise BoundaryError(f"could not resolve: {', '.join(missing)}. Run terraform apply first.")
        return {
            "jit_role_id": self.jit_role_id,
            "engineer_user_id": self.engineer_user_id,
            "prod_target_id": self.prod_target_id,
        }

    def _role_version(self) -> int:
        role = self._get(f"/v1/roles/{self.jit_role_id}")
        return role.get("version", 1)

    def role_principals(self) -> list[str]:
        role = self._get(f"/v1/roles/{self.jit_role_id}")
        return role.get("principal_ids", []) or []

    # -- the two actions that matter ------------------------------------------
    def grant(self) -> None:
        """Add the engineer to the JIT role. This is the moment prod access opens."""
        if self.engineer_user_id in self.role_principals():
            return
        self._post(
            f"/v1/roles/{self.jit_role_id}:add-principals",
            {"version": self._role_version(), "principal_ids": [self.engineer_user_id]},
        )

    def revoke(self) -> dict:
        """Close prod access: cancel live sessions, then remove the grant.

        Removing the principal from the role stops the engineer starting NEW
        sessions, but Boundary authorizes a session at connect time — it does not
        touch a session that is already open. An engineer who stays in their shell
        would keep working past the window. So we first cancel any in-flight
        sessions they hold against the prod target, then remove the grant. That is
        what makes "the window closed" mean the session ends, not merely that no
        new logins are allowed.

        Returns the ids of the sessions that were cancelled, for the audit line.
        """
        cancelled = self.cancel_engineer_sessions()
        if self.engineer_user_id in self.role_principals():
            self._post(
                f"/v1/roles/{self.jit_role_id}:remove-principals",
                {"version": self._role_version(), "principal_ids": [self.engineer_user_id]},
            )
        return {"cancelled_sessions": cancelled}

    # -- live-session teardown ------------------------------------------------
    def active_engineer_sessions(self) -> list[dict]:
        """Non-terminated sessions the engineer holds against the prod target.

        The list API returns only non-terminated sessions by default; we keep the
        ones that are still pending or active (a session already 'canceling' needs
        no second cancel).
        """
        items = self._get("/v1/sessions", scope_id="global", recursive="true").get("items", [])
        live = {"pending", "active"}
        return [
            s for s in items
            if s.get("user_id") == self.engineer_user_id
            and s.get("target_id") == self.prod_target_id
            and s.get("status") in live
        ]

    def cancel_engineer_sessions(self) -> list[str]:
        """Cancel every live prod session the engineer holds. Idempotent."""
        cancelled: list[str] = []
        for s in self.active_engineer_sessions():
            sid, ver = s.get("id"), s.get("version", 1)
            try:
                self._post(f"/v1/sessions/{sid}:cancel", {"version": ver})
                cancelled.append(sid)
            except BoundaryError:
                # Raced with the client disconnecting or a max-duration terminate;
                # the session is already going away, so treat it as done.
                pass
        return cancelled


def _find(items: list[dict], name: str) -> str | None:
    for it in items:
        if it.get("name") == name:
            return it.get("id")
    return None
