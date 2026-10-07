using System;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    /// Projects local camera/weather requests; receipts require an actual camera frame.
    public sealed class UnitySpatialPresentationController : MonoBehaviour
    {
        WorldWeatherOverlay overlay;
        WorldCameraController cameraController;
        Func<string> currentWorldID;
        Func<bool> normalWorldVisible;
        Func<JObject, bool> sendReceipt;
        JObject pending, expectedCamera, unsentReceipt;
        string snapshotWorldID, lastRequestID, lastRequestWorldID;
        string weather = "clear";
        ulong generation;
        int appliedFrame, lastCameraFrame = -1;
        float nextWeatherPaint;
        bool disposed;

        public bool RendererReady => !disposed && overlay?.panel != null &&
            cameraController?.PresentationCamera != null && lastCameraFrame > 0;
        public void Initialize(VisualElement parent, WorldCameraController camera,
            Func<string> worldID, Func<bool> visible, Func<JObject, bool> receipt)
        {
            cameraController = camera; currentWorldID = worldID;
            normalWorldVisible = visible; sendReceipt = receipt;
            overlay = new WorldWeatherOverlay(); parent.Insert(0, overlay);
            RenderPipelineManager.endCameraRendering += OnCameraRendered;
            Camera.onPostRender += OnBuiltInCameraRendered;
        }
        bool IsNormalWorld() => !disposed && normalWorldVisible?.Invoke() == true &&
            !string.IsNullOrEmpty(snapshotWorldID) && snapshotWorldID == currentWorldID?.Invoke();

        public void ApplySnapshot(JObject snapshot)
        {
            if (disposed || snapshot == null || overlay == null) return;
            string worldID = (string)snapshot["worldID"];
            if (snapshotWorldID != worldID) {
                pending = null; expectedCamera = null; unsentReceipt = null;
                lastRequestID = null; lastRequestWorldID = null;
            }
            snapshotWorldID = worldID;
            generation = (ulong?)snapshot["generation"] ?? 0;
            weather = (string)snapshot["weather"] ?? "clear";
            if (weather != "clear" && weather != "rain" && weather != "thunderstorm") weather = "clear";
            overlay.SetPresentation(weather, generation, IsNormalWorld());
            var request = snapshot["request"] as JObject;
            if (request == null) { pending = null; expectedCamera = null; unsentReceipt = null; return; }
            string id = (string)request["id"], requestedWorld = (string)request["worldID"];
            if (string.IsNullOrEmpty(id) || id == lastRequestID && requestedWorld == lastRequestWorldID) return;
            lastRequestID = id; lastRequestWorldID = requestedWorld;
            pending = (JObject)request.DeepClone(); expectedCamera = null; unsentReceipt = null;
            if (requestedWorld != snapshotWorldID || requestedWorld != currentWorldID?.Invoke()) { Reject("world_changed"); return; }
            if (!IsNormalWorld()) { Reject("normal_world_not_visible"); return; }
            try {
                switch ((string)pending["operation"]) {
                    case "camera":
                        if (cameraController == null) throw new InvalidOperationException("camera_controller_unavailable");
                        expectedCamera = cameraController.ExecuteCommand(pending);
                        break;
                    case "weather":
                        if ((string)pending["weather"] != weather)
                            throw new InvalidOperationException("weather_projection_mismatch");
                        break;
                    case "visibility": break;
                    default: throw new ArgumentException("unknown_spatial_presentation_operation");
                }
                appliedFrame = Time.frameCount;
                overlay.Tick(WorldWeatherOverlay.SecondsSinceReferenceDate(DateTimeOffset.UtcNow));
            } catch (Exception error) { Reject(error.Message); }
        }

        void Update()
        {
            if (disposed || overlay == null) return;
            overlay.SetPresentation(weather, generation, IsNormalWorld());
            if (pending != null && !IsNormalWorld()) Reject("normal_world_not_visible");
            if (Time.unscaledTime >= nextWeatherPaint) {
                nextWeatherPaint = Time.unscaledTime + 1f / 30f;
                overlay.Tick(WorldWeatherOverlay.SecondsSinceReferenceDate(DateTimeOffset.UtcNow));
            }
            FlushReceipt();
        }
        void OnCameraRendered(ScriptableRenderContext _, Camera camera) => ObserveRenderedCamera(camera, Time.frameCount);
        void OnBuiltInCameraRendered(Camera camera) => ObserveRenderedCamera(camera, Time.frameCount);
        public void ObserveRenderedCamera(Camera camera, int renderedFrame)
        {
            if (disposed || camera == null || camera != cameraController?.PresentationCamera ||
                !camera.enabled || !camera.gameObject.activeInHierarchy || camera.pixelWidth <= 0 || camera.pixelHeight <= 0) return;
            lastCameraFrame = renderedFrame;
            if (pending == null || renderedFrame <= appliedFrame) return;
            if (!IsNormalWorld()) { Reject("normal_world_not_visible"); return; }
            JObject readback;
            if ((string)pending["operation"] == "weather") {
                // UI mesh generation must have occurred before this camera frame.
                // An enqueued weather value alone never acknowledges its renderer.
                if (overlay.panel == null || !overlay.HasPainted || overlay.LastPaintedRevision != generation ||
                    overlay.FirstPaintedFrame >= renderedFrame || overlay.Weather != (string)pending["weather"]) return;
                readback = new JObject { ["weather"] = overlay.Weather,
                    ["overlayVisible"] = overlay.PresentationVisible,
                    ["passive"] = overlay.pickingMode == PickingMode.Ignore && !overlay.focusable,
                    ["paintedFrame"] = overlay.FirstPaintedFrame, ["lastPaintedFrame"] = overlay.LastPaintedFrame,
                    ["rainStrokeCount"] = overlay.LastPaintedStrokeCount, ["lightningOpacity"] = overlay.LastLightningOpacity,
                    ["overlayWidth"] = overlay.contentRect.width, ["overlayHeight"] = overlay.contentRect.height };
            } else {
                var cameraState = cameraController.ReadCameraState();
                readback = new JObject { ["camera"] = cameraState };
                if ((string)pending["operation"] == "camera") {
                    if (!JToken.DeepEquals(cameraState, expectedCamera?["camera"])) { Reject("camera_changed_before_render"); return; }
                    readback["direction"] = expectedCamera["direction"]?.DeepClone();
                    readback["distance"] = expectedCamera["distance"]?.DeepClone();
                }
            }
            readback["renderedFrame"] = renderedFrame;
            readback["normalWorldVisible"] = true;
            Complete(true, null, readback);
        }
        void Reject(string error) => Complete(false, error, null);
        void Complete(bool applied, string error, JObject readback)
        {
            if (pending == null) return;
            unsentReceipt = new JObject { ["op"] = "spatial.presentation.receipt",
                ["id"] = pending["id"]?.DeepClone(), ["worldID"] = pending["worldID"]?.DeepClone(),
                ["operation"] = pending["operation"]?.DeepClone(), ["applied"] = applied,
                ["error"] = error, ["readback"] = readback };
            pending = null; expectedCamera = null;
            FlushReceipt();
        }
        void FlushReceipt()
        {
            if (unsentReceipt != null && sendReceipt?.Invoke(unsentReceipt) == true) unsentReceipt = null;
        }
        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            RenderPipelineManager.endCameraRendering -= OnCameraRendered;
            Camera.onPostRender -= OnBuiltInCameraRendered;
            overlay?.RemoveFromHierarchy(); overlay = null;
            pending = null; expectedCamera = null; unsentReceipt = null;
        }
        void OnDestroy() => Dispose();
    }
}
