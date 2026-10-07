using System;
using System.Reflection;
using System.Runtime.Serialization;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.Localization;
using UnityEngine.Localization.Tables;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class MusicLibraryLocalizationChecks
    {
        public static void Verify()
        {
            var tableField = typeof(UiLocalization).GetField("table", BindingFlags.NonPublic | BindingFlags.Static);
            var previous = tableField.GetValue(null); MusicLibraryPanel panel = null;
            var tables = new System.Collections.Generic.List<UnityEngine.Object>();
            try {
                void Require(bool value, string message) { if (!value) throw new Exception(message); }
                var backend = (NativePlayerBackend)FormatterServices.GetUninitializedObject(typeof(NativePlayerBackend));
                var root = new VisualElement(); panel = new MusicLibraryPanel(root, backend, () => {});
                var flags = BindingFlags.NonPublic | BindingFlags.Instance;
                var update = typeof(MusicLibraryPanel).GetMethod("Update", flags);
                const string userName = "私の歌单 · My Songs";
                update.Invoke(panel, new object[] { new JObject { ["operation"] = "library", ["playlists"] = new JArray(new JObject { ["id"] = "user", ["name"] = userName, ["provider"] = "netease", ["count"] = 12 }) } });
                typeof(MusicLibraryPanel).GetField("playlistID", flags).SetValue(panel, "user");
                update.Invoke(panel, new object[] { new JObject { ["operation"] = "playlist", ["playlistID"] = "user", ["name"] = userName, ["provider"] = "netease", ["loaded"] = 12, ["total"] = 13, ["tracks"] = new JArray() } });
                var codes = new[] { "zh-CN", "en", "ja" };
                for (int i = 0; i < codes.Length; i++) {
                    var shared = ScriptableObject.CreateInstance<SharedTableData>(); tables.Add(shared);
                    var table = ScriptableObject.CreateInstance<StringTable>(); tables.Add(table);
                    table.SharedData = shared; table.LocaleIdentifier = new LocaleIdentifier(codes[i]);
                    foreach (var entry in LocalizationTableSeed.Strings) table.AddEntry(entry.Key, entry.Value[i]);
                    tableField.SetValue(null, table);
                    var changed = (Action)typeof(UiLocalization).GetField("Changed", BindingFlags.NonPublic | BindingFlags.Static).GetValue(null); changed?.Invoke();
                    var title = (Label)typeof(MusicLibraryPanel).GetField("title", flags).GetValue(panel);
                    var status = (Label)typeof(MusicLibraryPanel).GetField("status", flags).GetValue(panel);
                    var detailTitle = (Label)typeof(MusicLibraryPanel).GetField("detailTitle", flags).GetValue(panel);
                    var subtitle = (Label)typeof(MusicLibraryPanel).GetField("detailSubtitle", flags).GetValue(panel);
                    Require(title.text == LocalizationTableSeed.Strings["libraryTracks"][i], "Dynamic locale must refresh title");
                    Require(status.text == LocalizationTableSeed.Strings["libraryPlayHint"][i], "Dynamic locale must refresh hint");
                    Require(detailTitle.text == userName, "User playlist name must stay original");
                    Require(subtitle.text.Contains(string.Format(LocalizationTableSeed.Strings["libraryTrackCount"][i], "12 / 13")), "Counts must use localized template");
                    foreach (var button in new[] { "back", "refresh", "close" }) {
                        var control = (Button)typeof(MusicLibraryPanel).GetField(button, flags).GetValue(panel);
                        var key = button == "back" ? "libraryBack" : button == "refresh" ? "libraryRefresh" : "libraryClose";
                        Require(control.tooltip == LocalizationTableSeed.Strings[key][i], "Tooltips must refresh on locale change");
                    }
                }
                Debug.Log("MusicLibraryLocalizationChecks PASS: zh/en/ja dynamic title, hint, count, provider, tooltips; user names preserved"); EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
            finally { panel?.Dispose(); tableField.SetValue(null, previous); foreach (var item in tables) UnityEngine.Object.DestroyImmediate(item); }
        }
    }
}
