"""Hostless tests for the private image-to-prop job API."""
import base64
import json
import tempfile
import unittest
import threading
import urllib.error
import urllib.request
from unittest.mock import patch
import hashlib
from test_glb_inspect import glb
import glb_inspect
from pathlib import Path

try:
    import prop_service as service
except ModuleNotFoundError:
    service = None

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")


class JobsTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(service, "private image-to-prop service is not implemented")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = service.JobStore(Path(self.temp.name))
        self.addCleanup(self.store.close)

    def request(self, **overrides):
        return dict(image_base64=base64.b64encode(PNG).decode(), name="original blue cup",
                    source={"license": "CC0-1.0", "author": "gmgn"}, height_meters=0.12,
                    **overrides)

    def test_submit_is_durable_and_idempotent(self):
        a = self.store.submit("example-1", self.request())
        b = self.store.submit("example-1", self.request())
        self.assertEqual(a["id"], b["id"])
        self.assertEqual(a["state"], "queued")
        other = service.JobStore(Path(self.temp.name))
        self.addCleanup(other.close)
        self.assertEqual(other.get(a["id"])["id"], a["id"])
        self.assertEqual(len(list((Path(self.temp.name)/"inputs").glob("*.png"))), 1)

    def test_idempotency_conflict_does_not_create_job(self):
        self.store.submit("example-1", self.request())
        changed = self.request(); changed["name"] = "different"
        with self.assertRaisesRegex(service.APIError, "idempotency_conflict"):
            self.store.submit("example-1", changed)

    def test_strict_input_and_source(self):
        for changed in [dict(arbitrary_workflow={}), dict(height_meters=True),
                        dict(height_meters=float("nan")), dict(source={}),
                        dict(image_base64="not-image"), dict(name="../bad")]:
            request = self.request(); request.update(changed)
            with self.subTest(changed=changed), self.assertRaises(service.APIError):
                self.store.submit("invalid-1", request)

    def test_job_paths_cannot_escape(self):
        for job_id in ["../secret", "a/../../secret", "", "a"*200]:
            with self.subTest(job_id=job_id), self.assertRaises(service.APIError):
                self.store.get(job_id)

    def test_cancel_queued_never_submits(self):
        job = self.store.submit("cancel-1", self.request())
        cancelled = self.store.cancel(job["id"])
        self.assertEqual(cancelled["state"], "cancelled")
        self.assertIsNone(self.store.claim())

    def test_cancel_running_does_not_claim_remote_stopped(self):
        job = self.store.submit("cancel-1", self.request())
        claimed = self.store.claim()
        self.store.update(claimed["id"], state="running", prompt_id="remote-id")
        cancelled = self.store.cancel(job["id"])
        self.assertEqual(cancelled["state"], "cancel_requested")
        self.assertTrue(cancelled["compute_may_continue"])

    def test_restart_marks_inflight_uncertain_without_retry(self):
        job = self.store.submit("restart-1", self.request())
        self.store.claim()
        self.store.recover()
        self.assertEqual(self.store.get(job["id"])["state"], "interrupted")
        self.assertIsNone(self.store.claim())

    def test_claim_serial_and_results_redact_filesystem(self):
        job = self.store.submit("claim-1", self.request())
        self.assertNotIn("input_path", job)
        self.assertEqual(self.store.claim()["id"], job["id"])
        self.assertIsNone(self.store.claim())

    def test_private_http_requires_token_and_rejects_browser_origin(self):
        server = service.make_server(self.store, "test-secret", "127.0.0.1", 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}/health"
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(url)
        self.assertEqual(error.exception.code, 401)
        error.exception.close()
        request = urllib.request.Request(url, headers={"Authorization": "Bearer test-secret"})
        with urllib.request.urlopen(request) as response:
            self.assertEqual(json.load(response)["status"], "api_ready")
        request.add_header("Origin", "https://malicious.example")
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request)
        self.assertEqual(error.exception.code, 403)
        error.exception.close()

    def test_http_submit_query_cancel_roundtrip(self):
        server = service.make_server(self.store, "test-secret", "127.0.0.1", 0)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}"
        headers = {"Authorization": "Bearer test-secret", "Content-Type": "application/json", "Idempotency-Key": "http-1"}
        request = urllib.request.Request(url + "/v1/jobs", data=json.dumps(self.request()).encode(), headers=headers)
        with urllib.request.urlopen(request) as response:
            self.assertEqual(response.status, 202); job = json.load(response)
        request = urllib.request.Request(url + "/v1/jobs/" + job["id"], headers=headers)
        with urllib.request.urlopen(request) as response:
            self.assertEqual(json.load(response)["state"], "queued")
        request = urllib.request.Request(url + "/v1/jobs/" + job["id"] + "/cancel", data=b"{}", headers=headers)
        with urllib.request.urlopen(request) as response:
            self.assertEqual(json.load(response)["state"], "cancelled")

    def test_worker_waits_without_submitting_when_resources_busy(self):
        self.assertTrue(hasattr(service, "JobWorker"), "job worker missing")
        class BusyBackend:
            def readiness(self):
                return {"ready": False, "reason": "shared_memory_busy"}
            def submit(self, *args):
                raise AssertionError("must not submit while busy")
        job = self.store.submit("waiting-1", self.request())
        worker = service.JobWorker(self.store, BusyBackend())
        worker.tick()
        self.assertEqual(self.store.get(job["id"])["state"], "waiting_resources")
        self.store.cancel(job["id"])
        worker.tick()
        self.assertEqual(self.store.get(job["id"])["state"], "cancelled")

    def test_worker_submission_uncertainty_never_retries(self):
        self.assertTrue(hasattr(service, "JobWorker"), "job worker missing")
        class LostResponseBackend:
            calls = 0
            def readiness(self): return {"ready": True}
            def submit(self, *args):
                self.calls += 1
                raise TimeoutError()
        backend = LostResponseBackend()
        job = self.store.submit("uncertain-1", self.request())
        worker = service.JobWorker(self.store, backend)
        worker.tick(); worker.tick()
        self.assertEqual(backend.calls, 1)
        self.assertEqual(self.store.get(job["id"])["state"], "interrupted")

    def test_worker_observes_cancel_without_global_interrupt(self):
        self.assertTrue(hasattr(service, "JobWorker"), "job worker missing")
        class Backend:
            def readiness(self): return {"ready": True}
            def submit(self, *args): return "remote-one"
            def status(self, *args): return {"state": "running"}
        job = self.store.submit("cancel-running-1", self.request())
        worker = service.JobWorker(self.store, Backend())
        worker.tick()
        self.store.cancel(job["id"])
        worker.tick()
        self.assertEqual(self.store.get(job["id"])["state"], "cancel_requested")

    def test_backend_decodes_actual_comfy_history_shape(self):
        self.assertTrue(hasattr(service, "ComfyBackend"), "Comfy backend missing")
        backend = service.ComfyBackend(Path(__file__).with_name("workflow.source.json"), Path(self.temp.name))
        backend.request_json = lambda path, data=None, legacy=False: {
            "remote-one": {"status": {"completed": True, "status_str": "success"},
                           "outputs": {"322": {"result": ["props/abcd_00001.glb", None, []]}}}}
        status = backend.status("remote-one")
        self.assertEqual(status["state"], "completed")
        self.assertEqual(status["filename"], "props/abcd_00001.glb")

    def test_backend_rejects_untrusted_workflow(self):
        self.assertTrue(hasattr(service, "ComfyBackend"), "Comfy backend missing")
        path = Path(self.temp.name) / "bad.json"; path.write_text("{}")
        with self.assertRaisesRegex(ValueError, "untrusted_workflow"):
            service.ComfyBackend(path, Path(self.temp.name))

    def test_cancel_during_readiness_is_not_overwritten(self):
        job = self.store.submit("cancel-readiness", self.request())
        store = self.store
        class Backend:
            def readiness(self):
                store.cancel(job["id"])
                return {"ready": False, "reason": "shared_memory_busy"}
        service.JobWorker(self.store, Backend()).tick()
        self.assertIn(self.store.get(job["id"])["state"], {"cancelled", "cancel_requested"})

    def test_restart_preserves_unsubmitted_resource_wait(self):
        job = self.store.submit("waiting-restart", self.request())
        self.store.claim()
        self.store.update(job["id"], state="waiting_resources", reason="shared_memory_busy")
        self.store.recover()
        self.assertEqual(self.store.get(job["id"])["state"], "queued")
        self.assertEqual(self.store.claim()["id"], job["id"])

    def test_cancel_at_observation_boundary_survives_late_running_status(self):
        job = self.store.submit("late-status", self.request())
        store = self.store
        class Observation(dict):
            fired = False
            def __getitem__(self, key):
                # Deterministic cancellation at the remote-result consumption boundary.
                if key == "state" and not self.fired:
                    self.fired = True
                    store.cancel(job["id"])
                return super().__getitem__(key)
        class Backend:
            def readiness(self): return {"ready": True}
            def submit(self, *args): return "remote-one"
            def status(self, *args): return Observation(state="running")
        worker = service.JobWorker(store, Backend())
        worker.tick(); worker.tick()
        self.assertEqual(store.get(job["id"])["state"], "cancel_requested")

    def test_readiness_accepts_real_v3_combo_model_options(self):
        root = Path(__file__).parent
        backend = service.ComfyBackend(root/"workflow.source.json", Path(self.temp.name))
        info = {}
        for node in backend.workflow["nodes"]:
            if node["id"] not in {15, 40, 117, 118, 193}:
                continue
            entry = info.setdefault(node["type"], {"input": {"required": {"model": ["COMBO", {"options": []}]}}})
            entry["input"]["required"]["model"][1]["options"].append(node["widgets_values"][0])
        backend.request_json = lambda path, data=None, legacy=False: info if path=="/object_info" else {"queue_running":[], "queue_pending":[]}
        with patch.object(service.Path, "read_text", return_value="MemAvailable: 33554432 kB\n"):
            self.assertTrue(backend.readiness()["ready"])

    def test_observation_timeout_releases_worker_without_resubmit(self):
        self.assertTrue(hasattr(service.JobWorker, "observation_timeout_seconds"), "bounded observation missing")
        now = [0.0]
        class Backend:
            calls = 0
            def readiness(self): return {"ready": True}
            def submit(self, *args): self.calls += 1; return "remote-one"
            def status(self, *args): raise TimeoutError()
        backend = Backend()
        job = self.store.submit("status-timeout", self.request())
        worker = service.JobWorker(self.store, backend, clock=lambda: now[0], observation_timeout_seconds=5)
        worker.tick(); worker.tick()
        self.assertEqual(self.store.get(job["id"])["state"], "remote_pending")
        now[0] = 6
        worker.tick(); worker.tick()
        result = self.store.get(job["id"])
        self.assertEqual(result["state"], "interrupted")
        self.assertTrue(result["compute_may_continue"])
        self.assertEqual(backend.calls, 1)
        self.assertIsNone(worker.active)

    def test_root_lease_prevents_second_instance_recovery(self):
        self.assertTrue(hasattr(service, "RootLease"), "root process lease missing")
        root = Path(self.temp.name)
        job = self.store.submit("single-process", self.request()); self.store.claim()
        with service.RootLease(root):
            with self.assertRaisesRegex(RuntimeError, "service_already_running"):
                with service.RootLease(root):
                    self.store.recover()
            self.assertEqual(self.store.get(job["id"])["state"], "preflight")
        with service.RootLease(root):
            pass

    def collection_fixture(self):
        job = self.store.submit("collect-fixture", self.request())
        output = Path(self.temp.name)/"comfy_output"; (output/"props").mkdir(parents=True)
        source = output/"props"/(job["id"]+"_00001.glb")
        source.write_bytes(glb())
        backend = service.ComfyBackend(Path(__file__).with_name("workflow.source.json"), output)
        destination = Path(self.temp.name)/"outputs"/(job["id"]+".glb")
        return job, source, backend, destination

    def test_collection_rejects_source_symlink_even_inside_output_root(self):
        job, source, backend, destination = self.collection_fixture()
        target = source.with_name("alternate.glb"); source.rename(target); source.symlink_to(target)
        with self.assertRaises((ValueError, OSError)):
            backend.collect(job, {"filename":"props/"+source.name}, destination)
        self.assertFalse(destination.exists())

    def test_collection_publishes_exact_bytes_that_were_validated(self):
        job, source, backend, destination = self.collection_fixture()
        original = source.read_bytes()
        inspect = glb_inspect.inspect_glb
        def change_source_after_validation(path, **kwargs):
            result = inspect(path, **kwargs)
            source.write_bytes(b"changed-after-check")
            return result
        with patch.object(glb_inspect, "inspect_glb", side_effect=change_source_after_validation):
            result = backend.collect(job, {"filename":"props/"+source.name}, destination)
        self.assertEqual(destination.read_bytes(), original)
        self.assertEqual(result["inspection"]["sha256"], hashlib.sha256(destination.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
