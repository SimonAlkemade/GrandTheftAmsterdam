"""A small client for Tripo's image-to-3D API (https://platform.tripo3d.ai).

Reads the key from TRIPO_API_KEY. Not yet exercised against the live
service (it was unreachable from the build machine): endpoints and fields
follow Tripo's v2 OpenAPI documentation and should be checked on the first
real call.
"""
from __future__ import annotations

import os
import time

import requests

API = "https://api.tripo3d.ai/v2/openapi"


class OutOfCredits(Exception):
    """Tripo refused work because the account balance is used up."""


class TripoError(Exception):
    pass


def _credit_problem(status: int, body: dict) -> bool:
    text = str(body).lower()
    return status in (402, 403) and any(w in text for w in ("credit", "balance", "insufficient", "quota"))


class Tripo:
    def __init__(self, key: str | None = None, session: requests.Session | None = None):
        self.key = key or os.environ.get("TRIPO_API_KEY", "")
        if not self.key:
            raise TripoError("TRIPO_API_KEY is not set")
        self.http = session or requests.Session()
        self.http.headers["Authorization"] = "Bearer " + self.key

    def _check(self, r: requests.Response) -> dict:
        try:
            body = r.json()
        except ValueError:
            body = {"text": r.text[:300]}
        if _credit_problem(r.status_code, body):
            raise OutOfCredits(str(body))
        if r.status_code >= 400 or body.get("code", 0) != 0:
            raise TripoError("%s %s" % (r.status_code, body))
        return body.get("data", {})

    def balance(self) -> float:
        return float(self._check(self.http.get(API + "/user/balance", timeout=30)).get("balance", 0))

    def upload(self, jpg_path: str) -> str:
        with open(jpg_path, "rb") as fh:
            d = self._check(self.http.post(API + "/upload", files={"file": (os.path.basename(jpg_path), fh, "image/jpeg")}, timeout=120))
        return d["image_token"]

    def image_to_model(self, token: str) -> str:
        d = self._check(self.http.post(API + "/task", json={"type": "image_to_model", "file": {"type": "jpg", "file_token": token}}, timeout=60))
        return d["task_id"]

    def wait(self, task_id: str, timeout: float = 900, poll: float = 5) -> dict:
        t0 = time.time()
        while time.time() - t0 < timeout:
            d = self._check(self.http.get(API + "/task/" + task_id, timeout=30))
            status = d.get("status")
            if status == "success":
                return d
            if status in ("failed", "cancelled", "unknown", "banned", "expired"):
                raise TripoError("task %s %s" % (task_id, status))
            time.sleep(poll)
        raise TripoError("task %s timed out" % task_id)

    @staticmethod
    def model_url(task: dict) -> str:
        out = task.get("output", {})
        for k in ("pbr_model", "model", "base_model"):
            if out.get(k):
                return out[k]
        raise TripoError("no model in %s" % out)
