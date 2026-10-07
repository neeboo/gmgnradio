#if GMGN_UNIVRM
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using UniGLTF;
using UniVRM10;
using UnityEngine;

namespace GMGN.UnityPlayer.Characters
{
    // UniVRM Vrm10Instance processes retargeting at 11000. Contact refinement
    // and its receipt must observe that final pose before world sampling at12000.
    [DefaultExecutionOrder(11500)]
    public sealed class VrmCharacterRuntime : MonoBehaviour
    {
        public string CharacterId { get; private set; }
        public string MotionId { get; private set; }
        public bool IsMotionPlaying => motionOwner != null && motionOwner.GetComponent<Animation>().isPlaying;
        Vrm10Instance avatar;
        RuntimeGltfInstance motionOwner;
        bool speechDiagnosticPlaying;
        bool speechDiagnosticStopPending;
        int speechDiagnosticFrames;
        float speechDiagnosticRawLevel;
        float speechDiagnosticTarget;
        float speechDiagnosticMaxRawLevel;
        float speechDiagnosticMaxAppliedPercent;
        public float SpeechDiagnosticMaxRawLevel => speechDiagnosticMaxRawLevel;
        public float SpeechDiagnosticMaxAppliedPercent => speechDiagnosticMaxAppliedPercent;
        bool navigationLocomotion;
        Transform rightPalmAttachment;
        CharacterGripPose heldFingerPose;
        public int HeldFingerContactCount => heldFingerPose?.ContactCount ?? 0;
        public float HeldFingerMaximumContactError => heldFingerPose?.MaximumContactError ?? float.PositiveInfinity;
        public string[] HeldFingerDiagnostics => heldFingerPose?.ContactDiagnostics.ToArray() ?? Array.Empty<string>();
        public void ClearHeldFingerPose() { heldFingerPose?.Clear(); }
        void Update() { heldFingerPose?.Restore(); }
        public void ApplyHeldFingerPose(Vector3 centre,Vector3 axis,float radius)
        {
            if(avatar==null)return;
            if(heldFingerPose==null) {
                heldFingerPose=new CharacterGripPose();
                foreach(var bones in new[]{
                    new[]{HumanBodyBones.RightIndexProximal,HumanBodyBones.RightIndexIntermediate,HumanBodyBones.RightIndexDistal},
                    new[]{HumanBodyBones.RightMiddleProximal,HumanBodyBones.RightMiddleIntermediate,HumanBodyBones.RightMiddleDistal},
                    new[]{HumanBodyBones.RightRingProximal,HumanBodyBones.RightRingIntermediate,HumanBodyBones.RightRingDistal},
                    new[]{HumanBodyBones.RightLittleProximal,HumanBodyBones.RightLittleIntermediate,HumanBodyBones.RightLittleDistal}}) {
                    var chain=new Transform[4];
                    for(var index=0;index<3;index++)avatar.TryGetBoneTransform(bones[index],out chain[index]);
                    if(chain[2]==null||chain[1]==null)continue;
                    if(chain[2].childCount>0)chain[3]=chain[2].GetChild(0);
                    else {
                        // Derive the terminal point from vertices actually
                        // weighted to this distal bone, not an invented length.
                        var end=chain[2].position;var distance=0f;var terminalJoint=2;
                        // Some authored avatars declare distal bones with no
                        // skin influence. Their visible finger is driven by the
                        // intermediate bone; measure and refine that real chain.
                        for(var candidate=2;candidate>=1 && distance<.001f;candidate--) {
                        var forward=(chain[candidate].position-chain[candidate-1].position).normalized;
                        foreach(var skin in avatar.GetComponentsInChildren<SkinnedMeshRenderer>()) {
                            var boneIndex=Array.IndexOf(skin.bones,chain[candidate]);
                            if(boneIndex<0||skin.sharedMesh==null)continue;
                            var mesh=new Mesh();skin.BakeMesh(mesh);
                            var vertices=mesh.vertices;var weights=skin.sharedMesh.boneWeights;
                            for(var index=0;index<Math.Min(vertices.Length,weights.Length);index++) {
                                var w=weights[index];
                                var weight=(w.boneIndex0==boneIndex?w.weight0:0)+(w.boneIndex1==boneIndex?w.weight1:0)
                                    +(w.boneIndex2==boneIndex?w.weight2:0)+(w.boneIndex3==boneIndex?w.weight3:0);
                                if(weight<.35f)continue;
                                var point=skin.transform.position+skin.transform.rotation*vertices[index];
                                var along=Vector3.Dot(point-chain[candidate].position,forward);
                                if(along>distance){distance=along;end=chain[candidate].position+forward*along;terminalJoint=candidate;}
                            }
                            if(Application.isPlaying)Destroy(mesh);else DestroyImmediate(mesh);
                        }
                        }
                        if(distance<.001f)continue;
                        var tip=new GameObject("Grip fingertip "+bones[2]).transform;
                        tip.SetParent(chain[terminalJoint],false);tip.position=end;
                        if(terminalJoint==1)chain=new[]{chain[0],chain[1],tip};else chain[3]=tip;
                    }
                    heldFingerPose.Add(chain);
                }
            }
            heldFingerPose.Set(centre,axis,radius);heldFingerPose.Apply();
        }
        Vector3? restingHipsInAvatar;
        public void SetNavigationLocomotion(bool value) => navigationLocomotion=value;
        public static Vector3 NavigationHipsPosition(Vector3 animated,Vector3 resting,bool locomoting)
            => locomoting ? new Vector3(resting.x,animated.y,resting.z) : animated;
        Vector3? interactionContact;
        Vector3 measuredHand;
        float measuredDistance = float.PositiveInfinity;
        int measuredFrame = -1;
        float diagnosticClosest = float.PositiveInfinity;
        string interactionDiagnosticKey;
        int interactionDiagnosticSamples;
        float interactionDiagnosticMinimum = float.PositiveInfinity;
        float interactionDiagnosticReportedMinimum = float.PositiveInfinity;
        int interactionDiagnosticMinimumFrame;
        bool interactionDiagnosticWasReady;
        public void SetInteractionDiagnosticContext(string key) {
            if (key == interactionDiagnosticKey) return;
            if (interactionDiagnosticKey != null && float.IsFinite(interactionDiagnosticMinimum))
                Debug.Log($"[InteractionFrameMinimum] projection={interactionDiagnosticKey} frame={interactionDiagnosticMinimumFrame} wristDistance={interactionDiagnosticMinimum:F5}");
            interactionDiagnosticKey = key; interactionDiagnosticSamples = 0;
            interactionDiagnosticMinimum = float.PositiveInfinity;
            interactionDiagnosticReportedMinimum = float.PositiveInfinity;
            interactionDiagnosticWasReady = false;
        }
        public string InteractionMotionDiagnostic() {
            var animation = motionOwner != null ? motionOwner.GetComponent<Animation>() : null;
            var clip = animation != null ? animation.clip : null;
            var state = clip != null ? animation[clip.name] : null;
            return $"motion={MotionId} time={(state != null ? state.time : -1):F4} duration={(clip != null ? clip.length : -1):F4} speed={(state != null ? state.speed : 0):F3} playing={IsMotionPlaying}";
        }
        public void SetInteractionContact(Vector3? target) {
            if (interactionContact != target) { measuredFrame = -1; measuredDistance = float.PositiveInfinity; diagnosticClosest = float.PositiveInfinity; }
            interactionContact = target;
        }
        public bool TryReadInteractionContact(out Vector3 hand, out float distance)
        {
            hand = measuredHand; distance = measuredDistance;
            return interactionContact.HasValue && measuredFrame >= Time.frameCount - 1
                && float.IsFinite(distance) && distance <= .1f;
        }
        void LateUpdate()
        {
            // WorldRuntime owns route displacement. Only navigation removes the
            // VRMA's extra horizontal root track; retain vertical bob/jumps and
            // all authored translation for non-navigation performances.
            if(navigationLocomotion && restingHipsInAvatar.HasValue && avatar!=null &&
                avatar.TryGetBoneTransform(HumanBodyBones.Hips,out var hips)) {
                var animated=avatar.transform.InverseTransformPoint(hips.position);
                hips.position=avatar.transform.TransformPoint(NavigationHipsPosition(animated,restingHipsInAvatar.Value,true));
            }
            ApplyInteractionContactAfterRetarget();
            LogSpeechDiagnosticAfterExpression();
        }
        internal void ApplyInteractionContactAfterRetarget()
        {
            measuredDistance = float.PositiveInfinity; measuredFrame = Time.frameCount;
            if (!interactionContact.HasValue || avatar == null ||
                !avatar.TryGetBoneTransform(HumanBodyBones.RightUpperArm, out var upper) ||
                !avatar.TryGetBoneTransform(HumanBodyBones.RightLowerArm, out var lower) ||
                !avatar.TryGetBoneTransform(HumanBodyBones.RightHand, out var hand)) return;
            var target = interactionContact.Value;
            // Only refine an authored interaction pose already near its contact.
            // Never teleport the character or stretch limbs to reach a device.
            var offset = Vector3.Distance(hand.position, target);
            if (offset <= .2f && offset > .001f) {
                var a = upper.position; var b = lower.position; var c = hand.position;
                var first = Vector3.Distance(a,b); var second = Vector3.Distance(b,c);
                var direction = target-a; var length = direction.magnitude;
                if (Environment.GetEnvironmentVariable("GMGN_REACH_DEVICE_DECLARATION") != null &&
                    offset < diagnosticClosest - .01f) {
                    diagnosticClosest = offset;
                    Debug.Log($"[InteractionIK] offset={offset:F5} reach={length:F5} upper={first:F5} lower={second:F5} shoulder={a:F5} elbow={b:F5} hand={c:F5} target={target:F5} bones={upper.name}/{lower.name}/{hand.name}");
                }
                // An authored pose can be slightly outside the arm's reach.
                // Aim at the nearest reachable point without changing bone
                // lengths; the receipt still measures the real device target.
                var reachableLength = Mathf.Min(length, (first + second) * .999f);
                if (first > .001f && second > .001f && length > .001f &&
                    reachableLength > Mathf.Abs(first-second)) {
                    var axis = direction/length;
                    var reachableTarget = a + axis * reachableLength;
                    var bend = Vector3.ProjectOnPlane(b-a, axis);
                    if (bend.sqrMagnitude > .000001f) {
                        var along = (first*first + reachableLength*reachableLength - second*second)/(2*reachableLength);
                        var height = Mathf.Sqrt(Mathf.Max(0,first*first-along*along));
                        var elbow = a+axis*along+bend.normalized*height;
                        upper.rotation = Quaternion.FromToRotation(b-a,elbow-a)*upper.rotation;
                        lower.rotation = Quaternion.FromToRotation(hand.position-lower.position,reachableTarget-lower.position)*lower.rotation;
                    }
                }
            }
            measuredHand = hand.position;
            measuredDistance = Vector3.Distance(measuredHand,target);
            // Bounded evidence from the actual post-retarget scene frame. This
            // observes contact without changing the acceptance gate or receipt.
            var diagnosticReady = measuredDistance <= .1f;
            if (interactionDiagnosticKey != null && interactionDiagnosticSamples < 16 &&
                (interactionDiagnosticSamples == 0 ||
                 (interactionDiagnosticSamples < 10 && measuredDistance < interactionDiagnosticReportedMinimum - .05f) ||
                 diagnosticReady != interactionDiagnosticWasReady)) {
                interactionDiagnosticSamples++;
                interactionDiagnosticReportedMinimum = Mathf.Min(interactionDiagnosticReportedMinimum, measuredDistance);
                var fingerDistance = float.PositiveInfinity;
                foreach (var finger in new[] { HumanBodyBones.RightIndexDistal, HumanBodyBones.RightMiddleDistal,
                    HumanBodyBones.RightRingDistal, HumanBodyBones.RightLittleDistal })
                    if (avatar.TryGetBoneTransform(finger,out var bone)) fingerDistance = Mathf.Min(fingerDistance,Vector3.Distance(bone.position,target));
                Debug.Log($"[InteractionFrame] projection={interactionDiagnosticKey} frame={Time.frameCount} {InteractionMotionDiagnostic()} root={transform.position:F4} rootScale={transform.lossyScale:F4} avatarScale={avatar.transform.lossyScale:F4} shoulder={upper.position:F4} wrist={measuredHand:F4} target={target:F4} authoredOffset={offset:F4} wristDistance={measuredDistance:F4} fingerMinimum={fingerDistance:F4} ready={measuredDistance <= .1f}");
            }
            if(measuredDistance < interactionDiagnosticMinimum) {
                interactionDiagnosticMinimum = measuredDistance; interactionDiagnosticMinimumFrame=Time.frameCount;
            }
            interactionDiagnosticWasReady = diagnosticReady;
        }
        int generation;

        public async Task LoadAsync(string id, string path, CancellationToken cancellation)
        {
            heldFingerPose?.Clear();heldFingerPose=null;
            if (!File.Exists(path)) throw new FileNotFoundException("角色资源缺失。", path);
            var next = await Vrm10.LoadPathAsync(path, canLoadVrm0X: true, showMeshes: false,
                materialGenerator: new UrpVrm10MaterialDescriptorGenerator(), ct: cancellation);
            try {
                cancellation.ThrowIfCancellationRequested();
                if (next == null) throw new InvalidDataException("VRM角色未能载入。");
                // UniVRM initializes its control rig lazily and captures the
                // bones' initial world rotations. Build it at the imported
                // identity root, before world heading and presentation scale
                // are applied, or a 180-degree placement reverses arm motion.
                _ = next.Runtime;
                next.GetComponent<RuntimeGltfInstance>().ShowMeshes();
                foreach (var renderer in next.GetComponentsInChildren<Renderer>(true))
                    foreach (var material in renderer.sharedMaterials) {
                        if (material == null) continue;
                        var baseTexture = material.HasProperty("_BaseMap") ? material.GetTexture("_BaseMap")
                            : material.HasProperty("_MainTex") ? material.GetTexture("_MainTex") : null;
                        Debug.Log($"[VrmMaterial] name={material.name} shader={material.shader?.name} supported={material.shader != null && material.shader.isSupported} baseTexture={baseTexture?.name ?? "missing"} size={baseTexture?.width ?? 0}x{baseTexture?.height ?? 0}");
                    }
                NormalizePresentation(next.transform);
                next.transform.SetParent(transform, false);
                // UniVRM caches spring segment lengths during import. Rebuild
                // after the final presentation scale/parent so skirt lengths
                // and scaled leg colliders use the same world-space geometry.
                next.Runtime.SpringBone.ReconstructSpringBone();
                avatar = next; CharacterId = id;
                restingHipsInAvatar=avatar.TryGetBoneTransform(HumanBodyBones.Hips,out var hips)
                    ? avatar.transform.InverseTransformPoint(hips.position) : null;
            } catch { if (next != null) Destroy(next.gameObject); throw; }
        }

        // Match the PMX presentation height. Keep this below the authoritative
        // world transform, so a user's placement scale is neither lost nor baked
        // into the imported avatar. Measure geometry, not padded skinning bounds.
        static void NormalizePresentation(Transform root)
        {
            const float heightMeters = 1.65f;
            var bounds = new Bounds();
            var initialized = false;
            var baked = new Mesh();
            try {
                foreach (var renderer in root.GetComponentsInChildren<Renderer>(true)) {
                    if (!renderer.enabled) continue;
                    // The replacement's staging parent is intentionally inactive.
                    // Ignore hidden wardrobe/accessory nodes inside the avatar,
                    // without rejecting the whole uncommitted replacement.
                    bool visible = true;
                    for (var node = renderer.transform; node != root; node = node.parent)
                        if (!node.gameObject.activeSelf) { visible = false; break; }
                    if (!visible) continue;
                    Mesh mesh;
                    var matrix = root.worldToLocalMatrix * renderer.transform.localToWorldMatrix;
                    if (renderer is SkinnedMeshRenderer skin) {
                        baked.Clear();
                        // Follow UniGLTF.MeshFreezer: skinning already accounts
                        // for imported bone/mesh scale. Apply only the renderer's
                        // rotation and position to the baked vertices.
                        skin.BakeMesh(baked);
                        matrix = root.worldToLocalMatrix * Matrix4x4.TRS(
                            skin.transform.position, skin.transform.rotation, Vector3.one);
                        mesh = baked;
                    } else mesh = renderer.GetComponent<MeshFilter>()?.sharedMesh;
                    if (mesh == null) continue;
                    foreach (var vertex in mesh.vertices) {
                        var point = matrix.MultiplyPoint3x4(vertex);
                        if (!initialized) { bounds = new Bounds(point, Vector3.zero); initialized = true; }
                        else bounds.Encapsulate(point);
                    }
                }
            } finally { if (Application.isPlaying) Destroy(baked); else DestroyImmediate(baked); }
            if (!initialized || !float.IsFinite(bounds.size.y) || bounds.size.y <= .001f)
                throw new InvalidDataException("角色没有有效的可见网格。");
            var scale = heightMeters / bounds.size.y;
            root.localScale *= scale;
            root.localPosition = new Vector3(-bounds.center.x * scale, -bounds.min.y * scale, -bounds.center.z * scale);
            Debug.Log($"[CharacterScale] format=vrm sourceHeight={bounds.size.y:F4} targetHeight={heightMeters:F2} scale={scale:F4}");
        }

        public async Task PlayMotionAsync(string id, string path, bool loop, float rate, CancellationToken cancellation)
        {
            if (avatar == null) throw new InvalidOperationException("请先载入角色。");
            if (!File.Exists(path) || !float.IsFinite(rate) || rate <= 0) throw new InvalidDataException("动作资源无效。");
            var request = ++generation;
            RuntimeGltfInstance next = null;
            try {
                using var data = new AutoGltfFileParser(path).Parse();
                using var importer = new VrmAnimationImporter(new VrmAnimationData(data));
                next = await importer.LoadAsync(new RuntimeOnlyAwaitCaller());
                cancellation.ThrowIfCancellationRequested();
                if (request != generation) throw new OperationCanceledException();
                var animationInstance = next.GetComponent<Vrm10AnimationInstance>();
                var animation = next.GetComponent<Animation>();
                if (animationInstance == null || animation == null || animation.clip == null)
                    throw new InvalidDataException("VRMA动作缺少可播放的动画。");
                next.transform.SetParent(transform, false);
                if (animationInstance.BoxMan != null) animationInstance.ShowBoxMan(false);
                foreach (AnimationState state in animation) { state.speed = rate; state.wrapMode = loop ? WrapMode.Loop : WrapMode.Once; }
                if (!animation.Play() || !animation.isPlaying)
                    throw new InvalidDataException("VRMA动作未开始播放。");
                avatar.Runtime.VrmAnimation = animationInstance;
                var previous = motionOwner;
                motionOwner = next; next = null; MotionId = id;
                if (previous != null) Destroy(previous.gameObject);
            } finally { if (next != null) Destroy(next.gameObject); }
        }

        public void StopMotion()
        {
            ++generation;
            if (avatar != null) avatar.Runtime.VrmAnimation = null;
            if (motionOwner != null) Destroy(motionOwner.gameObject);
            motionOwner = null; MotionId = null;
        }
        public void SetSpeechLevel(bool playing, float level)
        {
            if (avatar == null) return;
            if (playing && !speechDiagnosticPlaying) {
                speechDiagnosticFrames = 12;
                speechDiagnosticMaxRawLevel = 0f;
                speechDiagnosticMaxAppliedPercent = 0f;
            }
            if (!playing && speechDiagnosticPlaying) speechDiagnosticStopPending = true;
            speechDiagnosticPlaying = playing;
            speechDiagnosticRawLevel = level;
            if (playing && float.IsFinite(level)) speechDiagnosticMaxRawLevel = Mathf.Max(speechDiagnosticMaxRawLevel, level);
            speechDiagnosticTarget = playing && float.IsFinite(level) ? Mathf.Clamp01(level * 2f) : 0f;
            avatar.Runtime.Expression.SetWeight(ExpressionKey.CreateFromPreset(ExpressionPreset.aa),
                speechDiagnosticTarget);
        }
        void LogSpeechDiagnosticAfterExpression()
        {
            if (avatar == null || (!speechDiagnosticPlaying && !speechDiagnosticStopPending)) return;
            var shouldLog = speechDiagnosticStopPending || speechDiagnosticFrames > 0;
            var actual = "";
            var expression = avatar.Vrm.Expression.Aa;
            if (expression != null) foreach (var binding in expression.MorphTargetBindings) {
                var node = avatar.transform.Find(binding.RelativePath);
                var skin = node != null ? node.GetComponent<SkinnedMeshRenderer>() : null;
                if (speechDiagnosticPlaying && skin != null)
                    speechDiagnosticMaxAppliedPercent = Mathf.Max(speechDiagnosticMaxAppliedPercent, skin.GetBlendShapeWeight(binding.Index));
                if (!shouldLog) continue;
                if (actual.Length > 0) actual += ",";
                actual += skin != null ? skin.GetBlendShapeWeight(binding.Index).ToString("F5", System.Globalization.CultureInfo.InvariantCulture) : "missing";
            }
            if (!shouldLog) return;
            var weight = avatar.Runtime.Expression.GetWeight(ExpressionKey.CreateFromPreset(ExpressionPreset.aa));
            Debug.Log($"[SpeechFrameDiagnostic] frame={Time.frameCount} playing={speechDiagnosticPlaying} rawLevel={speechDiagnosticRawLevel:F6} aaTarget={speechDiagnosticTarget:F6} aaRuntime={weight:F6} appliedPercent=[{actual}] maxRawLevel={speechDiagnosticMaxRawLevel:F6} maxAppliedPercent={speechDiagnosticMaxAppliedPercent:F5}");
            speechDiagnosticStopPending = false;
            if (speechDiagnosticFrames > 0) --speechDiagnosticFrames;
        }
        public bool TryGetHeadPosition(out Vector3 position)
        {
            position = default;
            if (avatar == null || !avatar.TryGetBoneTransform(HumanBodyBones.Head, out var head)) return false;
            position = head.position;
            return true;
        }
        public bool TryGetAttachmentBone(string slot, out Transform bone)
        {
            bone = null;
            if (avatar == null) return false;
            switch (slot) {
                case "rightHand":
                    if (!avatar.TryGetBoneTransform(HumanBodyBones.RightHand, out bone)) return false;
                    if (avatar.TryGetBoneTransform(HumanBodyBones.RightMiddleProximal, out var middle)) {
                        if (rightPalmAttachment == null || rightPalmAttachment.parent != bone) {
                            if (rightPalmAttachment != null) Destroy(rightPalmAttachment.gameObject);
                            rightPalmAttachment = new GameObject("Right palm attachment").transform;
                            rightPalmAttachment.SetParent(bone,false);
                            if(avatar.TryGetBoneTransform(HumanBodyBones.RightIndexProximal,out var indexFinger)&&
                                avatar.TryGetBoneTransform(HumanBodyBones.RightLittleProximal,out var littleFinger))
                                rightPalmAttachment.localRotation=CharacterGripPose.PalmLocalRotation(bone,indexFinger,middle,littleFinger,transform.up);
                        }
                        rightPalmAttachment.localPosition = bone.InverseTransformPoint((bone.position+middle.position)*.5f);
                        bone = rightPalmAttachment;
                    }
                    return true;
                case "waist": return avatar.TryGetBoneTransform(HumanBodyBones.Hips, out bone);
                case "back": return avatar.TryGetBoneTransform(HumanBodyBones.UpperChest, out bone)
                    || avatar.TryGetBoneTransform(HumanBodyBones.Chest, out bone)
                    || avatar.TryGetBoneTransform(HumanBodyBones.Spine, out bone);
                default: return false;
            }
        }
        void OnDestroy() { ++generation; }
    }
}
#endif
