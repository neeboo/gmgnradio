using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using GLTFast;
using GLTFast.Logging;
using GLTFast.Materials;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace GMGN.UnityPlayer.World
{
    public sealed class GltfWorldAssetLoader : IWorldAssetLoader
    {
        public Task<GameObject> LoadPreparedAsset(string packageLocalPath, JObject prop, CancellationToken cancellation)
            => Load(packageLocalPath, prop ?? throw new ArgumentNullException(nameof(prop)), cancellation);

        public Task<GameObject> LoadSceneAsset(string packageLocalPath, CancellationToken cancellation)
            => Load(packageLocalPath, null, cancellation);

        async Task<GameObject> Load(string packageLocalPath, JObject prop, CancellationToken cancellation)
        {
            // Backup blobs have no extension. Validate the GLB container itself.
            // Reject remote/external resources: recovery only reads verified bytes.
            ValidateEmbeddedGlb(packageLocalPath);
            var root = new GameObject("Recovered asset");
            var content = new GameObject("Model");
            content.transform.SetParent(root.transform, false);
            var logger = new CollectingLogger();
            var pipeline = (QualitySettings.renderPipeline != null ? QualitySettings.renderPipeline : GraphicsSettings.defaultRenderPipeline) as UniversalRenderPipelineAsset;
            if (pipeline == null) { UnityEngine.Object.Destroy(root); throw new InvalidDataException("空间模型需要启用 URP 渲染管线。"); }
            var importer = new GltfImport(materialGenerator: new WorldUrpMaterialGenerator(pipeline), logger: logger);
            try
            {
                if (!await importer.LoadFile(packageLocalPath, cancellationToken: cancellation) ||
                    !await importer.InstantiateMainSceneAsync(content.transform, cancellation))
                    throw new InvalidDataException("这个 GLB 模型没有成功加载。");
                cancellation.ThrowIfCancellationRequested();
                foreach (var renderer in content.GetComponentsInChildren<Renderer>(true))
                    foreach (var material in renderer.sharedMaterials)
                    {
                        if (material == null || material.shader == null || !material.shader.isSupported || material.shader.name == "Hidden/InternalErrorShader")
                            throw new WorldMaterialException("shader_unavailable", "模型材质着色器未正确打包，暂时无法显示这个物件。");
                        Debug.Log("[WorldMaterial] shader=" + material.shader.name + " keywords=" + string.Join(",", material.shaderKeywords));
                    }
                if (prop != null) Prepare(root.transform, content.transform, prop);
                root.AddComponent<WorldGltfLifetime>().Importer = importer;
                return root;
            }
            catch { logger.LogAll(); importer.Dispose(); UnityEngine.Object.Destroy(root); throw; }
        }

        public static void Prepare(Transform root, Transform content, JObject prop)
        {
            if (prop["orientation"]?["rotation"] is JObject rotation) content.localRotation = WorldCoordinates.Rotation(rotation);
            var sizeToken = (bool?)prop["sizeLocked"] == true || (prop["sizeIntent"] != null && prop["sizeIntent"].Type != JTokenType.Null)
                ? prop["size"] : prop["authoritativeSize"]?["dimensions"] ?? prop["size"];
            var target = WorldCoordinates.Scale(sizeToken);
            if (target.x <= 0 || target.y <= 0 || target.z <= 0 || target.x > 100 || target.y > 100 || target.z > 100)
                throw new InvalidDataException("物件尺寸无效。");
            var bounds = BoundsIn(root, content);
            var extent = bounds.size;
            if (extent.x < 0.00001f || extent.y < 0.00001f || extent.z < 0.00001f) throw new InvalidDataException("模型包围盒为空或退化。");
            // Normalize in world axes after orientation, using a separate parent
            // so non-uniform scale does not change the asset's orientation.
            var normalization = new GameObject("Authoritative size").transform;
            normalization.SetParent(root, false);
            content.SetParent(normalization, false);
            normalization.localScale = new Vector3(target.x / extent.x, target.y / extent.y, target.z / extent.z);
            normalization.localPosition = -Vector3.Scale(new Vector3(bounds.center.x, bounds.min.y, bounds.center.z), normalization.localScale);
        }

        static Bounds BoundsIn(Transform root, Transform content)
        {
            var initialized = false;
            var total = new Bounds();
            foreach (var renderer in content.GetComponentsInChildren<Renderer>(true))
            {
                Bounds local;
                if (renderer is SkinnedMeshRenderer skinned) local = skinned.localBounds;
                else { var filter = renderer.GetComponent<MeshFilter>(); if (filter?.sharedMesh == null) continue; local = filter.sharedMesh.bounds; }
                for (var i = 0; i < 8; i++)
                {
                    var p = new Vector3((i & 1) == 0 ? local.min.x : local.max.x, (i & 2) == 0 ? local.min.y : local.max.y, (i & 4) == 0 ? local.min.z : local.max.z);
                    p = root.InverseTransformPoint(renderer.transform.TransformPoint(p));
                    if (!initialized) { total = new Bounds(p, Vector3.zero); initialized = true; } else total.Encapsulate(p);
                }
            }
            if (!initialized) throw new InvalidDataException("模型没有可显示的网格。");
            return total;
        }

        static void ValidateEmbeddedGlb(string path)
        {
            using (var stream = File.OpenRead(path)) using (var reader = new BinaryReader(stream))
            {
                if (stream.Length < 20 || reader.ReadUInt32() != 0x46546c67 || reader.ReadUInt32() != 2 || reader.ReadUInt32() != stream.Length)
                    throw new InvalidDataException("备份模型不是有效的 GLB 2.0 文件。");
                var length = reader.ReadUInt32();
                if (reader.ReadUInt32() != 0x4e4f534a || length > stream.Length - 20 || length > 16 * 1024 * 1024)
                    throw new InvalidDataException("GLB 模型头部无效。");
                var json = JObject.Parse(Encoding.UTF8.GetString(reader.ReadBytes((int)length)));
                foreach (var kind in new[] { "buffers", "images" })
                    foreach (var item in json[kind] as JArray ?? new JArray())
                    {
                        var uri = (string)item["uri"];
                        if (uri != null && !uri.StartsWith("data:", StringComparison.Ordinal))
                            throw new InvalidDataException("这个模型引用了备份以外的资源，暂时无法恢复。");
                    }
            }
        }
    }

    public sealed class WorldMaterialException : Exception
    {
        public string Code { get; }
        public WorldMaterialException(string code, string message) : base(message) { Code = code; }
    }

    /// Retains glTFast's complete URP material conversion. Only shader lookup
    /// changes: a Resources reference is loaded before Shader.Find would run.
    sealed class WorldUrpMaterialGenerator : UniversalRPMaterialGenerator
    {
        public WorldUrpMaterialGenerator(UniversalRenderPipelineAsset pipeline) : base(pipeline) { }
        protected override Shader LoadShaderByName(string shaderName)
        {
            var reference = Resources.Load<Material>("WorldShaders/" + shaderName + "-0");
            if (reference == null || reference.shader == null)
                throw new WorldMaterialException("shader_reference_missing", "模型材质资源未打包，请更新这个测试版本。");
            Debug.Log("[WorldShader] loaded=" + reference.shader.name + " supported=" + reference.shader.isSupported);
            if (!reference.shader.isSupported)
                throw new WorldMaterialException("shader_unsupported", "模型着色器不支持当前图形设备。");
            return reference.shader;
        }
    }

    public sealed class WorldGltfLifetime : MonoBehaviour
    {
        public GltfImport Importer;
        void OnDestroy() { Importer?.Dispose(); Importer = null; }
    }
}
