using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.World.Editor
{
    public static class WorldRecoveryChecks
    {
        // Explicit read-only asset probe. No world/task service calls or assets
        // are saved; the loaded model exists only in this temporary Editor run.
        public static async void RunFormalSofa()
        {
            GameObject probeRoot = null;
            try {
                var fixturePath = Environment.GetEnvironmentVariable("GMGN_ASSET_PROBE_FIXTURE");
                Require(!string.IsNullOrEmpty(fixturePath), "Explicit read-only catalog/state fixture required");
                var fixture = JObject.Parse(File.ReadAllText(fixturePath));
                var state = (JObject)fixture["state"];
                var resolver = new GeneratedAssetResolver((string)fixture["dataRoot"], (string)fixture["worldID"]);
                resolver.SetCatalog((JObject)fixture["catalog"]);
                probeRoot = new GameObject("Read-only inventory recovery probe");
                // glTFast's default frame defer agent requires Play Mode. This
                // read-only Editor probe uses its official uninterrupted agent;
                // all asset validation/material/size preparation is unchanged.
                var items = await new WorldSceneRecovery(new GltfWorldAssetLoader(new GLTFast.UninterruptedDeferAgent()))
                    .RestoreState(state, probeRoot.transform, resolver.Resolve, System.Threading.CancellationToken.None, true);
                Require(items.Count == 1 && items[0].Status == "inventory" && items[0].Instance != null,
                    "Actual resolver and recovery must prepare the owned inventory model");
                Require(!items[0].Instance.activeSelf && items[0].Instance.GetComponentsInChildren<Renderer>(true).Length > 0,
                    "Inventory model must remain inactive before placement");
                var bridge = probeRoot.AddComponent<WorldRuntimeBridge>();
                var binding = BindingFlags.Instance | BindingFlags.NonPublic;
                var recovered = (System.Collections.Generic.Dictionary<string, RecoveryItem>)typeof(WorldRuntimeBridge)
                    .GetField("recoveredItems", binding).GetValue(bridge);
                recovered[items[0].ObjectID] = items[0];
                JArray inventory = null; bridge.InventoryUpdated += value => inventory = value;
                typeof(WorldRuntimeBridge).GetMethod("PublishInventory", binding).Invoke(bridge, new object[] { state["objectStates"] });
                Require(inventory?.Count == 1 && (bool?)inventory[0]["modelReady"] == true,
                    "Actual PublishInventory must publish modelReady for the recovered inventory");
                Require(!string.IsNullOrEmpty((string)inventory[0]["objectID"]), "GPUI inventory projection retains the actual recovered identity");
                Debug.Log("[FormalSofaProbe] PASS actual catalog resolve -> RestoreState inventory inactive model -> PublishInventory modelReady and identity; no placement or formal writes");
                GMGN.UnityPlayer.Editor.CameraKeyboardChecks.Validate();
                UnityEditor.EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogError("[FormalSofaProbe] code=" + WorldAssetFailureDiagnostics.Code(error));
                Debug.LogException(error);
                UnityEditor.EditorApplication.Exit(1);
            } finally { if (probeRoot != null) UnityEngine.Object.DestroyImmediate(probeRoot); }
        }
        public static void RunPreparedGrip()
        {
            var root = new GameObject("Prepared grip check");
            try {
                var content = GameObject.CreatePrimitive(PrimitiveType.Cube).transform;
                content.SetParent(root.transform, false);
                var prop = new JObject { ["sizeLocked"] = true,
                    ["size"] = new JObject { ["x"] = 2, ["y"] = 3, ["z"] = 4 } };
                GltfWorldAssetLoader.Prepare(root.transform, content, prop);
                var type = typeof(GltfWorldAssetLoader).Assembly.GetType("GMGN.UnityPlayer.World.PreparedPropGrip");
                Require(type != null, "prepared prop must retain original grip bounds");
                var grip = root.GetComponent(type);
                Require(grip != null, "prepared grip must be attached to loaded asset");
                var method = type.GetMethod("LocalPoint");
                var point = (Vector3)method.Invoke(grip, new object[] { new Vector3(.25f, .75f, .2f) });
                Require(Vector3.Distance(point, new Vector3(.5f, 2.25f, -1.2f)) < .0001f,
                    "grip must follow glTFast source-X reflection and prepared dimensions/support pivot");
                root.transform.SetPositionAndRotation(new Vector3(4, 5, 6), Quaternion.Euler(0, 70, 0));
                Require(Vector3.Distance((Vector3)method.Invoke(grip, new object[] { new Vector3(.25f, .75f, .2f) }), point) < .0001f,
                    "world placement must not alter model-local grip");
                var project = type.GetMethod("ApplyToBone");
                Require(project != null, "prepared prop must project its calibrated grip onto the bone");
                var bone = new GameObject("Attachment bone");
                try {
                    bone.transform.SetPositionAndRotation(new Vector3(1, 2, 3), Quaternion.Euler(20, 80, 15));
                    bone.transform.localScale = Vector3.one * 2;
                    var offset = new Vector3(.1f, .2f, -.3f);
                    project.Invoke(grip, new object[] { bone.transform, new Vector3(.25f, .75f, .2f), offset, Quaternion.Euler(0, 30, 0) });
                    Require(Vector3.Distance(root.transform.TransformPoint(point), bone.transform.position + bone.transform.rotation * offset) < .0001f,
                        "grip must hit calibrated bone target without inheriting avatar scale");
                    Require(root.transform.localScale == Vector3.one, "attachment must preserve prepared prop dimensions");
                    for (var frame = 0; frame < 120; frame++) {
                        bone.transform.SetPositionAndRotation(new Vector3(frame * .01f, 2 + Mathf.Sin(frame * .1f), 3),
                            Quaternion.Euler(frame, frame * 3, frame * .5f));
                        project.Invoke(grip, new object[] { bone.transform, new Vector3(.25f, .75f, .2f), offset, Quaternion.Euler(0, 30, 0) });
                        Require(Vector3.Distance(root.transform.TransformPoint(point), bone.transform.position + bone.transform.rotation * offset) < .0001f,
                            "moving attachment must follow bone without grip drift");
                        Require(root.transform.localScale == Vector3.one, "moving attachment must retain model size");
                    }
                } finally { UnityEngine.Object.DestroyImmediate(bone); }
                Debug.Log("[PreparedGripChecks] PASS original bounds, source handedness, nonuniform dimensions, placement independence");
                UnityEditor.EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); UnityEditor.EditorApplication.Exit(1); }
            finally { UnityEngine.Object.DestroyImmediate(root); }
        }
        sealed class HeldLoader : IWorldAssetLoader
        {
            public int Calls;
            public System.Threading.Tasks.Task<GameObject> LoadPreparedAsset(string path, JObject prop, System.Threading.CancellationToken token)
            { Calls++; return System.Threading.Tasks.Task.FromResult(new GameObject("Verified loader result")); }
        }
        public static async void RunHeldRecovery()
        {
            var parent = new GameObject("Held recovery check");
            try {
                var loader = new HeldLoader();
                var zero = new JObject { ["x"] = 0, ["y"] = 0, ["z"] = 0 };
                var state = new JObject {
                    ["heldProp"] = new JObject { ["objectID"] = "prop.held" },
                    ["objectStates"] = new JObject { ["prop.held"] = new JObject {
                        ["isEnabled"] = false,
                        ["transform"] = new JObject { ["position"] = zero,
                            ["rotation"] = new JObject { ["x"] = 0, ["y"] = 0, ["z"] = 0, ["w"] = 1 } },
                        ["metadata"] = new JObject { ["gmgn.generated-prop.v1"] = new JObject { ["objectID"] = "prop.held" }.ToString() }
                    }}
                };
                var items = await new WorldSceneRecovery(loader).RestoreState(state, parent.transform,
                    (prop, token) => System.Threading.Tasks.Task.FromResult("verified.asset"), System.Threading.CancellationToken.None);
                Require(loader.Calls == 1 && items[0].Instance != null, "held asset must load for bone attachment");
                Require(!items[0].Instance.activeSelf, "unbound held asset must not appear on floor");
                Debug.Log("[HeldRecoveryChecks] PASS asset preparation only; bone attachment remains a separate gate");
                UnityEditor.EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); UnityEditor.EditorApplication.Exit(1); }
            finally { UnityEngine.Object.DestroyImmediate(parent); }
        }
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
