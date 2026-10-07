using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;

namespace GMGN.UnityPlayer.World
{
    // Catalog generation is local to each host catalog instance and can restart
    // at the same value after selection. Compare the actual capability snapshot.
    public sealed class GeneratedAssetProjectionGate
    {
        JObject previous;
        public bool Accept(JObject catalog)
        {
            if (JToken.DeepEquals(previous, catalog)) return false;
            previous = (JObject)catalog.DeepClone();
            return true;
        }
    }

    // Only known, static messages become log codes. Never log exception messages
    // or stacks: unknown IO/JSON failures may contain local paths or payloads.
    public static class WorldAssetFailureDiagnostics
    {
        public static string Code(Exception error)
        {
            if (!(error is InvalidDataException)) return error.GetType().Name;
            return error.Message switch {
                "物件资产未包含在正式空间包中。" => "formal_asset_missing",
                "这个模型未包含在空间备份中。" => "backup_asset_missing",
                "这个模型尚未进入正式资产清单。" => "generated_catalog_missing",
                "生成资产清单尚未同步，原库存记录已保留。" => "generated_catalog_pending",
                "生成模型缺失或长度校验失败。" => "generated_length_mismatch",
                "生成模型内容校验失败。" => "generated_hash_mismatch",
                "生成资产路径不能包含符号链接。" => "generated_path_link",
                "物件资产身份不一致。" => "object_identity_mismatch",
                "物件位置数据不完整。" => "transform_incomplete",
                "物件位置数据无效。" => "transform_invalid",
                "物件旋转数据无效。" => "rotation_invalid",
                "备份模型不是有效的 GLB 2.0 文件。" => "glb_container_invalid",
                "GLB 模型头部无效。" => "glb_header_invalid",
                "这个模型引用了备份以外的资源，暂时无法恢复。" => "glb_external_resource",
                "这个 GLB 模型没有成功加载。" => "glb_import_failed",
                "模型没有成功加载。" => "model_instance_missing",
                "空间模型需要启用 URP 渲染管线。" => "urp_pipeline_missing",
                "物件尺寸无效。" => "prop_size_invalid",
                "模型包围盒为空或退化。" => "model_bounds_degenerate",
                "模型没有可显示的网格。" => "model_mesh_missing",
                _ => "invalid_asset"
            };
        }
    }

    /// Native-host catalog is a projection of matching Rust task receipts and
    /// world inventory. Paths are additionally confined to the explicit taskd
    /// data root; this does not weaken immutable backup package verification.
    public sealed class GeneratedAssetResolver
    {
        readonly string worldID, taskRoot;
        readonly Dictionary<string, JObject> catalog = new(StringComparer.Ordinal);
        public GeneratedAssetResolver(string dataRoot, string worldID)
        {
            if (string.IsNullOrWhiteSpace(dataRoot) || string.IsNullOrWhiteSpace(worldID)) throw new InvalidDataException("尚未指定生成资产的数据范围。");
            this.worldID = worldID;
            taskRoot = Path.GetFullPath(Path.Combine(dataRoot, "gmgn radio", "TaskService"));
            RejectLinks(taskRoot);
        }
        public void SetCatalog(JObject manifest)
        {
            if ((string)manifest?["worldID"] != worldID || !(manifest["entries"] is JArray entries)) throw new InvalidDataException("生成资产清单不属于当前空间。");
            var next = new Dictionary<string, JObject>(StringComparer.Ordinal);
            foreach (var token in entries) {
                if (!(token is JObject entry) || !Guid.TryParse((string)entry["taskID"], out var taskID) ||
                    !Guid.TryParse((string)entry["sourceWishID"], out _) || string.IsNullOrEmpty((string)entry["objectID"]))
                    throw new InvalidDataException("生成资产身份不完整。");
                var hash = (string)entry["sha256"];
                if (!ValidHash(hash) || (string)entry["assetID"] != "sha256:" + hash ||
                    !(entry["bytes"]?.Type == JTokenType.Integer) || (long)entry["bytes"] <= 0 || (long)entry["bytes"] > 32 * 1024 * 1024)
                    throw new InvalidDataException("生成资产校验信息无效。");
                var expected = Path.Combine(taskRoot, taskID.ToString("D").ToLowerInvariant() + ".glb");
                var historical = Path.Combine(taskRoot, taskID.ToString("D").ToUpperInvariant() + ".glb");
                var declaredPath = Path.GetFullPath((string)entry["localModelPath"] ?? "");
                if (declaredPath != expected && declaredPath != historical)
                    throw new InvalidDataException("生成模型路径不属于正式任务输出。");
                if (!next.TryAdd((string)entry["objectID"], (JObject)entry.DeepClone())) throw new InvalidDataException("生成资产身份重复。");
            }
            catalog.Clear(); foreach (var entry in next) catalog.Add(entry.Key, entry.Value);
        }
        public bool Contains(string objectID) => catalog.ContainsKey(objectID);
        public Task<string> Resolve(JObject prop, CancellationToken cancellation)
        {
            if (!catalog.TryGetValue((string)prop?["objectID"] ?? "", out var entry) ||
                (string)entry["sourceWishID"] != (string)prop["sourceWishID"] ||
                (string)entry["assetID"] != (string)prop["assetID"]) throw new InvalidDataException("这个模型尚未进入正式资产清单。");
            var snapshot = (JObject)entry.DeepClone();
            return Task.Run(() => {
                cancellation.ThrowIfCancellationRequested();
                var path = Path.GetFullPath((string)snapshot["localModelPath"]);
                RejectLinks(path);
                if (!File.Exists(path) || new FileInfo(path).Length != (long)snapshot["bytes"]) throw new InvalidDataException("生成模型缺失或长度校验失败。");
                using (var stream = File.OpenRead(path)) using (var sha = SHA256.Create()) {
                    var hash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                    if (hash != (string)snapshot["sha256"]) throw new InvalidDataException("生成模型内容校验失败。");
                }
                cancellation.ThrowIfCancellationRequested();
                return path;
            }, cancellation);
        }
        static bool ValidHash(string value) => value?.Length == 64 && value.All(c => c >= '0' && c <= '9' || c >= 'a' && c <= 'f');
        static void RejectLinks(string path)
        {
            for (var current = path; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("生成资产路径不能包含符号链接。");
        }
    }
}
