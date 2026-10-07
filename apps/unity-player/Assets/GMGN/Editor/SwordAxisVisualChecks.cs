using System;
using System.IO;
using System.Threading;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Editor
{
    public static class SwordAxisVisualChecks
    {
        public static async void Run()
        {
            try {
                var path = Environment.GetEnvironmentVariable("GMGN_GRIP_PROP_GLB");
                var directory = Environment.GetEnvironmentVariable("GMGN_SWORD_AXIS_OUTPUT");
                if (!File.Exists(path) || string.IsNullOrEmpty(directory)) throw new Exception("Actual sword and output directory required");
                Directory.CreateDirectory(directory);
                var model = await new GltfWorldAssetLoader(new GLTFast.UninterruptedDeferAgent())
                    .LoadSceneAsset(path, CancellationToken.None);
                var renderers = model.GetComponentsInChildren<Renderer>();
                if (renderers.Length == 0) throw new Exception("Sword has no renderer");
                var bounds = renderers[0].bounds;
                foreach (var renderer in renderers) bounds.Encapsulate(renderer.bounds);
                RenderSettings.ambientMode = AmbientMode.Flat;
                RenderSettings.ambientLight = Color.white * .65f;
                var lamp = new GameObject("Sword inspection light").AddComponent<Light>();
                lamp.type = LightType.Directional; lamp.intensity = 1.2f;
                lamp.transform.rotation = Quaternion.Euler(30, -30, 0);
                var camera = new GameObject("Sword inspection camera").AddComponent<Camera>();
                camera.orthographic = true; camera.orthographicSize = bounds.size.magnitude * .56f;
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = new Color(.12f, .14f, .18f);
                camera.nearClipPlane = .001f; camera.farClipPlane = 100;
                var target = new RenderTexture(1024, 1024, 24);
                camera.targetTexture = target;
                foreach (var axis in new[] { Vector3.forward, Vector3.back, Vector3.right, Vector3.left, Vector3.up, Vector3.down }) {
                    camera.transform.position = bounds.center + axis * bounds.size.magnitude * 2;
                    camera.transform.LookAt(bounds.center, Mathf.Abs(axis.y) > .5f ? Vector3.forward : Vector3.up);
                    camera.Render();
                    var previous = RenderTexture.active; RenderTexture.active = target;
                    var image = new Texture2D(1024, 1024, TextureFormat.RGB24, false);
                    image.ReadPixels(new Rect(0, 0, 1024, 1024), 0, 0); image.Apply();
                    RenderTexture.active = previous;
                    var name = axis == Vector3.forward ? "positive-z" : axis == Vector3.back ? "negative-z" : axis == Vector3.right ? "positive-x" : axis == Vector3.left ? "negative-x" : axis == Vector3.up ? "positive-y" : "negative-y";
                    File.WriteAllBytes(Path.Combine(directory, name + ".png"), image.EncodeToPNG());
                    UnityEngine.Object.DestroyImmediate(image);
                }
                camera.targetTexture = null; target.Release();
                UnityEngine.Object.DestroyImmediate(target);
                UnityEngine.Object.DestroyImmediate(camera.gameObject);
                UnityEngine.Object.DestroyImmediate(lamp.gameObject);
                UnityEngine.Object.DestroyImmediate(model);
                Debug.Log("PASS actual sword local XYZ inspection images generated; no audio or formal state changes");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
        }
    }
}
