using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer.World
{
    public interface IWorldAssetLoader
    {
        // Returns the actual asset, normalized to the authoritative prop size and
        // orientation, with its pivot on the support surface. Never a placeholder.
        Task<GameObject> LoadPreparedAsset(string packageLocalPath, JObject prop, CancellationToken cancellation);
    }

    public sealed class RecoveryItem
    {
        public string ObjectID;
        public string Status;
        public string Message;
        public GameObject Instance;
    }

    public static class WorldCoordinates
    {
        // WorldRuntime/SceneKit is right-handed Y-up; Unity is left-handed Y-up.
        public static Vector3 Position(JToken token) => new Vector3(Number(token, "x"), Number(token, "y"), -Number(token, "z"));
        public static Quaternion Rotation(JToken token)
        {
            var q = new Quaternion(-Number(token, "x"), -Number(token, "y"), Number(token, "z"), Number(token, "w"));
            if (Quaternion.Dot(q, q) < 0.000001f) throw new InvalidDataException("物件旋转数据无效。");
            return q.normalized;
        }
        public static Vector3 Scale(JToken token) => new Vector3(Number(token, "x"), Number(token, "y"), Number(token, "z"));
        static float Number(JToken token, string key)
        {
            if (token?[key] == null || !(token[key].Type == JTokenType.Float || token[key].Type == JTokenType.Integer)) throw new InvalidDataException("物件位置数据不完整。");
            var value = (float)token[key];
            if (float.IsInfinity(value) || float.IsNaN(value)) throw new InvalidDataException("物件位置数据无效。");
            return value;
        }
    }

    /// Read-only visual projection. Does not write files, taskd records or new IDs.
    public sealed class WorldSceneRecovery
    {
        readonly IWorldAssetLoader loader;
        // Asset IDs are opaque. The host resolves an ID to its backed-up reference;
        // this adapter never guesses model paths from object names or array order.
        readonly Func<string, string> assetReference;
        public WorldSceneRecovery(IWorldAssetLoader loader) { this.loader = loader; }
        public WorldSceneRecovery(IWorldAssetLoader loader, Func<string, string> assetReference)
        { this.loader = loader; this.assetReference = assetReference; }

        public async Task<IReadOnlyList<RecoveryItem>> Restore(PortableWorldPackage package, string worldID, Transform parent, CancellationToken cancellation)
        {
            var state = package.State(worldID);
            var objects = state["objectStates"] as JObject ?? throw new InvalidDataException("空间缺少物件状态。");
            var heldID = (string)state["heldProp"]?["objectID"];
            var result = new List<RecoveryItem>();
            foreach (var entry in objects.Properties())
            {
                cancellation.ThrowIfCancellationRequested();
                var item = new RecoveryItem { ObjectID = entry.Name };
                result.Add(item);
                if ((bool?)entry.Value["isEnabled"] != true) { item.Status = "disabled"; item.Message = "物件仍在库存中。"; continue; }
                if (entry.Name == heldID) { item.Status = "unsupported"; item.Message = "已保留手持状态，人物挂点尚未迁移。"; continue; }
                GameObject loaded = null;
                try
                {
                    var raw = (string)entry.Value["metadata"]?["gmgn.generated-prop.v1"];
                    if (raw == null) { item.Status = "unsupported"; item.Message = "空间包自带设备尚未接入资产恢复。"; continue; }
                    var prop = JObject.Parse(raw);
                    if ((string)prop["objectID"] != entry.Name) throw new InvalidDataException("物件资产身份不一致。");
                    if (loader == null) { item.Status = "unsupported"; item.Message = "物件数据已保留，模型加载器尚未接入。"; continue; }
                    var id = (string)prop["assetID"];
                    var path = assetReference == null ? package.ResolveAssetID(id) : package.ResolveReference(assetReference(id));
                    var transform = entry.Value["transform"];
                    var position = WorldCoordinates.Position(transform?["position"]);
                    var rotation = WorldCoordinates.Rotation(transform?["rotation"]);
                    loaded = await loader.LoadPreparedAsset(path, prop, cancellation);
                    cancellation.ThrowIfCancellationRequested();
                    if (loaded == null) throw new InvalidDataException("模型没有成功加载。");
                    loaded.transform.SetParent(parent, false);
                    loaded.transform.localPosition = position;
                    loaded.transform.localRotation = rotation;
                    // Generated props are already normalized to effectiveSize by
                    // the loader. Legacy transform.scale encodes that same size.
                    loaded.name = entry.Name;
                    item.Instance = loaded; item.Status = "restored"; item.Message = "物件模型和位置已恢复。";
                }
                catch (OperationCanceledException) { if (loaded != null) UnityEngine.Object.Destroy(loaded); throw; }
                catch (Exception error)
                {
                    if (loaded != null) UnityEngine.Object.Destroy(loaded);
                    item.Status = "failed";
                    item.Message = error is InvalidDataException ? error.Message : "这个物件恢复失败，原数据仍保留在备份中。";
                }
            }
            return result;
        }
    }
}
