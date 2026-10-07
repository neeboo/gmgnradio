using System;
using GMGN.UnityPlayer.Characters;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class CharacterPositionChecks
    {
        public static void Validate()
        {
            var actorObject = new GameObject("position-fixture-actor");
            var host = new GameObject("position-fixture-host");
            var cameraObject = new GameObject("position-fixture-camera");
            RenderTexture texture = null;
            try {
                var actor = actorObject.AddComponent<CharacterWorldAdapter>();
                var visual = GameObject.CreatePrimitive(PrimitiveType.Cube);
                visual.transform.SetParent(actor.transform, false);
                visual.transform.localPosition = new Vector3(0, .5f, 0);
                actor.transform.localPosition = new Vector3(1, .12f, 0);
                var camera = cameraObject.AddComponent<Camera>();
                texture = new RenderTexture(128, 128, 16); camera.targetTexture = texture;
                camera.transform.position = new Vector3(1, 1, -4);
                camera.transform.LookAt(actor.transform.position + Vector3.up * .5f);
                string world = "fixture-a"; bool visible = true; JObject receipt = null;
                var observer = host.AddComponent<UnityCharacterPositionObserver>();
                observer.Initialize(actor, () => world, () => visible, () => camera,
                    value => { receipt = value; return true; });
                var request = new JObject { ["requestID"] = "move", ["worldID"] = world,
                    ["revision"] = 8, ["position"] = new JArray(1, .12, 0), ["groundY"] = .12 };
                observer.ApplySnapshot(new JObject { ["renderRequest"] = request });
                int frame = Time.frameCount + 1;
                world = "fixture-b"; observer.ObserveRenderedCamera(camera, frame);
                if (receipt != null) throw new Exception("Stale world acknowledged position.");
                world = "fixture-a"; visible = false; observer.ObserveRenderedCamera(camera, frame);
                if (receipt != null) throw new Exception("Hidden/compact world acknowledged position.");
                visible = true; actor.transform.localPosition += Vector3.up;
                observer.ObserveRenderedCamera(camera, frame);
                if (receipt != null) throw new Exception("Floating actor acknowledged grounded target.");
                actor.transform.localPosition -= Vector3.up;
                observer.ObserveRenderedCamera(camera, Time.frameCount);
                if (receipt != null) throw new Exception("Pre-application camera frame acknowledged position.");
                var original = actor.transform.localPosition;
                observer.ObserveRenderedCamera(camera, frame);
                if (receipt == null || (int)receipt["renderedFrame"] != frame ||
                    Mathf.Abs((float)receipt["rootGroundDelta"]) > .001f)
                    throw new Exception("Actual grounded root did not produce a camera-frame receipt.");
                if (actor.transform.localPosition != original) throw new Exception("Position observer moved authority actor.");
                // Replay <=20 FPS: each successive render frame receives a newer
                // authority watermark first, with the same grounded destination.
                receipt = null; request["requestID"] = "low-fps";
                int lowFrame = Time.frameCount + 10;
                observer.ApplySnapshot(new JObject { ["renderRequest"] = request.DeepClone() }, lowFrame);
                visible = false;
                for (int offset = 1; offset <= 3; offset++) {
                    request["revision"] = 8 + offset;
                    observer.ApplySnapshot(new JObject { ["renderRequest"] = request.DeepClone() }, lowFrame + offset);
                    observer.ObserveRenderedCamera(camera, lowFrame + offset);
                    if (receipt != null) throw new Exception("Low-FPS hidden frame acknowledged position.");
                }
                visible = true; request["revision"] = 12;
                observer.ApplySnapshot(new JObject { ["renderRequest"] = request.DeepClone() }, lowFrame + 4);
                observer.ObserveRenderedCamera(camera, lowFrame + 4);
                if (receipt == null || (int)receipt["revision"] != 12)
                    throw new Exception("Per-frame authority watermark updates starved the low-FPS camera receipt.");
                receipt = null; request["requestID"] = "new-target";
                observer.ApplySnapshot(new JObject { ["renderRequest"] = request.DeepClone() }, lowFrame + 5);
                observer.ObserveRenderedCamera(camera, lowFrame + 5);
                if (receipt != null) throw new Exception("New request bypassed the first-application frame gate.");
                request["position"] = new JArray(1, .12, -.25);
                actor.transform.localPosition = new Vector3(1, .12f, .25f);
                observer.ApplySnapshot(new JObject { ["renderRequest"] = request.DeepClone() }, lowFrame + 6);
                observer.ObserveRenderedCamera(camera, lowFrame + 6);
                if (receipt != null) throw new Exception("Changed destination bypassed the application-frame gate.");
                observer.ObserveRenderedCamera(camera, lowFrame + 7);
                if (receipt == null) throw new Exception("Changed grounded destination did not acknowledge its later frame.");
                observer.Dispose();
                Debug.Log("PASS position observer: world/visibility/frame/root-ground gates, low-FPS watermark replay, no transform mutation.");
            } finally {
                UnityEngine.Object.DestroyImmediate(host); UnityEngine.Object.DestroyImmediate(actorObject);
                UnityEngine.Object.DestroyImmediate(cameraObject);
                if (texture != null) UnityEngine.Object.DestroyImmediate(texture);
            }
        }
    }
}
