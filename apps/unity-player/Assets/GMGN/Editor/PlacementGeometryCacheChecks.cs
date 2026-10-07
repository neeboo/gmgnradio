using System;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Editor
{
    public static class PlacementGeometryCacheChecks
    {
        const BindingFlags Fields = BindingFlags.Instance | BindingFlags.NonPublic;
        static object Geometry(PlacementRequestBuilder builder, string id) =>
            ((IDictionary)typeof(PlacementRequestBuilder).GetField("geometry", Fields).GetValue(builder))[id];
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
        public static void Validate()
        {
            var host = new GameObject("placement-cache-check");
            var root = new GameObject("fixture-root"); root.transform.SetParent(host.transform);
            var cube = GameObject.CreatePrimitive(PrimitiveType.Cube); cube.transform.SetParent(root.transform, false);
            Mesh replacement = null;
            try {
                var items = new List<RecoveryItem> { new RecoveryItem { ObjectID = "fixture", Instance = root } };
                var grid = new JObject(); var triangles = new JArray(); var blocking = new JArray();
                var builder = new PlacementRequestBuilder(grid, triangles, blocking, items);
                var original = Geometry(builder, "fixture");
                for (var i = 0; i < 100; i++) {
                    root.transform.SetPositionAndRotation(new Vector3(i * .123f, 0, i * -.31f), Quaternion.Euler(0, i * 3.7f, 0));
                    builder.UpdateItems(new List<RecoveryItem>(items));
                    Require(ReferenceEquals(original, Geometry(builder, "fixture")), "Unchanged loaded mesh rebuilt after root pose/recovered-list update");
                }
                cube.transform.localPosition = Vector3.right;
                builder.UpdateItems(items);
                var offset = Geometry(builder, "fixture");
                Require(!ReferenceEquals(original, offset), "Child transform did not invalidate local geometry");
                root.transform.localScale = new Vector3(2, 1, 1);
                builder.UpdateItems(items);
                var scaled = Geometry(builder, "fixture");
                Require(!ReferenceEquals(offset, scaled), "Scale did not invalidate bounds");
                replacement = UnityEngine.Object.Instantiate(cube.GetComponent<MeshFilter>().sharedMesh);
                cube.GetComponent<MeshFilter>().sharedMesh = replacement;
                builder.UpdateItems(items);
                Require(!ReferenceEquals(scaled, Geometry(builder, "fixture")), "Replacement mesh did not invalidate geometry");
                builder.UpdateItems(new List<RecoveryItem>());
                Require(Geometry(builder, "fixture") == null, "Removed object retained geometry");
                builder.UpdateItems(items);
                Require(Geometry(builder, "fixture") != null, "Restored object did not rebuild geometry");
                var controller = host.AddComponent<WorldInteractionController>();
                typeof(WorldInteractionController).GetField("items", Fields).SetValue(controller, items);
                controller.ConfigurePlacementGeometry(grid, triangles, blocking);
                var field = typeof(WorldInteractionController).GetField("placementBuilder", Fields);
                var first = field.GetValue(controller);
                controller.ConfigurePlacementGeometry(grid, triangles, blocking);
                Require(ReferenceEquals(first, field.GetValue(controller)), "Same derived grid replaced builder");
                typeof(WorldInteractionController).GetField("buildingEvaluation", Fields).SetValue(controller, true);
                controller.ConfigurePlacementGeometry(grid, triangles, blocking);
                Require(!ReferenceEquals(first, field.GetValue(controller)), "In-flight request geometry was mutated");
                typeof(WorldInteractionController).GetField("buildingEvaluation", Fields).SetValue(controller, false);
                first = field.GetValue(controller);
                controller.ConfigurePlacementGeometry(new JObject(), triangles, blocking);
                Require(!ReferenceEquals(first, field.GetValue(controller)), "New grid retained old session caches");
                Debug.Log("PASS placement geometry cache: 100 pose/list updates reuse mesh arrays; child transform, scale, replacement, removal/restoration invalidate; unchanged grid reuses builder, new grid/in-flight request isolates caches.");
            } finally {
                UnityEngine.Object.DestroyImmediate(host);
                if (replacement != null) UnityEngine.Object.DestroyImmediate(replacement);
            }
        }
    }
}
