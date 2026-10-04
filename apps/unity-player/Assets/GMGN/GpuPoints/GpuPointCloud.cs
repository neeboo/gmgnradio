using System;
using System.Runtime.InteropServices;
using UnityEngine;

namespace GMGN.UnityPlayer
{
    // Layout is shared with both shaders. Build seeds only when content changes.
    [StructLayout(LayoutKind.Sequential)]
    public struct GpuPointSeed
    {
        public Vector4 position; // xyz local position, w radius
        public Vector4 color;
        public Vector4 timing; // x highlight start, y end, z audio band (0..2), w phase
    }

    public sealed class GpuPointCloud : MonoBehaviour
    {
        public Bounds localBounds = new Bounds(Vector3.zero, Vector3.one * 20);
        public int PointCount { get; private set; }
        public string Status { get; private set; } = "Not initialized";
        public bool IsGpuReady => compute != null && material != null;
        GraphicsBuffer seeds, points;
        ComputeShader compute;
        Material material;
        MaterialPropertyBlock properties;
        int kernel;
        float clock;
        Vector4 features;

        public bool Initialize()
        {
            if (IsGpuReady) return true;
            if (!SystemInfo.supportsComputeShaders || SystemInfo.graphicsShaderLevel < 45)
                return Fail("GPU point rendering unavailable on this graphics device");
            var source = Resources.Load<ComputeShader>("GpuPointsUpdate");
            var shader = Resources.Load<Shader>("GpuPointsDraw");
            if (source == null || shader == null || !shader.isSupported)
                return Fail("GPU point shaders missing or unsupported");
            compute = Instantiate(source);
            material = new Material(shader);
            kernel = compute.FindKernel("UpdatePoints");
            properties = new MaterialPropertyBlock();
            Status = "GPU ready";
            return true;
        }

        bool Fail(string message) { Status = message; Debug.LogError(message, this); return false; }

        public bool SetPoints(GpuPointSeed[] content)
        {
            if (content == null) throw new ArgumentNullException(nameof(content));
            if (!Initialize()) return false;
            ReleaseBuffers();
            PointCount = content.Length;
            if (PointCount == 0) return true;
            seeds = new GraphicsBuffer(GraphicsBuffer.Target.Structured, PointCount, 48);
            points = new GraphicsBuffer(GraphicsBuffer.Target.Structured, PointCount, 48);
            seeds.SetData(content); // Only upload at content/lyric revision boundaries.
            compute.SetBuffer(kernel, "_Seeds", seeds);
            compute.SetBuffer(kernel, "_Points", points);
            properties.SetBuffer("_Points", points);
            Status = "GPU ready: " + PointCount + " points";
            return true;
        }

        public void SetPlayback(float seconds, bool playing, float bass, float vocal, float treble)
        {
            clock = seconds;
            features = new Vector4(Mathf.Clamp01(bass), Mathf.Clamp01(vocal), Mathf.Clamp01(treble), playing ? 1 : 0);
        }

        void LateUpdate()
        {
            if (!IsGpuReady || PointCount == 0) return;
            compute.SetInt("_PointCount", PointCount);
            compute.SetFloat("_Clock", clock);
            compute.SetVector("_Features", features);
            compute.Dispatch(kernel, (PointCount + 63) / 64, 1, 1);
            properties.SetMatrix("_CloudToWorld", transform.localToWorldMatrix);
            var matrix = transform.localToWorldMatrix;
            var ext = localBounds.extents;
            var x = matrix.MultiplyVector(new Vector3(ext.x, 0, 0));
            var y = matrix.MultiplyVector(new Vector3(0, ext.y, 0));
            var z = matrix.MultiplyVector(new Vector3(0, 0, ext.z));
            var extent = new Vector3(Mathf.Abs(x.x)+Mathf.Abs(y.x)+Mathf.Abs(z.x), Mathf.Abs(x.y)+Mathf.Abs(y.y)+Mathf.Abs(z.y), Mathf.Abs(x.z)+Mathf.Abs(y.z)+Mathf.Abs(z.z));
            var parameters = new RenderParams(material) {
                worldBounds = new Bounds(matrix.MultiplyPoint3x4(localBounds.center), extent * 2),
                matProps = properties, layer = gameObject.layer,
                shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off,
                receiveShadows = false
            };
            Graphics.RenderPrimitives(parameters, MeshTopology.Triangles, 6, PointCount);
        }

        void ReleaseBuffers() { seeds?.Dispose(); points?.Dispose(); seeds = null; points = null; PointCount = 0; }
        void OnDestroy() { ReleaseBuffers(); if (material != null) Destroy(material); if (compute != null) Destroy(compute); }
    }
}
