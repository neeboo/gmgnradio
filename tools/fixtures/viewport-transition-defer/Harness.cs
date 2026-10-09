using System;
using System.Collections.Generic;
using System.Globalization;
using GMGN.UnityPlayer;

/// <summary>
/// Drives the shipped <see cref="ViewportTransition"/> against the measured
/// 2026-10-09 fullscreen timeline and prints key=value lines for
/// `tools/test-viewport-transition-defer.py`.
///
/// The point of the harness is the negative control: the same timeline is also
/// run through a literal transcription of the pre-fix rule (no window at all,
/// so the first rebuild runs on the first moved frame) and that run has to put
/// the one-time warm inside the transition. A gate that cannot show the old
/// behaviour failing pins nothing.
/// </summary>
static class Harness
{
    // Measured on the reported machine (Player.log, 4096x2304 fullscreen):
    // `[LiveCamPointer] fullscreen clicked` then
    // `Metal RecreateSurface: surface size 4096x2304` ~1 ms later, and
    // `NSWindowDidEnterFullScreenNotification` 795 ms after the resize.
    const double RecreateAtSeconds = 0.001;
    const double DidEnterFullScreenSeconds = 0.795;
    const int WindowedWidth = 1440, WindowedHeight = 900;
    const int FullscreenWidth = 4096, FullscreenHeight = 2304;

    /// Frame rates the reported machine actually produced: 14 fps windowed,
    /// 30 fps through the transition, 60/75 as the ceiling.
    static readonly double[] Rates = { 14.0, 30.0, 60.0, 75.0, 240.0 };

    static void Emit(string key, string value)
    {
        Console.WriteLine(key + "=" + value);
    }

    static string Bool(bool value) { return value ? "true" : "false"; }

    static string Num(double value)
    {
        return value.ToString("F3", CultureInfo.InvariantCulture);
    }

    static int Main()
    {
        // The window must be closed before Begin and must open on Begin.
        var probe = new ViewportTransition();
        Emit("window.closedBeforeBegin", Bool(probe.Open));
        probe.Begin();
        Emit("window.opensOnBegin", Bool(probe.Open));
        // A NaN clock must close the window rather than hold it open forever.
        Emit("window.nanClockClosed", Bool(!probe.Observe(WindowedWidth, WindowedHeight, double.NaN)));

        bool coveredAnimation = true;
        bool shippedWarmInside = false;
        bool prefixWarmInside = false;
        double shippedWarmAtMs = -1;
        double prefixWarmAtMs = -1;
        double slowestCloseMs = 0;

        foreach (double fps in Rates)
        {
            var window = new ViewportTransition();
            window.Begin();
            double step = 1.0 / fps;

            bool openAtAnimationEnd = false;
            bool shippedRan = false, prefixRan = false;
            double closeAt = -1;

            for (int frame = 1; frame <= (int)Math.Ceiling(ViewportTransition.MaximumSeconds * fps) + 4; frame++)
            {
                double now = frame * step;
                int width = now >= RecreateAtSeconds ? FullscreenWidth : WindowedWidth;
                int height = now >= RecreateAtSeconds ? FullscreenHeight : WindowedHeight;
                bool moving = window.Observe(width, height, now);
                if (closeAt < 0 && !moving) closeAt = now;

                if (!openAtAnimationEnd && now >= DidEnterFullScreenSeconds) openAtAnimationEnd = moving;

                // The first layout of a track is a whole-content rebuild
                // (warmFontsMs=411.747 of rebuildMs=422.807). Both rules see
                // the same pending warm on the first moved frame.
                if (!shippedRan && !ViewportTransition.DeferFullRebuild(true, moving))
                {
                    shippedRan = true;
                    shippedWarmAtMs = now * 1000.0;
                    if (now < DidEnterFullScreenSeconds) shippedWarmInside = true;
                }
                // Pre-fix rule, transcribed verbatim from HEAD's
                // `GpuLyricsView.LateUpdate`: rebuild unconditionally.
                if (!prefixRan)
                {
                    prefixRan = true;
                    prefixWarmAtMs = now * 1000.0;
                    if (now < DidEnterFullScreenSeconds) prefixWarmInside = true;
                }
            }

            if (!openAtAnimationEnd) coveredAnimation = false;
            if (closeAt < 0 || closeAt > ViewportTransition.MaximumSeconds) slowestCloseMs = double.PositiveInfinity;
            else slowestCloseMs = Math.Max(slowestCloseMs, closeAt * 1000.0);
        }

        Emit("window.coversAnimation", Bool(coveredAnimation));
        Emit("window.maxCloseMs", Num(slowestCloseMs));
        Emit("window.boundMs", Num(ViewportTransition.MaximumSeconds * 1000.0));

        // A framebuffer that never stops changing must still be bounded.
        var hostile = new ViewportTransition();
        hostile.Begin();
        double hostileClose = -1;
        int flip = 0;
        for (int frame = 1; frame <= 600; frame++)
        {
            double now = frame / 60.0;
            bool moving = hostile.Observe(FullscreenWidth + (flip++ % 2), FullscreenHeight, now);
            if (!moving) { hostileClose = now; break; }
        }
        Emit("window.changingFramebufferCloseMs", hostileClose < 0 ? "unbounded" : Num(hostileClose * 1000.0));
        Emit("window.changingFramebufferBounded",
            Bool(hostileClose >= 0 && hostileClose <= ViewportTransition.MaximumSeconds));

        Emit("shipped.warm.insideTransition", Bool(shippedWarmInside));
        Emit("shipped.warm.atMs", Num(shippedWarmAtMs));
        Emit("prefix.warm.insideTransition", Bool(prefixWarmInside));
        Emit("prefix.warm.atMs", Num(prefixWarmAtMs));

        // The shipped window must not be so long that it swallows ordinary
        // windowed resizes: it is bounded, and the cheap rebuild path is never
        // gated, so only the one-time warm waits.
        Emit("window.minimumMs", Num(ViewportTransition.MinimumSeconds * 1000.0));
        Emit("shipped.defersCheapRebuild", Bool(ViewportTransition.DeferFullRebuild(false, true)));
        Emit("shipped.defersWarmOutsideTransition", Bool(ViewportTransition.DeferFullRebuild(true, false)));
        return 0;
    }
}
