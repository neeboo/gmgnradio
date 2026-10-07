using System;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Threading;
using GaussianSplatting.Runtime;
using GMGN.UnityPlayer.World;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class MarbleRuntimeChecks
    {
        public static void Check()
        {
            LogPathPrefixes(Application.temporaryCachePath);
            // macOS temporaryCachePath may be under the /var -> /private/var
            // symlink. Use the existing project tree, whose package ancestors
            // satisfy the same no-symlink policy as production packages.
            var temporary = Path.GetFullPath(Path.Combine(Application.dataPath, "../Library/gmgn-marble-checks-" + Guid.NewGuid().ToString("N")));
            Directory.CreateDirectory(temporary);
            LogPathPrefixes(temporary);
            try {
                for (byte degree = 0; degree <= 3; degree++) {
                    var path = Path.Combine(temporary, "scene.spz"); WriteFixture(path, degree);
                    var decoded = RuntimeMarbleSplatLoader.Decode(path, CancellationToken.None);
                    Require(decoded.Count == 4 && decoded.SHDegree == degree && decoded.Positions.Length == 48 && decoded.Other.Length == 64, "all points and ellipsoid attributes retained");
                    Require(BitConverter.ToSingle(decoded.Positions, 0) == 0.25f && BitConverter.ToSingle(decoded.Positions, 4) == -0.5f, "signed fixed-point positions preserved");
                    Require(decoded.SH.Length == 4 * 96 && decoded.Colors.Length == 2048 * 16 * 8, "upstream Float16 SH and Morton color layouts");
                    Require(degree != 0 || Array.TrueForAll(decoded.SH, value => value == 0), "SH0 has valid zero higher coefficients");
                    var runtime = new RuntimeMarbleSplatLoader.RuntimeAsset(decoded);
                    Require(runtime.Asset.splatCount == 4 && runtime.Asset.posData.bytes[2] == decoded.Positions[2] &&
                        runtime.Asset.otherData.dataSize == decoded.Other.Length && runtime.Asset.shFormat == GaussianSplatAsset.SHFormat.Float16,
                        "native binary TextAsset feeds real GaussianSplatAsset");
                    foreach (var file in new[] { runtime.Asset.posData, runtime.Asset.otherData, runtime.Asset.colorData, runtime.Asset.shData }) UnityEngine.Object.DestroyImmediate(file);
                    UnityEngine.Object.DestroyImmediate(runtime.Asset);
                    CheckPackage(temporary, path);
                }
                var invalid = Path.Combine(temporary, "invalid.spz"); WriteFixture(invalid, 0, 3);
                Reject(() => RuntimeMarbleSplatLoader.Decode(invalid, CancellationToken.None), "SPZ v3 must be rejected explicitly");
                File.WriteAllBytes(invalid, new byte[] { 31, 139, 0 });
                Reject(() => RuntimeMarbleSplatLoader.Decode(invalid, CancellationToken.None), "truncated SPZ must be rejected");
                var cabin = Path.GetFullPath(Path.Combine(Application.dataPath, "../../macos/Resources/Worlds/marble-living-cabin/scene-500k.spz"));
                var actual = RuntimeMarbleSplatLoader.Decode(cabin, CancellationToken.None);
                Require(actual.Count == 500000 && actual.SourceHash == "2f82fe6f4c8437e407170de4f945455058ff464729e09366ca1f4942930efc52" &&
                    (actual.Maximum - actual.Minimum).sqrMagnitude > 1, "real 500k cabin decoded without dropping points or zeroing positions");
                Debug.Log("PASS: Marble runtime SPZ SH0-3, binary GPU asset, generic formal identity/resources, invalid format rejection, real 500k source");
            } finally { Directory.Delete(temporary, true); }
        }
        static void LogPathPrefixes(string path)
        {
            Debug.Log("[MarbleFixturePath] root=" + path);
            var current = Path.GetFullPath(path);
            while (!string.IsNullOrEmpty(current)) {
                if (File.Exists(current) || Directory.Exists(current))
                    Debug.Log("[MarbleFixturePath] prefix=" + current + " attributes=" + File.GetAttributes(current));
                current = Path.GetDirectoryName(current);
            }
        }
        static void CheckPackage(string root, string splat)
        {
            // A small synthetic collider is a registered byte resource here;
            // Swift's separate production collision test decodes the real GLB.
            var collider = Path.Combine(root, "collider.glb"); File.WriteAllBytes(collider, new byte[] { 103, 108, 84, 70 });
            var document = new JObject { ["schemaVersion"] = 1, ["worldID"] = "new-marble-fixture",
                ["splatPath"] = "scene.spz", ["colliderPath"] = "collider.glb", ["colliderAxisConversion"] = "identity",
                ["origin"] = new JArray(0, 1, 2), ["uniformScale"] = 2,
                ["minimum"] = new JArray(-1, -2, -3), ["maximum"] = new JArray(1, 2, 3) };
            var metadata = Path.Combine(root, "marble-runtime.json"); File.WriteAllText(metadata, document.ToString());
            var manifest = new JObject { ["schemaVersion"] = 1, ["worldID"] = "new-marble-fixture", ["resources"] = new JArray(
                Resource("marble.runtime", "marble-runtime.json", "environment.marble", metadata),
                Resource("marble.splat", "scene.spz", "environment.spz", splat), Resource("marble.collider", "collider.glb", "environment.collider", collider)) };
            var path = Path.Combine(root, "world.json"); File.WriteAllText(path, manifest.ToString());
            var package = FormalWorldPackage.Open(root, "new-marble-fixture", Hash(path));
            Require(JToken.DeepEquals(package.ReadMarbleRuntime(), document), "generic world reads its own resource-bound Marble metadata");
            Require(package.ResolveResourcePath("scene.spz", "environment.spz") == splat, "renderer reads the same registered SPZ file");
            Reject(() => package.ResolveResourcePath("scene.spz", "scene.spz"), "wrong resource kind cannot replace formal environment");
            File.WriteAllText(metadata, "{}");
            Reject(() => FormalWorldPackage.Open(root, "new-marble-fixture", Hash(path)), "changed metadata cannot pass package hashes");
        }
        static JObject Resource(string id, string path, string kind, string file)
            => new JObject { ["id"] = id, ["path"] = path, ["kind"] = kind, ["sha256"] = Hash(file) };
        static string Hash(string path) { using var sha = SHA256.Create(); using var stream = File.OpenRead(path); return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant(); }
        static void WriteFixture(string path, byte degree, uint version = 2)
        {
            using var file = File.Create(path); using var gzip = new GZipStream(file, CompressionMode.Compress); using var writer = new BinaryWriter(gzip);
            writer.Write(0x5053474eU); writer.Write(version); writer.Write(4U); writer.Write(degree); writer.Write((byte)2); writer.Write((byte)0); writer.Write((byte)0);
            for (int i = 0; i < 4; i++) foreach (var value in new[] { 1 + i, -2 + i, 3 + i }) { writer.Write((byte)value); writer.Write((byte)(value >> 8)); writer.Write((byte)(value >> 16)); }
            for (int i = 0; i < 4; i++) writer.Write((byte)200);
            for (int i = 0; i < 12; i++) writer.Write((byte)128); // color
            for (int i = 0; i < 12; i++) writer.Write((byte)160); // unit Gaussian scales
            for (int i = 0; i < 12; i++) writer.Write((byte)128); // near identity rotation
            int coefficients = degree == 0 ? 0 : degree == 1 ? 3 : degree == 2 ? 8 : 15;
            for (int i = 0; i < 4 * coefficients * 3; i++) writer.Write((byte)160);
        }
        static void Require(bool value, string detail) { if (!value) throw new InvalidOperationException("Marble runtime check failed: " + detail); }
        static void Reject(Action action, string detail) { try { action(); } catch (Exception exception) when (exception is IOException || exception is InvalidDataException || exception is InvalidOperationException) { return; } throw new InvalidOperationException("Marble runtime check accepted invalid data: " + detail); }
    }
}
