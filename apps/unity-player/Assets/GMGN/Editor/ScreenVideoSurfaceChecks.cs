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
                controller.Initialize(root, _ => false);
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
                if (root.Q<Label>("screenCommandStatus").parent?.name != "screenVideoPanel" ||
                    root.Q<VisualElement>("screenVideoRows").parent?.name != "screenVideoPanel") throw new Exception("Screen status can be clipped inside scroll viewport");
                if (!root.Q<VisualElement>("screenVideoRows").Q<Label>().text.Contains("已停止")) throw new Exception("Playback state is missing from sticky panel footer");
                controller.SetWorldVisible(false);
                if (owner.GetComponentInChildren<MeshRenderer>() != null) throw new Exception("Hidden world retains active screen");
                controller.SetWorldVisible(true);
                controller.ApplySnapshot(new JObject { ["screens"] = new JArray(), ["frames"] = new JArray() });
                if (((IDictionary)field.GetValue(controller)).Count != 0) throw new Exception("Removed device retains screen");
                var send = typeof(UnityScreenVideoController).GetMethod("SendScreen", BindingFlags.Instance | BindingFlags.NonPublic);
                controller.ApplySnapshot(snapshot);
                send.Invoke(controller, new object[] { "screen.play" });
                if (!root.Q<Label>("screenCommandStatus").text.Contains("HTTPS")) throw new Exception("Missing actionable empty-link validation");
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
                await VerifyPanelLayout();
                Debug.Log("ScreenVideoSurfaceChecks PASS: persistent idle/loading/failed/stopped geometry, removal, visibility, empty HTTPS input, actual compact panel layout");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
            finally { UnityEngine.Object.DestroyImmediate(owner); }
        }
        static async System.Threading.Tasks.Task VerifyPanelLayout() {
            // The fixture owns scale explicitly; the host DLL is absent in Editor.
            foreach (var nativeScale in UnityEngine.Object.FindObjectsByType<NativeUIScale>(FindObjectsSortMode.None)) nativeScale.enabled = false;
            var go = new GameObject("Actual screen panel layout");
            var target = new RenderTexture(1440, 900, 0); target.Create();
            var settings = UnityEngine.Object.Instantiate(Resources.Load<PanelSettings>("PlayerPanel"));
            settings.scaleMode = PanelScaleMode.ConstantPixelSize; settings.scale = 2; settings.targetTexture = target;
            var document = go.AddComponent<UIDocument>(); document.panelSettings = settings;
            var root = document.rootVisualElement;
            Resources.Load<VisualTreeAsset>("Player").CloneTree(root); root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            root.AddToClassList("document-root"); root.AddToClassList("compact-window");
            var controller = go.AddComponent<UnityScreenVideoController>(); controller.Initialize(root.Q(className: "body"), _ => false);
            try {
                foreach (var state in new[] { "未开始", "取流失败：HTTP 403，视频源拒绝了媒体请求。" }) {
                    controller.ApplySnapshot(new JObject { ["screens"] = new JArray(new JObject { ["objectID"] = "layout.tv", ["name"] = "电视", ["state"] = state }), ["frames"] = new JArray() });
                    controller.Show(); root.Q<TextField>("screenURL").value = "https://www.youtube.com/watch?v=1tjrYgF9pes&list=RDNrsQHYM9hT4&index=12";
                    await System.Threading.Tasks.Task.Delay(700);
                    var panel = root.Q("screenVideoPanel"); var input = root.Q<TextField>("screenURL").Q(className: "unity-base-field__input");
                    var play = root.Q<Button>("screenPlay"); var stop = root.Q<Button>("screenStop"); var footer = root.Q("screenVideoRows").Q<Label>();
                    void Require(bool value, string issue) { if (!value) throw new Exception(issue); }
                    Require(root.panel.contextType == ContextType.Player && Mathf.Abs(root.layout.width - 720) < 1 && Mathf.Abs(root.layout.height - 450) < 1, "Fixture must reproduce physical 1440x900 at scale 2: " + root.layout);
                    Require(!(root.Q("screenVideoControls") is ScrollView) && panel.Q<Scroller>() == null, "Unexpected slider/scrollbar in screen form");
                    Require(input.worldBound.height >= 32 && play.worldBound.height >= 32 && stop.worldBound.height >= 32, "Input/buttons clipped: " + input.worldBound + "/" + play.worldBound + "/" + stop.worldBound);
                    Require(play.worldBound.xMax <= stop.worldBound.xMin && input.worldBound.yMax <= play.worldBound.yMin, "Screen controls overlap");
                    Require(panel.worldBound.yMin >= 0 && panel.worldBound.yMax <= root.worldBound.yMax && panel.worldBound.xMin >= 0 && panel.worldBound.xMax <= root.worldBound.xMax, "Screen card escapes compact viewport: " + panel.worldBound);
                    Require(footer.worldBound.height >= footer.resolvedStyle.fontSize && footer.worldBound.yMin >= play.worldBound.yMax && footer.worldBound.yMax <= panel.worldBound.yMax, "Footer clipped or overlapping: " + footer.worldBound);
                    Debug.Log($"ScreenVideoSurfaceChecks compact layout PASS: root={root.layout}; panel={panel.worldBound}; input={input.worldBound}; play={play.worldBound}; stop={stop.worldBound}; footer={footer.worldBound}; state={state}");
                }
            } finally { controller.Dispose(); UnityEngine.Object.Destroy(go); UnityEngine.Object.Destroy(settings); target.Release(); UnityEngine.Object.Destroy(target); }
        }
    }
}
