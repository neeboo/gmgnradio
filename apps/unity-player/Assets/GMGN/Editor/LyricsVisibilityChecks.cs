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
                var toggle = root.Q<Button>("toggleLyrics");
                var toolbar = toggle.parent;
                Require(toolbar.IndexOf(toggle) == 0 && toolbar.IndexOf(root.Q<Button>("chooseMusic")) == 1,
                    "Lyrics toggle must precede the music button at toolbar left edge");
                var screen = host.AddComponent<PlayerScreen>();
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                var gpu = host.AddComponent<GpuLyricsView>();
                typeof(PlayerScreen).GetField("gpuLyrics", flags).SetValue(screen, gpu);
                foreach (var name in new[] { "root", "lyric", "translation" })
                    typeof(PlayerScreen).GetField(name, flags).SetValue(screen,
                        name == "root" ? root : root.Q<Label>(name));
                var refresh = typeof(PlayerScreen).GetMethod("RefreshLyricVisibility", flags);
                var change = typeof(PlayerScreen).GetMethod("ToggleLyrics", flags);
                typeof(PlayerScreen).GetMethod("AddIcon", flags).Invoke(screen, new object[] { "toggleLyrics", "lyrics" });
                refresh.Invoke(screen, null);
                Require(string.IsNullOrEmpty(toggle.text) && toggle.childCount > 0 && toggle.ClassListContains("icon-button"),
                    "Lyrics toggle must retain its vector icon without a text label");
                Require(toggle.ClassListContains("selected") && root.Q<Label>("lyric").style.display.value == DisplayStyle.Flex,
                    "Lyrics default must stay visible");
                change.Invoke(screen, null);
                Require(!toggle.ClassListContains("selected") && PlayerPrefs.GetInt(preference, 1) == 0,
                    "Hidden preference must persist and clear selected state");
                Require(string.IsNullOrEmpty(toggle.text) && toggle.tooltip == "显示歌词",
                    "Hidden icon must expose the show-lyrics tooltip without restoring a label");
                Require(root.Q<Label>("lyric").style.display.value == DisplayStyle.None &&
                    root.Q<Label>("translation").style.display.value == DisplayStyle.None,
                    "Hidden lyrics must include translation");
                change.Invoke(screen, null);
                Require(toggle.ClassListContains("selected") && PlayerPrefs.GetInt(preference, 0) == 1,
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
            VerifyToolbarGeometry();
        }
        static void VerifyToolbarGeometry()
        {
            var host = new GameObject("lyrics-toolbar-player-panel");
            var document = host.AddComponent<UIDocument>();
            var settings = UnityEngine.Object.Instantiate(Resources.Load<PanelSettings>("PlayerPanel"));
            settings.scale = 2;
            document.panelSettings = settings;
            var frame = new VisualElement(); document.rootVisualElement.Add(frame);
            frame.style.width = 720; frame.style.height = 450; frame.style.flexShrink = 0;
            frame.AddToClassList("compact");
            Resources.Load<VisualTreeAsset>("Player").CloneTree(frame);
            frame.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            frame.Q<Button>("settings").text = "设置";
            var deadline = EditorApplication.timeSinceStartup + 1;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                EditorApplication.update -= check;
                try {
                    var toolbar = frame.Q<Button>("toggleLyrics").parent;
                    var lyrics = frame.Q<Button>("toggleLyrics");
                    Require(document.rootVisualElement.panel.contextType == ContextType.Player, "Requires real runtime PlayerPanel");
                    Require(string.IsNullOrEmpty(lyrics.text) && lyrics.ClassListContains("icon-button"),
                        "Lyrics button must use the compact icon style without a label");
                    foreach (var name in new[] { "toggleLyrics", "chooseMusic", "volume", "settings", "fullscreen", "compactWindow" }) {
                        var button = frame.Q(name);
                        Require(button.worldBound.width > 0 && button.worldBound.xMin >= toolbar.worldBound.xMin - 1 &&
                            button.worldBound.xMax <= toolbar.worldBound.xMax + 1,
                            $"Toolbar control {name} escaped 720x450: {button.worldBound}, toolbar={toolbar.worldBound}");
                    }
                    Debug.Log("PASS lyrics toolbar: real PlayerPanel scale2 720x450, single-line label unclipped, music/volume/settings/fullscreen retained");
                    UnityEngine.Object.DestroyImmediate(host); UnityEngine.Object.DestroyImmediate(settings);
                    EditorApplication.Exit(0);
                } catch (Exception error) {
                    Debug.LogException(error);
                    UnityEngine.Object.DestroyImmediate(host); UnityEngine.Object.DestroyImmediate(settings);
                    EditorApplication.Exit(1);
                }
            };
            EditorApplication.update += check;
        }
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    }
}
