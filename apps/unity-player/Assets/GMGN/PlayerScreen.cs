using System;
using System.Threading;
using Newtonsoft.Json.Linq;
using GMGN.UnityPlayer.Characters;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    // Unity executes world facts, native visuals and lyrics; GPUI owns every product control.
    public sealed class PlayerScreen : MonoBehaviour
    {
        IPlayerBackend backend;
        NativePlayerBackend native;
        VisualElement root;
        Label lyric, translation;
        Label uiFailure;
        AudioSculpture sculpture;
        PointCloudArtworkLoader pointArtwork;
        GpuLyricsView gpuLyrics;
        GPUIChat2Probe gpuiUI;
        UnityCompactWindowController compactWindow;
        UnityScreenVideoController screenVideo;
        UnitySpatialPresentationController spatialPresentation;
        UnityCharacterPositionObserver characterPositionObserver;
        WorldRuntimeBridge worldRuntime;
        CharacterWorldAdapter character;
        readonly CancellationTokenSource characterLifetime = new();
        JObject activityProjection, pendingWorldSelectionReceipt;
        float nextActivityProjection, nextWorldSelectionReceipt;
        bool lyricsVisible = true, gpuLyricModeReady, connected, spaceVisible, editingReported;
        string nativeStatus, nativeError, gpuLyricStatus, chatVoiceState = "idle", lastConfirmedContactKey;
        const string LyricsVisiblePreference = "gmgn.lyrics.visible";
        // A real GPUI consumed-Escape event, never a guessed old popup state.
        public static int PopupDismissedFrame { get; private set; } = -1;
        public static void ReportGPUIEscapeConsumed() { PopupDismissedFrame = Time.frameCount; }

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
            root = GetComponent<UIDocument>().rootVisualElement; root.AddToClassList("document-root");
            lyric = root.Q<Label>("lyric"); translation = root.Q<Label>("translation");
            lyricsVisible = PlayerPrefs.GetInt(LyricsVisiblePreference, 1) != 0;
            compactWindow = gameObject.AddComponent<UnityCompactWindowController>(); compactWindow.Initialize(root);
            compactWindow.ModeChanged += OnCompactModeChanged; compactWindow.EnterSpaceRequested += EnterLivecamSpace;
            sculpture = gameObject.AddComponent<AudioSculpture>();
            pointArtwork = gameObject.AddComponent<PointCloudArtworkLoader>();
            gpuLyrics = gameObject.AddComponent<GpuLyricsView>();
            try { backend = PlayerBackend.Create?.Invoke(); }
            catch (Exception error) { Debug.LogException(error); OnError("native_host_start_failed"); return; }
            if (backend is not NativePlayerBackend actual) { OnError("native_host_unavailable"); backend?.Dispose(); backend = null; return; }
            native = actual;
            backend.Snapshot += OnSnapshot; backend.Status += OnStatus; backend.Error += OnError;
            screenVideo = gameObject.AddComponent<UnityScreenVideoController>();
            screenVideo.Initialize(root.Q(className: "body")); screenVideo.SetWorldVisible(false);
            native.ScreenVideoUpdated += OnScreenVideoUpdated; native.VoiceStateChanged += OnVoiceState;
            native.ReplySpeechChanged += OnReplySpeechChanged;
            character = FindFirstObjectByType<CharacterWorldAdapter>();
            if (character == null) character = new GameObject("Resident character").AddComponent<CharacterWorldAdapter>();
            native.CharacterSelection += OnCharacterSelection; native.ResidentActivity += OnResidentActivity; native.UiIntent += OnUiIntent;
            character.SelectionCompleted += OnSelectionCompleted; character.ManualMotionCompleted += OnManualMotionCompleted;
            worldRuntime = gameObject.AddComponent<WorldRuntimeBridge>();
            native.WorldSelectionUpdated += OnWorldSelectionUpdated; native.WishOutputPreviewUpdated += OnWishOutputPreviewUpdated;
            worldRuntime.SelectionPrepared += OnWorldSelectionPrepared; worldRuntime.OutputProjectionAck = native.SendCommand;
            worldRuntime.BindCharacter(character); worldRuntime.PlaceDevice = native.SendDevicePlacement;
            native.GeneratedAssetsUpdated += OnGeneratedAssets; native.InventoryMutationUpdated += OnInventoryMutationUpdated;
            native.BuiltinDevices += OnBuiltinDevices; native.DevicePlacementUpdated += OnDevicePlacement;
            worldRuntime.DeviceActivated += OnDeviceActivated; worldRuntime.Initialize(native, sculpture);
            worldRuntime.Status += OnStatus; worldRuntime.Error += OnError; worldRuntime.ErrorCleared += OnWorldErrorCleared;
            worldRuntime.ModeChanged += OnWorldModeChanged;
            spatialPresentation = gameObject.AddComponent<UnitySpatialPresentationController>();
            spatialPresentation.Initialize(root.Q(className: "body"), GetComponent<WorldCameraController>(),
                () => worldRuntime.PresentationWorldID, () => worldRuntime.PresentationVisible && !compactWindow.IsCompact,
                receipt => native.SendCommand(receipt));
            native.SpatialPresentationUpdated += OnSpatialPresentationUpdated;
            characterPositionObserver = gameObject.AddComponent<UnityCharacterPositionObserver>();
            characterPositionObserver.Initialize(character, () => worldRuntime.PresentationWorldID,
                () => worldRuntime.PresentationVisible && !compactWindow.IsCompact,
                () => GetComponent<WorldCameraController>()?.PresentationCamera, receipt => native.SendCommand(receipt));
            native.CharacterPositionUpdated += OnCharacterPositionUpdated;
            gpuiUI = gameObject.AddComponent<GPUIChat2Probe>();
            gpuiUI.Bind(worldRuntime); gpuiUI.BindBackend(native); gpuiUI.Failure += OnError;
            gpuiUI.LocalUICommand = HandleLocalUICommand;
            gpuiUI.LocalUIProjection = () => new JObject {
                ["lyricsVisible"] = lyricsVisible, ["spaceVisible"] = spaceVisible,
                ["fullscreen"] = Screen.fullScreen, ["compact"] = compactWindow.IsCompact,
                ["connected"] = connected, ["status"] = nativeStatus ?? "", ["error"] = nativeError
            };
            connected = true;
            if (Environment.GetEnvironmentVariable("GMGN_UNITY_OPEN_SPACE") == "1") root.schedule.Execute(() => worldRuntime.Toggle());
        }
        bool HandleLocalUICommand(JObject command)
        {
            switch ((string)command["op"]) {
                case "ui.lyrics.toggle": ToggleLyrics(); return true;
                case "ui.space.toggle": if (compactWindow.IsCompact) EnterLivecamSpace(); else worldRuntime.Toggle(); return true;
                case "ui.livecam.space": EnterLivecamSpace(); return true;
                case "ui.window.fullscreen": compactWindow.ToggleFullscreen(); return true;
                case "ui.window.compact": compactWindow.Toggle(); return true;
                case "ui.window.restore": compactWindow.Restore(); return true;
                case "ui.input.escapeConsumed": ReportGPUIEscapeConsumed(); return true;
                default: return false;
            }
        }
        void OnStatus(string value) { nativeStatus = value; }
        void OnError(string value) {
            if (nativeError == value) return;
            nativeError = value;
            if (!string.IsNullOrEmpty(value)) Debug.LogError("GMGN: " + value);
            if (root != null && (gpuiUI == null || !gpuiUI.IsProjectionReady)) {
                if (uiFailure == null) { uiFailure = new Label(); uiFailure.name = "gpuiFailure"; uiFailure.style.color = Color.red; uiFailure.style.whiteSpace = WhiteSpace.Normal; uiFailure.pickingMode = PickingMode.Ignore; root.Add(uiFailure); }
                uiFailure.text = value ?? "";
                uiFailure.style.display = string.IsNullOrEmpty(value) ? DisplayStyle.None : DisplayStyle.Flex;
            }
        }
        void OnWorldErrorCleared(string previousError) { if (nativeError == previousError) OnError(null); }
        void OnWorldModeChanged(bool visible) { spaceVisible = visible; screenVideo?.SetWorldVisible(visible); }
        void OnCompactModeChanged(bool compact) { RefreshLyricVisibility(); }
        void EnterLivecamSpace() { compactWindow.Restore(); if (!spaceVisible) worldRuntime?.Toggle(); }
        void RefreshLyricVisibility()
        {
            bool visible = lyricsVisible && !(compactWindow?.IsCompact ?? false);
            gpuLyrics?.SetVisible(visible && gpuLyricModeReady);
            if (lyric != null) lyric.style.display = visible && !gpuLyricModeReady ? DisplayStyle.Flex : DisplayStyle.None;
            if (translation != null) translation.style.display = visible && !gpuLyricModeReady ? DisplayStyle.Flex : DisplayStyle.None;
        }
        void ToggleLyrics() { lyricsVisible = !lyricsVisible; PlayerPrefs.SetInt(LyricsVisiblePreference, lyricsVisible ? 1 : 0); PlayerPrefs.Save(); RefreshLyricVisibility(); }
        void OnSnapshot(PlayerSnapshot snapshot)
        {
            if (!string.IsNullOrEmpty(snapshot.locale) && snapshot.locale != UiLocalization.LocaleCode) UiLocalization.SelectHostLocale(snapshot.locale);
            lyric.text = snapshot.lyric ?? ""; translation.text = snapshot.translation ?? "";
            var lyricMode = snapshot.lyricVisual?.mode;
            gpuLyrics.SetTheme(snapshot.lyricVisual?.theme);
            gpuLyrics.SetLyrics(snapshot.sessionId, snapshot.lyricRevision, snapshot.lyricLines, lyricMode ?? "");
            gpuLyrics.SetPlayback(snapshot.position, snapshot.bass, snapshot.vocal, snapshot.treble);
            gpuLyricModeReady = gpuLyrics.SupportsMode(lyricMode ?? ""); RefreshLyricVisibility();
            if (!gpuLyricModeReady && gpuLyricStatus != lyricMode) { gpuLyricStatus = lyricMode; OnStatus("当前歌词风格的 GPU 渲染尚未完成迁移。"); }
            sculpture.SetFeatures(snapshot.playing, snapshot.bass, snapshot.vocal, snapshot.treble);
            if (snapshot.pointCloud is { } points) {
                var weights = Components(points.presetWeights);
                sculpture.SetVisual(points.choice, points.intensity, points.particleSize, new Vector3(weights.x, weights.y, weights.z), points.composition);
                sculpture.SetRhythm(Components(points.rhythm), Components(points.waveA), Components(points.waveB));
                pointArtwork.Load(points.artworkURL);
            }
        }
        static Vector4 Components(float[] v) => new Vector4(v != null && v.Length > 0 ? v[0] : 0, v != null && v.Length > 1 ? v[1] : 0, v != null && v.Length > 2 ? v[2] : 0, v != null && v.Length > 3 ? v[3] : 0);
        void Update()
        {
            if (uiFailure != null && gpuiUI?.IsProjectionReady == true) uiFailure.style.display = DisplayStyle.None;
            if (pendingWorldSelectionReceipt != null && Time.unscaledTime >= nextWorldSelectionReceipt) TrySendWorldSelectionReceipt();
            if (native != null) {
                bool editing = worldRuntime != null && worldRuntime.IsEditing;
                if (editing != editingReported && native.SendCommand(new JObject { ["op"] = "resident.autonomy.editing", ["editing"] = editing })) editingReported = editing;
            }
            backend?.Tick();
            if (character != null && activityProjection != null && Time.unscaledTime >= nextActivityProjection) {
                nextActivityProjection = Time.unscaledTime + .2f;
                var receipt = character.ApplyResidentActivity(activityProjection);
                if (receipt != null && native != null) { receipt["op"] = "activity.projected"; native.SendCommand(receipt); }
            }
        }
        void OnScreenVideoUpdated(JObject value) => screenVideo?.ApplySnapshot(value);
        void OnSpatialPresentationUpdated(JObject value) => spatialPresentation?.ApplySnapshot(value);
        void OnCharacterPositionUpdated(JObject value) => characterPositionObserver?.ApplySnapshot(value);
        void OnWorldSelectionUpdated(JObject value) => worldRuntime?.ApplyWorldSelection(value);
        void OnWishOutputPreviewUpdated(JObject value) => worldRuntime?.SetWishOutputPreview(value);
        void OnWorldSelectionPrepared(JObject receipt) { receipt["op"] = "world.selection.prepared"; pendingWorldSelectionReceipt = receipt; TrySendWorldSelectionReceipt(); }
        void TrySendWorldSelectionReceipt()
        {
            if (pendingWorldSelectionReceipt == null || native == null) return;
            nextWorldSelectionReceipt = Time.unscaledTime + .25f;
            if (native.SendCommand(pendingWorldSelectionReceipt)) pendingWorldSelectionReceipt = null;
        }
        void OnBuiltinDevices(JObject catalog) => worldRuntime?.SetDeviceTemplates(catalog["templates"] as JArray ?? new JArray());
        void OnDevicePlacement(JObject pulse) => worldRuntime?.ApplyDevicePlacement(pulse);
        void OnInventoryMutationUpdated(JObject mutation) => worldRuntime?.ApplyInventoryMutation(mutation);
        void OnGeneratedAssets(JObject catalog) => worldRuntime?.SetGeneratedAssets(catalog);
        void OnDeviceActivated(string objectID)
        {
            var pane = objectID == "wish_machine.device" ? "愿望" : objectID == "prop.jukebox" ? "音乐" : null;
            if (pane != null && gpuiUI?.OpenPanel(pane) != true) OnError("gpui_device_panel_unavailable");
        }
        async void OnCharacterSelection(JObject selection)
        {
            try { await character.ApplySelectionAsync(selection, characterLifetime.Token); }
            catch (OperationCanceledException) { }
            catch (Exception error) { Debug.LogException(error); }
        }
        void OnSelectionCompleted(JObject receipt) { receipt["op"] = "presence.runtime.result"; native?.SendCommand(receipt); }
        void OnManualMotionCompleted(JObject receipt) { receipt["op"] = "presence.motion.completed"; native?.SendCommand(receipt); }
        void OnResidentActivity(JObject activity)
        {
            activityProjection = activity;
            string objectID = (string)activity["contactConfirmedObjectID"], requestID = (string)activity["requestID"], worldID = (string)activity["worldID"];
            if (worldRuntime == null || string.IsNullOrEmpty(objectID) || string.IsNullOrEmpty(requestID)) return;
            var key = worldID + "|" + requestID + "|" + objectID;
            if (lastConfirmedContactKey == key) return;
            lastConfirmedContactKey = key; worldRuntime.PulseDeviceButton(objectID);
        }
        void OnReplySpeechChanged(bool playing, float level)
        {
            if (character != null && character.Runtime != null) character.Runtime.SetSpeechLevel(playing, level);
#if GMGN_UNIVRM
            if (character != null && character.VrmRuntime != null) character.VrmRuntime.SetSpeechLevel(playing, level);
#endif
        }
        void OnVoiceState(string state, string errorCode) { chatVoiceState = state; if (state == "error") OnError(errorCode); }
        static string ChatVoiceOperation(string state) => state == "listening" ? "voice.release" : state == "connecting" || state == "transcribing" ? "voice.cancel" : "voice.press";
        void ToggleChatVoice()
        {
            if (gpuiUI?.OpenChat() != true) { OnError("gpui_chat_unavailable"); return; }
            if (native?.VoiceCommand(ChatVoiceOperation(chatVoiceState)) != true) OnError("voice_command_not_accepted");
        }
        void OnUiIntent(string action)
        {
            if (action == "toggleStage") worldRuntime?.Toggle();
            else if (action == "toggleLyrics") ToggleLyrics();
            else if (action == "toggleVoice") ToggleChatVoice();
        }
        void OnApplicationFocus(bool focused) { if (!focused) native?.VoiceCommand("voice.cancel"); }
        void OnDestroy()
        {
            characterLifetime.Cancel();
            if (character != null) { character.SelectionCompleted -= OnSelectionCompleted; character.ManualMotionCompleted -= OnManualMotionCompleted; }
            if (compactWindow != null) { compactWindow.ModeChanged -= OnCompactModeChanged; compactWindow.EnterSpaceRequested -= EnterLivecamSpace; }
            if (gpuiUI != null) { gpuiUI.Failure -= OnError; gpuiUI.Shutdown(); }
            if (native != null) {
                native.ScreenVideoUpdated -= OnScreenVideoUpdated; native.VoiceStateChanged -= OnVoiceState; native.ReplySpeechChanged -= OnReplySpeechChanged;
                native.CharacterSelection -= OnCharacterSelection; native.ResidentActivity -= OnResidentActivity; native.UiIntent -= OnUiIntent;
                native.WorldSelectionUpdated -= OnWorldSelectionUpdated; native.WishOutputPreviewUpdated -= OnWishOutputPreviewUpdated;
                native.GeneratedAssetsUpdated -= OnGeneratedAssets; native.InventoryMutationUpdated -= OnInventoryMutationUpdated;
                native.BuiltinDevices -= OnBuiltinDevices; native.DevicePlacementUpdated -= OnDevicePlacement;
                native.SpatialPresentationUpdated -= OnSpatialPresentationUpdated; native.CharacterPositionUpdated -= OnCharacterPositionUpdated;
                native.SendCommand(new JObject { ["op"] = "ui.textInput", ["focused"] = false, ["composing"] = false });
            }
            if (worldRuntime != null) {
                worldRuntime.SelectionPrepared -= OnWorldSelectionPrepared; worldRuntime.DeviceActivated -= OnDeviceActivated;
                worldRuntime.Status -= OnStatus; worldRuntime.Error -= OnError; worldRuntime.ErrorCleared -= OnWorldErrorCleared;
                worldRuntime.ModeChanged -= OnWorldModeChanged; worldRuntime.OutputProjectionAck = null;
            }
            screenVideo?.Dispose(); spatialPresentation?.Dispose(); characterPositionObserver?.Dispose(); characterLifetime.Dispose();
            if (backend != null) { backend.Snapshot -= OnSnapshot; backend.Status -= OnStatus; backend.Error -= OnError; backend.Dispose(); }
        }
    }
}
