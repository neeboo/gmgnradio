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
        readonly List<JObject> playlists = new(), tracks = new(), programs = new();
        readonly ListView playlistList, trackList, programList;
        readonly Label status, title, count, detailTitle, detailSubtitle;
        readonly VisualElement detail;
        readonly Image detailCover;
        readonly Button back, history, refresh, close;
        readonly Dictionary<string, Texture2D> covers = new();
        readonly Dictionary<string, Task<Texture2D>> downloads = new();
        readonly CancellationTokenSource lifetime = new();
        string playlistID, currentTrackID, selectedProgramID;
        string statusKey = "libraryLoading", statusArgument, statusExternal, detailProvider, detailCount;
        PlayerSnapshot playback;
        bool showingTracks, historyView;
        static string Text(string key) => UiLocalization.Get(key);
        public VisualElement Element { get; }
        public MusicLibraryPanel(VisualElement parent, NativePlayerBackend backend, Action showQueue)
        {
            this.backend = backend;
            Element = new VisualElement { name = "musicLibraryPanel" };
            Element.AddToClassList("card"); Element.AddToClassList("music-library"); Element.AddToClassList("hidden");
            var stylesheet = Resources.Load<StyleSheet>("MusicLibrary"); if (stylesheet != null) Element.styleSheets.Add(stylesheet);
            var header = new VisualElement(); header.AddToClassList("music-library-header");
            back = IconButton("back", Text("libraryBack"), () => ShowTracks(false)); back.AddToClassList("hidden"); header.Add(back);
            title = new Label(Text("libraryPlaylists")); title.AddToClassList("music-library-title"); header.Add(title);
            count = new Label(); count.AddToClassList("music-library-count"); header.Add(count);
            history = IconButton("music", "浏览历史节目", () => SetHistoryView(!historyView)); history.name = "programHistoryToggle"; header.Add(history);
            refresh = IconButton("refresh", Text("libraryRefresh"), () => { SetStatus("libraryLoading"); if (!(historyView ? RequestProgramHistory() : backend.RequestMusicLibrary())) SetStatus("libraryBusy"); }); header.Add(refresh);
            close = IconButton("close", Text("libraryClose"), () => SetVisible(false)); header.Add(close); Element.Add(header);
            detail = new VisualElement(); detail.AddToClassList("music-library-detail"); detail.AddToClassList("hidden");
            detailCover = new Image { scaleMode = ScaleMode.ScaleAndCrop }; detailCover.AddToClassList("music-library-cover"); detail.Add(detailCover);
            var info = new VisualElement(); info.AddToClassList("music-library-info");
            detailTitle = new Label(); detailTitle.AddToClassList("music-library-name"); detailSubtitle = new Label(); detailSubtitle.AddToClassList("music-library-secondary");
            info.Add(detailTitle); info.Add(detailSubtitle); detail.Add(info); Element.Add(detail);
            status = new Label(Text("libraryLoading")); status.AddToClassList("music-library-status"); Element.Add(status);
            var listRegion = new VisualElement(); listRegion.AddToClassList("music-library-list-region"); Element.Add(listRegion);
            playlistList = BuildList(playlists, false); trackList = BuildList(tracks, true); trackList.AddToClassList("hidden"); listRegion.Add(playlistList); listRegion.Add(trackList);
            programList = BuildProgramList(); programList.AddToClassList("hidden"); listRegion.Add(programList);
            // Resolve the actual toolbar parent: caller may have passed shell.
            var toolbar = parent.Q(className: "player");
            if (toolbar?.parent != null) toolbar.parent.Insert(toolbar.parent.IndexOf(toolbar), Element);
            else parent.Add(Element);
            backend.MusicLibraryUpdated += Update;
            backend.Snapshot += UpdatePlayback;
            UiLocalization.Changed += RefreshLocale;
        }
        static Button IconButton(string kind, string tooltip, Action clicked)
        {
            var button = new Button(clicked) { tooltip = tooltip };
            button.AddToClassList("icon-button"); button.AddToClassList("music-library-action");
            button.Add(new PlayerScreen.ToolbarIcon(kind)); return button;
        }
        ListView BuildList(List<JObject> items, bool isTrack)
        {
            var list = new ListView { itemsSource = items, fixedItemHeight = isTrack ? 64 : 84,
                virtualizationMethod = CollectionVirtualizationMethod.FixedHeight, selectionType = SelectionType.None }; list.AddToClassList("music-library-list");
            var scroll = list.Q<ScrollView>();
            scroll.mode = ScrollViewMode.Vertical;
            scroll.horizontalScrollerVisibility = ScrollerVisibility.Hidden;
            scroll.verticalScrollerVisibility = ScrollerVisibility.Auto;
            scroll.contentViewport.AddToClassList("music-library-viewport");
            scroll.contentContainer.AddToClassList("music-library-content");
            list.makeItem = () => {
                var slot = new VisualElement(); slot.AddToClassList(isTrack ? "music-library-track-slot" : "music-library-playlist-slot");
                var row = new Button(); row.AddToClassList(isTrack ? "music-library-track" : "music-library-playlist");
                slot.Add(row);
                if (isTrack) { var number = new Label { name = "number" }; number.AddToClassList("music-library-number"); row.Add(number); }
                else { var cover = new Image { name = "cover", scaleMode = ScaleMode.ScaleAndCrop }; cover.AddToClassList("music-library-cover"); row.Add(cover); }
                var info = new VisualElement(); info.AddToClassList("music-library-info");
                var name = new Label { name = "title", enableRichText = false }; name.AddToClassList("music-library-name"); info.Add(name);
                var subtitle = new Label { name = "subtitle", enableRichText = false }; subtitle.AddToClassList("music-library-secondary"); info.Add(subtitle); row.Add(info);
                var trailing = new Label { name = "trailing" }; trailing.AddToClassList("music-library-trailing"); row.Add(trailing);
                row.clicked += () => {
                    if (row.userData is not JObject item) return;
                    if (isTrack) { SetStatus("libraryPreparing");
                        bool accepted = historyView
                            ? backend.SendCommand(new JObject { ["op"] = "music.program.play", ["programID"] = selectedProgramID, ["slotIndex"] = (int)item["index"] })
                            : backend.PlayMusicPlaylistTrack(playlistID, (int)item["index"]);
                        if (!accepted) SetStatus("libraryPrepareFailed"); }
                    else {
                        playlistID = (string)item["id"]; detailTitle.text = (string)item["name"]; SetDetail((string)item["provider"], item["count"].ToString());
                        BindCover(detailCover, (string)item["artworkURL"]); tracks.Clear(); trackList.RefreshItems(); ShowTracks(true); SetStatus("libraryTracksLoading");
                        if (!backend.RequestMusicPlaylist(playlistID)) SetStatus("libraryPlaylistBusy");
                    }
                }; return slot;
            };
            list.bindItem = (element, i) => {
                var row = element.Q<Button>(); var item = items[i]; row.userData = item;
                var active = isTrack && !string.IsNullOrEmpty(currentTrackID) && (string)item["id"] == currentTrackID;
                row.EnableInClassList("music-library-current", active); row.Q<Label>("title").text = (string)item[isTrack ? "title" : "name"];
                row.Q<Label>("subtitle").text = isTrack ? (string)item["artist"] : Provider((string)item["provider"]) + " · " + Count(item["count"].ToString());
                row.Q<Label>("trailing").text = isTrack ? (active ? Text("libraryPlaying") : Duration((double?)item["duration"] ?? 0)) : "›";
                if (isTrack) row.Q<Label>("number").text = (i + 1).ToString(); else BindCover(row.Q<Image>("cover"), (string)item["artworkURL"]);
                row.tooltip = row.Q<Label>("title").text;
            };
            list.unbindItem = (element, _) => { var image = element.Q<Image>("cover"); if (image != null) { image.userData = null; image.image = null; } }; return list;
        }
        bool RequestProgramHistory() => backend.SendCommand(new JObject { ["op"] = "music.program.history" });
        void SetHistoryView(bool history) {
            historyView = history; selectedProgramID = null; ShowTracks(false);
            SetStatus("libraryLoading");
            if (!(history ? RequestProgramHistory() : backend.RequestMusicLibrary())) SetStatus("libraryBusy");
        }
        ListView BuildProgramList() {
            var list = new ListView { itemsSource = programs, fixedItemHeight = 84, selectionType = SelectionType.None };
            list.AddToClassList("music-library-list");
            list.makeItem = () => {
                var row = new Button(); row.AddToClassList("music-library-playlist");
                row.clicked += () => {
                    if (row.userData is not JObject item) return;
                    selectedProgramID = (string)item["id"];
                    tracks.Clear(); if (item["tracks"] is JArray savedTracks) foreach (var track in savedTracks) tracks.Add((JObject)track);
                    detailTitle.text = (string)item["name"]; detailCount = null;
                    detailSubtitle.text = "DJ 节目 · " + tracks.Count + " 首";
                    detailCover.image = null; detailCover.userData = null;
                    trackList.RefreshItems(); ShowTracks(true); SetStatus("libraryPlayHint");
                };
                return row;
            };
            list.bindItem = (element, index) => {
                var row = (Button)element; var item = programs[index]; row.userData = item;
                string badge = (bool?)item["active"] == true ? "当前 · " : (bool?)item["pending"] == true ? "待切换 · " : "";
                row.text = badge + (string)item["name"] + " · " + (int?)item["count"] + " 首";
                row.tooltip = (string)item["name"];
            };
            return list;
        }
        static string Provider(string id) => id switch { "netease" => Text("libraryProviderNetease"), "qq-music" => Text("libraryProviderQQ"), "apple-music" => "Apple Music", _ => Text("libraryTitle") };
        static string Count(string count) => string.Format(Text("libraryTrackCount"), count);
        void SetDetail(string provider, string count) { detailProvider = provider; detailCount = count; detailSubtitle.text = Provider(provider) + " · " + Count(count); }
        void SetStatus(string key, string argument = null) { statusKey = key; statusArgument = argument; statusExternal = null; RefreshStatus(); }
        void RefreshStatus() { status.text = statusExternal ?? (statusArgument == null ? Text(statusKey) : string.Format(Text(statusKey), statusArgument)); }
        void UpdatePlayback(PlayerSnapshot snapshot) {
            playback = snapshot;
            if (statusKey == "libraryPlayingTitle" || (snapshot.playing && statusKey == "libraryPlayHint")) RefreshPlaybackStatus();
        }
        void RefreshPlaybackStatus() {
            if (playback == null) return;
            if (playback.playing && !string.IsNullOrEmpty(playback.title)) SetStatus("libraryPlayingTitle", playback.title);
            else SetStatus("libraryPlayHint");
        }
        void RefreshLocale() {
            back.tooltip = Text("libraryBack"); refresh.tooltip = Text("libraryRefresh"); close.tooltip = Text("libraryClose");
            ShowTracks(showingTracks); RefreshStatus();
            if (detailCount != null) SetDetail(detailProvider, detailCount);
            playlistList.RefreshItems(); trackList.RefreshItems();
        }
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
        void ShowTracks(bool show) { showingTracks = show; playlistList.EnableInClassList("hidden", show || historyView); programList.EnableInClassList("hidden", show || !historyView); trackList.EnableInClassList("hidden", !show); detail.EnableInClassList("hidden", !show); back.EnableInClassList("hidden", !show); title.text = show ? Text("libraryTracks") : historyView ? "历史节目" : Text("libraryPlaylists"); count.text = "· " + (historyView ? programs.Count : playlists.Count); count.EnableInClassList("hidden", show); history.tooltip = historyView ? "返回音乐歌单" : "浏览历史节目"; history.EnableInClassList("selected", historyView); }
        void Update(JObject value)
        {
            if (value["currentTrackID"] != null) { var next = (string)value["currentTrackID"]; if (currentTrackID != next) { currentTrackID = next; trackList.RefreshItems(); } }
            if ((string)value["status"] == "failed") { SetStatus("libraryUnavailable"); statusExternal = (string)value["message"]; RefreshStatus(); return; }
            switch ((string)value["operation"]) {
                case "program-history":
                    programs.Clear(); if (value["programs"] is JArray saved) foreach (var row in saved) programs.Add((JObject)row);
                    programList.RefreshItems(); if (historyView) { ShowTracks(false); SetStatus(programs.Count == 0 ? "libraryEmpty" : "librarySelectPlaylist"); }
                    break;
                case "library": playlists.Clear(); foreach (var row in (JArray)value["playlists"]) playlists.Add((JObject)row); playlistList.RefreshItems(); if (!historyView) { ShowTracks(false); SetStatus(playlists.Count == 0 ? "libraryEmpty" : "librarySelectPlaylist"); } break;
                case "playlist":
                    if (historyView || (string)value["playlistID"] != playlistID) return;
                    tracks.Clear(); foreach (var row in (JArray)value["tracks"]) tracks.Add((JObject)row);
                    detailTitle.text = (string)value["name"]; SetDetail((string)value["provider"], value["loaded"] + " / " + value["total"]);
                    BindCover(detailCover, (string)value["artworkURL"]); trackList.RefreshItems(); ShowTracks(true); SetStatus("libraryPlayHint"); break;
                case "play": case "program":
                    // Selection replies can arrive after a next-track snapshot.
                    // Only the live playback projection supplies the playing title.
                    SetStatus("libraryPlayHint");
                    RefreshPlaybackStatus(); break;
            }
        }
        public void SetVisible(bool visible) { Element.EnableInClassList("hidden", !visible); if (visible) Element.schedule.Execute(() => Debug.Log($"[Popup] music visible hidden={Element.ClassListContains("hidden")} display={Element.resolvedStyle.display} bounds={Element.worldBound} parent={Element.parent?.name}")); if (visible) { if (historyView) RequestProgramHistory(); else if (playlists.Count == 0) backend.RequestMusicLibrary(); } }
        public void Toggle() => SetVisible(Element.ClassListContains("hidden"));
        public void Dispose() { lifetime.Cancel(); backend.MusicLibraryUpdated -= Update; backend.Snapshot -= UpdatePlayback; UiLocalization.Changed -= RefreshLocale; Element.RemoveFromHierarchy(); foreach (var texture in covers.Values) UnityEngine.Object.Destroy(texture); covers.Clear(); }
    }
}
