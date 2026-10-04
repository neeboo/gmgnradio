using System;
using System.Runtime.InteropServices;
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
            if (Marshal.SizeOf(seedType) != 112)
                throw new InvalidOperationException("GPU lyric seed stride mismatch");
            var compute = Resources.Load<ComputeShader>("GpuLyricsUpdate");
            var shader = Resources.Load<Shader>("GpuLyricsDraw");
            if (compute == null || shader == null)
                throw new InvalidOperationException("GPU lyric shader resources missing");
            compute.FindKernel("UpdateLyrics");
            foreach (var message in ShaderUtil.GetComputeShaderMessages(compute))
                if (message.severity == ShaderCompilerMessageSeverity.Error)
                    throw new InvalidOperationException("GPU lyric Compute: " + message.message);
            foreach (var message in ShaderUtil.GetShaderMessages(shader))
                if (message.severity == ShaderCompilerMessageSeverity.Error)
                    throw new InvalidOperationException("GPU lyric draw: " + message.message);
            Debug.Log("GPU lyrics build diagnostics passed; 112-byte seed and shader resources present. Runtime capture still required.");
        }
    }
}
