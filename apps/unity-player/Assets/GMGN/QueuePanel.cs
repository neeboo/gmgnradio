using System;
using System.Collections.Generic;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    public sealed class QueuePanel : IDisposable
    {
        readonly IPlayerBackend backend;
        readonly List<QueueItem> items = new();
        readonly Label heading, empty;
        readonly ListView list;
        int currentIndex = -1;
        public VisualElement Element { get; }
        public bool Visible => !Element.ClassListContains("hidden");

        public static QueuePanel Attach(VisualElement parent, IPlayerBackend backend)
        {
            var panel = new QueuePanel(backend);
            var controls = parent.Q(className: "player");
            if (controls != null && controls.parent == parent) parent.Insert(parent.IndexOf(controls), panel.Element);
            else parent.Add(panel.Element);
            return panel;
        }

        QueuePanel(IPlayerBackend backend)
        {
            this.backend = backend ?? throw new ArgumentNullException(nameof(backend));
            Element = new VisualElement { name = "queuePanel" };
            Element.AddToClassList("card");
            Element.AddToClassList("chat-column");
            Element.AddToClassList("hidden");
            var header = new VisualElement(); header.AddToClassList("row"); header.AddToClassList("chat-header");
            heading = new Label("播放队列"); heading.AddToClassList("subtitle"); header.Add(heading);
            var close = new Button(() => SetVisible(false)) { text = "关闭", tooltip = "收起播放队列" }; header.Add(close);
            Element.Add(header);
            empty = new Label("还没有音乐。选择本地音乐，可一次添加多首。");
            empty.AddToClassList("empty-chat"); empty.AddToClassList("muted"); Element.Add(empty);
            list = new ListView { itemsSource = items, fixedItemHeight = 44, selectionType = SelectionType.None };
            list.AddToClassList("messages");
            list.makeItem = () => {
                var row = new Button(); row.style.height = 40; row.style.marginBottom = 4;
                row.style.unityTextAlign = UnityEngine.TextAnchor.MiddleLeft;
                row.clicked += () => { if (row.userData is int index) backend.SelectQueueItem(index); };
                return row;
            };
            list.bindItem = (element, index) => {
                var row = (Button)element; var item = items[index]; row.userData = item.index;
                row.text = (item.index == currentIndex ? "当前歌曲 · " : "") + item.title;
                row.tooltip = item.title; row.EnableInClassList("selected", item.index == currentIndex);
            };
            Element.Add(list);
            Element.Add(new Button(backend.ChooseMusic) { text = "选择本地音乐…", tooltip = "多选音频文件，替换当前播放队列" });
            backend.Snapshot += Update;
        }

        public void SetVisible(bool visible) => Element.EnableInClassList("hidden", !visible);
        public void Toggle() => SetVisible(!Visible);

        public void Update(PlayerSnapshot snapshot)
        {
            var queue = snapshot.queue ?? Array.Empty<QueueItem>();
            bool changed = items.Count != queue.Length || currentIndex != snapshot.queueIndex;
            if (!changed) for (int i = 0; i < queue.Length; i++) {
                if (items[i].index != queue[i].index || items[i].title != queue[i].title) { changed = true; break; }
            }
            if (!changed) return;
            currentIndex = snapshot.queueIndex;
            items.Clear(); items.AddRange(queue);
            heading.text = items.Count == 0 ? "播放队列" : $"播放队列 · {items.Count}";
            empty.EnableInClassList("hidden", items.Count > 0);
            list.RefreshItems();
        }

        public void Dispose()
        {
            backend.Snapshot -= Update;
            Element.RemoveFromHierarchy();
        }
    }
}
