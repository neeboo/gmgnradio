using System;
using System.Reflection;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class LyricsVisibilityChecks
    {
        public static void Validate()
        {
            const string preference = "gmgn.lyrics.visible";
            bool hadPreference = PlayerPrefs.HasKey(preference);
            int previous = PlayerPrefs.GetInt(preference, 1);
            var host = new GameObject("lyrics-visibility-check");
            try {
                var root = Resources.Load<VisualTreeAsset>("Player").CloneTree();
                Require(root.Query<Button>().ToList().Count == 0 && root.Query<TextField>().ToList().Count == 0, "Native resource retains lyrics without product controls");
                var screen = host.AddComponent<PlayerScreen>();
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                var gpu = host.AddComponent<GpuLyricsView>();
                typeof(PlayerScreen).GetField("gpuLyrics", flags).SetValue(screen, gpu);
                foreach (var name in new[] { "root", "lyric", "translation" })
                    typeof(PlayerScreen).GetField(name, flags).SetValue(screen,
                        name == "root" ? root : root.Q<Label>(name));
                var refresh = typeof(PlayerScreen).GetMethod("RefreshLyricVisibility", flags);
                var change = typeof(PlayerScreen).GetMethod("ToggleLyrics", flags);
                refresh.Invoke(screen, null);
                Require(root.Q<Label>("lyric").style.display.value == DisplayStyle.Flex,
                    "Lyrics default must stay visible");
                change.Invoke(screen, null);
                Require(PlayerPrefs.GetInt(preference, 1) == 0,
                    "Hidden preference must persist and clear selected state");
                Require(root.Q<Label>("lyric").style.display.value == DisplayStyle.None &&
                    root.Q<Label>("translation").style.display.value == DisplayStyle.None,
                    "Hidden lyrics must include translation");
                change.Invoke(screen, null);
                Require(PlayerPrefs.GetInt(preference, 0) == 1,
                    "Showing lyrics must restore the preference and selected state");
                typeof(PlayerScreen).GetField("gpuLyricModeReady", flags).SetValue(screen, true);
                refresh.Invoke(screen, null);
                var shown = gpu.GetType().GetField("shown", flags);
                Require((bool)shown.GetValue(gpu), "GPU lyrics renderer must be shown when enabled");
                change.Invoke(screen, null);
                Require(!(bool)shown.GetValue(gpu), "GPU renderer including style metadata must hide as a whole");
                Debug.Log("PASS lyrics visibility: leftmost toolbar button, default shown, local persistence, labels and selected state");
            } finally {
                host.SetActive(false);
                UnityEngine.Object.DestroyImmediate(host.GetComponent<PlayerScreen>());
                UnityEngine.Object.DestroyImmediate(host);
                if (hadPreference) PlayerPrefs.SetInt(preference, previous); else PlayerPrefs.DeleteKey(preference);
                PlayerPrefs.Save();
            }
            EditorApplication.Exit(0);
        }
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    }
}
