using System;
using GMGN.UnityPlayer.WorldPlacementGeometry;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class PlacementGridChecks
    {
        public static void Validate()
        {
            var host = new GameObject("local-placement-grid-fixture");
            try {
                var shader = Resources.Load<Shader>("PlacementGrid");
                if (shader != null)
                    foreach (var message in ShaderUtil.GetShaderMessages(shader)) Debug.Log(message.message);
                if (shader == null || ShaderUtil.ShaderHasError(shader))
                    throw new Exception("Placement grid shader failed to compile.");
                var view = host.AddComponent<PlacementGridView>();
                view.Initialize(shader);
                var result = new JObject { ["canPlace"] = true, ["columns"] = new JArray(
                    new JObject { ["x"] = 10, ["z"] = -5 },
                    new JObject { ["x"] = 11, ["z"] = -5 }) };
                view.ShowPreview(result, .2f, .5f);
                var mesh = host.GetComponent<MeshFilter>().sharedMesh;
                var renderer = host.GetComponent<MeshRenderer>();
                if (mesh.vertexCount != 12 * 4 || mesh.triangles.Length != 12 * 6)
                    throw new Exception("Footprint border was duplicated or extended beyond its local cells.");
                if (Mathf.Abs(mesh.bounds.size.x - .8f) > .0001f ||
                    Mathf.Abs(mesh.bounds.size.z - .6f) > .0001f ||
                    Mathf.Abs(mesh.bounds.center.y - .512f) > .0001f)
                    throw new Exception("Footprint grid bounds or support height are incorrect.");
                var accepted = renderer.sharedMaterial.GetColor("_Color");
                if (!renderer.enabled || accepted.g <= accepted.r)
                    throw new Exception("Complete accepted footprint was not green.");
                result["canPlace"] = false;
                view.ShowPreview(result, .2f, .5f);
                var rejected = renderer.sharedMaterial.GetColor("_Color");
                if (rejected.r <= rejected.g || mesh.vertexCount != 12 * 4)
                    throw new Exception("Complete rejected footprint was not uniformly red.");
                result["columns"] = new JArray();
                view.ShowPreview(result, .2f, .5f);
                if (renderer.enabled || mesh.vertexCount != 0)
                    throw new Exception("Missing footprint left a stale grid visible.");
                Debug.Log("PASS placement grid: footprint plus one-cell border only, deduplicated local bounds/support height, whole-footprint green/red, empty preview hidden, shader compiled.");
            } finally { UnityEngine.Object.DestroyImmediate(host); }
        }
    }
}
