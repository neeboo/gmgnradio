using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using GMGN.UnityPlayer.World;

class GeneratedAssetRegression
{
    static void Check(bool value, string name) { if (!value) throw new Exception(name); }
    static async Task Reject(Func<Task> body, string name) {
        try { await body(); } catch (InvalidDataException) { return; }
        throw new Exception("Accepted invalid input: " + name);
    }
    static async Task Main()
    {
        Check(WorldAssetFailureDiagnostics.Code(new InvalidDataException("这个模型尚未进入正式资产清单。")) == "generated_catalog_missing", "catalog diagnostic");
        Check(WorldAssetFailureDiagnostics.Code(new InvalidDataException("这个 GLB 模型没有成功加载。")) == "glb_import_failed", "import diagnostic");
        Check(WorldAssetFailureDiagnostics.Code(new InvalidDataException("模型包围盒为空或退化。")) == "model_bounds_degenerate", "bounds diagnostic");
        Check(WorldAssetFailureDiagnostics.Code(new InvalidDataException("private /Users/example/secret")) == "invalid_asset", "unknown message remains private");
        Check(WorldAssetFailureDiagnostics.Code(new IOException("private /Users/example/secret")) == "IOException", "IO path remains private");
        // macOS /var and /tmp are system symlinks; use the workspace's explicit
        // isolated fixture root so the production no-symlink rule stays intact.
        var root = Path.Combine(Environment.CurrentDirectory, "tmp", "gmgn-generated-resolver-" + Guid.NewGuid().ToString("N"));
        var taskRoot = Path.Combine(root, "gmgn radio", "TaskService"); Directory.CreateDirectory(taskRoot);
        var taskID = Guid.NewGuid(); var wishID = Guid.NewGuid();
        var bytes = new byte[] { 0x67, 0x6c, 0x54, 0x46, 2, 0, 0, 0 };
        var hash = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        var path = Path.Combine(taskRoot, taskID.ToString("D") + ".glb"); File.WriteAllBytes(path, bytes);
        var entry = new JObject { ["taskID"] = taskID.ToString(), ["sourceWishID"] = wishID.ToString(), ["objectID"] = "prop",
            ["assetID"] = "sha256:" + hash, ["sha256"] = hash, ["bytes"] = bytes.Length, ["localModelPath"] = path };
        var catalog = new JObject { ["worldID"] = "isolated-world", ["revision"] = 1, ["entries"] = new JArray(entry) };
        var prop = new JObject { ["objectID"] = "prop", ["sourceWishID"] = wishID.ToString(), ["assetID"] = "sha256:" + hash };
        var resolver = new GeneratedAssetResolver(root, "isolated-world"); resolver.SetCatalog(catalog);
        var gate = new GeneratedAssetProjectionGate();
        var initial = (JObject)catalog.DeepClone(); initial["generation"] = 1; initial["entries"] = new JArray();
        Check(gate.Accept(initial), "initial empty catalog pulse");
        var rebuilt = (JObject)catalog.DeepClone(); rebuilt["generation"] = 1;
        Check(gate.Accept(rebuilt), "same generation recreated catalog must publish newly owned model");
        Check(!gate.Accept((JObject)rebuilt.DeepClone()), "unchanged model catalog must not reload every poll");
        var switched = (JObject)rebuilt.DeepClone(); switched["worldID"] = "another-world";
        Check(gate.Accept(switched), "same generation different world must publish");
        resolver.SetCatalog(rebuilt);
        Check(await resolver.Resolve(prop, CancellationToken.None) == path, "same generation owned model reaches actual resolver");
        Console.WriteLine("PASS: recreated/same-generation catalogs publish owned models; world changes publish; unchanged polls suppressed");
        var formalRoot = Path.Combine(root, "formal"); Directory.CreateDirectory(formalRoot);
        File.WriteAllBytes(Path.Combine(formalRoot, "scene.glb"), bytes);
        var manifest = new JObject { ["schemaVersion"] = 1, ["worldID"] = "formal-world", ["resources"] = new JArray(
            new JObject { ["id"] = "scene", ["path"] = "scene.glb", ["sha256"] = hash, ["kind"] = "scene.glb" }) };
        var manifestPath = Path.Combine(formalRoot, "world.json"); File.WriteAllText(manifestPath, manifest.ToString());
        var manifestHash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(manifestPath))).ToLowerInvariant();
        var formal = FormalWorldPackage.Open(formalRoot, "formal-world", manifestHash);
        Check(formal.ResolveAssetID("sha256:" + hash) == Path.Combine(formalRoot, "scene.glb"), "formal declared asset");
        await Reject(() => { FormalWorldPackage.Open(formalRoot, "another", manifestHash); return Task.CompletedTask; }, "formal world identity");
        await Reject(() => { FormalWorldPackage.Open(formalRoot, "formal-world", new string('0',64)); return Task.CompletedTask; }, "formal manifest receipt hash");
        File.WriteAllBytes(Path.Combine(formalRoot, "scene.glb"), new byte[] { 1 });
        await Reject(() => { FormalWorldPackage.Open(formalRoot, "formal-world", manifestHash); return Task.CompletedTask; }, "formal corrupt resource");
        File.Delete(Path.Combine(formalRoot, "scene.glb")); File.CreateSymbolicLink(Path.Combine(formalRoot, "scene.glb"), path);
        await Reject(() => { FormalWorldPackage.Open(formalRoot, "formal-world", manifestHash); return Task.CompletedTask; }, "formal linked resource");
        Check(await resolver.Resolve(prop, CancellationToken.None) == path, "valid native catalog");
        var historicalPath = Path.Combine(taskRoot, taskID.ToString("D").ToUpperInvariant() + ".glb");
        File.WriteAllBytes(historicalPath, bytes);
        var historicalCatalog = (JObject)catalog.DeepClone(); historicalCatalog["entries"][0]["localModelPath"] = historicalPath;
        var historicalResolver = new GeneratedAssetResolver(root, "isolated-world"); historicalResolver.SetCatalog(historicalCatalog);
        Check(await historicalResolver.Resolve(prop, CancellationToken.None) == historicalPath, "historical uppercase formal task output");
        var foreignUUID = (JObject)catalog.DeepClone(); foreignUUID["entries"][0]["localModelPath"] = Path.Combine(taskRoot, Guid.NewGuid().ToString("D") + ".glb");
        await Reject(() => { resolver.SetCatalog(foreignUUID); return Task.CompletedTask; }, "foreign UUID output");
        var restart = new GeneratedAssetResolver(root, "isolated-world"); restart.SetCatalog(catalog);
        Check(await restart.Resolve(prop, CancellationToken.None) == path, "restart restores real file");
        var wrongWorld = (JObject)catalog.DeepClone(); wrongWorld["worldID"] = "another";
        await Reject(() => { resolver.SetCatalog(wrongWorld); return Task.CompletedTask; }, "wrong world");
        var outside = (JObject)catalog.DeepClone(); outside["entries"][0]["localModelPath"] = Path.Combine(root, "outside.glb");
        await Reject(() => { resolver.SetCatalog(outside); return Task.CompletedTask; }, "outside authority task path");
        var wrongIdentity = (JObject)prop.DeepClone(); wrongIdentity["sourceWishID"] = Guid.NewGuid().ToString();
        await Reject(async () => await resolver.Resolve(wrongIdentity, CancellationToken.None), "wish identity");
        File.WriteAllBytes(path, new byte[] { 0x67, 0x6c, 0x54, 0x46, 2, 0, 0, 1 });
        await Reject(async () => await resolver.Resolve(prop, CancellationToken.None), "tampered same size");
        File.Delete(path); var target = Path.Combine(root, "outside.glb"); File.WriteAllBytes(target, bytes); File.CreateSymbolicLink(path, target);
        await Reject(async () => await resolver.Resolve(prop, CancellationToken.None), "symlink");
        Console.WriteLine("PASS: actual resolver valid/recreated instance/wrong world/outside path/wish mismatch/hash corruption/symlink");
        // Only newly created isolated fixture root is removed.
        Directory.Delete(root, true);
    }
}
