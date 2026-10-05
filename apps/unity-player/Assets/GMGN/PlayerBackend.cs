using System;

namespace GMGN.UnityPlayer
{
    [Serializable] public sealed class QueueItem
    {
        public int index;
        public string title;
    }
    [Serializable] public sealed class PlayerSnapshot
    {
        public string sessionId, title, artist, lyric, translation;
        public string locale = "zh-CN";
        public double position, duration;
        public bool playing, seekSupported, nextSupported, previousSupported;
        public float volume, bass, vocal, treble;
        public int queueIndex, queueCount;
        public QueueItem[] queue = Array.Empty<QueueItem>();
        public long lyricRevision;
        public LyricPointLine[] lyricLines = Array.Empty<LyricPointLine>();
        public LyricVisualSnapshot lyricVisual;
        public PointCloudSnapshot pointCloud;
    }
    [Serializable] public sealed class PointCloudSnapshot
    {
        public string choice, artworkURL;
        public float intensity, particleSize, composition;
        public float[] presetWeights, rhythm, waveA, waveB;
    }
    [Serializable] public sealed class LyricVisualSnapshot
    {
        public long revision;
        public string configuredMode, mode;
        public LyricVisualTheme theme;
    }
    [Serializable] public sealed class LyricVisualTheme
    {
        public string name, description, backgroundColor, primaryColor, accentColor, secondaryColor;
        public LyricWordColor[] wordColors = Array.Empty<LyricWordColor>();
    }
    [Serializable] public sealed class LyricWordColor { public string word, color; }
    public sealed class ChatUpdate
    {
        public string messageId, text, error;
        public bool complete;
    }
    public interface IPlayerBackend : IDisposable
    {
        event Action<PlayerSnapshot> Snapshot;
        event Action<ChatUpdate> Chat;
        event Action<string> Status;
        void Tick();
        void PlayPause();
        void ChooseMusic();
        void Next();
        void Previous();
        void SelectQueueItem(int index);
        void OpenSettings();
        void Seek(double seconds);
        void SetVolume(float volume);
        void Send(string messageId, string text);
        void Cancel(string messageId);
    }
    public static class PlayerBackend
    {
        public static Func<IPlayerBackend> Create;
    }
}
