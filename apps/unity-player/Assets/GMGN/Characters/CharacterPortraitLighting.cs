using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

namespace GMGN.UnityPlayer.Characters
{
    // The desktop portrait has no visible room. Give it a neutral, camera-relative
    // light instead of retaining whichever room light happens to face its back.
    public sealed class CharacterPortraitLighting : IDisposable
    {
        readonly Dictionary<Light, bool> sceneLights = new();
        readonly AmbientMode ambientMode = RenderSettings.ambientMode;
        readonly Color ambientLight = RenderSettings.ambientLight;
        readonly SphericalHarmonicsL2 ambientProbe = RenderSettings.ambientProbe;
        readonly Light sun = RenderSettings.sun;
        readonly Light key;
        bool disposed;

        public CharacterPortraitLighting()
        {
            key = new GameObject("Portrait key light").AddComponent<Light>();
            key.type = LightType.Directional;
            key.color = Color.white;
            key.intensity = .9f;
            key.shadows = LightShadows.None;
            Apply();
        }

        public void Apply()
        {
            if (disposed) return;
            foreach (var light in UnityEngine.Object.FindObjectsByType<Light>(FindObjectsInactive.Include)) {
                if (light == key) continue;
                if (!sceneLights.ContainsKey(light)) sceneLights.Add(light, light.enabled);
                light.enabled = false;
            }
            RenderSettings.sun = key;
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = new Color(.4f, .4f, .4f);
            var probe = new SphericalHarmonicsL2();
            probe.AddAmbientLight(RenderSettings.ambientLight);
            RenderSettings.ambientProbe = probe;
        }

        public void FollowCamera(Transform camera)
        {
            if (!disposed && camera != null)
                key.transform.rotation = camera.rotation * Quaternion.Euler(12, -15, 0);
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            foreach (var entry in sceneLights) if (entry.Key != null) entry.Key.enabled = entry.Value;
            sceneLights.Clear();
            RenderSettings.sun = sun;
            RenderSettings.ambientMode = ambientMode;
            RenderSettings.ambientLight = ambientLight;
            RenderSettings.ambientProbe = ambientProbe;
            if (key != null) {
                key.enabled = false;
                UnityEngine.Object.Destroy(key.gameObject);
            }
        }
    }
}
