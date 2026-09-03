import json
import tempfile
import time
import unittest
from pathlib import Path
from urllib.request import Request, urlopen

from tools.motion.gmgn_motion_service import MotionGenerationService, create_http_server

from tools.motion.tests.test_gmgn_motion_factory import sample_spec


class MotionGenerationServiceTests(unittest.TestCase):
    def test_wraps_the_listener_with_the_supplied_tls_context(self) -> None:
        class RecordingTLSContext:
            def __init__(self) -> None:
                self.wrapped_socket = None

            def wrap_socket(self, socket, *, server_side: bool):
                self.wrapped_socket = socket
                self.server_side = server_side
                return socket

        with tempfile.TemporaryDirectory() as temporary:
            service = MotionGenerationService(
                output_root=Path(temporary),
                public_base_url="https://100.110.226.64:8765",
                generate_spec=lambda *_args: sample_spec(),
            )
            tls_context = RecordingTLSContext()
            server = create_http_server(
                "127.0.0.1",
                0,
                service,
                tls_context=tls_context,
            )
            try:
                self.assertIs(tls_context.wrapped_socket, server.socket)
                self.assertTrue(tls_context.server_side)
            finally:
                server.server_close()
                service.close()

    def test_starts_with_an_empty_downloadable_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            service = MotionGenerationService(
                output_root=root,
                public_base_url="http://127.0.0.1:8765",
                generate_spec=lambda *_args: sample_spec(),
            )
            server = create_http_server("127.0.0.1", 0, service)
            thread = __import__("threading").Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with urlopen(
                    f"http://127.0.0.1:{server.server_port}/catalog.json",
                    timeout=2,
                ) as response:
                    catalog = json.load(response)
                self.assertEqual(catalog, {"schemaVersion": 1, "motions": []})
                self.assertEqual(json.loads((root / "catalog.json").read_text()), catalog)
            finally:
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()
                service.close()

    def test_accepts_an_explicit_motion_spec_without_contacting_ardy(self) -> None:
        generator_calls = []

        def generate(*args) -> dict:
            generator_calls.append(args)
            raise AssertionError("explicit specs must bypass ARDY")

        with tempfile.TemporaryDirectory() as temporary:
            service = MotionGenerationService(
                output_root=Path(temporary),
                public_base_url="http://127.0.0.1:8765",
                generate_spec=generate,
            )
            try:
                accepted = service.submit(
                    {
                        "prompt": "wave with the right hand",
                        "name": "Right Hand Wave",
                        "format": "vmd",
                        "motionSpec": sample_spec(),
                    }
                )
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    job = service.status(accepted["jobID"])
                    if job["status"] in {"succeeded", "failed"}:
                        break
                    time.sleep(0.01)
                self.assertEqual(job["status"], "succeeded", job)
                self.assertEqual(generator_calls, [])
                self.assertEqual(job["motions"][0]["source"]["generator"]["engine"], "motion-spec")
            finally:
                service.close()

    def test_http_api_accepts_a_job_and_serves_its_download(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            service = MotionGenerationService(
                output_root=Path(temporary),
                public_base_url="http://127.0.0.1:8765",
                generate_spec=lambda *_args: sample_spec(),
            )
            server = create_http_server("127.0.0.1", 0, service)
            thread = __import__("threading").Thread(target=server.serve_forever, daemon=True)
            thread.start()
            origin = f"http://127.0.0.1:{server.server_port}"
            try:
                request = Request(
                    f"{origin}/api/v1/motions",
                    data=json.dumps({"prompt": "wave", "format": "vmd"}).encode(),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urlopen(request, timeout=2) as response:
                    self.assertEqual(response.status, 202)
                    accepted = json.load(response)

                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    with urlopen(f"{origin}{accepted['statusURL']}", timeout=2) as response:
                        job = json.load(response)
                    if job["status"] == "succeeded":
                        break
                    time.sleep(0.01)
                self.assertEqual(job["status"], "succeeded")
                with urlopen(f"{origin}/catalog.json", timeout=2) as response:
                    catalog = json.load(response)
                self.assertEqual(catalog["motions"][0]["id"], job["motions"][0]["id"])
                with urlopen(f"{origin}/{job['motions'][0]['path']}", timeout=2) as response:
                    self.assertTrue(response.read().startswith(b"Vocaloid Motion Data 0002"))
            finally:
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()
                service.close()

    def test_submits_an_async_job_and_publishes_downloadable_pmx_motion(self) -> None:
        requests = []

        def generate(
            prompt: str,
            duration: float | None,
            seed: int | None,
            waypoints: list[dict[str, float]],
        ) -> dict:
            requests.append({
                "prompt": prompt,
                "duration": duration,
                "seed": seed,
                "waypoints": waypoints,
            })
            return sample_spec()

        with tempfile.TemporaryDirectory() as temporary:
            service = MotionGenerationService(
                output_root=Path(temporary),
                public_base_url="http://127.0.0.1:8765",
                generate_spec=generate,
            )
            try:
                accepted = service.submit(
                    {
                        "prompt": "dance while stirring a pot",
                        "name": "Kitchen Stir Dance",
                        "duration": 8,
                        "seed": 17,
                        "waypoints": [
                            {"x": 0.5, "z": 1.0},
                            {"x": -0.25, "z": 2.0},
                        ],
                        "format": "vmd",
                        "activityIDs": ["cooking.stir", "music.dance"],
                        "strideSpeed": 0.9,
                        "playbackRate": 1.25,
                        "inPlace": True,
                    }
                )
                self.assertEqual(accepted["status"], "queued")
                self.assertEqual(accepted["statusURL"], f"/api/v1/motions/{accepted['jobID']}")
                self.assertEqual(
                    accepted["catalogURL"],
                    "http://127.0.0.1:8765/catalog.json",
                )

                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    job = service.status(accepted["jobID"])
                    if job["status"] in {"succeeded", "failed"}:
                        break
                    time.sleep(0.01)
                else:
                    self.fail("generation job did not finish")

                self.assertEqual(job["status"], "succeeded", job)
                self.assertEqual(requests, [{
                    "prompt": "dance while stirring a pot",
                    "duration": 8.0,
                    "seed": 17,
                    "waypoints": [
                        {"x": 0.5, "z": 1.0},
                        {"x": -0.25, "z": 2.0},
                    ],
                }])
                motion = job["motions"][0]
                self.assertEqual(motion["format"], "vmd")
                self.assertEqual(motion["avatarFormats"], ["pmx"])
                self.assertEqual(motion["strideSpeed"], 0.9)
                self.assertEqual(motion["playbackRate"], 1.25)
                self.assertTrue(motion["inPlace"])
                self.assertEqual(
                    motion["downloadURL"],
                    f"http://127.0.0.1:8765/{motion['path']}",
                )
                self.assertTrue((Path(temporary) / motion["path"]).is_file())
                catalog = json.loads((Path(temporary) / "catalog.json").read_text())
                self.assertEqual(catalog["motions"][0]["id"], motion["id"])
            finally:
                service.close()

    def test_explicit_loop_request_overrides_the_generator_metadata(self) -> None:
        generated_spec = sample_spec()
        generated_spec["loop"] = False

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            service = MotionGenerationService(
                output_root=root,
                public_base_url="http://127.0.0.1:8765",
                generate_spec=lambda *_args: generated_spec,
            )
            try:
                accepted = service.submit({"prompt": "natural walk", "loop": True})
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    job = service.status(accepted["jobID"])
                    if job["status"] in {"succeeded", "failed"}:
                        break
                    time.sleep(0.01)

                self.assertEqual(job["status"], "succeeded", job)
                self.assertTrue(job["motions"][0]["loop"])
                catalog = json.loads((root / "catalog.json").read_text())
                self.assertTrue(catalog["motions"][0]["loop"])
            finally:
                service.close()

    def test_rejects_invalid_requests_before_starting_a_job(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            service = MotionGenerationService(
                output_root=Path(temporary),
                public_base_url="http://127.0.0.1:8765",
                generate_spec=lambda *_args: sample_spec(),
            )
            try:
                for payload in (
                    {},
                    {"prompt": "   "},
                    {"prompt": "wave", "format": "fbx"},
                    {"prompt": "wave", "duration": 0},
                    {"prompt": "wave", "activityIDs": ["ok", 7]},
                    {"prompt": "walk", "waypoints": "not-a-list"},
                    {"prompt": "walk", "waypoints": [{}]},
                    {"prompt": "walk", "waypoints": [{"x": 30, "z": 0}]},
                    {"prompt": "walk", "loop": "yes"},
                ):
                    with self.subTest(payload=payload):
                        with self.assertRaises(ValueError):
                            service.submit(payload)
            finally:
                service.close()

    def test_reports_generation_failure_without_publishing_a_partial_catalog(self) -> None:
        def fail(*_args) -> dict:
            raise RuntimeError("generator unavailable")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            service = MotionGenerationService(
                output_root=root,
                public_base_url="http://127.0.0.1:8765",
                generate_spec=fail,
            )
            try:
                accepted = service.submit({"prompt": "wave"})
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    job = service.status(accepted["jobID"])
                    if job["status"] == "failed":
                        break
                    time.sleep(0.01)
                self.assertEqual(job["status"], "failed")
                self.assertIn("generator unavailable", job["error"])
                self.assertEqual(
                    json.loads((root / "catalog.json").read_text()),
                    {"schemaVersion": 1, "motions": []},
                )
            finally:
                service.close()


if __name__ == "__main__":
    unittest.main()
