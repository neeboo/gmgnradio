"""Real isolated taskd restart/CAS/import music authority acceptance."""
import unittest
from local_memory_process import Daemon
import tempfile


def program(identity, title="original"):
    return {"plan": {"brief": {"id": identity, "targetDuration": 1200}, "slots": [], "title": title,
                     "revision": 1, "generatedAt": "2026-10-07T00:00:00Z", "replanAfterTrackCount": 3},
            "updatedAt": "2026-10-07T00:00:00Z"}


def playlist(identity):
    return {"id": identity, "providerID": "appleMusic", "name": identity,
            "tracks": [], "totalTrackCount": 0}


class MusicStorageTests(unittest.TestCase):
    def test_restart_pending_import_and_cas(self):
        with tempfile.TemporaryDirectory(prefix="taskd-music-") as root:
            d = Daemon(root)
            try:
                def rpc(method, params=None):
                    response = d.request(method, params)
                    self.assertNotIn("error", response, response)
                    return response["result"]
                self.assertEqual(rpc("music_library_read")["revision"], 0)
                self.assertTrue(rpc("music_program_save", {"program": program("live"), "pending": True})["saved"])
                migration = {"source": "native-v1", "programs": [program("live", "do not overwrite"), program("old")], "playlists": [playlist("p1")]}
                result = rpc("music_import", migration)
                self.assertEqual(result["importedPrograms"], 1)
                self.assertEqual(result["importedPlaylists"], 1)
                self.assertEqual(rpc("music_import", migration)["alreadyImported"], True)
                library = rpc("music_library_read")
                self.assertEqual(library["revision"], 1)
                self.assertEqual(rpc("music_library_commit", {"playlists": [playlist("p2")], "baseRevision": 1})["revision"], 2)
                stale = d.request("music_library_commit", {"playlists": [], "baseRevision": 1})
                self.assertEqual(stale["error"]["code"], "music_revision_conflict")
                bad = d.request("music_program_save", {"program": {"plan": {"brief": {"id": "broken"}, "slots": []}, "updatedAt": 123}, "pending": True})
                self.assertEqual(bad["error"]["code"], "invalid_music_input")
                d.stop()
                d.start()
                listed = rpc("music_program_list")
                self.assertEqual(listed["pendingIDs"], ["live"])
                self.assertEqual({p["plan"]["brief"]["id"] for p in listed["programs"]}, {"live", "old"})
                self.assertEqual(next(p for p in listed["programs"] if p["plan"]["brief"]["id"] == "live")["plan"]["title"], "original")
                self.assertEqual(rpc("music_library_read"), {"playlists": [playlist("p2")], "revision": 2})
                self.assertTrue(rpc("music_import", migration)["alreadyImported"])
                rpc("music_program_save", {"program": program("live"), "pending": False})
                self.assertEqual(rpc("music_program_list")["pendingIDs"], [])
            finally:
                d.stop()


if __name__ == "__main__":
    unittest.main()
