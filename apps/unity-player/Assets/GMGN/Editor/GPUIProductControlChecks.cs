using System;
using System.Reflection;
using System.Runtime.InteropServices;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    // Read-only resource/type contract. Does not mount GPUI or construct a backend.
    public static class GPUIProductControlChecks
    {
        public static void Verify()
        {
            try {
                void Require(bool value, string message) { if (!value) throw new Exception(message); }
                var root = Resources.Load<VisualTreeAsset>("Player").CloneTree();
                Require(root.Q<Label>("lyric") != null && root.Q<Label>("translation") != null, "Native lyrics and translation must remain");
                Require(root.Q(className: "body") != null, "Actual native media renderer container must remain");
                Require(root.Query<Button>().ToList().Count == 0 && root.Query<TextField>().ToList().Count == 0 && root.Query<ScrollView>().ToList().Count == 0,
                    "Player resource must not retain old product controls or popup trees");
                const BindingFlags fields = BindingFlags.Instance | BindingFlags.NonPublic;
                foreach (var name in new[] { "draft", "chatPanel", "messages", "volume", "settingsPanel", "composition" })
                    Require(typeof(PlayerScreen).GetField(name, fields) == null, "Old product UI state retained: " + name);
                Require(typeof(PlayerScreen).GetField("backend", fields).FieldType == typeof(IPlayerBackend), "Player retains its sole original backend");
                Require(typeof(GPUIChat2Probe).GetMethod("Shutdown") != null && typeof(GPUIChat2Probe).GetMethod("Toggle") == null,
                    "GPUI lifetime must retain a persistent pane with explicit shutdown");
                var early = typeof(GPUIChat2Probe).GetCustomAttribute<DefaultExecutionOrder>();
                Require(early != null && early.order < 0, "Consumed Escape must be taken before world interaction Update");
                foreach (var name in new[] { "gmgn_gpui_chat_snapshot", "gmgn_gpui_chat_take_command", "gmgn_gpui_ui_command", "gmgn_gpui_take_escape_consumed" }) {
                    var method = typeof(GPUIChat2Probe).GetMethod(name, BindingFlags.Static | BindingFlags.NonPublic);
                    Require(method?.GetCustomAttribute<DllImportAttribute>()?.Value == "gmgn_gpui_overlay_probe", "Actual GPUI ABI missing: " + name);
                }
                Debug.Log("GPUIProductControlChecks PASS sole host, actual GPUI ABI, persistent lifetime, consumed Escape, lyrics-only native resource; no host/audio launched");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
        }
    }
}
