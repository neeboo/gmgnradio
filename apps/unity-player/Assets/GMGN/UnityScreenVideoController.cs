using System;
using System.Collections.Generic;
using System.Globalization;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    /// Consumes the host's original AVPlayer Metal texture, never decodes media or
    /// starts an audio source. Destroy this controller before closing the native host.
    public sealed class UnityScreenVideoController : MonoBehaviour
    {
        sealed class Surface : IDisposable
        {
            public GameObject Object;
            public Mesh Mesh;
            public Material Material;
            public Texture2D Texture;
            public int Width, Height;
            public void Dispose() {
                if (Object != null) Destroy(Object);
                if (Mesh != null) Destroy(Mesh);
                if (Material != null) Destroy(Material);
                if (Texture != null) Destroy(Texture);
            }
        }
        readonly Dictionary<string, Surface> surfaces = new();
        Texture2D background;
        Image backgroundImage;
        IntPtr backgroundPointer;
        bool backgroundGeometryLogged;
        VisualElement panel, rows;
        VisualElement owner;
        TextField pageURL;
        DropdownField screenChoice;
        Func<JObject, bool> command;
        Label commandStatus;
        bool? commandAccepted;
        string commandIssue;
        readonly List<string> screenIDs = new();
        readonly Dictionary<string, string> screenStates = new();
        bool worldVisible = true;
        string panelContent;
        public bool Visible => panel != null && panel.style.display.value != DisplayStyle.None;

        public void Initialize(VisualElement root, Func<JObject, bool> send) {
            command = send;
            // AVPlayer's IOSurface rows start at the top; UI Toolkit samples external
            // textures in Unity's bottom-up UV convention. Flip this background only.
            backgroundImage = new Image { pickingMode = PickingMode.Ignore, scaleMode = ScaleMode.ScaleAndCrop,
                uv = new Rect(0, 1, 1, -1) };
            backgroundImage.style.position = Position.Absolute;
            backgroundImage.style.left = backgroundImage.style.right = backgroundImage.style.top = backgroundImage.style.bottom = 0;
            backgroundImage.style.display = DisplayStyle.None;
            backgroundImage.RegisterCallback<GeometryChangedEvent>(ObserveBackgroundGeometry);
            root.Insert(0, backgroundImage);
            panel = new VisualElement { name = "screenVideoPanel" }; panel.AddToClassList("card"); panel.AddToClassList("screen-video-panel");
            owner = root; root.RegisterCallback<GeometryChangedEvent>(ResizePanel);
            FitPanel(root.layout.height);
            var sheet = Resources.Load<StyleSheet>("ScreenVideo"); if (sheet != null) panel.styleSheets.Add(sheet);
            var header = new VisualElement(); header.AddToClassList("screen-video-header");
            var title = new Label(UiLocalization.Get("screenTitle")) { name = "screenTitle" }; title.AddToClassList("subtitle"); header.Add(title);
            var close = new Button(Hide) { tooltip = UiLocalization.Get("inboxClose"), name = "screenClose" }; close.AddToClassList("icon-button"); close.Add(new PlayerScreen.ToolbarIcon("close")); header.Add(close); panel.Add(header);
            var controls = new VisualElement { name = "screenVideoControls" }; controls.AddToClassList("screen-video-controls"); panel.Add(controls);
            screenChoice = new DropdownField { name = "screenChoice" }; screenChoice.AddToClassList("screen-video-choice"); controls.Add(screenChoice);
            screenChoice.RegisterValueChangedCallback(_ => RefreshSelectedState());
            pageURL = new TextField { name = "screenURL", label = UiLocalization.Get("screenURL"), multiline = false }; pageURL.AddToClassList("screen-video-url"); controls.Add(pageURL);
            var actions = new VisualElement { name = "screenVideoActions" }; actions.AddToClassList("screen-video-actions"); controls.Add(actions);
            var play = new Button(() => SendScreen("screen.play")) { text = UiLocalization.Get("screenPlay"), name = "screenPlay" }; play.AddToClassList("screen-video-play"); play.AddToClassList("primary"); actions.Add(play);
            actions.Add(new Button(() => SendScreen("screen.stop")) { text = UiLocalization.Get("screenStop"), name = "screenStop" });
            // Keep playback/error state outside the scroll viewport, including compact windows.
            commandStatus = new Label { name = "screenCommandStatus" }; commandStatus.AddToClassList("screen-video-status"); panel.Add(commandStatus);
            rows = new VisualElement { name = "screenVideoRows" }; rows.AddToClassList("screen-video-rows"); panel.Add(rows);
            root.Add(panel); RefreshCommandStatus(); Hide(); UiLocalization.Changed += RefreshLocale;
        }
        void ResizePanel(GeometryChangedEvent e) => FitPanel(e.newRect.height);
        void ObserveBackgroundGeometry(GeometryChangedEvent e) {
            if (backgroundGeometryLogged || worldVisible || backgroundImage.image == null ||
                backgroundImage.panel == null || backgroundImage.resolvedStyle.display == DisplayStyle.None ||
                backgroundImage.resolvedStyle.opacity <= 0 || e.newRect.width <= 0 || e.newRect.height <= 0) return;
            backgroundGeometryLogged = true;
            var texture = backgroundImage.image;
            Debug.Log($"Stage background geometry: uv={backgroundImage.uv}; sourceRect={backgroundImage.sourceRect}; " +
                $"scaleMode={backgroundImage.scaleMode}; worldBound={backgroundImage.worldBound}; " +
                $"textureInstance={texture.GetEntityId()}; textureSize={texture.width}x{texture.height}; " +
                $"boundNativePointer={unchecked((ulong)backgroundPointer.ToInt64()):x}; " +
                $"textureNativePointer={unchecked((ulong)texture.GetNativeTexturePtr().ToInt64()):x}");
        }
        void FitPanel(float height) {
            // Include the toolbar reserve in the same body height budget.
            if (float.IsFinite(height) && height > 0) {
                float available = Mathf.Max(0, Mathf.Min(500, height - 96));
                panel.style.maxHeight = available;
            }
        }
        void RefreshLocale() {
            if (panel == null) return;
            panel.Q<Label>("screenTitle").text = UiLocalization.Get("screenTitle");
            panel.Q<Button>("screenClose").tooltip = UiLocalization.Get("inboxClose");
            panel.Q<Button>("screenPlay").text = UiLocalization.Get("screenPlay");
            panel.Q<Button>("screenStop").text = UiLocalization.Get("screenStop");
            pageURL.label = UiLocalization.Get("screenURL");
            RefreshCommandStatus();
        }
        void RefreshCommandStatus() {
            bool chinese = UiLocalization.LocaleCode?.StartsWith("zh", StringComparison.OrdinalIgnoreCase) == true;
            commandStatus.text = !string.IsNullOrEmpty(commandIssue) ? commandIssue : commandAccepted == false
                ? (chinese ? "主应用未接受新请求。" : "The host did not accept the new request.") : "";
            commandStatus.style.display = string.IsNullOrEmpty(commandStatus.text) ? DisplayStyle.None : DisplayStyle.Flex;
        }
        void SendScreen(string op) {
            bool chinese = UiLocalization.LocaleCode?.StartsWith("zh", StringComparison.OrdinalIgnoreCase) == true;
            commandIssue = null;
            if (screenChoice.index < 0 || screenChoice.index >= screenIDs.Count) commandIssue = chinese ? "请先在空间摆放并选择屏幕。" : "Place and select a screen first.";
            string url = pageURL.value?.Trim() ?? "";
            if (commandIssue == null && op == "screen.play" && (!Uri.TryCreate(url, UriKind.Absolute, out var parsed) || parsed.Scheme != "https"))
                commandIssue = chinese ? "请填写完整的 HTTPS 视频页面链接。" : "Enter a complete HTTPS video page link.";
            if (commandIssue != null) { commandAccepted = false; RefreshCommandStatus(); return; }
            commandAccepted = command?.Invoke(new JObject { ["op"] = op, ["objectID"] = screenIDs[screenChoice.index], ["url"] = url }) == true;
            RefreshCommandStatus();
            if (op == "screen.play" && commandAccepted == true) Hide();
        }
        public void Show() { panel.style.display = DisplayStyle.Flex; command?.Invoke(new JObject { ["op"] = "screen.list" }); }
        public void Hide() { if (panel != null) panel.style.display = DisplayStyle.None; }
        public void SetWorldVisible(bool visible) {
            worldVisible = visible;
            foreach (var surface in surfaces.Values) surface.Object.SetActive(visible);
            if (backgroundImage != null) backgroundImage.style.display = !visible && backgroundImage.image != null ? DisplayStyle.Flex : DisplayStyle.None;
        }
        static bool TextureValue(JObject value, out IntPtr pointer, out int width, out int height) {
            pointer = IntPtr.Zero; width = (int?)value?["width"] ?? 0; height = (int?)value?["height"] ?? 0;
            return SystemInfo.graphicsDeviceType == GraphicsDeviceType.Metal && width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
                (string)value?["format"] == "bgra8" && ulong.TryParse((string)value?["texturePointer"], NumberStyles.HexNumber,
                CultureInfo.InvariantCulture, out var address) && address != 0 && (pointer = new IntPtr(unchecked((long)address))) != IntPtr.Zero;
        }
        static Texture2D BindTexture(Texture2D current, IntPtr pointer, int width, int height) {
            if (current == null || current.width != width || current.height != height) {
                if (current != null) Destroy(current);
                return Texture2D.CreateExternalTexture(width, height, TextureFormat.BGRA32, false, true, pointer);
            }
            current.UpdateExternalTexture(pointer); return current;
        }
        public void ApplySnapshot(JObject value) {
            if (value == null) return;
            if (commandAccepted == false && string.IsNullOrEmpty(commandIssue) && !string.IsNullOrEmpty((string)value["commandNotice"])) {
                commandIssue = (string)value["commandNotice"]; RefreshCommandStatus();
            }
            var kept = new HashSet<string>();
            var frames = new Dictionary<string, JObject>();
            foreach (var token in value["frames"] as JArray ?? new JArray())
                if (token is JObject frame && !string.IsNullOrEmpty((string)frame["objectID"])) frames[(string)frame["objectID"]] = frame;
            // Geometry belongs to the placed device; decoder readiness only changes its texture.
            foreach (var token in value["screens"] as JArray ?? new JArray()) {
                if (token is not JObject screen || screen["quad"] is not JArray corners || corners.Count != 4) continue;
                string id = (string)screen["objectID"]; if (string.IsNullOrEmpty(id)) continue;
                var vertices = new Vector3[4]; bool valid = true;
                for (int i = 0; i < 4; i++) {
                    if (corners[i] is not JArray p || p.Count != 3) { valid = false; break; }
                    vertices[i] = new Vector3((float)p[0], (float)p[1], -(float)p[2]);
                    if (!float.IsFinite(vertices[i].x) || !float.IsFinite(vertices[i].y) || !float.IsFinite(vertices[i].z)) valid = false;
                }
                if (!valid) continue;
                Transform anchor = null;
                string assetID = (string)screen["assetID"];
                if (assetID == ScreenVideoSurfaceBinding.TelevisionAssetID) {
                    var prop = GetComponent<WorldRuntimeBridge>()?.GetPlacedObjectTransform(id);
                    if (!ScreenVideoSurfaceBinding.TryBind(assetID, prop, out anchor, out vertices)) continue;
                } else if ((string)screen["geometrySource"] != "calibrated") continue;
                if (!surfaces.TryGetValue(id, out var surface)) {
                    var shader = Shader.Find("Universal Render Pipeline/Unlit") ?? Shader.Find("Unlit/Texture");
                    if (shader == null) { Debug.LogError("Native screen shader unavailable"); continue; }
                    surface = new Surface { Object = new GameObject("Native screen " + id), Mesh = new Mesh(), Material = new Material(shader) };
                    surface.Object.AddComponent<MeshFilter>().sharedMesh = surface.Mesh;
                    surface.Object.AddComponent<MeshRenderer>().sharedMaterial = surface.Material;
                    surface.Material.SetFloat("_Cull", 0);
                    surfaces.Add(id, surface);
                }
                surface.Object.transform.SetParent(anchor != null ? anchor : transform, false);
                surface.Object.transform.localPosition = Vector3.zero;
                surface.Object.transform.localRotation = Quaternion.identity;
                surface.Object.transform.localScale = Vector3.one;
                bool ready = frames.TryGetValue(id, out var currentFrame) && TextureValue(currentFrame, out _, out _, out _);
                if (ready) {
                    TextureValue(currentFrame, out var pointer, out var width, out var height);
                    surface.Texture = BindTexture(surface.Texture, pointer, width, height);
                } else if (surface.Texture != null) { Destroy(surface.Texture); surface.Texture = null; }
                surface.Mesh.vertices = vertices; surface.Mesh.triangles = new[] { 0, 2, 1, 0, 3, 2 };
                // AVPlayer Metal pixels are top-down, matching the native background path above.
                // The bottom display corners therefore sample V=1, and top corners sample V=0.
                surface.Mesh.uv = new[] { new Vector2(0, 1), new Vector2(1, 1), new Vector2(1, 0), new Vector2(0, 0) };
                surface.Mesh.RecalculateBounds(); surface.Mesh.RecalculateNormals();
                surface.Material.mainTexture = surface.Texture;
                if (surface.Material.HasProperty("_BaseMap")) surface.Material.SetTexture("_BaseMap", surface.Texture);
                if (surface.Material.HasProperty("_BaseColor")) surface.Material.SetColor("_BaseColor", ready ? Color.white : Color.black);
                if (surface.Material.HasProperty("_Color")) surface.Material.SetColor("_Color", ready ? Color.white : Color.black);
                surface.Object.SetActive(worldVisible); kept.Add(id);
            }
            var removed = new List<string>();
            foreach (var entry in surfaces) if (!kept.Contains(entry.Key)) { entry.Value.Dispose(); removed.Add(entry.Key); }
            foreach (var id in removed) surfaces.Remove(id);
            if (value["background"] is JObject video && TextureValue(video, out var videoPointer, out var videoWidth, out var videoHeight)) {
                background = BindTexture(background, videoPointer, videoWidth, videoHeight);
                backgroundPointer = videoPointer;
                backgroundImage.image = background;
                // Missing-frame snapshots clear Image.image, which resets Image.uv.
                // Restore the native top-down mapping after every background binding.
                backgroundImage.uv = new Rect(0, 1, 1, -1);
                backgroundImage.style.opacity = (float?)value["video"]?["brightness"] ?? 1;
                backgroundImage.style.display = worldVisible ? DisplayStyle.None : DisplayStyle.Flex;
            } else { if (backgroundImage != null) { backgroundImage.image = null; backgroundImage.style.display = DisplayStyle.None; } }
            RefreshPanel(value["screens"] as JArray ?? new JArray());
        }
        void RefreshPanel(JArray screens) {
            if (screenChoice == null) return;
            var presentation = new JArray();
            foreach (var screen in screens) presentation.Add(new JObject {
                ["objectID"] = (string)screen["objectID"], ["name"] = (string)screen["name"], ["state"] = (string)screen["state"]
            });
            string next = presentation.ToString(Newtonsoft.Json.Formatting.None);
            if (next == panelContent) return;
            panelContent = next;
            string previous = screenChoice.index >= 0 && screenChoice.index < screenIDs.Count ? screenIDs[screenChoice.index] : null;
            screenIDs.Clear(); screenStates.Clear(); var labels = new List<string>();
            foreach (var screen in screens) {
                screenIDs.Add((string)screen["objectID"]); labels.Add((string)screen["name"]);
                screenStates[(string)screen["objectID"]] = (string)screen["state"];
            }
            screenChoice.choices = labels; var index = screenIDs.IndexOf(previous);
            screenChoice.index = index >= 0 ? index : screenIDs.Count > 0 ? 0 : -1;
            RefreshSelectedState();
        }
        void RefreshSelectedState() {
            if (rows == null) return;
            rows.Clear();
            if (screenChoice.index >= 0 && screenChoice.index < screenIDs.Count &&
                screenStates.TryGetValue(screenIDs[screenChoice.index], out var state)) rows.Add(new Label(state));
        }
        public void Dispose() {
            UiLocalization.Changed -= RefreshLocale;
            owner?.UnregisterCallback<GeometryChangedEvent>(ResizePanel);
            backgroundImage?.UnregisterCallback<GeometryChangedEvent>(ObserveBackgroundGeometry);
            foreach (var surface in surfaces.Values) surface.Dispose(); surfaces.Clear();
            if (background != null) Destroy(background);
            panel?.RemoveFromHierarchy(); backgroundImage?.RemoveFromHierarchy();
        }
        void OnDestroy() => Dispose();
    }
}
