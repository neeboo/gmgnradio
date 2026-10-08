using System;
using System.Reflection;
using UnityEditor;
using UnityEngine;
namespace GMGN.UnityPlayer.Editor
{
    public static class ChatVoiceInputChecks
    {
        public static void Verify()
        {
            try {
                string Operation(string state) => (string)typeof(PlayerScreen).GetMethod("ChatVoiceOperation", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { state });
                void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
                Require(Operation("idle") == "voice.press" && Operation("error") == "voice.press", "Idle/retry must start existing ASR capture");
                Require(Operation("listening") == "voice.release", "Recording stop must commit existing ASR capture");
                Require(Operation("connecting") == "voice.cancel" && Operation("transcribing") == "voice.cancel", "Busy stop must cancel pending ASR");
                Require(typeof(PlayerScreen).GetMethod("OnVoiceTranscript", BindingFlags.Instance | BindingFlags.NonPublic) == null, "Recognized text must have no retired Unity draft consumer");
                Debug.Log("ChatVoiceInputChecks PASS actual voice operation policy and no legacy draft consumer; no capture started");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
        }
    }
}
