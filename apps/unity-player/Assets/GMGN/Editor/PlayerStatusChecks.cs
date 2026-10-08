using System;
using System.Reflection;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class PlayerStatusChecks
    {
        public static void Verify()
        {
            var go = new GameObject("Error-only status check"); go.SetActive(false);
            try {
                var player = go.AddComponent<PlayerScreen>();
                var flags = BindingFlags.Instance | BindingFlags.NonPublic;
                string Error() => (string)typeof(PlayerScreen).GetField("nativeError", flags).GetValue(player);
                void Invoke(string method, params object[] args) => typeof(PlayerScreen).GetMethod(method, flags).Invoke(player, args);
                void Require(bool value, string message) { if (!value) throw new Exception(message); }
                Invoke("OnError", new object[] { null });
                foreach (var text in new[] { "这里还没有可播的曲子，请先选一首。", "动作已载入。", "Connected", "接続済み" }) {
                    Invoke("OnStatus", text);
                    Require(string.IsNullOrEmpty(Error()), "Normal status must stay hidden");
                }
                Invoke("OnError", "连接失败，请重新打开应用。");
                Require(Error() == "连接失败，请重新打开应用。", "Explicit errors must be visible");
                Invoke("OnStatus", "Music ready");
                Require(Error() == "连接失败，请重新打开应用。", "Ordinary progress must not replace active error");
                Invoke("OnWorldErrorCleared", "手持标定与当前角色或挂点不一致。");
                Require(Error() == "连接失败，请重新打开应用。", "Attachment recovery must preserve a newer unrelated error");
                Invoke("OnError", "手持标定与当前角色或挂点不一致。");
                Invoke("OnWorldErrorCleared", "手持标定与当前角色或挂点不一致。");
                Require(Error() == "" && string.IsNullOrEmpty(Error()), "Attachment recovery must clear its own stale error");
                var world = go.AddComponent<WorldRuntimeBridge>();
                var heldError = typeof(WorldRuntimeBridge).GetField("heldProjectionCode", flags);
                var clearHeldError = typeof(WorldRuntimeBridge).GetMethod("ClearHeldProjectionError", flags);
                var recoveryCount = 0;
                world.ErrorCleared += previous => { recoveryCount++; Invoke("OnWorldErrorCleared", previous); };
                Invoke("OnError", "当前角色缺少所选物件挂点。");
                heldError.SetValue(world, "当前角色缺少所选物件挂点。");
                clearHeldError.Invoke(world, null);
                Require(recoveryCount == 1 && heldError.GetValue(world) == null && string.IsNullOrEmpty(Error()),
                    "Successful attachment or release must publish and clear its recorded error");
                clearHeldError.Invoke(world, null);
                Require(recoveryCount == 1, "Attachment recovery must not emit repeated clears");
                Invoke("OnError", new object[] { null });
                Require(Error() == "" && string.IsNullOrEmpty(Error()), "Recovery must clear errors");
                Invoke("OnVoiceState", "recording", null);
                Require(string.IsNullOrEmpty(Error()), "Voice recording must not become top-left text");
                Debug.Log("PlayerStatusChecks PASS: ordinary status hidden, explicit error visible, recovery cleared, voice hidden");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
            finally { UnityEngine.Object.DestroyImmediate(go); }
        }
    }
}
