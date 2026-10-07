using System;
using System.IO;
using System.Threading.Tasks;
using System.Threading;
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
        public bool IsMotionPlaying =>
#if GMGN_UMT
            MotionId != null && !completed;
#else
            false;
#endif
        public bool PhysicsSupported => false;
        Vector3? interactionContact;
        Vector3 measuredContactHand;
        float measuredContactDistance = float.PositiveInfinity;
        int measuredContactFrame = -1;
        Transform rightPalmAttachment;
        CharacterGripPose heldFingerPose;
        public int HeldFingerContactCount => heldFingerPose?.ContactCount ?? 0;
        public float HeldFingerMaximumContactError => heldFingerPose?.MaximumContactError ?? float.PositiveInfinity;
        public string[] HeldFingerDiagnostics => heldFingerPose?.ContactDiagnostics.ToArray() ?? Array.Empty<string>();
        public void ClearHeldFingerPose() { heldFingerPose?.Clear(); }
        public void ApplyHeldFingerPose(Vector3 centre,Vector3 axis,float radius)
        {
#if GMGN_UMT
            if(imported==null)return;
            if(heldFingerPose==null) {
                heldFingerPose=new CharacterGripPose();
                foreach(var name in new[]{"右人指","右中指","右薬指","右小指"}) {
                    var chain=new Transform[4];var lastIndex=-1;
                    for(var number=0;number<3;number++)for(var index=0;index<imported.model.bones.Length;index++)
                        if(imported.model.bones[index].originalName.ToString()==name+new[]{"１","２","３"}[number]) {
                            chain[number]=imported.bones[index];if(number==2)lastIndex=index;break;
                        }
                    if(lastIndex<0)continue;
                    var end=imported.model.bones[lastIndex];
                    if(end.connectionBoneIndex>=0&&end.connectionBoneIndex<imported.bones.Length)
                        chain[3]=imported.bones[end.connectionBoneIndex];
                    else {
                        var tip=new GameObject("Grip fingertip "+name).transform;tip.SetParent(chain[2],false);
                        tip.localPosition=(Vector3)end.positionOffset;chain[3]=tip;
                    }
                    heldFingerPose.Add(chain);
                }
            }
            heldFingerPose.Set(centre,axis,radius);heldFingerPose.Apply();
#endif
        }
        public void SetInteractionContact(Vector3? target) {
            if (interactionContact != target) { measuredContactFrame = -1; measuredContactDistance = float.PositiveInfinity; }
            interactionContact = target;
        }
        public bool TryReadInteractionContact(out Vector3 hand, out float distance) {
            hand = measuredContactHand; distance = measuredContactDistance;
            return interactionContact.HasValue && measuredContactFrame >= Time.frameCount-1
                && float.IsFinite(distance) && distance <= .1f;
        }
        void ApplyInteractionContact() {
            measuredContactDistance = float.PositiveInfinity; measuredContactFrame = Time.frameCount;
#if GMGN_UMT
            if (!interactionContact.HasValue || imported == null) return;
            Transform upper = null, lower = null, hand = null;
            for (int i=0; i<imported.model.bones.Length; i++) {
                var name = imported.model.bones[i].originalName.ToString();
                if (name == "右腕") upper = imported.bones[i];
                if (name == "右ひじ") lower = imported.bones[i];
                if (name == "右手首") hand = imported.bones[i];
            }
            if (upper == null || lower == null || hand == null) return;
            var target = interactionContact.Value;
            var offset = Vector3.Distance(hand.position,target);
            var a=upper.position; var b=lower.position; var c=hand.position;
            var first=Vector3.Distance(a,b); var second=Vector3.Distance(b,c);
            // Imported PMX arms differ from the VRM authored button pose.
            // Refine only its nearby press pose, bounded by half this arm's
            // actual reach; retain bone lengths and the real 10 cm receipt.
            if (offset <= Mathf.Max(.2f, (first+second)*.5f) && offset > .001f) {
                var direction=target-a; var length=direction.magnitude;
                // Match the VRM refinement: a nearly extended arm aims at its
                // closest reachable point, without stretching either segment.
                // The receipt measures distance to the original device target.
                var reachableLength=Mathf.Min(length,(first+second)*.999f);
                if (first > .001f && second > .001f && length > .001f &&
                    reachableLength > Mathf.Abs(first-second)) {
                    var axis=direction/length; var bend=Vector3.ProjectOnPlane(b-a,axis);
                    if (bend.sqrMagnitude > .000001f) {
                        var reachableTarget=a+axis*reachableLength;
                        var along=(first*first+reachableLength*reachableLength-second*second)/(2*reachableLength);
                        var height=Mathf.Sqrt(Mathf.Max(0,first*first-along*along));
                        var elbow=a+axis*along+bend.normalized*height;
                        upper.rotation=Quaternion.FromToRotation(b-a,elbow-a)*upper.rotation;
                        lower.rotation=Quaternion.FromToRotation(hand.position-lower.position,reachableTarget-lower.position)*lower.rotation;
                    }
                }
            }
            measuredContactHand=hand.position;
            measuredContactDistance=Vector3.Distance(hand.position,target);
#endif
        }
        public bool TryGetAttachmentBone(string slot, out Transform bone)
        {
            bone = null;
#if GMGN_UMT
            if (imported == null) return false;
            var candidates = slot switch {
                "rightHand" => new[] { "右手首", "bone009" },
                "back" => new[] { "上半身2", "bone002", "上半身", "bone001" },
                "waist" => new[] { "腰", "下半身", "bone014", "センター", "bone000" },
                _ => Array.Empty<string>()
            };
            foreach (var name in candidates)
                for (var i = 0; i < imported.model.bones.Length; i++)
                    if (imported.model.bones[i].originalName.ToString() == name) {
                        bone = imported.bones[i];
                        if (slot == "rightHand") {
                            Transform middle = null,indexFinger=null,littleFinger=null;
                            for (var finger = 0; finger < imported.model.bones.Length; finger++)
                                if (imported.model.bones[finger].originalName.ToString() == "右中指１") {
                                    middle = imported.bones[finger];
                                }else if(imported.model.bones[finger].originalName.ToString()=="右人指１")indexFinger=imported.bones[finger];
                                else if(imported.model.bones[finger].originalName.ToString()=="右小指１")littleFinger=imported.bones[finger];
                            if (middle != null) {
                                if (rightPalmAttachment == null || rightPalmAttachment.parent != bone) {
                                    if (rightPalmAttachment != null) Destroy(rightPalmAttachment.gameObject);
                                    rightPalmAttachment = new GameObject("Right palm attachment").transform;
                                    rightPalmAttachment.SetParent(bone,false);
                                    if(indexFinger!=null&&littleFinger!=null)
                                        rightPalmAttachment.localRotation=CharacterGripPose.PalmLocalRotation(bone,indexFinger,middle,littleFinger,transform.up);
                                }
                                // Wrist and proximal middle-finger joint bound
                                // the palm. Place the calibrated handle at its
                                // anatomical centre, retaining authored wrist
                                // rotation and world-metre prop dimensions.
                                rightPalmAttachment.localPosition = bone.InverseTransformPoint((bone.position+middle.position)*.5f);
                                bone = rightPalmAttachment;
                            }
                        }
                        return true;
                    }
#endif
            return false;
        }
        public bool TryGetHeadPosition(out Vector3 position)
        {
            position = default;
#if GMGN_UMT
            if (imported == null) return false;
            for (var i = 0; i < imported.model.bones.Length; i++) {
                var bone = imported.model.bones[i];
                if (bone.originalName.ToString() != "頭" &&
                    !string.Equals(bone.originalNameEN.ToString(), "head", StringComparison.OrdinalIgnoreCase)) continue;
                position = imported.bones[i].position;
                return true;
            }
#endif
            return false;
        }
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
        SkinnedMeshRenderer[] speechTargets = Array.Empty<SkinnedMeshRenderer>();
        int[] speechIndices = Array.Empty<int>();
        bool speechPlaying, speechResetPending;
        float speechWeight;
        int speechDiagnosticFrames;
        bool speechDiagnosticStopPending;
        float speechDiagnosticRawLevel, speechDiagnosticMaxRawLevel, speechDiagnosticMaxAppliedPercent;
        public float SpeechDiagnosticMaxRawLevel => speechDiagnosticMaxRawLevel;
        public float SpeechDiagnosticMaxAppliedPercent => speechDiagnosticMaxAppliedPercent;
#endif

        public async Task LoadAsync(string characterId, string modelPath, float heightMeters = 1.65f)
        {
            heldFingerPose?.Clear();heldFingerPose=null;
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
                // NextFrameAsync needs the game loop. Editor import/preview
                // must finish without waiting for a frame that never arrives.
                var budget = new UMTFrameBudget(Application.isPlaying ? 4 : double.PositiveInfinity);
                using (var stream = File.OpenRead(modelPath)) model = await PMXReader.ReadAsync(budget, stream, false);
                if (request != generation) { Destroy(staging); Destroy(model); return; }
                var umtResources = Resources.Load<UMTResources>("UMTResources");
                if (umtResources == null) throw new InvalidDataException("MMD 名称映射资源缺失。");
                var renameLists = PMXRenameUtilities.LoadRenameListsJson(umtResources.GetPMXRenameListsJson());
                await PMXRenameUtilities.RenameAsync(budget, model, renameLists, umtResources);
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
                CacheSpeechTargets();
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

        public async Task PlayMotionAsync(string motionId, string vmdPath, bool loop, float rate = 1, CancellationToken cancellation = default)
        {
            if (loading) throw new InvalidOperationException("角色正在载入，请等待完成。");
            if (!IsLoaded) throw new InvalidOperationException("请先载入角色。");
            if (!File.Exists(vmdPath) || !string.Equals(Path.GetExtension(vmdPath), ".vmd", StringComparison.OrdinalIgnoreCase))
                throw new FileNotFoundException("请选择有效的 VMD 动作文件。", vmdPath);
            if (!float.IsFinite(rate) || rate <= 0) throw new ArgumentOutOfRangeException(nameof(rate));
#if GMGN_UMT
            var request = ++generation;
            var model = imported.model;
            var budget = new UMTFrameBudget(Application.isPlaying ? 4 : double.PositiveInfinity);
            var animation = await VMDReader.ReadAsync(budget, File.ReadAllBytesAsync(vmdPath));
            try
            {
                if (motionId.StartsWith("gmgn.motion.", StringComparison.Ordinal))
                    GeneratedHumanoidRetarget.Apply(animation, model);
                var converted = await VMDAnimationClipConverter.ConvertAsync(budget, animation, model, null,
                    new VMDAnimationClipOptions { bakeIKToFK = true, bakePhysicsToFK = false });
                cancellation.ThrowIfCancellationRequested();
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
            heldFingerPose?.Restore();
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
        void CacheSpeechTargets()
        {
            var renderers = new System.Collections.Generic.List<SkinnedMeshRenderer>();
            var indices = new System.Collections.Generic.List<int>();
            var names = new System.Collections.Generic.List<string>();
            foreach (var sourceName in new[] { "あ", "aa", "Aa", "mouth_a", "vrc.v.aa" }) {
                foreach (var morph in imported.model.morphs)
                    if (morph.originalName.ToString() == sourceName) names.Add(morph.renamedName.ToString());
            }
            foreach (var skin in imported.root.GetComponentsInChildren<SkinnedMeshRenderer>(true)) {
                foreach (var name in names) {
                    var index = skin.sharedMesh.GetBlendShapeIndex(name);
                    if (index < 0) continue;
                    renderers.Add(skin); indices.Add(index); break;
                }
            }
            speechTargets = renderers.ToArray(); speechIndices = indices.ToArray();
        }
        // Apply after the VMD morph curves so speech is visible while a motion plays.
        // Once speech stops, clear its mouth weight then let authored curves resume.
        void LateUpdate()
        {
            ApplyInteractionContact();
            if (!speechPlaying && !speechResetPending) return;
            for (var i = 0; i < speechTargets.Length; i++)
                if (speechTargets[i] != null) speechTargets[i].SetBlendShapeWeight(speechIndices[i], speechPlaying ? speechWeight : 0);
            LogSpeechDiagnosticAfterMorph();
            speechResetPending = false;
        }
        void LogSpeechDiagnosticAfterMorph()
        {
            var shouldLog = speechDiagnosticStopPending || (speechPlaying && speechDiagnosticFrames > 0);
            var actual = "";
            for (var i = 0; i < speechTargets.Length; ++i) {
                var skin = speechTargets[i];
                var applied = skin != null ? skin.GetBlendShapeWeight(speechIndices[i]) : 0f;
                if (speechPlaying && skin != null) speechDiagnosticMaxAppliedPercent = Mathf.Max(speechDiagnosticMaxAppliedPercent, applied);
                if (!shouldLog) continue;
                if (actual.Length > 0) actual += ",";
                actual += skin != null ? applied.ToString("F5", System.Globalization.CultureInfo.InvariantCulture) : "missing";
            }
            if (!shouldLog) return;
            Debug.Log($"[PmxSpeechFrameDiagnostic] frame={Time.frameCount} playing={speechPlaying} rawLevel={speechDiagnosticRawLevel:F6} aaTarget={speechWeight / 100f:F6} runtimePercent={speechWeight:F5} bindingCount={speechTargets.Length} appliedPercent=[{actual}] maxRawLevel={speechDiagnosticMaxRawLevel:F6} maxAppliedPercent={speechDiagnosticMaxAppliedPercent:F5}");
            speechDiagnosticStopPending = false;
            if (speechDiagnosticFrames > 0) --speechDiagnosticFrames;
        }
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
        public void SetSpeechLevel(bool playing, float level)
        {
#if GMGN_UMT
            if (playing && !speechPlaying) {
                speechDiagnosticFrames = 12;
                speechDiagnosticMaxRawLevel = 0f;
                speechDiagnosticMaxAppliedPercent = 0f;
            }
            if (!playing && speechPlaying) speechDiagnosticStopPending = true;
            speechDiagnosticRawLevel = level;
            if (playing && float.IsFinite(level)) speechDiagnosticMaxRawLevel = Mathf.Max(speechDiagnosticMaxRawLevel, level);
            if (speechPlaying || playing) speechResetPending = true;
            speechPlaying = playing;
            speechWeight = playing && float.IsFinite(level) ? Mathf.Clamp01(level * 2f) * 100f : 0;
#endif
        }
        void OnDestroy()
        {
            ++generation;
#if GMGN_UMT
            DisposeImport(imported, container);
#endif
        }
    }
}
