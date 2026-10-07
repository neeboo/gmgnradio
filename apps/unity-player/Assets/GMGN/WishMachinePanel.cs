using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    /// Explicit operations only. Opening a device/catalog never submits a
    /// generation, claims an output, or fabricates resident arrival evidence.
    public sealed class WishMachinePanel : IDisposable
    {
        readonly Func<JObject, bool> request;
        readonly Action openChat;
        readonly List<JObject> entries = new();
        readonly Label title, notice;
        readonly Button refresh, create, close;
        readonly ListView list;
        bool pending;
        string noticeKey = "wishEmpty";
        public VisualElement Element { get; }

        public WishMachinePanel(VisualElement parent, Func<JObject, bool> request, Action openChat)
        {
            this.request = request; this.openChat = openChat;
            Element = new VisualElement { name = "wishMachinePanel" };
            Element.AddToClassList("card"); Element.AddToClassList("wish-panel"); Element.AddToClassList("hidden");
            var header = new VisualElement(); header.AddToClassList("wish-header");
            title = new Label { enableRichText = false }; title.AddToClassList("wish-title"); header.Add(title);
            refresh = HeaderButton("wishRefresh", "refresh", () => Send("wish.status")); header.Add(refresh);
            close = HeaderButton("wishClose", "close", Hide); header.Add(close); Element.Add(header);
            notice = new Label { enableRichText = false }; notice.AddToClassList("wish-notice"); Element.Add(notice);
            list = new ListView { itemsSource = entries, fixedItemHeight = 74,
                virtualizationMethod = CollectionVirtualizationMethod.FixedHeight, selectionType = SelectionType.None };
            list.AddToClassList("wish-list");
            var scroll = list.Q<ScrollView>();
            scroll.mode = ScrollViewMode.Vertical;
            scroll.horizontalScrollerVisibility = ScrollerVisibility.Hidden;
            scroll.verticalScrollerVisibility = ScrollerVisibility.Auto;
            scroll.contentViewport.RegisterCallback<GeometryChangedEvent>(e => {
                scroll.contentContainer.style.width = e.newRect.width;
            });
            list.makeItem = () => {
                var row = new VisualElement(); row.AddToClassList("wish-row");
                var info = new VisualElement(); info.AddToClassList("wish-info");
                var name = new Label { name = "wishName", enableRichText = false }; name.AddToClassList("wish-name"); info.Add(name);
                var stage = new Label { name = "wishStage", enableRichText = false }; stage.AddToClassList("wish-stage"); info.Add(stage); row.Add(info);
                var action = new Button { name = "wishAction" };
                action.AddToClassList("wish-action");
                action.Add(new PlayerScreen.ToolbarIcon("box"));
                action.clicked += () => {
                    if (action.userData is JObject entry) Send((string)entry["stage"] == "claimed" ? "wish.inventory.retry" : "wish.claim", (string)entry["wishID"]);
                };
                row.Add(action); return row;
            };
            list.bindItem = (row, index) => {
                var entry = entries[index];
                row.Q<Label>("wishName").text = (string)entry["name"];
                row.Q<Label>("wishName").tooltip = (string)entry["name"];
                var registered = (bool?)entry["inventoryRegistered"] == true;
                var stage = (string)entry["stage"];
                row.Q<Label>("wishStage").text = UiLocalization.Get(registered ? "wishInInventory" : "wishStage_" + stage);
                var action = row.Q<Button>("wishAction"); action.userData = entry;
                action.tooltip = UiLocalization.Get(stage == "claimed" ? "wishRetryInventory" : "wishClaim");
                action.style.display = registered || (stage != "claimed" && stage != "ready") ? DisplayStyle.None : DisplayStyle.Flex;
                action.SetEnabled(!pending && (stage == "claimed" || (bool?)entry["claimAvailable"] == true));
            };
            Element.Add(list);
            var footer = new VisualElement(); footer.AddToClassList("wish-footer");
            create = new Button(() => { Hide(); this.openChat?.Invoke(); }); create.AddToClassList("wish-create");
            create.Add(new PlayerScreen.ToolbarIcon("chat"));
            create.Add(new Label { name = "wishCreateLabel", enableRichText = false });
            footer.Add(create); Element.Add(footer);
            var toolbar = parent.Q(className: "player");
            if (toolbar?.parent != null) toolbar.parent.Insert(toolbar.parent.IndexOf(toolbar), Element); else parent.Add(Element);
            UiLocalization.Changed += RefreshLocale; RefreshLocale();
        }
        static Button HeaderButton(string name, string icon, Action clicked)
        {
            var button = new Button(clicked) { name = name };
            button.AddToClassList("icon-button"); button.Add(new PlayerScreen.ToolbarIcon(icon));
            return button;
        }
        public void Show() { Element.RemoveFromClassList("hidden"); Send("wish.status"); }
        public void Hide() { Element.AddToClassList("hidden"); }
        public void Update(JObject value)
        {
            if (value?["status"] == null) return;
            pending = false;
            if (value["entries"] is JArray items) { entries.Clear(); foreach (var item in items) if (item is JObject entry) entries.Add(entry); }
            noticeKey = (string)value["status"] == "failed" ? "wishFailed" : entries.Count == 0 ? "wishEmpty" : "wishUpdated";
            RefreshLocale();
        }
        void Send(string operation, string wishID = null)
        {
            if (pending) return;
            var payload = new JObject { ["op"] = operation, ["requestID"] = "unity-wish:" + Guid.NewGuid().ToString("D") };
            if (wishID != null) payload["wishID"] = wishID;
            pending = request?.Invoke(payload) == true;
            noticeKey = pending ? "wishWorking" : "wishFailed"; RefreshLocale();
        }
        void RefreshLocale()
        {
            title.text = UiLocalization.Get("wishTitle"); refresh.tooltip = UiLocalization.Get("wishRefresh");
            close.tooltip = UiLocalization.Get("wishClose"); create.Q<Label>("wishCreateLabel").text = UiLocalization.Get("wishCreateInChat");
            notice.EnableInClassList("hidden", noticeKey == "wishUpdated");
            notice.text = UiLocalization.Get(noticeKey); refresh.SetEnabled(!pending); list.RefreshItems();
        }
        public void Dispose() { UiLocalization.Changed -= RefreshLocale; Element.RemoveFromHierarchy(); }
    }
}
