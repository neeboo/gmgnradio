using System;
using System.IO;
using System.Threading.Tasks;
using UnityEngine;
#if GMGN_UMT
using UMT;
#endif

namespace GMGN.UnityPlayer.Characters
{
    public sealed class PmxCharacterRuntime : MonoBehaviour
    {
        public event Action<string> Notice;
        public event Action<string> MotionCompleted;
        public string CharacterId { get; private set; }
        public string MotionId { get; private set; }
        public bool PhysicsSupported => false;
        public bool IsLoaded { get; private set; }
        bool loading;
        int generation;
#if GMGN_UMT
        PMXImportResult imported;
        GameObject container;
        VMDModelClipData motion;
        Transform[] targets;
        SkinnedMeshRenderer[] morphTargets;
        int[] morphIndices;
        Vector3[] bindPositions;
        Quaternion[] bindRotations;
        float elapsed, motionDuration, playbackRate = 1;
        bool looping, completed;
        bool poseDiagnosticPending;
#endif

        public async Task LoadAsync(string characterId, string modelPath, float heightMeters = 1.65f)
        {
            if (loading) throw new InvalidOperationException("角色正在载入，请等待完成。");
            if (!File.Exists(modelPath) || !string.Equals(Path.GetExtension(modelPath), ".pmx", StringComparison.OrdinalIgnoreCase))
                throw new FileNotFoundException("请选择有效的 PMX 角色文件。", modelPath);
            if (!float.IsFinite(heightMeters) || heightMeters <= 0) throw new ArgumentOutOfRangeException(nameof(heightMeters));
#if GMGN_UMT
            // Register the retained official URP shaders before UMT's runtime
            // material builder resolves them with Shader.Find.
            Resources.Load<Material>("WorldShaders/CharacterUrpUnlit-0");
            Resources.Load<Material>("WorldShaders/CharacterUrpUnlit-1");
            loading = true;
            var request = ++generation;
            PMXImportResult next = null;
            PMXModel model = null;
            var staging = new GameObject("PMX Import");
            staging.SetActive(false);
            staging.transform.SetParent(transform, false);
            try
            {
                Notice?.Invoke("正在载入角色…");
                var budget = new UMTFrameBudget(4);
                using (var stream = File.OpenRead(modelPath)) model = await PMXReader.ReadAsync(budget, stream, false);
                if (request != generation) { Destroy(staging); Destroy(model); return; }
                var resourceRoot = Path.GetFullPath(Path.GetDirectoryName(modelPath)) + Path.DirectorySeparatorChar;
                foreach (var texture in model.texturePaths) {
                    var relative = texture.ToString().Replace('\\', Path.DirectorySeparatorChar);
                    if (string.IsNullOrEmpty(relative)) continue;
                    if (!Path.GetFullPath(Path.Combine(resourceRoot, relative)).StartsWith(resourceRoot, StringComparison.Ordinal))
                        throw new InvalidDataException("角色贴图路径超出了角色资源目录。");
                }
                next = await BuildWithoutBulletAsync(budget, model, new PMXImportOptions {
                    sourcePath = modelPath, textureBaseDirectory = Path.GetDirectoryName(modelPath),
                    parent = staging.transform, applyRenames = false, createAvatar = false, strictVersion = false
                });
                if (request != generation) { DisposeImport(next, staging); return; }
                var bounds = BoundsOf(next.root);
                if (bounds.size.y <= .001f) throw new InvalidDataException("角色没有有效的可见网格。");
                var scale = heightMeters / bounds.size.y;
                next.root.transform.localScale *= scale;
                next.root.transform.localPosition = new Vector3(-bounds.center.x * scale, -bounds.min.y * scale, -bounds.center.z * scale);
                DisposeImport(imported, container);
                imported = next; container = staging; motion = null;
                bindPositions = new Vector3[next.bones.Length]; bindRotations = new Quaternion[next.bones.Length];
                for (var i = 0; i < next.bones.Length; i++) { bindPositions[i] = next.bones[i].localPosition; bindRotations[i] = next.bones[i].localRotation; }
                CharacterId = characterId; MotionId = null; IsLoaded = true;
                staging.SetActive(true);
                LogSkinningBounds("bind");
                Notice?.Invoke("角色已载入；MMD 物理尚未接入。");
            }
            catch
            {
                if (next != null) DisposeImport(next, staging);
                else { Destroy(staging); if (model != null) Destroy(model); }
                throw;
            }
            finally { loading = false; }
#else
            await Task.CompletedTask;
            throw new NotSupportedException("PMX 运行时导入组件尚未安装。");
#endif
        }

        public async Task PlayMotionAsync(string motionId, string vmdPath, bool loop, float rate = 1)
        {
            if (loading) throw new InvalidOperationException("角色正在载入，请等待完成。");
            if (!IsLoaded) throw new InvalidOperationException("请先载入角色。");
            if (!File.Exists(vmdPath) || !string.Equals(Path.GetExtension(vmdPath), ".vmd", StringComparison.OrdinalIgnoreCase))
                throw new FileNotFoundException("请选择有效的 VMD 动作文件。", vmdPath);
            if (!float.IsFinite(rate) || rate <= 0) throw new ArgumentOutOfRangeException(nameof(rate));
#if GMGN_UMT
            var request = ++generation;
            var model = imported.model;
            var budget = new UMTFrameBudget(4);
            var animation = await VMDReader.ReadAsync(budget, File.ReadAllBytesAsync(vmdPath));
            try
            {
                if (motionId.StartsWith("gmgn.motion.", StringComparison.Ordinal))
                    GeneratedHumanoidRetarget.Apply(animation, model);
                var converted = await VMDAnimationClipConverter.ConvertAsync(budget, animation, model, null,
                    new VMDAnimationClipOptions { bakeIKToFK = true, bakePhysicsToFK = false });
                if (request != generation || imported?.model != model) return;
                var nextTargets = new Transform[converted.bones.paths.Length];
                var bound = 0;
                float end = 0;
                for (var i = 0; i < nextTargets.Length; i++) {
                    var path = converted.bones.paths[i];
                    if (!string.IsNullOrEmpty(path)) nextTargets[i] = imported.root.transform.Find(path);
                    if (nextTargets[i] != null) bound++;
                }
                foreach (var curve in converted.bones.curves) if (curve != null && curve.length > 0)
                    end = Mathf.Max(end, curve[curve.length - 1].time);
                if (bound == 0 || end <= 0) throw new InvalidDataException("这个动作没有匹配到角色骨骼。");
                var renderers = new SkinnedMeshRenderer[converted.morphs.paths.Length];
                var indices = new int[renderers.Length];
                for (var i = 0; i < renderers.Length; i++) {
                    var target = imported.root.transform.Find(converted.morphs.paths[i]);
                    renderers[i] = target != null ? target.GetComponent<SkinnedMeshRenderer>() : null;
                    indices[i] = renderers[i] != null ? renderers[i].sharedMesh.GetBlendShapeIndex(converted.morphs.names[i]) : -1;
                }
                ResetBones();
                targets = nextTargets; morphTargets = renderers; morphIndices = indices; motion = converted;
                MotionId = motionId; elapsed = 0; motionDuration = end; looping = loop; playbackRate = rate; completed = false;
                poseDiagnosticPending = true;
                Notice?.Invoke("动作已载入。");
            }
            finally { Destroy(animation); }
#else
            await Task.CompletedTask;
            throw new NotSupportedException("VMD 动作运行时尚未安装。");
#endif
        }

        public void StopMotion()
        {
            ++generation; MotionId = null;
#if GMGN_UMT
            motion = null;
            ResetBones();
#endif
        }

#if GMGN_UMT
        static async Task<PMXImportResult> BuildWithoutBulletAsync(UMTFrameBudget budget, PMXModel model, PMXImportOptions options)
        {
            var result = new PMXImportResult { model = model, root = new GameObject(options.sourceName ?? "PMX Character") };
            result.root.transform.SetParent(options.parent, false);
            try {
                result.texturesByIndex = PMXTextureLoader.Load(model, options, result);
                await budget.YieldIfNeeded();
                result.materials.AddRange(PMXMaterialBuilder.Build(model, options, result.root.name, result.texturesByIndex));
                PrepareMaterials(model, result);
                await budget.YieldIfNeeded();
                result.bones = PMXBoneBuilder.BuildBones(model, result.root.transform);
                var poses = PMXBoneBuilder.BuildBindposes(result.root.transform, result.bones);
                await budget.YieldIfNeeded();
                var groups = PMXMorphBuilder.BuildMorphLinkedMaterialGroups(model);
                result.meshes.AddRange(PMXMeshBuilder.Build(model, result.root.name, groups, poses));
                await budget.YieldIfNeeded();
                PMXRendererBuilder.Build(model, result.root, result.meshes, result.materials, result.bones);
                foreach (var renderer in result.root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
                    renderer.quality = SkinQuality.Bone4;
                await budget.YieldIfNeeded();
                return result;
            }
            catch { DisposeImport(result, result.root); throw; }
        }
        static void PrepareMaterials(PMXModel model, PMXImportResult result)
        {
            // Match the existing Swift PMX compatibility path: original texture
            // times authored tint, double-sided, lit cloth without grey emission.
            // UMT's URP fallback sets _Color, whereas URP reads _BaseColor.
            var shader = Resources.Load<Shader>("Characters/PmxStageLit");
            if (shader == null) throw new InvalidDataException("角色材质资源没有打包，请重新构建应用。");
            for (var i = 0; i < result.materials.Count; i++) {
                var material = result.materials[i];
                var authored = model.materials[i];
                var texture = material.GetTexture("_BaseMap");
                var transparent = material.renderQueue >= 3000;
                material.shader = shader;
                material.SetTexture("_BaseMap", texture ?? Texture2D.whiteTexture);
                material.SetColor("_BaseColor", authored.diffuse);
                material.SetFloat("_Cull", 0);
                material.SetFloat("_SrcBlend", transparent ? 5 : 1);
                material.SetFloat("_DstBlend", transparent ? 10 : 0);
                material.SetFloat("_ZWrite", 1);
                material.renderQueue = transparent ? 3000 : 2000;
            }
        }
        void ResetBones()
        {
            if (imported == null) return;
            for (var i = 0; i < imported.bones.Length; i++) {
                imported.bones[i].localPosition = bindPositions[i]; imported.bones[i].localRotation = bindRotations[i];
            }
            foreach (var renderer in imported.root.GetComponentsInChildren<SkinnedMeshRenderer>())
                for (var i = 0; i < renderer.sharedMesh.blendShapeCount; i++) renderer.SetBlendShapeWeight(i, 0);
        }
        void Update()
        {
            if (motion == null || completed) return;
            elapsed += Time.deltaTime * playbackRate;
            var t = looping ? elapsed % motionDuration : Mathf.Min(elapsed, motionDuration);
            for (var i = 0; i < targets.Length; i++) {
                var target = targets[i]; if (target == null) continue;
                var c = i * 7; var p = target.localPosition; var q = target.localRotation;
                target.localPosition = new Vector3(Evaluate(c, t, p.x), Evaluate(c + 1, t, p.y), Evaluate(c + 2, t, p.z));
                target.localRotation = new Quaternion(Evaluate(c + 3, t, q.x), Evaluate(c + 4, t, q.y), Evaluate(c + 5, t, q.z), Evaluate(c + 6, t, q.w)).normalized;
            }
            for (var i = 0; i < morphTargets.Length; i++) if (morphTargets[i] != null && morphIndices[i] >= 0 && motion.morphs.curves[i] != null)
                morphTargets[i].SetBlendShapeWeight(morphIndices[i], motion.morphs.curves[i].Evaluate(t));
            if (poseDiagnosticPending) { poseDiagnosticPending = false; LogSkinningBounds("motion"); }
            if (!looping && elapsed >= motionDuration) { completed = true; MotionCompleted?.Invoke(MotionId); }
        }
        float Evaluate(int index, float t, float fallback) => motion.bones.curves[index]?.Evaluate(t) ?? fallback;
        void LogSkinningBounds(string stage)
        {
            if (imported == null) return;
            foreach (var renderer in imported.root.GetComponentsInChildren<SkinnedMeshRenderer>(true)) {
                var baked = new Mesh();
                try {
                    renderer.BakeMesh(baked, false);
                    var vertices = baked.vertices;
                    var source = renderer.sharedMesh.vertices;
                    float maxDelta = 0;
                    for (var i = 0; i < vertices.Length; i++) maxDelta = Mathf.Max(maxDelta, Vector3.Distance(vertices[i], source[i]));
                    Debug.Log($"[CharacterSkin] stage={stage} mesh={renderer.name} vertices={vertices.Length} source={renderer.sharedMesh.bounds} baked={baked.bounds} maxDelta={maxDelta:F5}");
                }
                finally { Destroy(baked); }
            }
        }
        static Bounds BoundsOf(GameObject root)
        {
            var renderers = root.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            if (renderers.Length == 0) return default;
            var bounds = new Bounds();
            var initialized = false;
            foreach (var renderer in renderers) {
                var local = renderer.localBounds;
                var matrix = root.transform.worldToLocalMatrix * renderer.transform.localToWorldMatrix;
                for (var i = 0; i < 8; i++) {
                    var corner = local.center + Vector3.Scale(local.extents,
                        new Vector3((i & 1) == 0 ? -1 : 1, (i & 2) == 0 ? -1 : 1, (i & 4) == 0 ? -1 : 1));
                    var point = matrix.MultiplyPoint3x4(corner);
                    if (!initialized) { bounds = new Bounds(point, Vector3.zero); initialized = true; }
                    else bounds.Encapsulate(point);
                }
            }
            return bounds;
        }
        static void DisposeImport(PMXImportResult value, GameObject owner)
        {
            if (owner != null) Destroy(owner);
            if (value == null) return;
            foreach (var mesh in value.meshes) if (mesh.mesh != null) Destroy(mesh.mesh);
            foreach (var material in value.materials) if (material != null) Destroy(material);
            foreach (var texture in value.textures) if (texture != null) Destroy(texture);
            if (value.model != null) Destroy(value.model);
        }
#endif
        void OnDestroy()
        {
            ++generation;
#if GMGN_UMT
            DisposeImport(imported, container);
#endif
        }
    }
}
