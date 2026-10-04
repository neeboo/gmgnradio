using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.UIElements;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer
{
    /// Selection and preview are transient. Only a matching Rust receipt and
    /// authoritative readback may advance the saved projection.
    public sealed class WorldInteractionController : MonoBehaviour
    {
        NativePlayerBackend backend;
        string worldID, requestID;
        IReadOnlyList<RecoveryItem> items;
        Label message;
        RecoveryItem selected;
        Vector3 initialPosition;
        Quaternion initialRotation;
        JObject authority, submitted;
        ulong savedRevision;
        bool active, saving, awaitingReadback;
        VisualElement inputRoot;
        public event Action<string> Status;
        public Func<string, Vector3, Quaternion, JObject, JObject> BuildPlacementRequest;
        public Func<string, Vector3, Quaternion, JObject, Task<JObject>> BuildPlacementRequestAsync;
        public Action<JObject, Transform> ApplyValidatedPreview;
        public event Action<JObject> PreviewChanged;
        public event Action PreviewStarted;
        public event Action PreviewEnded;
        WorldPlacementManipulator manipulator;
        string evaluationID;
        ulong evaluatedRevision;
        bool releasePending;
        int poseVersion, evaluatedPoseVersion;
        float nextEvaluation, releaseDeadline;
        bool buildingEvaluation;
        float? evaluatedSupportHeight;
        public bool OwnsPointer => manipulator?.Dragging == true || releasePending || saving;
        public void ConfigurePlacementGeometry(JObject grid, JArray triangles, JArray blockingVolumes)
        {
            var builder = new PlacementRequestBuilder(grid, triangles, blockingVolumes, items);
            BuildPlacementRequestAsync = builder.BuildAsync;
            ApplyValidatedPreview = builder.Apply;
        }
        public bool BlocksCameraAt(Vector2 screen)
        {
            if (OwnsPointer) return true;
            if (!active || Camera.main == null || items == null) return false;
            var ray = Camera.main.ScreenPointToRay(screen);
            foreach (var item in items) {
                if (item.Instance == null || !item.Instance.activeInHierarchy || item.Status != "restored") continue;
                foreach (var renderer in item.Instance.GetComponentsInChildren<Renderer>())
                    if (renderer.bounds.IntersectRay(ray)) return true;
            }
            return false;
        }

        public void Configure(NativePlayerBackend native, string identity, IReadOnlyList<RecoveryItem> recovered, VisualElement root)
        {
            backend = native; worldID = identity; items = recovered;
            backend.WorldUpdated += OnWorld;
            backend.PlacementEvaluated += OnPlacement;
            message = new Label();
            // Empty space must receive UI Toolkit pointer events too. Reading
            // Mouse.wasPressedThisFrame alone can miss short native clicks.
            inputRoot = root;
            inputRoot.pickingMode = PickingMode.Position;
            manipulator = new WorldPlacementManipulator(this);
            inputRoot.AddManipulator(manipulator);
            if (backend.WorldProjection != null) OnWorld(backend.WorldProjection);
            backend.RequestWorldSnapshot(worldID);
        }

        public void SetActive(bool value)
        {
            active = value;
            if (!value) manipulator?.Abort();
            if (!value && !saving) Cancel();
        }

        void SelectAt(Vector2 point, VisualElement target)
        {
            var root = inputRoot;
            if (root?.panel == null || Camera.main == null) return;
            for (var hit = target; hit != null; hit = hit.parent)
                if (hit is Button || hit is TextField || hit is Slider || hit is ScrollView ||
                    hit.name == "chatPanel" || hit.name == "worldInteraction" || hit.ClassListContains("queue-panel")) {
                    Debug.Log($"World selection blocked by UI: {hit.name}"); return;
                }
            var scale = GetComponent<UIDocument>().panelSettings.scale;
            var screen = new Vector2(point.x * scale, Screen.height - point.y * scale);
            Debug.Log($"World selection pointer: panel={point}; scale={scale}; framebuffer={screen}; focused={Application.isFocused}");
            var ray = Camera.main.ScreenPointToRay(screen);
            RecoveryItem nearest = null; var distance = float.PositiveInfinity;
            foreach (var item in items) {
                if (item.Instance == null || !item.Instance.activeInHierarchy || item.Status != "restored") continue;
                foreach (var renderer in item.Instance.GetComponentsInChildren<Renderer>())
                    if (renderer.bounds.IntersectRay(ray, out var depth) && depth < distance) { nearest = item; distance = depth; }
            }
            if (nearest == null) {
                Cancel();
                Debug.Log("World selection missed all recovered renderer bounds");
                foreach (var item in items) {
                    if (item.Instance == null) continue;
                    foreach (var renderer in item.Instance.GetComponentsInChildren<Renderer>())
                        Debug.Log($"World selection candidate: objectID={item.ObjectID}; bounds={renderer.bounds}; screenCenter={Camera.main.WorldToScreenPoint(renderer.bounds.center)}");
                }
                return;
            }
            Debug.Log($"World selection hit: objectID={nearest.ObjectID}; depth={distance}");
            Cancel(); selected = nearest;
            initialPosition = selected.Instance.transform.position; initialRotation = selected.Instance.transform.rotation;
        }

        void Cancel()
        {
            if (saving) return;
            evaluationID = null; releasePending = false; PreviewEnded?.Invoke();
            if (selected?.Instance != null) selected.Instance.transform.SetPositionAndRotation(initialPosition, initialRotation);
            selected = null;
        }
        void Confirm()
        {
            if (selected == null || authority?["state"] is not JObject state || saving) return;
            submitted = (JObject)state.DeepClone();
            if (submitted["objectStates"]?[selected.ObjectID]?["transform"] is not JObject transform) {
                message.text = "这个物件不在当前空间数据中，请刷新后重试。"; return;
            }
            var p = selected.Instance.transform.position; var q = selected.Instance.transform.rotation;
            transform["position"] = new JObject { ["x"] = p.x, ["y"] = p.y, ["z"] = -p.z };
            transform["rotation"] = new JObject { ["x"] = -q.x, ["y"] = -q.y, ["z"] = q.z, ["w"] = q.w };
            submitted["revision"] = (ulong)submitted["revision"] + 1;
            requestID = "unity-layout:" + Guid.NewGuid().ToString("D");
            saving = backend.CommitWorld(worldID, requestID, (ulong)authority["recordRevision"], submitted,
                new JObject { ["kind"] = "move-preview-confirm", ["objectID"] = selected.ObjectID });
            if (!saving) { message.text = "空间服务忙，这次尚未保存。请稍后确认。"; return; }
            message.text = "正在保存，等待空间服务确认…";
            Status?.Invoke(message.text);
        }

        internal bool BeginGesture(PointerDownEvent e)
        {
            if (!active || saving || releasePending || (e.button != 0 && e.button != 1)) return false;
            var focused = inputRoot.focusController?.focusedElement as VisualElement;
            for (; focused != null; focused = focused.parent) if (focused is TextField) return false;
            // Reuse the proven panel-to-framebuffer selection boundary.
            OnPointerDownForGesture(e);
            if (selected != null) PreviewStarted?.Invoke();
            return selected != null;
        }
        void OnPointerDownForGesture(PointerDownEvent e)
        {
            // Selection handles either button; rotation is performed by the manipulator.
            SelectAt(e.position, e.target as VisualElement);
        }
        internal void MoveGesture(Vector2 start, Vector2 point, int button)
        {
            if (selected == null || saving) return;
            poseVersion++;
            if (button == 1) selected.Instance.transform.rotation = initialRotation * Quaternion.Euler(0, (point.x - start.x) * .5f, 0);
            else {
                var plane = new Plane(Vector3.up, initialPosition);
                if (plane.Raycast(PointerRay(start), out var a) && plane.Raycast(PointerRay(point), out var b))
                    selected.Instance.transform.position = initialPosition + PointerRay(point).GetPoint(b) - PointerRay(start).GetPoint(a);
            }
            Evaluate(false);
        }
        internal void EndGesture(bool changed)
        {
            if (!changed) { Cancel(); return; }
            releasePending = true; releaseDeadline = Time.unscaledTime + 5; Evaluate(true);
        }
        internal void AbortGesture() { Cancel(); }
        Ray PointerRay(Vector2 point)
        {
            var scale = GetComponent<UIDocument>().panelSettings.scale;
            return Camera.main.ScreenPointToRay(new Vector2(point.x * scale, Screen.height - point.y * scale));
        }
        async void Evaluate(bool final)
        {
            if (selected == null || authority == null) return;
            if (buildingEvaluation || evaluationID != null || Time.unscaledTime < nextEvaluation) return;
            nextEvaluation = Time.unscaledTime + .12f;
            evaluatedRevision = (ulong)authority["recordRevision"];
            evaluatedPoseVersion = poseVersion;
            evaluationID = "unity-placement:" + Guid.NewGuid().ToString("D");
            var buildingID = evaluationID;
            JObject payload;
            buildingEvaluation = true;
            try {
                payload = BuildPlacementRequestAsync != null
                    ? await BuildPlacementRequestAsync(selected.ObjectID, selected.Instance.transform.position, selected.Instance.transform.rotation, authority)
                    : BuildPlacementRequest?.Invoke(selected.ObjectID, selected.Instance.transform.position, selected.Instance.transform.rotation, authority);
            } catch (Exception error) {
                Debug.LogWarning("Placement request preparation failed: " + error.GetType().Name);
                payload = null;
            } finally { buildingEvaluation = false; }
            if (evaluationID != buildingID || selected == null) return;
            if (poseVersion != evaluatedPoseVersion) { evaluationID = null; return; }
            if (payload == null || ApplyValidatedPreview == null) {
                evaluationID = null;
                Status?.Invoke("空间摆放几何尚未就绪，这次调整不会保存。");
                if (final) Cancel(); return;
            }
            evaluatedSupportHeight = (float?)payload["anchor"]?["supportHeight"];
            if (!backend.RequestPlacementEvaluation(payload, evaluationID)) {
                evaluationID = null;
            }
        }
        void OnPlacement(JObject update)
        {
            if (evaluationID == null || (string)update["requestID"] != evaluationID || selected == null) return;
            evaluationID = null;
            if (poseVersion != evaluatedPoseVersion) return;
            var result = update["result"] as JObject;
            if (result != null && evaluatedSupportHeight.HasValue) result["previewSupportHeight"] = evaluatedSupportHeight.Value;
            if ((bool?)result?["canPlace"] == true) ApplyValidatedPreview?.Invoke(result, selected.Instance.transform);
            PreviewChanged?.Invoke(result);
            if (!releasePending) return;
            releasePending = false;
            if ((string)update["status"] != "completed" || (bool?)result?["canPlace"] != true ||
                (ulong)authority["recordRevision"] != evaluatedRevision) {
                Status?.Invoke("当前位置不能摆放，调整已取消。"); Cancel(); return;
            }
            // Only the latest released pose, validated against this revision, may write.
            Confirm();
        }
        void OnApplicationFocus(bool focused) { if (!focused) manipulator?.Abort(); }
        void Update()
        {
            if (Keyboard.current?.escapeKey.wasPressedThisFrame == true) manipulator?.Abort();
            if (!releasePending || evaluationID != null) return;
            if (Time.unscaledTime >= releaseDeadline) { Status?.Invoke("空间校验未完成，这次调整未保存。"); Cancel(); return; }
            Evaluate(true);
        }

        void OnWorld(JObject update)
        {
            if ((string)update["worldID"] != worldID) return;
            if (update["result"]?["record"] is JObject record) {
                authority = (JObject)record.DeepClone();
                if (awaitingReadback && (ulong)record["recordRevision"] >= savedRevision) {
                    var persisted = record["state"]?["objectStates"]?[selected.ObjectID]?["transform"];
                    var expected = submitted["objectStates"]?[selected.ObjectID]?["transform"];
                    saving = false; awaitingReadback = false;
                    var matches = MatchesTransform(persisted, expected);
                    Debug.Log($"World save readback: receiptRevision={savedRevision}; recordRevision={record["recordRevision"]}; geometryMatches={matches}; actual={persisted?.ToString(Newtonsoft.Json.Formatting.None)}; expected={expected?.ToString(Newtonsoft.Json.Formatting.None)}");
                    if (matches) {
                        PreviewEnded?.Invoke();
                        selected = null; message.text = "物件位置已保存，并已从空间服务重新读取确认。";
                        Status?.Invoke(message.text);
                    } else { Cancel(); message.text = "空间已有其他更新，预览已撤销，请重新操作。"; }
                }
                foreach (var item in items) {
                    if (item.Instance == null || selected == item) continue;
                    var objectState = record["state"]?["objectStates"]?[item.ObjectID];
                    if (objectState?["transform"] == null) continue;
                    item.Instance.SetActive((bool?)objectState["isEnabled"] == true);
                    item.Instance.transform.SetPositionAndRotation(WorldCoordinates.Position(objectState["transform"]["position"]),
                        WorldCoordinates.Rotation(objectState["transform"]["rotation"]));
                }
                return;
            }
            if (awaitingReadback && (string)update["operation"] == "world.snapshot" && (string)update["status"] == "failed") {
                message.text = "保存回执已收到，读回确认失败；尚不能确认最终位置。"; Status?.Invoke(message.text); return;
            }
            if (!saving || (string)update["requestID"] != requestID) return;
            if ((string)update["status"] == "failed") {
                saving = false; awaitingReadback = false;
                Cancel(); message.text = (string)update["message"] ?? "这次没有保存，请刷新后重试。";
                backend.RequestWorldSnapshot(worldID); return;
            }
            if ((string)update["operation"] == "world.commit" && update["result"]?["revision"] != null) {
                savedRevision = (ulong)update["result"]["revision"];
                awaitingReadback = true;
                if (!backend.RequestWorldSnapshot(worldID)) message.text = "已收到保存回执，但读回确认尚未完成。";
            }
        }

        static bool MatchesTransform(JToken actual, JToken expected)
        {
            // Rust JSON normalizes number spelling; integer 0 and float 0.0
            // represent the same transform. Compare geometry at float precision,
            // not JSON token type or representation. Quaternion signs may flip.
            if (actual == null || expected == null) return false;
            foreach (var component in new[] { "position", "scale" })
                foreach (var axis in new[] { "x", "y", "z" }) {
                    var a = (double?)actual[component]?[axis]; var b = (double?)expected[component]?[axis];
                    if (a == null || b == null || double.IsNaN(a.Value) || double.IsNaN(b.Value) || double.IsInfinity(a.Value) || double.IsInfinity(b.Value) ||
                        Math.Abs(a.Value - b.Value) > 0.000001 * Math.Max(1, Math.Abs(b.Value))) return false;
                }
            var qa = actual["rotation"]; var qb = expected["rotation"];
            if (qa == null || qb == null) return false;
            double dot = 0, normA = 0, normB = 0;
            foreach (var axis in new[] { "x", "y", "z", "w" }) {
                var a = (double?)qa[axis]; var b = (double?)qb[axis];
                if (a == null || b == null || double.IsNaN(a.Value) || double.IsNaN(b.Value)) return false;
                dot += a.Value * b.Value; normA += a.Value * a.Value; normB += b.Value * b.Value;
            }
            return normA > 0 && normB > 0 && Math.Abs(Math.Abs(dot / Math.Sqrt(normA * normB)) - 1) < .000001;
        }

        void OnDestroy() {
            if (backend != null) backend.WorldUpdated -= OnWorld;
            if (backend != null) backend.PlacementEvaluated -= OnPlacement;
            if (manipulator != null) inputRoot?.RemoveManipulator(manipulator);
        }
    }
}
