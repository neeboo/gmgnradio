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
        sealed class Message { public string id, role, text, requestText; public bool failed; }
        readonly List<Message> messages = new();
        readonly Dictionary<string, int> indices = new();
        IPlayerBackend backend;
        ListView list;
        TextField draft;
        Label status, lyric, translation;
        Button play, send, cancel, newMessages;
        Slider volume;
        string pending;
        double duration;
        bool follow = true, dirty, refreshing;
        ScrollView chatScroll;
        IVisualElementScheduledItem followScroll;
        AudioSculpture sculpture;
        VisualElement root, chatPanel;
        ToolbarIcon playIcon;
        bool connected;
        Keyboard keyboard;
        string composition = "";
        QueuePanel queuePanel;
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
            status = root.Q<Label>("status");
            lyric = root.Q<Label>("lyric"); translation = root.Q<Label>("translation");
            draft = root.Q<TextField>("draft"); draft.textEdition.placeholder = "和角色聊聊…";
            BindKeyboard();
            send = root.Q<Button>("send"); cancel = root.Q<Button>("cancel"); play = root.Q<Button>("play");
            chatPanel = root.Q("chatPanel");
            root.Q<Button>("chatToggle").clicked += () => ToggleChat(chatPanel.ClassListContains("hidden"));
            root.Q<Button>("closeChat").clicked += () => ToggleChat(false);
            root.Q<Button>("fullscreen").clicked += NativeUIScale.ToggleFullscreen;
            AddIcon("chooseMusic", "music"); AddIcon("previous", "previous");
            playIcon = AddIcon("play", "play"); AddIcon("next", "next");
            AddIcon("microphone", "microphone"); AddIcon("chatToggle", "chat");
            AddIcon("inbox", "mail"); AddIcon("props", "box"); AddIcon("screen", "screen");
            AddIcon("settings", "settings"); AddIcon("fullscreen", "fullscreen");
            AddIcon("mode", "screen"); AddIcon("closeChat", "close");
            AddIcon("send", "send"); AddIcon("cancel", "stop");
            volume = root.Q<Slider>("volume");
            list = root.Q<ListView>("messages"); newMessages = root.Q<Button>("newMessages");
            list.itemsSource = messages;
            list.makeItem = () => { var box = new VisualElement(); box.AddToClassList("message");
                var role = new Label(); role.AddToClassList("message-role"); box.Add(role);
                var body = new Label { enableRichText = false }; body.AddToClassList("message-text");
                body.selection.isSelectable = true; box.Add(body);
                var retry = new Button { text = "重新编辑并发送" }; retry.AddToClassList("retry-message");
                retry.clicked += () => { if (retry.userData is Message message) RestoreDraft(message); };
                box.Add(retry); return box; };
            list.bindItem = (row, i) => { var message = messages[i]; ((Label)row[0]).text = message.role; ((Label)row[1]).text = message.text;
                row.EnableInClassList("message-error", message.failed);
                var retry = (Button)row[2]; retry.userData = message; retry.EnableInClassList("hidden", !message.failed); };
            chatScroll = list.Q<ScrollView>();
            chatScroll.verticalScroller.valueChanged += value => {
                if (refreshing) return;
                follow = value >= chatScroll.verticalScroller.highValue - 36;
                if (follow) newMessages.AddToClassList("hidden");
            };
            newMessages.clicked += () => { follow = true; ScrollToLatest(); };
            send.clicked += Send;
            draft.RegisterValueChangedCallback(_ => UpdateComposer());
            cancel.clicked += () => { if (pending == null) return;
                try { backend?.Cancel(pending); }
                catch (Exception) { status.text = "暂时无法停止回复，请稍后重试。"; } };
            draft.RegisterCallback<KeyDownEvent>(e => {
                if ((e.keyCode != KeyCode.Return && e.keyCode != KeyCode.KeypadEnter) || e.shiftKey) return;
                if (composition.Length > 0 || Time.frameCount <= compositionEndedFrame + 1) return;
                e.StopImmediatePropagation(); e.PreventDefault(); Send();
            }, TrickleDown.TrickleDown);
            play.clicked += () => backend?.PlayPause(); root.Q<Button>("next").clicked += () => backend?.Next();
            root.Q<Button>("previous").clicked += () => backend?.Previous();
            root.Q<Button>("chooseMusic").clicked += () => { ToggleChat(false); queuePanel?.Toggle(); };
            volume.RegisterValueChangedCallback(e => backend?.SetVolume(e.newValue));
            sculpture = gameObject.AddComponent<AudioSculpture>();
            try { backend = PlayerBackend.Create?.Invoke(); }
            catch (Exception error) { status.text = "音乐与对话服务连接失败：" + error.Message; status.AddToClassList("status-error"); SetConnected(false); return; }
            if (backend == null) { status.text = "音乐与对话服务未连接"; SetConnected(false); return; }
            backend.Snapshot += OnSnapshot; backend.Chat += OnChat; backend.Status += OnStatus;
            queuePanel = QueuePanel.Attach(root.Q(className: "body"), backend);
            if (backend is NativePlayerBackend native) {
                var world = gameObject.AddComponent<WorldRuntimeBridge>();
                world.Initialize(native, sculpture);
                world.Status += OnStatus;
                var mode = root.Q<Button>("mode");
                mode.SetEnabled(world.Configured);
                mode.tooltip = world.Configured ? "切换播放器与空间" : "尚未指定空间备份";
                Debug.Log($"World mode initialized: configured={world.Configured}; enabled={mode.enabledInHierarchy}");
                mode.RegisterCallback<PointerDownEvent>(e => Debug.Log($"World mode pointer down: button={e.button}; position={e.position}; enabled={mode.enabledInHierarchy}"), TrickleDown.TrickleDown);
                mode.RegisterCallback<PointerUpEvent>(e => Debug.Log($"World mode pointer up: button={e.button}; position={e.position}"), TrickleDown.TrickleDown);
                mode.RegisterCallback<GeometryChangedEvent>(_ => Debug.Log($"World mode bounds: {mode.worldBound}; panelScale={GetComponent<UIDocument>().panelSettings.scale}"));
                mode.clicked += () => { Debug.Log("World mode clicked"); world.Toggle(); };
                root.RegisterCallback<PointerDownEvent>(e => Debug.Log($"UI pointer down: target={(e.target as VisualElement)?.name}; position={e.position}; button={e.button}"), TrickleDown.TrickleDown);
                world.ModeChanged += visible => {
                    // Preserve the vector icon created above; change only its label.
                    var label = mode.Q<Label>(); if (label != null) label.text = visible ? "空间" : "播放器";
                };
                if (Environment.GetEnvironmentVariable("GMGN_UNITY_OPEN_SPACE") == "1")
                    root.schedule.Execute(() => { Debug.Log("World explicit startup requested; not a click acceptance"); world.Toggle(); });
            }
            SetConnected(true); status.text = "音乐与角色已连接";
        }
        void SetConnected(bool ready) { connected = ready; play.SetEnabled(ready); volume.SetEnabled(ready); root.Q<Button>("next").SetEnabled(false); root.Q<Button>("previous").SetEnabled(false); root.Q<Button>("chooseMusic").SetEnabled(ready); UpdateComposer(); }
        void ToggleChat(bool visible) { if (visible) queuePanel?.SetVisible(false); chatPanel.EnableInClassList("hidden", !visible); root.Q<Button>("chatToggle").EnableInClassList("selected", visible); if (visible) { draft.Focus(); if (follow) ScrollToLatest(); } }
        void UpdateComposer() { send.SetEnabled(connected && pending == null && !string.IsNullOrWhiteSpace(draft.value)); send.EnableInClassList("hidden", pending != null); cancel.EnableInClassList("hidden", pending == null); cancel.SetEnabled(connected && pending != null); }
        void OnStatus(string value) => status.text = value;
        void OnSnapshot(PlayerSnapshot snapshot)
        {
            lyric.text = snapshot.lyric ?? ""; translation.text = snapshot.translation ?? "";
            duration = snapshot.duration;
            GetComponent<UIDocument>().rootVisualElement.Q<Button>("next").SetEnabled(snapshot.nextSupported);
            root.Q<Button>("previous").SetEnabled(snapshot.previousSupported);
            root.Q<Button>("previous").tooltip = snapshot.previousSupported ? "上一首" : "当前队列没有上一首";
            root.Q<Button>("next").tooltip = snapshot.nextSupported ? "下一首" : "当前队列没有下一首";
            volume.SetValueWithoutNotify(snapshot.volume);
            play.tooltip = snapshot.playing ? "暂停" : "播放";
            playIcon.Kind = snapshot.playing ? "pause" : "play";
            sculpture.SetFeatures(snapshot.playing, snapshot.bass, snapshot.vocal, snapshot.treble);
        }
        static string Format(double seconds) { var span = TimeSpan.FromSeconds(Math.Max(0, seconds)); return $"{(int)span.TotalMinutes}:{span.Seconds:00}"; }
        void Send()
        {
            if (backend == null || pending != null || string.IsNullOrWhiteSpace(draft.value)) return;
            pending = Guid.NewGuid().ToString("N"); var text = draft.value.Trim();
            messages.Add(new Message { role = "你", text = text });
            GetComponent<UIDocument>().rootVisualElement.Q<Label>("emptyChat").AddToClassList("hidden");
            indices[pending] = messages.Count; messages.Add(new Message { id = pending, role = "角色", text = "正在回复…", requestText = text });
            dirty = true; draft.SetValueWithoutNotify(""); UpdateComposer();
            try { backend.Send(pending, text); }
            catch (Exception) { OnChat(new ChatUpdate { messageId = pending, error = "消息未发送，请重试。", complete = true }); }
        }
        void OnChat(ChatUpdate update)
        {
            if (!indices.TryGetValue(update.messageId, out var index)) return;
            var message = messages[index];
            message.failed = !string.IsNullOrEmpty(update.error);
            var text = message.failed ? "回复未完成：" + update.error : update.text;
            if (message.text == text && !update.complete) return;
            message.text = text;
            dirty = true;
            if (update.complete && pending == update.messageId) { pending = null; UpdateComposer(); }
        }
        void Update()
        {
            BindKeyboard();
            backend?.Tick();
            if (!dirty) return;
            dirty = false;
            var offset = chatScroll.scrollOffset;
            refreshing = true; list.RefreshItems();
            if (follow) ScrollToLatest(); else { chatScroll.scrollOffset = offset; newMessages.RemoveFromClassList("hidden"); }
            refreshing = false;
        }
        void ScrollToLatest()
        {
            newMessages.AddToClassList("hidden");
            followScroll?.Pause();
            followScroll = list.schedule.Execute(() => { if (!follow || chatPanel.ClassListContains("hidden")) return;
                refreshing = true; list.ScrollToItem(-1); refreshing = false; });
        }
        void RestoreDraft(Message message)
        {
            if (!string.IsNullOrWhiteSpace(draft.value)) { status.text = "输入框里还有内容，请先发送或清空，再重新编辑这条消息。"; return; }
            draft.value = message.requestText ?? ""; draft.Focus();
        }
        void BindKeyboard() { if (keyboard == Keyboard.current) return; if (keyboard != null) keyboard.onIMECompositionChange -= OnComposition; keyboard = Keyboard.current; if (keyboard != null) keyboard.onIMECompositionChange += OnComposition; }
        void OnComposition(IMECompositionString value) { var next = value.ToString(); if (composition.Length > 0 && next.Length == 0) compositionEndedFrame = Time.frameCount; composition = next; }
        void OnDestroy() { followScroll?.Pause(); queuePanel?.Dispose(); if (keyboard != null) keyboard.onIMECompositionChange -= OnComposition; if (backend == null) return; backend.Snapshot -= OnSnapshot; backend.Chat -= OnChat; backend.Status -= OnStatus; backend.Dispose(); }

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
