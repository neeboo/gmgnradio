using System;
using System.IO;
using Newtonsoft.Json.Linq;
using GMGN.UnityPlayer;
using GMGN.UnityPlayer.World;
class OptionalProjectionChecks
{
    static void Require(bool value, string code) { if (!value) throw new Exception(code); }
    static int Main()
    {
        var empty = JObject.Parse("{\"heldProp\":null,\"objectStates\":{}}");
        bool reproduced = false;
        try { var old = (string)empty["heldProp"]?["objectID"]; }
        catch (InvalidOperationException) { reproduced = true; }
        Require(reproduced, "original_json_null_failure_reproduced");
        Require(WorldProjectionOptional.Held(empty) == null && WorldProjectionOptional.HeldID(empty) == null, "explicit_null_decoded");
        Require(WorldProjectionOptional.HeldID(new JObject()) == null, "missing_optional_decoded");
        Require(WorldProjectionOptional.HeldID(null) == null, "missing_state_decoded");
        Require(WorldProjectionOptional.HeldID(JObject.Parse("{\"heldProp\":{\"objectID\":\"sword\",\"hand\":\"rightHand\"}}")) == "sword", "actual_held_identity_preserved");
        foreach (var bad in new[] { "1", "\"bad\"", "[]" }) {
            bool rejected = false;
            try { WorldProjectionOptional.HeldID(JObject.Parse("{\"heldProp\":" + bad + "}")); }
            catch (InvalidDataException) { rejected = true; }
            Require(rejected, "invalid_shape_rejected");
        }
        var gate = new CameraKeyboardGate();
        Require(gate.Read(1) == 1, "raw_key_initially_allowed");
        gate.Suspend();
        Require(gate.Read(1) == 0 && gate.Read(8) == 0, "focus_blocks_held_keys");
        Require(gate.Read(0) == 0 && gate.Read(1) == 1, "release_then_new_key_restored");
        Console.WriteLine("PASS real JSON-null reproduction/optional decoder + release-safe camera keyboard gate");
        return 0;
    }
}
