using System;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class ArtworkOrientationChecks
    {
        public static void Run()
        {
            Texture2D artwork = null;
            GraphicsBuffer seeds = null, output = null;
            ComputeShader compute = null;
            try {
                if (!SystemInfo.supportsComputeShaders) throw new Exception("Real GPU required");
                artwork = new Texture2D(2, 2, TextureFormat.RGBA32, false, true);
                artwork.SetPixels(new[] { Color.blue, Color.blue, Color.red, Color.red });
                artwork.wrapMode = TextureWrapMode.Clamp;
                artwork.filterMode = FilterMode.Point;
                artwork.Apply();
                var points = new[] {
                    new GpuPointSeed { position = new Vector4(0, 1.5f, 0, 1), timing = new Vector4(1, -1, 4, 0) },
                    new GpuPointSeed { position = new Vector4(0, -1.5f, 0, 1), timing = new Vector4(1, -1, 4, 0) }
                };
                seeds = new GraphicsBuffer(GraphicsBuffer.Target.Structured, 2, 48);
                output = new GraphicsBuffer(GraphicsBuffer.Target.Structured, 2, 48);
                seeds.SetData(points);
                compute = UnityEngine.Object.Instantiate(Resources.Load<ComputeShader>("GpuStagePointsUpdate"));
                var kernel = compute.FindKernel("UpdatePoints");
                compute.SetBuffer(kernel, "_Seeds", seeds);
                compute.SetBuffer(kernel, "_Points", output);
                compute.SetTexture(kernel, "_Artwork", artwork);
                compute.SetInt("_PointCount", 2);
                compute.SetInt("_HasArtwork", 1);
                compute.SetFloat("_Clock", 0);
                compute.SetFloat("_Intensity", 0);
                compute.SetVector("_Features", Vector4.zero);
                compute.SetVector("_Preset", new Vector4(1, 0, 0, 0));
                compute.SetVector("_Rhythm", Vector4.zero);
                compute.SetVector("_WaveA", Vector4.zero);
                compute.SetVector("_WaveB", Vector4.zero);
                compute.SetVector("_Layering", Vector4.one);
                compute.Dispatch(kernel, 1, 1, 1);
                output.GetData(points);
                if (points[0].position.y <= points[1].position.y ||
                    points[0].color.x <= points[0].color.z || points[1].color.z <= points[1].color.x)
                    throw new Exception($"Artwork upside down: top={points[0].color}, bottom={points[1].color}");
                Debug.Log("PASS artwork orientation: real GPU top red / bottom blue, world Y upright; no audio");
                EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error);
                EditorApplication.Exit(1);
            } finally {
                seeds?.Dispose(); output?.Dispose();
                if (artwork != null) UnityEngine.Object.DestroyImmediate(artwork);
                if (compute != null) UnityEngine.Object.DestroyImmediate(compute);
            }
        }
    }
}
