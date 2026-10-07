using System;
using System.Collections.Generic;
using System.Threading;
using Newtonsoft.Json.Linq;
using GMGN.UnityPlayer.Characters;
using GMGN.UnityPlayer.World;
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
        ScrollView list;
        Func<VisualElement> makeMessage;
        Action<VisualElement, int> bindMessage;
        TextField draft;
        Label status, lyric, translation;
        Button play, send, cancel;
        Slider volume;
        string pending;
        double duration;
        bool follow = true, dirty, refreshing;
        ScrollView chatScroll;
        ResidentThinkingCloud thinkingCloud;
        bool draggingChatScrollbar;
        IVisualElementScheduledItem followScroll;
        AudioSculpture sculpture;
        PointCloudArtworkLoader pointArtwork;
        GpuLyricsView gpuLyrics;
        string gpuLyricStatus;
        bool voiceStatusError;
        string chatVoiceState = "idle";
        string measuredDraftText;
        float measuredDraftWidth = -1;
        VisualElement root, chatPanel;
        Rect reportedChatImageDropRegion;
        bool chatImageDropRegionReported;
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
        [System.Runtime.InteropServices.DllImport("UnityMediaHost")]
        static extern void gmgn_unity_chat_image_drop_region(float x, float y, float width, float height);
#endif
        ToolbarIcon playIcon;
        bool connected;
        Keyboard keyboard;
        string composition = "";
        IDisposable imeCompositionBinding;
        QueuePanel queuePanel;
        MusicLibraryPanel musicLibraryPanel;
        InboxPanel inboxPanel;
        UnityPushToTalkControl voiceControl;
        UnityScreenVideoController screenVideo;
        UnitySpatialPresentationController spatialPresentation;
        UnityCharacterPositionObserver characterPositionObserver;
        ScrollView chatImageRows;
        Button chooseChatImages;
        JObject chatAttachments;
        readonly List<Texture2D> chatImageTextures = new();
        UnityCompactWindowController compactWindow;
        UnityPushToTalkControl livecamVoiceControl;
        ToolbarIcon livecamPlayIcon;
        bool autonomousThinking, editingReported;
        WorldInteractionController editingController;
        float nextEditingLookup;
        JObject pendingWorldSelectionReceipt;
        float nextWorldSelectionReceipt;
        WorldRuntimeBridge worldRuntime;
        CharacterWorldAdapter character;
        CancellationTokenSource characterLifetime = new();
        JObject activityProjection;
        float nextActivityProjection;
        bool lyricsVisible = true, shortcutVoiceActive, gpuLyricModeReady;
        const string LyricsVisiblePreference = "gmgn.lyrics.visible";
        BuiltinDeviceCatalogPanel deviceCatalog;
        WishMachinePanel wishPanel;
        JArray deviceTemplates = new();
        int compositionEndedFrame = -10;
        bool textInputReported, textCompositionReported;
        Keyboard imeCursorKeyboard;
        Vector2 imeCursorPosition;
        bool spaceVisible, spaceConfigured, lastPlaying, lastPrevious, lastNext;
        string L(string key) => UiLocalization.Get(key);

        void ApplyLocale()
        {
            RefreshLyricVisibility();
            root.Q<Label>("chatTitle").text = L("chat");
            root.Q<Label>("emptyChat").text = L("empty");
            draft.textEdition.placeholder = L("placeholder");
            foreach (var entry in new[] { ("send", "send"), ("cancel", "cancel"), ("closeChat", "close"),
                ("chatToggle", "chat"), ("chooseMusic", "music"), ("settings", "settingsTip"),
                ("fullscreen", "fullscreen"), ("inbox", "inbox"),
                ("props", "props"), ("screen", "screen"), ("compactWindow", "compactWindow"),
                ("restoreWindow", "restoreWindow") }) root.Q<Button>(entry.Item1).tooltip = L(entry.Item2);
            foreach (var entry in new[] { ("livecamSpace", "space"), ("livecamPlayer", "music"),
                ("livecamChat", "chat"), ("livecamInbox", "inboxTitle"),
                ("livecamSettings", "settingsTip"), ("livecamPrevious", "previous"),
                ("livecamPlay", lastPlaying ? "pause" : "play"), ("livecamNext", "next"), ("compactHistory", "chat") })
                root.Q<Button>(entry.Item1).tooltip = L(entry.Item2);
            root.Q<Slider>("volume").tooltip = L("volume");
            root.Q<Button>("settings").Q<Label>().text = L("settings");
            root.Q<Button>("mode").Q<Label>().text = L(spaceVisible ? "space" : "player");
            root.Q<Button>("mode").tooltip = L(spaceConfigured ? "mode" : "noSpace");
            play.tooltip = L(lastPlaying ? "pause" : "play");
            root.Q<Button>("previous").tooltip = L(lastPrevious ? "previous" : "noPrevious");
            root.Q<Button>("next").tooltip = L(lastNext ? "next" : "noNext");
            if (inboxPanel != null) { root.Q<Button>("inbox").tooltip = L("inboxTitle"); inboxPanel.SetLocale(UiLocalization.LocaleCode); }
            root.Q<Button>("chatVoice").tooltip = VoiceReadyHint();
            if (chatVoiceState == "idle") root.Q<Label>("chatVoiceStatus").AddToClassList("hidden");
            RefreshMessages();
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
            root.RegisterCallback<KeyDownEvent>(DismissPopupOnEscape, TrickleDown.TrickleDown);
            root.AddToClassList("document-root");
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            root.RegisterCallback<GeometryChangedEvent>(e => root.EnableInClassList("compact", e.newRect.width < 780 || e.newRect.height < 600));
            status = root.Q<Label>("status");
            OnError(null);
            lyric = root.Q<Label>("lyric"); translation = root.Q<Label>("translation");
            lyricsVisible = PlayerPrefs.GetInt(LyricsVisiblePreference, 1) != 0;
            root.Q<Button>("toggleLyrics").clicked += ToggleLyrics;
            RefreshLyricVisibility();
            draft = root.Q<TextField>("draft"); draft.textEdition.placeholder = "和角色聊聊…";
            draft.isDelayed = false;
            draft.verticalScrollerVisibility = ScrollerVisibility.Auto;
            BindKeyboard();
            imeCompositionBinding = ChatImeBridge.BindComposition(root);
            root.RegisterCallback<FocusInEvent>(e => ReportTextInputState(ChatImeBridge.FieldForElement(e.target as VisualElement) != null));
            root.RegisterCallback<FocusOutEvent>(_ => { ReportTextInputState(false); root.schedule.Execute(ReportTextInput); });
            draft.RegisterCallback<FocusInEvent>(_ => {
                BindKeyboard();
                keyboard?.SetIMEEnabled(true);
            });
            draft.RegisterCallback<FocusOutEvent>(_ => {
                composition = "";
                ChatImeBridge.SetComposition(root, "");
                ChatImeBridge.UpdateCompositionCaret(draft, "");
                compositionEndedFrame = Time.frameCount;
            });
            send = root.Q<Button>("send"); cancel = root.Q<Button>("cancel"); play = root.Q<Button>("play");
            chatPanel = root.Q("chatPanel");
            root.Q<Button>("chatToggle").clicked += () => ToggleChat(chatPanel.ClassListContains("hidden"));
            root.Q<Button>("closeChat").clicked += () => ToggleChat(false);
            compactWindow = gameObject.AddComponent<UnityCompactWindowController>();
            compactWindow.Initialize(root);
            compactWindow.ModeChanged += OnCompactModeChanged;
            compactWindow.EnterSpaceRequested += EnterLivecamSpace;
            root.Q<Button>("fullscreen").clicked += compactWindow.ToggleFullscreen;
            root.Q<Button>("compactWindow").clicked += compactWindow.Toggle;
            root.Q<Button>("restoreWindow").clicked += compactWindow.Restore;
            AddIcon("toggleLyrics", "lyrics");
            AddIcon("chooseMusic", "music"); AddIcon("previous", "previous");
            playIcon = AddIcon("play", "play"); AddIcon("next", "next");
            AddIcon("chatToggle", "chat");
            AddIcon("inbox", "mail"); AddIcon("props", "box"); AddIcon("screen", "screen");
            AddIcon("settings", "settings"); AddIcon("fullscreen", "fullscreen");
            AddIcon("compactWindow", "compact"); AddIcon("restoreWindow", "restore");
            AddIcon("livecamSpace", "screen"); AddIcon("livecamPlayer", "music");
            AddIcon("livecamChat", "chat"); AddIcon("livecamInbox", "mail");
            AddIcon("livecamSettings", "settings");
            AddIcon("livecamPrevious", "previous"); livecamPlayIcon = AddIcon("livecamPlay", "play");
            AddIcon("livecamNext", "next"); AddIcon("compactHistory", "restore");
            root.Q<Button>("livecamSpace").clicked += EnterLivecamSpace;
            root.Q<Button>("livecamPlayer").clicked += () => { var menu = root.Q("livecamPlayerMenu"); bool show = menu.ClassListContains("hidden"); ClosePopups(); menu.EnableInClassList("hidden", !show); };
            root.Q<Button>("livecamChat").clicked += () => ToggleChat(chatPanel.ClassListContains("hidden"));
            root.Q<Button>("livecamInbox").clicked += ToggleInbox;
            root.Q<Button>("livecamSettings").clicked += () => { Debug.Log($"External compact settings clicked backendReady={backend != null}"); backend?.OpenSettings(); };
            root.Q<Button>("livecamPrevious").clicked += () => backend?.Previous();
            root.Q<Button>("livecamPlay").clicked += () => backend?.PlayPause();
            root.Q<Button>("livecamNext").clicked += () => backend?.Next();
            root.Q<Button>("compactHistory").clicked += () => { chatPanel.ToggleInClassList("compact-history"); if (follow) ScrollToLatest(); };
            AddIcon("mode", "screen"); AddIcon("closeChat", "close");
            AddIcon("send", "send"); AddIcon("cancel", "stop");
            AddIcon("chatVoice", "microphone");
            root.Q<Button>("chatVoice").clicked += ToggleChatVoice;
            volume = root.Q<Slider>("volume");
            list = root.Q<ScrollView>("messages");
            makeMessage = () => { var box = new VisualElement(); box.AddToClassList("message");
                box.style.flexDirection = FlexDirection.Column;
                var role = new Label(); role.AddToClassList("message-role"); box.Add(role);
                var body = new Label { enableRichText = false }; body.AddToClassList("message-text");
                body.selection.isSelectable = true; box.Add(body);
                body.RegisterCallback<GeometryChangedEvent>(e => {
                    if (Mathf.Abs(e.newRect.width - e.oldRect.width) > .5f) MeasureMessageBody(body);
                });
                var retry = new Button { text = L("retry") }; retry.AddToClassList("retry-message");
                retry.clicked += () => { if (retry.userData is Message message) RestoreDraft(message); };
                box.Add(retry); return box; };
            bindMessage = (row, i) => { var message = messages[i]; ((Label)row[0]).text = L(message.role); ((Label)row[1]).text = message.text;
                // Keep text measurement independent of the scroll viewport's
                // available height, including when an existing reply grows.
                var width = chatScroll?.contentViewport.layout.width ?? 0;
                if (width > 24 && float.IsFinite(width)) {
                    row.style.width = width;
                    row[1].style.width = width - 24;
                }
                row[1].style.whiteSpace = WhiteSpace.Normal;
                row[1].style.flexShrink = 0;
                var body = (Label)row[1];
                body.schedule.Execute(() => MeasureMessageBody(body));
                row.EnableInClassList("message-error", message.failed);
                var retry = (Button)row[2]; retry.text = L("retry"); retry.userData = message; retry.EnableInClassList("hidden", !message.failed); };
            chatScroll = list;
            chatScroll.mode = ScrollViewMode.Vertical;
            chatScroll.horizontalScrollerVisibility = ScrollerVisibility.Hidden;
            chatScroll.verticalScrollerVisibility = ScrollerVisibility.Auto;
            chatScroll.contentViewport.RegisterCallback<GeometryChangedEvent>(e => {
                // Dynamic-height virtual rows need a finite wrapping width;
                // otherwise their intrinsic text width creates horizontal scroll.
                chatScroll.contentContainer.style.width = e.newRect.width;
                chatScroll.contentContainer.style.minWidth = 0;
                if (Mathf.Abs(e.newRect.width - e.oldRect.width) > .5f) {
                    dirty = true;
                }
            });
            InstallChatScrollTracking();
            send.clicked += Send;
            draft.RegisterValueChangedCallback(_ => UpdateComposer());
            cancel.clicked += () => { if (pending == null) return;
                try { backend?.Cancel(pending); RefreshThinking(); }
                catch (Exception) { OnError("暂时无法停止回复，请稍后重试。"); } };
            draft.RegisterCallback<KeyDownEvent>(e => {
                if (ChatImeBridge.ShouldSubmit(e, composition, Time.frameCount, compositionEndedFrame)) Send();
            }, TrickleDown.TrickleDown);
            play.clicked += () => backend?.PlayPause(); root.Q<Button>("next").clicked += () => backend?.Next();
            root.Q<Button>("previous").clicked += () => backend?.Previous();
            root.Q<Button>("chooseMusic").clicked += ToggleMusicLibrary;
            volume.RegisterValueChangedCallback(e => backend?.SetVolume(e.newValue));
            UiLocalization.Changed += ApplyLocale;
            UiLocalization.SelectHostLocale("zh-CN");
            thinkingCloud = gameObject.AddComponent<ResidentThinkingCloud>();
            thinkingCloud.Initialize(root);
            sculpture = gameObject.AddComponent<AudioSculpture>();
            pointArtwork = gameObject.AddComponent<PointCloudArtworkLoader>();
            gpuLyrics = gameObject.AddComponent<GpuLyricsView>();
            root.Q<Button>("settings").clicked += () => { Debug.Log("External settings clicked"); backend?.OpenSettings(); };
            try { backend = PlayerBackend.Create?.Invoke(); }
            catch (Exception error) { Debug.LogException(error); OnError("音乐与对话服务连接失败，请重新打开应用。"); SetConnected(false); return; }
            if (backend == null) { OnError("音乐与对话服务未连接，请重新打开应用。"); SetConnected(false); return; }
            backend.Snapshot += OnSnapshot; backend.Chat += OnChat; backend.Status += OnStatus; backend.Error += OnError;
            queuePanel = QueuePanel.Attach(root.Q(className: "body"), backend);
            if (backend is NativePlayerBackend nativeMusic) musicLibraryPanel = new MusicLibraryPanel(root.Q(className: "body"), nativeMusic, () => { ClosePopups(); queuePanel.SetVisible(true); });
            if (backend is NativePlayerBackend native) {
                InstallChatImageControls(native);
                native.ChatAttachmentsUpdated += OnChatAttachmentsUpdated;
                screenVideo = gameObject.AddComponent<UnityScreenVideoController>();
                screenVideo.Initialize(root.Q(className: "body"), native.SendCommand);
                screenVideo.SetWorldVisible(spaceVisible);
                native.ScreenVideoUpdated += OnScreenVideoUpdated;
                native.AutonomousReply += OnAutonomousReply;
                native.AutonomyRunningChanged += OnAutonomyRunningChanged;
                native.ReplySpeechChanged += (playing, level) => {
                    if (character != null && character.Runtime != null) character.Runtime.SetSpeechLevel(playing, level);
#if GMGN_UNIVRM
                    if (character != null && character.VrmRuntime != null) character.VrmRuntime.SetSpeechLevel(playing, level);
#endif
                };
                var screenButton = root.Q<Button>("screen");
                screenButton.SetEnabled(true);
                screenButton.clicked += () => {
                    bool show = !screenVideo.Visible; ClosePopups(); if (show) screenVideo.Show();
                };
                native.VoiceTranscript += OnVoiceTranscript;
                native.VoiceStateChanged += OnVoiceState;
                character = FindFirstObjectByType<CharacterWorldAdapter>();
                if (character == null) character = new GameObject("Resident character").AddComponent<CharacterWorldAdapter>();
                native.CharacterSelection += OnCharacterSelection;
                native.ResidentActivity += OnResidentActivity;
                native.UiIntent += OnUiIntent;
                character.SelectionCompleted += OnSelectionCompleted;
                character.ManualMotionCompleted += OnManualMotionCompleted;
                inboxPanel = new InboxPanel(root.Q(className: "body"), native);
                inboxPanel.UnreadChanged += count => UpdateInboxUnreadIndicators(root, count);
                UpdateInboxUnreadIndicators(root, inboxPanel.UnreadCount);
                var inboxButton = root.Q<Button>("inbox");
                inboxButton.SetEnabled(true);
                inboxButton.tooltip = L("inboxTitle");
                inboxButton.clicked += ToggleInbox;
                var world = gameObject.AddComponent<WorldRuntimeBridge>();
                worldRuntime = world;
                native.WorldSelectionUpdated += OnWorldSelectionUpdated;
                native.WishOutputPreviewUpdated += OnWishOutputPreviewUpdated;
                world.SelectionPrepared += OnWorldSelectionPrepared;
                world.OutputProjectionAck = native.SendCommand;
                world.BindCharacter(character);
                world.PlaceDevice = native.SendDevicePlacement;
                wishPanel = new WishMachinePanel(root.Q(className: "body"), native.SendCommand, () => ToggleChat(true));
                native.WishUpdated += OnWishUpdated;
                native.GeneratedAssetsUpdated += OnGeneratedAssets;
                world.DeviceActivated += OnDeviceActivated;
                deviceCatalog = new BuiltinDeviceCatalogPanel(root.Q(className: "body"));
                world.InventoryUpdated += OnInventoryUpdated;
                deviceCatalog.InventorySelection += id => { if (world.BeginInventoryPlacement(id)) deviceCatalog.Hide(); };
                deviceCatalog.InventoryDeletion += id => { if (world.DeleteInventoryObject(id)) deviceCatalog.Hide(); };
                native.InventoryMutationUpdated += OnInventoryMutationUpdated;
                native.BuiltinDevices += OnBuiltinDevices;
                native.DevicePlacementUpdated += OnDevicePlacement;
                deviceCatalog.Selection += id => {
                    foreach (var entry in deviceTemplates) if ((string)entry["id"] == id) {
                        world.BeginDevicePlacement((JObject)entry);
                        deviceCatalog.Hide();
                        break;
                    }
                };
                var propsButton = root.Q<Button>("props");
                propsButton.SetEnabled(true);
                propsButton.clicked += () => { bool editing = !world.IsEditing; ClosePopups(); world.SetEditing(editing); propsButton.EnableInClassList("selected", editing); if (editing) deviceCatalog.Show(); };
                world.Initialize(native, sculpture);
                spatialPresentation = gameObject.AddComponent<UnitySpatialPresentationController>();
                spatialPresentation.Initialize(root.Q(className: "body"), gameObject.GetComponent<WorldCameraController>(),
                    () => world.PresentationWorldID,
                    () => world.PresentationVisible && compactWindow?.IsCompact != true,
                    receipt => native.SendCommand(receipt));
                native.SpatialPresentationUpdated += OnSpatialPresentationUpdated;
                characterPositionObserver = gameObject.AddComponent<UnityCharacterPositionObserver>();
                characterPositionObserver.Initialize(character,
                    () => world.PresentationWorldID,
                    () => world.PresentationVisible && compactWindow?.IsCompact != true,
                    () => gameObject.GetComponent<WorldCameraController>()?.PresentationCamera,
                    receipt => native.SendCommand(receipt));
                native.CharacterPositionUpdated += OnCharacterPositionUpdated;
                world.Status += OnStatus;
                world.Error += OnError;
                world.ErrorCleared += OnWorldErrorCleared;
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
                root.RegisterCallback<PointerUpEvent>(e => Debug.Log($"UI pointer up: target={(e.target as VisualElement)?.name}; position={e.position}; button={e.button}"), TrickleDown.TrickleDown);
                root.RegisterCallback<ClickEvent>(e => Debug.Log($"UI click: target={(e.target as VisualElement)?.name}; position={e.position}; button={e.button}"), TrickleDown.TrickleDown);
                world.ModeChanged += visible => {
                    spaceVisible = visible;
                    spaceConfigured = world.Configured;
                    mode.SetEnabled(spaceConfigured);
                    mode.tooltip = L(spaceConfigured ? "mode" : "noSpace");
                    screenVideo?.SetWorldVisible(visible);
                    // Preserve the vector icon created above; change only its label.
                    var label = mode.Q<Label>(); if (label != null) label.text = L(visible ? "space" : "player");
                };
                if (Environment.GetEnvironmentVariable("GMGN_UNITY_OPEN_SPACE") == "1")
                    root.schedule.Execute(() => { Debug.Log("World explicit startup requested; not a click acceptance"); world.Toggle(); });
            }
            SetConnected(true); OnError(null);
        }
        void SetConnected(bool ready) { connected = ready; play.SetEnabled(ready); volume.SetEnabled(ready); root.Q<Button>("next").SetEnabled(false); root.Q<Button>("previous").SetEnabled(false); root.Q<Button>("chooseMusic").SetEnabled(ready); root.Q<Button>("settings").SetEnabled(ready); UpdateComposer(); }
        public static int PopupDismissedFrame { get; private set; } = -1;
        void ToggleMusicLibrary() {
            bool show = musicLibraryPanel?.Element.ClassListContains("hidden") ?? false;
            Debug.Log($"[Popup] music clicked available={musicLibraryPanel != null} show={show} compact={compactWindow?.IsCompact ?? false}");
            ClosePopups(); musicLibraryPanel?.SetVisible(show);
        }
        void DismissPopupOnEscape(KeyDownEvent e) {
            if (e.keyCode != KeyCode.Escape || !HasPopup || ChatImeBridge.BlocksSubmit(composition, Time.frameCount, compositionEndedFrame)) return;
            PopupDismissedFrame = Time.frameCount; ClosePopups(); e.StopImmediatePropagation(); e.PreventDefault();
        }
        void ClosePopups(bool keepChat = false) {
            if (!keepChat) CancelChatVoice();
            if (!keepChat) { chatPanel?.AddToClassList("hidden"); root.Q<Button>("chatToggle")?.RemoveFromClassList("selected"); }
            inboxPanel?.Hide(); queuePanel?.SetVisible(false); musicLibraryPanel?.SetVisible(false);
            wishPanel?.Hide(); screenVideo?.Hide(); deviceCatalog?.Hide();
            root.Q("livecamPlayerMenu")?.AddToClassList("hidden");
            ReportTextInput();
        }
        bool HasPopup => (chatPanel != null && !chatPanel.ClassListContains("hidden")) ||
            (inboxPanel != null && !inboxPanel.Element.ClassListContains("hidden")) || queuePanel?.Visible == true ||
            (musicLibraryPanel != null && !musicLibraryPanel.Element.ClassListContains("hidden")) || screenVideo?.Visible == true ||
            (wishPanel != null && !wishPanel.Element.ClassListContains("hidden")) ||
            (root?.Q("builtinDeviceCatalog") is VisualElement catalog && catalog.style.display.value != DisplayStyle.None) ||
            (root?.Q("livecamPlayerMenu") is VisualElement menu && !menu.ClassListContains("hidden"));
        void ToggleChat(bool visible) { if (visible) ClosePopups(true); else CancelChatVoice(); chatPanel.EnableInClassList("hidden", !visible); root.Q<Button>("chatToggle").EnableInClassList("selected", visible); if (visible) { draft.schedule.Execute(() => draft.Focus()); if (follow) ScrollToLatest(); } else ReportTextInput(); }
        bool ChatImagesReady => chatAttachments == null || (bool?)chatAttachments["canSubmit"] == true;
        int ChatImageCount => (int?)chatAttachments?["count"] ?? 0;
        void UpdateComposer() { MeasureDraftText(); send.SetEnabled(connected && pending == null && composition.Length == 0 && ChatImagesReady && (!string.IsNullOrWhiteSpace(draft.value) || ChatImageCount > 0)); send.EnableInClassList("hidden", pending != null); cancel.EnableInClassList("hidden", pending == null); cancel.SetEnabled(connected && pending != null); chooseChatImages?.SetEnabled(connected && pending == null && ChatImagesReady && ChatImageCount < 4); }
        void InstallChatImageControls(NativePlayerBackend native) {
            chooseChatImages = new Button(() => native.SendCommand(new JObject { ["op"] = "chat.attachments.pick" })) { text = "+", name = "chooseChatImages", tooltip = "添加图片（最多 4 张）" };
            chooseChatImages.AddToClassList("icon-button"); chooseChatImages.AddToClassList("chat-attachment-button");
            root.Q(className: "composer-footer").Insert(0, chooseChatImages);
            draft.RegisterCallback<KeyDownEvent>(e => {
                if (!connected || pending != null || composition.Length != 0 || e.keyCode != KeyCode.V || (!e.commandKey && !e.ctrlKey)) return;
                if (native.SendCommand(new JObject { ["op"] = "chat.attachments.pasteIfImage" })) {
                    e.StopImmediatePropagation(); e.PreventDefault();
                }
            }, TrickleDown.TrickleDown);
            chatImageRows = new ScrollView(ScrollViewMode.Vertical) { name = "chatImageDrafts" };
            chatImageRows.horizontalScrollerVisibility = ScrollerVisibility.Hidden;
            chatImageRows.verticalScrollerVisibility = ScrollerVisibility.Auto;
            chatImageRows.AddToClassList("chat-image-drafts"); chatImageRows.AddToClassList("hidden");
            draft.parent.Insert(draft.parent.IndexOf(draft), chatImageRows);
            if (native.ChatAttachments != null) OnChatAttachmentsUpdated(native.ChatAttachments);
        }
        void OnChatAttachmentsUpdated(JObject value) {
            chatAttachments = value; chatImageRows?.Clear(); ReleaseChatImageTextures();
            if (value["attachments"] is JArray images) foreach (var image in images) {
                string id = (string)image["id"];
                var row = new VisualElement(); row.AddToClassList("chat-image-row");
                if (image["thumbnailPNG"]?.Type == JTokenType.String) {
                    Texture2D texture = null;
                    try {
                        string encoded = (string)image["thumbnailPNG"];
                        if (encoded.Length <= 44000) {
                            byte[] bytes = Convert.FromBase64String(encoded);
                            if (bytes.Length <= 32768) {
                                texture = new Texture2D(2, 2, TextureFormat.RGBA32, false);
                                if (texture.LoadImage(bytes) && texture.width <= 96 && texture.height <= 96) {
                                    chatImageTextures.Add(texture);
                                    var preview = new Image { image = texture, scaleMode = ScaleMode.ScaleToFit };
                                    preview.AddToClassList("chat-image-thumbnail");
                                    row.Add(preview); texture = null;
                                }
                            }
                        }
                    } catch (FormatException) { }
                    finally { if (texture != null) Destroy(texture); }
                }
                var label = new Label((string)image["name"] ?? "图片"); label.AddToClassList("chat-image-filename"); row.Add(label);
                var remove = new Button(() => { if (pending == null) (backend as NativePlayerBackend)?.SendCommand(new JObject { ["op"] = "chat.attachments.remove", ["id"] = id }); }) { text = "移除" };
                remove.AddToClassList("chat-image-remove"); remove.SetEnabled(pending == null && (bool?)value["isPreparing"] != true && (bool?)value["isSelecting"] != true); row.Add(remove); chatImageRows?.Add(row);
            }
            if ((bool?)value["isSelecting"] == true) chatImageRows?.Add(new Label("请选择图片…"));
            if ((bool?)value["isPreparing"] == true) chatImageRows?.Add(new Label("正在准备图片…"));
            if (value["error"]?.Type == JTokenType.String) chatImageRows?.Add(new Label((string)value["error"]));
            bool hasPreview = ChatImageCount > 0 || (bool?)value["isSelecting"] == true || (bool?)value["isPreparing"] == true || value["error"]?.Type == JTokenType.String;
            chatImageRows?.EnableInClassList("hidden", !hasPreview);
            chatPanel?.EnableInClassList("chat-has-images", hasPreview);
            UpdateComposer();
        }
        void ReleaseChatImageTextures() {
            foreach (var texture in chatImageTextures) if (texture != null) {
#if UNITY_EDITOR
                if (!Application.isPlaying) DestroyImmediate(texture); else
#endif
                Destroy(texture);
            }
            chatImageTextures.Clear();
        }
        void MeasureDraftText() {
            var text = draft?.Q<TextElement>(className: "unity-text-element"); if (text == null) return;
            var width = text.contentRect.width; if (!float.IsFinite(width) || width <= 0) return;
            var value = text.text ?? "";
            if (measuredDraftText == value && Mathf.Abs(measuredDraftWidth - width) < .5f) return;
            measuredDraftText = value; measuredDraftWidth = width;
            // IME adds an absolute child caret. Yoga then no longer measures this
            // TextElement as a leaf, so keep its text content size explicit.
            var height = text.MeasureTextSize(value, width, VisualElement.MeasureMode.AtMost, 0, VisualElement.MeasureMode.Undefined).y;
            if (float.IsFinite(height)) { text.style.height = Mathf.Max(height, text.resolvedStyle.fontSize * 1.4f); text.style.flexShrink = 0; }
        }
        void OnStatus(string value) { if (!string.IsNullOrWhiteSpace(value)) Debug.Log("[PlayerStatus] " + value); }
        void OnWorldErrorCleared(string previousError) {
            if (!string.IsNullOrEmpty(previousError) && status.text == previousError) OnError(null);
        }
        void OnError(string value) {
            status.text = value ?? "";
            status.EnableInClassList("status-error", !string.IsNullOrWhiteSpace(value));
            status.style.display = string.IsNullOrWhiteSpace(value) ? DisplayStyle.None : DisplayStyle.Flex;
        }
        void OnScreenVideoUpdated(JObject value) => screenVideo?.ApplySnapshot(value);
        void OnSpatialPresentationUpdated(JObject value) => spatialPresentation?.ApplySnapshot(value);
        void OnCharacterPositionUpdated(JObject value) => characterPositionObserver?.ApplySnapshot(value);
        void OnCompactModeChanged(bool compact) {
            RefreshLyricVisibility();
            root.Q("livecamPlayerMenu").AddToClassList("hidden");
            if (!compact) return;
            inboxPanel?.Hide(); queuePanel?.SetVisible(false); musicLibraryPanel?.SetVisible(false);
            deviceCatalog?.Hide(); wishPanel?.Hide(); screenVideo?.Hide();
            if (!chatPanel.ClassListContains("hidden") && follow) ScrollToLatest();
        }
        void EnterLivecamSpace() { compactWindow.Restore(); if (!spaceVisible) worldRuntime?.Toggle(); }
        static void UpdateInboxUnreadIndicators(VisualElement root, int count)
        {
            foreach (var name in new[] { "inbox", "livecamInbox" }) {
                var button = root.Q<Button>(name);
                if (button == null) continue;
                var badge = button.Q<Label>(className: "inbox-unread-badge");
                if (badge == null) {
                    badge = new Label { pickingMode = PickingMode.Ignore, enableRichText = false };
                    badge.AddToClassList("inbox-unread-badge");
                    button.Add(badge);
                }
                badge.text = count > 99 ? "99+" : count.ToString();
                badge.style.display = count > 0 ? DisplayStyle.Flex : DisplayStyle.None;
            }
        }

        void ToggleInbox() {
            if (inboxPanel == null) return;
            if (!inboxPanel.Element.ClassListContains("hidden")) { inboxPanel.Hide(); return; }
            ClosePopups();
            root.Q("livecamPlayerMenu").AddToClassList("hidden"); inboxPanel.Show();
        }
        void OnWorldSelectionUpdated(JObject value) => worldRuntime?.ApplyWorldSelection(value);
        void OnWishOutputPreviewUpdated(JObject value) => worldRuntime?.SetWishOutputPreview(value);
        void OnWorldSelectionPrepared(JObject receipt) {
            receipt["op"] = "world.selection.prepared";
            pendingWorldSelectionReceipt = receipt;
            TrySendWorldSelectionReceipt();
        }
        void TrySendWorldSelectionReceipt() {
            if (pendingWorldSelectionReceipt == null || backend is not NativePlayerBackend native) return;
            nextWorldSelectionReceipt = Time.unscaledTime + .25f;
            if (native.SendCommand(pendingWorldSelectionReceipt)) pendingWorldSelectionReceipt = null;
        }
        void OnAutonomyRunningChanged(bool running) { autonomousThinking = running; RefreshThinking(); }
        void RefreshThinking() => thinkingCloud?.SetPending(pending != null || autonomousThinking);
        void RefreshLyricVisibility() {
            var toggle = root?.Q<Button>("toggleLyrics");
            if (toggle != null) {
                toggle.text = string.Empty;
                toggle.tooltip = lyricsVisible ? VoiceHint("hideLyrics", "隐藏歌词", "Hide lyrics", "歌詞を隠す") : VoiceHint("showLyrics", "显示歌词", "Show lyrics", "歌詞を表示");
                toggle.EnableInClassList("selected", lyricsVisible);
            }
            bool visible = lyricsVisible && !(compactWindow?.IsCompact ?? false);
            gpuLyrics?.SetVisible(visible && gpuLyricModeReady);
            if (lyric != null) lyric.style.display = visible && !gpuLyricModeReady ? DisplayStyle.Flex : DisplayStyle.None;
            if (translation != null) translation.style.display = visible && !gpuLyricModeReady ? DisplayStyle.Flex : DisplayStyle.None;
        }
        void ToggleLyrics() {
            lyricsVisible = !lyricsVisible;
            PlayerPrefs.SetInt(LyricsVisiblePreference, lyricsVisible ? 1 : 0);
            PlayerPrefs.Save();
            RefreshLyricVisibility();
        }
        void OnAutonomousReply(string text, ulong revision) {
            messages.Add(new Message { id = "autonomous:" + revision, role = "chatRoleResident", text = text });
            root.Q<Label>("emptyChat").AddToClassList("hidden");
            dirty = true;
        }
        void OnSnapshot(PlayerSnapshot snapshot)
        {
            if (!string.IsNullOrEmpty(snapshot.locale) && snapshot.locale != UiLocalization.LocaleCode) UiLocalization.SelectHostLocale(snapshot.locale);
            lyric.text = snapshot.lyric ?? ""; translation.text = snapshot.translation ?? "";
            var lyricMode = snapshot.lyricVisual?.mode;
            gpuLyrics.SetTheme(snapshot.lyricVisual?.theme);
            gpuLyrics.SetLyrics(snapshot.sessionId, snapshot.lyricRevision,
                snapshot.lyricLines, lyricMode ?? "");
            gpuLyrics.SetPlayback(snapshot.position, snapshot.bass, snapshot.vocal, snapshot.treble);
            bool gpuModeReady = gpuLyrics.SupportsMode(lyricMode ?? "");
            gpuLyricModeReady = gpuModeReady;
            RefreshLyricVisibility();
            // Text labels remain only for genuinely unmigrated styles. Do not
            // draw a second UI lyric over the active GPU presentation.
            if (!gpuModeReady && gpuLyricStatus != lyricMode) {
                gpuLyricStatus = lyricMode;
                OnStatus("当前歌词风格的 GPU 渲染尚未完成迁移。");
            }
            duration = snapshot.duration;
            GetComponent<UIDocument>().rootVisualElement.Q<Button>("next").SetEnabled(snapshot.nextSupported);
            root.Q<Button>("previous").SetEnabled(snapshot.previousSupported);
            lastPrevious = snapshot.previousSupported; lastNext = snapshot.nextSupported; lastPlaying = snapshot.playing;
            root.Q<Button>("livecamPrevious").SetEnabled(snapshot.previousSupported);
            root.Q<Button>("livecamNext").SetEnabled(snapshot.nextSupported);
            root.Q<Button>("livecamPlay").SetEnabled(connected); livecamPlayIcon.Kind = snapshot.playing ? "pause" : "play";
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
            if (composition.Length > 0) return;
            if (backend == null || pending != null || !ChatImagesReady || (string.IsNullOrWhiteSpace(draft.value) && ChatImageCount == 0)) {
                Debug.Log($"[UnityChat] send_blocked backend={backend != null} pending={pending != null} hasText={!string.IsNullOrWhiteSpace(draft.value)}");
                return;
            }
            Debug.Log("[UnityChat] send_clicked");
            follow = true; draggingChatScrollbar = false;
            pending = Guid.NewGuid().ToString("N"); var text = draft.value.Trim();
            messages.Add(new Message { role = "chatRoleUser", text = text + (ChatImageCount > 0 ? $"\n[图片 × {ChatImageCount}]" : "") });
            GetComponent<UIDocument>().rootVisualElement.Q<Label>("emptyChat").AddToClassList("hidden");
            indices[pending] = messages.Count; messages.Add(new Message { id = pending, role = "chatRoleResident", text = L("chatResponding"), requestText = text });
            dirty = true; draft.SetValueWithoutNotify(""); UpdateComposer();
            RefreshThinking();
            try {
                if (backend is NativePlayerBackend native && chatAttachments != null) {
                    var ids = new JArray(); if (chatAttachments["attachments"] is JArray images) foreach (var image in images) ids.Add((string)image["id"]);
                    native.SendWithAttachments(pending, text, ids, (ulong?)chatAttachments["generation"] ?? 0);
                } else backend.Send(pending, text);
            }
            catch (Exception) { OnChat(new ChatUpdate { messageId = pending, error = L("chatSendFailed"), complete = true }); }
        }
        void OnChat(ChatUpdate update)
        {
            if (update.complete) Debug.Log($"[UnityChat] completed failed={!string.IsNullOrEmpty(update.error)} hasText={!string.IsNullOrEmpty(update.text)}");
            if (!indices.TryGetValue(update.messageId, out var index)) return;
            var message = messages[index];
            message.failed = !string.IsNullOrEmpty(update.error);
            var text = message.failed ? L("chatIncomplete") + update.error : update.text;
            if (message.text == text && !update.complete) return;
            message.text = text;
            dirty = true;
            if (update.complete && pending == update.messageId) { pending = null; RefreshThinking(); UpdateComposer(); }
        }
        void Update()
        {
            BindKeyboard();
            MeasureDraftText();
            ReportTextInput();
            UpdateImeGeometry();
            UpdateRuntime();
            ReportChatImageDropRegion();
        }
        void ReportChatImageDropRegion()
        {
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            if (backend is not NativePlayerBackend) return;
            var region = Rect.zero;
            var panelScale = GetComponent<UIDocument>()?.panelSettings?.scale ?? 1;
            if (connected && pending == null && ChatImagesReady && ChatImageCount < 4 &&
                chatPanel != null && !chatPanel.ClassListContains("hidden") && draft != null &&
                panelScale > 0 && Screen.width > 0 && Screen.height > 0) {
                region = NormalizeChatImageDropRegion(draft.worldBound, Screen.width, Screen.height, panelScale);
            }
            if (chatImageDropRegionReported && region == reportedChatImageDropRegion) return;
            gmgn_unity_chat_image_drop_region(region.x, region.y, region.width, region.height);
            reportedChatImageDropRegion = region;
            chatImageDropRegionReported = true;
#endif
        }
        internal static Rect NormalizeChatImageDropRegion(Rect bounds, int framebufferWidth, int framebufferHeight, float panelScale)
        {
            if (panelScale <= 0 || framebufferWidth <= 0 || framebufferHeight <= 0 || bounds.width <= 0 || bounds.height <= 0)
                return Rect.zero;
            var width = framebufferWidth / panelScale;
            var height = framebufferHeight / panelScale;
            return new Rect(bounds.x / width, bounds.y / height, bounds.width / width, bounds.height / height);
        }
        void UpdateImeGeometry()
        {
            var focusedText = ChatImeBridge.FocusedField(root);
            ChatImeBridge.UpdateCompositionCaret(draft, composition);
            if (keyboard != null && focusedText != null && ChatImeBridge.TryCandidatePosition(focusedText,
                new Vector2(Screen.width, Screen.height), out var candidate) &&
                (keyboard != imeCursorKeyboard || (candidate - imeCursorPosition).sqrMagnitude > .25f)) {
                keyboard.SetIMECursorPosition(candidate);
                imeCursorKeyboard = keyboard; imeCursorPosition = candidate;
            }
        }
        void UpdateRuntime()
        {
            if (keyboard != null && keyboard.escapeKey.wasPressedThisFrame && HasPopup &&
                !ChatImeBridge.BlocksSubmit(composition, Time.frameCount, compositionEndedFrame)) { PopupDismissedFrame = Time.frameCount; ClosePopups(); }
            if (pendingWorldSelectionReceipt != null && Time.unscaledTime >= nextWorldSelectionReceipt) TrySendWorldSelectionReceipt();
            if (backend is NativePlayerBackend editingNative) {
                if (editingController == null && Time.unscaledTime >= nextEditingLookup) {
                    editingController = FindAnyObjectByType<WorldInteractionController>();
                    nextEditingLookup = Time.unscaledTime + .5f;
                }
                bool editing = worldRuntime != null && worldRuntime.IsEditing;
                if (editing != editingReported && editingNative.SendCommand(new JObject { ["op"] = "resident.autonomy.editing", ["editing"] = editing })) editingReported = editing;
            }
            backend?.Tick();
            if (character != null && activityProjection != null && Time.unscaledTime >= nextActivityProjection) {
                nextActivityProjection = Time.unscaledTime + .2f;
                var receipt = character.ApplyResidentActivity(activityProjection);
                if (receipt != null && backend is NativePlayerBackend native) {
                    receipt["op"] = "activity.projected";
                    native.SendCommand(receipt);
                }
            }
            if (!dirty) return;
            dirty = false;
            var offset = chatScroll.scrollOffset;
            refreshing = true; RefreshMessages();
            if (follow) ScrollToLatest(); else chatScroll.scrollOffset = offset;
            refreshing = false;
        }
        void ScrollToLatest()
        {
            followScroll?.Pause();
            followScroll = list.schedule.Execute(() => {
                if (!follow || chatPanel.ClassListContains("hidden")) { followScroll?.Pause(); return; }
                refreshing = true;
                float bottom = Mathf.Max(0, chatScroll.verticalScroller.highValue);
                if (Mathf.Abs(chatScroll.scrollOffset.y - bottom) > .5f) chatScroll.scrollOffset = new Vector2(0, bottom);
                refreshing = false;
            }).Every(16);
        }
        void OnChatWheel(float direction)
        {
            if (direction == 0) return;
            followScroll?.Pause();
            if (direction < 0) follow = false;
            else chatScroll.schedule.Execute(() => {
                follow = chatScroll.scrollOffset.y >= chatScroll.verticalScroller.highValue - 36;
                if (follow) ScrollToLatest();
            });
        }
        void InstallChatScrollTracking()
        {
            chatScroll.verticalScroller.valueChanged += value => {
                if (refreshing || !draggingChatScrollbar) return;
                follow = value >= chatScroll.verticalScroller.highValue - 36;
            };
            chatScroll.RegisterCallback<WheelEvent>(e => OnChatWheel(e.delta.y), TrickleDown.TrickleDown);
            chatScroll.verticalScroller.RegisterCallback<PointerDownEvent>(_ => { draggingChatScrollbar = true; followScroll?.Pause(); follow = false; }, TrickleDown.TrickleDown);
            chatScroll.RegisterCallback<PointerUpEvent>(_ => EndChatScrollbarDrag(), TrickleDown.TrickleDown);
            chatScroll.verticalScroller.RegisterCallback<PointerCaptureOutEvent>(_ => EndChatScrollbarDrag(), TrickleDown.TrickleDown);
            chatScroll.contentContainer.RegisterCallback<GeometryChangedEvent>(_ => { if (follow && !refreshing) ScrollToLatest(); });
        }
        void EndChatScrollbarDrag()
        {
            if (!draggingChatScrollbar) return;
            draggingChatScrollbar = false;
            follow = chatScroll.scrollOffset.y >= chatScroll.verticalScroller.highValue - 36;
            if (follow) ScrollToLatest();
        }
        void RefreshMessages()
        {
            if (list == null || makeMessage == null || bindMessage == null) return;
            var content = list.contentContainer;
            while (content.childCount > messages.Count) content.RemoveAt(content.childCount - 1);
            while (content.childCount < messages.Count) content.Add(makeMessage());
            for (var i = 0; i < messages.Count; ++i) bindMessage(content[i], i);
            list.schedule.Execute(() => {
                if (content.childCount == 0) return;
                var row = content[content.childCount - 1];
                Debug.Log($"[ChatLayout] viewport={list.contentViewport.layout} content={content.layout} range={list.verticalScroller.highValue} row={row.layout} role={row[0].layout} body={row[1].layout}");
            }).StartingIn(250);
        }
        static void MeasureMessageBody(Label body)
        {
            var width = body.contentRect.width;
            if (width <= 0 || !float.IsFinite(width)) return;
            var measured = body.MeasureTextSize(body.text, width, VisualElement.MeasureMode.Exactly,
                0, VisualElement.MeasureMode.Undefined);
            var height = Mathf.Ceil(measured.y + body.resolvedStyle.paddingTop + body.resolvedStyle.paddingBottom);
            if (float.IsFinite(height) && height > 0) body.style.height = height;
        }
        void RestoreDraft(Message message)
        {
            if (!string.IsNullOrWhiteSpace(draft.value)) { OnStatus(L("chatDraftNotEmpty")); return; }
            draft.value = message.requestText ?? ""; draft.Focus();
        }
        void BindKeyboard() { if (keyboard == Keyboard.current) return; if (keyboard != null) keyboard.onIMECompositionChange -= OnComposition; keyboard = Keyboard.current; if (keyboard != null) keyboard.onIMECompositionChange += OnComposition; }
        void OnComposition(IMECompositionString value) {
            var field = ChatImeBridge.FocusedField(root);
            var next = field == null ? "" : value.ToString();
            if (composition.Length > 0 && next.Length == 0) compositionEndedFrame = Time.frameCount;
            composition = next;
            ChatImeBridge.SetComposition(root, next);
            ChatImeBridge.Forward(field, next);
            ReportTextInput();
            UpdateImeGeometry();
            UpdateComposer();
        }
        void ReportTextInput() => ReportTextInputState(ChatImeBridge.FocusedField(root) != null);
        void ReportTextInputState(bool focused)
        {
            if (!focused && composition.Length > 0) { composition = ""; ChatImeBridge.SetComposition(root, ""); compositionEndedFrame = Time.frameCount; }
            if (backend is not NativePlayerBackend native) return;
            var composing = focused && composition.Length > 0;
            if (focused == textInputReported && composing == textCompositionReported) return;
            if (native.SendCommand(new JObject { ["op"] = "ui.textInput", ["focused"] = focused, ["composing"] = composing })) {
                textInputReported = focused; textCompositionReported = composing;
                keyboard?.SetIMEEnabled(focused);
                if (!focused) imeCursorKeyboard = null;
            }
        }
        void OnVoiceTranscript(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return;
            draft.value = string.IsNullOrWhiteSpace(draft.value) ? text : draft.value + "\n" + text;
            ToggleChat(true); draft.Focus(); UpdateComposer();
        }
        void OpenChatVoice() { ToggleChat(true); root.Q<Button>("chatVoice")?.Focus(); }
        void ToggleChatVoice() {
            OpenChatVoice();
            if (backend is not NativePlayerBackend native) return;
            var operation = ChatVoiceOperation(chatVoiceState);
            if (native.VoiceCommand(operation)) {
                shortcutVoiceActive = operation == "voice.press";
                OnVoiceState(operation == "voice.press" ? "connecting" : operation == "voice.release" ? "transcribing" : "idle", null);
            }
        }
        static string ChatVoiceOperation(string state) => state == "listening" ? "voice.release" :
            state == "connecting" || state == "transcribing" ? "voice.cancel" : "voice.press";
        void OnVoiceState(string state, string errorCode) {
            chatVoiceState = state;
            var voiceButton = root?.Q<Button>("chatVoice");
            voiceButton?.EnableInClassList("selected", state == "listening" || state == "connecting");
            var voiceIcon = voiceButton?.Q<ToolbarIcon>(); if (voiceIcon != null) voiceIcon.Kind = state == "listening" || state == "connecting" || state == "transcribing" ? "stop" : "microphone";
            var voiceLabel = root?.Q<Label>("chatVoiceStatus");
            if (voiceLabel != null) {
                voiceLabel.text = state == "idle" ? "" : state == "listening" ? VoiceListeningHint() : UiLocalization.VoiceStatus(state, errorCode);
                voiceLabel.EnableInClassList("hidden", state == "idle");
                voiceLabel.EnableInClassList("status-error", state == "error");
            }
            if (state == "error") { voiceStatusError = true; OnError(UiLocalization.VoiceStatus(state, errorCode)); }
            else { OnStatus(UiLocalization.VoiceStatus(state, errorCode)); if (voiceStatusError) { voiceStatusError = false; OnError(null); } }
            if (state == "idle" || state == "error") shortcutVoiceActive = false;
        }
        string VoiceReadyHint() => VoiceHint("chatVoiceReady", "语音输入 · 确认文字后发送", "Voice input · review before sending", "音声入力 · 内容を確認して送信");
        string VoiceListeningHint() => VoiceHint("chatVoiceListening", "正在录音 · 点击停止", "Recording · click to stop", "録音中 · クリックして停止");
        string VoiceHint(string key, string zh, string en, string ja) {
            var value = UiLocalization.Get(key); if (!string.IsNullOrEmpty(value)) return value;
            var locale = UiLocalization.LocaleCode ?? "zh-CN"; return locale.StartsWith("ja") ? ja : locale.StartsWith("en") ? en : zh;
        }
        void CancelChatVoice() {
            if (chatVoiceState == "idle" || chatVoiceState == "error") return;
            (backend as NativePlayerBackend)?.VoiceCommand("voice.cancel"); OnVoiceState("idle", null);
        }
        void OnApplicationFocus(bool focused) {
            if (focused) return;
            voiceControl?.Cancel();
            livecamVoiceControl?.Cancel();
            CancelChatVoice();
            shortcutVoiceActive = false;
        }
        void DisposeCharacter() {
            characterLifetime.Cancel();
            if (character != null) character.SelectionCompleted -= OnSelectionCompleted;
            if (character != null) character.ManualMotionCompleted -= OnManualMotionCompleted;
            if (backend is NativePlayerBackend native) {
                native.CharacterSelection -= OnCharacterSelection;
                native.ResidentActivity -= OnResidentActivity;
                native.UiIntent -= OnUiIntent;
                native.BuiltinDevices -= OnBuiltinDevices;
                native.DevicePlacementUpdated -= OnDevicePlacement;
                native.WishUpdated -= OnWishUpdated;
                native.GeneratedAssetsUpdated -= OnGeneratedAssets;
                native.InventoryMutationUpdated -= OnInventoryMutationUpdated;
                native.VoiceStateChanged -= OnVoiceState;
            }
            characterLifetime.Dispose();
            deviceCatalog?.Dispose();
            wishPanel?.Dispose();
            if (worldRuntime != null) worldRuntime.DeviceActivated -= OnDeviceActivated;
            if (worldRuntime != null) worldRuntime.InventoryUpdated -= OnInventoryUpdated;
        }
        void OnBuiltinDevices(JObject catalog) {
            deviceTemplates = catalog["templates"] as JArray ?? new JArray();
            deviceCatalog.SetTemplates(deviceTemplates, UiLocalization.LocaleCode);
            worldRuntime.SetDeviceTemplates(deviceTemplates);
        }
        void OnDevicePlacement(JObject pulse) => worldRuntime?.ApplyDevicePlacement(pulse);
        void OnInventoryUpdated(JArray inventory) => deviceCatalog?.SetInventory(inventory);
        void OnInventoryMutationUpdated(JObject mutation) => worldRuntime?.ApplyInventoryMutation(mutation);
        void OnWishUpdated(JObject pulse) => wishPanel?.Update(pulse);
        void OnGeneratedAssets(JObject catalog) => worldRuntime?.SetGeneratedAssets(catalog);
        void OnDeviceActivated(string objectID) {
            if (objectID == "wish_machine.device") { ClosePopups(); wishPanel?.Show(); }
            else if (objectID == "prop.jukebox") { ClosePopups(); musicLibraryPanel?.SetVisible(true); }
        }
        async void OnCharacterSelection(JObject selection)
        {
            try { await character.ApplySelectionAsync(selection, characterLifetime.Token); }
            catch (OperationCanceledException) { }
            catch (Exception error) { Debug.LogException(error); }
        }
        void OnSelectionCompleted(JObject receipt) {
            receipt["op"] = "presence.runtime.result";
            (backend as NativePlayerBackend)?.SendCommand(receipt);
        }
        void OnManualMotionCompleted(JObject receipt) {
            receipt["op"] = "presence.motion.completed";
            (backend as NativePlayerBackend)?.SendCommand(receipt);
        }
        string lastConfirmedContactKey;
        void OnResidentActivity(JObject activity) {
            activityProjection = activity;
            var objectID = (string)activity["contactConfirmedObjectID"];
            var requestID = (string)activity["requestID"];
            var worldID = (string)activity["worldID"];
            if (worldRuntime == null || string.IsNullOrEmpty(objectID) || string.IsNullOrEmpty(requestID)) return;
            var key = worldID + "|" + requestID + "|" + objectID;
            if (lastConfirmedContactKey == key) return;
            lastConfirmedContactKey = key;
            worldRuntime.PulseDeviceButton(objectID);
        }
        void OnUiIntent(string action) {
            if (action == "toggleStage") worldRuntime?.Toggle();
            else if (action == "toggleLyrics") ToggleLyrics();
            else if (action == "toggleVoice") ToggleChatVoice();
        }
        void OnDestroy() {
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            if (chatImageDropRegionReported) gmgn_unity_chat_image_drop_region(0, 0, 0, 0);
#endif
            imeCompositionBinding?.Dispose();
            (backend as NativePlayerBackend)?.SendCommand(new JObject { ["op"] = "ui.textInput", ["focused"] = false, ["composing"] = false });
            keyboard?.SetIMEEnabled(false);
            DisposeCharacter(); UiLocalization.Changed -= ApplyLocale; voiceControl?.Dispose(); livecamVoiceControl?.Dispose();
            if (compactWindow != null) { compactWindow.ModeChanged -= OnCompactModeChanged; compactWindow.EnterSpaceRequested -= EnterLivecamSpace; }
            if (backend is NativePlayerBackend native) {
                native.VoiceTranscript -= OnVoiceTranscript; native.ScreenVideoUpdated -= OnScreenVideoUpdated;
                native.AutonomousReply -= OnAutonomousReply; native.AutonomyRunningChanged -= OnAutonomyRunningChanged;
                native.WorldSelectionUpdated -= OnWorldSelectionUpdated; native.WishOutputPreviewUpdated -= OnWishOutputPreviewUpdated;
                native.SpatialPresentationUpdated -= OnSpatialPresentationUpdated;
                native.CharacterPositionUpdated -= OnCharacterPositionUpdated;
                native.ChatAttachmentsUpdated -= OnChatAttachmentsUpdated;
                ReleaseChatImageTextures();
            }
            if (worldRuntime != null) { worldRuntime.SelectionPrepared -= OnWorldSelectionPrepared; worldRuntime.ErrorCleared -= OnWorldErrorCleared; worldRuntime.OutputProjectionAck = null; }
            screenVideo?.Dispose(); followScroll?.Pause(); inboxPanel?.Dispose(); queuePanel?.Dispose(); musicLibraryPanel?.Dispose();
            spatialPresentation?.Dispose();
            characterPositionObserver?.Dispose();
            if (keyboard != null) keyboard.onIMECompositionChange -= OnComposition;
            if (backend == null) return;
            backend.Snapshot -= OnSnapshot; backend.Chat -= OnChat; backend.Status -= OnStatus; backend.Error -= OnError; backend.Dispose();
        }

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
                    case "lyrics": Path(2,4,18,4,18,16,2,16,2,4); Path(5,8,15,8); Path(5,12,11,12); break;
                    case "mail": Path(2,4,18,4,18,16,2,16,2,4); Path(2,4,10,11,18,4); break;
                    case "screen": Path(2,3,18,3,18,14,2,14,2,3); Path(10,14,10,18); Path(6,18,14,18); break;
                    case "compact": Path(2,3,18,3,18,17,2,17,2,3); Path(11,10,16,10,16,15,11,15,11,10); break;
                    case "restore": Path(3,8,3,3,8,3); Path(3,3,10,10); Path(12,3,17,3,17,17,3,17,3,12); break;
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
