namespace GMGN.UnityPlayer
{
    /// <summary>
    /// Bounded window around a native framebuffer move. `Screen.SetResolution`
    /// recreates Unity's Metal surface synchronously (`Metal RecreateSurface`
    /// 1440x900 -> 4096x2304, 8.1x the pixels) and AppKit then animates the
    /// window for most of a second, so `Screen.width/height` and the UI panel
    /// scale keep moving for many frames after the request.
    ///
    /// A view that starts a one-time, whole-content GPU rebuild on the first
    /// moved frame pays that entire cost on the transition frame. On the
    /// reported machine the GPUI overlay is an NSView mounted inside this same
    /// process (`GPUIChat2Probe.gmgn_gpui_probe_mount` in the Unity window's
    /// content view), so the same main-thread stall is what shows up as the
    /// "no overlay frame" gap in the transition.
    ///
    /// This type is deliberately pure: it references no UnityEngine type, so
    /// `tools/test-viewport-transition-defer.py` compiles exactly this file
    /// with the Unity-bundled Roslyn compiler and drives it against the
    /// measured timeline. The bound below cannot rot without the gate going red.
    /// </summary>
    public struct ViewportTransition
    {
        /// The window never closes before this, so it always covers AppKit's
        /// animation. Measured entry on the reported machine (229, 4096x2304):
        /// `NSWindowDidResizeNotification` 56.092 -> `NSWindowDidEnterFullScreenNotification`
        /// 56.887 = 795 ms.
        public const double MinimumSeconds = 1.0;

        /// The window always closes by this, however the framebuffer behaves,
        /// so a moved framebuffer can never suppress a rebuild indefinitely.
        public const double MaximumSeconds = 2.0;

        /// Consecutive unchanged framebuffer observations that end the window
        /// once `MinimumSeconds` has passed. The surface is recreated about a
        /// millisecond after the request, so this only trims the tail; it can
        /// never end the window inside the animation.
        public const int RequiredStableFrames = 3;

        int width, height, stableFrames;
        bool open;

        public bool Open { get { return open; } }

        /// Start the window. Called by the only code path that moves the
        /// framebuffer (`NativeUIScale.ToggleFullscreen`).
        public void Begin()
        {
            open = true;
            width = 0;
            height = 0;
            stableFrames = 0;
        }

        /// End the window early. Safe to call when it is already closed.
        public void End()
        {
            open = false;
            stableFrames = 0;
        }

        /// One main-thread frame. `elapsedSeconds` is the time since `Begin`.
        /// Returns true while the framebuffer may still be moving.
        public bool Observe(int nextWidth, int nextHeight, double elapsedSeconds)
        {
            if (!open) return false;
            // `!(x < max)` rather than `x >= max` so a NaN clock closes the
            // window instead of holding it open forever.
            if (!(elapsedSeconds < MaximumSeconds)) { End(); return false; }
            if (nextWidth != width || nextHeight != height) {
                width = nextWidth;
                height = nextHeight;
                stableFrames = 0;
            } else stableFrames++;
            if (elapsedSeconds >= MinimumSeconds && stableFrames >= RequiredStableFrames) {
                End();
                return false;
            }
            return true;
        }

        /// A whole-content rebuild carries a one-time warm of every glyph the
        /// track uses (`GpuLyricsView.WarmFonts`). Measured on the reported
        /// machine: `rebuildMs=422.807; warmFontsMs=411.747` in the transition
        /// frame, against `rebuildMs=0.698; warmFontsMs=0.016` for the same
        /// resize once the warm is done. Only the warm is deferred: the cheap
        /// resize rebuild keeps the previous layout current, and deferring it
        /// would hold a stale layout on screen for no measured gain.
        public static bool DeferFullRebuild(bool fullRebuildPending, bool framebufferMoving)
        {
            return fullRebuildPending && framebufferMoving;
        }
    }
}
