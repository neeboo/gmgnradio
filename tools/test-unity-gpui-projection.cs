using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.Serialization;
using Newtonsoft.Json.Linq;
using GMGN.UnityPlayer;
class GPUIProjectionChecks
{
    static void Require(bool value, string code) { if (!value) throw new Exception(code); }
    static int Main()
    {
        // No constructor/native host is run. Test the real production projection
        // method with only its actual per-UI transport bookkeeping populated.
        var backend = (NativePlayerBackend)FormatterServices.GetUninitializedObject(typeof(NativePlayerBackend));
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var map = new Dictionary<ulong, ulong> { [41] = 1 };
        var failures = new List<JObject>();
        typeof(NativePlayerBackend).GetField("gpuiRequests", flags).SetValue(backend, map);
        typeof(NativePlayerBackend).GetField("gpuiFailures", flags).SetValue(backend, failures);
        string projected = null;
        backend.GPUIHostSnapshot += json => projected = json;
        var publish = typeof(NativePlayerBackend).GetMethod("PublishGPUIProjection", flags);
        var raw = JObject.Parse("{\"chat\":{\"events\":[{\"kind\":\"delta\",\"requestID\":41,\"text\":\"中文\"},{\"kind\":\"reply\",\"requestID\":99}],\"state\":{\"isThinking\":true}},\"music\":{\"title\":\"same owner\"}}");
        publish.Invoke(backend, new object[] { raw });
        var output = JObject.Parse(projected);
        Require(output["chat"]["events"].Count() == 1 && (ulong)output["chat"]["events"][0]["requestID"] == 1, "only_mapped_ids_forwarded");
        Require((ulong)raw["chat"]["events"][0]["requestID"] == 41 && raw["chat"]["events"].Count() == 2, "original_single_poll_projection_unchanged");
        Require((string)output["music"]["title"] == "same owner" && map.Count == 1, "nonterminal_and_other_owner_retained");
        failures.Add(new JObject { ["kind"] = "failure", ["requestID"] = 2, ["code"] = "command_not_accepted" });
        raw["chat"]["events"] = new JArray(new JObject { ["kind"] = "reply", ["requestID"] = 41 });
        publish.Invoke(backend, new object[] { raw });
        Require(map.Count == 0 && failures.Count == 0 && JObject.Parse(projected)["chat"]["events"].Count() == 2, "terminal_and_real_dispatch_failure_consumed");
        map[42] = 1; failures.Add(new JObject()); backend.BeginGPUIEpoch();
        Require(map.Count == 0 && failures.Count == 0, "remount_drops_old_epoch_no_command_replay");
        Console.WriteLine("PASS production GPUI request mapping/projection/terminal/failure/epoch; no native host or UI started");
        return 0;
    }
}
