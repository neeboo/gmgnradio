using System.Collections.Generic;
using System;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer
{
    public sealed class PlacementPreparationException : Exception
    {
        public string Code { get; }
        public PlacementPreparationException(string code, string message) : base(message) { Code = code; }
    }
    /// Mesh arrays are read once, on the main thread. All large JSON assembly
    /// and world-triangle projection run off the UI thread.
    public sealed class PlacementRequestBuilder
    {
        sealed class Geometry {
            public Transform Root;
            public Vector3[] LocalVertices;
            public int[] Indices;
            public Bounds Bounds;
            public Vector3 BottomOffset;
        }
        readonly JObject grid;
        readonly JArray triangles, blocking;
        readonly IReadOnlyList<RecoveryItem> items;
        readonly Dictionary<string, Geometry> geometry = new();
        readonly Dictionary<string, JObject> obstacleCache = new();
        readonly Dictionary<string, Matrix4x4> obstacleMatrices = new();
        string gridJSON, triangleJSON, blockingJSON;
        readonly Dictionary<string, string> unavailable = new();
        public PlacementRequestBuilder(JObject grid, JArray triangles, JArray blocking, IReadOnlyList<RecoveryItem> items)
        {
            this.grid = grid; this.triangles = triangles; this.blocking = blocking; this.items = items;
            foreach (var item in items) {
                if (item.Instance == null) continue;
                var root = item.Instance.transform;
                var vertices = new List<Vector3>(); var indices = new List<int>(); var valid = true;
                foreach (var filter in root.GetComponentsInChildren<MeshFilter>()) {
                    var mesh = filter.sharedMesh;
                    if (mesh == null || !mesh.isReadable) { valid = false; unavailable[item.ObjectID] = "nonreadableMesh"; break; }
                    var matrix = root.worldToLocalMatrix * filter.transform.localToWorldMatrix;
                    var offset = vertices.Count;
                    foreach (var point in mesh.vertices) vertices.Add(matrix.MultiplyPoint3x4(point));
                    foreach (var index in mesh.triangles) indices.Add(offset + index);
                }
                if (!valid || vertices.Count == 0 || indices.Count == 0) {
                    if (!unavailable.ContainsKey(item.ObjectID)) unavailable[item.ObjectID] = "noMeshFilters";
                    Debug.LogWarning($"Placement geometry unavailable: objectID={item.ObjectID}; code={unavailable[item.ObjectID]}; filters={root.GetComponentsInChildren<MeshFilter>().Length}; skinned={root.GetComponentsInChildren<SkinnedMeshRenderer>().Length}");
                    continue;
                }
                var bounds = new Bounds(Vector3.Scale(vertices[0], root.lossyScale), Vector3.zero);
                foreach (var p in vertices) bounds.Encapsulate(Vector3.Scale(p, root.lossyScale));
                geometry[item.ObjectID] = new Geometry { Root = root, LocalVertices = vertices.ToArray(),
                    Indices = indices.ToArray(), Bounds = bounds,
                    BottomOffset = new Vector3(bounds.center.x, bounds.min.y, bounds.center.z) };
                Debug.Log($"Placement geometry cached: objectID={item.ObjectID}; vertices={vertices.Count}; triangles={indices.Count/3}; bounds={bounds}; bottomOffset={geometry[item.ObjectID].BottomOffset}");
            }
        }
        public Task<JObject> BuildAsync(string id, Vector3 position, Quaternion rotation, JObject authority)
        {
            if (!geometry.TryGetValue(id, out var selected)) throw new PlacementPreparationException(unavailable.TryGetValue(id, out var code) ? code : "missingSelectedMesh", "这个物件的碰撞几何未载入，暂时不能移动。");
            var matrices = new Dictionary<string, Matrix4x4>();
            foreach (var item in items) {
                if (item.ObjectID == id || item.Instance == null || !item.Instance.activeInHierarchy) continue;
                if (!geometry.TryGetValue(item.ObjectID, out var mesh)) throw new PlacementPreparationException("missingObstacleMesh:" + item.ObjectID, "另一个物件缺少碰撞几何，这次调整已取消。");
                matrices[item.ObjectID] = mesh.Root.localToWorldMatrix;
            }
            if (authority?["state"]?["objectStates"] is JObject states)
                foreach (var state in states.Properties()) {
                    if (state.Name != id && (bool?)state.Value["isEnabled"] == true && !matrices.ContainsKey(state.Name))
                        throw new PlacementPreparationException("unmodelledProp:" + state.Name, "有空间物件尚未载入，这次调整已取消。");
                }
            // Only immutable JSON and copied value-type transforms cross threads.
            return Task.Run(() => BuildCore(id, position, rotation, selected, matrices));
        }
        JObject BuildCore(string id, Vector3 position, Quaternion rotation, Geometry selected, Dictionary<string, Matrix4x4> matrices)
        {
            if (grid?["layers"] is not JArray layers || triangles == null || triangles.Count == 0) throw new PlacementPreparationException("missingGridGeometry", "空间碰撞几何未载入，暂时不能摆放。");
            var bounds = selected.Bounds;
            if (bounds.size.x <= 0 || bounds.size.y <= 0 || bounds.size.z <= 0) throw new PlacementPreparationException("invalidBounds", "物件尺寸无效，调整已取消。");
            var spacing = (float?)grid["spacing"] ?? 0;
            if (spacing <= 0) throw new PlacementPreparationException("invalidSpacing", "空间网格无效，调整已取消。");
            if (Vector3.Dot(rotation * Vector3.up, Vector3.up) < .9999f) throw new PlacementPreparationException("tiltedObject", "这个物件是倾斜姿态，当前摆放仅支持平放旋转。");
            var yaw = -Mathf.Round(rotation.eulerAngles.y / 45f) * 45f * Mathf.Deg2Rad;
            var snappedRotation = Quaternion.Euler(0, -yaw * Mathf.Rad2Deg, 0);
            var bottomCenter = position + snappedRotation * selected.BottomOffset;
            var half = new Vector2(bounds.size.x, bounds.size.z) * .5f;
            var corner = new Vector2(bottomCenter.x, -bottomCenter.z) - new Vector2(
                Mathf.Cos(yaw) * half.x + Mathf.Sin(yaw) * half.y,
                -Mathf.Sin(yaw) * half.x + Mathf.Cos(yaw) * half.y);
            var x = Mathf.RoundToInt(corner.x / spacing); var z = Mathf.RoundToInt(corner.y / spacing);
            JObject anchor = null; var distance = float.PositiveInfinity;
            foreach (var layer in layers) {
                if ((int?)layer["column"]?["x"] != x || (int?)layer["column"]?["z"] != z) continue;
                var d = Mathf.Abs((float)layer["supportHeight"] - bottomCenter.y);
                if (d < distance) { distance = d; anchor = layer as JObject; }
            }
            if (anchor == null) {
                Debug.Log($"Placement rejected: code=noAnchor; objectID={id}; column=({x},{z}); root={position}; bottomCenter={bottomCenter}; size={bounds.size}; yaw={yaw}; layerCount={layers.Count}");
                throw new PlacementPreparationException("noAnchor", "这里没有可放置的支撑面，调整已取消。");
            }
            // Static geometry is serialized once per derived-grid session. JRaw
            // preserves the actual arrays on the wire without copying 161k
            // triangle tokens on every gesture sample.
            gridJSON ??= grid.ToString(Newtonsoft.Json.Formatting.None);
            triangleJSON ??= triangles.ToString(Newtonsoft.Json.Formatting.None);
            blockingJSON ??= (blocking ?? new JArray()).ToString(Newtonsoft.Json.Formatting.None);
            var placed = new JArray();
            foreach (var entry in matrices) {
                if (!obstacleMatrices.TryGetValue(entry.Key, out var old) || old != entry.Value) {
                    var mesh = geometry[entry.Key]; var faces = new JArray();
                    for (var i = 0; i + 2 < mesh.Indices.Length; i += 3) {
                        var face = new JArray();
                        foreach (var index in new[] { mesh.Indices[i], mesh.Indices[i+2], mesh.Indices[i+1] }) {
                            var p = entry.Value.MultiplyPoint3x4(mesh.LocalVertices[index]);
                            face.Add(new JArray(p.x, p.y, -p.z));
                        }
                        faces.Add(face);
                    }
                    obstacleCache[entry.Key] = new JObject { ["shape"] = "mesh", ["id"] = entry.Key, ["triangles"] = faces };
                    obstacleMatrices[entry.Key] = entry.Value;
                }
                placed.Add(obstacleCache[entry.Key].DeepClone());
            }
            return new JObject { ["grid"] = new JRaw(gridJSON), ["anchor"] = anchor.DeepClone(),
                ["footprint"] = new JObject { ["size"] = new JArray(bounds.size.x, bounds.size.z), ["yaw"] = yaw },
                ["height"] = bounds.size.y, ["triangles"] = new JRaw(triangleJSON),
                ["blockingVolumes"] = new JRaw(blockingJSON), ["placedObstacles"] = placed };
        }
        public void Apply(JObject result, Transform root)
        {
            if (result?["volume"] is not JObject volume || volume["center"] is not JArray center || volume["halfExtents"] is not JArray half) return;
            Geometry selected = null;
            foreach (var entry in geometry) if (entry.Value.Root == root) { selected = entry.Value; break; }
            if (selected == null) return;
            var rotation = Quaternion.Euler(0, -(float)volume["yaw"] * Mathf.Rad2Deg, 0);
            var bottomCenter = new Vector3((float)center[0], (float)center[1] - (float)half[1], -(float)center[2]);
            root.SetPositionAndRotation(bottomCenter - rotation * selected.BottomOffset, rotation);
        }
    }
}
