using System;
using System.Collections;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class ScreenVideoSurfaceChecks
    {
        [InitializeOnLoadMethod] static void InstallRuntimeCheck() {
            EditorApplication.playModeStateChanged += state => {
                if (state != PlayModeStateChange.EnteredPlayMode || !SessionState.GetBool("GMGN.ScreenSurfaceCheck", false)) return;
                SessionState.SetBool("GMGN.ScreenSurfaceCheck", false); Verify();
            };
        }
        public static void VerifyRuntime() {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            new GameObject("Disabled product bootstrap sentinel").AddComponent<PlayerScreen>().enabled = false;
            SessionState.SetBool("GMGN.ScreenSurfaceCheck", true); EditorApplication.EnterPlaymode();
        }
        public static async void Verify()
        {
            var owner = new GameObject("Screen geometry check");
            try {
                var controller = owner.AddComponent<UnityScreenVideoController>();
                var root = new VisualElement();
                controller.Initialize(root);
                var quad = new JArray(new JArray(-1, 0, 0), new JArray(1, 0, 0), new JArray(1, 1, 0), new JArray(-1, 1, 0));
                var screen = new JObject { ["objectID"] = "fixture.tv", ["name"] = "电视", ["state"] = "未开始", ["geometrySource"] = "calibrated", ["quad"] = quad };
                var snapshot = new JObject { ["screens"] = new JArray(screen), ["frames"] = new JArray() };
                var field = typeof(UnityScreenVideoController).GetField("surfaces", BindingFlags.Instance | BindingFlags.NonPublic);
                foreach (var state in new[] { "未开始", "正在取流", "取流失败：HTTP 403，视频源拒绝了媒体请求。", "已停止" }) {
                    screen["state"] = state;
                    controller.ApplySnapshot(snapshot);
                    if (((IDictionary)field.GetValue(controller)).Count != 1) throw new Exception("Missing persistent screen: " + state);
                    var renderer = owner.GetComponentInChildren<MeshRenderer>();
                    if (renderer == null || renderer.sharedMaterial.mainTexture != null) throw new Exception("Expected black screen without decoded frame");
                    var color = renderer.sharedMaterial.HasProperty("_BaseColor") ? renderer.sharedMaterial.GetColor("_BaseColor") : renderer.sharedMaterial.color;
                    if (color != Color.black) throw new Exception("Screen placeholder is not black");
                    var mesh = renderer.GetComponent<MeshFilter>().sharedMesh;
                    if (mesh.uv[0] != new Vector2(0, 1) || mesh.uv[2] != new Vector2(1, 0)) throw new Exception("Native top-down display UV is inverted");
                }
                if (root.Query<UnityEngine.UIElements.Button>().ToList().Count != 0 || root.Query<TextField>().ToList().Count != 0) throw new Exception("Native screen renderer must not construct retired product controls");
                controller.SetWorldVisible(false);
                if (owner.GetComponentInChildren<MeshRenderer>() != null) throw new Exception("Hidden world retains active screen");
                controller.SetWorldVisible(true);
                controller.ApplySnapshot(new JObject { ["screens"] = new JArray(), ["frames"] = new JArray() });
                if (((IDictionary)field.GetValue(controller)).Count != 0) throw new Exception("Removed device retains screen");
                controller.Dispose();
                var path = Environment.GetEnvironmentVariable("GMGN_SCREEN_VIDEO_MODEL_FIXTURE");
                if (!string.IsNullOrEmpty(path)) {
                    var prop = new JObject { ["size"] = new JObject { ["x"] = 1.443, ["y"] = .862, ["z"] = .302 }, ["sizeLocked"] = true };
                    var actual = await new World.GltfWorldAssetLoader().LoadPreparedAsset(path, prop, System.Threading.CancellationToken.None);
                    try {
                        if (!ScreenVideoSurfaceBinding.TryBind(ScreenVideoSurfaceBinding.TelevisionAssetID, actual.transform, out var anchor, out var aperture)) throw new Exception("Receipt TV mesh did not match calibrated aperture");
                        if (ScreenVideoSurfaceBinding.TryBind("sha256:unknown", actual.transform, out _, out _)) throw new Exception("Uncalibrated asset was accepted");
                        var before = actual.transform.InverseTransformPoint(anchor.TransformPoint(aperture[0]));
                        if (before.y < .05f || before.y > .1f || Mathf.Abs(before.z) < .15f || Mathf.Abs(before.x) > .711f) throw new Exception("Display aperture includes feet, misses front skin or covers bezel: " + before);
                        actual.transform.position = new Vector3(2, 3, 4); actual.transform.rotation = Quaternion.Euler(12, 73, 5);
                        var after = actual.transform.InverseTransformPoint(anchor.TransformPoint(aperture[0]));
                        if ((before - after).sqrMagnitude > .000001f) throw new Exception("Display aperture does not follow TV transform");
                        Debug.Log("ScreenVideoSurfaceChecks actual GLB PASS: calibrated aperture inside bezel, excludes feet, follows model transform, rejects unknown asset");
                    } finally { UnityEngine.Object.Destroy(actual); }
                }
                Debug.Log("ScreenVideoSurfaceChecks PASS: persistent idle/loading/failed/stopped geometry, removal, visibility, no legacy screen controls");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
            finally { UnityEngine.Object.DestroyImmediate(owner); }
        }
    }
}
