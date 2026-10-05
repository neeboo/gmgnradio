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
        PointCloudArtworkLoader pointArtwork;
        GpuLyricsView gpuLyrics;
        string gpuLyricStatus;
        VisualElement root, chatPanel;
        ToolbarIcon playIcon;
        bool connected;
        Keyboard keyboard;
        string composition = "";
        QueuePanel queuePanel;
        MusicLibraryPanel musicLibraryPanel;
        int compositionEndedFrame = -10;
        string locale = "zh-CN";
        bool spaceVisible, spaceConfigured, lastPlaying, lastPrevious, lastNext;
        string L(string key) => UiLocalization.Get(key, locale);

        void ApplyLocale(string value)
        {
            locale = value == "en" || value == "ja" ? value : "zh-CN";
            root.Q<Label>("chatTitle").text = L("chat");
            root.Q<Label>("chatHint").text = L("hint");
            root.Q<Label>("emptyChat").text = L("empty");
            draft.textEdition.placeholder = L("placeholder");
            newMessages.text = L("new");
            foreach (var entry in new[] { ("send", "send"), ("cancel", "cancel"), ("closeChat", "close"),
                ("chatToggle", "chat"), ("chooseMusic", "music"), ("settings", "settingsTip"),
                ("fullscreen", "fullscreen"), ("microphone", "microphone"), ("inbox", "inbox"),
                ("props", "props"), ("screen", "screen") }) root.Q<Button>(entry.Item1).tooltip = L(entry.Item2);
            root.Q<Slider>("volume").tooltip = L("volume");
            root.Q<Button>("settings").Q<Label>().text = L("settings");
            root.Q<Button>("mode").Q<Label>().text = L(spaceVisible ? "space" : "player");
            root.Q<Button>("mode").tooltip = L(spaceConfigured ? "mode" : "noSpace");
            play.tooltip = L(lastPlaying ? "pause" : "play");
            root.Q<Button>("previous").tooltip = L(lastPrevious ? "previous" : "noPrevious");
            root.Q<Button>("next").tooltip = L(lastNext ? "next" : "noNext");
            list.RefreshItems();
        }

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
            draft.isDelayed = false;
            BindKeyboard();
            draft.RegisterCallback<FocusInEvent>(_ => {
                BindKeyboard();
                keyboard?.SetIMEEnabled(true);
            });
            draft.RegisterCallback<FocusOutEvent>(_ => {
                composition = "";
                compositionEndedFrame = Time.frameCount;
            });
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
                var retry = new Button { text = L("retry") }; retry.AddToClassList("retry-message");
                retry.clicked += () => { if (retry.userData is Message message) RestoreDraft(message); };
                box.Add(retry); return box; };
            list.bindItem = (row, i) => { var message = messages[i]; ((Label)row[0]).text = message.role; ((Label)row[1]).text = message.text;
                row.EnableInClassList("message-error", message.failed);
                var retry = (Button)row[2]; retry.text = L("retry"); retry.userData = message; retry.EnableInClassList("hidden", !message.failed); };
            chatScroll = list.Q<ScrollView>();
            chatScroll.mode = ScrollViewMode.Vertical;
            chatScroll.horizontalScrollerVisibility = ScrollerVisibility.Hidden;
            chatScroll.verticalScrollerVisibility = ScrollerVisibility.Auto;
            chatScroll.contentViewport.RegisterCallback<GeometryChangedEvent>(e => {
                // Dynamic-height virtual rows need a finite wrapping width;
                // otherwise their intrinsic text width creates horizontal scroll.
                chatScroll.contentContainer.style.width = e.newRect.width;
                chatScroll.contentContainer.style.minWidth = 0;
            });
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
            root.Q<Button>("chooseMusic").clicked += () => { ToggleChat(false); queuePanel?.SetVisible(false); musicLibraryPanel?.Toggle(); };
            volume.RegisterValueChangedCallback(e => backend?.SetVolume(e.newValue));
            ApplyLocale(locale);
            sculpture = gameObject.AddComponent<AudioSculpture>();
            pointArtwork = gameObject.AddComponent<PointCloudArtworkLoader>();
            gpuLyrics = gameObject.AddComponent<GpuLyricsView>();
            root.Q<Button>("settings").clicked += () => { Debug.Log("External settings clicked"); backend?.OpenSettings(); };
            try { backend = PlayerBackend.Create?.Invoke(); }
            catch (Exception error) { status.text = "音乐与对话服务连接失败：" + error.Message; status.AddToClassList("status-error"); SetConnected(false); return; }
            if (backend == null) { status.text = "音乐与对话服务未连接"; SetConnected(false); return; }
            backend.Snapshot += OnSnapshot; backend.Chat += OnChat; backend.Status += OnStatus;
            queuePanel = QueuePanel.Attach(root.Q(className: "body"), backend);
            if (backend is NativePlayerBackend nativeMusic) musicLibraryPanel = new MusicLibraryPanel(root.Q(className: "body"), nativeMusic, () => queuePanel.SetVisible(true));
            if (backend is NativePlayerBackend native) {
                var world = gameObject.AddComponent<WorldRuntimeBridge>();
                world.Initialize(native, sculpture);
                world.Status += OnStatus;
                var mode = root.Q<Button>("mode");
                mode.SetEnabled(world.Configured);
                spaceConfigured = world.Configured;
                mode.tooltip = L(spaceConfigured ? "mode" : "noSpace");
                Debug.Log($"World mode initialized: configured={world.Configured}; enabled={mode.enabledInHierarchy}");
                mode.RegisterCallback<PointerDownEvent>(e => Debug.Log($"World mode pointer down: button={e.button}; position={e.position}; enabled={mode.enabledInHierarchy}"), TrickleDown.TrickleDown);
                mode.RegisterCallback<PointerUpEvent>(e => Debug.Log($"World mode pointer up: button={e.button}; position={e.position}"), TrickleDown.TrickleDown);
                mode.RegisterCallback<GeometryChangedEvent>(_ => Debug.Log($"World mode bounds: {mode.worldBound}; panelScale={GetComponent<UIDocument>().panelSettings.scale}"));
                mode.clicked += () => { Debug.Log("World mode clicked"); world.Toggle(); };
                root.RegisterCallback<PointerDownEvent>(e => Debug.Log($"UI pointer down: target={(e.target as VisualElement)?.name}; position={e.position}; button={e.button}"), TrickleDown.TrickleDown);
                world.ModeChanged += visible => {
                    spaceVisible = visible;
                    // Preserve the vector icon created above; change only its label.
                    var label = mode.Q<Label>(); if (label != null) label.text = L(visible ? "space" : "player");
                };
                if (Environment.GetEnvironmentVariable("GMGN_UNITY_OPEN_SPACE") == "1")
                    root.schedule.Execute(() => { Debug.Log("World explicit startup requested; not a click acceptance"); world.Toggle(); });
            }
            SetConnected(true); status.text = "";
        }
        void SetConnected(bool ready) { connected = ready; play.SetEnabled(ready); volume.SetEnabled(ready); root.Q<Button>("next").SetEnabled(false); root.Q<Button>("previous").SetEnabled(false); root.Q<Button>("chooseMusic").SetEnabled(ready); root.Q<Button>("settings").SetEnabled(ready); UpdateComposer(); }
        void ToggleChat(bool visible) { if (visible) queuePanel?.SetVisible(false); chatPanel.EnableInClassList("hidden", !visible); root.Q<Button>("chatToggle").EnableInClassList("selected", visible); if (visible) { draft.schedule.Execute(() => draft.Focus()); if (follow) ScrollToLatest(); } }
        void UpdateComposer() { send.SetEnabled(connected && pending == null && !string.IsNullOrWhiteSpace(draft.value)); send.EnableInClassList("hidden", pending != null); cancel.EnableInClassList("hidden", pending == null); cancel.SetEnabled(connected && pending != null); }
        void OnStatus(string value) => status.text = value;
        void OnSnapshot(PlayerSnapshot snapshot)
        {
            if (!string.IsNullOrEmpty(snapshot.locale) && snapshot.locale != locale) ApplyLocale(snapshot.locale);
            lyric.text = snapshot.lyric ?? ""; translation.text = snapshot.translation ?? "";
            var lyricMode = snapshot.lyricVisual?.mode;
            gpuLyrics.SetTheme(snapshot.lyricVisual?.theme);
            gpuLyrics.SetLyrics(snapshot.sessionId, snapshot.lyricRevision,
                snapshot.lyricLines, lyricMode ?? "");
            gpuLyrics.SetPlayback(snapshot.position, snapshot.bass, snapshot.vocal, snapshot.treble);
            bool gpuModeReady = gpuLyrics.SupportsMode(lyricMode ?? "");
            gpuLyrics.SetVisible(gpuModeReady);
            // Text labels remain only for genuinely unmigrated styles. Do not
            // draw a second UI lyric over the active GPU presentation.
            lyric.style.display = gpuModeReady ? DisplayStyle.None : DisplayStyle.Flex;
            translation.style.display = gpuModeReady ? DisplayStyle.None : DisplayStyle.Flex;
            if (!gpuModeReady && gpuLyricStatus != lyricMode) {
                gpuLyricStatus = lyricMode;
                OnStatus("当前歌词风格的 GPU 渲染尚未完成迁移。");
            }
            duration = snapshot.duration;
            GetComponent<UIDocument>().rootVisualElement.Q<Button>("next").SetEnabled(snapshot.nextSupported);
            root.Q<Button>("previous").SetEnabled(snapshot.previousSupported);
            lastPrevious = snapshot.previousSupported; lastNext = snapshot.nextSupported; lastPlaying = snapshot.playing;
            root.Q<Button>("previous").tooltip = L(lastPrevious ? "previous" : "noPrevious");
            root.Q<Button>("next").tooltip = L(lastNext ? "next" : "noNext");
            volume.SetValueWithoutNotify(snapshot.volume);
            play.tooltip = L(snapshot.playing ? "pause" : "play");
            playIcon.Kind = snapshot.playing ? "pause" : "play";
            sculpture.SetFeatures(snapshot.playing, snapshot.bass, snapshot.vocal, snapshot.treble);
            if (snapshot.pointCloud is { } points) {
                var weights = Components(points.presetWeights);
                sculpture.SetVisual(points.choice, points.intensity, points.particleSize,
                    new Vector3(weights.x, weights.y, weights.z), points.composition);
                sculpture.SetRhythm(Components(points.rhythm), Components(points.waveA), Components(points.waveB));
                pointArtwork.Load(points.artworkURL);
            }
        }
        static Vector4 Components(float[] values) => new Vector4(
            values != null && values.Length > 0 ? values[0] : 0,
            values != null && values.Length > 1 ? values[1] : 0,
            values != null && values.Length > 2 ? values[2] : 0,
            values != null && values.Length > 3 ? values[3] : 0);
        static string Format(double seconds) { var span = TimeSpan.FromSeconds(Math.Max(0, seconds)); return $"{(int)span.TotalMinutes}:{span.Seconds:00}"; }
        void Send()
        {
            if (backend == null || pending != null || string.IsNullOrWhiteSpace(draft.value)) {
                Debug.Log($"[UnityChat] send_blocked backend={backend != null} pending={pending != null} hasText={!string.IsNullOrWhiteSpace(draft.value)}");
                return;
            }
            Debug.Log("[UnityChat] send_clicked");
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
            if (update.complete) Debug.Log($"[UnityChat] completed failed={!string.IsNullOrEmpty(update.error)} hasText={!string.IsNullOrEmpty(update.text)}");
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
        void OnDestroy() { followScroll?.Pause(); queuePanel?.Dispose(); musicLibraryPanel?.Dispose(); if (keyboard != null) keyboard.onIMECompositionChange -= OnComposition; if (backend == null) return; backend.Snapshot -= OnSnapshot; backend.Chat -= OnChat; backend.Status -= OnStatus; backend.Dispose(); }

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

        public sealed class ToolbarIcon : VisualElement
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
                    case "back": Path(13,4,7,10,13,16); break;
                    case "refresh": p.BeginPath(); p.Arc(new Vector2(10,10), 6, Angle.Degrees(35), Angle.Degrees(320), ArcDirection.Clockwise); p.Stroke(); Path(13,4,17,4,17,8); break;
                }
            }
        }
    }
}
