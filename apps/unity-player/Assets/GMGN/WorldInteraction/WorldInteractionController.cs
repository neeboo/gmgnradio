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
        List<RecoveryItem> mutableItems;
        JObject deviceTemplate, lastPlacementPayload, placementGrid;
        JArray placementTriangles, placementBlocking;
        public Func<JObject, bool> PlaceDevice;
        public event Action<BuiltinWorldDevice> DeviceRestored;
        bool inventoryPreview;
        bool deviceExistingPreview;
        bool deviceRelocationPreview;
        JArray deviceTemplates;
        public void ConfigureDeviceTemplates(JArray templates) => deviceTemplates = templates == null ? new JArray() : (JArray)templates.DeepClone();
        Label message;
        RecoveryItem selected;
        Vector3 initialPosition;
        Vector3 gesturePosition;
        Quaternion gestureRotation;
        Quaternion initialRotation;
        JObject authority, submitted;
        ulong savedRevision;
        bool active, saving, awaitingReadback;
        bool editing;
        public bool IsEditing => active && editing;
        public void SetEditing(bool value)
        {
            editing = value && active;
            if (!editing) { manipulator?.Abort(); Cancel(); }
        }
        string savedObjectID;
        bool readbackUnconfirmed;
        int readbackAttempts;
        float nextReadback;
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
        int pendingEscapeFrame = -1;
        float? evaluatedSupportHeight;
        public bool OwnsPointer => manipulator?.Dragging == true || releasePending || saving || deviceTemplate != null || deviceRelocationPreview || inventoryPreview;
        PlacementRequestBuilder placementBuilder;
        public void ConfigurePlacementGeometry(JObject grid, JArray triangles, JArray blockingVolumes)
        {
            bool sameGeometry = ReferenceEquals(placementGrid, grid) && ReferenceEquals(placementTriangles, triangles) &&
                ReferenceEquals(placementBlocking, blockingVolumes);
            placementGrid = grid; placementTriangles = triangles; placementBlocking = blockingVolumes;
            // An in-flight request owns its builder's dictionaries until assembly
            // finishes; changing recovered objects must not mutate that snapshot.
            if (!sameGeometry || placementBuilder == null || buildingEvaluation)
                placementBuilder = new PlacementRequestBuilder(grid, triangles, blockingVolumes, items);
            else placementBuilder.UpdateItems(items);
            BuildPlacementRequestAsync = placementBuilder.BuildAsync;
            ApplyValidatedPreview = placementBuilder.Apply;
        }
        public bool BlocksCameraAt(Vector2 screen)
        {
            if (OwnsPointer) return true;
            if (!active || Camera.main == null || items == null) return false;
            var ray = Camera.main.ScreenPointToRay(screen);
            foreach (var item in items) {
                if (item.Instance == null || !item.Instance.activeInHierarchy || item.Status != "restored") continue;
                if (!IsEditing && item.Instance.GetComponent<BuiltinWorldDevice>() == null) continue;
                foreach (var renderer in item.Instance.GetComponentsInChildren<Renderer>())
                    if (renderer.bounds.IntersectRay(ray)) return true;
            }
            return false;
        }

        public void Configure(NativePlayerBackend native, string identity, IReadOnlyList<RecoveryItem> recovered, VisualElement root)
        {
            backend = native; worldID = identity; mutableItems = new List<RecoveryItem>(recovered); items = mutableItems;
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
            if (!value) editing = false;
            if (value && readbackUnconfirmed) backend.RequestWorldSnapshot(worldID);
            if (!value) manipulator?.Abort();
            if (!value && !saving) Cancel();
        }

        void SelectAt(Vector2 point, VisualElement target)
        {
            var root = inputRoot;
            if (root?.panel == null || Camera.main == null) return;
            for (var hit = target; hit != null; hit = hit.parent)
                if (hit is Button || hit is TextField || hit is Slider || hit is ScrollView) {
                    Debug.Log($"World selection blocked by UI: {hit.name}"); return;
                }
            var ray = PointerRay(point);
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
            if ((deviceTemplate != null || inventoryPreview) && nearest == selected) return;
            Cancel(); selected = nearest;
            initialPosition = selected.Instance.transform.position; initialRotation = selected.Instance.transform.rotation;
        }

        void Cancel()
        {
            if (saving) return;
            evaluationID = null; releasePending = false; PreviewEnded?.Invoke();
            if (selected?.Instance != null) {
                var persisted = authority?["state"]?["objectStates"]?[selected.ObjectID]?["transform"];
                if (persisted?["position"] != null && persisted["rotation"] != null)
                    selected.Instance.transform.SetPositionAndRotation(WorldCoordinates.Position(persisted["position"]), WorldCoordinates.Rotation(persisted["rotation"]));
                else selected.Instance.transform.SetPositionAndRotation(initialPosition, initialRotation);
            }
            if (inventoryPreview && selected?.Instance != null) {
                bool placed = (bool?)authority?["state"]?["objectStates"]?[selected.ObjectID]?["isEnabled"] == true &&
                    authority?["state"]?["propTombstones"]?[selected.ObjectID] == null &&
                    WorldProjectionOptional.HeldID(authority?["state"]) != selected.ObjectID;
                selected.Instance.SetActive(placed); selected.Status = placed ? "restored" : "inventory";
            }
            if (deviceTemplate != null && selected != null) {
                if (!deviceExistingPreview) {
                    mutableItems.Remove(selected);
                    if (selected.Instance != null) Destroy(selected.Instance);
                }
                deviceTemplate = null;
                deviceExistingPreview = false;
                RebuildDeviceGeometry();
            }
            inventoryPreview = false; deviceTemplate = null; deviceExistingPreview = false;
            selected = null; deviceRelocationPreview = false;
        }

        void RebuildDeviceGeometry()
        {
            if (placementGrid != null) ConfigurePlacementGeometry(placementGrid, placementTriangles, placementBlocking);
        }
        public void UpdateRecoveredItems(IReadOnlyList<RecoveryItem> recovered)
        {
            if (saving) return;
            var replacement = selected == null ? null : new List<RecoveryItem>(recovered).Find(item => item.ObjectID == selected.ObjectID);
            bool retain = replacement?.Instance != null && selected?.Instance != null &&
                replacement.Instance == selected.Instance &&
                authority?["state"]?["objectStates"]?[selected.ObjectID] != null &&
                authority?["state"]?["propTombstones"]?[selected.ObjectID] == null &&
                WorldProjectionOptional.HeldID(authority?["state"]) != selected.ObjectID;
            if (!retain) Cancel();
            else { selected = replacement; if (inventoryPreview) { selected.Instance.SetActive(true); selected.Status = "restored"; } }
            mutableItems = new List<RecoveryItem>(recovered); items = mutableItems; RebuildDeviceGeometry();
        }
        public bool BeginInventoryPlacement(string objectID, Vector3? position = null)
        {
            if (!IsEditing || saving || authority == null || placementGrid == null) return false;
            if (WorldProjectionOptional.HeldID(authority["state"]) == objectID) return false;
            var item = mutableItems.Find(value => value.ObjectID == objectID && (value.Status == "inventory" || value.Status == "restored") && value.Instance != null);
            if (item == null) return false;
            Cancel(); selected = item; inventoryPreview = true; initialPosition = item.Instance.transform.position;
            initialRotation = item.Instance.transform.rotation; item.Instance.SetActive(true); item.Status = "restored";
            if (position.HasValue) item.Instance.transform.position = position.Value;
            // The host seeds previews in front of the camera. Inventory props
            // belong on actual support geometry, never on a camera-height plane.
            ProjectPreviewToSurface(new Ray(item.Instance.transform.position, Vector3.down));
            active = true; RebuildDeviceGeometry(); PreviewStarted?.Invoke(); return true;
        }
        // Selection creates only a cancellable preview. No backend command runs
        // until the released pointer pose passes authority placement evaluation.
        public bool BeginDevicePlacement(JObject template, Vector3 position)
        {
            if (!IsEditing || saving || authority == null || placementGrid == null || PlaceDevice == null) return false;
            var id = (string)template?["id"];
            if (string.IsNullOrEmpty(id)) return false;
            var existing = authority["state"]?["objectStates"]?[id];
            if ((bool?)existing?["isEnabled"] == true && existing["metadata"]?["gmgn.builtin-device.v1"] != null) {
                var item = mutableItems.Find(value => value.ObjectID == id && value.Instance != null && value.Status == "restored");
                if (item == null) return false;
                Cancel(); selected = item; deviceTemplate = (JObject)template.DeepClone();
                initialPosition = item.Instance.transform.position; initialRotation = item.Instance.transform.rotation;
                deviceRelocationPreview = true; item.Instance.transform.position = position;
                active = true; RebuildDeviceGeometry(); PreviewStarted?.Invoke(); return true;
            }
            Cancel();
            deviceTemplate = (JObject)template.DeepClone();
            selected = mutableItems.Find(item => item.ObjectID == id && item.Instance != null);
            deviceExistingPreview = selected != null;
            if (selected == null) {
                var marker = BuiltinWorldDevice.CreateMarker(template, transform);
                selected = new RecoveryItem { ObjectID = id, Status = "restored", Instance = marker.gameObject };
                mutableItems.Add(selected);
            }
            initialPosition = selected.Instance.transform.position; initialRotation = selected.Instance.transform.rotation;
            selected.Instance.transform.position = position;
            active = true; RebuildDeviceGeometry(); PreviewStarted?.Invoke(); return true;
        }

        public void ApplyDevicePlacement(JObject update)
        {
            if (!saving || deviceTemplate == null || (string)update["requestID"] != requestID) return;
            if ((string)update["status"] == "failed") {
                saving = false;
                var code = (string)update["code"] ?? "world_device_unavailable";
                message.text = "未保存（" + code + "），预览已保留，可调整位置再确认。";
                Status?.Invoke(message.text); backend.RequestWorldSnapshot(worldID); return;
            }
            if (update["result"]?["record"] is not JObject record) return;
            var saved = record["state"]?["objectStates"]?[selected.ObjectID];
            if ((bool?)saved?["isEnabled"] != true || saved["metadata"]?["gmgn.builtin-device.v1"] == null) return;
            selected.Instance.transform.SetPositionAndRotation(WorldCoordinates.Position(saved["transform"]["position"]), WorldCoordinates.Rotation(saved["transform"]["rotation"]));
            authority = (JObject)record.DeepClone(); saving = false; deviceTemplate = null;
            deviceExistingPreview = false; deviceRelocationPreview = false;
            DeviceRestored?.Invoke(selected.Instance.GetComponent<BuiltinWorldDevice>());
            selected = null; PreviewEnded?.Invoke(); RebuildDeviceGeometry();
        }

        public void RestoreDevices(JObject record, Transform parent)
        {
            if (record?["state"]?["objectStates"] is not JObject states) return;
            foreach (var entry in states.Properties()) {
                var raw = (string)entry.Value["metadata"]?["gmgn.builtin-device.v1"];
                if ((bool?)entry.Value["isEnabled"] != true || mutableItems.Exists(item => item.ObjectID == entry.Name)) continue;
                JObject declaration = raw == null ? null : JObject.Parse(raw);
                if (declaration == null && deviceTemplates != null)
                    foreach (var template in deviceTemplates) if ((string)template["id"] == entry.Name) { declaration = template as JObject; break; }
                if (declaration == null) continue;
                if ((string)declaration["id"] != entry.Name) continue;
                var marker = BuiltinWorldDevice.CreateMarker(declaration, parent);
                marker.transform.SetPositionAndRotation(WorldCoordinates.Position(entry.Value["transform"]["position"]), WorldCoordinates.Rotation(entry.Value["transform"]["rotation"]));
                mutableItems.Add(new RecoveryItem { ObjectID = entry.Name, Status = "restored", Instance = marker.gameObject });
                DeviceRestored?.Invoke(marker);
            }
            RebuildDeviceGeometry();
        }
        void Confirm()
        {
            if (!IsEditing || selected == null || authority?["state"] is not JObject state || saving) return;
            if (deviceTemplate != null) {
                requestID = "unity-device:" + Guid.NewGuid().ToString("D");
                saving = PlaceDevice?.Invoke(new JObject { ["op"] = "world.device.place", ["worldID"] = worldID,
                    ["requestID"] = requestID, ["templateID"] = (string)deviceTemplate["id"],
                    ["expectedRevision"] = (ulong)authority["recordRevision"], ["expectedLayoutRevision"] = (ulong)state["layoutRevision"],
                    ["position"] = OriginalPointerIntent()["position"], ["yaw"] = OriginalPointerIntent()["yaw"] }) == true;
                if (!saving) Status?.Invoke("空间服务忙，摆放预览已保留，请稍后再确认。");
                return;
            }
            requestID = "unity-layout:" + Guid.NewGuid().ToString("D");
            saving = backend.RequestPropOperation("world.prop.command", worldID, requestID,
                (ulong)authority["recordRevision"], (ulong)state["layoutRevision"], OriginalPointerIntent());
            if (!saving) { message.text = "空间服务忙，调整预览已保留，请稍后重试。"; Status?.Invoke(message.text); return; }
            message.text = "正在保存，等待空间服务确认…";
            Status?.Invoke(message.text);
        }
        JObject PointerPlaceIntent()
        {
            var p = selected.Instance.transform.position;
            return new JObject { ["op"] = "place", ["objectID"] = selected.ObjectID,
                ["position"] = new JArray(p.x, p.y, -p.z),
                ["yaw"] = -selected.Instance.transform.eulerAngles.y * Mathf.Deg2Rad };
        }

        JObject OriginalPointerIntent()
            => poseVersion == evaluatedPoseVersion && (string)lastPlacementPayload?["objectID"] == selected?.ObjectID
                ? (JObject)lastPlacementPayload.DeepClone() : PointerPlaceIntent();

        internal bool BeginGesture(PointerDownEvent e)
        {
            if (GetComponent<GPUIChat2Probe>()?.BlocksWorldInput == true) return false;
            if (!active || saving || awaitingReadback || readbackUnconfirmed || (e.button != 0 && e.button != 1)) return false;
            for (var hit = e.target as VisualElement; hit != null; hit = hit.parent)
                if (hit is Button || hit is TextField || hit is Slider || hit is ScrollView) return false;
            var focused = inputRoot.focusController?.focusedElement as VisualElement;
            for (; focused != null; focused = focused.parent) if (focused is TextField) return false;
            // A new gesture supersedes a released pose still being evaluated.
            // Otherwise a right-drag's async validation locks out the following
            // left-drag; stale evaluation receipts must not commit its old pose.
            if (releasePending) { releasePending = false; evaluationID = null; poseVersion++; }
            // Reuse the proven panel-to-framebuffer selection boundary.
            OnPointerDownForGesture(e);
            if (!IsEditing && (e.button != 0 || selected?.Instance?.GetComponent<BuiltinWorldDevice>() == null)) {
                Cancel(); return false;
            }
            if (selected != null) {
                // Keep cancellation's original pose separate from the visible
                // preview pose used as the origin of this pointer gesture.
                gesturePosition = selected.Instance.transform.position;
                gestureRotation = selected.Instance.transform.rotation;
                if (IsEditing) PreviewStarted?.Invoke();
            }
            return selected != null;
        }
        void OnPointerDownForGesture(PointerDownEvent e)
        {
            // A catalog preview already owns the gesture. Rotation can start
            // anywhere in the world viewport without reselecting its mesh.
            if ((deviceTemplate != null || deviceRelocationPreview || inventoryPreview) && selected != null && e.button == 1) return;
            if ((deviceTemplate != null || deviceRelocationPreview || inventoryPreview) && selected != null && e.button == 0) {
                var ray = PointerRay(e.position);
                // The initial preview can be at camera height. Project onto the
                // actual room surface, so lowering to the validated support
                // height does not move the object away from the clicked point.
                ProjectPreviewToSurface(ray);
                return;
            }
            // Selection handles either button; rotation is performed by the manipulator.
            SelectAt(e.position, e.target as VisualElement);
        }
        bool ProjectPreviewToSurface(Ray ray)
        {
            if (selected?.Instance == null || !PlacementRequestBuilder.TryPickEnvironment(placementTriangles, ray,
                out var point, supportOnly: inventoryPreview)) return false;
            selected.Instance.transform.position = point;
            return true;
        }
        internal void MoveGesture(Vector2 start, Vector2 point, int button)
        {
            if (!IsEditing || selected == null || saving) return;
            poseVersion++;
            if (button == 1) selected.Instance.transform.rotation = gestureRotation * Quaternion.Euler(0, (point.x - start.x) * .5f, 0);
            else if (inventoryPreview) {
                // A plane through the initial camera-height preview can send
                // near-horizontal pointer rays tens of metres outside the room.
                if (!ProjectPreviewToSurface(PointerRay(point))) return;
            }
            else {
                var plane = new Plane(Vector3.up, gesturePosition);
                if (plane.Raycast(PointerRay(start), out var a) && plane.Raycast(PointerRay(point), out var b))
                    selected.Instance.transform.position = gesturePosition + PointerRay(point).GetPoint(b) - PointerRay(start).GetPoint(a);
            }
            Evaluate(false);
        }
        internal void EndGesture(bool changed, int button = 0)
        {
            if (!IsEditing) {
                var device = !changed ? selected?.Instance?.GetComponent<BuiltinWorldDevice>() : null;
                Cancel(); device?.Activate(); return;
            }
            if (button == 1 && (deviceTemplate != null || deviceRelocationPreview || inventoryPreview)) {
                // Catalog rotation changes the preview; only a left release
                // confirms placement. A right click must not hide its item.
                releasePending = false; Evaluate(false); return;
            }
            if (!changed && (deviceTemplate != null || deviceRelocationPreview || inventoryPreview)) {
                poseVersion++;
                releasePending = true; releaseDeadline = Time.unscaledTime + 5; Evaluate(true);
                return;
            }
            if (!changed) {
                var device = deviceTemplate == null && !inventoryPreview ? selected?.Instance?.GetComponent<BuiltinWorldDevice>() : null;
                Cancel(); device?.Activate(); return;
            }
            releasePending = true; releaseDeadline = Time.unscaledTime + 5; Evaluate(true);
        }
        internal void AbortGesture() { Cancel(); }
        Ray PointerRay(Vector2 point)
        {
            var panel = GetComponent<UIDocument>().rootVisualElement.panel;
            var origin = RuntimePanelUtils.ScreenToPanel(panel, Vector2.zero);
            var end = RuntimePanelUtils.ScreenToPanel(panel, new Vector2(Screen.width, Screen.height));
            var screen = PanelPointToScreen(point, origin, end, new Vector2(Screen.width, Screen.height));
            Debug.Log($"Placement pointer: panel={point}; mappedScreen={screen}; panelOrigin={origin}; panelEnd={end}; framebuffer={Screen.width}x{Screen.height}");
            return Camera.main.ScreenPointToRay(screen);
        }
        public static Vector2 PanelPointToScreen(Vector2 point, Vector2 origin, Vector2 end, Vector2 framebuffer)
            => new Vector2((point.x-origin.x)/(end.x-origin.x)*framebuffer.x,
                framebuffer.y-(point.y-origin.y)/(end.y-origin.y)*framebuffer.y);
        void Evaluate(bool final)
        {
            if (!IsEditing || selected == null || authority == null) return;
            if (buildingEvaluation || evaluationID != null || Time.unscaledTime < nextEvaluation) return;
            nextEvaluation = Time.unscaledTime + .12f;
            evaluatedRevision = (ulong)authority["recordRevision"];
            evaluatedPoseVersion = poseVersion;
            lastPlacementPayload = PointerPlaceIntent();
            evaluationID = "unity-placement:" + Guid.NewGuid().ToString("D");
            if (deviceTemplate == null) {
                evaluatedSupportHeight = null;
                if (!backend.RequestPropOperation("world.prop.preview", worldID, evaluationID, evaluatedRevision,
                    (ulong)authority["state"]["layoutRevision"], PointerPlaceIntent())) evaluationID = null;
                return;
            }
            var pointer = PointerPlaceIntent();
            if (!backend.RequestDevicePreview(worldID, evaluationID, evaluatedRevision, (ulong)authority["state"]["layoutRevision"],
                (string)deviceTemplate["id"], pointer["position"], pointer["yaw"])) evaluationID = null;
            return;
        }
        void OnPlacement(JObject update)
        {
            if (evaluationID == null || (string)update["requestID"] != evaluationID || selected == null) return;
            evaluationID = null;
            if (poseVersion != evaluatedPoseVersion) return;
            if ((string)update["status"] == "failed") {
                PreviewChanged?.Invoke(new JObject { ["canPlace"] = false, ["columns"] = new JArray() });
                Status?.Invoke((string)update["message"] ?? "摆放校验服务未能确认，这次调整未保存。");
                releasePending = false;
                return;
            }
            var result = update["result"] as JObject;
            if (result != null && evaluatedSupportHeight.HasValue) result["previewSupportHeight"] = evaluatedSupportHeight.Value;
            if ((bool?)result?["canPlace"] == true) {
                if ((string)update["operation"] == "world.prop.preview" && result["receipt"]?["placement"] is JObject placement) {
                    selected.Instance.transform.SetPositionAndRotation(WorldCoordinates.Position(placement["position"]),
                        Quaternion.Euler(0, -(float)placement["yaw"] * Mathf.Rad2Deg, 0));
                } else if ((string)update["operation"] == "world.device.preview" && result["placement"] is JObject devicePlacement) {
                    selected.Instance.transform.SetPositionAndRotation(WorldCoordinates.Position(devicePlacement["position"]),
                        Quaternion.Euler(0, -(float)devicePlacement["yaw"] * Mathf.Rad2Deg, 0));
                }
            }
            PreviewChanged?.Invoke(result);
            if (!releasePending) return;
            releasePending = false;
            if ((string)update["status"] != "completed" || (bool?)result?["canPlace"] != true ||
                (ulong)authority["recordRevision"] != evaluatedRevision) {
                Debug.Log($"Placement release rejected: status={update["status"]}; canPlace={result?["canPlace"]}; reason={result?["reason"]?["code"]}; evaluatedRevision={evaluatedRevision}; currentRevision={authority["recordRevision"]}");
                Status?.Invoke("当前位置不能摆放，请移动到绿色区域后再确认。"); return;
            }
            // Only the latest released pose, validated against this revision, may write.
            Confirm();
        }
        void OnApplicationFocus(bool focused) { if (!focused) manipulator?.Abort(); }
        void Update()
        {
            // UI Toolkit may dispatch KeyDown after this MonoBehaviour's Update.
            // Resolve on the following frame so popup dismissal gets first refusal.
            if (pendingEscapeFrame >= 0 && Time.frameCount > pendingEscapeFrame) {
                if (PlayerScreen.PopupDismissedFrame < pendingEscapeFrame) manipulator?.Abort();
                pendingEscapeFrame = -1;
            }
            if (GetComponent<GPUIChat2Probe>()?.BlocksWorldInput != true && Keyboard.current?.escapeKey.wasPressedThisFrame == true)
                pendingEscapeFrame = Time.frameCount;
            if (awaitingReadback && Time.unscaledTime >= nextReadback) {
                if (readbackAttempts >= 3) {
                    awaitingReadback = false; readbackUnconfirmed = true;
                    Status?.Invoke("保存回执已收到，但最终状态尚未确认；可以查看空间，重新打开空间会再次读取。");
                } else RequestSaveReadback();
            }
            if (!releasePending || evaluationID != null) return;
            if (Time.unscaledTime >= releaseDeadline) { Status?.Invoke("空间校验未完成，请调整位置或再次确认。"); releasePending = false; evaluationID = null; return; }
            Evaluate(true);
        }

        void OnWorld(JObject update)
        {
            if ((string)update["worldID"] != worldID) return;
            if (update["result"]?["record"] is JObject record) {
                if ((ulong?)record["recordRevision"] < (ulong?)authority?["recordRevision"]) return;
                authority = (JObject)record.DeepClone();
                if (!saving && selected != null && ((record["state"]?["objectStates"]?[selected.ObjectID] == null && (deviceTemplate == null || deviceExistingPreview)) ||
                    record["state"]?["propTombstones"]?[selected.ObjectID] != null ||
                    WorldProjectionOptional.HeldID(record["state"]) == selected.ObjectID)) Cancel();
                if ((awaitingReadback || readbackUnconfirmed) && (ulong)record["recordRevision"] >= savedRevision) {
                    var persisted = record["state"]?["objectStates"]?[savedObjectID]?["transform"];
                    var expected = submitted["objectStates"]?[savedObjectID]?["transform"];
                    saving = false; awaitingReadback = false; readbackUnconfirmed = false;
                    var matches = MatchesTransform(persisted, expected) && (!inventoryPreview || (bool?)record["state"]?["objectStates"]?[savedObjectID]?["isEnabled"] == true);
                    Debug.Log($"World save readback: receiptRevision={savedRevision}; recordRevision={record["recordRevision"]}; geometryMatches={matches}; actual={persisted?.ToString(Newtonsoft.Json.Formatting.None)}; expected={expected?.ToString(Newtonsoft.Json.Formatting.None)}");
                    if (matches) {
                        PreviewEnded?.Invoke();
                        inventoryPreview = false;
                        selected = null; deviceRelocationPreview = false; message.text = "物件位置已保存，并已从空间服务重新读取确认。";
                        Status?.Invoke(message.text);
                    } else { Cancel(); message.text = "空间已有其他更新，当前画面已采用最新状态。"; Status?.Invoke(message.text); }
                }
                foreach (var item in items) {
                    if (item.Instance == null || selected == item ||
                        (awaitingReadback && item.ObjectID == savedObjectID)) continue;
                    var objectState = record["state"]?["objectStates"]?[item.ObjectID];
                    if (objectState?["transform"] == null) continue;
                    item.Instance.SetActive((bool?)objectState["isEnabled"] == true);
                    item.Instance.transform.SetPositionAndRotation(WorldCoordinates.Position(objectState["transform"]["position"]),
                        WorldCoordinates.Rotation(objectState["transform"]["rotation"]));
                }
                return;
            }
            if (awaitingReadback && (string)update["operation"] == "world.snapshot" && (string)update["status"] == "failed") {
                nextReadback = Time.unscaledTime + 1;
                message.text = "保存回执已收到，正在重试读取最终状态。"; Status?.Invoke(message.text); return;
            }
            if (!saving || (string)update["requestID"] != requestID) return;
            if ((string)update["status"] == "failed") {
                saving = false; awaitingReadback = false;
                message.text = (string)update["message"] ?? "这次没有保存，调整预览已保留，请重新确认。";
                backend.RequestWorldSnapshot(worldID); return;
            }
            if ((string)update["operation"] == "world.prop.command" && update["result"]?["snapshot"]?["record"] is JObject committed) {
                submitted = (JObject)committed["state"].DeepClone();
                savedRevision = (ulong)committed["recordRevision"];
                savedObjectID = selected.ObjectID;
                // The write has a receipt. Never turn subsequent read failures
                // into a fictitious cancelled write or keep camera input locked.
                saving = false; selected = null; PreviewEnded?.Invoke();
                awaitingReadback = true;
                readbackAttempts = 0; RequestSaveReadback();
            }
        }
        void RequestSaveReadback()
        {
            readbackAttempts++;
            nextReadback = Time.unscaledTime + 6;
            if (!backend.RequestWorldSnapshot(worldID)) nextReadback = Time.unscaledTime + 1;
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
