using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.Reflection;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.TextCore.Text;

namespace GMGN.UnityPlayer.Editor
{
    public static class CurrentSongLyricsDiagnostic
    {
        public static void Run()
        {
            GameObject root = null;
            try {
                using var client = new WebClient();
                client.Headers[HttpRequestHeader.UserAgent] = "Mozilla/5.0";
                client.Headers[HttpRequestHeader.Referer] = "https://music.163.com/";
                var reply = JObject.Parse(client.DownloadString("https://music.163.com/api/song/lyric?id=22679504&lv=-1&kv=-1&tv=-1&yv=-1"));
                var lines = new List<LyricPointLine>();
                foreach (var row in ((string)reply["lrc"]?["lyric"] ?? "").Split('\n')) {
                    var matches = Regex.Matches(row, @"\[(\d+):(\d+(?:\.\d+)?)\]");
                    var text = Regex.Replace(row, @"\[[^\]]*\]", "").Trim();
                    if (text.Length == 0) continue;
                    foreach (Match match in matches) lines.Add(new LyricPointLine {
                        text = text, startsAt = double.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) * 60 + double.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture)
                    });
                }
                lines.Sort((a,b) => a.startsAt.CompareTo(b.startsAt));
                for (var i=0;i<lines.Count;i++) lines[i].endsAt = i+1 < lines.Count ? lines[i+1].startsAt : lines[i].startsAt+30;
                root = new GameObject("Current song isolated lyrics diagnostic");
                var view = root.AddComponent<GpuLyricsView>();
                var ready = view.EnsureGpuReady();
                Debug.Log($"[CurrentSongLyricsDiagnostic] timeline={lines.Count} gpuReady={ready} status={view.Status} compute={SystemInfo.supportsComputeShaders}");
                if (!ready || lines.Count == 0) throw new Exception("GPU or timeline unavailable: " + view.Status);
                view.SetLyrics("netease:22679504", 1, lines.ToArray(), "monet_poster");
                view.SetVisible(true);
                view.SetPlayback(lines[Math.Min(3,lines.Count-1)].startsAt+1, .2f,.2f,.2f);
                typeof(GpuLyricsView).GetMethod("LateUpdate", BindingFlags.NonPublic|BindingFlags.Instance).Invoke(view,null);
                Debug.Log($"[CurrentSongLyricsDiagnostic] mode={view.Mode} points={view.PointCapacity} status={view.Status}");
                foreach (var role in new[]{"Light","Medium","Semibold","Bold","Black"}) {
                    foreach (var suffix in new[]{"Font","LatinFont"}) {
                        var asset = Resources.Load<FontAsset>("PlayerLyrics"+role+suffix);
                        if(asset == null) continue;
                        foreach(var atlas in asset.atlasTextures) if(atlas != null)
                            Debug.Log($"[CurrentSongLyricsDiagnostic] font={asset.name} atlas={atlas.width}x{atlas.height} format={atlas.format} glyphs={asset.glyphTable.Count}");
                    }
                }
                if(view.PointCapacity == 0) throw new Exception("No lyric glyphs: " + view.Status);
                foreach(var sample in new[]{"普通歌词测试", "备用字体 łŁ 测试"}) {
                    var content = new[]{new LyricPointLine{text=sample,startsAt=0,endsAt=10}};
                    foreach(var mode in new[]{"luminous","monet_poster","folding_verse","mindscape","claddagh","cloud_steps","article","chorus_chat","confession","pendulum","diorama"}) {
                        view.SetLyrics(sample,2,content,mode); view.SetPlayback(2,.2f,.2f,.2f);
                        typeof(GpuLyricsView).GetMethod("LateUpdate",BindingFlags.NonPublic|BindingFlags.Instance).Invoke(view,null);
                        if(view.PointCapacity == 0) throw new Exception("Style regression: "+mode+" "+view.Status);
                        Debug.Log($"[CurrentSongLyricsDiagnostic] regression mode={mode} fallback={sample.Contains("ł")} points={view.PointCapacity}");
                    }
                }
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
            finally { if(root != null) UnityEngine.Object.DestroyImmediate(root); }
        }
    }
}
