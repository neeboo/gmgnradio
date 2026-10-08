using System;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UIElements;
using GMGN.UnityPlayer.World;
using UnityEditor;

namespace GMGN.UnityPlayer.Editor
{
    public static class InventoryCatalogChecks
    {
        // Pure UI/projection check: no task daemon, model import, audio or world writes.
        public static void Run()
        {
            GameObject root = null;
            try {
                root = new GameObject("Inventory catalog check");
                var bridge = root.AddComponent<WorldRuntimeBridge>();
                var objects = new JObject();
                for (int i = 0; i < 6; i++) objects["prop-" + i] = new JObject {
                    ["isEnabled"] = i != 5,
                    ["metadata"] = new JObject { ["gmgn.generated-prop.v1"] = new JObject { ["displayName"] = "Owned " + i }.ToString() }
                };
                objects["builtin"] = new JObject { ["isEnabled"] = true };
                var state = new JObject { ["objectStates"] = objects,
                    ["heldProp"] = new JObject { ["objectID"] = "prop-4" },
                    ["propTombstones"] = new JObject { ["prop-3"] = new JObject { ["deleted"] = true } } };
                typeof(WorldRuntimeBridge).GetProperty("AuthorityProjection").SetValue(bridge, new JObject { ["state"] = state });
                JArray inventory = null;
                bridge.InventoryUpdated += value => inventory = value;
                typeof(WorldRuntimeBridge).GetMethod("PublishInventory", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(bridge, new object[] { objects });
                Require(inventory.Count == 5, "placed and stored generated objects retained; tombstone and builtin omitted");
                Require((bool)inventory.Single(item => (string)item["objectID"] == "prop-4")["held"], "held object retained and labelled");
                Require(!(bool)inventory.Single(item => (string)item["objectID"] == "prop-5")["placed"], "stored object labelled");
                Require(inventory.All(item => !string.IsNullOrEmpty((string)item["objectID"])), "GPUI inventory projection preserves all authoritative IDs");
                Debug.Log("InventoryCatalogChecks PASS actual inventory/held/stored/tombstone projection");
                UnityEditor.EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error); UnityEditor.EditorApplication.Exit(1);
            } finally { if (root != null) UnityEngine.Object.DestroyImmediate(root); }
        }
        static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    }
}
