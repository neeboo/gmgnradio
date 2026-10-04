using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;
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
        VisualElement root, chatPanel;
        ToolbarIcon playIcon;
        bool connected;
        Keyboard keyboard;
        string composition = "";
        int compositionEndedFrame = -10;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Boot()
        {
            Application.runInBackground = true;
            if (FindAnyObjectByType<PlayerScreen>() != null) return;
            var obj = new GameObject("GMGN Player");
            var document = obj.AddComponent<UIDocument>();
            document.panelSettings = Resources.Load<PanelSettings>("PlayerPanel");
            document.visualTreeAsset = Resources.Load<VisualTreeAsset>("Player");
            obj.AddComponent<PlayerScreen>();
        }

        void Start()
        {
            root = GetComponent<UIDocument>().rootVisualElement;
            root.AddToClassList("document-root");
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            root.RegisterCallback<GeometryChangedEvent>(e => root.EnableInClassList("compact", e.newRect.width < 780 || e.newRect.height < 600));
            status = root.Q<Label>("status"); track = root.Q<Label>("track"); artist = root.Q<Label>("artist");
            lyric = root.Q<Label>("lyric"); translation = root.Q<Label>("translation"); time = root.Q<Label>("time");
            draft = root.Q<TextField>("draft"); draft.textEdition.placeholder = "和角色聊聊…";
            BindKeyboard();
            send = root.Q<Button>("send"); cancel = root.Q<Button>("cancel"); play = root.Q<Button>("play");
            chatPanel = root.Q("chatPanel");
            root.Q<Button>("chatToggle").clicked += () => ToggleChat(chatPanel.ClassListContains("hidden"));
            root.Q<Button>("closeChat").clicked += () => ToggleChat(false);
            root.Q<Button>("fullscreen").clicked += () => Screen.fullScreen = !Screen.fullScreen;
            AddIcon("chooseMusic", "music"); AddIcon("previous", "previous");
            playIcon = AddIcon("play", "play"); AddIcon("next", "next");
            AddIcon("microphone", "microphone"); AddIcon("chatToggle", "chat");
            AddIcon("inbox", "mail"); AddIcon("props", "box"); AddIcon("screen", "screen");
            AddIcon("settings", "settings"); AddIcon("fullscreen", "fullscreen");
            AddIcon("mode", "screen"); AddIcon("closeChat", "close");
            AddIcon("send", "send"); AddIcon("cancel", "stop");
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
            draft.RegisterValueChangedCallback(_ => UpdateComposer());
            cancel.clicked += () => { if (pending != null) backend?.Cancel(pending); };
            draft.RegisterCallback<KeyDownEvent>(e => {
                if ((e.keyCode != KeyCode.Return && e.keyCode != KeyCode.KeypadEnter) || e.shiftKey) return;
                if (composition.Length > 0 || Time.frameCount <= compositionEndedFrame + 1) return;
                e.StopImmediatePropagation(); e.PreventDefault(); Send();
            }, TrickleDown.TrickleDown);
            play.clicked += () => backend?.PlayPause(); root.Q<Button>("next").clicked += () => backend?.Next();
            root.Q<Button>("previous").clicked += () => backend?.Previous();
            root.Q<Button>("chooseMusic").clicked += () => backend?.ChooseMusic();
            seek.RegisterValueChangedCallback(e => backend?.Seek(e.newValue));
            volume.RegisterValueChangedCallback(e => backend?.SetVolume(e.newValue));
            sculpture = gameObject.AddComponent<AudioSculpture>();
            try { backend = PlayerBackend.Create?.Invoke(); }
            catch (Exception error) { status.text = "音乐与对话服务连接失败：" + error.Message; status.AddToClassList("status-error"); SetConnected(false); return; }
            if (backend == null) { status.text = "音乐与对话服务未连接"; SetConnected(false); return; }
            backend.Snapshot += OnSnapshot; backend.Chat += OnChat; backend.Status += OnStatus;
            SetConnected(true); status.text = "音乐与角色已连接";
        }
        void SetConnected(bool ready) { connected = ready; play.SetEnabled(ready); seek.SetEnabled(false); volume.SetEnabled(ready); root.Q<Button>("next").SetEnabled(false); root.Q<Button>("previous").SetEnabled(false); root.Q<Button>("chooseMusic").SetEnabled(ready); UpdateComposer(); }
        void ToggleChat(bool visible) { chatPanel.EnableInClassList("hidden", !visible); root.Q<Button>("chatToggle").EnableInClassList("selected", visible); if (visible) draft.Focus(); }
        void UpdateComposer() { send.SetEnabled(connected && pending == null && !string.IsNullOrWhiteSpace(draft.value)); send.EnableInClassList("hidden", pending != null); cancel.EnableInClassList("hidden", pending == null); cancel.SetEnabled(connected && pending != null); }
        void OnStatus(string value) => status.text = value;
        void OnSnapshot(PlayerSnapshot snapshot)
        {
            track.text = string.IsNullOrEmpty(snapshot.title) ? "尚未播放" : snapshot.title;
            artist.text = snapshot.artist ?? ""; lyric.text = snapshot.lyric ?? ""; translation.text = snapshot.translation ?? "";
            duration = snapshot.duration; seek.highValue = (float)Math.Max(1, duration);
            seek.SetEnabled(snapshot.seekSupported);
            GetComponent<UIDocument>().rootVisualElement.Q<Button>("next").SetEnabled(snapshot.nextSupported);
            root.Q<Button>("previous").SetEnabled(snapshot.previousSupported);
            root.Q<Button>("previous").tooltip = snapshot.previousSupported ? "上一首" : "当前队列没有上一首";
            root.Q<Button>("next").tooltip = snapshot.nextSupported ? "下一首" : "当前队列没有下一首";
            seek.tooltip = snapshot.seekSupported ? "跳转播放位置" : "当前样板尚未支持跳转";
            seek.SetValueWithoutNotify((float)snapshot.position); volume.SetValueWithoutNotify(snapshot.volume);
            play.tooltip = snapshot.playing ? "暂停" : "播放";
            playIcon.Kind = snapshot.playing ? "pause" : "play";
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
            dirty = true; draft.SetValueWithoutNotify(""); UpdateComposer();
            backend.Send(pending, text);
        }
        void OnChat(ChatUpdate update)
        {
            if (!indices.TryGetValue(update.messageId, out var index)) return;
            messages[index].text = string.IsNullOrEmpty(update.error) ? update.text : "回复未完成：" + update.error;
            dirty = true;
            if (update.complete && pending == update.messageId) { pending = null; UpdateComposer(); }
        }
        void Update()
        {
            BindKeyboard();
            backend?.Tick();
            if (!dirty) return;
            dirty = false; list.RefreshItems();
            if (follow) list.schedule.Execute(() => list.ScrollToItem(-1)); else newMessages.RemoveFromClassList("hidden");
        }
        void BindKeyboard() { if (keyboard == Keyboard.current) return; if (keyboard != null) keyboard.onIMECompositionChange -= OnComposition; keyboard = Keyboard.current; if (keyboard != null) keyboard.onIMECompositionChange += OnComposition; }
        void OnComposition(IMECompositionString value) { var next = value.ToString(); if (composition.Length > 0 && next.Length == 0) compositionEndedFrame = Time.frameCount; composition = next; }
        void OnDestroy() { if (keyboard != null) keyboard.onIMECompositionChange -= OnComposition; if (backend == null) return; backend.Snapshot -= OnSnapshot; backend.Chat -= OnChat; backend.Status -= OnStatus; backend.Dispose(); }

        ToolbarIcon AddIcon(string name, string kind)
        {
            var button = root.Q<Button>(name);
            var label = button.text;
            if (!string.IsNullOrEmpty(label)) button.text = "";
            var icon = new ToolbarIcon(kind);
            button.Insert(0, icon);
            if (!string.IsNullOrEmpty(label)) { var text = new Label(label); text.AddToClassList("button-label"); text.pickingMode = PickingMode.Ignore; button.Add(text); }
            return icon;
        }

        sealed class ToolbarIcon : VisualElement
        {
            string kind;
            public string Kind { set { if (kind == value) return; kind = value; MarkDirtyRepaint(); } }
            public ToolbarIcon(string value) { kind = value; pickingMode = PickingMode.Ignore; AddToClassList("toolbar-icon"); generateVisualContent += Draw; }
            void Draw(MeshGenerationContext ctx)
            {
                var p = ctx.painter2D;
                p.strokeColor = resolvedStyle.color; p.lineWidth = 1.6f;
                p.lineCap = LineCap.Round; p.lineJoin = LineJoin.Round;
                void Path(params float[] points) { p.BeginPath(); p.MoveTo(new Vector2(points[0], points[1])); for (int i = 2; i < points.Length; i += 2) p.LineTo(new Vector2(points[i], points[i + 1])); p.Stroke(); }
                switch (kind)
                {
                    case "play": Path(6,3,17,10,6,17,6,3); break;
                    case "pause": Path(6,3,6,17); Path(14,3,14,17); break;
                    case "next": Path(4,4,13,10,4,16,4,4); Path(16,4,16,16); break;
                    case "previous": Path(16,4,7,10,16,16,16,4); Path(4,4,4,16); break;
                    case "chat": Path(3,3,17,3,17,14,9,14,4,18,4,14,3,14,3,3); break;
                    case "mail": Path(2,4,18,4,18,16,2,16,2,4); Path(2,4,10,11,18,4); break;
                    case "screen": Path(2,3,18,3,18,14,2,14,2,3); Path(10,14,10,18); Path(6,18,14,18); break;
                    case "box": Path(10,2,18,6,18,14,10,18,2,14,2,6,10,2); Path(2,6,10,10,18,6); Path(10,10,10,18); Path(6,4,14,8); break;
                    case "music": Path(3,5,12,5); Path(3,9,12,9); Path(3,13,8,13); Path(15,3,15,15,11,15,11,18,15,18,15,15); break;
                    case "microphone": Path(7,3,13,3,13,11,7,11,7,3); Path(4,8,4,12,7,15,13,15,16,12,16,8); Path(10,15,10,18); break;
                    case "settings": Path(2,5,18,5); Path(2,10,18,10); Path(2,15,18,15); Path(6,3,6,7); Path(14,8,14,12); Path(8,13,8,17); break;
                    case "fullscreen": Path(2,7,2,2,7,2); Path(13,2,18,2,18,7); Path(18,13,18,18,13,18); Path(7,18,2,18,2,13); break;
                    case "send": Path(4,9,10,3,16,9); Path(10,3,10,17); break;
                    case "stop": Path(4,4,16,4,16,16,4,16,4,4); break;
                    case "close": Path(4,4,16,16); Path(16,4,4,16); break;
                }
            }
        }
    }
}
