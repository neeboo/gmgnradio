using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Networking;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    public sealed class MusicLibraryPanel : IDisposable
    {
        readonly NativePlayerBackend backend;
        readonly List<JObject> playlists = new(), tracks = new();
        readonly ListView playlistList, trackList;
        readonly Label status, title, detailTitle, detailSubtitle;
        readonly VisualElement detail;
        readonly Image detailCover;
        readonly Dictionary<string, Texture2D> covers = new();
        readonly Dictionary<string, Task<Texture2D>> downloads = new();
        readonly CancellationTokenSource lifetime = new();
        string playlistID, currentTrackID;
        public VisualElement Element { get; }
        public MusicLibraryPanel(VisualElement parent, NativePlayerBackend backend, Action showQueue)
        {
            this.backend = backend;
            Element = new VisualElement { name = "musicLibraryPanel" };
            Element.AddToClassList("card"); Element.AddToClassList("music-library"); Element.AddToClassList("hidden");
            var stylesheet = Resources.Load<StyleSheet>("MusicLibrary"); if (stylesheet != null) Element.styleSheets.Add(stylesheet);
            var header = new VisualElement(); header.AddToClassList("music-library-header");
            title = new Label("歌单"); title.AddToClassList("music-library-title"); header.Add(title);
            header.Add(new Button(() => { status.text = "正在读取歌单…"; if (!backend.RequestMusicLibrary()) status.text = "音乐库正在忙，请稍后重试。"; }) { text = "刷新" });
            header.Add(new Button(() => { SetVisible(false); showQueue(); }) { text = "队列" });
            header.Add(new Button(() => SetVisible(false)) { text = "关闭" }); Element.Add(header);
            detail = new VisualElement(); detail.AddToClassList("music-library-detail"); detail.AddToClassList("hidden");
            detail.Add(new Button(() => ShowTracks(false)) { text = "‹ 返回", tooltip = "返回歌单" });
            detailCover = new Image { scaleMode = ScaleMode.ScaleAndCrop }; detailCover.AddToClassList("music-library-cover"); detail.Add(detailCover);
            var info = new VisualElement(); info.AddToClassList("music-library-info");
            detailTitle = new Label(); detailTitle.AddToClassList("music-library-name"); detailSubtitle = new Label(); detailSubtitle.AddToClassList("music-library-secondary");
            info.Add(detailTitle); info.Add(detailSubtitle); detail.Add(info); Element.Add(detail);
            status = new Label("正在读取歌单…"); status.AddToClassList("music-library-status"); Element.Add(status);
            playlistList = BuildList(playlists, false); trackList = BuildList(tracks, true); trackList.AddToClassList("hidden"); Element.Add(playlistList); Element.Add(trackList);
            var local = new Button(backend.ChooseMusic) { text = "打开本地音乐…" }; local.AddToClassList("music-library-local"); Element.Add(local);
            // Resolve the actual toolbar parent: caller may have passed shell.
            var toolbar = parent.Q(className: "player");
            if (toolbar?.parent != null) toolbar.parent.Insert(toolbar.parent.IndexOf(toolbar), Element);
            else parent.Add(Element);
            backend.MusicLibraryUpdated += Update;
        }
        ListView BuildList(List<JObject> items, bool isTrack)
        {
            var list = new ListView { itemsSource = items, fixedItemHeight = isTrack ? 64 : 84, selectionType = SelectionType.None }; list.AddToClassList("music-library-list");
            list.makeItem = () => {
                var row = new Button(); row.AddToClassList(isTrack ? "music-library-track" : "music-library-playlist");
                if (isTrack) { var number = new Label { name = "number" }; number.AddToClassList("music-library-number"); row.Add(number); }
                else { var cover = new Image { name = "cover", scaleMode = ScaleMode.ScaleAndCrop }; cover.AddToClassList("music-library-cover"); row.Add(cover); }
                var info = new VisualElement(); info.AddToClassList("music-library-info");
                var name = new Label { name = "title", enableRichText = false }; name.AddToClassList("music-library-name"); info.Add(name);
                var subtitle = new Label { name = "subtitle", enableRichText = false }; subtitle.AddToClassList("music-library-secondary"); info.Add(subtitle); row.Add(info);
                var trailing = new Label { name = "trailing" }; trailing.AddToClassList("music-library-trailing"); row.Add(trailing);
                row.clicked += () => {
                    if (row.userData is not JObject item) return;
                    if (isTrack) { status.text = "正在准备播放…"; if (!backend.PlayMusicPlaylistTrack(playlistID, (int)item["index"])) status.text = "这首歌未能开始准备，请重试。"; }
                    else {
                        playlistID = (string)item["id"]; detailTitle.text = (string)item["name"]; detailSubtitle.text = Provider((string)item["provider"]) + " · " + item["count"] + " 首";
                        BindCover(detailCover, (string)item["artworkURL"]); tracks.Clear(); trackList.RefreshItems(); ShowTracks(true); status.text = "正在读取歌单歌曲…";
                        if (!backend.RequestMusicPlaylist(playlistID)) status.text = "歌单正在忙，请返回后重试。";
                    }
                }; return row;
            };
            list.bindItem = (element, i) => {
                var row = (Button)element; var item = items[i]; row.userData = item;
                var active = isTrack && !string.IsNullOrEmpty(currentTrackID) && (string)item["id"] == currentTrackID;
                row.EnableInClassList("music-library-current", active); row.Q<Label>("title").text = (string)item[isTrack ? "title" : "name"];
                row.Q<Label>("subtitle").text = isTrack ? (string)item["artist"] : Provider((string)item["provider"]) + " · " + item["count"] + " 首";
                row.Q<Label>("trailing").text = isTrack ? (active ? "正在播放" : Duration((double?)item["duration"] ?? 0)) : "›";
                if (isTrack) row.Q<Label>("number").text = (i + 1).ToString(); else BindCover(row.Q<Image>("cover"), (string)item["artworkURL"]);
                row.tooltip = row.Q<Label>("title").text;
            };
            list.unbindItem = (element, _) => { var image = element.Q<Image>("cover"); if (image != null) { image.userData = null; image.image = null; } }; return list;
        }
        static string Provider(string id) => id switch { "netease" => "网易云", "qq-music" => "QQ 音乐", "apple-music" => "Apple Music", _ => "音乐库" };
        static string Duration(double seconds) => seconds > 0 ? $"{(int)seconds / 60}:{(int)seconds % 60:00}" : "";
        async void BindCover(Image image, string url)
        {
            image.userData = url; image.image = null;
            if (string.IsNullOrEmpty(url) || !Uri.TryCreate(url, UriKind.Absolute, out var uri) || (uri.Scheme != "https" && uri.Scheme != "http")) return;
            try {
                if (!covers.TryGetValue(url, out var texture)) {
                    if (!downloads.TryGetValue(url, out var task)) { if (covers.Count + downloads.Count >= 128) return; task = FetchCover(url); downloads[url] = task; }
                    texture = await task;
                }
                if (!lifetime.IsCancellationRequested && (string)image.userData == url) image.image = texture;
            } catch (Exception) { }
        }
        async Task<Texture2D> FetchCover(string url)
        {
            try {
                using var request = UnityWebRequestTexture.GetTexture(url, true); request.timeout = 15;
                var operation = request.SendWebRequest();
                while (!operation.isDone) { if (lifetime.IsCancellationRequested || request.downloadedBytes > 2 * 1024 * 1024) { request.Abort(); return null; } await Task.Yield(); }
                if (lifetime.IsCancellationRequested || request.result != UnityWebRequest.Result.Success) return null;
                if (request.downloadedBytes > 2 * 1024 * 1024) return null;
                var texture = DownloadHandlerTexture.GetContent(request); covers[url] = texture; return texture;
            } finally { downloads.Remove(url); }
        }
        void ShowTracks(bool show) { playlistList.EnableInClassList("hidden", show); trackList.EnableInClassList("hidden", !show); detail.EnableInClassList("hidden", !show); title.text = show ? "歌曲" : $"歌单 · {playlists.Count}"; }
        void Update(JObject value)
        {
            if (value["currentTrackID"] != null) { var next = (string)value["currentTrackID"]; if (currentTrackID != next) { currentTrackID = next; trackList.RefreshItems(); } }
            if ((string)value["status"] == "failed") { status.text = (string)value["message"] ?? "音乐库暂时不可用。"; return; }
            switch ((string)value["operation"]) {
                case "library": playlists.Clear(); foreach (var row in (JArray)value["playlists"]) playlists.Add((JObject)row); playlistList.RefreshItems(); ShowTracks(false); status.text = playlists.Count == 0 ? "还没有已同步歌单。" : "选择一个歌单查看歌曲"; break;
                case "playlist":
                    if ((string)value["playlistID"] != playlistID) return;
                    tracks.Clear(); foreach (var row in (JArray)value["tracks"]) tracks.Add((JObject)row);
                    detailTitle.text = (string)value["name"]; detailSubtitle.text = Provider((string)value["provider"]) + " · " + value["loaded"] + " / " + value["total"] + " 首";
                    BindCover(detailCover, (string)value["artworkURL"]); trackList.RefreshItems(); ShowTracks(true); status.text = "点击歌曲开始播放"; break;
                case "play": status.text = "正在播放 · " + (string)value["title"]; break;
            }
        }
        public void SetVisible(bool visible) { Element.EnableInClassList("hidden", !visible); if (visible && playlists.Count == 0) backend.RequestMusicLibrary(); }
        public void Toggle() => SetVisible(Element.ClassListContains("hidden"));
        public void Dispose() { lifetime.Cancel(); backend.MusicLibraryUpdated -= Update; Element.RemoveFromHierarchy(); foreach (var texture in covers.Values) UnityEngine.Object.Destroy(texture); covers.Clear(); }
    }
}
