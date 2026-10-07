using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    /// Merely opening the panel does not read notifications. A deliberate row
    /// click opens the exact event and requests its durable human-read state.
    public sealed class InboxPanel : IDisposable
    {
        readonly NativePlayerBackend backend;
        readonly List<JObject> entries = new();
        readonly Label title, status, detailTitle, detailText;
        readonly Button refresh, close, back;
        readonly ListView list;
        readonly VisualElement detail;
        string selectedTask, statusKey = "inboxEmpty";
        bool pending;
        public VisualElement Element { get; }
        public int UnreadCount { get; private set; }
        public event Action<int> UnreadChanged;
        string Text(string key) => UiLocalization.Get(key);
        void SetStatus(string key) { statusKey = key; status.text = Text(key); }
        public InboxPanel(VisualElement parent, NativePlayerBackend backend)
        {
            this.backend = backend;
            Element = new VisualElement { name = "inboxPanel" };
            Element.AddToClassList("card"); Element.AddToClassList("inbox-panel"); Element.AddToClassList("hidden");
            var sheet = Resources.Load<StyleSheet>("Inbox"); if (sheet != null) Element.styleSheets.Add(sheet);
            var header = new VisualElement(); header.AddToClassList("inbox-header");
            back = HeaderButton("back", () => ShowDetail(null)); back.AddToClassList("hidden"); header.Add(back);
            title = new Label { enableRichText = false }; title.AddToClassList("inbox-title"); header.Add(title);
            refresh = HeaderButton("refresh", Refresh); header.Add(refresh);
            close = HeaderButton("close", Hide); header.Add(close); Element.Add(header);
            status = new Label { enableRichText = false }; status.AddToClassList("inbox-status"); Element.Add(status);
            list = new ListView { itemsSource = entries, fixedItemHeight = 76,
                virtualizationMethod = CollectionVirtualizationMethod.FixedHeight, selectionType = SelectionType.None };
            list.AddToClassList("inbox-list");
            list.makeItem = () => {
                var row = new Button(); row.AddToClassList("inbox-row");
                var info = new VisualElement(); info.AddToClassList("inbox-info");
                var name = new Label { name = "title", enableRichText = false }; name.AddToClassList("inbox-row-title"); info.Add(name);
                var state = new Label { name = "state", enableRichText = false }; state.AddToClassList("inbox-secondary"); info.Add(state); row.Add(info);
                var read = new Label { name = "read", enableRichText = false }; read.AddToClassList("inbox-read"); row.Add(read);
                row.clicked += () => { if (row.userData is JObject entry) Open(entry); };
                return row;
            };
            list.bindItem = (element, index) => {
                var entry = entries[index]; element.userData = entry;
                element.Q<Label>("title").text = (string)entry["title"];
                element.Q<Label>("state").text = (string)entry["status"];
                var unread = (bool?)entry["isRead"] != true;
                element.Q<Label>("read").text = Text(unread ? "inboxUnread" : "inboxRead");
                element.EnableInClassList("inbox-unread", unread);
            };
            Element.Add(list);
            var detailScroll = new ScrollView(ScrollViewMode.Vertical) {
                horizontalScrollerVisibility = ScrollerVisibility.Hidden,
                verticalScrollerVisibility = ScrollerVisibility.Auto
            };
            detail = detailScroll; detail.AddToClassList("inbox-detail"); detail.AddToClassList("hidden");
            detailTitle = new Label { enableRichText = false }; detailTitle.AddToClassList("inbox-detail-title"); detail.Add(detailTitle);
            detailText = new Label { enableRichText = false }; detailText.AddToClassList("inbox-detail-text"); detail.Add(detailText); Element.Add(detail);
            var toolbar = parent.Q(className: "player");
            if (toolbar?.parent != null) toolbar.parent.Insert(toolbar.parent.IndexOf(toolbar), Element); else parent.Add(Element);
            backend.InboxUpdated += Update;
            UiLocalization.Changed += RefreshLocale;
            RefreshLocale();
        }
        public void SetLocale(string value) => RefreshLocale();
        static Button HeaderButton(string icon, Action clicked)
        {
            var button = new Button(clicked);
            button.AddToClassList("icon-button");
            button.style.width = 32; button.style.height = 32; button.style.flexShrink = 0;
            button.style.paddingLeft = 4; button.style.paddingRight = 4;
            button.Add(new PlayerScreen.ToolbarIcon(icon));
            return button;
        }
        void RefreshLocale()
        {
            title.text = Text("inboxTitle"); refresh.tooltip = Text("inboxRefresh");
            close.tooltip = Text("inboxClose"); back.tooltip = Text("inboxBack"); list.RefreshItems();
            status.text = Text(statusKey);
        }
        public void Show() { Element.RemoveFromClassList("hidden"); Refresh(); }
        public void Hide() { Element.AddToClassList("hidden"); }
        void Refresh()
        {
            if (pending) return;
            SetStatus("inboxLoading"); pending = backend.RequestInbox();
            if (!pending) SetStatus("inboxNotConnected");
            refresh.SetEnabled(!pending);
        }
        void Open(JObject entry)
        {
            if (pending) return;
            ShowDetail(entry);
            if ((bool?)entry["isRead"] == true) return;
            pending = backend.MarkInboxRead((string)entry["taskKey"], (string)entry["lastEventID"]);
            SetStatus(pending ? "inboxReading" : "inboxReadError"); refresh.SetEnabled(!pending);
        }
        void ShowDetail(JObject entry)
        {
            selectedTask = (string)entry?["taskKey"];
            list.EnableInClassList("hidden", entry != null); detail.EnableInClassList("hidden", entry == null);
            back.EnableInClassList("hidden", entry == null);
            if (entry == null) return;
            detailTitle.text = (string)entry["title"]; detailText.text = (string)entry["detail"];
        }
        void Update(JObject update)
        {
            if (update["status"] == null) return; // Compact pending pulse never clears content.
            pending = false; refresh.SetEnabled(true);
            if (update["entries"] is JArray authoritative) {
                entries.Clear(); foreach (var entry in authoritative) if (entry is JObject item) entries.Add(item);
                list.RefreshItems();
                UnreadCount = (int?)update["unreadCount"] ?? entries.FindAll(e => (bool?)e["isRead"] != true).Count;
                UnreadChanged?.Invoke(UnreadCount);
            }
            if ((string)update["status"] == "failed") { SetStatus("inboxReadError"); return; }
            SetStatus(entries.Count == 0 ? "inboxEmpty" : "inboxUpdated");
            if (selectedTask != null) ShowDetail(entries.Find(e => (string)e["taskKey"] == selectedTask));
        }
        public void Dispose() { backend.InboxUpdated -= Update; UiLocalization.Changed -= RefreshLocale; Element.RemoveFromHierarchy(); }
    }
}
