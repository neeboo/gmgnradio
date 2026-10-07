using System;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class PopupLifecycleChecks
    {
        public static void VerifyScreenLayout()
        {
            var window = ScriptableObject.CreateInstance<EditorWindow>();
            window.position = new Rect(0, 0, 800, 600);
            var root = window.rootVisualElement;
            Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            var go = new GameObject("Screen layout check"); go.SetActive(false);
            var controller = go.AddComponent<UnityScreenVideoController>();
            var body = root.Q(className: "body"); controller.Initialize(body, _ => true);
            var entries = new JArray();
            for (int i = 0; i < 50; i++) entries.Add(new JObject { ["objectID"] = "screen-" + i, ["name"] = new string('長', 100), ["state"] = "ready" });
            controller.ApplySnapshot(new JObject { ["screens"] = entries }); controller.Show();
            window.Show(); var deadline = EditorApplication.timeSinceStartup + 1; int phase = 0;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    void Require(bool value, string message) { if (!value) throw new Exception(message); }
                    var panel = body.Q("screenVideoPanel"); var header = panel.Q(className: "screen-video-header");
                    var scroll = panel.Q<ScrollView>("screenVideoRows"); var viewport = scroll.contentViewport;
                    if (phase == 2) {
                        Require(!controller.Visible, "Actual close button submit must dismiss screen");
                        Debug.Log("ScreenPopupLayout PASS: 50 long rows, bounded viewport/header, bottom reachability, actual close button");
                        EditorApplication.update -= check; UnityEngine.Object.DestroyImmediate(go); window.Close(); EditorApplication.Exit(0); return;
                    }
                    Require(panel.parent == body, "Screen must be positioned in the same body as toolbar");
                    Require(panel.worldBound.xMin >= body.worldBound.xMin - 1 && panel.worldBound.xMax <= body.worldBound.xMax + 1, "Screen escapes body horizontally");
                    Require(panel.worldBound.yMin >= body.worldBound.yMin - 1, "Screen escapes body above");
                    Require(viewport.worldBound.height > 0, "Screen viewport must retain positive height");
                    Require(header.worldBound.yMax <= viewport.worldBound.yMin + 1, "Screen rows overlap header");
                    Require(viewport.worldBound.yMax <= panel.worldBound.yMax + 1, "Screen rows escape card");
                    Require(scroll.horizontalScroller.resolvedStyle.display == DisplayStyle.None, "Screen must have no horizontal bar");
                    if (phase == 0) { phase++; scroll.ScrollTo(scroll.contentContainer[49]); deadline = EditorApplication.timeSinceStartup + 1; return; }
                    Require(scroll.contentContainer[49].worldBound.yMax <= viewport.worldBound.yMax + 2, "Last screen must scroll into view");
                    if (phase == 1) {
                        phase++; var close = panel.Q<Button>("screenClose"); close.Focus();
                        using (var submit = NavigationSubmitEvent.GetPooled()) close.SendEvent(submit);
                        deadline = EditorApplication.timeSinceStartup + .2; return;
                    }
                } catch (Exception error) { Debug.LogException(error); EditorApplication.update -= check; UnityEngine.Object.DestroyImmediate(go); window.Close(); EditorApplication.Exit(1); }
            };
            EditorApplication.update += check;
        }
        public static void Verify()
        {
            var go = new GameObject("Popup lifecycle check"); go.SetActive(false);
            try {
                void Require(bool value, string message) { if (!value) throw new Exception(message); }
                var root = new VisualElement();
                root.Add(new Button { name = "chatToggle" });
                root.Add(new VisualElement { name = "livecamPlayerMenu" });
                var chat = new VisualElement(); root.Add(chat);
                var catalog = new VisualElement { name = "builtinDeviceCatalog" }; root.Add(catalog);
                var screen = go.AddComponent<UnityScreenVideoController>(); screen.Initialize(root, _ => true);
                using var wish = new WishMachinePanel(root, _ => true, () => {});
                var player = go.AddComponent<PlayerScreen>();
                var flags = BindingFlags.Instance | BindingFlags.NonPublic;
                typeof(PlayerScreen).GetField("root", flags).SetValue(player, root);
                typeof(PlayerScreen).GetField("chatPanel", flags).SetValue(player, chat);
                typeof(PlayerScreen).GetField("screenVideo", flags).SetValue(player, screen);
                typeof(PlayerScreen).GetField("wishPanel", flags).SetValue(player, wish);
                screen.Show(); wish.Show();
                Require(screen.Visible, "Screen must open");
                Require(root.Q<Button>("screenClose").Q<PlayerScreen.ToolbarIcon>() != null, "Screen close must use shared icon");
                using (var escape = KeyDownEvent.GetPooled(new Event { type = EventType.KeyDown, keyCode = KeyCode.Escape }))
                    typeof(PlayerScreen).GetMethod("DismissPopupOnEscape", flags).Invoke(player, new object[] { escape });
                Require(!screen.Visible && wish.Element.ClassListContains("hidden") && chat.ClassListContains("hidden"), "ClosePopups must close all competing panels");
                Require(PlayerScreen.PopupDismissedFrame == Time.frameCount, "Escape must consume its frame for world interaction gate");
                screen.Hide();
                Require(!screen.Visible, "Close must remain idempotent");
                screen.Show(); wish.Show();
                typeof(PlayerScreen).GetMethod("OnCompactModeChanged", flags).Invoke(player, new object[] { true });
                Require(!screen.Visible && wish.Element.ClassListContains("hidden"), "Entering compact must hide full-size device popups");
                Debug.Log("PopupLifecycleChecks PASS: shared screen close icon, production Escape handler dismisses competitors and consumes frame, idempotent close");
                UnityEngine.Object.DestroyImmediate(go); EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); UnityEngine.Object.DestroyImmediate(go); EditorApplication.Exit(1); }
        }
    }
}
