using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Newtonsoft.Json.Linq;

namespace GMGN.UnityPlayer.World
{
    /// Read-only recovery staging. Rust remains the only world-state writer.
    public sealed class PortableWorldPackage
    {
        public string Root { get; }
        public JObject Document { get; }
        readonly HashSet<string> files;
        PortableWorldPackage(string root, JObject document, HashSet<string> files)
        { Root = root; Document = document; this.files = files; }

        public static PortableWorldPackage Open(string directory)
        {
            var root = Path.GetFullPath(directory);
            RejectLinks(root);
            var manifest = JObject.Parse(File.ReadAllText(Path.Combine(root, "manifest.json")));
            if ((string)manifest["format"] != "gmgn.portable-world-backup" || (int?)manifest["formatVersion"] != 1)
                throw new InvalidDataException("空间备份版本不支持。");
            var entries = manifest["files"] as JArray ?? throw new InvalidDataException("空间备份缺少文件清单。");
            var listed = new HashSet<string>(StringComparer.Ordinal) { "manifest.json" };
            foreach (var token in entries)
            {
                var rel = (string)token["path"];
                var path = Resolve(root, rel);
                if (!listed.Add(rel) || !(rel == "worlds.json" || rel.StartsWith("assets/", StringComparison.Ordinal) || rel.StartsWith("blobs/", StringComparison.Ordinal)))
                    throw new InvalidDataException("空间备份文件清单重复或包含不支持的路径。");
                var bytes = (long?)token["bytes"];
                if (!File.Exists(path) || bytes == null || bytes < 0 || new FileInfo(path).Length != bytes || Hash(path) != (string)token["sha256"])
                    throw new InvalidDataException("空间备份文件缺失或校验失败：" + rel);
            }
            var actual = new HashSet<string>(StringComparer.Ordinal);
            foreach (var path in Enumerate(root)) actual.Add(path.Substring(root.Length + 1).Replace(Path.DirectorySeparatorChar, '/'));
            if (!listed.SetEquals(actual) || !listed.Contains("worlds.json"))
                throw new InvalidDataException("空间备份包含未登记文件或缺少世界数据。");
            var document = JObject.Parse(File.ReadAllText(Path.Combine(root, "worlds.json")));
            if ((int?)document["schemaVersion"] != 1 || !(document["records"] is JArray records) || records.Count == 0 || !(document["referenceBindings"] is JObject bindings) || !(document["blobs"] is JArray blobs))
                throw new InvalidDataException("空间备份数据结构不支持。");
            var identities = new HashSet<string>(StringComparer.Ordinal);
            foreach (var record in records)
            {
                var identity = new JArray(record["world_id"], record["domain"], record["key"]).ToString(Newtonsoft.Json.Formatting.None);
                if (new[] { "world_id", "domain", "key" }.Any(k => string.IsNullOrEmpty((string)record[k])) || !identities.Add(identity) || (long?)record["revision"] < 1 || record["revision"] == null || !new[] { 0, 1 }.Contains((int?)record["tombstone"] ?? -1) || record["value"] == null || record["hash"]?.Type != JTokenType.String)
                    throw new InvalidDataException("空间记录身份或版本无效。");
            }
            foreach (var binding in bindings.Properties())
                if (!listed.Contains((string)binding.Value)) throw new InvalidDataException("空间资产引用没有对应文件。");
            foreach (var blob in blobs)
            {
                var rel = (string)blob["path"];
                if (!listed.Contains(rel) || Hash(Resolve(root, rel)) != (string)blob["sha256"] || new FileInfo(Resolve(root, rel)).Length != (long?)blob["bytes"])
                    throw new InvalidDataException("空间资产索引校验失败。");
            }
            return new PortableWorldPackage(root, document, listed);
        }

        public string ResolveReference(string original)
        {
            var mapped = (string)Document["referenceBindings"]?[original];
            if (mapped == null || !files.Contains(mapped)) throw new InvalidDataException("这个资产未包含在备份中。");
            return Resolve(Root, mapped);
        }

        public string ResolveAssetID(string assetID)
        {
            const string prefix = "sha256:";
            if (assetID == null || !assetID.StartsWith(prefix, StringComparison.Ordinal)) throw new InvalidDataException("资产编号不支持恢复。");
            var sha = assetID.Substring(prefix.Length);
            if (sha.Length != 64 || sha.Any(c => !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f'))) throw new InvalidDataException("资产编号校验无效。");
            var blob = ((JArray)Document["blobs"]).SingleOrDefault(b => (string)b["sha256"] == sha);
            if (blob == null) throw new InvalidDataException("这个模型未包含在空间备份中。");
            var rel = (string)blob["path"];
            if (!files.Contains(rel)) throw new InvalidDataException("空间模型文件缺失。");
            return Resolve(Root, rel);
        }

        public JObject State(string worldID)
        {
            var record = ((JArray)Document["records"]).SingleOrDefault(r => (string)r["world_id"] == worldID && (string)r["domain"] == "worlds" && (string)r["key"] == "state" && (int?)r["tombstone"] == 0);
            if (record?["value"] is JObject stored)
            {
                var state = (JObject)stored.DeepClone();
                var objects = new JObject();
                foreach (var item in ((JArray)Document["records"]).Where(r => (string)r["world_id"] == worldID && (string)r["domain"] == "objects" && (int?)r["tombstone"] == 0))
                {
                    if (!(item["value"] is JObject value)) throw new InvalidDataException("空间物件记录无效。");
                    objects[(string)item["key"]] = value.DeepClone();
                }
                state["objectStates"] = objects;
                return state;
            }
            throw new InvalidDataException("备份中没有这个空间的有效状态。");
        }

        static string Resolve(string root, string relative)
        {
            if (string.IsNullOrEmpty(relative) || relative.Contains("\\") || relative.Contains(":") || relative.Split('/').Any(p => p == "" || p == "." || p == ".."))
                throw new InvalidDataException("空间备份路径无效。");
            var path = Path.GetFullPath(Path.Combine(root, relative));
            if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal)) throw new InvalidDataException("空间备份路径越界。");
            RejectLinks(path); return path;
        }
        static void RejectLinks(string path)
        {
            for (var current = path; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("空间备份不能包含符号链接。");
        }
        static IEnumerable<string> Enumerate(string root)
        {
            foreach (var child in Directory.EnumerateFileSystemEntries(root))
            { RejectLinks(child); if (Directory.Exists(child)) { foreach (var file in Enumerate(child)) yield return file; } else yield return child; }
        }
        static string Hash(string path)
        { using (var hash = SHA256.Create()) using (var stream = File.OpenRead(path)) return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant(); }
    }
}
