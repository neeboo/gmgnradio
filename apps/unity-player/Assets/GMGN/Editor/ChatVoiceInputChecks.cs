using System;
using System.Collections;
using System.Reflection;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;
using UnityEngine.Localization.Tables;

namespace GMGN.UnityPlayer.Editor
{
    public static class ChatVoiceInputChecks
    {
        public static void Verify()
        {
            var go = new GameObject("Chat voice checks"); go.SetActive(false);
            var localeField = typeof(UiLocalization).GetField("table", BindingFlags.Static | BindingFlags.NonPublic);
            var previousTable = localeField.GetValue(null);
            var table = ScriptableObject.CreateInstance<StringTable>();
            table.SharedData = ScriptableObject.CreateInstance<SharedTableData>();
            foreach (var state in new[] { "connecting", "listening", "transcribing", "idle" }) table.AddEntry("pttState_" + state, state);
            table.AddEntry("pttError_microphone_permission", "Permission required"); localeField.SetValue(null, table);
            try {
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                var player = go.AddComponent<PlayerScreen>(); var root = new VisualElement();
                Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
                void Set(string field, object value) => typeof(PlayerScreen).GetField(field, flags).SetValue(player, value);
                void Call(string method, params object[] args) => typeof(PlayerScreen).GetMethod(method, flags).Invoke(player, args);
                void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
                Set("root", root); Set("chatPanel", root.Q("chatPanel")); Set("draft", root.Q<TextField>("draft"));
                Set("send", root.Q<Button>("send")); Set("cancel", root.Q<Button>("cancel")); Set("status", root.Q<Label>("status")); Set("follow", false);
                var icon = new PlayerScreen.ToolbarIcon("microphone"); root.Q<Button>("chatVoice").Add(icon);
                string IconKind() => (string)typeof(PlayerScreen.ToolbarIcon).GetField("kind", flags).GetValue(icon);
                string Operation(string state) => (string)typeof(PlayerScreen).GetMethod("ChatVoiceOperation", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { state });
                Require(Operation("idle") == "voice.press" && Operation("error") == "voice.press", "Idle/retry must start existing ASR capture");
                Require(Operation("listening") == "voice.release", "Recording stop must commit existing ASR capture");
                Require(Operation("connecting") == "voice.cancel" && Operation("transcribing") == "voice.cancel", "Busy stop must cancel pending ASR");
                foreach (var state in new[] { "connecting", "listening", "transcribing" }) {
                    Call("OnVoiceState", state, null);
                    Require(IconKind() == "stop", "Active capture/transcription must expose stop icon");
                    Require(!string.IsNullOrWhiteSpace(root.Q<Label>("chatVoiceStatus").text), "Recording state must be visible inside chat");
                }
                Call("OnVoiceState", "error", "microphone_permission");
                Require(root.Q<Label>("chatVoiceStatus").ClassListContains("status-error"), "ASR failure must appear inside chat");
                Call("OnVoiceState", "idle", null); Require(IconKind() == "microphone", "Idle must restore recording icon");
                Call("OnVoiceTranscript", "你好世界");
                Require(root.Q<TextField>("draft").value == "你好世界", "Recognition must populate draft");
                Require(!root.Q("chatPanel").ClassListContains("hidden"), "Recognition must expose editable chat");
                Call("OnVoiceTranscript", "第二句");
                Require(root.Q<TextField>("draft").value == "你好世界\n第二句", "Recognition must preserve existing draft");
                var messages = (ICollection)typeof(PlayerScreen).GetField("messages", flags).GetValue(player);
                Require(messages.Count == 0 && typeof(PlayerScreen).GetField("pending", flags).GetValue(player) == null, "Recognition must never auto-submit a chat message");
                Debug.Log("ChatVoiceInputChecks PASS: recording/transcribing/error/idle, draft append, chat opens, no automatic submission");
                UnityEngine.Object.DestroyImmediate(go); localeField.SetValue(null, previousTable); EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); UnityEngine.Object.DestroyImmediate(go); localeField.SetValue(null, previousTable); EditorApplication.Exit(1); }
        }
    }
}
