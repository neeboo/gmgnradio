using System;
using System.Collections.Generic;
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
        VisualElement panel;
        VisualElement controls, actions;
        Label message;
        Button confirm, cancel;
        RecoveryItem selected;
        Vector3 initialPosition;
        Quaternion initialRotation;
        JObject authority, submitted;
        ulong savedRevision;
        bool active, saving, awaitingReadback;
        VisualElement inputRoot;
        public event Action<string> Status;

        public void Configure(NativePlayerBackend native, string identity, IReadOnlyList<RecoveryItem> recovered, VisualElement root)
        {
            backend = native; worldID = identity; items = recovered;
            backend.WorldUpdated += OnWorld;
            panel = new VisualElement { name = "worldInteraction" };
            panel.AddToClassList("world-interaction-panel");
            panel.style.position = Position.Absolute; panel.style.left = 24; panel.style.top = 100;
            panel.style.width = 260; panel.style.paddingLeft = 12; panel.style.paddingRight = 12;
            panel.style.paddingTop = 12; panel.style.paddingBottom = 12;
            panel.style.backgroundColor = new Color(.06f, .07f, .085f, .96f);
            panel.style.color = new Color(.93f, .94f, .96f);
            panel.style.fontSize = 14;
            panel.style.borderTopLeftRadius = panel.style.borderTopRightRadius = 12;
            panel.style.borderBottomLeftRadius = panel.style.borderBottomRightRadius = 12;
            panel.style.display = DisplayStyle.None;
            var title = new Label("物件调整"); title.style.fontSize = 14; title.style.marginBottom = 8;
            panel.Add(title);
            message = new Label("点击空间里的真实物件，预览移动与旋转。");
            message.style.whiteSpace = WhiteSpace.Normal; message.style.fontSize = 12;
            message.style.color = new Color(.72f, .76f, .80f); panel.Add(message);
            controls = new VisualElement(); controls.style.flexDirection = FlexDirection.Row; controls.style.flexWrap = Wrap.Wrap;
            void Add(string text, Action action) { var button = new Button(action) { text = text };
                button.style.height = 30; button.style.fontSize = 12; button.style.paddingTop = 4; button.style.paddingBottom = 4;
                button.style.marginTop = 8; button.style.marginRight = 4; controls.Add(button); }
            Add("←", () => Move(-.25f, 0, 0)); Add("→", () => Move(.25f, 0, 0));
            Add("前", () => Move(0, 0, .25f)); Add("后", () => Move(0, 0, -.25f));
            Add("升", () => Move(0, .25f, 0)); Add("降", () => Move(0, -.25f, 0));
            Add("旋转 45°", () => { if (selected == null || saving) return; selected.Instance.transform.rotation *= Quaternion.Euler(0, 45, 0); ShowPreview(); });
            panel.Add(controls);
            confirm = new Button(Confirm) { text = "确认保存" }; cancel = new Button(Cancel) { text = "取消预览" };
            actions = new VisualElement(); actions.style.flexDirection = FlexDirection.Row; actions.style.marginTop = 12;
            confirm.style.height = cancel.style.height = 30; confirm.style.fontSize = cancel.style.fontSize = 12;
            confirm.style.paddingTop = cancel.style.paddingTop = 4; confirm.style.paddingBottom = cancel.style.paddingBottom = 4;
            confirm.style.backgroundColor = new Color(.03f, .23f, .32f); cancel.style.marginLeft = 8;
            actions.Add(confirm); actions.Add(cancel); panel.Add(actions);
            var refresh = new Button(() => backend.RequestWorldSnapshot(worldID)) { text = "刷新空间数据" };
            refresh.style.fontSize = 12; refresh.style.height = 28; refresh.style.marginTop = 8;
            refresh.style.alignSelf = Align.FlexStart; refresh.style.paddingTop = 4; refresh.style.paddingBottom = 4;
            panel.Add(refresh);
            root.Add(panel);
            // Empty space must receive UI Toolkit pointer events too. Reading
            // Mouse.wasPressedThisFrame alone can miss short native clicks.
            inputRoot = root;
            inputRoot.pickingMode = PickingMode.Position;
            inputRoot.RegisterCallback<PointerDownEvent>(OnPointerDown, TrickleDown.TrickleDown);
            if (backend.WorldProjection != null) OnWorld(backend.WorldProjection);
            backend.RequestWorldSnapshot(worldID);
            ShowPreview();
        }

        public void SetActive(bool value)
        {
            active = value;
            if (!value && !saving) Cancel();
            panel.style.display = value ? DisplayStyle.Flex : DisplayStyle.None;
        }

        void OnPointerDown(PointerDownEvent e)
        {
            if (!active || saving || e.button != 0) return;
            var root = inputRoot;
            if (root?.panel == null || Camera.main == null) return;
            for (var hit = e.target as VisualElement; hit != null; hit = hit.parent)
                if (hit is Button || hit is TextField || hit is Slider || hit is ScrollView ||
                    hit.name == "chatPanel" || hit.name == "worldInteraction" || hit.ClassListContains("queue-panel")) {
                    Debug.Log($"World selection blocked by UI: {hit.name}"); return;
                }
            var scale = GetComponent<UIDocument>().panelSettings.scale;
            var screen = new Vector2(e.position.x * scale, Screen.height - e.position.y * scale);
            Debug.Log($"World selection pointer: panel={e.position}; scale={scale}; framebuffer={screen}; focused={Application.isFocused}");
            var ray = Camera.main.ScreenPointToRay(screen);
            RecoveryItem nearest = null; var distance = float.PositiveInfinity;
            foreach (var item in items) {
                if (item.Instance == null || item.Status != "restored") continue;
                foreach (var renderer in item.Instance.GetComponentsInChildren<Renderer>())
                    if (renderer.bounds.IntersectRay(ray, out var depth) && depth < distance) { nearest = item; distance = depth; }
            }
            if (nearest == null) {
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
            ShowPreview();
        }

        void Move(float x, float y, float z)
        {
            if (selected == null || saving) return;
            var p = selected.Instance.transform.position + new Vector3(x, y, z);
            selected.Instance.transform.position = new Vector3(x == 0 ? p.x : Mathf.Round(p.x / .25f) * .25f,
                y == 0 ? p.y : initialPosition.y + Mathf.Round((p.y - initialPosition.y) / .25f) * .25f,
                z == 0 ? p.z : Mathf.Round(p.z / .25f) * .25f);
            ShowPreview();
        }
        void ShowPreview()
        {
            message.text = selected == null ? "点击空间里的真实物件。" : "物件调整预览（尚未保存）；0.25 米网格吸附，碰撞校验尚未迁移。";
            UpdateSelectionControls();
        }
        void UpdateSelectionControls()
        {
            controls.style.display = actions.style.display = selected == null ? DisplayStyle.None : DisplayStyle.Flex;
            controls.SetEnabled(selected != null && !saving);
            confirm.SetEnabled(selected != null && authority != null && !saving);
            cancel.SetEnabled(selected != null && !saving);
        }
        void Cancel()
        {
            if (saving) return;
            if (selected?.Instance != null) selected.Instance.transform.SetPositionAndRotation(initialPosition, initialRotation);
            selected = null; ShowPreview();
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
            confirm.SetEnabled(false); cancel.SetEnabled(false); message.text = "正在保存，等待空间服务确认…";
            controls.SetEnabled(false);
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
                        selected = null; message.text = "物件位置已保存，并已从空间服务重新读取确认。";
                        Status?.Invoke(message.text);
                    } else { Cancel(); message.text = "空间已有其他更新，预览已撤销，请重新操作。"; }
                    confirm.SetEnabled(false); cancel.SetEnabled(false);
                    UpdateSelectionControls();
                }
                foreach (var item in items) {
                    if (item.Instance == null || selected == item) continue;
                    var objectState = record["state"]?["objectStates"]?[item.ObjectID];
                    if (objectState?["transform"] == null) continue;
                    item.Instance.SetActive((bool?)objectState["isEnabled"] == true);
                    item.Instance.transform.SetPositionAndRotation(WorldCoordinates.Position(objectState["transform"]["position"]),
                        WorldCoordinates.Rotation(objectState["transform"]["rotation"]));
                }
                if (selected != null && !saving) ShowPreview();
                return;
            }
            if (awaitingReadback && (string)update["operation"] == "world.snapshot" && (string)update["status"] == "failed") {
                message.text = "已收到保存回执，但读回确认失败。请点击刷新空间数据。"; return;
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
            inputRoot?.UnregisterCallback<PointerDownEvent>(OnPointerDown, TrickleDown.TrickleDown);
        }
    }
}
