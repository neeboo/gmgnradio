"""Real isolated HTTP-only taskd authentication/SSE/restart acceptance."""
import http.client
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from process import Daemon


class HttpTransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="taskd-http-transport-")
        self.daemon = Daemon(self.temp.name)

    def tearDown(self):
        self.daemon.stop()
        self.temp.cleanup()

    def connection(self):
        endpoint = json.loads(Path(self.daemon.path).read_text())
        self.assertEqual(endpoint["version"], 2)
        host, port = endpoint["address"].rsplit(":", 1)
        return http.client.HTTPConnection(host, int(port), timeout=5), endpoint["token"]

    def request(self, path, method="snapshot", params=None, headers=None, verb="POST"):
        connection, token = self.connection()
        merged = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
        merged.update(headers or {})
        payload = None if verb == "GET" else json.dumps({"id": "http-test", "method": method, "params": params or {}})
        connection.request(verb, path, payload, merged)
        response = connection.getresponse()
        value = json.loads(response.read())
        status = response.status
        connection.close()
        return status, value

    @staticmethod
    def data(response):
        while True:
            line = response.readline()
            if not line:
                raise AssertionError("SSE ended before data")
            if line.startswith(b"data: "):
                value = json.loads(line[6:])
                assert response.readline() in (b"\n", b"\r\n")
                return value

    def test_http_auth_origin_and_route_contract(self):
        self.assertEqual(self.request("/health", verb="GET"), (200, {"version": 2, "transport": "http"}))
        status, reply = self.request("/rpc", headers={"Authorization": "Bearer wrong"})
        self.assertEqual((status, reply["error"]["code"]), (401, "http_unauthorized"))
        status, reply = self.request("/rpc", headers={"Origin": "https://example.invalid"})
        self.assertEqual((status, reply["error"]["code"]), (403, "http_origin_forbidden"))
        status, reply = self.request("/rpc", "subscribe", {"after": 0})
        self.assertEqual((status, reply["error"]["code"]), (400, "http_events_route_required"))
        status, reply = self.request("/events", "snapshot")
        self.assertEqual((status, reply["error"]["code"]), (400, "http_stream_method_required"))
        status, reply = self.request("/events", "voice_asr_start")
        self.assertEqual((status, reply["error"]["code"]), (400, "invalid_client_id"))

    def test_sse_ack_replay_live_and_v1_descriptor_upgrade(self):
        first = self.daemon.submit("https://example.invalid")["result"]["job"]
        connection, token = self.connection()
        connection.request("POST", "/events", json.dumps({"id": "subscription", "method": "subscribe", "params": {"after": 0}}), {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Type"), "text/event-stream")
        ack = self.data(response)
        self.assertEqual(ack, {"id": "subscription", "result": {"subscribed": True}})
        replay = self.data(response)
        self.assertEqual(replay["event"]["job"]["id"], first["id"])
        second = self.daemon.submit("https://example.invalid")["result"]["job"]
        for _ in range(8):
            live = self.data(response)
            if live["event"]["job"]["id"] == second["id"]:
                break
        else:
            self.fail("live committed event missing")
        self.assertGreater(live["event"]["sequence"], replay["event"]["sequence"])
        response.close()
        connection.close()
        self.daemon.stop()
        descriptor = Path(self.daemon.path)
        previous = json.loads(descriptor.read_text())
        previous["version"] = 1
        descriptor.write_text(json.dumps(previous))
        self.daemon.start()
        self.assertEqual(self.request("/health", verb="GET")[1]["version"], 2)
        jobs = self.daemon.request("snapshot")["result"]["jobs"]
        self.assertEqual({job["id"] for job in jobs}, {first["id"], second["id"]})

    def test_voice_sse_never_echoes_key_and_stream_drop_releases_client(self):
        connection, token = self.connection()
        client_id = str(uuid.uuid4())
        key = "http-secret-never-persist"
        params = {"sessionID": "speech", "provider": "elevenlabs", "apiKey": key, "voiceID": "invalid voice", "text": "hello"}
        connection.request("POST", "/events", json.dumps({"id": "start", "method": "voice_tts_start", "params": params}), {"Authorization": "Bearer " + token, "Content-Type": "application/json", "X-GMGN-Client-ID": client_id})
        response = connection.getresponse()
        ack = self.data(response)
        self.assertTrue(ack["result"]["started"])
        event = self.data(response)
        self.assertNotIn("id", event)
        self.assertEqual(event["voice_event"]["type"], "error")
        self.assertNotIn(key, json.dumps(event))
        response.close()
        connection.close()
        _, stale = self.request("/rpc", "voice_cancel", {"sessionID": "speech"}, {"X-GMGN-Client-ID": client_id})
        self.assertEqual(stale["error"]["code"], "voice_session_not_found")
        self.daemon.stop()
        for path in Path(self.temp.name).rglob("*"):
            if path.is_file():
                self.assertNotIn(key.encode(), path.read_bytes(), path.name)


if __name__ == "__main__":
    unittest.main()
