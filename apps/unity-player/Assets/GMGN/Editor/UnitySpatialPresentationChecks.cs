using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class UnitySpatialPresentationChecks
    {
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
        static bool Near(Vector3 a, Vector3 b) => Vector3.Distance(a, b) < .0001f;
        public static void Validate()
        {
            var host = new GameObject("spatial-presentation-fixture");
            var cameraObject = new GameObject("spatial-presentation-camera");
            var role = new GameObject("spatial-presentation-role");
            UnitySpatialPresentationController presentation = null;
            try {
                var camera = cameraObject.AddComponent<Camera>();
                camera.pixelRect = new Rect(0, 0, 640, 480);
                camera.transform.SetPositionAndRotation(new Vector3(1, 2, 3), Quaternion.Euler(20, 30, 0));
                camera.fieldOfView = 66;
                var homePosition = camera.transform.position; var homeRotation = camera.transform.rotation;
                var controller = host.AddComponent<WorldCameraController>();
                controller.Configure(camera, null);
                bool normal = true, compact = false, editing = false;
                string world = "world-a";
                controller.BindResident(role.transform, world, () => normal && !compact && !editing);
                controller.SetActive(true);
                JObject Move(string direction, float distance = 2) => new JObject { ["direction"] = direction, ["distance"] = distance };
                controller.ExecuteCommand(Move("forward"));
                Require(Near(camera.transform.position, homePosition + camera.transform.forward * 2), "Forward command lost camera pitch.");
                controller.ExecuteCommand(Move("backward"));
                Require(Near(camera.transform.position, homePosition), "Backward command did not reverse forward.");
                var right = new Vector3(Mathf.Cos(30 * Mathf.Deg2Rad), 0, -Mathf.Sin(30 * Mathf.Deg2Rad));
                controller.ExecuteCommand(Move("right", .1f));
                Require(Near(camera.transform.position, homePosition + right * .5f), "Right command did not use horizontal yaw or lower distance clamp.");
                controller.ExecuteCommand(Move("left", 20));
                Require(Near(camera.transform.position, homePosition + right * (.5f - 10)), "Left command or upper clamp was wrong.");
                controller.ExecuteCommand(Move("reset"));
                Require(Near(camera.transform.position, homePosition) && Quaternion.Angle(camera.transform.rotation, homeRotation) < .001f && camera.fieldOfView == 66,
                    "Reset did not restore the normal world camera home without changing FOV.");

                var receipts = new List<JObject>(); var ui = new VisualElement();
                presentation = host.AddComponent<UnitySpatialPresentationController>();
                presentation.Initialize(ui, controller, () => world, () => normal && !compact,
                    receipt => { receipts.Add((JObject)receipt.DeepClone()); return true; });
                ulong revision = 0;
                JObject Snapshot(string id, string operation, string weather = "clear", string requestedWorld = "world-a")
                    => new JObject { ["generation"] = ++revision, ["worldID"] = "world-a", ["weather"] = weather,
                        ["request"] = new JObject { ["id"] = id, ["worldID"] = requestedWorld, ["operation"] = operation,
                            ["direction"] = "forward", ["distance"] = 2, ["weather"] = weather } };
                var first = Snapshot("camera-1", "camera");
                presentation.ApplySnapshot(first);
                var moved = camera.transform.position;
                Require(receipts.Count == 0, "Queued camera command was acknowledged before a render callback.");
                presentation.ObserveRenderedCamera(camera, Time.frameCount + 1);
                Require(receipts.Count == 1 && (bool)receipts[0]["applied"] && receipts[0]["readback"]?["camera"] != null,
                    "Actual camera state did not produce a matching frame receipt.");
                presentation.ApplySnapshot(first);
                Require(Near(camera.transform.position, moved) && receipts.Count == 1, "Repeated request moved camera twice.");
                presentation.ApplySnapshot(Snapshot("weather-unpainted", "weather", "rain"));
                presentation.ObserveRenderedCamera(camera, Time.frameCount + 2);
                Require(receipts.Count == 1, "Unattached/unpainted weather overlay was acknowledged as rendered.");
                compact = true;
                presentation.ApplySnapshot(Snapshot("compact-reject", "camera"));
                Require(receipts.Count == 2 && !(bool)receipts[1]["applied"] && Near(camera.transform.position, moved), "Compact request altered its portrait camera.");
                compact = false; normal = false;
                presentation.ApplySnapshot(Snapshot("hidden-reject", "camera"));
                Require(receipts.Count == 3 && !(bool)receipts[2]["applied"], "Hidden world request was accepted.");
                normal = true;
                presentation.ApplySnapshot(Snapshot("stale-world", "camera", requestedWorld: "world-b"));
                Require(receipts.Count == 4 && (string)receipts[3]["error"] == "world_changed", "Wrong-world request was accepted.");
                editing = true;
                presentation.ApplySnapshot(Snapshot("editing-camera", "camera"));
                presentation.ObserveRenderedCamera(camera, Time.frameCount + 3);
                Require(receipts.Count == 5 && (bool)receipts[4]["applied"], "Explicit camera command was conflated with the editing-only follow suppression.");
                editing = false;
                presentation.ApplySnapshot(Snapshot("camera-overridden", "camera"));
                camera.transform.position += Vector3.right;
                presentation.ObserveRenderedCamera(camera, Time.frameCount + 3);
                Require(receipts.Count == 6 && (string)receipts[5]["error"] == "camera_changed_before_render", "Overridden camera was reported as the requested rendered result.");
                var visiblePosition = camera.transform.position; var visibleRotation = camera.transform.rotation;
                presentation.ApplySnapshot(Snapshot("visibility-confirm", "visibility"));
                Require(receipts.Count == 6, "Visibility preflight succeeded before an actual camera frame.");
                presentation.ObserveRenderedCamera(camera, Time.frameCount + 4);
                Require(receipts.Count == 7 && (bool)receipts[6]["applied"] &&
                    (string)receipts[6]["operation"] == "visibility" && Near(camera.transform.position, visiblePosition) &&
                    Quaternion.Angle(camera.transform.rotation, visibleRotation) < .001f,
                    "Read-only visibility confirmation changed the camera or omitted its frame readback.");
                compact = true;
                presentation.ApplySnapshot(Snapshot("visibility-compact", "visibility"));
                Require(receipts.Count == 8 && !(bool)receipts[7]["applied"] && Near(camera.transform.position, visiblePosition),
                    "Compact visibility preflight was accepted or changed camera state.");

                var overlay = new WorldWeatherOverlay();
                Require(overlay.pickingMode == PickingMode.Ignore && !overlay.focusable && overlay.childCount == 0, "Weather overlay can consume pointer/focus.");
                var rain = WorldWeatherOverlay.RainStrokes(0, 720, 480, .64f);
                Require(rain.Length == 80 && rain[0].Width == 1.4f && rain[1].Width == .7f && Mathf.Abs(rain[0].EndAlpha - .2176f) < .00001f,
                    "Rain count/width/intensity diverged from original Canvas.");
                Require(rain[0].Start == new Vector2(16, -92) && rain[0].End == new Vector2(0, -42), "Rain seed/time trajectory diverged.");
                Require(WorldWeatherOverlay.RainStrokes(1, 1440, 480, .92f).Length == 160, "Rain width/count scaling diverged.");
                Require(WorldWeatherOverlay.LightningOpacity(.03) == .46f && WorldWeatherOverlay.LightningOpacity(.17) == .22f &&
                    WorldWeatherOverlay.LightningOpacity(.3) == 0, "Thunderstorm flash cadence diverged.");
                Require(WorldWeatherOverlay.SecondsSinceReferenceDate(new DateTimeOffset(2001,1,1,0,0,0,TimeSpan.Zero)) == 0, "Weather time does not use the 2001 reference epoch.");
                presentation.Dispose();
                Debug.Log("PASS spatial presentation: read-only normal-frame preflight, real camera direction/clamp/reset, render-receipt gate, hidden/compact/world/override rejection, explicit editing camera, passive original weather geometry/epoch/flashes. Weather pixel rendering requires Player acceptance.");
            } finally {
                presentation?.Dispose();
                UnityEngine.Object.DestroyImmediate(host); UnityEngine.Object.DestroyImmediate(cameraObject); UnityEngine.Object.DestroyImmediate(role);
            }
        }
    }
}
