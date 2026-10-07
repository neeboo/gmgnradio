using System;
using System.Collections.Generic;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;
using GMGN.UnityPlayer.Characters;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Editor
{
    public static class CompactHeldPropChecks
    {
        public static void Validate()
        {
            const BindingFlags fields = BindingFlags.Instance | BindingFlags.NonPublic;
            var host = new GameObject("compact-held-fixture");
            var root = new GameObject("held-fixture-world");
            try {
                var world = host.AddComponent<WorldRuntimeBridge>();
                var compact = host.AddComponent<UnityCompactWindowController>();
                var avatar = GameObject.CreatePrimitive(PrimitiveType.Cube); avatar.transform.SetParent(root.transform);
                var resident = avatar.AddComponent<CharacterWorldAdapter>();
                typeof(CharacterWorldAdapter).GetProperty("CharacterId").SetValue(resident, "fixture-avatar");
                typeof(WorldRuntimeBridge).GetField("character", fields).SetValue(world, resident);
                typeof(WorldRuntimeBridge).GetField("worldRoot", fields).SetValue(world, root);
                var held = GameObject.CreatePrimitive(PrimitiveType.Cube); held.transform.SetParent(root.transform);
                var background = GameObject.CreatePrimitive(PrimitiveType.Cube); background.transform.SetParent(root.transform);
                var items = (Dictionary<string,RecoveryItem>)typeof(WorldRuntimeBridge).GetField("recoveredItems", fields).GetValue(world);
                items["sword"] = new RecoveryItem { ObjectID="sword", Status="attached", Instance=held };
                var projection = JObject.Parse("{\"state\":{\"heldProp\":{\"objectID\":\"sword\",\"avatarAssetID\":\"fixture-avatar\"}}}");
                typeof(WorldRuntimeBridge).GetProperty("AuthorityProjection").SetValue(world, projection);
                var apply = typeof(UnityCompactWindowController).GetMethod("ApplyLiveCamProfile", fields);
                var end = typeof(UnityCompactWindowController).GetMethod("EndLiveCam", fields);
                var swordRenderer = held.GetComponent<Renderer>();
                int originalLayer = held.layer;
                apply.Invoke(compact, null);
                if (!swordRenderer.enabled || background.GetComponent<Renderer>().enabled)
                    throw new Exception("Compact must show held world-pose prop while masking background.");
                projection["state"]["heldProp"]["avatarAssetID"] = "another-avatar";
                apply.Invoke(compact, null);
                if (swordRenderer.enabled) throw new Exception("Stale avatar attachment remained visible.");
                projection["state"]["heldProp"]["avatarAssetID"] = "fixture-avatar";
                apply.Invoke(compact, null);
                if (!swordRenderer.enabled) throw new Exception("New held binding did not restore a previously masked renderer.");
                end.Invoke(compact, null);
                if (!swordRenderer.enabled || !background.GetComponent<Renderer>().enabled || held.layer != originalLayer)
                    throw new Exception("Compact exit failed to restore renderer state or changed prop layer.");
                Debug.Log("PASS compact held prop: world-pose held renderer visible, background masked, stale avatar rejected, rebind/exit restored; layers unchanged.");
            } finally { UnityEngine.Object.DestroyImmediate(host); UnityEngine.Object.DestroyImmediate(root); }
        }
    }
}
