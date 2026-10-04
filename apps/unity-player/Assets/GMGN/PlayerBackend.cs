using System;

namespace GMGN.UnityPlayer
{
    [Serializable] public sealed class PlayerSnapshot
    {
        public string sessionId, title, artist, lyric, translation;
        public double position, duration;
        public bool playing, seekSupported, nextSupported;
        public float volume, bass, vocal, treble;
    }
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
