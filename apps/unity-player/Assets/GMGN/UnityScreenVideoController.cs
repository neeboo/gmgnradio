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
        bool worldVisible = true;
        // This Image is the native AVPlayer renderer, not a product control.
        public void Initialize(VisualElement root) {
            backgroundImage = new Image { pickingMode = PickingMode.Ignore, scaleMode = ScaleMode.ScaleAndCrop,
                uv = new Rect(0, 1, 1, -1) };
            backgroundImage.style.position = Position.Absolute;
            backgroundImage.style.left = backgroundImage.style.right = backgroundImage.style.top = backgroundImage.style.bottom = 0;
            backgroundImage.style.display = DisplayStyle.None;
            root.Insert(0, backgroundImage);
        }
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
                backgroundImage.image = background;
                // Missing-frame snapshots clear Image.image, which resets Image.uv.
                // Restore the native top-down mapping after every background binding.
                backgroundImage.uv = new Rect(0, 1, 1, -1);
                backgroundImage.style.opacity = (float?)value["video"]?["brightness"] ?? 1;
                backgroundImage.style.display = worldVisible ? DisplayStyle.None : DisplayStyle.Flex;
            } else { if (backgroundImage != null) { backgroundImage.image = null; backgroundImage.style.display = DisplayStyle.None; } }
        }
        public void Dispose() {
            foreach (var surface in surfaces.Values) surface.Dispose();
            surfaces.Clear();
            if (background != null) Destroy(background);
            background = null;
            backgroundImage?.RemoveFromHierarchy(); backgroundImage = null;
        }
        void OnDestroy() => Dispose();
    }
}
