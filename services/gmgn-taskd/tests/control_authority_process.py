"""Real isolated taskd HTTP and SQLite; no audio, real CLI, or user data."""
import unittest
import http_transport_process


class ControlAuthorityTests(unittest.TestCase):
    setUp = http_transport_process.HttpTransportTests.setUp
    tearDown = http_transport_process.HttpTransportTests.tearDown
    connection = http_transport_process.HttpTransportTests.connection
    request = http_transport_process.HttpTransportTests.request

    def rpc(self, method, **params):
        status, reply = self.request("/rpc", method, params)
        self.assertEqual(status, 200)
        return reply

    def test_music_queue_survives_process_restart_and_stale_receipt_is_rejected(self):
        scope = dict(playerID="private-player", hostSessionID="host-1")
        entries = [dict(id="a", payload=dict(path="/private-fixture/a")),
                   dict(id="b", payload=dict(path="/private-fixture/b"))]
        selection = dict(scope, requestID="selection-1", mode="local", queue=entries, index=0)
        ticket = self.rpc("music_playback_begin", **selection)["result"]["ticket"]
        receipt = dict(scope, generation=ticket["generation"], requestID="selection-1",
                       trackID="a", accepted=True)
        state = self.rpc("music_playback_commit", **receipt)["result"]["state"]
        self.assertEqual(state["index"], 0)
        self.daemon.stop()
        self.daemon.start()
        recovered = self.rpc("music_playback_read", **scope)["result"]["state"]
        self.assertEqual(recovered["sessionID"], state["sessionID"])
        self.assertEqual(recovered["queue"], entries)
        replay = self.rpc("music_playback_begin", **selection)["result"]
        self.assertEqual(replay["state"]["generation"], recovered["generation"])
        wrong = self.rpc("music_playback_receipt", **dict(scope, sessionID="stale",
                                                         trackID="a", status="completed"))
        self.assertIn("error", wrong)
        self.assertEqual(self.rpc("music_playback_read", **scope)["result"]["state"]["index"], 0)

    def test_wish_control_is_in_same_store_and_old_session_cannot_write(self):
        opened = self.rpc("wish_control_open", ownerID="private-owner", hostSessionID="host-1")["result"]
        self.assertEqual(opened["revision"], 0)
        self.daemon.stop()
        self.daemon.start()
        adopted = self.rpc("wish_control_open", ownerID="private-owner", hostSessionID="host-2")["result"]
        self.assertEqual(adopted["archive"], opened["archive"])
        stale = self.rpc("wish_control_commit", ownerID="private-owner", hostSessionID="host-1",
                         expectedRevision=0, archive=opened["archive"])
        self.assertIn("error", stale)
        read = self.rpc("wish_control_read", ownerID="private-owner", hostSessionID="host-2")["result"]
        self.assertEqual(read["revision"], 0)


if __name__ == "__main__":
    unittest.main()
