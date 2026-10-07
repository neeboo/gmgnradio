using System;
using System.Reflection;
using System.Runtime.Serialization;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class MusicPopupChecks
    {
        public static void Verify()
        {
            var window = ScriptableObject.CreateInstance<EditorWindow>(); window.position = new Rect(0, 0, 1600, 900);
            var root = window.rootVisualElement; Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            var go = new GameObject("Music popup check"); go.SetActive(false);
            var player = go.AddComponent<PlayerScreen>(); const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            // The test exercises the production component and click route, with
            // seeded library data so it never starts or calls a native host.
            var backend = (NativePlayerBackend)FormatterServices.GetUninitializedObject(typeof(NativePlayerBackend));
            var music = new MusicLibraryPanel(root.Q(className: "body"), backend, () => {});
            typeof(MusicLibraryPanel).GetMethod("Update", flags).Invoke(music, new object[] { new JObject {
                ["operation"] = "library", ["playlists"] = new JArray(new JObject { ["id"] = "fixture", ["name"] = "Fixture", ["provider"] = "local", ["trackCount"] = 1 }) } });
            typeof(PlayerScreen).GetField("root", flags).SetValue(player, root);
            typeof(PlayerScreen).GetField("chatPanel", flags).SetValue(player, root.Q("chatPanel"));
            typeof(PlayerScreen).GetField("musicLibraryPanel", flags).SetValue(player, music);
            var button = root.Q<Button>("chooseMusic"); button.SetEnabled(true);
            button.clicked += (Action)Delegate.CreateDelegate(typeof(Action), player, typeof(PlayerScreen).GetMethod("ToggleMusicLibrary", flags));
            window.Show(); var deadline = EditorApplication.timeSinceStartup + 1; int phase = 0;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
                    if (phase == 0 || phase == 2) {
                        button.Focus(); using (var submit = NavigationSubmitEvent.GetPooled()) button.SendEvent(submit);
                        phase++; deadline = EditorApplication.timeSinceStartup + .4; return;
                    }
                    if (phase == 1) {
                        Require(!music.Element.ClassListContains("hidden") && music.Element.resolvedStyle.display == DisplayStyle.Flex, "Actual library button must show panel");
                        Require(music.Element.worldBound.width > 0 && music.Element.worldBound.height > 0, "Library must retain visible geometry");
                        Require(music.Element.worldBound.yMax <= button.worldBound.yMin, "Library must sit above toolbar");
                        phase++; deadline = EditorApplication.timeSinceStartup + .2; return;
                    }
                    Require(music.Element.ClassListContains("hidden"), "Second actual button submit must close library");
                    Debug.Log("MusicPopupChecks PASS: actual toolbar submit opens visible library above toolbar and toggles closed");
                    EditorApplication.update -= check; music.Dispose(); UnityEngine.Object.DestroyImmediate(go); window.Close(); EditorApplication.Exit(0);
                } catch (Exception error) { Debug.LogException(error); EditorApplication.update -= check; music.Dispose(); UnityEngine.Object.DestroyImmediate(go); window.Close(); EditorApplication.Exit(1); }
            }; EditorApplication.update += check;
        }
    }
}
