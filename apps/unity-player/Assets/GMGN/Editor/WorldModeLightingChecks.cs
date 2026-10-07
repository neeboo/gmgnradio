using System;
using System.Reflection;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Editor
{
    public static class WorldModeLightingChecks
    {
        public static void Run()
        {
            var originalMode = RenderSettings.ambientMode;
            var originalProbe = RenderSettings.ambientProbe;
            var root = new GameObject("Lighting regression");
            try {
                var lighting = root.AddComponent<WorldLighting>();
                if (lighting.ApplyCapturedAmbient()) throw new Exception("Uncaptured ambient must not replace active lighting");
                var captured = new SphericalHarmonicsL2();
                captured.AddAmbientLight(new Color(.4f, .2f, .1f));
                var flags = BindingFlags.NonPublic | BindingFlags.Instance;
                typeof(WorldLighting).GetField("roomAmbient", flags).SetValue(lighting, captured);
                typeof(WorldLighting).GetField("changedAmbient", flags).SetValue(lighting, true);
                for (var i = 0; i < 10; i++) {
                    root.SetActive(false);
                    RenderSettings.ambientMode = AmbientMode.Flat;
                    RenderSettings.ambientProbe = new SphericalHarmonicsL2();
                    root.SetActive(true);
                    if (!lighting.ApplyCapturedAmbient() || RenderSettings.ambientMode != AmbientMode.Custom)
                        throw new Exception("Cached room ambient was not restored");
                    for (var c = 0; c < 3; c++) for (var k = 0; k < 9; k++)
                        if (Mathf.Abs(RenderSettings.ambientProbe[c,k] - captured[c,k]) > .00001f)
                            throw new Exception("Captured room irradiance changed during mode switching");
                }
                Debug.Log("[WorldModeLightingChecks] PASS ten mode cycles preserve captured room irradiance");
            } finally {
                UnityEngine.Object.DestroyImmediate(root);
                RenderSettings.ambientMode = originalMode;
                RenderSettings.ambientProbe = originalProbe;
            }
        }
    }
}
