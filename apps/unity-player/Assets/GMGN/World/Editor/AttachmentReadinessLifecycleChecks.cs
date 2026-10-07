using System;
using System.Collections.Generic;
using System.Reflection;
using GMGN.UnityPlayer.World;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class AttachmentReadinessLifecycleChecks
    {
        public static void Check()
        {
            var owner = new GameObject("isolated readiness check");
            var root = new GameObject("isolated world");
            try {
                var bridge = owner.AddComponent<WorldRuntimeBridge>();
                var type = typeof(WorldRuntimeBridge);
                var flags = BindingFlags.Instance | BindingFlags.NonPublic;
                var items = (Dictionary<string, RecoveryItem>)type.GetField("recoveredItems", flags).GetValue(bridge);
                var prop = new GameObject("loaded prop"); prop.transform.SetParent(root.transform);
                prop.AddComponent<PreparedPropGrip>();
                items["sword"] = new RecoveryItem { ObjectID = "sword", Instance = prop, AssetMetadata = "{\"assetID\":\"sha256:fixture\"}" };
                JObject Receipt(bool visible) {
                    root.SetActive(visible);
                    type.GetField("visible", flags).SetValue(bridge, visible);
                    return (JObject)type.GetMethod("BuildAttachmentReadinessReceipt", flags).Invoke(bridge, null);
                }
                void Ready(JObject receipt, bool expected, string step) {
                    if (((string)receipt["assets"]?["sword"] == "sha256:fixture") != expected)
                        throw new InvalidOperationException("Attachment readiness lifecycle: " + step);
                }
                Ready(Receipt(true), true, "visible loaded asset");
                var hidden = Receipt(false);
                Ready(hidden, true, "hidden loaded asset remains prepared for return");
                if (((JArray)hidden["slots"]).Count != 0) throw new InvalidOperationException("Hidden slot semantics changed");
                Ready(Receipt(true), true, "visible again without reload");
                UnityEngine.Object.DestroyImmediate(prop.GetComponent<PreparedPropGrip>());
                Ready(Receipt(false), false, "unprepared asset remains blocked");
                prop.AddComponent<PreparedPropGrip>();
                items["sword"].AssetMetadata = null;
                Ready(Receipt(false), false, "missing asset metadata remains blocked");
                items["sword"].AssetMetadata = "not json";
                Ready(Receipt(false), false, "invalid asset metadata remains blocked");
                items["sword"].AssetMetadata = "{\"assetID\":\"sha256:fixture\"}";
                UnityEngine.Object.DestroyImmediate(prop);
                Ready(Receipt(false), false, "unloaded asset remains blocked");
                items.Clear();
                Ready(Receipt(true), false, "cleared world remains blocked");
                Debug.Log("PASS: actual attachment receipt visible-hidden-return-preparation-visible lifecycle and missing/unloaded asset rejection");
            } finally {
                UnityEngine.Object.DestroyImmediate(root);
                UnityEngine.Object.DestroyImmediate(owner);
            }
        }
    }
}
