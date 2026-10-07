"""Notification replay against a real HTTP daemon and an isolated SQLite root.

No provider is configured: submitted jobs remain local pending facts.
"""
import json
import uuid
import unittest
import http_transport_process


class NotificationHttpTests(unittest.TestCase):
    setUp = http_transport_process.HttpTransportTests.setUp
    tearDown = http_transport_process.HttpTransportTests.tearDown
    connection = http_transport_process.HttpTransportTests.connection
    request = http_transport_process.HttpTransportTests.request
    data = staticmethod(http_transport_process.HttpTransportTests.data)

    def subscribe_until(self, consumer, target, context=None, after=0):
        connection, token = self.connection()
        connection.request("POST", "/events", json.dumps({
            "id": "notifications", "method": "subscribe_messages",
            "params": dict(consumer=consumer, after=after, **(context or self.context)),
        }), {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        response = connection.getresponse()
        try:
            self.assertEqual(response.status, 200)
            self.assertTrue(self.data(response)["result"]["subscribed"])
            found = []
            for _ in range(64):
                message = self.data(response)["message"]
                found.append(message)
                if message["id"] == target:
                    return found
            self.fail("notification sentinel missing")
        finally:
            response.close()
            connection.close()

    def publish(self, kind, context=None):
        request = dict(id=str(uuid.uuid4()), taskId=self.task_id,
                       kind=kind, payload={"fact": kind}, **(context or self.context))
        status, reply = self.request("/rpc", "publish_message", request)
        self.assertEqual(status, 200)
        return request, reply["result"]["message"]

    def test_notification_replay_ack_scope_and_terminal_facts(self):
        self.context = dict(worldID="notification-world", residentScope="resident-a")
        self.task_id = self.daemon.submit("http://127.0.0.1:9", context=self.context)["result"]["job"]["id"]
        request, ready = self.publish("wish.outputReady")
        self.assertEqual(self.request("/rpc", "publish_message", request)[1]["result"]["message"], ready)
        for field, value in (("payload", {"fact": "changed"}), ("worldID", "other-world"),
                             ("residentScope", "other-resident"), ("kind", "wish.failed"),
                             ("taskId", str(uuid.uuid4()))):
            self.assertEqual(self.request("/rpc", "publish_message", dict(request, **{field: value}))[1]["error"]["code"], "message_id_conflict")
        self.assertEqual(self.request("/rpc", "publish_message", request, {"Origin": "https://example.invalid"})[0], 403)
        for foreign in (dict(self.context, worldID="other-world"), dict(self.context, residentScope="other-resident")):
            self.assertEqual(self.request("/rpc", "ack_message", dict(id=ready["id"], consumer="ui", **foreign))[1]["error"]["code"], "message_scope_mismatch")
            _, sentinel = self.publish("wish.claimed", foreign)
            self.assertEqual(self.subscribe_until("agent", sentinel["id"], foreign), [sentinel])

        _, failed = self.publish("wish.failed")
        _, cancelled = self.publish("wish.cancelled")
        for consumer in ("world", "ui", "agent"):
            received = self.subscribe_until(consumer, cancelled["id"], after=cancelled["sequence"])
            self.assertEqual([item for item in received if item["id"] in {ready["id"], failed["id"], cancelled["id"]}], [ready, failed, cancelled])
        # Reconnect intentionally supplies a stale high cursor: notification SSE
        # must still replay every unacked entry from zero.
        self.daemon.stop()
        self.daemon.start()
        self.assertIn(ready, self.subscribe_until("ui", cancelled["id"], after=cancelled["sequence"] + 100))
        for _ in range(2):
            self.assertTrue(self.request("/rpc", "ack_message", dict(id=ready["id"], consumer="ui", **self.context))[1]["result"]["acknowledged"])
        self.daemon.stop()
        self.daemon.start()
        self.assertNotIn(ready, self.subscribe_until("ui", cancelled["id"]))
        for consumer in ("world", "agent"):
            self.assertIn(ready, self.subscribe_until(consumer, cancelled["id"]))


if __name__ == "__main__":
    unittest.main()
