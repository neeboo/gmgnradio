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
    /// component's `Update()` being pumped. Every `true` is followed by a
    /// `false`, even when the next check arrives several frames later.
    /// Resuming starts a new work budget. The gates still yield frames (the
    /// pacing the library wants) but they cannot livelock. It changes only
    /// *when* load work runs — no package, hash or material check is relaxed.
    public sealed class WorldPrepareDeferAgent : GLTFast.IDeferAgent
    {
        // Work budget between yields. Resuming a yield always permits work,
        // irrespective of time spent waiting for the next frame.
        readonly double windowSeconds;
        double windowStarted;
        bool deferred;

        public WorldPrepareDeferAgent(double windowSeconds = 0.004)
        {
            if (!(windowSeconds > 0)) throw new ArgumentOutOfRangeException(nameof(windowSeconds));
            this.windowSeconds = windowSeconds;
            windowStarted = Time.realtimeSinceStartupAsDouble;
        }

        /// Once a caller yields, the next check permits work and starts a
        /// fresh budget. Charging the wait to the budget would make every
        /// frame longer than 4 ms defer again, starving glTFast's while gates.
        bool Consume()
        {
            var now = Time.realtimeSinceStartupAsDouble;
            if (deferred)
            {
                deferred = false;
                windowStarted = now;
                return false;
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
