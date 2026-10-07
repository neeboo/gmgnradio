using System;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.World
{
    /// Selection emits an authored template ID only. The host owns registration,
    /// placement validation and saved identities; opening this panel writes nothing.
    public sealed class BuiltinDeviceCatalogPanel : IDisposable
    {
        readonly VisualElement panel, rows, owner;
        readonly Label title;
        JArray templateCache = new JArray();
        JArray inventoryCache = new JArray();
        public event Action<string> Selection;
        public event Action<string> InventorySelection;
        public event Action<string> InventoryDeletion;
        public BuiltinDeviceCatalogPanel(VisualElement root)
        {
            owner = root;
            panel = new VisualElement { name = "builtinDeviceCatalog" };
            panel.style.position = Position.Absolute;
            panel.style.right = 24; panel.style.bottom = 16;
            panel.AddToClassList("inventory-panel");
            var sheet = Resources.Load<StyleSheet>("Inventory");
            if (sheet != null) panel.styleSheets.Add(sheet);
            var header = new VisualElement(); header.AddToClassList("inventory-header");
            title = new Label(); title.AddToClassList("inventory-title");
            header.Add(title); var close = new Button(Hide) { text = "×", tooltip = Text("关闭", "Close", "閉じる") };
            close.AddToClassList("inventory-close"); header.Add(close);
            panel.Add(header); var scroll = new ScrollView(ScrollViewMode.Vertical);
            scroll.AddToClassList("inventory-scroll");
            scroll.horizontalScrollerVisibility = ScrollerVisibility.Hidden;
            scroll.contentViewport.AddToClassList("inventory-viewport");
            scroll.contentContainer.AddToClassList("inventory-content");
            rows = scroll.contentContainer; panel.Add(scroll); root.Add(panel); Hide();
            owner.RegisterCallback<GeometryChangedEvent>(OnOwnerGeometryChanged);
            UpdatePanelHeight();
            UiLocalization.Changed += RefreshStrings;
        }
        void OnOwnerGeometryChanged(GeometryChangedEvent _) => UpdatePanelHeight();
        void UpdatePanelHeight()
        {
            // A definite height gives Yoga a bounded scrolling region. Percentage
            // max-height alone leaves ScrollView measuring its full content height.
            if (owner.contentRect.height > 0)
                panel.style.height = Mathf.Min(560, Mathf.Max(0, owner.contentRect.height - 32));
        }
        void RefreshStrings() => Render();
        public void SetInventory(JArray items) { inventoryCache = items == null ? new JArray() : (JArray)items.DeepClone(); Render(); }
        public void SetTemplates(JArray declarations, string locale)
        {
            templateCache = declarations == null ? new JArray() : (JArray)declarations.DeepClone();
            Render();
        }
        void Render()
        {
            title.text = Text("物品", "Objects", "アイテム");
            rows.Clear();
            AddSection(Text("基本设备", "ESSENTIALS", "基本設備"));
            foreach (var token in templateCache)
            {
                var renderer = (string)token["renderer"]; var id = (string)token["id"];
                if (string.IsNullOrEmpty(id) || (renderer != "builtin.jukebox" && renderer != "builtin.wish_machine")) continue;
                var wish = renderer == "builtin.wish_machine";
                var label = UiLocalization.Get(wish ? "wishMachine" : "jukebox");
                var row = new VisualElement(); row.AddToClassList("inventory-essential");
                var icon = new Label(wish ? "✦" : "♫"); icon.AddToClassList("inventory-symbol"); row.Add(icon);
                var info = new VisualElement(); info.AddToClassList("inventory-info");
                var name = new Label(label); name.AddToClassList("inventory-name"); info.Add(name);
                var hint = new Label(Text("空间设备 · 保留", "Space device · protected", "空間設備 · 保護")); hint.AddToClassList("inventory-detail"); info.Add(hint); row.Add(info);
                var button = new Button(() => { Selection?.Invoke(id); Hide(); }) { text = Text("摆放", "Place", "配置") };
                button.AddToClassList("inventory-primary"); row.Add(button); rows.Add(row);
            }
            AddSection(Text("我的物品", "MY OBJECTS", "所有アイテム") + "  ·  " + inventoryCache.Count);
            if (inventoryCache.Count == 0) {
                var empty = new Label(Text("还没有物品\n生成的物品会收在这里。", "No objects yet\nGenerated objects will appear here.", "アイテムはまだありません\n生成したアイテムがここに表示されます。"));
                empty.AddToClassList("inventory-empty"); rows.Add(empty);
            }
            foreach(var item in inventoryCache) {
                var id = (string)item["objectID"];
                if(string.IsNullOrEmpty(id)) continue;
                bool held = (bool?)item["held"] == true, placed = (bool?)item["placed"] == true;
                string state = held ? Text("手持中", "Held", "手持ち") : placed ? Text("已摆放", "Placed", "配置済み") : Text("未摆放", "Stored", "未配置");
                var row = new VisualElement(); row.AddToClassList("inventory-card");
                var heading = new VisualElement(); heading.AddToClassList("inventory-card-heading");
                var name = new Label((string)item["name"] ?? id); name.AddToClassList("inventory-name"); name.tooltip = name.text;
                heading.Add(name);
                var badge = new Label(state); badge.AddToClassList("inventory-badge"); badge.AddToClassList(held ? "inventory-held" : placed ? "inventory-placed" : "inventory-stored"); heading.Add(badge); row.Add(heading);
                bool ready = (bool?)item["modelReady"] == true;
                var detail = new Label(held ? Text("让角色放下后，再移动或删除", "Put down before moving or deleting", "置いてから移動・削除できます") : !ready ? Text("模型正在载入，物品已保留", "Loading model · object retained", "モデルを読み込み中 · 保存済み") : placed ? Text("已在空间中 · 可重新调整位置", "In your space · position can be changed", "空間に配置済み · 位置変更可能") : Text("收在物品库 · 选择位置即可摆放", "In storage · choose a position to place", "保管中 · 場所を選んで配置"));
                detail.AddToClassList("inventory-detail"); row.Add(detail);
                var actions = new VisualElement(); actions.AddToClassList("inventory-actions");
                var button = new Button(() => InventorySelection?.Invoke(id)) { text = placed ? Text("重新摆放", "Move", "移動") : Text("摆放", "Place", "配置") };
                button.SetEnabled(!held && ready); button.AddToClassList("inventory-primary");
                var remove = new Button() { text = Text("删除", "Delete", "削除") };
                remove.AddToClassList("inventory-delete");
                bool confirmed = false;
                remove.clicked += () => {
                    if (!confirmed) { confirmed = true; remove.text = Text("确认删除", "Confirm delete", "削除を確認"); remove.AddToClassList("inventory-delete-confirm"); return; }
                    InventoryDeletion?.Invoke(id); remove.SetEnabled(false);
                };
                remove.SetEnabled(!held); actions.Add(button); actions.Add(remove); row.Add(actions); rows.Add(row);
            }
        }
        void AddSection(string text) { var label = new Label(text); label.AddToClassList("inventory-section"); rows.Add(label); }
        static string Text(string zh, string en, string ja) => UiLocalization.LocaleCode == "en" ? en : UiLocalization.LocaleCode == "ja" ? ja : zh;
        public void Show() { UpdatePanelHeight(); panel.style.display = DisplayStyle.Flex; }
        public void Hide() => panel.style.display = DisplayStyle.None;
        public void Dispose() { UiLocalization.Changed -= RefreshStrings; owner.UnregisterCallback<GeometryChangedEvent>(OnOwnerGeometryChanged); panel.RemoveFromHierarchy(); }
    }
}
