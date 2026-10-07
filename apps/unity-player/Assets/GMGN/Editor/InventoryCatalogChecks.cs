using System;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UIElements;
using GMGN.UnityPlayer.World;
using UnityEditor;

namespace GMGN.UnityPlayer.Editor
{
    public static class InventoryCatalogChecks
    {
        // Pure UI/projection check: no task daemon, model import, audio or world writes.
        public static void Run()
        {
            GameObject root = null;
            BuiltinDeviceCatalogPanel panel = null;
            try {
                root = new GameObject("Inventory catalog check");
                var bridge = root.AddComponent<WorldRuntimeBridge>();
                var objects = new JObject();
                for (int i = 0; i < 6; i++) objects["prop-" + i] = new JObject {
                    ["isEnabled"] = i != 5,
                    ["metadata"] = new JObject { ["gmgn.generated-prop.v1"] = new JObject { ["displayName"] = "Owned " + i }.ToString() }
                };
                objects["builtin"] = new JObject { ["isEnabled"] = true };
                var state = new JObject { ["objectStates"] = objects,
                    ["heldProp"] = new JObject { ["objectID"] = "prop-4" },
                    ["propTombstones"] = new JObject { ["prop-3"] = new JObject { ["deleted"] = true } } };
                typeof(WorldRuntimeBridge).GetProperty("AuthorityProjection").SetValue(bridge, new JObject { ["state"] = state });
                JArray inventory = null;
                bridge.InventoryUpdated += value => inventory = value;
                typeof(WorldRuntimeBridge).GetMethod("PublishInventory", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(bridge, new object[] { objects });
                Require(inventory.Count == 5, "placed and stored generated objects retained; tombstone and builtin omitted");
                Require((bool)inventory.Single(item => (string)item["objectID"] == "prop-4")["held"], "held object retained and labelled");
                Require(!(bool)inventory.Single(item => (string)item["objectID"] == "prop-5")["placed"], "stored object labelled");
                var ui = new VisualElement();
                panel = new BuiltinDeviceCatalogPanel(ui); panel.SetInventory(inventory);
                Require(ui.Query<Label>().ToList().Count(label => label.text.StartsWith("Owned ")) == 5, "all owned rows rendered");
                Require(ui.Query<Button>().ToList().Count(button => button.text == "删除") == 5, "delete only for owned generated rows");
                Require(ui.Query<Button>().ToList().Where(button => button.text == "删除").Count(button => !button.enabledSelf) == 1, "held deletion disabled");
                Require(ui.Query<VisualElement>(className: "inventory-card").ToList().Count == 5, "each generated object has a styled card");
                Require(ui.Query<Label>(className: "inventory-badge").ToList().Count == 5, "state labels separated from object names");
                Require(ui.Query<Label>(className: "inventory-held").ToList().Count == 1, "held state distinct from placed state");
                Require(ui.Q<VisualElement>("builtinDeviceCatalog").styleSheets.count == 1, "dedicated inventory stylesheet loaded");
                panel.SetTemplates(new JArray {
                    new JObject { ["id"] = "jukebox", ["renderer"] = "builtin.jukebox" },
                    new JObject { ["id"] = "wish", ["renderer"] = "builtin.wish_machine" }
                }, "zh");
                Require(ui.Query<VisualElement>(className: "inventory-essential").ToList().Count == 2, "protected essentials separate from owned cards");
                Require(ui.Query<Button>().ToList().Count(button => button.text == "删除") == 5, "essentials have no delete affordance");
                panel.SetInventory(new JArray());
                Require(ui.Query<Label>(className: "inventory-empty").ToList().Count == 1, "empty inventory explains where generated objects appear");
                Debug.Log("InventoryCatalogChecks PASS");
                UnityEditor.EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error); UnityEditor.EditorApplication.Exit(1);
            } finally { panel?.Dispose(); if (root != null) UnityEngine.Object.DestroyImmediate(root); }
        }
        static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        public static void VerifyLayout()
        {
            try {
                foreach (var scale in UnityEngine.Object.FindObjectsByType<NativeUIScale>(FindObjectsSortMode.None)) scale.enabled = false;
                foreach (var size in new[] { new Vector2Int(720, 450), new Vector2Int(2048, 1152) })
                    CheckRuntimeLayout(size);
                Debug.Log("InventoryCatalogChecks layout PASS: actual Retina runtime panels, 50 long Chinese titles, header/toolbar containment, top/middle/bottom clipping and scroll reachability");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
        }
        static void CheckRuntimeLayout(Vector2Int size)
        {
            var go = new GameObject("Inventory layout fixture");
            var target = new RenderTexture(size.x * 2, size.y * 2, 0); target.Create();
            var settings = UnityEngine.Object.Instantiate(Resources.Load<PanelSettings>("PlayerPanel"));
            settings.scaleMode = PanelScaleMode.ConstantPixelSize; settings.scale = 2; settings.targetTexture = target;
            var document = go.AddComponent<UIDocument>(); document.panelSettings = settings;
            var root = document.rootVisualElement;
            root.style.width = size.x; root.style.height = size.y;
            Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player")); root.AddToClassList("document-root");
            if (size.x == 720) root.AddToClassList("compact-window");
            var owner = root.Q(className: "body");
            var catalog = new BuiltinDeviceCatalogPanel(owner);
            var inventory = new JArray();
            for (int i = 0; i < 50; i++) inventory.Add(new JObject {
                ["objectID"] = "layout-prop-" + i, ["name"] = "白色长剑与三人布艺沙发" + new string('长', 120) + i,
                ["modelReady"] = true, ["placed"] = i % 2 == 0, ["held"] = i == 4
            });
            catalog.SetTemplates(new JArray {
                new JObject { ["id"] = "jukebox", ["renderer"] = "builtin.jukebox" },
                new JObject { ["id"] = "wish", ["renderer"] = "builtin.wish_machine" }
            }, "zh");
            catalog.SetInventory(inventory); catalog.Show();
            try {
                RenderPanel(root);
                Require(root.panel.contextType == ContextType.Player && Mathf.Abs(root.layout.width - size.x) < 1 && Mathf.Abs(root.layout.height - size.y) < 1,
                    "Fixture must use the actual runtime panel scale: " + root.layout);
                var panel = owner.Q("builtinDeviceCatalog"); var scroll = panel.Q<ScrollView>();
                var viewport = scroll.contentViewport; var header = panel.Q(className: "inventory-header");
                Require(scroll.verticalScroller.highValue > 100, "Many objects must create a real scrolling range");
                for (int phase = 0; phase < 3; phase++) {
                    scroll.scrollOffset = new Vector2(0, phase == 0 ? 0 : phase == 1 ? scroll.verticalScroller.highValue / 2 : scroll.verticalScroller.highValue);
                    RenderPanel(root);
                    Require(Inside(panel.worldBound, owner.worldBound), "Inventory popup escapes its actual body: " + panel.worldBound + " / " + owner.worldBound);
                    Require(Inside(header.worldBound, panel.worldBound), "Inventory header escapes popup");
                    Require(viewport.worldBound.height >= 60 && Inside(viewport.worldBound, panel.worldBound), "Real scroll viewport is empty or escapes popup: " + viewport.worldBound);
                    Require(header.worldBound.yMax <= viewport.worldBound.yMin + 1, "Scrolled cards overlap header");
                    Require(scroll.horizontalScroller.resolvedStyle.display == DisplayStyle.None, "Long Chinese names must not create horizontal scrolling");
                    var cards = panel.Query<VisualElement>(className: "inventory-card").ToList();
                    foreach (var card in cards) {
                        Require(card.worldBound.xMin >= viewport.worldBound.xMin - 1 && card.worldBound.xMax <= viewport.worldBound.xMax + 1, "Card exceeds viewport horizontally");
                        var name = card.Q<Label>(className: "inventory-name");
                        Require(name.worldBound.width > 0 && Inside(name.worldBound, card.worldBound), "Long title escapes its card");
                        // Rendering and picking share the viewport clip. Offscreen rows
                        // must not intercept clicks in the fixed header or panel padding.
                        foreach (var point in new[] { new Vector2(viewport.worldBound.center.x, viewport.worldBound.yMin - 4), new Vector2(viewport.worldBound.center.x, viewport.worldBound.yMax + 4) }) {
                            var picked = root.panel.Pick(point);
                            Require(picked == null || (picked != card && !card.Contains(picked)), "Offscreen card steals a click beyond the scroll clip");
                        }
                    }
                    if (phase == 2) Require(cards.Last().worldBound.yMax <= viewport.worldBound.yMax + 2 && cards.Last().worldBound.yMax > viewport.worldBound.yMin, "Last item must be reachable by scrolling to bottom");
                    SaveLayoutImage(target, $"/tmp/gmgn-inventory-layout-{size.x}x{size.y}-{phase}.png");
                    Debug.Log($"InventoryCatalogChecks geometry PASS size={size} phase={phase} owner={owner.worldBound} panel={panel.worldBound} header={header.worldBound} viewport={viewport.worldBound} offset={scroll.scrollOffset} range={scroll.verticalScroller.highValue}");
                }
            } finally { catalog.Dispose(); UnityEngine.Object.DestroyImmediate(go); UnityEngine.Object.DestroyImmediate(settings); target.Release(); UnityEngine.Object.DestroyImmediate(target); }
        }
        static bool Inside(Rect child, Rect parent) => child.xMin >= parent.xMin - 1 && child.yMin >= parent.yMin - 1 && child.xMax <= parent.xMax + 1 && child.yMax <= parent.yMax + 1;
        static void RenderPanel(VisualElement root)
        {
            // Match StageVideoOrientationChecks: Edit mode does not automatically
            // drive a runtime panel. Use its real renderer, not a synthetic Yoga tree.
            var panel = root.panel; var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
            for (int i = 0; i < 4; i++) {
                panel.GetType().GetMethod("Update", flags).Invoke(panel, null);
                panel.GetType().GetMethod("UpdateForRepaint", flags).Invoke(panel, null);
            }
            panel.GetType().GetMethod("Repaint", flags).Invoke(panel, null);
            panel.GetType().GetMethod("Render", flags).Invoke(panel, null);
        }
        static void SaveLayoutImage(RenderTexture target, string path)
        {
            var previous = RenderTexture.active; var image = new Texture2D(target.width, target.height, TextureFormat.RGBA32, false);
            try { RenderTexture.active = target; image.ReadPixels(new Rect(0, 0, target.width, target.height), 0, 0); image.Apply(); System.IO.File.WriteAllBytes(path, image.EncodeToPNG()); }
            finally { RenderTexture.active = previous; UnityEngine.Object.DestroyImmediate(image); }
        }
    }
}
