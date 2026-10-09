using System.IO;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace GMGN.UnityPlayer
{
    /// The single owner of one GPUI poll's payload work: **one** parse of the host envelope, an
    /// in-place adjunct pass, and **one** UTF-8 write with no BOM.
    ///
    /// Before 2026-10-09 17:00 the same poll cost five whole-envelope tree passes: the backend
    /// deep-cloned the parsed envelope, serialized it to a string, and `GPUIChat2Probe` parsed that
    /// string right back; then the payload was serialized a second time into a UTF-16 string and
    /// re-encoded to bytes. `sample` on the real machine (build 228, 158 KB envelope, 20 Hz poll) put
    /// 71 % of the Unity main thread in that path, and the numbers scale with the envelope, which is
    /// why the stage-active case (points=22536, music + lyrics + queue in the envelope) measured
    /// cpuMs≈92 while the idle case measured ≈39.5.
    ///
    /// This type is deliberately free of `UnityEngine` so `tools/test-gpui-projection-cost.py` can
    /// compile this file alone and measure one poll against the pre-fix shape, with byte equality of
    /// the payload as the correctness half of the gate.
    public static class GPUIProjectionPayload
    {
        /// The same bound the C# boundary and `gmgn_gpui_chat_snapshot` already enforce.
        public const int Capacity = 4 * 1024 * 1024;
        static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

        /// The one parse of the host envelope that a poll is allowed. The caller keeps reading the
        /// returned tree for the rest of the tick.
        public static JObject Parse(string envelope) => JObject.Parse(envelope);

        /// Adds the main-thread adjuncts to this tick's own tree. No whole-tree clone: nothing keeps
        /// the projection past `Encode`, and every adjunct is either a fresh clone or a value the
        /// probe replaces rather than mutates.
        public static void Augment(JObject projection, JToken inventory, JToken worldAuthority, JToken ui,
            JToken uiCommandResult, JToken settingsCommandResult)
        {
            projection["unityInventory"] = inventory;
            projection["unityWorldAuthority"] = worldAuthority;
            if (ui != null) projection["ui"] = ui;
            if (uiCommandResult != null) projection["unityUICommandResult"] = uiCommandResult;
            if (projection["settings"] is JObject settings && settings["supportedCommands"] is JArray supported &&
                !supported.Contains("stage.camera.reset")) supported.Add("stage.camera.reset");
            if (settingsCommandResult != null) projection["settingsCommandResult"] = settingsCommandResult;
        }

        /// `JToken.ToString(Formatting.None)` + `Encoding.UTF8.GetBytes` produced these same bytes
        /// through a whole UTF-16 copy of the envelope (large-object heap) plus a second encode pass.
        public static byte[] Encode(JObject projection)
        {
            using var stream = new MemoryStream(256 * 1024);
            using (var text = new StreamWriter(stream, Utf8NoBom, 64 * 1024, true))
            using (var json = new JsonTextWriter(text) { Formatting = Formatting.None }) {
                projection.WriteTo(json);
                json.Flush(); text.Flush();
            }
            return stream.ToArray();
        }
    }
}
