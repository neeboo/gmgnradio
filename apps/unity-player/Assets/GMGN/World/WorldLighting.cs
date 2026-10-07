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
        SphericalHarmonicsL2 roomAmbient;
        bool changedAmbient;
        public bool ApplyCapturedAmbient()
        {
            if (!changedAmbient) return false;
            RenderSettings.ambientMode = AmbientMode.Custom;
            RenderSettings.ambientProbe = roomAmbient;
            return true;
        }
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
            Debug.Log("[WorldLighting] capture_texture type=" + probe.texture.GetType().Name + " format=" + probe.texture.graphicsFormat + " dimension=" + probe.texture.dimension);
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
                    var sum = 0.0; var count = 0;
                    var totalInvalid = 0;
                    for (var face = 0; face < 6; face++)
                    {
                        var pixels = request.GetData<Color>(face);
                        if (pixels.Length != facePixels) { Debug.LogWarning("[WorldLighting] reflection_face_size_invalid face=" + face); return; }
                        var invalid = 0; var valid = 0; var peak = 0f;
                        for (var i = 0; i < pixels.Length; i++)
                        {
                            var color = pixels[i];
                            if (!Finite(color)) { invalid++; continue; }
                            valid++; peak = Mathf.Max(peak, color.r, color.g, color.b);
                            if (i % step == 0) { sum += System.Math.Max(0.0, ((double)color.r + color.g + color.b) / 3); count++; }
                        }
                        totalInvalid += invalid;
                        Debug.Log("[WorldLighting] face=" + face + " valid=" + valid + " nonfinite=" + invalid + " peak=" + peak.ToString("F4", System.Globalization.CultureInfo.InvariantCulture));
                    }
                    var average = count == 0 ? 0 : sum / count;
                    Debug.Log("[WorldLighting] reflection_mean_radiance=" + average.ToString("F5", System.Globalization.CultureInfo.InvariantCulture));
                    if (totalInvalid > 0) Debug.LogWarning("[WorldLighting] reflection_contains_nonfinite_pixels total=" + totalInvalid + "; integrator excludes these pixels; capture pipeline requires repair");
                    if (count == 0) Debug.LogWarning("[WorldLighting] reflection_has_no_valid_samples");
                    else if (average < 0.00001f) Debug.LogWarning("[WorldLighting] captured_room_is_black");
                    else
                    {
                        // Integrate irradiance from the actual rendered room.
                        // No fabricated ambient color or material recoloring.
                        var stride = Mathf.Max(1, size / 16);
                        var harmonics = new SphericalHarmonicsL2();
                        var integrated = 0;
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
                                    if (!Finite(color)) continue;
                                    harmonics.AddDirectionalLight(CubeDirection(face, u, v).normalized, color, solidAngle);
                                    integrated++;
                                }
                        }
                        if (integrated == 0) { Debug.LogWarning("[WorldLighting] diffuse_no_valid_samples"); return; }
                        for (var channel = 0; channel < 3; channel++) for (var coefficient = 0; coefficient < 9; coefficient++)
                            if (!Finite(harmonics[channel, coefficient])) { Debug.LogWarning("[WorldLighting] diffuse_nonfinite_coefficients"); return; }
                        roomAmbient = harmonics;
                        changedAmbient = true;
                        // A readback may complete after switching to Player.
                        // Cache it without changing the currently visible mode.
                        if (gameObject.activeInHierarchy) ApplyCapturedAmbient();
                        Debug.Log("[WorldLighting] room_diffuse_irradiance_ready validSamples=" + integrated);
                    }
                });
        }
        static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        static bool Finite(Color color) => Finite(color.r) && Finite(color.g) && Finite(color.b) && Finite(color.a);
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
    }
}
