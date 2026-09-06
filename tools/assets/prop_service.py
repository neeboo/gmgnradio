"""Private, bounded image-to-prop jobs. No user-supplied Comfy graph or paths."""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
import uuid
import fcntl
import stat
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError

MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_BODY_BYTES = 12 * 1024 * 1024
TERMINAL = {"completed", "failed", "cancelled", "interrupted"}


class APIError(Exception):
    def __init__(self, code, status=400):
        self.code, self.status = code, status
        super().__init__(code)


class RootLease:
    """Acquire before opening/recovering a job store; release on process exit."""
    def __init__(self, root):
        self.root, self.fd = Path(root), None

    def __enter__(self):
        self.root.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(self.root / "service.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.fd); self.fd = None
            raise RuntimeError("service_already_running") from None
        return self

    def __exit__(self, *args):
        os.close(self.fd); self.fd = None


def validate_request(data):
    allowed = {"image_base64", "name", "source", "height_meters"}
    if not isinstance(data, dict) or set(data) != allowed:
        raise APIError("invalid_fields")
    name = data["name"]
    if not isinstance(name, str) or not 1 <= len(name) <= 100 or any(c in name for c in "/\\\x00"):
        raise APIError("invalid_name")
    source = data["source"]
    if (not isinstance(source, dict) or set(source) != {"license", "author"}
            or any(not isinstance(v, str) or not 1 <= len(v) <= 200 for v in source.values())):
        raise APIError("source_required")
    height = data["height_meters"]
    if isinstance(height, bool) or not isinstance(height, (float, int)) or not math.isfinite(height) or not 0.01 <= height <= 3:
        raise APIError("invalid_height")
    try:
        encoded = data["image_base64"]
        if not isinstance(encoded, str) or len(encoded) > MAX_BODY_BYTES:
            raise ValueError()
        image = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError):
        raise APIError("invalid_image") from None
    if not 24 <= len(image) <= MAX_IMAGE_BYTES or not image.startswith(b"\x89PNG\r\n\x1a\n"):
        raise APIError("png_required")
    width, height_px = int.from_bytes(image[16:20], "big"), int.from_bytes(image[20:24], "big")
    if not 1 <= width <= 2048 or not 1 <= height_px <= 2048:
        raise APIError("image_dimensions_exceeded")
    return image


class JobStore:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        for directory in ("inputs", "outputs"):
            (self.root / directory).mkdir(exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(self.root / "jobs.sqlite3", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, idem TEXT UNIQUE, digest TEXT, state TEXT, data TEXT, prompt_id TEXT, reason TEXT, result TEXT, created REAL, updated REAL)")
        self.db.commit()

    def close(self):
        self.db.close()

    def _row(self, job_id):
        if not isinstance(job_id, str) or not re.fullmatch(r"[0-9a-f]{32}", job_id):
            raise APIError("job_not_found", 404)
        row = self.db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        if row is None:
            raise APIError("job_not_found", 404)
        return row

    def _public(self, row):
        data = json.loads(row["data"])
        return dict(id=row["id"], state=row["state"], reason=row["reason"], name=data["name"],
                    source=data["source"], height_meters=data["height_meters"],
                    result=json.loads(row["result"]) if row["result"] else None,
                    compute_may_continue=row["state"] in {"cancel_requested", "interrupted"},
                    created_at=row["created"], updated_at=row["updated"])

    def submit(self, key, data):
        if not isinstance(key, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,100}", key):
            raise APIError("idempotency_key_required")
        image = validate_request(data)
        digest = hashlib.sha256(json.dumps(data, sort_keys=True, allow_nan=False).encode()).hexdigest()
        with self.lock:
            row = self.db.execute("SELECT * FROM jobs WHERE idem=?", (key,)).fetchone()
            if row:
                if row["digest"] != digest:
                    raise APIError("idempotency_conflict", 409)
                return self._public(row)
            count = self.db.execute("SELECT count(*) FROM jobs WHERE state NOT IN ('completed','failed','cancelled','interrupted')").fetchone()[0]
            if count >= 8:
                raise APIError("queue_full", 429)
            job_id, now = uuid.uuid4().hex, time.time()
            (self.root / "inputs" / f"{job_id}.png").write_bytes(image)
            metadata = {k: v for k, v in data.items() if k != "image_base64"}
            self.db.execute("INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?,?)", (job_id, key, digest, "queued", json.dumps(metadata), None, None, None, now, now))
            self.db.commit()
            return self.get(job_id)

    def get(self, job_id):
        with self.lock:
            return self._public(self._row(job_id))

    def claim(self):
        with self.lock:
            row = self.db.execute("SELECT * FROM jobs WHERE state='queued' ORDER BY created LIMIT 1").fetchone()
            if row is None:
                return None
            self.update(row["id"], state="preflight")
            return self.get(row["id"])

    def update(self, job_id, **fields):
        if set(fields) - {"state", "prompt_id", "reason", "result"}:
            raise ValueError("unknown update")
        if "result" in fields:
            fields["result"] = json.dumps(fields["result"])
        with self.lock:
            self._row(job_id)
            fields["updated"] = time.time()
            self.db.execute("UPDATE jobs SET " + ",".join(k + "=?" for k in fields) + " WHERE id=?", (*fields.values(), job_id))
            self.db.commit()

    def cancel(self, job_id):
        with self.lock:
            row = self._row(job_id)
            if row["state"] not in TERMINAL:
                self.update(job_id, state="cancelled" if row["state"] in {"queued", "waiting_resources"} else "cancel_requested")
            return self.get(job_id)

    def recover(self):
        with self.lock:
            # No remote request occurs in this state, so preserving the queue is safe.
            self.db.execute("UPDATE jobs SET state='queued', updated=? WHERE state='waiting_resources'", (time.time(),))
            self.db.execute("UPDATE jobs SET state='interrupted', reason='service_restarted_no_resubmit', updated=? WHERE state NOT IN ('queued','completed','failed','cancelled','interrupted')", (time.time(),))
            self.db.commit()


def make_server(store, token, host="127.0.0.1", port=8191, readiness=None):
    if host != "127.0.0.1" or not token:
        raise ValueError("private_loopback_and_token_required")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # No request bodies, query strings, or bearer secrets in logs.

        def reply(self, status, result):
            body = json.dumps(result, allow_nan=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers(); self.wfile.write(body)

        def handle_request(self):
            try:
                if self.headers.get("Origin"):
                    raise APIError("browser_origin_forbidden", 403)
                if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token):
                    raise APIError("unauthorized", 401)
                path = urlsplit(self.path)
                if path.query or path.fragment:
                    raise APIError("unknown_route", 404)
                parts = path.path.strip("/").split("/")
                if self.command == "GET" and parts == ["health"]:
                    return self.reply(200, {"status": "api_ready", "generation": readiness() if readiness else {"ready": False, "reason": "worker_not_configured"}})
                if self.command == "GET" and len(parts) == 3 and parts[:2] == ["v1", "jobs"]:
                    return self.reply(200, store.get(parts[2]))
                if self.command == "GET" and len(parts) == 4 and parts[:2] == ["v1", "jobs"] and parts[3] == "model.glb":
                    job = store.get(parts[2])
                    if job["state"] != "completed":
                        raise APIError("artifact_not_ready", 409)
                    artifact = store.root / "outputs" / (job["id"] + ".glb")
                    body = artifact.read_bytes()
                    self.send_response(200)
                    self.send_header("Content-Type", "model/gltf-binary")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Content-Disposition", 'attachment; filename="model.glb"')
                    self.end_headers(); self.wfile.write(body)
                    return
                if self.command != "POST":
                    raise APIError("unknown_route", 404)
                if self.headers.get("Content-Type") != "application/json" or self.headers.get("Transfer-Encoding"):
                    raise APIError("json_required", 415)
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    raise APIError("invalid_length") from None
                if not 1 <= length <= MAX_BODY_BYTES:
                    raise APIError("body_too_large", 413)
                self.connection.settimeout(10)
                data = json.loads(self.rfile.read(length))
                if parts == ["v1", "jobs"]:
                    return self.reply(202, store.submit(self.headers.get("Idempotency-Key"), data))
                if len(parts) == 4 and parts[:2] == ["v1", "jobs"] and parts[3] == "cancel" and data == {}:
                    return self.reply(200, store.cancel(parts[2]))
                raise APIError("unknown_route", 404)
            except APIError as error:
                self.reply(error.status, {"error": error.code})
            except (ValueError, TimeoutError):
                self.reply(400, {"error": "invalid_request"})
            except Exception:
                self.reply(500, {"error": "internal_error"})

        do_GET = handle_request
        do_POST = handle_request

    return ThreadingHTTPServer((host, port), Handler)


class JobWorker:
    """One remote prompt at a time; lost submit responses are never retried."""
    observation_timeout_seconds = 2 * 60 * 60

    def __init__(self, store, backend, *, clock=time.monotonic, observation_timeout_seconds=None):
        self.store, self.backend, self.active = store, backend, None
        self.clock, self.observation_started = clock, None
        if observation_timeout_seconds is not None:
            self.observation_timeout_seconds = observation_timeout_seconds

    def tick(self):
        if self.active is None:
            job = self.store.claim()
            if job is None:
                return
            self.active = job["id"]
            self.observation_started = None
        job_id = self.active
        job = self.store.get(job_id)
        if job["state"] in TERMINAL:
            self.active = None
            return
        if job["state"] in {"preflight", "waiting_resources"}:
            readiness = self.backend.readiness()
            if not readiness["ready"]:
                with self.store.lock:
                    if self.store.get(job_id)["state"] in {"cancelled", "cancel_requested"}:
                        self.store.update(job_id, state="cancelled")
                        self.active = None
                    else:
                        self.store.update(job_id, state="waiting_resources", reason=readiness["reason"])
                return
            # Make cancellation and the submit boundary atomic to local API calls.
            with self.store.lock:
                if self.store.get(job_id)["state"] in {"cancelled", "cancel_requested"}:
                    self.store.update(job_id, state="cancelled")
                    self.active = None
                    return
                self.store.update(job_id, state="submitting", reason=None)
            try:
                prompt_id = self.backend.submit(job_id, self.store.root / "inputs" / f"{job_id}.png")
                self.observation_started = self.clock()
                with self.store.lock:
                    cancelled = self.store.get(job_id)["state"] == "cancel_requested"
                    self.store.update(job_id, prompt_id=prompt_id, state="cancel_requested" if cancelled else "remote_pending")
            except APIError as error:
                self.store.update(job_id, state="failed", reason=error.code)
            except Exception:
                self.store.update(job_id, state="interrupted", reason="submission_uncertain_no_retry")
            return
        with self.store.lock:
            prompt_id = self.store._row(job_id)["prompt_id"]
        if not prompt_id:
            self.store.update(job_id, state="interrupted", reason="missing_remote_id_no_retry")
            return
        if self.observation_started is not None and self.clock() - self.observation_started >= self.observation_timeout_seconds:
            self.store.update(job_id, state="interrupted", reason="remote_observation_timeout_no_retry")
            self.active = None
            return
        try:
            status = self.backend.status(prompt_id)
        except Exception:
            self.store.update(job_id, reason="remote_status_unavailable")
            return
        observed_state = status["state"]
        if observed_state == "completed":
            with self.store.lock:
                if self.store.get(job_id)["state"] == "cancel_requested":
                    self.store.update(job_id, state="cancelled", reason="remote_finished_after_cancel")
                    return
            try:
                result = self.backend.collect(job, status, self.store.root / "outputs" / f"{job_id}.glb")
                with self.store.lock:
                    if self.store.get(job_id)["state"] == "cancel_requested":
                        self.store.update(job_id, state="cancelled", reason="remote_finished_after_cancel")
                    else:
                        self.store.update(job_id, state="completed", reason=None, result=result)
            except Exception:
                with self.store.lock:
                    cancelled = self.store.get(job_id)["state"] == "cancel_requested"
                    self.store.update(job_id, state="cancelled" if cancelled else "failed", reason="artifact_validation_failed")
        else:
            with self.store.lock:
                cancelled = self.store.get(job_id)["state"] == "cancel_requested"
                if observed_state == "failed":
                    self.store.update(job_id, state="cancelled" if cancelled else "failed", reason="generation_failed")
                elif not cancelled:
                    self.store.update(job_id, state=observed_state, reason=None)

    def run(self):
        while True:
            try:
                self.tick()
            except Exception:
                # Do not take down the read/cancel API on transient backend errors.
                if self.active:
                    self.store.update(self.active, reason="worker_observation_error")
            waiting = self.active and self.store.get(self.active)["state"] == "waiting_resources"
            time.sleep(30 if waiting else 3)


class ComfyBackend:
    """Only talks to the two operator-owned loopback Comfy instances."""
    def __init__(self, workflow_path, comfy_output, min_available_gib=24):
        source = Path(workflow_path).read_bytes()
        if hashlib.sha256(source).hexdigest() != "a4ffdea180901016255224df7e509f7db0fe2325f688a8c4376bf153dcf1b7a0":
            raise ValueError("untrusted_workflow")
        self.workflow = json.loads(source)
        self.output = Path(comfy_output).resolve()
        self.min_available_gib = min_available_gib

    def request_json(self, path, data=None, legacy=False):
        url = ("http://127.0.0.1:8188" if legacy else "http://127.0.0.1:8190") + path
        request = Request(url, data=json.dumps(data).encode() if data is not None else None,
                          headers={"Content-Type": "application/json"})
        with urlopen(request, timeout=15) as response:
            return json.load(response)

    def readiness(self):
        try:
            old_queue = self.request_json("/queue", legacy=True)
            if old_queue.get("queue_running") or old_queue.get("queue_pending"):
                return {"ready": False, "reason": "existing_comfy_busy"}
            queue = self.request_json("/queue")
            if queue.get("queue_running") or queue.get("queue_pending"):
                return {"ready": False, "reason": "prop_comfy_busy"}
            info = self.request_json("/object_info")
            missing = []
            for node in self.workflow["nodes"]:
                if node["id"] not in {15, 40, 117, 118, 193}:
                    continue
                choices = info.get(node["type"], {}).get("input", {}).get("required", {})
                filename = node["widgets_values"][0]
                def model_options(spec):
                    if isinstance(spec[0], list):
                        return spec[0]
                    if spec[0] == "COMBO" and len(spec) > 1:
                        return spec[1].get("options", [])
                    return []
                if not any(filename in model_options(spec) for spec in choices.values() if spec):
                    missing.append(filename)
            if missing:
                return {"ready": False, "reason": "models_missing", "missing_models": missing}
            memory = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines())
            available = int(memory["MemAvailable"].split()[0]) / 1024**2
            if available < self.min_available_gib:
                return {"ready": False, "reason": "shared_memory_busy", "available_gib": round(available, 1), "minimum_gib": self.min_available_gib}
            return {"ready": True, "available_gib": round(available, 1), "profile": "trellis2-prop-low-v1"}
        except Exception:
            return {"ready": False, "reason": "backend_unavailable"}

    def submit(self, job_id, image_path):
        from PIL import Image
        from workflow_adapter import build_prompt
        try:
            with Image.open(image_path) as image:
                image.verify()
        except Exception:
            raise APIError("invalid_png") from None
        info = self.request_json("/object_info")
        boundary = "gmgn" + secrets.token_hex(16)
        filename = job_id + ".png"
        body = ((f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{filename}\"\r\nContent-Type: image/png\r\n\r\n").encode()
                + image_path.read_bytes() + f"\r\n--{boundary}--\r\n".encode())
        request = Request("http://127.0.0.1:8190/upload/image", data=body,
                          headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
        with urlopen(request, timeout=30) as response:
            uploaded = json.load(response)
        if uploaded.get("name") != filename or uploaded.get("subfolder", "") != "":
            raise APIError("unexpected_upload_name")
        prompt = build_prompt(self.workflow, info, image_name=filename, seed=42, output_prefix="props/" + job_id)
        try:
            result = self.request_json("/prompt", {"prompt": prompt, "client_id": "gmgn-prop-" + job_id})
        except HTTPError as error:
            # Comfy validation 400 means no execution accepted. Other failures may be ambiguous.
            if error.code == 400:
                raise APIError("workflow_validation_failed") from None
            raise
        if not isinstance(result.get("prompt_id"), str):
            raise RuntimeError("missing_remote_id")
        return result["prompt_id"]

    def status(self, prompt_id):
        history = self.request_json("/history/" + prompt_id)
        if prompt_id in history:
            record = history[prompt_id]
            if record.get("status", {}).get("status_str") == "error":
                return {"state": "failed"}
            if record.get("status", {}).get("completed"):
                result = record.get("outputs", {}).get("322", {}).get("result", [])
                if result and isinstance(result[0], str):
                    return {"state": "completed", "filename": result[0]}
                return {"state": "failed"}
        queue = self.request_json("/queue")
        if any(item[1] == prompt_id for item in queue.get("queue_running", [])):
            return {"state": "running"}
        if any(item[1] == prompt_id for item in queue.get("queue_pending", [])):
            return {"state": "remote_pending"}
        raise RuntimeError("remote_prompt_not_observable")

    def collect(self, job, status, destination):
        from glb_inspect import inspect_glb
        filename = status["filename"]
        if not re.fullmatch(r"props/" + job["id"] + r"_[0-9]+\.glb", filename):
            raise ValueError("artifact_path_not_owned")
        max_bytes = 32 * 1024 * 1024
        # Open every untrusted path component without following links. Read once,
        # then validate and publish that private snapshot, not the mutable source.
        root_fd = os.open(self.output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            props_fd = os.open("props", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
            try:
                source_fd = os.open(filename.split("/")[1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=props_fd)
            finally:
                os.close(props_fd)
        finally:
            os.close(root_fd)
        with os.fdopen(source_fd, "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > max_bytes:
                raise ValueError("artifact_size_or_type")
            data = source.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise ValueError("artifact_size_exceeded")
        fd, temporary_name = tempfile.mkstemp(prefix=job["id"]+"-", suffix=".glb.partial", dir=destination.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(data); output.flush(); os.fsync(output.fileno())
            inspection = inspect_glb(temporary, max_bytes=max_bytes, max_triangles=22000)
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
        return {"model_url": "/v1/jobs/" + job["id"] + "/model.glb", "inspection": inspection,
                "source": job["source"], "suggested_height_meters": job["height_meters"],
                "scale_requires_confirmation": True, "affordance_candidates": ["inspect", "place"],
                "interaction_bindings": [], "interaction_status": "unbound",
                "workflow_profile": "trellis2-prop-low-v1"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--workflow", type=Path, required=True)
    parser.add_argument("--comfy-output", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if not args.token_file.exists():
        args.token_file.write_text(secrets.token_urlsafe(32) + "\n")
    os.chmod(args.token_file, 0o600)
    token = args.token_file.read_text().strip()
    with RootLease(args.root):
        store = JobStore(args.root)
        backend = ComfyBackend(args.workflow, args.comfy_output)
        worker = JobWorker(store, backend)
        server = make_server(store, token, readiness=backend.readiness)
        store.recover()
        threading.Thread(target=worker.run, daemon=True).start()
        server.serve_forever()


if __name__ == "__main__":
    main()
