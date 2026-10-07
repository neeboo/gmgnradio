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
            public MeshFilter[] Filters;
            public Mesh[] Meshes;
            public Matrix4x4[] LocalMatrices;
            public Vector3 Scale;
        }
        readonly JObject grid;
        readonly JArray triangles, blocking;
        IReadOnlyList<RecoveryItem> items;
        readonly Dictionary<string, Geometry> geometry = new();
        readonly Dictionary<string, JObject> obstacleCache = new();
        readonly Dictionary<string, string> obstacleJSON = new();
        readonly Dictionary<string, Matrix4x4> obstacleMatrices = new();
        string gridJSON, blockingJSON;
        readonly Dictionary<string, string> unavailable = new();
        public PlacementRequestBuilder(JObject grid, JArray triangles, JArray blocking, IReadOnlyList<RecoveryItem> items)
        {
            this.grid = grid; this.triangles = triangles; this.blocking = blocking;
            UpdateItems(items);
        }
        // Geometry belongs to the loaded mesh, not the latest world-state revision.
        // Keep root pose out of this key: world transforms are captured by BuildAsync.
        static Matrix4x4 RelativeMatrix(Transform child, Transform root)
        {
            var matrix = Matrix4x4.identity;
            for (var current = child; current != root; current = current.parent)
                matrix = Matrix4x4.TRS(current.localPosition, current.localRotation, current.localScale) * matrix;
            return matrix;
        }
        public void UpdateItems(IReadOnlyList<RecoveryItem> updated)
        {
            items = updated;
            var retained = new HashSet<string>();
            foreach (var item in items) {
                if (item.Instance == null) continue;
                retained.Add(item.ObjectID);
                var root = item.Instance.transform;
                var filters = root.GetComponentsInChildren<MeshFilter>();
                var meshes = new Mesh[filters.Length];
                var matrices = new Matrix4x4[filters.Length];
                for (var i = 0; i < filters.Length; i++) {
                    meshes[i] = filters[i].sharedMesh;
                    matrices[i] = RelativeMatrix(filters[i].transform, root);
                }
                if (geometry.TryGetValue(item.ObjectID, out var previous) && previous.Root == root &&
                    previous.Scale == root.lossyScale && previous.Filters.Length == filters.Length) {
                    var unchanged = true;
                    for (var i = 0; i < filters.Length; i++)
                        if (previous.Filters[i] != filters[i] || previous.Meshes[i] != meshes[i] ||
                            previous.LocalMatrices[i] != matrices[i]) { unchanged = false; break; }
                    if (unchanged) continue;
                }
                geometry.Remove(item.ObjectID); unavailable.Remove(item.ObjectID);
                obstacleCache.Remove(item.ObjectID); obstacleJSON.Remove(item.ObjectID); obstacleMatrices.Remove(item.ObjectID);
                var vertices = new List<Vector3>(); var indices = new List<int>(); var valid = true;
                for (var i = 0; i < filters.Length; i++) {
                    var mesh = meshes[i];
                    if (mesh == null || !mesh.isReadable) { valid = false; unavailable[item.ObjectID] = "nonreadableMesh"; break; }
                    var matrix = matrices[i];
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
                    BottomOffset = new Vector3(bounds.center.x, bounds.min.y, bounds.center.z),
                    Filters = filters, Meshes = meshes, LocalMatrices = matrices, Scale = root.lossyScale };
                Debug.Log($"Placement geometry cached: objectID={item.ObjectID}; vertices={vertices.Count}; triangles={indices.Count/3}; bounds={bounds}; bottomOffset={geometry[item.ObjectID].BottomOffset}");
            }
            foreach (var id in new List<string>(geometry.Keys)) if (!retained.Contains(id)) {
                geometry.Remove(id); unavailable.Remove(id);
                obstacleCache.Remove(id); obstacleJSON.Remove(id); obstacleMatrices.Remove(id);
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
            // Resolve a stable support plane from continuous measured floor.
            // Furniture may bridge a recess; its whole underside need not touch.
            if (TryResolveFootprintSupportHeight(grid, anchor, new Vector2(bounds.size.x, bounds.size.z), yaw, out var restingHeight)) {
                anchor = (JObject)anchor.DeepClone();
                anchor["supportHeight"] = restingHeight;
            }
            // Grid and blocking geometry are immutable within the derived-grid
            // session. Environment faces are queried around each released pose.
            gridJSON ??= grid.ToString(Newtonsoft.Json.Formatting.None);
            blockingJSON ??= (blocking ?? new JArray()).ToString(Newtonsoft.Json.Formatting.None);
            var cosine = Mathf.Cos(yaw); var sine = Mathf.Sin(yaw);
            var centerX = x * spacing + cosine * half.x + sine * half.y;
            var centerZ = z * spacing - sine * half.x + cosine * half.y;
            var support = (float)anchor["supportHeight"];
            var extentX = Mathf.Abs(cosine) * half.x + Mathf.Abs(sine) * half.y;
            var extentZ = Mathf.Abs(sine) * half.x + Mathf.Abs(cosine) * half.y;
            // Match SceneKit's local triangle query; the authority still performs
            // exact SAT. Complete placed meshes remain intact for containment.
            var localTriangles = QueryEnvironmentTriangles(triangles,
                new Vector3(centerX - extentX, support, centerZ - extentZ),
                new Vector3(centerX + extentX, support + bounds.size.y, centerZ + extentZ));
            var placed = new JArray();
            foreach (var entry in matrices) {
                if (!obstacleMatrices.TryGetValue(entry.Key, out var old) || old != entry.Value) {
                    var mesh = geometry[entry.Key]; var faces = new JArray(); var vertices = new JArray();
                    var lookup = new Dictionary<(int x, int y, int z), int>();
                    var vertexIndices = new int[mesh.LocalVertices.Length];
                    for (var i = 0; i < mesh.LocalVertices.Length; i++) {
                        var p = entry.Value.MultiplyPoint3x4(mesh.LocalVertices[i]);
                        var key = (BitConverter.SingleToInt32Bits(p.x), BitConverter.SingleToInt32Bits(p.y), BitConverter.SingleToInt32Bits(-p.z));
                        if (!lookup.TryGetValue(key, out var index)) {
                            index = vertices.Count; lookup[key] = index;
                            vertices.Add(new JArray(p.x, p.y, -p.z));
                        }
                        vertexIndices[i] = index;
                    }
                    for (var i = 0; i + 2 < mesh.Indices.Length; i += 3) {
                        faces.Add(new JArray(vertexIndices[mesh.Indices[i]], vertexIndices[mesh.Indices[i+2]], vertexIndices[mesh.Indices[i+1]]));
                    }
                    obstacleCache[entry.Key] = new JObject { ["shape"] = "mesh", ["id"] = entry.Key,
                        ["triangles"] = new JObject { ["vertices"] = vertices, ["indices"] = faces } };
                    obstacleJSON[entry.Key] = obstacleCache[entry.Key].ToString(Newtonsoft.Json.Formatting.None);
                    obstacleMatrices[entry.Key] = entry.Value;
                }
                placed.Add(new JRaw(obstacleJSON[entry.Key]));
            }
            return new JObject { ["grid"] = new JRaw(gridJSON), ["anchor"] = anchor.DeepClone(),
                ["footprint"] = new JObject { ["size"] = new JArray(bounds.size.x, bounds.size.z), ["yaw"] = yaw },
                ["height"] = bounds.size.y, ["triangles"] = localTriangles,
                ["blockingVolumes"] = new JRaw(blockingJSON), ["placedObstacles"] = placed };
        }
        public static bool TryPickEnvironment(JArray source, Ray ray, out Vector3 point, bool supportOnly = false)
        {
            point = default; var nearest = float.PositiveInfinity;
            if (source == null) return false;
            foreach (JArray triangle in source) {
                Vector3 Read(int i) => new Vector3((float)triangle[i][0], (float)triangle[i][1], -(float)triangle[i][2]);
                var a = Read(0); var edge1 = Read(1)-a; var edge2 = Read(2)-a;
                if (supportOnly && Mathf.Abs(Vector3.Cross(edge1, edge2).normalized.y) < .7f) continue;
                var cross = Vector3.Cross(ray.direction, edge2);
                var determinant = Vector3.Dot(edge1, cross);
                if (Mathf.Abs(determinant) < .000001f) continue;
                var inverse = 1f/determinant; var offset = ray.origin-a;
                var u = Vector3.Dot(offset,cross)*inverse;
                if (u < 0 || u > 1) continue;
                var q = Vector3.Cross(offset,edge1); var v = Vector3.Dot(ray.direction,q)*inverse;
                if (v < 0 || u+v > 1) continue;
                var distance = Vector3.Dot(edge2,q)*inverse;
                if (distance < 0 || distance >= nearest) continue;
                nearest = distance; point = ray.GetPoint(distance);
            }
            return !float.IsPositiveInfinity(nearest);
        }
        public static JArray QueryEnvironmentTriangles(JArray source, Vector3 minimum, Vector3 maximum)
        {
            const float margin = .01f;
            minimum -= Vector3.one * margin; maximum += Vector3.one * margin;
            var result = new JArray();
            foreach (JArray triangle in source) {
                var lower = new Vector3(float.PositiveInfinity, float.PositiveInfinity, float.PositiveInfinity);
                var upper = new Vector3(float.NegativeInfinity, float.NegativeInfinity, float.NegativeInfinity);
                foreach (JArray vertex in triangle) {
                    var point = new Vector3((float)vertex[0], (float)vertex[1], (float)vertex[2]);
                    lower = Vector3.Min(lower, point); upper = Vector3.Max(upper, point);
                }
                if (upper.x < minimum.x || lower.x > maximum.x || upper.y < minimum.y || lower.y > maximum.y ||
                    upper.z < minimum.z || lower.z > maximum.z) continue;
                result.Add(triangle.DeepClone());
            }
            return result;
        }
        public static bool TryResolveFootprintSupportHeight(JObject grid, JObject anchor, Vector2 size, float yaw, out float height)
        {
            height = (float)anchor["supportHeight"];
            var spacing = (float)grid["spacing"];
            var columnX = (int)anchor["column"]["x"]; var columnZ = (int)anchor["column"]["z"];
            var cosine = Mathf.Cos(yaw); var sine = Mathf.Sin(yaw);
            var half = size * .5f;
            var center = new Vector2(columnX * spacing + cosine * half.x + sine * half.y,
                columnZ * spacing - sine * half.x + cosine * half.y);
            var extent = new Vector2(Mathf.Abs(cosine) * half.x + Mathf.Abs(sine) * half.y,
                Mathf.Abs(sine) * half.x + Mathf.Abs(cosine) * half.y);
            var lowX = Mathf.FloorToInt((center.x - extent.x) / spacing); var highX = Mathf.FloorToInt((center.x + extent.x) / spacing);
            var lowZ = Mathf.FloorToInt((center.y - extent.y) / spacing); var highZ = Mathf.FloorToInt((center.y + extent.y) / spacing);
            if ((double)(highX - lowX + 1) * (highZ - lowZ + 1) > 4096) return false;
            var heights = new Dictionary<(int, int), float>();
            foreach (var layer in (JArray)grid["layers"])
                if ((int)layer["layer"] == (int)anchor["layer"])
                    heights[((int)layer["column"]["x"], (int)layer["column"]["z"])] = (float)layer["supportHeight"];
            var first = new Vector2(cosine, -sine); var second = new Vector2(sine, cosine);
            var axes = new[] { first, second, Vector2.right, Vector2.up };
            var covered = new Dictionary<(int x,int z),float>();
            float maximum = float.NegativeInfinity;
            for (int x = lowX; x <= highX; x++) for (int z = lowZ; z <= highZ; z++) {
                var offset = new Vector2((x + .5f) * spacing, (z + .5f) * spacing) - center;
                var separated = false;
                foreach (var axis in axes) {
                    var radius = half.x * Mathf.Abs(Vector2.Dot(first, axis)) + half.y * Mathf.Abs(Vector2.Dot(second, axis))
                        + spacing * .5f * (Mathf.Abs(axis.x) + Mathf.Abs(axis.y));
                    if (Mathf.Abs(Vector2.Dot(offset, axis)) >= radius - .0001f) { separated = true; break; }
                }
                if (separated) continue;
                if (!heights.TryGetValue((x, z), out var value) || !float.IsFinite(value)) return false;
                covered[(x,z)] = value; maximum = Mathf.Max(maximum, value);
            }
            const float contactBand = .02f;
            const float rounding = .0001f;
            if (covered.Count == 0 || !float.IsFinite(maximum)) return false;
            var contacts = new List<Vector2>();
            foreach (var entry in covered) {
                var cell = entry.Key;
                // Recesses below the resting plane do not become obstacles merely
                // because adjacent samples differ. Only actual near-plane contact
                // contributes to the stable support hull.
                if(maximum-entry.Value>contactBand+rounding) continue;
                contacts.Add(new Vector2(cell.x*spacing,cell.z*spacing));
                contacts.Add(new Vector2((cell.x+1)*spacing,cell.z*spacing));
                contacts.Add(new Vector2((cell.x+1)*spacing,(cell.z+1)*spacing));
                contacts.Add(new Vector2(cell.x*spacing,(cell.z+1)*spacing));
            }
            if(!SupportHullContainsCenter(contacts,center)) return false;
            height = maximum;
            return true;
        }
        static bool SupportHullContainsCenter(List<Vector2> points,Vector2 center)
        {
            points.Sort((a,b) => a.x!=b.x ? a.x.CompareTo(b.x) : a.y.CompareTo(b.y));
            var unique=new List<Vector2>();
            foreach(var point in points)
                if(unique.Count==0 || !unique[unique.Count-1].Equals(point)) unique.Add(point);
            if(unique.Count<3) return false;
            float Cross(Vector2 a,Vector2 b,Vector2 c) => (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x);
            var hull=new List<Vector2>();
            foreach(var point in unique) {
                while(hull.Count>=2 && Cross(hull[hull.Count-2],hull[hull.Count-1],point)<=0) hull.RemoveAt(hull.Count-1);
                hull.Add(point);
            }
            var lower=hull.Count;
            for(int i=unique.Count-2;i>=0;i--) {
                var point=unique[i];
                while(hull.Count>lower && Cross(hull[hull.Count-2],hull[hull.Count-1],point)<=0) hull.RemoveAt(hull.Count-1);
                hull.Add(point);
            }
            hull.RemoveAt(hull.Count-1);
            if(hull.Count<3) return false;
            for(int i=0;i<hull.Count;i++)
                if(Cross(hull[i],hull[(i+1)%hull.Count],center)<=.0001f) return false;
            return true;
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
