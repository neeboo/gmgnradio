using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using System.Text;
using System.Runtime.InteropServices;
using UnityEngine;
using Newtonsoft.Json.Linq;

namespace GMGN.UnityPlayer
{
    public sealed class NativePlayerBackend : IPlayerBackend
    {
        const string Library = "UnityMediaHost";
        [DllImport(Library)] static extern IntPtr gmgn_unity_host_create([MarshalAs(UnmanagedType.LPUTF8Str)] string root, [MarshalAs(UnmanagedType.LPUTF8Str)] string suite);
        [DllImport(Library)] static extern int gmgn_unity_host_command(IntPtr host, [MarshalAs(UnmanagedType.LPUTF8Str)] string command);
        [DllImport(Library)] static extern int gmgn_unity_host_placement(IntPtr host, byte[] bytes, int count);
        [DllImport(Library)] static extern int gmgn_unity_host_device_placement(IntPtr host, byte[] bytes, int count);
        [DllImport(Library)] static extern IntPtr gmgn_unity_host_snapshot(IntPtr host);
        [DllImport(Library)] static extern void gmgn_unity_host_string_free(IntPtr value);
        [DllImport(Library)] static extern int gmgn_unity_host_destroy(IntPtr host);
        [Serializable] sealed class Envelope { public string locale; public Music music; public Conversation chat; public WorldPulse world, musicLibrary, inbox; public Voice voice; }
        [Serializable] sealed class Voice { public string state, errorCode, transcript; public ulong transcriptRevision; }
        [Serializable] sealed class WorldPulse { public ulong generation; public bool pending; public string status; }
        [Serializable] sealed class Music { public ulong playbackSessionID; public string title, notice, noticeSeverity; public double duration, position; public bool isPlaying, canNext, canPrevious, seekSupported; public int queueIndex, queueCount; public QueueItem[] queue; public float volume; public Features features; public long lyricRevision; public LyricVisualSnapshot lyricVisual; public PointCloudSnapshot pointCloud; public LyricPointLine[] lines; }
        [Serializable] sealed class Features { public float low, mid, high, bass, vocal, treble; }
        [Serializable] sealed class Conversation { public Event[] events; public ChatState state; }
        [Serializable] sealed class ChatState { public string failureCode; }
        [Serializable] sealed class Event { public string kind, text, message; public ulong requestID; }
        [Serializable] sealed class Command { public string op, text, path, lyricPath; public ulong requestID; public int index; public bool autoplay; public double value; }
        readonly Dictionary<ulong, string> requestIds = new();
        IntPtr host;
        ulong sequence;
        LyricPointLine[] lyrics = Array.Empty<LyricPointLine>();
        QueueItem[] musicQueue = Array.Empty<QueueItem>();
        ulong? lyricSession;
        long lyricRevision = -1;
        float nextPoll;
        bool playing;
        bool nextSupported, previousSupported;
        ulong? worldGeneration;
        ulong? musicLibraryGeneration;
        ulong? inboxGeneration;
        ulong voiceTranscriptRevision;
        string voiceState, voiceError;
        ulong selectionRevision, uiIntentRevision;
        ulong? devicePlacementGeneration;
        ulong? wishGeneration;
        ulong? inventoryMutationGeneration;
        public event Action<JObject> InventoryMutationUpdated;
        public event Action<JObject> WishUpdated;
        public event Action<JObject> GeneratedAssetsUpdated;
        readonly World.GeneratedAssetProjectionGate generatedAssetProjection = new();
        public event Action<JObject> BuiltinDevices;
        public event Action<JObject> DevicePlacementUpdated;
        string deviceCatalogFingerprint;
        public event Action<JObject> CharacterSelection;
        public event Action<JObject> ResidentActivity;
        public event Action<JObject> SpatialPresentationUpdated;
        public event Action<JObject> CharacterPositionUpdated;
        public event Action<JObject> ChatAttachmentsUpdated;
        public JObject ChatAttachments { get; private set; }
        ulong? chatAttachmentsGeneration;
        string spatialPresentationFingerprint;
        string characterPositionFingerprint;
        public event Action<string> UiIntent;
        public bool SendCommand(JObject command) => ExecuteWorld(command);
        public bool SendDevicePlacement(JObject command)
        {
            if (host == IntPtr.Zero || command == null || (string)command["op"] != "world.device.place"
                || Interlocked.CompareExchange(ref placementSerializationPending, 1, 0) != 0) return false;
            var requestID = (string)command["requestID"];
            Task.Run(() => {
                try {
                    var bytes = Encoding.UTF8.GetBytes(command.ToString(Newtonsoft.Json.Formatting.None));
                    placementCommands.Enqueue((bytes.Length <= 64 * 1024 * 1024 ? bytes : null, "world.device.place", requestID,
                        bytes.Length <= 64 * 1024 * 1024 ? null : "payload_too_large"));
                } catch (Exception error) { placementCommands.Enqueue((null, "world.device.place", requestID, error.GetType().Name)); }
            });
            return true;
        }
        public event Action<JObject> ScreenVideoUpdated;
        public event Action<string, ulong> AutonomousReply;
        public event Action<bool> AutonomyRunningChanged;
        public event Action<bool, float> ReplySpeechChanged;
        public event Action<JObject> WorldSelectionUpdated;
        public event Action<JObject> WishOutputPreviewUpdated;
        ulong? wishOutputPreviewGeneration;
        string wishOutputPreviewWorldID;
        ulong? worldSelectionRevision;
        string worldSelectionPhase;
        ulong autonomousReplyRevision;
        bool autonomyRunning;
        string chatFailureCode;
        public event Action<string> VoiceTranscript;
        public event Action<string, string> VoiceStateChanged;
        public bool VoiceCommand(string operation) => ExecuteWorld(new JObject { ["op"] = operation });
        public event Action<JObject> InboxUpdated;
        public bool RequestInbox() => ExecuteWorld(new JObject { ["op"] = "inbox.list", ["requestID"] = "unity-inbox:" + Guid.NewGuid().ToString("D") });
        public bool MarkInboxRead(string taskKey, string expectedEventID) => ExecuteWorld(new JObject {
            ["op"] = "inbox.read", ["requestID"] = "unity-inbox:" + Guid.NewGuid().ToString("D"),
            ["taskKey"] = taskKey, ["expectedEventID"] = expectedEventID });
        public event Action<JObject> MusicLibraryUpdated;
        public bool RequestMusicLibrary() => ExecuteWorld(new JObject { ["op"] = "music.library" });
        public bool RequestMusicPlaylist(string id) => ExecuteWorld(new JObject { ["op"] = "music.playlist", ["playlistID"] = id });
        public bool PlayMusicPlaylistTrack(string id, int index) => ExecuteWorld(new JObject { ["op"] = "music.playlist.play", ["playlistID"] = id, ["index"] = index });
        public JObject WorldProjection { get; private set; }
        public event Action<JObject> WorldUpdated;
        public event Action<JObject> PlacementEvaluated;
        public event Action<JObject> PlacementDerived;
        readonly ConcurrentQueue<(byte[] bytes, string operation, string requestID, string error)> placementCommands = new();
        int placementSerializationPending;
        // Ownership is transferred: callers must not mutate payload after acceptance.
        // Serialization is background work; the Swift MainActor ABI is only called by Tick.
        bool QueuePlacement(JObject payload, string requestID, string operation)
        {
            var worldID = (string)WorldProjection?["worldID"];
            if (host == IntPtr.Zero || payload == null || string.IsNullOrWhiteSpace(requestID)
                || string.IsNullOrWhiteSpace(worldID) || Interlocked.CompareExchange(ref placementSerializationPending, 1, 0) != 0) return false;
            Task.Run(() => {
                try {
                    var command = new JObject { ["op"] = operation, ["worldID"] = worldID,
                        ["requestID"] = requestID, ["payload"] = payload };
                    var bytes = Encoding.UTF8.GetBytes(command.ToString(Newtonsoft.Json.Formatting.None));
                    placementCommands.Enqueue((bytes.Length <= 64 * 1024 * 1024 ? bytes : null, operation, requestID,
                        bytes.Length <= 64 * 1024 * 1024 ? null : "payload_too_large"));
                } catch (Exception error) {
                    placementCommands.Enqueue((null, operation, requestID, error.GetType().Name));
                }
            });
            return true;
        }
        public bool RequestPlacementDerivation(JObject payload, string requestID)
        {
            return QueuePlacement(payload, requestID, "world.placement.derive");
        }
        public bool RequestPlacementEvaluation(JObject payload, string requestID)
        {
            return QueuePlacement(payload, requestID, "world.placement.evaluate");
        }
        public bool RequestWorldSnapshot(string worldID) => ExecuteWorld(new JObject { ["op"] = "world.snapshot", ["worldID"] = worldID });
        public bool CommitWorld(string worldID, string requestID, ulong expectedRevision, JObject state, JObject intent)
            => ExecuteWorld(new JObject { ["op"] = "world.commit", ["worldID"] = worldID, ["requestID"] = requestID,
                ["expectedRevision"] = expectedRevision, ["state"] = state, ["intent"] = intent });
        bool ExecuteWorld(JObject command) => host != IntPtr.Zero && gmgn_unity_host_command(host, command.ToString(Newtonsoft.Json.Formatting.None)) == 1;
        public event Action<PlayerSnapshot> Snapshot;
        public event Action<ChatUpdate> Chat;
        public event Action<string> Status;
        public event Action<string> Error;
        string lastMusicNotice, lastMusicSeverity;
        public string DataRoot { get; }
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Register() => PlayerBackend.Create = () => new NativePlayerBackend();
        public NativePlayerBackend()
        {
            var root = Environment.GetEnvironmentVariable("GMGN_UNITY_DATA_ROOT");
            if (string.IsNullOrEmpty(root)) {
                // The macOS host consumes the original product support root.
                // Tests retain explicit isolation through GMGN_UNITY_DATA_ROOT.
                root = Application.platform == RuntimePlatform.OSXPlayer || Application.platform == RuntimePlatform.OSXEditor
                    ? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support")
                    : Application.persistentDataPath;
            }
            System.IO.Directory.CreateDirectory(root);
            DataRoot = System.IO.Path.GetFullPath(root);
            host = gmgn_unity_host_create(DataRoot, "ai.gmgn.unity-sample.player.preferences");
            if (host == IntPtr.Zero) throw new InvalidOperationException("无法启动隔离音乐与对话服务。");
            var path = Environment.GetEnvironmentVariable("GMGN_UNITY_MUSIC_PATH");
            if (!string.IsNullOrEmpty(path)) {
                var lyricPath = Environment.GetEnvironmentVariable("GMGN_UNITY_LRC_PATH");
                // JsonUtility serializes an unset string as empty, not JSON null.
                if (string.IsNullOrEmpty(lyricPath)) lyricPath = System.IO.Path.ChangeExtension(path, ".lrc");
                if (!Execute(new Command { op = "music.load", path = path, lyricPath = lyricPath, autoplay = true }))
                    Debug.LogWarning("启动音乐未载入；请通过选择音乐重试。");
            }
        }
        bool Execute(Command command) => gmgn_unity_host_command(host, JsonUtility.ToJson(command)) == 1;
        public void Tick()
        {
            if (placementCommands.TryDequeue(out var placement)) {
                Interlocked.Exchange(ref placementSerializationPending, 0);
                if (placement.error != null || host == IntPtr.Zero ||
                    (placement.operation == "world.device.place"
                        ? gmgn_unity_host_device_placement(host, placement.bytes, placement.bytes.Length)
                        : gmgn_unity_host_placement(host, placement.bytes, placement.bytes.Length)) != 1) {
                    var failed = new JObject { ["operation"] = placement.operation, ["requestID"] = placement.requestID,
                        ["status"] = "failed", ["code"] = placement.error != null ? "serialization_failed" : "placement_not_accepted",
                        ["message"] = "摆放校验未能开始，请稍后重试。" };
                    if (placement.operation == "world.placement.derive") PlacementDerived?.Invoke(failed);
                    else if (placement.operation == "world.device.place") DevicePlacementUpdated?.Invoke(failed);
                    else PlacementEvaluated?.Invoke(failed);
                }
            }
            if (Time.unscaledTime < nextPoll) return;
            nextPoll = Time.unscaledTime + .05f;
            var pointer = gmgn_unity_host_snapshot(host); if (pointer == IntPtr.Zero) return;
            Envelope value; string json;
            try { json = Marshal.PtrToStringUTF8(pointer); value = JsonUtility.FromJson<Envelope>(json); }
            finally { gmgn_unity_host_string_free(pointer); }
            var projection = JObject.Parse(json);
            if (projection["characterPosition"] is JObject characterPosition) {
                var fingerprint = characterPosition.ToString(Newtonsoft.Json.Formatting.None);
                if (characterPositionFingerprint != fingerprint) {
                    characterPositionFingerprint = fingerprint;
                    CharacterPositionUpdated?.Invoke(characterPosition);
                }
            }
            if (projection["spatialPresentation"] is JObject spatialPresentation) {
                var fingerprint = spatialPresentation.ToString(Newtonsoft.Json.Formatting.None);
                if (spatialPresentationFingerprint != fingerprint) {
                    spatialPresentationFingerprint = fingerprint;
                    SpatialPresentationUpdated?.Invoke(spatialPresentation);
                }
            }
            string nextChatFailure = value.chat?.state?.failureCode;
            if (chatFailureCode != nextChatFailure) {
                chatFailureCode = nextChatFailure;
                if (!string.IsNullOrEmpty(chatFailureCode)) Debug.LogWarning("[UnityChat] failure code=" + chatFailureCode);
            }
            if (projection["wishOutputPreview"] is JObject wishOutputPreview && (ulong?)wishOutputPreview["generation"] is ulong outputGeneration) {
                string outputWorldID = (string)wishOutputPreview["worldID"];
                if (wishOutputPreviewGeneration != outputGeneration || wishOutputPreviewWorldID != outputWorldID) {
                    wishOutputPreviewGeneration = outputGeneration; wishOutputPreviewWorldID = outputWorldID;
                    WishOutputPreviewUpdated?.Invoke(wishOutputPreview);
                }
            }
            if (projection["worldSelection"] is JObject worldSelection) {
                ulong selectionEpoch = (ulong?)worldSelection["revision"] ?? 0;
                string phase = (string)worldSelection["phase"];
                if (worldSelectionRevision != selectionEpoch || worldSelectionPhase != phase) {
                    worldSelectionRevision = selectionEpoch; worldSelectionPhase = phase;
                    Debug.Log($"World selection: worldID={(string)worldSelection["worldID"]}; revision={selectionEpoch}; phase={phase}; code={(string)worldSelection["code"]}; message={(string)worldSelection["message"]}");
                    WorldSelectionUpdated?.Invoke(worldSelection);
                }
            }
            if (projection["replySpeech"] is JObject speech)
                ReplySpeechChanged?.Invoke((bool?)speech["isPlaying"] ?? false, (float?)speech["level"] ?? 0);
            if (projection["chat"] is JObject conversation) {
                bool running = (bool?)conversation["autonomy"]?["isRunning"] ?? false;
                if (running != autonomyRunning) { autonomyRunning = running; AutonomyRunningChanged?.Invoke(running); }
                if (conversation["autonomousReplies"] is JArray replies) foreach (var reply in replies) {
                    ulong replyRevision = (ulong?)reply["revision"] ?? 0;
                    if (replyRevision <= autonomousReplyRevision) continue;
                    autonomousReplyRevision = replyRevision;
                    string text = (string)reply["text"];
                    if (!string.IsNullOrWhiteSpace(text)) AutonomousReply?.Invoke(text, replyRevision);
                }
            }
            if (projection["chatAttachments"] is JObject attachments) {
                ApplyChatAttachmentsSnapshot(attachments);
            }
            if (projection["screenVideo"] is JObject screenVideo) ScreenVideoUpdated?.Invoke(screenVideo);
            if (projection["inventoryMutation"] is JObject mutation && (ulong?)mutation["generation"] is ulong mutationRevision && inventoryMutationGeneration != mutationRevision) {
                inventoryMutationGeneration = mutationRevision; InventoryMutationUpdated?.Invoke(mutation);
            }
            if (projection["generatedAssets"] is JObject assets && (ulong?)assets["generation"] is ulong && generatedAssetProjection.Accept(assets)) {
                GeneratedAssetsUpdated?.Invoke(assets);
            }
            if (projection["wish"] is JObject wish && (ulong?)wish["generation"] is ulong wishRevision && wishGeneration != wishRevision) {
                wishGeneration = wishRevision; WishUpdated?.Invoke(wish);
            }
            if (projection["builtinDevices"] is JObject catalog) {
                var fingerprint = catalog.ToString(Newtonsoft.Json.Formatting.None);
                if (fingerprint != deviceCatalogFingerprint) { deviceCatalogFingerprint = fingerprint; BuiltinDevices?.Invoke(catalog); }
            }
            if (projection["devicePlacement"] is JObject devicePulse && (ulong?)devicePulse["generation"] is ulong deviceRevision && devicePlacementGeneration != deviceRevision) {
                devicePlacementGeneration = deviceRevision;
                DevicePlacementUpdated?.Invoke(devicePulse);
            }
            if (projection["selection"] is JObject selection && (ulong?)selection["revision"] is ulong revision && revision > selectionRevision) {
                selectionRevision = revision;
                CharacterSelection?.Invoke(selection);
            }
            if (projection["activity"] is JObject activity) ResidentActivity?.Invoke(activity);
            if (projection["uiIntents"] is JArray intents) {
                foreach (var item in intents) {
                    var intentRevision = (ulong?)item["revision"] ?? 0;
                    if (intentRevision <= uiIntentRevision) continue;
                    UiIntent?.Invoke((string)item["action"]);
                    uiIntentRevision = intentRevision;
                }
                if (intents.Count > 0) ExecuteWorld(new JObject { ["op"] = "ui.intent.ack", ["revision"] = uiIntentRevision });
            }
            if (value.voice != null) {
                if (voiceState != value.voice.state || voiceError != value.voice.errorCode) {
                    voiceState = value.voice.state; voiceError = value.voice.errorCode;
                    VoiceStateChanged?.Invoke(voiceState, voiceError);
                }
                if (value.voice.transcriptRevision > voiceTranscriptRevision) {
                    voiceTranscriptRevision = value.voice.transcriptRevision;
                    if (!string.IsNullOrWhiteSpace(value.voice.transcript)) VoiceTranscript?.Invoke(value.voice.transcript);
                }
            }
            if (value.inbox != null && inboxGeneration != value.inbox.generation) {
                inboxGeneration = value.inbox.generation;
                var notification = JObject.Parse(json)["inbox"] as JObject;
                if (notification != null) InboxUpdated?.Invoke(notification);
            }
            if (value.musicLibrary != null && musicLibraryGeneration != value.musicLibrary.generation) {
                musicLibraryGeneration = value.musicLibrary.generation;
                var library = JObject.Parse(json)["musicLibrary"] as JObject;
                if (library != null) MusicLibraryUpdated?.Invoke(library);
            }
            if (value.world != null && worldGeneration != value.world.generation) {
                worldGeneration = value.world.generation;
                var update = JObject.Parse(json)["world"] as JObject;
                if (update != null && update["status"] != null) {
                    if ((string)update["operation"] == "world.placement.evaluate") {
                        PlacementEvaluated?.Invoke(update);
                    } else if ((string)update["operation"] == "world.placement.derive") {
                        PlacementDerived?.Invoke(update);
                    } else {
                        WorldProjection = update;
                        WorldUpdated?.Invoke(update);
                    }
                }
            }
            if (value.music != null) {
                var music = value.music; playing = music.isPlaying;
                nextSupported = music.canNext; previousSupported = music.canPrevious;
                if (music.queue != null) musicQueue = music.queue;
                if (lyricSession != music.playbackSessionID || lyricRevision != music.lyricRevision) {
                    // Clear old track data even when a new timeline is not ready.
                    lyricSession = music.playbackSessionID; lyricRevision = music.lyricRevision;
                    lyrics = music.lines ?? Array.Empty<LyricPointLine>();
                } else if (music.lines != null) lyrics = music.lines;
                string lyric = "", translation = "";
                foreach (var line in lyrics) { if (music.position >= line.startsAt && music.position < line.endsAt) { lyric = line.text; translation = line.translation; break; } }
                Snapshot?.Invoke(new PlayerSnapshot { locale = value.locale ?? "zh-CN", sessionId = music.playbackSessionID.ToString(), title = music.title, duration = music.duration, position = music.position, playing = music.isPlaying, nextSupported = music.canNext, previousSupported = music.canPrevious, seekSupported = music.seekSupported, volume = music.volume, lyric = lyric, translation = translation, lyricRevision = music.lyricRevision, lyricLines = lyrics, lyricVisual = music.lyricVisual, pointCloud = music.pointCloud, queueIndex = music.queueIndex, queueCount = music.queueCount, queue = musicQueue, bass = music.features?.bass ?? 0, vocal = music.features?.vocal ?? 0, treble = music.features?.treble ?? 0 });
                var severity = music.noticeSeverity;
                if (music.notice != lastMusicNotice || severity != lastMusicSeverity) {
                    lastMusicNotice = music.notice; lastMusicSeverity = severity;
                    if (severity == "error") Error?.Invoke(music.notice);
                    else { Error?.Invoke(null); if (!string.IsNullOrEmpty(music.notice)) Status?.Invoke(music.notice); }
                }
            }
            if (value.chat?.events == null) return;
            foreach (var item in value.chat.events) {
                if (!requestIds.TryGetValue(item.requestID, out var id)) { Debug.LogWarning($"[UnityChat] unmatched_event kind={item.kind} request={item.requestID}"); continue; }
                if (item.kind != "delta") Debug.Log($"[UnityChat] event kind={item.kind} request={item.requestID}");
                if (item.kind == "accepted") {
                    Chat?.Invoke(new ChatUpdate { messageId = id, text = UiLocalization.Get("chatAccepted"), complete = false });
                } else if (item.kind == "delta") {
                    Chat?.Invoke(new ChatUpdate { messageId = id, text = item.text ?? "", complete = false });
                } else if (item.kind == "reply" || item.kind == "failure" || item.kind == "cancelled") {
                    Chat?.Invoke(new ChatUpdate { messageId = id, text = item.text ?? item.message ?? "", error = item.kind == "failure" ? item.message : null, complete = true });
                    requestIds.Remove(item.requestID);
                }
            }
        }
        public void PlayPause() => Execute(new Command { op = playing ? "music.pause" : "music.play" });
        void ApplyChatAttachmentsSnapshot(JObject attachments)
        {
            if ((ulong?)attachments["generation"] is not ulong revision || chatAttachmentsGeneration == revision) return;
            chatAttachmentsGeneration = revision; ChatAttachments = attachments;
            ChatAttachmentsUpdated?.Invoke(attachments);
        }
        public void ChooseMusic() => Execute(new Command { op = "music.choose" });
        public void Next() => Navigate("music.next", nextSupported, "当前歌单没有下一首。");
        public void Previous() => Navigate("music.previous", previousSupported, "当前歌单没有上一首。");
        void Navigate(string operation, bool supported, string unavailable)
        {
            if (!supported) { Status?.Invoke(unavailable); return; }
            if (!Execute(new Command { op = operation })) Error?.Invoke("暂时无法切换歌曲，请稍后重试。");
        }
        public void SelectQueueItem(int index) { if (!Execute(new Command { op = "music.select", index = index })) Error?.Invoke("这首音乐暂时无法播放，请重新选择音乐。"); }
        public void OpenSettings() { if (!Execute(new Command { op = "settings.open" })) Error?.Invoke("设置面板暂时无法打开。"); }
        public void Seek(double seconds) => Status?.Invoke("当前音乐后端尚未提供跳转。");
        public void SetVolume(float volume) => Execute(new Command { op = "music.volume", value = volume });
        public void Send(string messageId, string text) { var id = ++sequence; requestIds[id] = messageId; var accepted = Execute(new Command { op = "chat.send", requestID = id, text = text }); Debug.Log($"[UnityChat] native_command accepted={accepted} request={id}"); if (!accepted) { requestIds.Remove(id); Chat?.Invoke(new ChatUpdate { messageId = messageId, error = "消息未发送，请重试。", complete = true }); } }
        public void SendWithAttachments(string messageId, string text, JArray attachmentIDs, ulong generation) {
            var id = ++sequence; requestIds[id] = messageId;
            bool accepted = ExecuteWorld(new JObject { ["op"] = "chat.send", ["requestID"] = id, ["text"] = text,
                ["attachmentIDs"] = attachmentIDs.DeepClone(), ["attachmentGeneration"] = generation });
            if (!accepted) { requestIds.Remove(id); Chat?.Invoke(new ChatUpdate { messageId = messageId, error = "消息未发送，请重试。", complete = true }); }
        }
        public void Cancel(string messageId) { foreach (var pair in requestIds) if (pair.Value == messageId) { Execute(new Command { op = "chat.cancel", requestID = pair.Key }); break; } }
        public void Dispose() { if (host != IntPtr.Zero) gmgn_unity_host_destroy(host); host = IntPtr.Zero; }
    }
}
