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
            if (Marshal.SizeOf(seedType) != 128)
                throw new InvalidOperationException("GPU lyric seed stride mismatch");
            ValidateContextBounds(seedType);
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
            Debug.Log("GPU lyrics build diagnostics passed; 128-byte seed and shader resources present. Runtime capture still required.");
        }
        static void ValidateContextBounds(Type seedType){
            const BindingFlags flags=BindingFlags.NonPublic|BindingFlags.Instance;
            var layout=typeof(GpuLyricsView).GetMethod("FlowContextLayout",BindingFlags.NonPublic|BindingFlags.Static);
            var align=typeof(GpuLyricsView).GetMethod("AlignGlyphRange",flags);
            var boundsMethod=typeof(GpuLyricsView).GetMethod("GlyphRangeBounds",flags);
            var rectangle=seedType.GetField("rectangle");
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
                            var seed=Activator.CreateInstance(seedType);rectangle.SetValue(seed,rect);descriptors.Add(seed);
                        }
                        var anchor=trailing?frame.z:frame.y;
                        align.Invoke(view,new object[]{0,anchor,trailing});
                        var bounds=(Vector2)boundsMethod.Invoke(view,new object[]{0});
                        if(bounds.x<24-.01f||bounds.y>viewport-24+.01f || Mathf.Abs((trailing?bounds.y:bounds.x)-(trailing?expectedRight:expectedLeft))>.01f)
                            throw new InvalidOperationException($"Flow actual descriptor bounds failed: viewport={viewport} trailing={trailing} bounds={bounds}");
                        Debug.Log($"GPU Flow descriptor bounds verified: logical={viewport} trailing={trailing} bounds={bounds}");
                    }
                }
            }finally{UnityEngine.Object.DestroyImmediate(host);}
        }
    }
}
