using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    public sealed class PlayerScreen : MonoBehaviour
    {
        sealed class Message { public string id, role, text; }
        readonly List<Message> messages = new();
        readonly Dictionary<string, int> indices = new();
        IPlayerBackend backend;
        ListView list;
        TextField draft;
        Label status, track, artist, lyric, translation, time;
        Button play, send, cancel, newMessages;
        Slider seek, volume;
        string pending;
        double duration;
        bool follow = true, dirty;
        AudioSculpture sculpture;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Boot()
        {
            if (FindAnyObjectByType<PlayerScreen>() != null) return;
            var obj = new GameObject("GMGN Player");
            var document = obj.AddComponent<UIDocument>();
            document.panelSettings = Resources.Load<PanelSettings>("PlayerPanel");
            document.visualTreeAsset = Resources.Load<VisualTreeAsset>("Player");
            obj.AddComponent<PlayerScreen>();
        }

        void Start()
        {
            var root = GetComponent<UIDocument>().rootVisualElement;
            root.AddToClassList("document-root");
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            root.schedule.Execute(() => Debug.Log($"GMGN layout root={root.layout} shell={root.Q(className: "shell").layout} body={root.Q(className: "body").layout} player={root.Q(className: "player").layout} chat={root.Q(className: "chat-column").layout}")).StartingIn(250);
            status = root.Q<Label>("status"); track = root.Q<Label>("track"); artist = root.Q<Label>("artist");
            lyric = root.Q<Label>("lyric"); translation = root.Q<Label>("translation"); time = root.Q<Label>("time");
            draft = root.Q<TextField>("draft"); draft.textEdition.placeholder = "和角色聊聊…";
            send = root.Q<Button>("send"); cancel = root.Q<Button>("cancel"); play = root.Q<Button>("play");
            seek = root.Q<Slider>("seek"); volume = root.Q<Slider>("volume");
            list = root.Q<ListView>("messages"); newMessages = root.Q<Button>("newMessages");
            list.itemsSource = messages;
            list.makeItem = () => { var box = new VisualElement(); box.AddToClassList("message");
                var role = new Label(); role.AddToClassList("message-role"); box.Add(role);
                var body = new Label { enableRichText = false }; body.AddToClassList("message-text");
                body.selection.isSelectable = true; box.Add(body); return box; };
            list.bindItem = (row, i) => { ((Label)row[0]).text = messages[i].role; ((Label)row[1]).text = messages[i].text; };
            var chatScroll = list.Q<ScrollView>();
            chatScroll.verticalScroller.valueChanged += value => {
                follow = value >= chatScroll.verticalScroller.highValue - 36;
                if (follow) newMessages.AddToClassList("hidden");
            };
            newMessages.clicked += () => { follow = true; list.ScrollToItem(-1); newMessages.AddToClassList("hidden"); };
            send.clicked += Send;
            cancel.clicked += () => { if (pending != null) backend?.Cancel(pending); };
            draft.RegisterCallback<KeyDownEvent>(e => {
                if ((e.keyCode != KeyCode.Return && e.keyCode != KeyCode.KeypadEnter) || e.shiftKey) return;
                if (!string.IsNullOrEmpty(Input.compositionString)) return;
                e.StopImmediatePropagation(); e.PreventDefault(); Send();
            }, TrickleDown.TrickleDown);
            play.clicked += () => backend?.PlayPause(); root.Q<Button>("next").clicked += () => backend?.Next();
            root.Q<Button>("chooseMusic").clicked += () => backend?.ChooseMusic();
            seek.RegisterValueChangedCallback(e => backend?.Seek(e.newValue));
            volume.RegisterValueChangedCallback(e => backend?.SetVolume(e.newValue));
            sculpture = gameObject.AddComponent<AudioSculpture>();
            try { backend = PlayerBackend.Create?.Invoke(); }
            catch (Exception error) { status.text = "音乐与对话服务连接失败：" + error.Message; status.AddToClassList("status-error"); SetConnected(false); return; }
            if (backend == null) { status.text = "音乐与对话服务未连接"; SetConnected(false); return; }
            backend.Snapshot += OnSnapshot; backend.Chat += OnChat; backend.Status += OnStatus;
            SetConnected(true); status.text = "音乐与角色已连接"; cancel.SetEnabled(false);
        }
        void SetConnected(bool ready) { play.SetEnabled(ready); send.SetEnabled(ready); seek.SetEnabled(false); volume.SetEnabled(ready); var root = GetComponent<UIDocument>().rootVisualElement; root.Q<Button>("next").SetEnabled(false); root.Q<Button>("chooseMusic").SetEnabled(ready); }
        void OnStatus(string value) => status.text = value;
        void OnSnapshot(PlayerSnapshot snapshot)
        {
            track.text = string.IsNullOrEmpty(snapshot.title) ? "尚未播放" : snapshot.title;
            artist.text = snapshot.artist ?? ""; lyric.text = snapshot.lyric ?? ""; translation.text = snapshot.translation ?? "";
            duration = snapshot.duration; seek.highValue = (float)Math.Max(1, duration);
            seek.SetEnabled(snapshot.seekSupported);
            GetComponent<UIDocument>().rootVisualElement.Q<Button>("next").SetEnabled(snapshot.nextSupported);
            seek.tooltip = snapshot.seekSupported ? "跳转播放位置" : "当前样板尚未支持跳转";
            seek.SetValueWithoutNotify((float)snapshot.position); volume.SetValueWithoutNotify(snapshot.volume);
            play.text = snapshot.playing ? "暂停" : "播放";
            time.text = Format(snapshot.position) + " / " + Format(duration);
            sculpture.SetFeatures(snapshot.playing, snapshot.bass, snapshot.vocal, snapshot.treble);
        }
        static string Format(double seconds) { var span = TimeSpan.FromSeconds(Math.Max(0, seconds)); return $"{(int)span.TotalMinutes}:{span.Seconds:00}"; }
        void Send()
        {
            if (backend == null || pending != null || string.IsNullOrWhiteSpace(draft.value)) return;
            pending = Guid.NewGuid().ToString("N"); var text = draft.value.Trim();
            messages.Add(new Message { role = "你", text = text });
            GetComponent<UIDocument>().rootVisualElement.Q<Label>("emptyChat").AddToClassList("hidden");
            indices[pending] = messages.Count; messages.Add(new Message { id = pending, role = "角色", text = "正在回复…" });
            dirty = true; draft.SetValueWithoutNotify(""); send.SetEnabled(false); cancel.SetEnabled(true);
            backend.Send(pending, text);
        }
        void OnChat(ChatUpdate update)
        {
            if (!indices.TryGetValue(update.messageId, out var index)) return;
            messages[index].text = string.IsNullOrEmpty(update.error) ? update.text : "回复未完成：" + update.error;
            dirty = true;
            if (update.complete && pending == update.messageId) { pending = null; send.SetEnabled(true); cancel.SetEnabled(false); }
        }
        void Update()
        {
            backend?.Tick();
            if (!dirty) return;
            dirty = false; list.RefreshItems();
            if (follow) list.schedule.Execute(() => list.ScrollToItem(-1)); else newMessages.RemoveFromClassList("hidden");
        }
        void OnDestroy() { if (backend == null) return; backend.Snapshot -= OnSnapshot; backend.Chat -= OnChat; backend.Status -= OnStatus; backend.Dispose(); }
    }
}
