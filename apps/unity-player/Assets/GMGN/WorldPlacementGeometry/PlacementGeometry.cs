using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using GMGN.UnityPlayer.World;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer.WorldPlacementGeometry
{
    // Immutable-session geometry; Rust alone derives the grid and decides legality.
    public sealed class PlacementGeometry
    {
        public JObject DeriveRequest { get; private set; }
        public static async Task<PlacementGeometry> LoadBundledCabin(PortableWorldPackage package, CancellationToken cancellation)
        {
            const string root = "assets/cabin/";
            var world = JObject.Parse(File.ReadAllText(package.ResolvePackageFile(root + "world.json")));
            var marble = JObject.Parse(File.ReadAllText(package.ResolvePackageFile(root + "marble.json")));
            if ((string)world["packageID"] != "marble-living-cabin" || (string)world["worldID"] != (string)marble["world"]?["world_id"])
                throw new InvalidDataException("碰撞包与生活舱编号不一致。");
            var framing = marble["framing"];
            var scale = (float)framing["scale"];
            var origin = UnityPoint(framing["origin"]);
            if (!float.IsFinite(scale) || scale <= 0) throw new InvalidDataException("碰撞包校准比例无效。");
            // Load first adapts glTFast's reflected-X scene to our reflected-Z
            // scene basis. Then match Swift WorldLabs OpenCV flips Y/Z,
            // subtract framing origin and scale.
            var matrix = Matrix4x4.TRS(-origin * scale, Quaternion.identity, new Vector3(scale, -scale, -scale));
            var geometry = await Load(package, root + "collider.glb", matrix,
                WorldCoordinates.Position(world["spawn"]["position"]), cancellation);
            geometry.AddManifestBlockingVolumes((JArray)world["collisionVolumes"]);
            return geometry;
        }
        public static async Task<PlacementGeometry> Load(PortableWorldPackage package, string colliderReference,
            Matrix4x4 unityColliderToGameplay, Vector3 seedUnity, CancellationToken cancellation)
        {
            if (string.IsNullOrEmpty(colliderReference))
                throw new InvalidDataException("空间备份缺少真实碰撞模型，暂时不能摆放。");
            var path = colliderReference.StartsWith("assets/", StringComparison.Ordinal)
                ? package.ResolvePackageFile(colliderReference) : package.ResolveReference(colliderReference);
            var model = await new GltfWorldAssetLoader().LoadCollisionAsset(path, cancellation);
            try
            {
                // The collider is query data, never a visible replacement of the scene.
                foreach (var renderer in model.GetComponentsInChildren<Renderer>(true)) renderer.enabled = false;
                var snapshots = new List<MeshSnapshot>();
                foreach (var filter in model.GetComponentsInChildren<MeshFilter>(true))
                {
                    var mesh = filter.sharedMesh;
                    if (mesh == null) continue;
                    if (!mesh.isReadable) throw new InvalidDataException("碰撞模型未保留几何数据，请启用 GLTFAST_KEEP_MESH_DATA 后重新构建。");
                    var vertices = mesh.vertices; var indices = mesh.triangles;
                    // Installed glTFast 6.20 ConvertVector3FloatToFloatInterleavedJob
                    // flips X (not Z), and NodeExtension reflects node transforms
                    // in the same basis. Y180 maps that entire scene into the Z-
                    // reflected Unity basis used by WorldCoordinates.
                    var importedToWorldBasis = Matrix4x4.Scale(new Vector3(-1, 1, -1));
                    var matrix = unityColliderToGameplay * importedToWorldBasis
                        * model.transform.worldToLocalMatrix * filter.transform.localToWorldMatrix;
                    snapshots.Add(new MeshSnapshot { Vertices = vertices, Indices = indices, Matrix = matrix });
                    cancellation.ThrowIfCancellationRequested();
                    await Task.Yield();
                }
                // Only value-type arrays leave the main thread. No Unity objects,
                // transforms, mesh properties or rendering APIs are accessed here.
                return await Task.Run(() => BuildRequest(snapshots, seedUnity, cancellation), cancellation);
            }
            finally { UnityEngine.Object.Destroy(model); }
        }
        sealed class MeshSnapshot { public Vector3[] Vertices; public int[] Indices; public Matrix4x4 Matrix; }
        static PlacementGeometry BuildRequest(List<MeshSnapshot> snapshots, Vector3 seedUnity, CancellationToken cancellation)
        {
                var triangles = new JArray();
                var bounds = new Bounds(); var initialized = false;
                foreach (var snapshot in snapshots)
                {
                    var indices = snapshot.Indices; var vertices = snapshot.Vertices; var matrix = snapshot.Matrix;
                    for (var i = 0; i < indices.Length; i += 3)
                    {
                        if ((i & 1023) == 0) cancellation.ThrowIfCancellationRequested();
                        // glTFast already reverses winding for its X reflection;
                        // Y180 is orientation preserving. Reverse winding with
                        // the final Z reflection back to the Swift/Rust convention.
                        var face = new JArray();
                        for (int corner = 0; corner < 3; corner++)
                        {
                            var index = indices[i + (corner == 0 ? 0 : corner == 1 ? 2 : 1)];
                            var point = matrix.MultiplyPoint3x4(vertices[index]);
                            Check(point); if (!initialized) { bounds = new Bounds(point, Vector3.zero); initialized = true; } else bounds.Encapsulate(point);
                            face.Add(RightHanded(point));
                        }
                        triangles.Add(face);
                    }
                }
                if (triangles.Count == 0) throw new InvalidDataException("真实碰撞模型没有三角形，无法生成摆放格子。");
                return new PlacementGeometry { DeriveRequest = new JObject {
                    ["triangles"] = triangles, ["blockingVolumes"] = new JArray(), ["seed"] = RightHanded(seedUnity),
                    ["bounds"] = new JObject { ["minimumX"] = bounds.min.x, ["maximumX"] = bounds.max.x,
                        ["minimumZ"] = -bounds.max.z, ["maximumZ"] = -bounds.min.z } } };
        }
        public static JArray RightHanded(Vector3 point) { Check(point); return new JArray(point.x, point.y, -point.z); }
        public void AddManifestBlockingVolumes(JArray volumes)
        {
            var output = (JArray)DeriveRequest["blockingVolumes"];
            // Preserve arbitrary rotation as real box triangles. A yaw-only
            // approximation would change tilted collision volumes.
            foreach (var volume in volumes)
            {
                if ((bool?)volume["isBlocking"] != true) continue;
                var center = WorldCoordinates.Position(volume["center"]);
                var half = WorldCoordinates.Scale(volume["halfExtents"]);
                if (half.x <= 0 || half.y <= 0 || half.z <= 0) throw new InvalidDataException("空间碰撞体尺寸无效。");
                var rotation = WorldCoordinates.Rotation(volume["rotation"]);
                var corners = new Vector3[8];
                for (int i = 0; i < 8; i++) corners[i] = center + rotation * new Vector3((i & 1) == 0 ? -half.x : half.x,
                    (i & 2) == 0 ? -half.y : half.y, (i & 4) == 0 ? -half.z : half.z);
                int[] faces = { 0,2,3,0,3,1,4,5,7,4,7,6,0,1,5,0,5,4,2,6,7,2,7,3,0,4,6,0,6,2,1,3,7,1,7,5 };
                var triangles = new JArray();
                for (int i = 0; i < faces.Length; i += 3)
                    triangles.Add(new JArray(RightHanded(corners[faces[i]]), RightHanded(corners[faces[i+2]]), RightHanded(corners[faces[i+1]])));
                output.Add(new JObject { ["shape"] = "mesh", ["id"] = (string)volume["id"], ["isClosed"] = true, ["triangles"] = triangles });
            }
        }
        public static Vector3 UnityPoint(JToken point) => new Vector3((float)point[0], (float)point[1], -(float)point[2]);
        static void Check(Vector3 point)
        {
            if (!float.IsFinite(point.x) || !float.IsFinite(point.y) || !float.IsFinite(point.z))
                throw new InvalidDataException("碰撞模型包含无效坐标。");
        }
    }
}
