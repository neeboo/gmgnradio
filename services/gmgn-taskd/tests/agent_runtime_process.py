"""Isolated real HTTP scheduler recovery; no model or native actions."""
import unittest
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http_transport_process


class AgentRuntimeTests(unittest.TestCase):
    setUp = http_transport_process.HttpTransportTests.setUp
    tearDown = http_transport_process.HttpTransportTests.tearDown
    connection = http_transport_process.HttpTransportTests.connection
    request = http_transport_process.HttpTransportTests.request

    def rpc(self, method, **params):
        status, reply = self.request("/rpc", method, dict(
            worldID="isolated-agent-world", residentScope="resident-a", **params))
        self.assertEqual(status, 200)
        return reply

    def configure(self, session):
        self.assertTrue(self.rpc("agent_loop_configure", hostSessionID=session,
                                hourlyLimit=6, minimumWakeIntervalSeconds=1,
                                backgroundEnabled=True, available=True)["result"]["configured"])

    def enqueue(self, event):
        return self.rpc("agent_loop_enqueue", eventID=event, intentID="intent",
                        kind="continuation", intentState="active", command={"observe": True})

    def claim(self, run, session, now):
        return self.rpc("agent_loop_claim", runID=run, hostSessionID=session, nowMillis=now)

    def test_cancel_and_restart_require_verified_terminal_receipt(self):
        self.configure("session-1")
        self.enqueue("event-1")
        self.enqueue("event-2")
        self.assertTrue(self.claim("run-1", "session-1", 1000)["result"]["claimed"])
        cancelled = self.rpc("agent_loop_cancel", eventID="event-1")["result"]
        self.assertFalse(cancelled["cancelled"])
        self.assertEqual(cancelled["state"], "cancel_requested")
        self.assertFalse(self.claim("run-2", "session-1", 3000)["result"]["claimed"])
        self.daemon.stop()
        self.daemon.start()
        events = self.rpc("agent_loop_read")["result"]["events"]
        self.assertEqual(events[0]["state"], "unknown")
        self.assertTrue(self.rpc("agent_loop_cancel", eventID="event-1")["result"]["requiresVerification"])
        self.configure("session-2")
        self.assertFalse(self.claim("run-2", "session-2", 4000)["result"]["claimed"])
        receipt = dict(eventID="event-1", runID="run-1", hostSessionID="session-2",
                       originalHostSessionID="session-1", outcome="completed",
                       receipt={"verified": True})
        self.assertTrue(self.rpc("agent_loop_reconcile", **receipt)["result"]["accepted"])
        self.assertTrue(self.rpc("agent_loop_reconcile", **receipt)["result"]["duplicate"])
        self.assertTrue(self.claim("run-2", "session-2", 5000)["result"]["claimed"])

    def test_model_cannot_register_tool_authority(self):
        self.assertIn("error", self.rpc("agent_tool_register", tools=[]))
        self.assertIn("error", self.rpc("agent_tool_reconcile", operationID="not-authorized"))

    def test_real_provider_http_tool_receipt_and_durable_completion(self):
        requests = []

        def chunk(delta, finish=None):
            return "data: " + json.dumps(dict(id="fixture", object="chat.completion.chunk",
                created=0, model="fixture-model", choices=[dict(index=0, delta=delta,
                finish_reason=finish)])) + "\n\n"

        class Provider(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(handler):
                self.assertEqual(handler.path, "/v1/chat/completions")
                self.assertEqual(handler.headers["Authorization"], "Bearer fake-local-key")
                requests.append(json.loads(handler.rfile.read(int(handler.headers["Content-Length"]))))
                if len(requests) == 1:
                    body = chunk(dict(role="assistant", tool_calls=[dict(index=0, id="call-1",
                        type="function", function=dict(name="gmgn_move", arguments='{"x":1}'))]))
                    body += chunk({}, "tool_calls")
                else:
                    body = chunk(dict(role="assistant", content="arrived")) + chunk({}, "stop")
                data = (body + "data: [DONE]\n\n").encode()
                handler.send_response(200)
                handler.send_header("Content-Type", "text/event-stream")
                handler.send_header("Content-Length", str(len(data)))
                handler.end_headers()
                handler.wfile.write(data)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.configure("session-http")
            self.enqueue("event-http")
            self.assertTrue(self.claim("run-http", "session-http", 1000)["result"]["claimed"])
            identity = dict(hostSessionID="session-http", runID="run-http")
            configured = self.rpc("agent_runtime_configure", **identity, eventID="event-http",
                provider=dict(backend="openai", endpoint=f"http://127.0.0.1:{server.server_port}/v1",
                    model="fixture-model", apiKey="fake-local-key"),
                tools=[dict(name="gmgn_move", description="Fixture only", effect="write",
                    inputSchema=dict(type="object", properties=dict(x=dict(type="integer")),
                        required=["x"], additionalProperties=False))],
                operations=[dict(operationID="trusted-move-1", toolName="gmgn_move", arguments=dict(x=1))])
            self.assertTrue(configured["result"]["configured"])
            self.assertTrue(self.rpc("agent_runtime_start", **identity, input="move")["result"]["started"])
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                state = self.rpc("agent_runtime_read", **identity)["result"]
                if state["pendingTools"]:
                    break
                time.sleep(0.02)
            else:
                self.fail(f"No pending tool: {state}")
            self.assertEqual(state["pendingTools"][0]["operationID"], "trusted-move-1")
            receipt = dict(**identity, callID="call-1", operationID="trusted-move-1",
                           status="completed", output=dict(arrived=True))
            self.assertIn("error", self.rpc("agent_runtime_tool_receipt", **dict(receipt, operationID="wrong")))
            self.assertTrue(self.rpc("agent_runtime_tool_receipt", **receipt)["result"]["accepted"])
            while time.monotonic() < deadline:
                state = self.rpc("agent_runtime_read", **identity)["result"]
                if state["state"] != "running":
                    break
                time.sleep(0.02)
            self.assertEqual(state["state"], "completed", state)
            self.assertEqual(state["text"], "arrived")
            self.assertNotIn("fake-local-key", json.dumps(state))
            self.assertEqual(len(requests), 2)
            self.assertIn("tool", [message["role"] for message in requests[1]["messages"]])
            self.assertEqual(self.rpc("agent_loop_read")["result"]["events"][0]["state"], "completed")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
