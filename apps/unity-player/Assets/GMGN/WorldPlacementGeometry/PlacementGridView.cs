using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Rendering;

namespace GMGN.UnityPlayer.WorldPlacementGeometry
{
    // Geometry is uploaded only when Rust's result changes; no per-frame CPU grid generation.
    public sealed class PlacementGridView : MonoBehaviour
    {
        Mesh mesh; Material material; MeshFilter filter; MeshRenderer display;
        public void Initialize(Shader shader)
        {
            if (shader == null || !shader.isSupported) throw new System.InvalidOperationException("摆放格子着色器不可用。");
            material = new Material(shader); mesh = new Mesh { indexFormat = IndexFormat.UInt32 };
            filter = gameObject.AddComponent<MeshFilter>(); filter.sharedMesh = mesh;
            display = gameObject.AddComponent<MeshRenderer>(); display.sharedMaterial = material;
            display.shadowCastingMode = ShadowCastingMode.Off; display.receiveShadows = false;
        }
        public void ShowPreview(JObject result, float spacing, float supportHeight)
        {
            // A single-cell border keeps the grid local to the complete item
            // footprint. Every cell reflects the same authoritative verdict.
            var nearby = new HashSet<Vector2Int>();
            foreach (var column in (JArray)result["columns"]) {
                var x = (int)column["x"]; var z = (int)column["z"];
                for (var dx = -1; dx <= 1; dx++)
                    for (var dz = -1; dz <= 1; dz++)
                        nearby.Add(new Vector2Int(x + dx, z + dz));
            }
            var cells = new List<Vector3>();
            foreach (var column in nearby)
                cells.Add(new Vector3(column.x * spacing, supportHeight, -column.y * spacing));
            Upload(cells, spacing, (bool?)result["canPlace"] == true ? new Color(.2f,1,.45f,.7f) : new Color(1,.15f,.15f,.7f));
        }
        public void ShowAuthoritativePreview(JObject result)
        {
            if (result?["columns"] is not JArray columns || result["spacing"] == null) { Hide(); return; }
            var spacing = (float)result["spacing"];
            var cells = new List<Vector3>();
            foreach (var item in columns) {
                if (item["column"] == null || item["height"] == null) { Hide(); return; }
                cells.Add(new Vector3((int)item["column"]["x"] * spacing, (float)item["height"], -(int)item["column"]["z"] * spacing));
            }
            // Colour is the Rust whole-object verdict projected onto its local footprint.
            Upload(cells, spacing, (bool?)result["canPlace"] == true ? new Color(.2f,1,.45f,.7f) : new Color(1,.15f,.15f,.7f));
        }
        void Upload(List<Vector3> cells, float spacing, Color color)
        {
            var vertices = new List<Vector3>(); var uv = new List<Vector2>(); var indices = new List<int>();
            foreach (var p in cells) {
                var n = vertices.Count; var lift = Vector3.up * .012f;
                vertices.Add(p + lift); vertices.Add(p + new Vector3(spacing,.012f,0));
                vertices.Add(p + new Vector3(spacing,.012f,-spacing)); vertices.Add(p + new Vector3(0,.012f,-spacing));
                uv.Add(Vector2.zero); uv.Add(Vector2.right); uv.Add(Vector2.one); uv.Add(Vector2.up);
                indices.AddRange(new[] {n,n+1,n+2,n,n+2,n+3});
            }
            mesh.Clear(); mesh.SetVertices(vertices); mesh.SetUVs(0,uv); mesh.SetTriangles(indices,0); mesh.RecalculateBounds();
            material.SetColor("_Color",color); display.enabled = cells.Count > 0;
        }
        public void Hide() { if (display != null) display.enabled = false; }
        void OnDestroy() { if (mesh != null) Destroy(mesh); if (material != null) Destroy(material); }
    }
}
