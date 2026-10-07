using System;
using System.Reflection;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class CompactLyricVisibilityChecks
    {
        public static void Verify()
        {
            var go = new GameObject("Compact lyric visibility check");
            try {
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
                var document = go.AddComponent<UIDocument>();
                document.panelSettings = Resources.Load<PanelSettings>("PlayerPanel");
                var root = document.rootVisualElement;
                Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
                // Materialize UIDocument while enabled, then keep runtime components
                // disabled. PlayerScreen.Start and native compact transitions never run.
                var player = go.AddComponent<PlayerScreen>();
                player.enabled = false;
                var compact = go.AddComponent<UnityCompactWindowController>();
                compact.enabled = false;
                var gpu = go.AddComponent<GpuLyricsView>();
                void Set(string field, object value) => typeof(PlayerScreen).GetField(field, flags).SetValue(player, value);
                void Call(string method, object argument) => typeof(PlayerScreen).GetMethod(method, flags).Invoke(player, new[] { argument });
                void Compact(bool active) { typeof(UnityCompactWindowController).GetField("<IsCompact>k__BackingField", flags).SetValue(compact, active); Call("OnCompactModeChanged", active); }
                bool Shown() => (bool)typeof(GpuLyricsView).GetField("shown", flags).GetValue(gpu);
                Set("root", root); Set("compactWindow", compact); Set("gpuLyrics", gpu);
                Set("lyric", root.Q<Label>("lyric")); Set("translation", root.Q<Label>("translation"));
                Set("status", root.Q<Label>("status")); Set("chatPanel", root.Q("chatPanel"));
                Set("volume", root.Q<Slider>("volume")); Set("play", root.Q<Button>("play"));
                Set("playIcon", new PlayerScreen.ToolbarIcon("play")); Set("livecamPlayIcon", new PlayerScreen.ToolbarIcon("play"));
                Set("sculpture", go.AddComponent<AudioSculpture>());
                var snapshot = new PlayerSnapshot { locale = UiLocalization.LocaleCode, lyric = "Hello", translation = "こんにちは", lyricVisual = new LyricVisualSnapshot { mode = "monet_poster" } };
                Call("OnSnapshot", snapshot); Require(Shown(), "Normal mode must show selected GPU lyrics");
                Compact(true); Require(!Shown(), "Compact transition must immediately hide GPU lyrics");
                for (int i = 0; i < 20; i++) { snapshot.position += .1; Call("OnSnapshot", snapshot); Require(!Shown(), "Snapshot must not restore compact GPU lyrics"); }
                snapshot.lyricVisual.mode = "unmigrated-test-style"; Call("OnSnapshot", snapshot);
                Require(root.Q<Label>("lyric").style.display.value == DisplayStyle.None && root.Q<Label>("translation").style.display.value == DisplayStyle.None,
                    "Compact snapshots must also suppress fallback lyrics");
                Compact(false); Require(root.Q<Label>("lyric").style.display.value == DisplayStyle.Flex, "Exit must restore fallback lyrics");
                snapshot.lyricVisual.mode = "monet_poster"; Call("OnSnapshot", snapshot); Require(Shown(), "Exit must restore selected GPU lyrics");
                Set("lyricsVisible", false); Compact(true); Call("OnSnapshot", snapshot); Compact(false); Call("OnSnapshot", snapshot);
                Require(!Shown() && root.Q<Label>("lyric").style.display.value == DisplayStyle.None,
                    "User hidden preference must survive compact entry and exit");
                Require((bool)typeof(PlayerScreen).GetField("lyricsVisible", flags).GetValue(player) == false, "Compact mode must preserve user preference");
                Debug.Log("CompactLyricVisibilityChecks PASS: immediate hide, 20 real snapshots, GPU/fallback restore, hidden user preference");
                UnityEngine.Object.DestroyImmediate(go); EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error);
                var compact = go.GetComponent<UnityCompactWindowController>();
                if (compact != null) typeof(UnityCompactWindowController).GetField("<IsCompact>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(compact, false);
                UnityEngine.Object.DestroyImmediate(go); EditorApplication.Exit(1);
            }
        }
    }
}
