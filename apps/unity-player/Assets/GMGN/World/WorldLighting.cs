using System.Collections;
using UnityEngine;
using UnityEngine.Rendering;

namespace GMGN.UnityPlayer.World
{
    /// Captures the rendered room itself for metallic glTF lighting. Does not
    /// modify material factors, textures, emission or substitute an unlit shader.
    public sealed class WorldLighting : MonoBehaviour
    {
        ReflectionProbe probe;
        int captureID = -1;
        SphericalHarmonicsL2 previousAmbient;
        AmbientMode previousAmbientMode;
        bool changedAmbient;
        public void Initialize(Vector3 worldPosition)
        {
            if (probe != null) return;
            // Both template quality levels disable realtime probes. Enabling a
            // probe component alone cannot override that engine-level switch.
            QualitySettings.realtimeReflectionProbes = true;
            var holder = new GameObject("Room reflection lighting");
            holder.transform.SetParent(transform, false);
            holder.transform.position = worldPosition;
            probe = holder.AddComponent<ReflectionProbe>();
            probe.mode = ReflectionProbeMode.Realtime;
            probe.refreshMode = ReflectionProbeRefreshMode.ViaScripting;
            probe.timeSlicingMode = ReflectionProbeTimeSlicingMode.AllFacesAtOnce;
            probe.resolution = 128;
            probe.hdr = true;
            probe.boxProjection = true;
            probe.size = new Vector3(64, 64, 64);
            probe.intensity = 1;
            probe.nearClipPlane = 0.05f;
            probe.farClipPlane = 64;
            probe.clearFlags = ReflectionProbeClearFlags.SolidColor;
            probe.backgroundColor = Color.black;
            StartCoroutine(CaptureOnce());
        }

        IEnumerator CaptureOnce()
        {
            // Wait until recovered meshes and Gaussian renderer are active.
            yield return null;
            yield return new WaitForEndOfFrame();
            captureID = probe.RenderProbe();
            Debug.Log("[WorldLighting] capture_requested id=" + captureID + " realtimeProbes=" + QualitySettings.realtimeReflectionProbes);
            if (captureID < 0) { Debug.LogWarning("[WorldLighting] reflection_capture_request_rejected"); yield break; }
            var deadline = Time.realtimeSinceStartup + 15;
            while (probe != null && !probe.IsFinishedRendering(captureID) && Time.realtimeSinceStartup < deadline) yield return null;
            if (probe == null) yield break;
            if (!probe.IsFinishedRendering(captureID) || probe.texture == null)
            { Debug.LogWarning("[WorldLighting] reflection_capture_failed finished=" + probe.IsFinishedRendering(captureID) + " texture=" + (probe.texture != null)); yield break; }
            Debug.Log("[WorldLighting] room_reflection_ready resolution=" + probe.texture.width);
            if (SystemInfo.supportsAsyncGPUReadback)
                AsyncGPUReadback.Request(probe.texture, 0, TextureFormat.RGBAFloat, request => {
                    if (request.hasError) { Debug.LogWarning("[WorldLighting] reflection_readback_failed"); return; }
                    if (probe == null) { Debug.LogWarning("[WorldLighting] reflection_owner_destroyed"); return; }
                    var size = probe.texture.width;
                    var facePixels = size * size;
                    Debug.Log("[WorldLighting] reflection_readback layers=" + request.layerCount + " layerBytes=" + request.layerDataSize + " expectedFacePixels=" + facePixels);
                    if (request.layerCount != 6 || request.layerDataSize != facePixels * 16)
                    { Debug.LogWarning("[WorldLighting] reflection_readback_layout_unsupported"); return; }
                    var step = Mathf.Max(1, facePixels / 1024);
                    var sum = 0f; var count = 0;
                    for (var face = 0; face < 6; face++)
                    {
                        var pixels = request.GetData<Color>(face);
                        if (pixels.Length != facePixels) { Debug.LogWarning("[WorldLighting] reflection_face_size_invalid face=" + face); return; }
                        for (var i = 0; i < pixels.Length; i += step) { var color = pixels[i]; sum += Mathf.Max(0, color.r + color.g + color.b) / 3; count++; }
                    }
                    var average = count == 0 ? 0 : sum / count;
                    Debug.Log("[WorldLighting] reflection_mean_radiance=" + average.ToString("F5", System.Globalization.CultureInfo.InvariantCulture));
                    if (average < 0.00001f) Debug.LogWarning("[WorldLighting] captured_room_is_black");
                    else
                    {
                        // Integrate irradiance from the actual rendered room.
                        // No fabricated ambient color or material recoloring.
                        var stride = Mathf.Max(1, size / 16);
                        var harmonics = new SphericalHarmonicsL2();
                        for (var face = 0; face < 6; face++)
                        {
                            var pixels = request.GetData<Color>(face);
                            for (var y = 0; y < size; y += stride)
                                for (var x = 0; x < size; x += stride)
                                {
                                    var u = 2f * (x + stride * 0.5f) / size - 1;
                                    var v = 2f * (y + stride * 0.5f) / size - 1;
                                    var solidAngle = 4f * stride * stride / (size * size * Mathf.Pow(1 + u * u + v * v, 1.5f));
                                    var color = pixels[y * size + x];
                                    harmonics.AddDirectionalLight(CubeDirection(face, u, v).normalized, color, solidAngle);
                                }
                        }
                        previousAmbient = RenderSettings.ambientProbe;
                        previousAmbientMode = RenderSettings.ambientMode;
                        RenderSettings.ambientMode = AmbientMode.Custom;
                        RenderSettings.ambientProbe = harmonics;
                        changedAmbient = true;
                        Debug.Log("[WorldLighting] room_diffuse_irradiance_ready samples=" + (6 * (size / stride) * (size / stride)));
                    }
                });
        }
        static Vector3 CubeDirection(int face, float u, float v)
        {
            switch (face) {
                case 0: return new Vector3(1, -v, -u);
                case 1: return new Vector3(-1, -v, u);
                case 2: return new Vector3(u, 1, v);
                case 3: return new Vector3(u, -1, -v);
                case 4: return new Vector3(u, -v, 1);
                default: return new Vector3(-u, -v, -1);
            }
        }
        void OnDestroy()
        {
            if (changedAmbient) { RenderSettings.ambientProbe = previousAmbient; RenderSettings.ambientMode = previousAmbientMode; }
        }
    }
}
