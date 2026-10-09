using System;
using System.Threading.Tasks;
using UnityEngine;

namespace GMGN.UnityPlayer.World
{
    /// Bounded, self-clocked defer agent for the world prepare transaction.
    ///
    /// GLTFast's loaders contain progress gates written as
    /// `while (ShouldDefer()) await Task.Yield();` (image import, mesh/accessor
    /// waits). Those loops only ever finish if `ShouldDefer()` eventually
    /// answers `false`, and the library's default agent answers from a *frame
    /// budget* that a hidden, implicitly created `TimeBudgetPerFrameDeferAgent`
    /// component refreshes in its own `Update()` — `0.5 / Application
    /// .targetFrameRate` = 6.7 ms here, against ~92 ms frames. When the answer
    /// stays `true` the whole prepare parks in `prepare` with no log, no
    /// exception and no scheduled work (measured 2026-10-09 on the real
    /// machine: `phase=prepare` for 30+ minutes, the first generated prop's
    /// GLB still open, every job worker idle).
    ///
    /// This agent owns its own clock, so it never depends on another
    /// component's `Update()` being pumped, and it never defers twice in a row
    /// inside one window: every `true` is followed by a `false` for the next
    /// check of the same window. The gates therefore still yield frames (the
    /// pacing the library wants) but they cannot livelock. It changes only
    /// *when* load work runs — no package, hash or material check is relaxed.
    public sealed class WorldPrepareDeferAgent : GLTFast.IDeferAgent
    {
        // One yield per window. Small enough to keep the import running,
        // large enough that a frame is not dominated by the loader.
        readonly double windowSeconds;
        double windowStarted;
        bool deferred;

        public WorldPrepareDeferAgent(double windowSeconds = 0.004)
        {
            if (!(windowSeconds > 0)) throw new ArgumentOutOfRangeException(nameof(windowSeconds));
            this.windowSeconds = windowSeconds;
            windowStarted = Time.realtimeSinceStartupAsDouble;
        }

        /// Answers at most one `true` per window, then `false` until the next
        /// window starts. Callers that loop on this answer always make
        /// progress.
        bool Consume()
        {
            var now = Time.realtimeSinceStartupAsDouble;
            if (deferred)
            {
                if (now - windowStarted < windowSeconds) return false;
                deferred = false;
            }
            if (now - windowStarted < windowSeconds) return false;
            deferred = true;
            windowStarted = now;
            return true;
        }

        public bool ShouldDefer() => Consume();
        public bool ShouldDefer(float duration) => Consume();
        public async Task BreakPoint() { if (Consume()) await Task.Yield(); }
        public async Task BreakPoint(float duration) { if (Consume()) await Task.Yield(); }
    }
}
