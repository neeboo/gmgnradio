using System;
using System.Globalization;
using System.Collections;
using System.Reflection;
using System.Runtime.InteropServices;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class StageVideoOrientationChecks
    {
        [InitializeOnLoadMethod] static void InstallBackbufferCheck() {
            EditorApplication.playModeStateChanged += state => {
                if (state != PlayModeStateChange.EnteredPlayMode || !SessionState.GetBool("GMGN.StageVideoBackbufferCheck", false)) return;
                SessionState.SetBool("GMGN.StageVideoBackbufferCheck", false);
                foreach (var scale in UnityEngine.Object.FindObjectsByType<NativeUIScale>(FindObjectsSortMode.None)) UnityEngine.Object.DestroyImmediate(scale.gameObject);
                Verify();
            };
        }
        public static void VerifyBackbuffer() {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            // Prevent the product's runtime bootstrap from opening its native backend.
            var sentinel = new GameObject("Disabled product bootstrap sentinel");
            sentinel.AddComponent<PlayerScreen>().enabled = false;
            var gameView = EditorWindow.GetWindow(typeof(EditorWindow).Assembly.GetType("UnityEditor.GameView"));
            gameView.position = new Rect(0, 0, 1440, 924); gameView.Show();
            SessionState.SetBool("GMGN.StageVideoBackbufferCheck", true); EditorApplication.EnterPlaymode();
        }
        [DllImport("/usr/lib/libSystem.B.dylib")] static extern IntPtr dlopen(string path, int mode);
        [DllImport("/usr/lib/libSystem.B.dylib")] static extern IntPtr dlsym(IntPtr handle, string name);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr TexturePointer();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Dimension();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate uint Pixel(int x, int y);
        public static void Verify()
        {
            var libraryPath = Environment.GetEnvironmentVariable("GMGN_STAGE_VIDEO_FIXTURE_LIBRARY");
            bool native = !string.IsNullOrEmpty(libraryPath);
            bool backbuffer = EditorApplication.isPlaying;
            int targetWidth = native ? 1440 : 128, targetHeight = native ? 900 : 128;
            if (backbuffer) { targetWidth = Screen.width; targetHeight = Screen.height; }
            IntPtr nativePointer = IntPtr.Zero; int nativeWidth = 0, nativeHeight = 0; Pixel nativePixel = null; TexturePointer nativeTexture = null;
            if (native) {
                var library = dlopen(libraryPath, 2);
                if (library == IntPtr.Zero) throw new Exception("Cannot load native video fixture.");
                nativeTexture = Marshal.GetDelegateForFunctionPointer<TexturePointer>(dlsym(library, "stage_fixture_texture")); nativePointer = nativeTexture();
                nativeWidth = Marshal.GetDelegateForFunctionPointer<Dimension>(dlsym(library, "stage_fixture_width"))();
                nativeHeight = Marshal.GetDelegateForFunctionPointer<Dimension>(dlsym(library, "stage_fixture_height"))();
                nativePixel = Marshal.GetDelegateForFunctionPointer<Pixel>(dlsym(library, "stage_fixture_pixel"));
                if (nativePointer == IntPtr.Zero || nativeWidth != 898 || nativeHeight != 450) throw new Exception("Original MP4 native fixture unavailable.");
            }
            var host = new GameObject("Stage video orientation fixture");
            var target = new RenderTexture(targetWidth, targetHeight, 0); target.Create();
            var settings = ScriptableObject.CreateInstance<PanelSettings>();
            settings.targetTexture = backbuffer ? null : target; settings.scaleMode = PanelScaleMode.ConstantPixelSize;
            var document = host.AddComponent<UIDocument>(); document.panelSettings = settings;
            var root = document.rootVisualElement; root.style.width = targetWidth; root.style.height = targetHeight;
            var controller = host.AddComponent<UnityScreenVideoController>(); controller.Initialize(root, _ => true);
            controller.SetWorldVisible(false);
            // The host sends snapshots with no decoded background before its first frame,
            // and after stop. Unity's Image.image=null resets UV to its default rectangle.
            controller.ApplySnapshot(new JObject());
            var imageBeforeFrame = root[0] as Image;
            if (imageBeforeFrame.uv != new Rect(0, 0, 1, 1)) throw new Exception("Missing-background snapshot must reproduce Image.image=null UV reset.");
            Debug.Log("StageVideoOrientation reproduced missing-background snapshot UV reset to default.");
            // Emulate top-down IOSurface storage: the first raw rows contain red (source top).
            var source = new Texture2D(32, 16, TextureFormat.BGRA32, false, true);
            source.filterMode = FilterMode.Point;
            var pixels = new Color[512];
            for (int y = 0; y < 16; y++) for (int x = 0; x < 32; x++) pixels[y * 32 + x] = y < 8 ? Color.red : Color.blue;
            source.SetPixels(pixels); source.Apply();
            var snapshot = new JObject { ["background"] = new JObject {
                ["width"] = native ? nativeWidth : 32, ["height"] = native ? nativeHeight : 16, ["format"] = "bgra8",
                ["texturePointer"] = unchecked((ulong)(native ? nativePointer : source.GetNativeTexturePtr()).ToInt64()).ToString("x", CultureInfo.InvariantCulture)
            }};
            controller.ApplySnapshot(snapshot);
            var image = root[0] as Image;
            image.style.width = targetWidth; image.style.height = targetHeight;
            int phase = 0; double deadline = EditorApplication.timeSinceStartup + 1;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                var readback = new Texture2D(targetWidth, targetHeight, TextureFormat.RGBA32, false);
                try {
                    // Edit mode does not drive the runtime panel render loop automatically.
                    if (native && Environment.GetEnvironmentVariable("GMGN_STAGE_VIDEO_FIXTURE_REPLACE_TEXTURE") == "1") {
                        var changed = nativeTexture();
                        if (changed == IntPtr.Zero || changed == nativePointer) throw new Exception("Native fixture must deliver a new Metal texture identity.");
                        Debug.Log($"Native texture identity changed {nativePointer.ToInt64():x} -> {changed.ToInt64():x}");
                        nativePointer = changed; snapshot["background"]["texturePointer"] = unchecked((ulong)changed.ToInt64()).ToString("x", CultureInfo.InvariantCulture);
                    }
                    controller.ApplySnapshot(snapshot); // Match the Player's recurring Image.image assignment.
                    if (image.uv != new Rect(0, 1, 1, -1)) throw new Exception("Background binding must restore native UV after a missing frame.");
                    if (phase == 2) {
                        image.uv = new Rect(0, 0, 1, 1); image.MarkDirtyRepaint();
                        RuntimePanelUtils.ResetRenderer(root.panel);
                    }
                    var panel = root.panel;
                    if (!backbuffer) {
                    panel.GetType().GetMethod("Update", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).Invoke(panel, null);
                    panel.GetType().GetMethod("UpdateForRepaint", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).Invoke(panel, null);
                    panel.GetType().GetMethod("Repaint", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).Invoke(panel, null);
                    bool screenBranch = Environment.GetEnvironmentVariable("GMGN_STAGE_VIDEO_FIXTURE_SCREEN") == "1";
                    if (screenBranch) {
                        // Exercise BaseRuntimePanel.Render's screen branch while capturing its framebuffer.
                        var field = panel.GetType().GetField("targetTexture", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                        field.SetValue(panel, null); RenderTexture.active = target;
                    }
                    panel.GetType().GetMethod("Render", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).Invoke(panel, null);
                    var previous = RenderTexture.active; RenderTexture.active = target;
                    readback.ReadPixels(new Rect(0, 0, targetWidth, targetHeight), 0, 0); readback.Apply(); RenderTexture.active = previous;
                    } else {
                        UnityEngine.Object.DestroyImmediate(readback); readback = ScreenCapture.CaptureScreenshotAsTexture();
                        if (readback.width != targetWidth || readback.height != targetHeight) {
                            Debug.Log($"GameView framebuffer settled {targetWidth}x{targetHeight} -> {readback.width}x{readback.height}");
                            targetWidth = readback.width; targetHeight = readback.height;
                            root.style.width = image.style.width = targetWidth; root.style.height = image.style.height = targetHeight;
                            UnityEngine.Object.DestroyImmediate(readback); deadline = EditorApplication.timeSinceStartup + .5; return;
                        }
                    }
                    var top = readback.GetPixel(64, 96); var bottom = readback.GetPixel(64, 32);
                    var capturePrefix = Environment.GetEnvironmentVariable("GMGN_STAGE_VIDEO_FIXTURE_CAPTURE_PREFIX");
                    if (!string.IsNullOrEmpty(capturePrefix)) System.IO.File.WriteAllBytes(capturePrefix + "-" + phase + ".png", readback.EncodeToPNG());
                    Debug.Log($"StageVideoOrientation phase={phase} actualUI={image.worldBound} top={top} bottom={bottom} uv={image.uv}");
                    bool upright = top.r > .8f && top.b < .2f && bottom.b > .8f && bottom.r < .2f;
                    bool inverted = top.b > .8f && top.r < .2f && bottom.r > .8f && bottom.b < .2f;
                    if (native) {
                        double uprightError = 0, invertedError = 0;
                        float scale = Mathf.Max((float)targetWidth / nativeWidth, (float)targetHeight / nativeHeight);
                        float offsetX = (nativeWidth - targetWidth / scale) / 2, offsetY = (nativeHeight - targetHeight / scale) / 2;
                        for (int row = 0; row < 25; row++) for (int column = 0; column < 40; column++) {
                            int x = (column * targetWidth / 40) + targetWidth / 80, y = (row * targetHeight / 25) + targetHeight / 50;
                            int sx = Mathf.Clamp((int)(offsetX + x / scale), 0, nativeWidth - 1);
                            int sy = Mathf.Clamp((int)(offsetY + (targetHeight - 1 - y) / scale), 0, nativeHeight - 1);
                            uint normal = nativePixel(sx, sy), flipped = nativePixel(sx, nativeHeight - 1 - sy);
                            Color actual = readback.GetPixel(x, y);
                            double Error(uint rgb) => Math.Abs(actual.r - ((rgb >> 16) & 255) / 255f) + Math.Abs(actual.g - ((rgb >> 8) & 255) / 255f) + Math.Abs(actual.b - (rgb & 255) / 255f);
                            uprightError += Error(normal); invertedError += Error(flipped);
                        }
                        Debug.Log($"NativeMP4Orientation phase={phase} {nativeWidth}x{nativeHeight} -> {targetWidth}x{targetHeight} uprightError={uprightError:F3} invertedError={invertedError:F3} uvAfterRepeatedSnapshot={image.uv}");
                        upright = uprightError < invertedError * .7; inverted = invertedError < uprightError * .7;
                    }
                    if (phase < 2 && !upright) throw new Exception("Production UI Toolkit external texture must show native top rows at the top, including after missing/stop frames.");
                    if (phase == 2 && !inverted) throw new Exception("Removing the production UV flip must reproduce the inverted negative control.");
                    UnityEngine.Object.DestroyImmediate(readback);
                    if (phase < 2) {
                        if (phase == 0) {
                            controller.ApplySnapshot(new JObject());
                            if (image.uv != new Rect(0, 0, 1, 1) || image.image != null) throw new Exception("Stop/missing-frame snapshot must clear texture and reset UV.");
                            controller.ApplySnapshot(snapshot);
                        } else {
                            image.uv = new Rect(0, 0, 1, 1); image.MarkDirtyRepaint();
                            RuntimePanelUtils.ResetRenderer(root.panel);
                        }
                        phase++; deadline = EditorApplication.timeSinceStartup + .5; return;
                    }
                    Debug.Log("StageVideoOrientationChecks PASS: initial missing-frame and stop/rebind rendered upright; default UV negative control rendered upside-down.");
                    Finish(0);
                } catch (Exception error) { Debug.LogException(error); UnityEngine.Object.DestroyImmediate(readback); Finish(1); }
            };
            void Finish(int code) {
                EditorApplication.update -= check; UnityEngine.Object.DestroyImmediate(host);
                UnityEngine.Object.DestroyImmediate(source); UnityEngine.Object.DestroyImmediate(settings);
                target.Release(); UnityEngine.Object.DestroyImmediate(target); EditorApplication.Exit(code);
            }
            if (backbuffer) host.AddComponent<StageVideoEndFrameProbe>().Check = () => check();
            else EditorApplication.update += check;
        }
    }
    public sealed class StageVideoEndFrameProbe : MonoBehaviour {
        public Action Check;
        IEnumerator Start() { while (true) { yield return new WaitForEndOfFrame(); Check?.Invoke(); } }
    }
}
