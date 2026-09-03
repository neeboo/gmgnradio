#!/usr/bin/env python3
"""Asynchronous HTTP API for generating and publishing gmgn radio motions."""

from __future__ import annotations

import argparse
import json
import math
import re
import ssl
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlparse

from tools.motion.gmgn_motion_factory import (
    ArdyClient,
    MotionSpecError,
    normalize_waypoints,
    publish_motion,
    validate_motion_spec,
)


GenerateSpec = Callable[[str, float | None, int | None, list[dict[str, float]]], dict[str, Any]]
_SLUG_COMPONENT = re.compile(r"[^a-z0-9]+")


def _now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _slug(value: str) -> str:
    normalized = _SLUG_COMPONENT.sub("-", value.lower()).strip("-")
    return normalized[:40] or "motion"


class MotionGenerationService:
    """Owns one generation queue and an immutable downloadable catalog."""

    def __init__(
        self,
        *,
        output_root: Path,
        public_base_url: str,
        generate_spec: GenerateSpec,
        generator: dict[str, Any] | None = None,
    ) -> None:
        parsed = urlparse(public_base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("public base URL must be HTTP or HTTPS")
        self.output_root = output_root.resolve()
        self.output_root.mkdir(parents=True, exist_ok=True)
        catalog_path = self.output_root / "catalog.json"
        try:
            with catalog_path.open("x", encoding="utf-8") as catalog_file:
                json.dump({"schemaVersion": 1, "motions": []}, catalog_file, indent=2)
                catalog_file.write("\n")
        except FileExistsError:
            pass
        self.public_base_url = public_base_url.rstrip("/")
        self.generate_spec = generate_spec
        self.generator = generator or {
            "engine": "ardy",
            "model": "ARDY-Core-RP-20FPS-Horizon40",
            "revision": "unknown",
        }
        self._jobs: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="gmgn-motion")

    @property
    def catalog_url(self) -> str:
        return f"{self.public_base_url}/catalog.json"

    def submit(self, raw: Any) -> dict[str, Any]:
        request = self._validate_request(raw)
        job_id = str(uuid.uuid4())
        accepted = {
            "jobID": job_id,
            "status": "queued",
            "statusURL": f"/api/v1/motions/{job_id}",
            "catalogURL": self.catalog_url,
            "createdAt": _now(),
        }
        with self._lock:
            self._jobs[job_id] = dict(accepted)
        self._executor.submit(self._run, job_id, request)
        return accepted

    def status(self, job_id: str) -> dict[str, Any]:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                raise KeyError(job_id)
            return json.loads(json.dumps(job, ensure_ascii=False))

    def close(self) -> None:
        self._executor.shutdown(wait=True, cancel_futures=False)

    def _validate_request(self, raw: Any) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise ValueError("request body must be a JSON object")
        prompt = raw.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            raise ValueError("prompt must not be empty")
        prompt = prompt.strip()
        motion_format = raw.get("format", "vmd")
        if motion_format not in {"vmd", "vrma"}:
            raise ValueError("format must be vmd or vrma")
        duration = raw.get("duration")
        if duration is not None:
            if isinstance(duration, bool) or not isinstance(duration, (int, float)):
                raise ValueError("duration must be a number")
            duration = float(duration)
            if not 0.1 <= duration <= 300.0:
                raise ValueError("duration must be between 0.1 and 300 seconds")
        seed = raw.get("seed")
        if seed is not None and (isinstance(seed, bool) or not isinstance(seed, int)):
            raise ValueError("seed must be an integer")
        loop = raw.get("loop")
        if loop is not None and not isinstance(loop, bool):
            raise ValueError("loop must be a boolean")
        stride_speed = raw.get("strideSpeed")
        if stride_speed is not None:
            if (
                isinstance(stride_speed, bool)
                or not isinstance(stride_speed, (int, float))
                or not math.isfinite(stride_speed)
                or stride_speed <= 0
            ):
                raise ValueError("strideSpeed must be a positive finite number")
            stride_speed = float(stride_speed)
        playback_rate = raw.get("playbackRate")
        if playback_rate is not None:
            if (
                isinstance(playback_rate, bool)
                or not isinstance(playback_rate, (int, float))
                or not math.isfinite(playback_rate)
                or playback_rate <= 0
                or playback_rate > 8
            ):
                raise ValueError("playbackRate must be within (0, 8]")
            playback_rate = float(playback_rate)
        in_place = raw.get("inPlace")
        if in_place is not None and not isinstance(in_place, bool):
            raise ValueError("inPlace must be a boolean")
        waypoints = normalize_waypoints(raw.get("waypoints"))
        activity_ids = raw.get("activityIDs", ["music.dance"])
        if (
            not isinstance(activity_ids, list)
            or not all(isinstance(item, str) and item.strip() for item in activity_ids)
        ):
            raise ValueError("activityIDs must contain non-empty strings")
        display_name = raw.get("name", prompt[:48])
        if not isinstance(display_name, str) or not display_name.strip():
            raise ValueError("name must not be empty")
        version = raw.get("version", "1.0.0")
        if not isinstance(version, str):
            raise ValueError("version must be a string")
        suffix = uuid.uuid4().hex[:8]
        motion_id = raw.get("id", f"gmgn.motion.generated.{_slug(prompt)}-{suffix}")
        if not isinstance(motion_id, str):
            raise ValueError("id must be a string")
        motion_spec = raw.get("motionSpec")
        if motion_spec is not None:
            motion_spec = validate_motion_spec(motion_spec)
        return {
            "prompt": prompt,
            "name": display_name.strip(),
            "duration": duration,
            "seed": seed,
            "loop": loop,
            "strideSpeed": stride_speed,
            "playbackRate": playback_rate,
            "inPlace": in_place,
            "waypoints": waypoints,
            "format": motion_format,
            "activityIDs": [item.strip() for item in activity_ids],
            "id": motion_id,
            "version": version,
            "motionSpec": motion_spec,
        }

    def _run(self, job_id: str, request: dict[str, Any]) -> None:
        self._update(job_id, status="running", startedAt=_now())
        try:
            explicit_spec = request["motionSpec"]
            spec = explicit_spec or self.generate_spec(
                request["prompt"],
                request["duration"],
                request["seed"],
                request["waypoints"],
            )
            if request["loop"] is not None:
                spec = dict(spec)
                spec["loop"] = request["loop"]
                spec = validate_motion_spec(spec)
            generator = self.generator if explicit_spec is None else {
                "engine": "motion-spec",
                "model": "codex-authored",
                "revision": "api-v1",
            }
            entry = publish_motion(
                spec=spec,
                output_root=self.output_root,
                motion_id=request["id"],
                display_name=request["name"],
                version=request["version"],
                activity_ids=request["activityIDs"],
                prompt=request["prompt"],
                seed=request["seed"],
                generator=generator,
                motion_format=request["format"],
                stride_speed=request["strideSpeed"],
                playback_rate=request["playbackRate"],
                in_place=request["inPlace"],
            )
            result = dict(entry)
            result["downloadURL"] = f"{self.public_base_url}/{entry['path']}"
            self._update(
                job_id,
                status="succeeded",
                finishedAt=_now(),
                motions=[result],
            )
        except Exception as error:
            self._update(
                job_id,
                status="failed",
                finishedAt=_now(),
                error=str(error),
            )

    def _update(self, job_id: str, **values: Any) -> None:
        with self._lock:
            self._jobs[job_id].update(values)


class _MotionRequestHandler(SimpleHTTPRequestHandler):
    server_version = "GMGNMotionService/1"

    def __init__(
        self,
        *args: Any,
        service: MotionGenerationService,
        api_token: str | None = None,
        **kwargs: Any,
    ) -> None:
        self.service = service
        self.api_token = api_token
        super().__init__(*args, directory=str(service.output_root), **kwargs)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._json(200, {"status": "ok", "catalogURL": self.service.catalog_url})
            return
        prefix = "/api/v1/motions/"
        if self.path.startswith(prefix):
            if not self._authorized():
                return
            job_id = self.path[len(prefix) :].split("?", 1)[0]
            try:
                self._json(200, self.service.status(job_id))
            except KeyError:
                self._json(404, {"error": "generation job not found"})
            return
        super().do_GET()

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/api/v1/motions":
            self._json(404, {"error": "endpoint not found"})
            return
        if not self._authorized():
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0 or content_length > 64 * 1024:
                raise ValueError("request body must be between 1 byte and 64 KiB")
            payload = json.loads(self.rfile.read(content_length))
            accepted = self.service.submit(payload)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError, MotionSpecError) as error:
            self._json(400, {"error": str(error)})
            return
        self._json(202, accepted)

    def log_message(self, format: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {format % args}")

    def _authorized(self) -> bool:
        if self.api_token is None:
            return True
        if self.headers.get("Authorization") == f"Bearer {self.api_token}":
            return True
        self._json(401, {"error": "missing or invalid bearer token"})
        return False

    def _json(self, status: int, value: Any) -> None:
        data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def create_http_server(
    host: str,
    port: int,
    service: MotionGenerationService,
    *,
    api_token: str | None = None,
    tls_context: Any | None = None,
) -> ThreadingHTTPServer:
    handler = partial(_MotionRequestHandler, service=service, api_token=api_token)
    server = ThreadingHTTPServer((host, port), handler)
    if tls_context is not None:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    return server


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="GMGN asynchronous motion generation API")
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--ardy-url")
    parser.add_argument("--preview-spec", type=Path)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--public-base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--api-token")
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--model", default="ARDY-Core-RP-20FPS-Horizon40")
    parser.add_argument("--revision", default="unknown")
    parser.add_argument("--tls-cert", type=Path)
    parser.add_argument("--tls-key", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if bool(args.ardy_url) == bool(args.preview_spec):
        raise SystemExit("provide exactly one of --ardy-url or --preview-spec")
    if args.ardy_url:
        client = ArdyClient(args.ardy_url, timeout=args.timeout)

        def generate(
            prompt: str,
            duration: float | None,
            seed: int | None,
            waypoints: list[dict[str, float]],
        ) -> dict[str, Any]:
            return client.generate(
                text=prompt,
                duration=duration,
                seed=seed,
                waypoints=waypoints,
            )

        generator = {"engine": "ardy", "model": args.model, "revision": args.revision}
    else:
        try:
            preview = json.loads(args.preview_spec.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise SystemExit(f"cannot load preview spec: {error}") from error

        def generate(
            _prompt: str,
            _duration: float | None,
            _seed: int | None,
            _waypoints: list[dict[str, float]],
        ) -> dict[str, Any]:
            return preview

        generator = {"engine": "motion-spec", "model": "preview-fixture", "revision": "local"}

    service = MotionGenerationService(
        output_root=args.output_root,
        public_base_url=args.public_base_url,
        generate_spec=generate,
        generator=generator,
    )
    if bool(args.tls_cert) != bool(args.tls_key):
        raise SystemExit("provide both --tls-cert and --tls-key")
    tls_context = None
    if args.tls_cert:
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
        tls_context.load_cert_chain(args.tls_cert, args.tls_key)
    server = create_http_server(
        args.host,
        args.port,
        service,
        api_token=args.api_token,
        tls_context=tls_context,
    )
    print(f"motion API: {args.public_base_url}/api/v1/motions")
    print(f"catalog: {service.catalog_url}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        server.server_close()
        service.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
