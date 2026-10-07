using System;
using System.Collections.Generic;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Editor
{
    public static class PlacementQueryValidation
    {
        public static void Validate()
        {
            var spanning = JArray.Parse("[[-10,0,-10],[10,0,-10],[0,0,10]]");
            var touching = JArray.Parse("[[1.005,0,0],[1.005,1,0],[1.005,0,1]]");
            var distant = JArray.Parse("[[10,0,0],[10,1,0],[10,0,1]]");
            var source = new JArray(spanning, touching, distant);
            var selected = PlacementRequestBuilder.QueryEnvironmentTriangles(source, Vector3.zero, Vector3.one);
            if (selected.Count != 2 || !JToken.DeepEquals(selected[0], spanning) || !JToken.DeepEquals(selected[1], touching)
                || source.Count != 3) throw new Exception("Local placement geometry lost spanning/contact faces or changed source geometry.");
            var empty = PlacementRequestBuilder.QueryEnvironmentTriangles(source, new Vector3(20,20,20), new Vector3(21,21,21));
            if (empty.Count != 0) throw new Exception("Distant environment geometry leaked into local placement query.");
            var retina = WorldInteractionController.PanelPointToScreen(new Vector2(700,350), Vector2.zero,
                new Vector2(1024,496), new Vector2(2048,992));
            if (Vector2.Distance(retina,new Vector2(1400,292)) > .001f) throw new Exception("Retina pointer mapping differs from framebuffer coordinates.");
            ValidateExistingDeviceRelocation();
            ValidateInventoryPreview();
            ValidateDragAfterPendingRotation();
            var floor = JArray.Parse("[[[-2,0,1],[2,0,1],[0,0,5]]]");
            if (!PlacementRequestBuilder.TryPickEnvironment(floor, new Ray(new Vector3(0,3,-2),Vector3.down),out var hit)
                || Vector3.Distance(hit,new Vector3(0,0,-2)) > .001f)
                throw new Exception("Environment picking lost gameplay-to-Unity Z conversion or floor intersection.");
            if (PlacementRequestBuilder.TryPickEnvironment(floor,new Ray(new Vector3(5,3,-2),Vector3.down),out _))
                throw new Exception("Environment picking accepted a point outside its triangle.");
            Debug.Log("PASS local placement query: spanning faces, margin contact, exact winding, source preserved, distant faces excluded; no live placement claim.");
        }
        static void ValidateDragAfterPendingRotation()
        {
            var owner = new GameObject("placement-pending-rotation-fixture");
            var instance = GameObject.CreatePrimitive(PrimitiveType.Cube);
            var cameraObject = new GameObject("placement-drag-camera");
            var settings = ScriptableObject.CreateInstance<UnityEngine.UIElements.PanelSettings>();
            try {
                var camera = cameraObject.AddComponent<Camera>(); cameraObject.tag = "MainCamera";
                camera.transform.position = new Vector3(0, 3, -6);
                camera.transform.LookAt(Vector3.zero);
                var document = owner.AddComponent<UnityEngine.UIElements.UIDocument>();
                document.panelSettings = settings;
                var root = document.rootVisualElement;
                if (root.panel == null) throw new Exception("Placement fixture runtime panel must be attached.");
                var controller = owner.AddComponent<WorldInteractionController>();
                var item = new RecoveryItem { ObjectID = "rotation-then-drag-sofa", Status = "restored", Instance = instance };
                const BindingFlags flags = BindingFlags.NonPublic | BindingFlags.Instance;
                var type = typeof(WorldInteractionController);
                void Set(string name, object value) => type.GetField(name, flags).SetValue(controller, value);
                Set("selected", item); Set("inventoryPreview", true); Set("inputRoot", root);
                Set("placementTriangles", JArray.Parse("[[[-10,0,-10],[10,0,-10],[0,0,10]]]"));
                controller.SetActive(true); controller.SetEditing(true);
                Set("releasePending", true); Set("evaluationID", "released-rotation-evaluation");
                instance.transform.rotation = Quaternion.Euler(0, 45, 0);
                Vector2 PanelPoint(Vector3 world) {
                    var point = camera.WorldToScreenPoint(world);
                    return UnityEngine.UIElements.RuntimePanelUtils.ScreenToPanel(root.panel,
                        new Vector2(point.x, Screen.height - point.y));
                }
                var start = PanelPoint(Vector3.zero); var end = PanelPoint(Vector3.right);
                using (var down = UnityEngine.UIElements.PointerDownEvent.GetPooled(new Event {
                    type = EventType.MouseDown, button = 0, mousePosition = start })) {
                    if (!(bool)type.GetMethod("BeginGesture", flags).Invoke(controller, new object[] { down }))
                        throw new Exception("Pending rotation evaluation blocked the next left drag.");
                }
                if ((bool)type.GetField("releasePending", flags).GetValue(controller)
                    || type.GetField("evaluationID", flags).GetValue(controller) != null)
                    throw new Exception("New drag did not supersede the released rotation evaluation.");
                type.GetMethod("MoveGesture", flags).Invoke(controller, new object[] { start, end, 0 });
                if (Vector3.Distance(instance.transform.position, Vector3.right) > .01f
                    || Quaternion.Angle(instance.transform.rotation, Quaternion.Euler(0, 45, 0)) > .001f)
                    throw new Exception("Actual left drag must move along the floor while preserving the prior rotation.");
                type.GetMethod("OnPlacement", flags).Invoke(controller, new object[] { JObject.Parse(
                    "{\"requestID\":\"released-rotation-evaluation\",\"status\":\"completed\",\"result\":{\"canPlace\":false}}") });
                if (!instance.activeSelf || Vector3.Distance(instance.transform.position, Vector3.right) > .01f)
                    throw new Exception("Stale rotation rejection cancelled the new drag.");
                Set("saving", true);
                using (var down = UnityEngine.UIElements.PointerDownEvent.GetPooled(new Event {
                    type = EventType.MouseDown, button = 0, mousePosition = end })) {
                    if ((bool)type.GetMethod("BeginGesture", flags).Invoke(controller, new object[] { down }))
                        throw new Exception("An authoritative save must still block new gestures.");
                }
                Debug.Log("PASS actual inventory drag after rotation: attached runtime panel/rays, pending evaluation superseded, floor translation, yaw preserved, stale rejection ignored, save remains protected.");
            } finally {
                UnityEngine.Object.DestroyImmediate(owner); UnityEngine.Object.DestroyImmediate(instance);
                UnityEngine.Object.DestroyImmediate(cameraObject); UnityEngine.Object.DestroyImmediate(settings);
            }
        }
        static void ValidateInventoryPreview()
        {
            var owner = new GameObject("inventory-placement-fixture");
            var instance = GameObject.CreatePrimitive(PrimitiveType.Cube);
            instance.transform.localScale = new Vector3(2, 1.0159059f, 1.1296002f);
            instance.SetActive(false);
            try {
                var controller = owner.AddComponent<WorldInteractionController>();
                var item = new RecoveryItem { ObjectID = "owned-sofa", Status = "inventory", Instance = instance };
                var items = new List<RecoveryItem> { item };
                var binding = BindingFlags.NonPublic | BindingFlags.Instance;
                void Set(string name, object value) => typeof(WorldInteractionController).GetField(name, binding).SetValue(controller, value);
                Set("authority", JObject.Parse("{\"recordRevision\":1,\"state\":{\"objectStates\":{}}}"));
                Set("placementGrid", JObject.Parse("{\"spacing\":0.25,\"layers\":[]}"));
                var floor = JArray.Parse("[[[-10,0,-10],[10,0,-10],[0,0,10]]]");
                Set("placementTriangles", floor); Set("mutableItems", items); Set("items", items);
                controller.SetActive(true); controller.SetEditing(true);
                if (!controller.BeginInventoryPlacement(item.ObjectID, new Vector3(0, .94f, 0)) || instance.transform.position.y != 0)
                    throw new Exception("Inventory preview must project camera-height seed to the real floor.");
                if (instance.transform.localScale != new Vector3(2, 1.0159059f, 1.1296002f))
                    throw new Exception("Preview changed the authoritative two-metre sofa size.");
                var project = typeof(WorldInteractionController).GetMethod("ProjectPreviewToSurface", binding);
                if (!(bool)project.Invoke(controller, new object[] { new Ray(new Vector3(1, 3, 0), Vector3.down) })
                    || Vector3.Distance(instance.transform.position, new Vector3(1, 0, 0)) > .001f)
                    throw new Exception("Inventory pointer must move to actual support geometry.");
                var position = instance.transform.position;
                if ((bool)project.Invoke(controller, new object[] { new Ray(new Vector3(30, 3, 0), Vector3.down) })
                    || instance.transform.position != position)
                    throw new Exception("A missed floor ray must not extrapolate outside the room.");
                var wall = JArray.Parse("[[[0,0,-2],[0,3,-2],[0,0,2]]]");
                if (PlacementRequestBuilder.TryPickEnvironment(wall, new Ray(new Vector3(-1, 1, 0), Vector3.right), out _, true))
                    throw new Exception("Inventory preview must not treat a vertical wall as support.");
                var evaluations = 0;
                controller.BuildPlacementRequestAsync = null;
                controller.BuildPlacementRequest = (_, _, _, _) => { evaluations++; return null; };
                using (var pointer = UnityEngine.UIElements.PointerDownEvent.GetPooled(new Event {
                    type = EventType.MouseDown, button = 1, mousePosition = new Vector2(99999, 99999) })) {
                    typeof(WorldInteractionController).GetMethod("OnPointerDownForGesture", binding).Invoke(controller, new object[] { pointer });
                }
                if (!controller.OwnsPointer || !instance.activeSelf)
                    throw new Exception("Right-click outside preview mesh must retain inventory selection and block camera movement.");
                Set("gestureRotation", Quaternion.identity);
                typeof(WorldInteractionController).GetMethod("MoveGesture", binding).Invoke(controller,
                    new object[] { Vector2.zero, new Vector2(180, 0), 1 });
                if (Quaternion.Angle(instance.transform.rotation, Quaternion.Euler(0, 90, 0)) > .001f
                    || !controller.OwnsPointer || instance.transform.position != position)
                    throw new Exception("Inventory right drag must rotate the selected model without moving it or releasing pointer ownership.");
                evaluations = 0; Set("nextEvaluation", float.NegativeInfinity);
                typeof(WorldInteractionController).GetMethod("EndGesture", binding).Invoke(controller, new object[] { false });
                if (evaluations != 1) throw new Exception("Inventory click without dragging must enter placement validation.");
                Debug.Log("PASS inventory preview: floor projection, pointer floor movement, missed-ray retention, wall rejection, two-metre size retained, right drag retains selection/rotates/owns camera gesture, click validates; no backend writes.");
            } finally { UnityEngine.Object.DestroyImmediate(owner); UnityEngine.Object.DestroyImmediate(instance); }
        }
        static void ValidateExistingDeviceRelocation()
        {
            var owner = new GameObject("placement-controller-fixture");
            var instance = GameObject.CreatePrimitive(PrimitiveType.Cube);
            var original = new Vector3(2,0,3); instance.transform.position = original;
            try {
                var controller = owner.AddComponent<WorldInteractionController>();
                var item = new RecoveryItem { ObjectID="prop.jukebox", Status="restored", Instance=instance };
                var items = new List<RecoveryItem> { item };
                void Set(string name, object value) => typeof(WorldInteractionController).GetField(name,BindingFlags.NonPublic|BindingFlags.Instance).SetValue(controller,value);
                Set("authority", JObject.Parse("{\"recordRevision\":1,\"state\":{\"objectStates\":{\"prop.jukebox\":{\"isEnabled\":true,\"metadata\":{\"gmgn.builtin-device.v1\":\"{}\"}}}}}"));
                Set("placementGrid",JObject.Parse("{\"spacing\":0.25,\"layers\":[]}"));
                Set("placementTriangles",new JArray()); Set("mutableItems",items); Set("items",items);
                var writes=0; controller.PlaceDevice=_=> { writes++; return true; };
                controller.SetActive(true);
                if(controller.BeginDevicePlacement(new JObject { ["id"]="prop.jukebox" },new Vector3(4,0,5)))
                    throw new Exception("Normal mode allowed catalog relocation.");
                controller.SetEditing(true);
                if(!controller.BeginDevicePlacement(new JObject { ["id"]="prop.jukebox" },new Vector3(4,0,5)))
                    throw new Exception("Existing placed device cannot enter relocation preview from catalog.");
                if(!controller.OwnsPointer || items.Count!=1 || !instance.activeSelf || writes!=0)
                    throw new Exception("Relocation preview duplicated, disabled or wrote the existing device.");
                controller.SetEditing(false);
                if(instance.transform.position!=original || controller.OwnsPointer || writes!=0 || items.Count!=1)
                    throw new Exception("Cancel did not preserve original placed device pose and identity.");
                if(controller.IsEditing || controller.BeginDevicePlacement(new JObject { ["id"]="prop.jukebox" },Vector3.zero))
                    throw new Exception("Exiting edit mode left catalog relocation enabled.");
                Set("selected",item); Set("gesturePosition",original); Set("gestureRotation",Quaternion.identity);
                var rotation = instance.transform.rotation;
                typeof(WorldInteractionController).GetMethod("MoveGesture",BindingFlags.NonPublic|BindingFlags.Instance)
                    .Invoke(controller,new object[] { Vector2.zero,new Vector2(100,0),1 });
                if(instance.transform.rotation!=rotation || instance.transform.position!=original)
                    throw new Exception("Normal mode allowed direct rotation gesture.");
                Set("selected",null); item.Status="inventory"; instance.SetActive(false);
                if(controller.BeginInventoryPlacement(item.ObjectID,Vector3.one) || instance.activeSelf)
                    throw new Exception("Normal mode allowed inventory placement.");
            } finally { UnityEngine.Object.DestroyImmediate(owner); UnityEngine.Object.DestroyImmediate(instance); }
        }
    }
}
