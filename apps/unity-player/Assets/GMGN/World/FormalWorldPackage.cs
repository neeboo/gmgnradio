using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using Newtonsoft.Json.Linq;

namespace GMGN.UnityPlayer.World
{
    // Read-only counterpart of the host's validated world.json package. This
    // does not manufacture a backup manifest or import another authority state.
    public sealed class FormalWorldPackage
    {
        public string Root { get; }
        public JObject Manifest { get; }
        readonly Dictionary<string, string> resources = new(StringComparer.Ordinal);
        readonly Dictionary<string, string> hashes = new(StringComparer.Ordinal);
        FormalWorldPackage(string root, JObject manifest) { Root = root; Manifest = manifest; }

        public static FormalWorldPackage Open(string directory, string worldID, string manifestHash)
        {
            var root = Path.GetFullPath(directory);
            RejectLinks(root);
            var manifestPath = Path.Combine(root, "world.json");
            RejectLinks(manifestPath);
            if (!File.Exists(manifestPath) || new FileInfo(manifestPath).Length > 8 * 1024 * 1024 || Hash(manifestPath) != manifestHash)
                throw new InvalidDataException("空间声明已变化或校验失败，请刷新空间列表。");
            var manifest = JObject.Parse(File.ReadAllText(manifestPath));
            if ((int?)manifest["schemaVersion"] != 1 || (string)manifest["worldID"] != worldID || !(manifest["resources"] is JArray entries))
                throw new InvalidDataException("空间声明身份或版本不支持。");
            var package = new FormalWorldPackage(root, manifest);
            foreach (var entry in entries) {
                var id = (string)entry["id"]; var relative = (string)entry["path"]; var hash = (string)entry["sha256"];
                if (!IsHash(hash) || string.IsNullOrEmpty(id) || package.resources.ContainsKey(id) || string.IsNullOrEmpty(relative) ||
                    relative.Contains("\\") || relative.Contains(":") || Path.IsPathRooted(relative))
                    throw new InvalidDataException("空间资源声明无效。");
                foreach (var part in relative.Split('/')) if (part == "" || part == "." || part == "..")
                    throw new InvalidDataException("空间资源路径无效。");
                var path = Path.Combine(root, relative);
                RejectLinks(path);
                if (!File.Exists(path) || Hash(path) != hash) throw new InvalidDataException("空间资源缺失或校验失败：" + id);
                package.resources.Add(id, path);
                if (!package.hashes.ContainsKey(hash)) package.hashes.Add(hash, path);
            }
            return package;
        }
        public string ResolveResource(string id)
            => resources.TryGetValue(id, out var path) ? path : throw new InvalidDataException("空间没有这个已登记资源。");
        public string ResolveResourcePath(string relative, string kind)
        {
            JObject selected = null;
            foreach (JObject entry in (JArray)Manifest["resources"])
                if ((string)entry["path"] == relative && (string)entry["kind"] == kind) {
                    if (selected != null) throw new InvalidDataException("空间资源声明重复。");
                    selected = entry;
                }
            if (selected == null) throw new InvalidDataException("空间环境文件未登记在正式包中。");
            return ResolveResource((string)selected["id"]);
        }
        public JObject ReadMarbleRuntime()
        {
            JObject selected = null;
            foreach (JObject entry in (JArray)Manifest["resources"])
                if ((string)entry["kind"] == "environment.marble") {
                    if (selected != null) throw new InvalidDataException("空间包含多个 Marble 环境配置。");
                    selected = entry;
                }
            if (selected == null) return null;
            var document = JObject.Parse(File.ReadAllText(ResolveResource((string)selected["id"])));
            var scale = (float?)document["uniformScale"] ?? 0;
            var axis = (string)document["colliderAxisConversion"];
            if ((int?)document["schemaVersion"] != 1 || (string)document["worldID"] != (string)Manifest["worldID"] ||
                !float.IsFinite(scale) || scale <= 0 || (axis != "identity" && axis != "flipYAndZ"))
                throw new InvalidDataException("Marble 环境配置身份或坐标转换无效。");
            foreach (var key in new[] { "origin", "minimum", "maximum" }) {
                if (!(document[key] is JArray vector) || vector.Count != 3) throw new InvalidDataException("Marble 环境坐标无效。");
                foreach (var number in vector)
                    if ((number.Type != JTokenType.Float && number.Type != JTokenType.Integer) || !float.IsFinite((float)number))
                        throw new InvalidDataException("Marble 环境坐标无效。");
            }
            for (int i = 0; i < 3; i++)
                if ((float)document["minimum"][i] >= (float)document["maximum"][i]) throw new InvalidDataException("Marble 环境边界无效。");
            ResolveResourcePath((string)document["splatPath"], "environment.spz");
            ResolveResourcePath((string)document["colliderPath"], "environment.collider");
            return document;
        }
        public string ResolveAssetID(string assetID)
        {
            const string prefix = "sha256:";
            if (assetID != null && assetID.StartsWith(prefix, StringComparison.Ordinal) && hashes.TryGetValue(assetID.Substring(prefix.Length), out var path)) return path;
            throw new InvalidDataException("物件资产未包含在正式空间包中。");
        }
        static string Hash(string path)
        {
            using var sha = SHA256.Create(); using var stream = File.OpenRead(path);
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
        static bool IsHash(string value)
        {
            if (value == null || value.Length != 64) return false;
            foreach (var c in value) if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f')) return false;
            return true;
        }
        static void RejectLinks(string path)
        {
            var current = Path.GetFullPath(path);
            while (!string.IsNullOrEmpty(current)) {
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("空间包不允许符号链接。");
                current = Path.GetDirectoryName(current);
            }
        }
    }
}
