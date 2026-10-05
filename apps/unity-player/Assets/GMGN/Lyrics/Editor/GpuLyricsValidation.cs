using System;
using System.Runtime.InteropServices;
using System.Reflection;
using System.Collections;
using UnityEditor;
using UnityEditor.Rendering;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    // Build-time diagnostics, not a replacement for a Metal frame capture.
    public static class GpuLyricsValidation
    {
        public static void Validate()
        {
            var seedType = typeof(GpuLyricsView).Assembly.GetType("GMGN.UnityPlayer.LyricGlyphSeed", true);
            if (Marshal.SizeOf(seedType) != 144)
                throw new InvalidOperationException("GPU lyric seed stride mismatch");
            ValidateContextBounds(seedType);
            ValidateWrapping();
            foreach(var resource in new[]{"PlayerLyricsBoldFont","PlayerLyricsMediumFont","PlayerLyricsSemiboldFont","PlayerLyricsBlackFont","PlayerLyricsLightFont"}){
                var font=Resources.Load<UnityEngine.TextCore.Text.FontAsset>(resource);
                if(font==null||font.atlasWidth!=1024||font.atlasHeight!=1024)throw new InvalidOperationException("GPU weighted lyric font missing or atlas size mismatch: "+resource);
            }
            var compute = Resources.Load<ComputeShader>("GpuLyricsUpdate");
            var shader = Resources.Load<Shader>("GpuLyricsGlyphDraw");
            if (compute == null || shader == null)
                throw new InvalidOperationException("GPU lyric shader resources missing");
            // Batch build uses -nographics / Null device; runtime kernels are
            // unavailable there. Player Metal compilation and runtime still
            // have to validate the actual kernel.
            if (SystemInfo.graphicsDeviceType != UnityEngine.Rendering.GraphicsDeviceType.Null)
                compute.FindKernel("UpdateLyrics");
            foreach (var message in ShaderUtil.GetComputeShaderMessages(compute))
                if (message.severity == ShaderCompilerMessageSeverity.Error)
                    throw new InvalidOperationException("GPU lyric Compute: " + message.message);
            foreach (var message in ShaderUtil.GetShaderMessages(shader))
                if (message.severity == ShaderCompilerMessageSeverity.Error)
                    throw new InvalidOperationException("GPU lyric draw: " + message.message);
            foreach(var resource in new[]{"GpuLyricsBlur","GpuLyricsGlowComposite"}){
                var effectShader=Resources.Load<Shader>(resource);
                if(effectShader==null)throw new InvalidOperationException("GPU lyric glow shader missing: "+resource);
                foreach(var message in ShaderUtil.GetShaderMessages(effectShader))if(message.severity==ShaderCompilerMessageSeverity.Error)throw new InvalidOperationException(resource+": "+message.message);
            }
            Debug.Log("GPU lyrics build diagnostics passed; 144-byte seed and shader resources present. Runtime capture still required.");
        }
        static void ValidateWrapping(){
            var method=typeof(GpuLyricsView).GetMethod("WrapTwoLines",BindingFlags.NonPublic|BindingFlags.Static);
            Func<string,float> measure=text=>System.Globalization.StringInfo.ParseCombiningCharacters(text).Length*10;
            foreach(var text in new[]{"one two three four five", "春天的雨落在安静的街道上", "第一行\n第二行", "a😀b😀c😀d😀e😀f", "supercalifragilisticexpialidocious"}){
                var rows=(string[])method.Invoke(null,new object[]{text,60f,measure});
                if(rows.Length<1||rows.Length>2)throw new InvalidOperationException("Translation two-line limit failed");
                foreach(var row in rows){
                    if(measure(row)>60)throw new InvalidOperationException("Translation wrapped row exceeds width");
                    for(var i=0;i<row.Length;i++)if(char.IsSurrogate(row[i])){if(!char.IsHighSurrogate(row[i])||i+1==row.Length||!char.IsLowSurrogate(row[++i]))throw new InvalidOperationException("Translation split a grapheme surrogate");}
                }
            }
            var explicitRows=(string[])method.Invoke(null,new object[]{"第一行\n第二行",60f,measure});
            if(explicitRows.Length!=2||explicitRows[0]!="第一行"||explicitRows[1]!="第二行")throw new InvalidOperationException("Translation explicit newline changed");
            Debug.Log("GPU translation wrapping: Latin/CJK/emoji/long-word/explicit newline descriptor input checks passed; real font metrics still require runtime capture.");
        }
        static void ValidateContextBounds(Type seedType){
            const BindingFlags flags=BindingFlags.NonPublic|BindingFlags.Instance;
            var layout=typeof(GpuLyricsView).GetMethod("FlowContextLayout",BindingFlags.NonPublic|BindingFlags.Static);
            var align=typeof(GpuLyricsView).GetMethod("AlignGlyphRange",flags);
            var boundsMethod=typeof(GpuLyricsView).GetMethod("GlyphRangeBounds",flags);
            var rectangle=seedType.GetField("rectangle");
            var timing=seedType.GetField("timing");var metadata=seedType.GetField("metadata");
            var host=new GameObject("GPU lyrics bounds validation");
            try{
                var view=host.AddComponent<GpuLyricsView>();
                var descriptors=(IList)typeof(GpuLyricsView).GetField("descriptors",flags).GetValue(view);
                foreach(var viewport in new[]{720f,1440f}){
                    var frame=(Vector3)layout.Invoke(null,new object[]{viewport});
                    var expectedLeft=viewport==720?24:338;
                    var expectedRight=viewport==720?696:1102;
                    foreach(var trailing in new[]{false,true}){
                        descriptors.Clear();
                        // Non-monotonic rectangles test the actual extremal
                        // vertices, not a first/last-character approximation.
                        foreach(var rect in new[]{new Vector4(-75,40,12,22),new Vector4(-82,40,8,20),new Vector4(70,40,24,20),new Vector4(60,40,9,20)}){
                            var seed=Activator.CreateInstance(seedType);rectangle.SetValue(seed,rect);metadata.SetValue(seed,new Vector4(1,0,0,0));timing.SetValue(seed,new Vector4(0,1,6,50));descriptors.Add(seed);
                        }
                        var anchor=trailing?frame.z:frame.y;
                        align.Invoke(view,new object[]{0,anchor,trailing});
                        var bounds=(Vector2)boundsMethod.Invoke(view,new object[]{0});
                        if(bounds.x<24-.01f||bounds.y>viewport-24+.01f || Mathf.Abs((trailing?bounds.y:bounds.x)-(trailing?expectedRight:expectedLeft))>.01f)
                            throw new InvalidOperationException($"Flow actual descriptor bounds failed: viewport={viewport} trailing={trailing} bounds={bounds}");
                        var expectedAnchorCenter=6+(trailing?anchor-94:anchor+82);
                        foreach(var descriptor in descriptors){var groupTiming=(Vector4)timing.GetValue(descriptor);if(Mathf.Abs(groupTiming.z-expectedAnchorCenter)>.01f||groupTiming.w!=50)throw new InvalidOperationException("Display-unit shared anchor did not follow layout translation");}
                        Debug.Log($"GPU Flow descriptor bounds verified: logical={viewport} trailing={trailing} bounds={bounds}");
                    }
                }
                var unitPosition=typeof(GpuLyricsView).GetMethod("PositionDisplayUnit",flags);
                var beforeA=(Vector4)rectangle.GetValue(descriptors[0]);var beforeB=(Vector4)rectangle.GetValue(descriptors[1]);
                unitPosition.Invoke(view,new object[]{new System.Collections.Generic.List<int>{0,1},new Vector4(200,100,.3f,.9f),.75f});
                var afterA=(Vector4)rectangle.GetValue(descriptors[0]);var afterB=(Vector4)rectangle.GetValue(descriptors[1]);
                if(!Mathf.Approximately(afterB.x-afterA.x,beforeB.x-beforeA.x)||!Mathf.Approximately(afterB.y-afterA.y,beforeB.y-beforeA.y))throw new InvalidOperationException("Cloud/orbit display unit destroyed intra-word glyph offsets");
                foreach(var index in new[]{0,1}){var anchor=(Vector4)timing.GetValue(descriptors[index]);if(anchor.z!=200||anchor.w!=100)throw new InvalidOperationException("Cloud/orbit display unit anchors differ");}
                var tokenize=typeof(GpuLyricsView).GetMethod("DisplayUnits",BindingFlags.NonPublic|BindingFlags.Static);
                var english=(System.Collections.Generic.List<string>)tokenize.Invoke(null,new object[]{"Singin' in the Rain"});
                if(english.Count!=4)throw new InvalidOperationException("Cloud/orbit must position words, not 18 physical characters");
                Debug.Log("GPU cloud/orbit actual descriptor regrouping preserves word glyph offsets and shared anchors.");
                var articleLayout=typeof(GpuLyricsView).GetMethod("ArticleBlockFrame",BindingFlags.NonPublic|BindingFlags.Static);
                foreach(var viewport in new[]{720f,1440f})foreach(var leading in new[]{true,false}){
                    var articleFrame=(Vector3)articleLayout.Invoke(null,new object[]{viewport,viewport*(leading?.123f:.877f),14});
                    descriptors.Clear();foreach(var rect in new[]{new Vector4(-20,40,24,20),new Vector4(80,40,19,20)}){var seed=Activator.CreateInstance(seedType);rectangle.SetValue(seed,rect);descriptors.Add(seed);}
                    align.Invoke(view,new object[]{0,leading?articleFrame.y:articleFrame.z,!leading});
                    var actual=(Vector2)boundsMethod.Invoke(view,new object[]{0});
                    if(actual.x<24-.01f||actual.y>viewport-24+.01f||Mathf.Abs((leading?actual.x:actual.y)-(leading?24:viewport-24))>.01f)throw new InvalidOperationException("Article actual glyph vertices clipped: "+actual);
                    Debug.Log($"GPU article glyph boundary check: logical={viewport} leading={leading} actual={actual}");
                }
                var wrap=typeof(GpuLyricsView).GetMethod("WrapLines",BindingFlags.NonPublic|BindingFlags.Static);
                Func<string,float> measure=text=>System.Globalization.StringInfo.ParseCombiningCharacters(text).Length*10;
                var articleRows=(string[])wrap.Invoke(null,new object[]{"一二三四五六七八九十一二三四五六七八九十",60f,measure,3});
                if(articleRows.Length!=3)throw new InvalidOperationException("Article three-line context limit failed");
                foreach(var row in articleRows)if(measure(row)>60)throw new InvalidOperationException("Article context row width overflow");
            }finally{UnityEngine.Object.DestroyImmediate(host);}
        }
    }
}
