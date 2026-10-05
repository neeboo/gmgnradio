using UnityEngine;

namespace GMGN.UnityPlayer
{
    // Independent from player/world visibility. Never reads geometry or image buffers.
    public sealed class GpuFrameDiagnostics : MonoBehaviour
    {
        readonly FrameTiming[] timings = new FrameTiming[1];
        double nextReport;
        static int stageFrame = -1, stagePoints;
        static double stageSubmitMs;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Register()
        {
            stageFrame = -1;
            new GameObject("GPU frame diagnostics").AddComponent<GpuFrameDiagnostics>();
        }

        public static void RecordStageSubmit(int points, double milliseconds)
        {
            stageFrame = Time.frameCount;
            stagePoints = points;
            stageSubmitMs = milliseconds;
        }

        void LateUpdate()
        {
            bool enabled = FrameTimingManager.IsFeatureEnabled();
            if (enabled) FrameTimingManager.CaptureFrameTimings();
            double now = Time.realtimeSinceStartupAsDouble;
            if (now < nextReport) return;
            nextReport = now + 5;
            uint count = enabled ? FrameTimingManager.GetLatestTimings(1, timings) : 0;
            var camera = Camera.main;
            string timing = count > 0
                ? $"cpuMs={timings[0].cpuFrameTime:F3} gpuMs={timings[0].gpuFrameTime:F3} gpuAvailable={timings[0].gpuFrameTime > 0}"
                : $"finishedFrameTimingUnavailable enabled={enabled}";
            bool stageActive = Time.frameCount - stageFrame <= 1 && stageFrame >= 0;
            Debug.Log($"GPU frame timing {timing} stageActive={stageActive} stageSubmitMs={(stageActive ? stageSubmitMs : 0):F3} points={(stageActive ? stagePoints : 0)} screen={Screen.width}x{Screen.height} camera={camera?.pixelWidth}x{camera?.pixelHeight} scaledCamera={camera?.scaledPixelWidth}x{camera?.scaledPixelHeight} fullscreen={Screen.fullScreen}/{Screen.fullScreenMode} display={Screen.currentResolution.width}x{Screen.currentResolution.height}");
        }
    }
}
