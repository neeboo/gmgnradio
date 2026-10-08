using System;
using System.Runtime.InteropServices;
using UnityEngine;

// Isolated fixture only. Explicitly add to a private Player scene to run the experiment.
// No business host, audio, world ownership, or production registration is created.
public sealed class OverlayProbeBehaviour : MonoBehaviour
{
    const string Library = "gmgn_gpui_overlay_probe";
    [DllImport(Library)] static extern int gmgn_overlay_register_current_unity_window();
    [DllImport(Library)] static extern IntPtr gmgn_overlay_unity_content_view();
    [DllImport(Library)] static extern int gmgn_gpui_probe_mount(IntPtr parent);
    [DllImport(Library)] static extern void gmgn_gpui_probe_unmount();
    bool mounted;
    void Start()
    {
        // Unity Start runs on its main thread. No arbitrary window pointers are accepted.
        try {
            if (gmgn_overlay_register_current_unity_window() != 1) {
                Debug.LogError("聊天2: Unity window unavailable or ambiguous."); return;
            }
            var parent = gmgn_overlay_unity_content_view();
            mounted = parent != IntPtr.Zero && gmgn_gpui_probe_mount(parent) == 0;
            if (!mounted) Debug.LogError("聊天2: actual GPUI mount failed.");
        } catch (DllNotFoundException) { Debug.LogError("聊天2: probe library missing."); }
          catch (EntryPointNotFoundException) { Debug.LogError("聊天2: probe ABI missing."); }
    }
    void OnDestroy() { if (mounted) { gmgn_gpui_probe_unmount(); mounted = false; } }
}
