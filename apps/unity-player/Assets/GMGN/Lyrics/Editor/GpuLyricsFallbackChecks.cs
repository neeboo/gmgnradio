using System;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using UnityEngine;
using UnityEngine.TextCore.Text;
using UnityEditor;

namespace GMGN.UnityPlayer.Editor
{
    public static class GpuLyricsFallbackChecks
    {
        public static void Run()
        {
            PlayerBuild.PrepareLyricsFonts(); AssetDatabase.SaveAssets();
            var root=new GameObject("Latin glyph regression");
            try {
                var view=root.AddComponent<GpuLyricsView>();
                const BindingFlags flags=BindingFlags.NonPublic|BindingFlags.Instance;
                var type=typeof(GpuLyricsView);
                var fallbacks=(Dictionary<FontAsset,FontAsset>)type.GetField("fontFallbacks",flags).GetValue(view);
                var pages=(Dictionary<FontAsset,int>)type.GetField("fontPages",flags).GetValue(view);
                var descriptors=(IList)type.GetField("descriptors",flags).GetValue(view);
                foreach(var style in new[]{"Light","Medium","Semibold","Bold","Black"}) {
                    var primary=Resources.Load<FontAsset>("PlayerLyrics"+style+"Font");
                    var latin=Resources.Load<FontAsset>("PlayerLyrics"+style+"LatinFont");
                    if(primary==null||latin==null)throw new Exception("Missing role fonts "+style);
                    type.GetField("font",flags).SetValue(view,primary); fallbacks[primary]=latin;
                    type.GetMethod("WarmFont",flags).Invoke(view,new object[]{primary,"łŁ中"});
                    if(!primary.characterLookupTable.ContainsKey('中'))throw new Exception("CJK glyph lost");
                    if(!latin.characterLookupTable.ContainsKey('ł')||!latin.characterLookupTable.ContainsKey('Ł'))throw new Exception("Polish glyph unavailable "+style);
                    pages.Clear(); pages[primary]=0; pages[latin]=primary.atlasTextures.Length;
                    descriptors.Clear();
                    type.GetMethod("AddLine",flags).Invoke(view,new object[]{new LyricPointLine{text="łŁ中",startsAt=0,endsAt=1},48f,400f,200f,Color.white,false});
                    if(descriptors.Count!=3)throw new Exception("Actual subtitle descriptor skipped a glyph "+style);
                    for(var i=0;i<3;i++) {
                        var descriptor=descriptors[i]; var seedType=descriptor.GetType();
                        var rect=(Vector4)seedType.GetField("rectangle").GetValue(descriptor);
                        var metadata=(Vector4)seedType.GetField("metadata").GetValue(descriptor);
                        if(rect.z<=0||rect.w<=0)throw new Exception("Empty glyph quad");
                        if(i<2&&metadata.z<pages[latin]||i==2&&metadata.z>=pages[latin])throw new Exception("Wrong actual atlas owner");
                    }
                    Debug.Log("[GpuLyricsFallbackChecks] PASS "+style+" subtitle łŁ中: Latin fallback pages + original CJK page");
                }
            } finally { UnityEngine.Object.DestroyImmediate(root); }
        }
    }
}
