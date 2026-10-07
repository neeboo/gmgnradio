using System;
using System.Reflection;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class LyricsResizeResourceChecks
    {
        const BindingFlags Flags = BindingFlags.Instance | BindingFlags.NonPublic;
        public static void Run()
        {
            var host = new GameObject("Lyrics resize GPU resource check");
            var gpu = host.AddComponent<GpuLyricsView>();
            gpu.enabled = false;
            try {
                Require(gpu.EnsureGpuReady(), "actual weighted fonts/compute/draw/blur shaders load");
                gpu.SetLyrics("resize-test", 1, new[] {
                    new LyricPointLine { id="first", text="你好 Hello GPU", translation="Atlas reuse", startsAt=0, endsAt=20 },
                    new LyricPointLine { id="second", text="真正的字体资源", startsAt=20, endsAt=40 }
                }, "monet_poster");
                Require(Settle(gpu, 1440, 900, 2, 0), "first viewport immediate");
                Set(gpu, "activeIndex", 0); Invoke(gpu, "Rebuild");
                Require(gpu.PointCapacity>0 && gpu.AtlasUploadCount==1, "initial real glyphs and atlas uploaded");
                var atlas = Get<Texture2DArray>(gpu, "atlasPages");
                var glyphs = Get<GraphicsBuffer>(gpu, "glyphs");
                var points = Get<GraphicsBuffer>(gpu, "points");
                Require(atlas.depth>=5 && glyphs.IsValid() && points.IsValid(), "real multi-font atlas and GPU buffers");
                Invoke(gpu, "LateUpdate");
                var firstGlow = Get<RenderTexture>(gpu, "glowA");
                Require(firstGlow!=null && firstGlow.IsCreated(), "real blur shader render target created");
                int allocations=gpu.GlowTargetAllocationCount;
                for(int i=1;i<=12;i++) {
                    Require(!Settle(gpu, 1440+i*200, 900+i*110, 2, i*.01), "intermediate resize is deferred");
                    Invoke(gpu, "RenderGlow");
                    Require(Get<RenderTexture>(gpu,"glowA")==firstGlow, "intermediate resize reuses real RT");
                }
                Require(!Settle(gpu, 4096, 2304, 2, .2), "fullscreen starts settling");
                Require(Settle(gpu, 4096, 2304, 2, .4), "final native 4K viewport settles");
                Invoke(gpu,"Rebuild");Invoke(gpu,"RenderGlow");
                Require(Get<Texture2DArray>(gpu,"atlasPages")==atlas && gpu.AtlasUploadCount==1, "4K resize does not copy font atlases");
                Require(Get<GraphicsBuffer>(gpu,"glyphs")==glyphs && Get<GraphicsBuffer>(gpu,"points")==points, "4K resize retains GPU buffers");
                var fullscreenGlow=Get<RenderTexture>(gpu,"glowA");
                Require(fullscreenGlow.width==1024 && fullscreenGlow.height==576 && fullscreenGlow.IsCreated(), "native 4K glow has original full resolution");
                Require(gpu.GlowTargetAllocationCount==allocations+1, "one RT pair for stable fullscreen");
                Set(gpu,"activeIndex",1);Invoke(gpu,"Rebuild");
                Require(gpu.AtlasUploadCount==1 && Get<Texture2DArray>(gpu,"atlasPages")==atlas, "next lyric line reuses warmed atlas");
                gpu.SetLyrics("next-song",2,new[]{new LyricPointLine{id="new",text="换歌 Unicode Ω",startsAt=0,endsAt=20}},"monet_poster");
                Require(gpu.PointCapacity==0, "track switch immediately hides old glyphs");
                Set(gpu,"activeIndex",0);Invoke(gpu,"Rebuild");
                Require(gpu.PointCapacity>0 && gpu.AtlasUploadCount==2, "new song font changes refresh atlas");
                var atlasAfterTrack=Get<Texture2DArray>(gpu,"atlasPages");
                var source=Get<UnityEngine.TextCore.Text.FontAsset>(gpu,"boldFont").atlasTextures[0];
                source.IncrementUpdateCount();Invoke(gpu,"Rebuild");
                Require(gpu.AtlasUploadCount==3, "external dynamic font texture update refreshes GPU atlas");
                gpu.Clear();
                Require(gpu.PointCapacity==0 && Get<GraphicsBuffer>(gpu,"glyphs")==glyphs, "clear hides lyrics while retaining reusable buffer");
                Debug.Log($"PASS: actual lyrics fonts/compute/blur GPU resources retained through 12 resize frames, native 4096x2304, line/track/dynamic atlas invalidation; uploads={gpu.AtlasUploadCount}, glowAllocations={gpu.GlowTargetAllocationCount}");
            } catch(TargetInvocationException error) {
                throw error.InnerException ?? error;
            } finally {
                UnityEngine.Object.DestroyImmediate(host);
            }
        }
        static bool Settle(GpuLyricsView value,int width,int height,float scale,double now) =>
            (bool)typeof(GpuLyricsView).GetMethod("SettleViewport",Flags).Invoke(value,new object[]{width,height,scale,now});
        static T Get<T>(GpuLyricsView value,string name) => (T)typeof(GpuLyricsView).GetField(name,Flags).GetValue(value);
        static void Set(GpuLyricsView value,string name,object data) => typeof(GpuLyricsView).GetField(name,Flags).SetValue(value,data);
        static object Invoke(GpuLyricsView value,string name) => typeof(GpuLyricsView).GetMethod(name,Flags).Invoke(value,null);
        static void Require(bool value,string message) { if(!value)throw new Exception("FAIL lyrics GPU resize: "+message); }
    }
}
