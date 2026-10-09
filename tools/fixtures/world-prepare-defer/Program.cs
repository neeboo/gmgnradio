using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using GMGN.UnityPlayer.World;

// Only the clock and frame pump are simulated. Compile the production defer
// agent and glTFast interface, without starting Unity, a GPU or audio devices.
namespace UnityEngine
{
    public static class Time { public static double realtimeSinceStartupAsDouble; }
}

sealed class FrameContext : SynchronizationContext
{
    readonly Queue<Action> pending = new Queue<Action>();
    public override void Post(SendOrPostCallback callback, object state)
    { pending.Enqueue(() => callback(state)); }
    public void Pump()
    {
        int count = pending.Count;
        for (int i = 0; i < count; i++) pending.Dequeue()();
    }
}

static class Program
{
    static void Require(bool condition, string name)
    { if (!condition) throw new Exception(name); }

    // glTFast ImageImport's actual scheduling pattern, including cancellation.
    static async Task ImageGate(GLTFast.IDeferAgent agent, CancellationToken cancellation)
    {
        while (agent.ShouldDefer())
        {
            cancellation.ThrowIfCancellationRequested();
            await Task.Yield();
        }
        cancellation.ThrowIfCancellationRequested();
    }

    static void Advance(FrameContext context, double seconds)
    {
        UnityEngine.Time.realtimeSinceStartupAsDouble += seconds;
        context.Pump();
    }

    static void FrameProgress(int fps, int parallel)
    {
        var context = new FrameContext();
        SynchronizationContext.SetSynchronizationContext(context);
        UnityEngine.Time.realtimeSinceStartupAsDouble = 0;
        var agent = new WorldPrepareDeferAgent();
        // Seven serial assets, multiple image gates may share the same agent.
        for (int asset = 0; asset < 7; asset++)
        {
            UnityEngine.Time.realtimeSinceStartupAsDouble += 0.005;
            var tasks = new Task[parallel];
            for (int i = 0; i < parallel; i++)
                tasks[i] = ImageGate(agent, CancellationToken.None);
            var all = Task.WhenAll(tasks);
            for (int frame = 0; frame < 4 && !all.IsCompleted; frame++)
                Advance(context, 1.0 / fps);
            Require(all.Status == TaskStatus.RanToCompletion,
                "load stalled: fps=" + fps + " parallel=" + parallel + " asset=" + asset);
        }
    }

    static int Main()
    {
        try
        {
            foreach (int fps in new[] { 10, 30, 56, 60, 75, 120, 240, 500 })
                foreach (int parallel in new[] { 1, 2, 8, 64 }) FrameProgress(fps, parallel);

            UnityEngine.Time.realtimeSinceStartupAsDouble = 0;
            var agent = new WorldPrepareDeferAgent();
            Require(!agent.ShouldDefer(), "fresh budget should allow work");
            UnityEngine.Time.realtimeSinceStartupAsDouble = 0.005;
            Require(agent.ShouldDefer(), "spent budget must still yield");
            UnityEngine.Time.realtimeSinceStartupAsDouble = 2;
            Require(!agent.ShouldDefer(), "resumption after long frame must make progress");
            Require(!agent.ShouldDefer(), "resumption must start a fresh work budget");
            UnityEngine.Time.realtimeSinceStartupAsDouble += 0.005;
            Require(agent.ShouldDefer(0.1f), "duration overload must retain pacing");
            UnityEngine.Time.realtimeSinceStartupAsDouble += 0.020;
            Require(!agent.ShouldDefer(0.1f), "duration overload must make progress");

            var context = new FrameContext();
            SynchronizationContext.SetSynchronizationContext(context);
            UnityEngine.Time.realtimeSinceStartupAsDouble += 0.005;
            using (var cancellation = new CancellationTokenSource())
            {
                var gate = ImageGate(agent, cancellation.Token);
                cancellation.Cancel();
                Advance(context, 0.020);
                Require(gate.IsCanceled, "canceled import must not continue");
            }
            UnityEngine.Time.realtimeSinceStartupAsDouble += 0.005;
            var point = agent.BreakPoint();
            Require(!point.IsCompleted, "BreakPoint must yield after budget exhaustion");
            Advance(context, 0.020);
            Require(point.IsCompleted, "BreakPoint must resume next frame");

            Console.WriteLine("PASS: production defer agent, 32 frame/concurrency cases, seven serial assets, pacing, suspension and cancellation");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine("FAIL: " + error.Message); return 1; }
    }
}
