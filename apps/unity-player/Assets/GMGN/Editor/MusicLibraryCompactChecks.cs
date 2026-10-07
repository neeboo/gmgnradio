using System;
using System.Reflection;
using System.Runtime.Serialization;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;
using UnityEngine.Localization.Tables;

namespace GMGN.UnityPlayer.Editor
{
    public static class MusicLibraryCompactChecks
    {
        public static void Verify()
        {
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            var localeField = typeof(UiLocalization).GetField("table", BindingFlags.Static | BindingFlags.NonPublic);
            var previousTable = localeField.GetValue(null);
            var chineseTable = AssetDatabase.LoadAssetAtPath<StringTable>("Assets/GMGN/Localization/GMGN UI_zh-CN.asset");
            if (chineseTable == null) throw new Exception("Actual Chinese UI table is missing");
            localeField.SetValue(null, chineseTable);
            var window = ScriptableObject.CreateInstance<EditorWindow>();
            window.minSize = new Vector2(224, 336); window.position = new Rect(0, 0, 224, 336);
            var root = window.rootVisualElement;
            Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            root.AddToClassList("compact"); root.style.width = 224; root.style.height = 336;
            // The real panel receives fixture metadata but never calls a native host.
            var backend = (NativePlayerBackend)FormatterServices.GetUninitializedObject(typeof(NativePlayerBackend));
            var panel = new MusicLibraryPanel(root.Q(className: "body"), backend, () => {});
            var playlists = new JArray();
            for (int i = 0; i < 50; i++) playlists.Add(new JObject { ["id"] = "fixture-" + i, ["name"] = "中文歌单 " + i, ["provider"] = "local", ["count"] = 1 });
            typeof(MusicLibraryPanel).GetMethod("Update", flags).Invoke(panel, new object[] { new JObject { ["operation"] = "library", ["playlists"] = playlists } });
            panel.SetVisible(true); window.Show();
            int phase = 0; double deadline = EditorApplication.timeSinceStartup + 1;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    var title = (Label)typeof(MusicLibraryPanel).GetField("title", flags).GetValue(panel);
                    var count = (Label)typeof(MusicLibraryPanel).GetField("count", flags).GetValue(panel);
                    var history = panel.Element.Q<Button>("programHistoryToggle");
                    var header = panel.Element.Q(className: "music-library-header");
                    void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
                    Require(panel.Element.worldBound.width > 0 && header.worldBound.height < 40, "Header must remain a single compact row");
                    Require(!string.IsNullOrEmpty(title.text) && title.resolvedStyle.whiteSpace == WhiteSpace.NoWrap && title.worldBound.height > 0 && title.worldBound.height < 30, "Actual localized title must remain visible and never form a vertical Chinese column");
                    Require(string.IsNullOrEmpty(history.text) && history.tooltip.Length > 0, "History toggle must be an icon with a descriptive tooltip");
                    Require(history.worldBound.xMax <= header.worldBound.xMax + 1, "History toggle exceeds header bounds");
                    if (phase < 3) {
                        Require(root.worldBound.width <= 225, "Fixture must actually constrain layout to 224 pixels");
                        Require(history.worldBound.width >= 25 && history.worldBound.width <= 27, "Compact history control must remain usable and bounded");
                        if (phase < 2) {
                            Require(title.worldBound.xMax <= count.worldBound.xMin + 1, "Title overlaps count");
                            Require(count.worldBound.xMax <= history.worldBound.xMin + 1, "Count overlaps history control");
                            Require(count.text == (phase == 0 ? "· 50" : "· 20") && count.worldBound.width > 15, "List count must remain visible");
                        } else Require(count.resolvedStyle.display == DisplayStyle.None, "Detail header must release count space for back button");
                    } else Require(history.worldBound.width >= 31 && history.worldBound.width <= 33, "Normal control size changed");
                    foreach (var child in header.Children()) if (child is Button button && button.resolvedStyle.display != DisplayStyle.None)
                        Require(button.worldBound.xMax <= header.worldBound.xMax + 1, "Header button exceeds available width");
                    Debug.Log($"PASS MusicLibraryCompactChecks phase={phase} root={root.worldBound} header={header.worldBound} title={title.worldBound} count={count.worldBound} history={history.worldBound}");
                    if (phase == 0) {
                        typeof(MusicLibraryPanel).GetField("historyView", flags).SetValue(panel, true);
                        var programs = new JArray();
                        for (int i = 0; i < 20; i++) programs.Add(new JObject { ["id"] = "program-" + i, ["name"] = "历史节目 " + i, ["count"] = 8, ["tracks"] = new JArray() });
                        typeof(MusicLibraryPanel).GetMethod("Update", flags).Invoke(panel, new object[] { new JObject { ["operation"] = "program-history", ["programs"] = programs } });
                        phase++; deadline = EditorApplication.timeSinceStartup + .5; return;
                    }
                    if (phase == 1) {
                        typeof(MusicLibraryPanel).GetMethod("ShowTracks", flags).Invoke(panel, new object[] { true });
                        phase++; deadline = EditorApplication.timeSinceStartup + .5; return;
                    }
                    if (phase == 2) {
                        root.RemoveFromClassList("compact"); root.style.width = 1600; root.style.height = 900;
                        window.position = new Rect(0, 0, 1600, 900);
                        typeof(MusicLibraryPanel).GetMethod("ShowTracks", flags).Invoke(panel, new object[] { false });
                        phase++; deadline = EditorApplication.timeSinceStartup + .5; return;
                    }
                    EditorApplication.update -= check; panel.Dispose(); window.Close();
                    localeField.SetValue(null, previousTable);
                    Debug.Log("PASS MusicLibraryCompactChecks: actual 224x336 playlist/history title and count remain horizontal; normal controls preserved; no host calls");
                    EditorApplication.Exit(0);
                } catch (Exception error) {
                    Debug.LogException(error); EditorApplication.update -= check; panel.Dispose(); window.Close(); localeField.SetValue(null, previousTable); EditorApplication.Exit(1);
                }
            };
            EditorApplication.update += check;
        }
    }
}
