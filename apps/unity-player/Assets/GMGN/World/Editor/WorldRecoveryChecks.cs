using System;
using System.IO;
using System.Security.Cryptography;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer.World.Editor
{
    public static class WorldRecoveryChecks
    {
        // Invoke through Unity executeMethod; no user state or live service touched.
        public static void Run()
        {
            var root = Path.Combine(Path.GetTempPath(), "gmgn-world-check-" + Guid.NewGuid().ToString("N"));
            // macOS temp aliases (/var and /tmp) are symlinks. Use their physical
            // system-owned location so the package rejects all payload symlinks.
            if (Application.platform == RuntimePlatform.OSXEditor && (root.StartsWith("/var/", StringComparison.Ordinal) || root.StartsWith("/tmp/", StringComparison.Ordinal))) root = "/private" + root;
            Directory.CreateDirectory(root);
            try
            {
                var state = new JObject { ["objectStates"] = new JObject() };
                var worlds = new JObject {
                    ["schemaVersion"] = 1,
                    ["records"] = new JArray(
                        new JObject { ["world_id"] = "check-world", ["domain"] = "worlds", ["key"] = "state", ["revision"] = 1, ["tombstone"] = 0, ["hash"] = "record", ["value"] = state },
                        new JObject { ["world_id"] = "check-world", ["domain"] = "objects", ["key"] = "live", ["revision"] = 2, ["tombstone"] = 0, ["hash"] = "object", ["value"] = new JObject { ["isEnabled"] = true } },
                        new JObject { ["world_id"] = "check-world", ["domain"] = "objects", ["key"] = "deleted", ["revision"] = 3, ["tombstone"] = 1, ["hash"] = "deleted", ["value"] = new JObject { ["isEnabled"] = true } }),
                    ["referenceBindings"] = new JObject(), ["blobs"] = new JArray()
                };
                var payload = Path.Combine(root, "worlds.json");
                File.WriteAllText(payload, worlds.ToString());
                string sha;
                using (var hash = SHA256.Create()) sha = BitConverter.ToString(hash.ComputeHash(File.ReadAllBytes(payload))).Replace("-", "").ToLowerInvariant();
                var manifest = new JObject { ["format"] = "gmgn.portable-world-backup", ["formatVersion"] = 1, ["files"] = new JArray(new JObject { ["path"] = "worlds.json", ["bytes"] = new FileInfo(payload).Length, ["sha256"] = sha }) };
                File.WriteAllText(Path.Combine(root, "manifest.json"), manifest.ToString());
                Require(PortableWorldPackage.Open(root).State("check-world")["objectStates"] != null, "state recovery");
                var recovered = PortableWorldPackage.Open(root).State("check-world")["objectStates"];
                Require(recovered["live"] != null && recovered["deleted"] == null, "object records and tombstones");
                ExpectFailure(() => PortableWorldPackage.Open(root).ResolveReference("/old/missing.glb"), "missing binding");
                File.AppendAllText(payload, " ");
                ExpectFailure(() => PortableWorldPackage.Open(root), "tampered payload");
                File.WriteAllText(payload, worlds.ToString());
                File.WriteAllText(Path.Combine(root, "unlisted.txt"), "extra");
                ExpectFailure(() => PortableWorldPackage.Open(root), "unlisted payload");
                File.Delete(Path.Combine(root, "unlisted.txt"));
                manifest["files"][0]["path"] = "../worlds.json";
                File.WriteAllText(Path.Combine(root, "manifest.json"), manifest.ToString());
                ExpectFailure(() => PortableWorldPackage.Open(root), "path traversal");
                var v = new JObject { ["x"] = 1, ["y"] = 2, ["z"] = 3 };
                Require(WorldCoordinates.Position(v) == new Vector3(1, 2, -3), "coordinate reflection");
                var q = new JObject { ["x"] = 0, ["y"] = 0, ["z"] = 0, ["w"] = 1 };
                Require(WorldCoordinates.Rotation(q) == Quaternion.identity, "identity rotation");
                Debug.Log("[WorldRecoveryChecks] PASS: state, missing binding, tamper, file set, traversal, coordinates");
            }
            finally { Directory.Delete(root, true); }
        }
        static void Require(bool value, string name) { if (!value) throw new Exception("World recovery check failed: " + name); }
        static void ExpectFailure(Action action, string name)
        {
            try { action(); }
            catch (InvalidDataException) { return; }
            throw new Exception("World recovery unexpectedly accepted: " + name);
        }
    }
}
