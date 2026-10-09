using System;
using System.Collections;
using System.Runtime.InteropServices;
using System.Text;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer
{
    // Product controls share the existing Player's sole backend and world.
    [DefaultExecutionOrder(-100)]
    public sealed class GPUIChat2Probe : MonoBehaviour
    {
        const string Library = "gmgn_gpui_overlay_probe";
        [DllImport(Library)] static extern int gmgn_overlay_register_current_unity_window();
        [DllImport(Library)] static extern IntPtr gmgn_overlay_unity_content_view();
        [DllImport(Library)] static extern int gmgn_gpui_probe_mount(IntPtr parent);
        [DllImport(Library)] static extern void gmgn_gpui_probe_unmount();
        [DllImport(Library)] static extern int gmgn_overlay_owns_input();
        [DllImport(Library)] static extern int gmgn_overlay_set_panel_expanded(int expanded);
        [DllImport(Library)] static extern ulong gmgn_overlay_geometry_revision();
        [DllImport(Library)] static extern int gmgn_overlay_normalize_chat_rect(float x, float y, float width, float height,
            out float nx, out float ny, out float nw, out float nh);
        [DllImport("UnityMediaHost")] static extern void gmgn_unity_chat_image_drop_region(float x, float y, float width, float height);
        [DllImport(Library)] static extern int gmgn_gpui_chat_snapshot(byte[] bytes, UIntPtr length);
        [DllImport(Library)] static extern IntPtr gmgn_gpui_chat_take_command(byte[] bytes, UIntPtr capacity);
        [DllImport(Library)] static extern int gmgn_gpui_ui_command(byte[] bytes, UIntPtr length);
        [DllImport(Library)] static extern int gmgn_gpui_take_escape_consumed();
        WorldRuntimeBridge world;
        NativePlayerBackend backend;
        readonly byte[] commandBuffer = new byte[256 * 1024];
        JObject latestProjection;
        JArray inventory = new JArray();
        JObject lastUICommandResult;
        JObject localSettingsResult;
        Rect composerDropRect;
        ulong dropGeometry;
        public Func<JObject, bool> LocalUICommand;
        public Func<JObject> LocalUIProjection;
        bool mounted;
        bool projectionReady;
        bool projectionFailureReported;
        public event Action ProjectionReady;
        public event Action<string> Failure;
        void ReportFailure(string code) { Debug.LogError(code); Failure?.Invoke(code); }
        public bool IsMounted => mounted;
        public bool IsProjectionReady => mounted && projectionReady;
        public bool OpenChat()
            => OpenPanel("聊天");
        public bool OpenPanel(string name)
        {
            if (!IsProjectionReady) return false;
            string op = name switch { "聊天" => "ui.chat.open", "设置" => "ui.settings.open", "愿望" => "ui.wish.open", "音乐" => "ui.music.open", _ => null };
            if (op == null) return false;
            var bytes = Encoding.UTF8.GetBytes("{\"op\":\"" + op + "\"}");
            return gmgn_gpui_ui_command(bytes, (UIntPtr)bytes.Length) == 0;
        }
        public bool BlocksWorldInput => mounted && gmgn_overlay_owns_input() == 1;
        public void Bind(WorldRuntimeBridge existingWorld) {
            if (world != null) world.InventoryUpdated -= ApplyInventory;
            world = existingWorld;
            if (world != null) world.InventoryUpdated += ApplyInventory;
        }
        void ApplyInventory(JArray value) { inventory = (JArray)value.DeepClone(); }
        public void BindBackend(NativePlayerBackend existingBackend)
        {
            if (backend != null) backend.GPUIHostProjection -= ApplySnapshot;
            backend = existingBackend;
            if (backend != null) backend.GPUIHostProjection += ApplySnapshot;
        }
        // One parse and one serialization per poll. `projection` is the tree the backend parsed
        // this tick; the adjuncts below are added to it in place and it is written straight to UTF-8
        // bytes for the native boundary, so no UTF-16 string of the whole envelope is materialized
        // and no second parse of our own output happens.
        void ApplySnapshot(JObject projection)
        {
            latestProjection = projection;
            if (!mounted) return;
            GPUIProjectionPayload.Augment(projection, inventory.DeepClone(), world?.AuthorityProjection?.DeepClone(),
                LocalUIProjection?.Invoke(), lastUICommandResult?.DeepClone(), localSettingsResult?.DeepClone());
            var bytes = GPUIProjectionPayload.Encode(projection);
            if (bytes.Length > GPUIProjectionPayload.Capacity || gmgn_gpui_chat_snapshot(bytes, (UIntPtr)bytes.Length) != 0) {
                if (!projectionFailureReported) ReportFailure("GPUI: host snapshot projection rejected.");
                projectionFailureReported = true;
            } else {
                projectionFailureReported = false;
                if (!projectionReady) { projectionReady = true; ProjectionReady?.Invoke(); }
            }
        }
        void Update()
        {
            if (!mounted || backend == null) return;
            if (gmgn_gpui_take_escape_consumed() == 1) PlayerScreen.ReportGPUIEscapeConsumed();
            if (dropGeometry != gmgn_overlay_geometry_revision()) PublishDropRegion();
            for (int i = 0; i < 4; i++) {
                long count = gmgn_gpui_chat_take_command(commandBuffer, (UIntPtr)commandBuffer.Length).ToInt64();
                if (count == 0) break;
                if (count < 0 || count > commandBuffer.Length) {
                    Debug.LogError("GPUI: command exceeds bounded transport capacity."); break;
                }
                try {
                    var command = JObject.Parse(Encoding.UTF8.GetString(commandBuffer, 0, (int)count));
                    if ((string)command["op"] == "ui.settings.command" && (string)command["command"]?["op"] == "stage.camera.reset") {
                        bool reset = false;
                        try { reset = world != null && world.ResetPresentationCamera() != null; }
                        catch (InvalidOperationException) { }
                        localSettingsResult = new JObject { ["requestID"] = command["requestID"],
                            ["status"] = reset ? "accepted" : "failed", ["code"] = reset ? null : "camera_reset_unavailable" };
                        if (latestProjection != null) ApplySnapshot(latestProjection);
                    }
                    else if ((string)command["op"] == "ui.chat.dropRegion") {
                        composerDropRect = new Rect((float?)command["x"] ?? 0, (float?)command["y"] ?? 0,
                            (float?)command["width"] ?? 0, (float?)command["height"] ?? 0);
                        PublishDropRegion();
                    }
                    else if ((string)command["op"] == "ui.overlay.panel") {
                        bool resized = command["expanded"]?.Type == JTokenType.Boolean &&
                            gmgn_overlay_set_panel_expanded((bool)command["expanded"] ? 1 : 0) == 1;
                        lastUICommandResult = new JObject { ["op"] = command["op"], ["requestID"] = command["requestID"],
                            ["status"] = resized ? "started" : "rejected" };
                    }
                    else if (LocalUICommand?.Invoke(command) == true) { }
                    else if ((string)command["op"] == "ui.inventory.place" || (string)command["op"] == "ui.device.place") {
                        bool started = false;
                        if ((string)command["op"] == "ui.inventory.place")
                            started = command["objectID"]?.Type == JTokenType.String && world != null && world.BeginInventoryPlacement((string)command["objectID"]);
                        else if (command["templateID"]?.Type == JTokenType.String && latestProjection != null) {
                            var templates = latestProjection["builtinDevices"]?["templates"] as JArray;
                            if (templates != null) foreach (var item in templates) {
                                if (item is JObject template && (string)template["id"] == (string)command["templateID"]) {
                                    started = world != null && world.BeginDevicePlacement(template); break;
                                }
                            }
                        }
                        lastUICommandResult = new JObject { ["op"] = command["op"], ["requestID"] = command["requestID"],
                            ["status"] = started ? "started" : "rejected", ["code"] = started ? null : "placement_not_ready" };
                        if (latestProjection != null) ApplySnapshot(latestProjection);
                    } else {
                        if ((string)command["op"] == "ui.settings.command") localSettingsResult = null;
                        if (!backend.SendGPUICommand(command)) {
                            if ((string)command["op"] == "ui.settings.command") {
                                localSettingsResult = new JObject { ["requestID"] = command["requestID"],
                                    ["status"] = "failed", ["code"] = "settings_command_not_accepted" };
                                if (latestProjection != null) ApplySnapshot(latestProjection);
                            }
                            Debug.LogWarning("GPUI: host command not accepted.");
                        }
                    }
                } catch (Newtonsoft.Json.JsonException) { Debug.LogError("GPUI: malformed command rejected."); }
            }
        }
        void PublishDropRegion()
        {
            dropGeometry = gmgn_overlay_geometry_revision();
            gmgn_overlay_normalize_chat_rect(composerDropRect.x, composerDropRect.y, composerDropRect.width, composerDropRect.height,
                out var x, out var y, out var width, out var height);
            gmgn_unity_chat_image_drop_region(x, y, width, height);
        }
        IEnumerator Start()
        {
            float deadline = Time.realtimeSinceStartup + 60;
            while (latestProjection == null && Time.realtimeSinceStartup < deadline)
                yield return null;
            if (backend == null || latestProjection == null) {
                ReportFailure("GPUI: existing host snapshot unavailable; controls not mounted."); yield break;
            }
            // The existing world remains the sole owner. Mount only after its real startup projection.
            TryMount();
        }
        void TryMount()
        {
            try {
                if (gmgn_overlay_register_current_unity_window() != 1) {
                    ReportFailure("GPUI: Unity window unavailable or ambiguous."); return;
                }
                var parent = gmgn_overlay_unity_content_view();
                mounted = parent != IntPtr.Zero && gmgn_gpui_probe_mount(parent) == 0;
                if (mounted) {
                    backend?.BeginGPUIEpoch();
                    gmgn_overlay_set_panel_expanded(0);
                    composerDropRect = Rect.zero; PublishDropRegion();
                    Debug.Log("聊天2: actual GPUI mounted in existing Unity window; existing host transport.");
                    if (latestProjection != null) {
                        if (latestProjection["chat"] is JObject chat) chat["events"] = new JArray();
                        ApplySnapshot(latestProjection);
                    }
                }
                else ReportFailure("GPUI: actual GPUI mount failed.");
            } catch (DllNotFoundException) { ReportFailure("GPUI: UI library missing."); }
              catch (EntryPointNotFoundException) { ReportFailure("GPUI: UI ABI missing."); }
        }
        public void Shutdown() {
            if (world != null) world.InventoryUpdated -= ApplyInventory;
            if (backend != null) backend.GPUIHostProjection -= ApplySnapshot;
            if (mounted) { gmgn_unity_chat_image_drop_region(0, 0, 0, 0); gmgn_gpui_probe_unmount(); mounted = false; }
            projectionReady = false; backend = null; world = null;
        }
        void OnDestroy() => Shutdown();
    }
}
