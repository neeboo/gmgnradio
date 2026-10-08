using System.IO;
using Newtonsoft.Json.Linq;

namespace GMGN.UnityPlayer.World
{
    // JSON null is a JValue, not a C# null. Decode optional projection objects
    // before indexing; malformed non-null shapes remain explicit errors.
    public static class WorldProjectionOptional
    {
        public static JObject Object(JToken token)
        {
            if (token == null || token.Type == JTokenType.Null) return null;
            return token as JObject ?? throw new InvalidDataException("Optional world projection must be an object or null.");
        }
        public static JObject Held(JToken state) => Object(Object(state)?["heldProp"]);
        public static string HeldID(JToken state) => (string)Held(state)?["objectID"];
    }
}
