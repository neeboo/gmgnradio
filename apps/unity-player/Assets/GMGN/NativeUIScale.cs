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
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Register() => new GameObject("Native UI scale").AddComponent<NativeUIScale>();
        void Update()
        {
            if (Time.unscaledTime < nextCheck) return;
            nextCheck = Time.unscaledTime + .5f;
            if (Screen.fullScreen) {
                int widthPixels = (int)gmgn_unity_screen_pixels(0), heightPixels = (int)gmgn_unity_screen_pixels(1);
                if (widthPixels > 0 && heightPixels > 0 && (Screen.width != widthPixels || Screen.height != heightPixels)) {
                    Screen.SetResolution(widthPixels, heightPixels, FullScreenMode.FullScreenWindow);
                    return;
                }
            }
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
