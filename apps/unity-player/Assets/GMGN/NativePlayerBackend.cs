using System;
using System.Collections.Generic;
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
        [DllImport(Library)] static extern IntPtr gmgn_unity_host_snapshot(IntPtr host);
        [DllImport(Library)] static extern void gmgn_unity_host_string_free(IntPtr value);
        [DllImport(Library)] static extern int gmgn_unity_host_destroy(IntPtr host);
        [Serializable] sealed class Envelope { public Music music; public Conversation chat; public WorldPulse world; }
        [Serializable] sealed class WorldPulse { public ulong generation; public bool pending; public string status; }
        [Serializable] sealed class Music { public ulong playbackSessionID; public string title, notice; public double duration, position; public bool isPlaying, canNext, canPrevious, seekSupported; public int queueIndex, queueCount; public QueueItem[] queue; public float volume; public Features features; public Line[] lines; }
        [Serializable] sealed class Features { public float low, mid, high; }
        [Serializable] sealed class Line { public string text; public double start, end; }
        [Serializable] sealed class Conversation { public Event[] events; }
        [Serializable] sealed class Event { public string kind, text, message; public ulong requestID; }
        [Serializable] sealed class Command { public string op, text, path, lyricPath; public ulong requestID; public int index; public bool autoplay; public double value; }
        readonly Dictionary<ulong, string> requestIds = new();
        IntPtr host;
        ulong sequence;
        Line[] lyrics = Array.Empty<Line>();
        float nextPoll;
        bool playing;
        ulong? worldGeneration;
        public JObject WorldProjection { get; private set; }
        public event Action<JObject> WorldUpdated;
        public bool RequestWorldSnapshot(string worldID) => ExecuteWorld(new JObject { ["op"] = "world.snapshot", ["worldID"] = worldID });
        public bool CommitWorld(string worldID, string requestID, ulong expectedRevision, JObject state, JObject intent)
            => ExecuteWorld(new JObject { ["op"] = "world.commit", ["worldID"] = worldID, ["requestID"] = requestID,
                ["expectedRevision"] = expectedRevision, ["state"] = state, ["intent"] = intent });
        bool ExecuteWorld(JObject command) => host != IntPtr.Zero && gmgn_unity_host_command(host, command.ToString(Newtonsoft.Json.Formatting.None)) == 1;
        public event Action<PlayerSnapshot> Snapshot;
        public event Action<ChatUpdate> Chat;
        public event Action<string> Status;
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Register() => PlayerBackend.Create = () => new NativePlayerBackend();
        public NativePlayerBackend()
        {
            var root = Environment.GetEnvironmentVariable("GMGN_UNITY_DATA_ROOT");
            if (string.IsNullOrEmpty(root)) root = System.IO.Path.Combine(Application.persistentDataPath, "unity-sample");
            System.IO.Directory.CreateDirectory(root);
            host = gmgn_unity_host_create(root, "ai.gmgn.unity-sample.player.preferences");
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
            if (Time.unscaledTime < nextPoll) return;
            nextPoll = Time.unscaledTime + .05f;
            var pointer = gmgn_unity_host_snapshot(host); if (pointer == IntPtr.Zero) return;
            Envelope value; string json;
            try { json = Marshal.PtrToStringUTF8(pointer); value = JsonUtility.FromJson<Envelope>(json); }
            finally { gmgn_unity_host_string_free(pointer); }
            if (value.world != null && worldGeneration != value.world.generation) {
                worldGeneration = value.world.generation;
                var update = JObject.Parse(json)["world"] as JObject;
                if (update != null && update["status"] != null) {
                    WorldProjection = update;
                    WorldUpdated?.Invoke(update);
                }
            }
            if (value.music != null) {
                var music = value.music; playing = music.isPlaying;
                if (music.lines != null) lyrics = music.lines;
                string lyric = "";
                foreach (var line in lyrics) { if (music.position >= line.start && music.position < line.end) { lyric = line.text; break; } }
                Snapshot?.Invoke(new PlayerSnapshot { sessionId = music.playbackSessionID.ToString(), title = music.title, duration = music.duration, position = music.position, playing = music.isPlaying, nextSupported = music.canNext, previousSupported = music.canPrevious, seekSupported = music.seekSupported, volume = music.volume, lyric = lyric, queueIndex = music.queueIndex, queueCount = music.queueCount, queue = music.queue ?? Array.Empty<QueueItem>(), bass = music.features?.low ?? 0, vocal = music.features?.mid ?? 0, treble = music.features?.high ?? 0 });
                if (!string.IsNullOrEmpty(music.notice)) Status?.Invoke(music.notice);
            }
            if (value.chat?.events == null) return;
            foreach (var item in value.chat.events) {
                if (!requestIds.TryGetValue(item.requestID, out var id)) continue;
                if (item.kind == "delta") {
                    Chat?.Invoke(new ChatUpdate { messageId = id, text = item.text ?? "", complete = false });
                } else if (item.kind == "reply" || item.kind == "failure" || item.kind == "cancelled") {
                    Chat?.Invoke(new ChatUpdate { messageId = id, text = item.text ?? item.message ?? "", error = item.kind == "failure" ? item.message : null, complete = true });
                    requestIds.Remove(item.requestID);
                }
            }
        }
        public void PlayPause() => Execute(new Command { op = playing ? "music.pause" : "music.play" });
        public void ChooseMusic() => Execute(new Command { op = "music.choose" });
        public void Next() => Execute(new Command { op = "music.next" });
        public void Previous() => Execute(new Command { op = "music.previous" });
        public void SelectQueueItem(int index) { if (!Execute(new Command { op = "music.select", index = index })) Status?.Invoke("这首音乐暂时无法播放，请重新选择音乐。"); }
        public void Seek(double seconds) => Status?.Invoke("当前音乐后端尚未提供跳转。");
        public void SetVolume(float volume) => Execute(new Command { op = "music.volume", value = volume });
        public void Send(string messageId, string text) { var id = ++sequence; requestIds[id] = messageId; if (!Execute(new Command { op = "chat.send", requestID = id, text = text })) { requestIds.Remove(id); Chat?.Invoke(new ChatUpdate { messageId = messageId, error = "消息未发送，请重试。", complete = true }); } }
        public void Cancel(string messageId) { foreach (var pair in requestIds) if (pair.Value == messageId) { Execute(new Command { op = "chat.cancel", requestID = pair.Key }); break; } }
        public void Dispose() { if (host != IntPtr.Zero) gmgn_unity_host_destroy(host); host = IntPtr.Zero; }
    }
}
