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
        public static void ToggleFullscreen()
        {
            if (Screen.fullScreen) {
                Screen.SetResolution(windowWidth, windowHeight, FullScreenMode.Windowed);
            } else {
                windowWidth = Screen.width; windowHeight = Screen.height;
                int width = (int)gmgn_unity_screen_pixels(0), height = (int)gmgn_unity_screen_pixels(1);
                if (width > 0 && height > 0) Screen.SetResolution(width, height, FullScreenMode.FullScreenWindow);
            }
        }
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Register()
        {
            QualitySettings.vSyncCount = 0;
            Application.targetFrameRate = 60;
            new GameObject("Native UI scale").AddComponent<NativeUIScale>();
        }
        void Update()
        {
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
