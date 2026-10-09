using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using GMGN.UnityPlayer;

// Cost harness for one GPUI poll. It compiles the *shipped* `GPUIProjectionPayload` and times it
// against a literal transcription of the pre-fix shape, on the same envelope, in the same process.
//
// Usage: dotnet CostHarness.dll <envelope.json> [iterations] [seed]
// Prints `prefix.<stat>=`, `shipped.<stat>=` and `equal=<bool>` lines; the caller asserts them.
static class CostHarness
{
    /// The 2026-10-09 16:00 code path, verbatim in shape:
    /// NativePlayerBackend.Tick parsed the envelope, PublishGPUIProjection deep-cloned the whole tree
    /// and serialized it to a string, and GPUIChat2Probe.ApplySnapshot parsed that string again,
    /// cloned its adjuncts, and serialized the payload a second time through UTF-16.
    static byte[] PreFix(string json, JToken inventory, JToken worldAuthority, JToken ui,
        JToken uiCommandResult, JToken settingsCommandResult)
    {
        var parsed = JObject.Parse(json);
        var projection = (JObject)parsed.DeepClone();
        var serialized = projection.ToString(Formatting.None);
        var reprojection = JObject.Parse(serialized);
        reprojection["unityInventory"] = inventory.DeepClone();
        reprojection["unityWorldAuthority"] = worldAuthority.DeepClone();
        if (ui != null) reprojection["ui"] = ui;
        if (uiCommandResult != null) reprojection["unityUICommandResult"] = uiCommandResult.DeepClone();
        if (reprojection["settings"] is JObject settings && settings["supportedCommands"] is JArray supported &&
            !supported.Contains("stage.camera.reset")) supported.Add("stage.camera.reset");
        if (settingsCommandResult != null) reprojection["settingsCommandResult"] = settingsCommandResult.DeepClone();
        return Encoding.UTF8.GetBytes(reprojection.ToString(Formatting.None));
    }

    /// The shipped path, called exactly the way `GPUIChat2Probe.ApplySnapshot` calls it.
    static byte[] Shipped(string json, JToken inventory, JToken worldAuthority, JToken ui,
        JToken uiCommandResult, JToken settingsCommandResult)
    {
        var projection = GPUIProjectionPayload.Parse(json);
        GPUIProjectionPayload.Augment(projection, inventory.DeepClone(), worldAuthority.DeepClone(), ui,
            uiCommandResult?.DeepClone(), settingsCommandResult?.DeepClone());
        return GPUIProjectionPayload.Encode(projection);
    }

    static JToken AdjunctInventory()
    {
        var inventory = new JArray();
        for (var index = 0; index < 40; index++)
            inventory.Add(new JObject { ["objectID"] = "prop." + index.ToString(CultureInfo.InvariantCulture),
                ["name"] = "物件 " + index.ToString(CultureInfo.InvariantCulture), ["kind"] = "prop", ["owned"] = true,
                ["position"] = new JObject { ["x"] = index * 0.25, ["y"] = 0.0, ["z"] = -index * 0.5 } });
        return inventory;
    }

    static JToken AdjunctWorldAuthority()
    {
        var state = new JObject { ["worldID"] = "space.living" };
        for (var index = 0; index < 32; index++)
            state["prop" + index.ToString(CultureInfo.InvariantCulture)] =
                new JObject { ["objectID"] = "prop." + index.ToString(CultureInfo.InvariantCulture), ["revision"] = index };
        return new JObject { ["state"] = state, ["revision"] = 7 };
    }

    static JToken AdjunctUi() => new JObject { ["lyricsVisible"] = true, ["spaceVisible"] = false,
        ["fullscreen"] = false, ["compact"] = false, ["connected"] = true, ["status"] = "", ["error"] = null };

    static double Median(List<double> values)
    {
        values.Sort();
        return values[values.Count / 2];
    }

    static (double median, double p95, long allocated) Time(Func<byte[]> body, int iterations)
    {
        for (var warm = 0; warm < Math.Max(4, iterations / 10); warm++) body();
        var samples = new List<double>(iterations);
        var before = GC.GetAllocatedBytesForCurrentThread();
        for (var index = 0; index < iterations; index++) {
            var watch = Stopwatch.StartNew();
            body();
            watch.Stop();
            samples.Add(watch.Elapsed.TotalMilliseconds);
        }
        var allocated = GC.GetAllocatedBytesForCurrentThread() - before;
        return (Median(samples), samples[(int)(samples.Count * 0.95)], allocated / iterations);
    }

    static int Main(string[] args)
    {
        if (args.Length < 1) { Console.Error.WriteLine("usage: CostHarness <envelope.json> [iterations]"); return 2; }
        var json = File.ReadAllText(args[0]);
        var iterations = args.Length > 1 ? int.Parse(args[1], CultureInfo.InvariantCulture) : 120;
        var inventory = AdjunctInventory();
        var worldAuthority = AdjunctWorldAuthority();

        // Correctness half: the payload must be byte-identical to the pre-fix payload, including the
        // absence of a UTF-8 BOM. Both the empty-adjunct and the full-adjunct poll are checked.
        var emptyShipped = Shipped(json, inventory, worldAuthority, null, null, null);
        var emptyPreFix = PreFix(json, inventory, worldAuthority, null, null, null);
        var fullShipped = Shipped(json, inventory, worldAuthority, AdjunctUi(), new JObject { ["op"] = "ui.overlay.panel" }, null);
        var fullPreFix = PreFix(json, inventory, worldAuthority, AdjunctUi(), new JObject { ["op"] = "ui.overlay.panel" }, null);
        var equalEmpty = emptyShipped.SequenceEqual(emptyPreFix);
        var equalFull = fullShipped.SequenceEqual(fullPreFix);
        var bom = fullShipped.Length >= 3 && fullShipped[0] == 0xEF && fullShipped[1] == 0xBB && fullShipped[2] == 0xBF;
        Console.WriteLine("payload.bytes=" + fullShipped.Length.ToString(CultureInfo.InvariantCulture));
        Console.WriteLine("equal.empty=" + equalEmpty.ToString().ToLowerInvariant());
        Console.WriteLine("equal.full=" + equalFull.ToString().ToLowerInvariant());
        Console.WriteLine("bom=" + bom.ToString().ToLowerInvariant());
        if (!equalEmpty || !equalFull || bom) return 1;

        var preFix = Time(() => PreFix(json, inventory, worldAuthority, AdjunctUi(), null, null), iterations);
        var shipped = Time(() => Shipped(json, inventory, worldAuthority, AdjunctUi(), null, null), iterations);
        Console.WriteLine("prefix.medianMs=" + preFix.median.ToString("F3", CultureInfo.InvariantCulture));
        Console.WriteLine("prefix.p95Ms=" + preFix.p95.ToString("F3", CultureInfo.InvariantCulture));
        Console.WriteLine("prefix.bytesPerPoll=" + preFix.allocated.ToString(CultureInfo.InvariantCulture));
        Console.WriteLine("shipped.medianMs=" + shipped.median.ToString("F3", CultureInfo.InvariantCulture));
        Console.WriteLine("shipped.p95Ms=" + shipped.p95.ToString("F3", CultureInfo.InvariantCulture));
        Console.WriteLine("shipped.bytesPerPoll=" + shipped.allocated.ToString(CultureInfo.InvariantCulture));
        Console.WriteLine("ratio=" + (shipped.median / preFix.median).ToString("F3", CultureInfo.InvariantCulture));
        return 0;
    }
}
