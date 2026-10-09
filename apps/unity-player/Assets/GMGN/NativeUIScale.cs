using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    public sealed class NativeUIScale : MonoBehaviour
    {
        [DllImport("UnityMediaHost")] static extern double gmgn_unity_window_width();
        [DllImport("UnityMediaHost")] static extern double gmgn_unity_screen_pixels(int axis);
        float nextCheck;
        float previous;
        float reportAt;
        int frames, slowFrames;
        static int windowWidth = 1440, windowHeight = 900;
        static ViewportTransition viewport;
        static double viewportStartedAt;
        // The only code path that moves the framebuffer also owns the window
        // that says so. `Screen.SetResolution` recreates the Metal surface
        // synchronously and AppKit keeps the window animating afterwards, so
        // views that would otherwise start a whole-content GPU rebuild on the
        // first moved frame read this instead.
        public static bool FramebufferMoving { get { return viewport.Open; } }
        public static void BeginViewportTransition()
        {
            viewport.Begin();
            viewportStartedAt = Time.realtimeSinceStartupAsDouble;
        }
        public static void ToggleFullscreen()
        {
            if (Screen.fullScreen) {
                BeginViewportTransition();
                Screen.SetResolution(windowWidth, windowHeight, FullScreenMode.Windowed);
            } else {
                windowWidth = Screen.width; windowHeight = Screen.height;
                int width = (int)gmgn_unity_screen_pixels(0), height = (int)gmgn_unity_screen_pixels(1);
                if (width > 0 && height > 0) {
                    BeginViewportTransition();
                    Screen.SetResolution(width, height, FullScreenMode.FullScreenWindow);
                }
            }
        }
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Register()
        {
            QualitySettings.vSyncCount = 0;
            Application.targetFrameRate = 75;
            new GameObject("Native UI scale").AddComponent<NativeUIScale>();
        }
        void Update()
        {
            // Drives the bounded transition window from a component that runs
            // every frame, whether or not any lyrics are showing.
            viewport.Observe(Screen.width, Screen.height, Time.realtimeSinceStartupAsDouble - viewportStartedAt);
            frames++;
            if (Time.unscaledDeltaTime > .05f) slowFrames++;
            if (Time.unscaledTime >= reportAt + 5) {
                Debug.Log($"UI performance fps={frames / (Time.unscaledTime - reportAt):F1}; framesOver50ms={slowFrames}; render={Screen.width}x{Screen.height}");
                reportAt = Time.unscaledTime; frames = 0; slowFrames = 0;
            }
            if (Time.unscaledTime < nextCheck) return;
            nextCheck = Time.unscaledTime + .5f;
            var document = FindAnyObjectByType<UIDocument>();
            if (document == null || document.panelSettings == null) return;
            var width = gmgn_unity_window_width();
            if (width <= 0) return;
            var scale = Screen.width / (float)width;
            if (scale <= 0 || Mathf.Approximately(scale, previous)) return;
            document.panelSettings.scale = scale;
            previous = scale;
            Debug.Log($"Native UI scale={scale}; windowPoints={width}; framebuffer={Screen.width}x{Screen.height}");
        }
    }
}
