using System;
using System.Collections.Generic;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UIElements;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Editor
{
    public static class PlacementPreviewLifecycleChecks
    {
        static readonly BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
        static void Set(object owner, string name, object value) => owner.GetType().GetField(name, Private).SetValue(owner, value);
        static T Get<T>(object owner, string name) => (T)owner.GetType().GetField(name, Private).GetValue(owner);
        static void Call(object owner, string name, params object[] args) => owner.GetType().GetMethod(name, Private).Invoke(owner, args);
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
        public static void Validate()
        {
            var host = new GameObject("placement-preview-lifecycle");
            var sofa = GameObject.CreatePrimitive(PrimitiveType.Cube);
            try {
                var controller = host.AddComponent<WorldInteractionController>();
                var item = new RecoveryItem { ObjectID = "sofa", Status = "restored", Instance = sofa };
                var pose = new Vector3(2, .025f, 4);
                sofa.transform.position = pose;
                var transform = new JObject {
                    ["position"] = new JObject { ["x"] = 2, ["y"] = .025f, ["z"] = -4 },
                    ["rotation"] = new JObject { ["x"] = 0, ["y"] = 0, ["z"] = 0, ["w"] = 1 },
                    ["scale"] = new JObject { ["x"] = 1, ["y"] = 1, ["z"] = 1 }
                };
                var originTransform = (JObject)transform.DeepClone();
                originTransform["position"] = new JObject { ["x"] = 0, ["y"] = 0, ["z"] = 0 };
                var state = new JObject { ["objectStates"] = new JObject { ["sofa"] = new JObject { ["isEnabled"] = false, ["transform"] = originTransform } } };
                var record = new JObject { ["recordRevision"] = 3, ["state"] = state };
                Set(controller, "active", true); Set(controller, "editing", true);
                Set(controller, "selected", item); Set(controller, "inventoryPreview", true);
                Set(controller, "authority", record); Set(controller, "evaluatedRevision", (ulong)3);
                Set(controller, "worldID", "test"); Set(controller, "items", new List<RecoveryItem> { item });
                Set(controller, "message", new Label());
                JObject observed = null; int ended = 0;
                controller.PreviewChanged += value => observed = value;
                controller.PreviewEnded += () => ended++;
                Set(controller, "releasePending", true); Set(controller, "evaluationID", "left-release");
                Call(controller, "OnPlacement", new JObject { ["requestID"] = "left-release", ["status"] = "completed",
                    ["result"] = new JObject { ["canPlace"] = false, ["reason"] = new JObject { ["code"] = "noSupport" }, ["columns"] = new JArray(new JObject { ["x"] = -1, ["z"] = -34 }) } });
                Require(sofa.activeSelf && sofa.transform.position == pose && Get<RecoveryItem>(controller, "selected") == item && ended == 0,
                    "Rejected left placement must keep the visible inventory preview at its attempted pose.");
                Require((bool?)observed?["canPlace"] == false && observed["columns"] is JArray columns && columns.Count == 1,
                    "Rejected footprint must remain available for red-grid rendering.");
                Set(controller, "evaluationID", "rotation-in-flight");
                Call(controller, "EndGesture", false, 1);
                Require(!Get<bool>(controller, "releasePending") && sofa.activeSelf && ended == 0,
                    "Right click must not confirm or cancel inventory placement.");
                Call(controller, "EndGesture", true, 1);
                Require(!Get<bool>(controller, "releasePending") && sofa.activeSelf && ended == 0,
                    "Right rotation must remain an editable preview.");
                Set(controller, "releasePending", true);
                Call(controller, "OnPlacement", new JObject { ["requestID"] = "rotation-in-flight", ["status"] = "failed", ["message"] = "service failed" });
                Require(sofa.activeSelf && Get<RecoveryItem>(controller, "selected") == item && !Get<bool>(controller, "releasePending"),
                    "Evaluation service failure must retain retryable preview.");
                Set(controller, "inventoryPreview", false); Set(controller, "evaluationID", "existing-release"); Set(controller, "releasePending", true);
                Call(controller, "OnPlacement", new JObject { ["requestID"] = "existing-release", ["status"] = "completed", ["result"] = new JObject { ["canPlace"] = false } });
                Require(sofa.activeSelf && sofa.transform.position == pose && ended == 0,
                    "Rejected existing-object move must retain the attempted pose for adjustment.");
                Set(controller, "inventoryPreview", true); Set(controller, "awaitingReadback", true);
                Set(controller, "savedRevision", (ulong)4); Set(controller, "savedObjectID", "sofa");
                Set(controller, "selected", null);
                Call(controller, "OnWorld", new JObject { ["worldID"] = "test", ["result"] = new JObject { ["record"] = record } });
                Require(sofa.activeSelf && sofa.transform.position == pose && Get<bool>(controller, "awaitingReadback"),
                    "Stale disabled inventory snapshot must not hide the placement after its save receipt.");
                state["objectStates"]["sofa"]["isEnabled"] = true;
                state["objectStates"]["sofa"]["transform"] = transform;
                Set(controller, "submitted", state.DeepClone());
                record["recordRevision"] = 4;
                Call(controller, "OnWorld", new JObject { ["worldID"] = "test", ["result"] = new JObject { ["record"] = record } });
                Require(sofa.activeSelf && sofa.transform.position == pose && Get<RecoveryItem>(controller, "selected") == null && !Get<bool>(controller, "inventoryPreview") && ended == 1,
                    "Matching authoritative enabled-object readback must finish placement without hiding the sofa.");
                state["objectStates"]["sofa"]["isEnabled"] = false;
                record["recordRevision"] = 5;
                Call(controller, "OnWorld", new JObject { ["worldID"] = "test", ["result"] = new JObject { ["record"] = record } });
                sofa.SetActive(true); sofa.transform.position = pose;
                Set(controller, "selected", item); Set(controller, "inventoryPreview", true);
                controller.UpdateRecoveredItems(new List<RecoveryItem> { item });
                Require(sofa.activeSelf && sofa.transform.position == pose && Get<RecoveryItem>(controller, "selected") == item && ended == 1,
                    "Inventory-list refresh must preserve a live preview and its local-grid lifecycle.");
                state["heldProp"] = new JObject { ["objectID"] = "sofa" };
                record["recordRevision"] = 6;
                Call(controller, "OnWorld", new JObject { ["worldID"] = "test", ["result"] = new JObject { ["record"] = record } });
                Require(!sofa.activeSelf && Get<RecoveryItem>(controller, "selected") == null && !Get<bool>(controller, "inventoryPreview"),
                    "Authoritative hand ownership must end the preview and allow inventory refresh.");
                state.Remove("heldProp"); state["objectStates"]["sofa"]["isEnabled"] = true;
                record["recordRevision"] = 7;
                Call(controller, "OnWorld", new JObject { ["worldID"] = "test", ["result"] = new JObject { ["record"] = record } });
                sofa.SetActive(true); Set(controller, "selected", item); Set(controller, "inventoryPreview", true);
                Call(controller, "Cancel");
                Require(sofa.activeSelf && !Get<bool>(controller, "inventoryPreview"), "Cancelling a placed-object move must preserve its authoritative visibility.");
                Set(controller, "inventoryPreview", true); Set(controller, "selected", null);
                Call(controller, "Cancel");
                Require(!Get<bool>(controller, "inventoryPreview") && !controller.OwnsPointer,
                    "Null-selection cancellation must release preview ownership.");
                Debug.Log("PASS placement preview lifecycle: rejected left release retains sofa/red footprint, right click/rotation retains preview, service failure retryable, existing move retained, accepted authority readback visible.");
            } finally { UnityEngine.Object.DestroyImmediate(sofa); UnityEngine.Object.DestroyImmediate(host); }
        }
    }
}
