using System;
using System.IO;
using System.Threading;
using Newtonsoft.Json.Linq;
using GMGN.UnityPlayer.World;
class RecoveryNullChecks
{
    static int Main()
    {
        var recovery = new WorldSceneRecovery(null);
        foreach (var optional in new[] { "null", "{\"objectID\":\"sword\"}", "{}" }) {
            var state = JObject.Parse("{\"objectStates\":{},\"heldProp\":" + optional + "}");
            var result = recovery.RestoreState(state, null, null, CancellationToken.None, true).GetAwaiter().GetResult();
            if (result.Count != 0) return 1;
        }
        bool rejected = false;
        try { recovery.RestoreState(JObject.Parse("{\"objectStates\":{},\"heldProp\":1}"), null, null,
            CancellationToken.None, true).GetAwaiter().GetResult(); }
        catch (InvalidDataException) { rejected = true; }
        if (!rejected) return 2;
        Console.WriteLine("PASS actual RestoreState JSON-null/held metadata entry; malformed shape denied; no scene or loader run");
        return 0;
    }
}
