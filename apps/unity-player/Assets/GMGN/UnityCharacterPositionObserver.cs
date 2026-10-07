using System;
using GMGN.UnityPlayer.Characters;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Rendering;

namespace GMGN.UnityPlayer
{
    /// Camera-frame observer only: never moves the actor, collision or objects.
    public sealed class UnityCharacterPositionObserver : MonoBehaviour
    {
        CharacterWorldAdapter character;
        Func<string> currentWorld;
        Func<bool> visible;
        Func<Camera> currentCamera;
        Func<JObject, bool> send;
        JObject request;
        int appliedFrame;
        bool disposed;

        public void Initialize(CharacterWorldAdapter actor, Func<string> worldID,
            Func<bool> normalWorldVisible, Func<Camera> presentationCamera,
            Func<JObject, bool> sendReceipt)
        {
            character = actor; currentWorld = worldID; visible = normalWorldVisible;
            currentCamera = presentationCamera; send = sendReceipt;
            RenderPipelineManager.endCameraRendering += OnCameraRendered;
            Camera.onPostRender += ObserveCamera;
        }
        public void ApplySnapshot(JObject snapshot) => ApplySnapshot(snapshot, Time.frameCount);
        public void ApplySnapshot(JObject snapshot, int receivedFrame)
        {
            var next = snapshot?["renderRequest"] as JObject;
            if (JToken.DeepEquals(next, request)) return;
            bool sameTarget = next != null && request != null &&
                JToken.DeepEquals(next["worldID"], request["worldID"]) &&
                JToken.DeepEquals(next["requestID"], request["requestID"]) &&
                JToken.DeepEquals(next["position"], request["position"]) &&
                JToken.DeepEquals(next["groundY"], request["groundY"]);
            request = next == null ? null : (JObject)next.DeepClone();
            // Idle authority ticks advance revision. At <=20 FPS a new watermark
            // can arrive every render frame; keep the first target-application
            // frame so those updates cannot starve the camera receipt.
            if (!sameTarget) appliedFrame = receivedFrame;
        }
        void OnCameraRendered(ScriptableRenderContext _, Camera camera) => ObserveCamera(camera);
        void ObserveCamera(Camera camera) => ObserveRenderedCamera(camera, Time.frameCount);
        public void ObserveRenderedCamera(Camera camera, int renderedFrame)
        {
            if (disposed || request == null || character == null || camera == null ||
                camera != currentCamera?.Invoke() || !camera.enabled || !camera.gameObject.activeInHierarchy ||
                camera.pixelWidth <= 0 || camera.pixelHeight <= 0 || renderedFrame <= appliedFrame ||
                visible?.Invoke() != true || (string)request["worldID"] != currentWorld?.Invoke() ||
                !character.gameObject.activeInHierarchy) return;
            var target = request["position"] as JArray;
            if (target == null || target.Count != 3) return;
            var position = character.transform.localPosition;
            var authority = new Vector3((float)target[0], (float)target[1], -(float)target[2]);
            if (!float.IsFinite(authority.x) || !float.IsFinite(authority.y) || !float.IsFinite(authority.z) ||
                Vector3.Distance(position, authority) > .05f) return;
            // The host collision validator admitted the target's ground Y. This
            // verifies rendered actor-root Y, not a claim about animated toes.
            if (request["groundY"] == null) return;
            float groundY = (float)request["groundY"];
            if (!float.IsFinite(groundY) || Mathf.Abs(position.y - groundY) > .05f) return;
            var planes = GeometryUtility.CalculateFrustumPlanes(camera);
            bool actorDrawn = false;
            foreach (var renderer in character.GetComponentsInChildren<Renderer>()) {
                if (renderer.enabled && renderer.gameObject.activeInHierarchy &&
                    (camera.cullingMask & (1 << renderer.gameObject.layer)) != 0 &&
                    GeometryUtility.TestPlanesAABB(planes, renderer.bounds)) { actorDrawn = true; break; }
            }
            if (!actorDrawn) return;
            var receipt = new JObject { ["op"] = "presence.position.rendered",
                ["requestID"] = request["requestID"]?.DeepClone(),
                ["worldID"] = request["worldID"]?.DeepClone(),
                ["revision"] = request["revision"]?.DeepClone(),
                ["position"] = new JArray(position.x, position.y, -position.z),
                ["rootY"] = position.y, ["groundY"] = groundY,
                ["rootGroundDelta"] = position.y - groundY,
                ["groundEvidence"] = "authority-collision-target",
                ["renderedFrame"] = renderedFrame, ["normalWorldVisible"] = true };
            if (send?.Invoke(receipt) == true) request = null;
        }
        public void Dispose()
        {
            if (disposed) return;
            disposed = true; request = null;
            RenderPipelineManager.endCameraRendering -= OnCameraRendered;
            Camera.onPostRender -= ObserveCamera;
        }
        void OnDestroy() => Dispose();
    }
}
