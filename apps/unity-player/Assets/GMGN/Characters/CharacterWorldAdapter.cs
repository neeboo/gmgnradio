using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using GMGN.UnityPlayer.World;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer.Characters
{
    public sealed class CharacterWorldAdapter : MonoBehaviour
    {
        public PmxCharacterRuntime Runtime { get; private set; }
        public string Notice { get; private set; }
        public event Action<string> NoticeChanged;

        public static async Task<CharacterWorldAdapter> RestoreAsync(JObject state, Transform parent, CancellationToken cancellation)
        {
            var manifestPath = Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
            if (string.IsNullOrWhiteSpace(manifestPath)) return null;
            cancellation.ThrowIfCancellationRequested();
            var manifest = JObject.Parse(File.ReadAllText(manifestPath));
            if ((string)manifest["engine"] != "pmx") throw new NotSupportedException("当前角色格式尚未迁移到 Unity。");
            var id = Required(manifest, "id");
            var model = EntryPath(manifestPath, Required(manifest, "entry"));
            var root = new GameObject("World Character");
            root.transform.SetParent(parent, false);
            var adapter = root.AddComponent<CharacterWorldAdapter>();
            adapter.Runtime = root.AddComponent<PmxCharacterRuntime>();
            adapter.Runtime.Notice += adapter.SetNotice;
            try {
                adapter.ApplyState(state);
                await adapter.Runtime.LoadAsync(id, model);
                cancellation.ThrowIfCancellationRequested();
                var motionPath = Environment.GetEnvironmentVariable("GMGN_UNITY_MOTION_MANIFEST");
                if (!string.IsNullOrWhiteSpace(motionPath)) {
                    var motion = JObject.Parse(File.ReadAllText(motionPath));
                    if ((string)motion["format"] != "vmd") throw new NotSupportedException("当前动作格式尚未迁移到 Unity。");
                    var entry = EntryPath(motionPath, Required(motion, "entry"));
                    var declaredHash = (string)motion["sha256"];
                    if (!string.IsNullOrEmpty(declaredHash)) {
                        using var sha = SHA256.Create(); using var stream = File.OpenRead(entry);
                        var actual = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                        if (actual != declaredHash) throw new InvalidDataException("动作文件校验失败，原包未修改。");
                    }
                    await adapter.Runtime.PlayMotionAsync(Required(motion, "id"), entry, (bool?)motion["loop"] ?? true, (float?)motion["playbackRate"] ?? 1);
                    cancellation.ThrowIfCancellationRequested();
                }
                return adapter;
            }
            catch { Destroy(root); throw; }
        }

        public void ApplyState(JObject state)
        {
            var pose = state?["agentTransform"];
            if (pose == null) throw new InvalidDataException("空间缺少角色位置。");
            transform.localPosition = WorldCoordinates.Position(pose["position"]);
            transform.localRotation = WorldCoordinates.Rotation(pose["rotation"]);
            var scale = WorldCoordinates.Scale(pose["scale"]);
            if (scale.x <= 0 || scale.y <= 0 || scale.z <= 0) throw new InvalidDataException("角色尺寸数据无效。");
            transform.localScale = scale;
        }

        void SetNotice(string value) { Notice = value; NoticeChanged?.Invoke(value); }
        static string Required(JObject value, string key)
        {
            var text = (string)value[key];
            if (string.IsNullOrWhiteSpace(text)) throw new InvalidDataException("角色或动作包的清单不完整。");
            return text;
        }
        static string EntryPath(string manifest, string entry)
        {
            if (Path.IsPathRooted(entry)) throw new InvalidDataException("角色或动作包入口必须为包内路径。");
            var root = Path.GetFullPath(Path.GetDirectoryName(manifest)) + Path.DirectorySeparatorChar;
            var path = Path.GetFullPath(Path.Combine(root, entry.Replace('\\', Path.DirectorySeparatorChar)));
            if (!path.StartsWith(root, StringComparison.Ordinal) || !File.Exists(path)) throw new InvalidDataException("角色或动作包入口文件缺失或越界。");
            for (var current = path; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("角色或动作包不能包含符号链接。");
            return path;
        }
        void OnDestroy() { if (Runtime != null) Runtime.Notice -= SetNotice; }
    }
}
