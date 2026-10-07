using System;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class WishPanelChecks
    {
        public static void VerifyLayout()
        {
            var window = ScriptableObject.CreateInstance<EditorWindow>();
            window.position = new Rect(0, 0, 800, 600);
            var root = window.rootVisualElement;
            Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            var panel = new WishMachinePanel(root.Q(className: "body"), _ => true, () => {});
            var entries = new JArray();
            for (var i = 0; i < 50; i++) entries.Add(new JObject { ["name"] = new string('長', 160), ["stage"] = "ready", ["claimAvailable"] = true });
            panel.Show(); panel.Update(new JObject { ["status"] = "ok", ["entries"] = entries });
            window.Show();
            var deadline = EditorApplication.timeSinceStartup + 1;
            var phase = 0;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    void Require(bool value, string message) { if (!value) throw new Exception(message); }
                    var list = panel.Element.Q<ListView>();
                    var viewport = list.Q<ScrollView>().contentViewport;
                    var header = panel.Element.Q(className: "wish-header");
                    var footer = panel.Element.Q(className: "wish-footer");
                    Require(viewport.worldBound.height > 0, "Wish viewport must retain positive height");
                    Require(header.worldBound.yMax <= viewport.worldBound.yMin + 1, "Rows overlap wish header");
                    Require(viewport.worldBound.yMax <= footer.worldBound.yMin + 1, "Rows overlap create footer");
                    Require(footer.worldBound.yMax <= panel.Element.worldBound.yMax + 1, "Footer escapes panel");
                    foreach (var name in list.Query<Label>("wishName").ToList()) {
                        if (name.worldBound.height <= 0) continue;
                        Require(name.worldBound.width <= viewport.worldBound.width && name.worldBound.width > 0,
                            $"Long name overflows viewport: name={name.worldBound}, viewport={viewport.worldBound}");
                    }
                    if (phase++ == 0) {
                        list.ScrollToItem(49);
                        deadline = EditorApplication.timeSinceStartup + 1;
                        return;
                    }
                    Require(list.Q<ScrollView>().horizontalScroller.resolvedStyle.display == DisplayStyle.None,
                        "Horizontal bar must stay hidden at bottom");
                    Debug.Log("WishPanelLayout PASS: 50 long-name items, bounded header/footer, bottom scrolling");
                    EditorApplication.update -= check; panel.Dispose(); window.Close(); EditorApplication.Exit(0);
                } catch (Exception error) {
                    Debug.LogException(error); EditorApplication.update -= check; panel.Dispose(); window.Close(); EditorApplication.Exit(1);
                }
            };
            EditorApplication.update += check;
        }
        public static void Verify()
        {
            try {
                void Require(bool value, string message) { if (!value) throw new Exception(message); }
                var parent = new VisualElement();
                using var panel = new WishMachinePanel(parent, _ => true, () => {});
                var list = panel.Element.Q<ListView>();
                Require(list.Q<ScrollView>().horizontalScrollerVisibility == ScrollerVisibility.Hidden,
                    "Wish list must disable horizontal scrolling");
                Require(panel.Element.ClassListContains("wish-panel"), "Wish panel must use shared bounded panel styling");
                Require(panel.Element.Q<Button>("wishRefresh").Q<PlayerScreen.ToolbarIcon>() != null,
                    "Refresh must use the shared icon, not notification text");
                Require(panel.Element.Q<Button>("wishClose").Q<PlayerScreen.ToolbarIcon>() != null,
                    "Close must use the shared icon");
                panel.Update(new JObject { ["status"] = "ok", ["entries"] = new JArray(
                    new JObject { ["name"] = new string('長', 160), ["stage"] = "claimed", ["inventoryRegistered"] = true },
                    new JObject { ["name"] = "Ready", ["stage"] = "ready", ["claimAvailable"] = true }) });
                var row = list.makeItem(); list.bindItem(row, 0);
                Require(row.Q<Label>("wishName").ClassListContains("wish-name"), "Long names need bounded ellipsis styling");
                Require(row.Q<Button>("wishAction").resolvedStyle.display == DisplayStyle.None ||
                    row.Q<Button>("wishAction").style.display.value == DisplayStyle.None, "Registered item must not offer another claim");
                list.bindItem(row, 1);
                Require(row.Q<Button>("wishAction").enabledSelf, "Ready item must keep its claim operation available");
                Debug.Log("WishPanelChecks PASS: bounded list, icon header, long-name styling, claim-state binding");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
        }
    }
}
