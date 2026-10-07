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
#if GMGN_UNIVRM
        public VrmCharacterRuntime VrmRuntime { get; private set; }
#endif
        public string Notice { get; private set; }
        public event Action<string> NoticeChanged;
        public event Action<JObject> SelectionCompleted;
        public event Action<JObject> ManualMotionCompleted;
        public string CharacterId { get; private set; }
        public long LoadedSelectionRevision { get; private set; }
        public string LoadedAvatarFormat =>
#if GMGN_UNIVRM
            VrmRuntime != null ? "vrm" :
#endif
            Runtime != null && Runtime.IsLoaded ? "pmx" : selectedContent != null ? "orb" : null;
        public bool TryGetAttachmentBone(string slot, out Transform bone)
        {
            if (Runtime != null) return Runtime.TryGetAttachmentBone(slot, out bone);
#if GMGN_UNIVRM
            if (VrmRuntime != null) return VrmRuntime.TryGetAttachmentBone(slot, out bone);
#endif
            bone = null; return false;
        }
        public void ClearHeldFingerPose()
        {
            Runtime?.ClearHeldFingerPose();
#if GMGN_UNIVRM
            VrmRuntime?.ClearHeldFingerPose();
#endif
        }
        public void ApplyHeldFingerPose(Vector3 centre,Vector3 axis,float radius)
        {
            Runtime?.ApplyHeldFingerPose(centre,axis,radius);
#if GMGN_UNIVRM
            VrmRuntime?.ApplyHeldFingerPose(centre,axis,radius);
#endif
        }
        public Vector3 HeadPosition {
            get {
                if (Runtime != null && Runtime.TryGetHeadPosition(out var pmxHead)) return pmxHead;
#if GMGN_UNIVRM
                if (VrmRuntime != null && VrmRuntime.TryGetHeadPosition(out var vrmHead)) return vrmHead;
#endif
                return transform.TransformPoint(new Vector3(0, 1.65f, 0));
            }
        }
        public string MotionId => Runtime != null ? Runtime.MotionId :
#if GMGN_UNIVRM
            VrmRuntime != null ? VrmRuntime.MotionId :
#endif
            null;
        long selectionGeneration;
        GameObject selectedContent;
        string currentModelPath;
        string activityMotionKey;
        bool activityMotionReady;
        CancellationTokenSource activityMotionCancellation;
        bool selectedMotionOwnsIdle;
        string finiteSelectedMotionID;
        long finiteSelectedRevision;
        bool finiteSelectedWasPlaying;
        bool IsCurrentMotionPlaying => Runtime != null ? Runtime.IsMotionPlaying :
#if GMGN_UNIVRM
            VrmRuntime != null ? VrmRuntime.IsMotionPlaying :
#endif
            false;
        void RememberManualMotion(JObject motion) {
            selectedMotionOwnsIdle = true;
            finiteSelectedMotionID = motion != null && (bool?)motion["loop"] == false ? (string)motion["id"] : null;
            finiteSelectedRevision = LoadedSelectionRevision;
            finiteSelectedWasPlaying = finiteSelectedMotionID != null && IsCurrentMotionPlaying;
        }
        Vector3 activityTargetPosition;
        Quaternion activityTargetRotation;
        bool hasActivityTarget;
        string activityPoseWorldID;
        ulong? activityPoseRevision;

        // The host supplies verified package paths from its authoritative stores.
        // Prepare a complete replacement before discarding the visible character.
        public async Task ApplySelectionAsync(JObject selection, CancellationToken cancellation)
        {
            var generation = ++selectionGeneration;
            var revision = (long?)selection?["revision"] ?? 0;
            GameObject staging = null;
            try {
                cancellation.ThrowIfCancellationRequested();
                var avatar = selection?["avatar"] as JObject;
                var format = (string)avatar?["format"] ?? "orb";
                var id = (string)avatar?["id"] ?? "builtin.breathing-orb";
                var requestedMotion = selection?["motion"] as JObject;
                // A settings selection supersedes an in-flight activity import,
                // including the fast path that keeps the same avatar instance.
                activityMotionCancellation?.Cancel();
                activityMotionKey = null; activityMotionReady = false;
                selectedMotionOwnsIdle = true;
                Debug.Log($"[CharacterSelection] revision={revision} character={id} format={format} motion={(string)requestedMotion?["id"]} motionFormat={(string)requestedMotion?["format"]}");
#if GMGN_UNIVRM
                if (format == "vrm" && VrmRuntime != null && CharacterId == id &&
                    currentModelPath == (string)avatar?["modelPath"]) {
                    if (requestedMotion == null || (string)requestedMotion["format"] == "procedural") VrmRuntime.StopMotion();
                    else {
                        if ((string)requestedMotion["format"] != "vrma")
                            throw new NotSupportedException("这个动作与当前角色不兼容，保留原动作。");
                        await VrmRuntime.PlayMotionAsync(Required(requestedMotion,"id"),Required(requestedMotion,"path"),
                            (bool?)requestedMotion["loop"] ?? true,(float?)requestedMotion["playbackRate"] ?? 1,cancellation);
                    }
                    cancellation.ThrowIfCancellationRequested();
                    if (generation != selectionGeneration) throw new OperationCanceledException();
                    LoadedSelectionRevision = revision;
                    RememberManualMotion(requestedMotion);
                    SelectionCompleted?.Invoke(new JObject { ["revision"] = revision,["success"] = true,
                        ["characterID"] = CharacterId,["motionID"] = MotionId });
                    return;
                }
#endif
                if (format == "pmx" && Runtime != null && Runtime.IsLoaded && CharacterId == id &&
                    currentModelPath == (string)avatar?["modelPath"]) {
                    if (requestedMotion == null || (string)requestedMotion["format"] == "procedural") Runtime.StopMotion();
                    else {
                        if ((string)requestedMotion["format"] != "vmd")
                            throw new NotSupportedException("这个动作与当前角色不兼容，保留原动作。");
                        await Runtime.PlayMotionAsync(Required(requestedMotion, "id"), Required(requestedMotion, "path"),
                            (bool?)requestedMotion["loop"] ?? true, (float?)requestedMotion["playbackRate"] ?? 1, cancellation);
                    }
                    cancellation.ThrowIfCancellationRequested();
                    if (generation != selectionGeneration) throw new OperationCanceledException();
                    LoadedSelectionRevision = revision;
                    RememberManualMotion(requestedMotion);
                    SelectionCompleted?.Invoke(new JObject { ["revision"] = revision, ["success"] = true,
                        ["characterID"] = CharacterId, ["motionID"] = MotionId });
                    return;
                }
                staging = new GameObject("Character Selection");
                staging.transform.SetParent(transform, false);
                staging.SetActive(false);
                PmxCharacterRuntime next = null;
#if GMGN_UNIVRM
                VrmCharacterRuntime nextVrm = null;
#endif
                if (format == "orb" || format == "builtin") {
                    var orb = GameObject.CreatePrimitive(PrimitiveType.Quad);
                    orb.transform.SetParent(staging.transform, false);
                    orb.transform.localPosition = new Vector3(0, .85f, 0);
                    orb.transform.localScale = Vector3.one * .48f;
                    Destroy(orb.GetComponent<Collider>());
                    var breathingOrb = orb.AddComponent<BreathingOrbRuntime>();
                    var appearance = selection?["orbAppearance"];
                    if (appearance != null) breathingOrb.SetAppearance(new Color((float?)appearance["red"] ?? .16f,
                        (float?)appearance["green"] ?? .62f, (float?)appearance["blue"] ?? 1),
                        (float?)appearance["flowIntensity"] ?? .82f);
                } else if (format == "pmx") {
                    next = staging.AddComponent<PmxCharacterRuntime>();
                    await next.LoadAsync(id, Required(avatar, "modelPath"));
                    if (!next.IsLoaded) throw new OperationCanceledException();
#if GMGN_UNIVRM
                } else if (format == "vrm") {
                    nextVrm = staging.AddComponent<VrmCharacterRuntime>();
                    await nextVrm.LoadAsync(id, Required(avatar, "modelPath"), cancellation);
#endif
                } else throw new NotSupportedException("这个角色格式尚未接入 Unity，保留原角色。");
                var motion = selection?["motion"] as JObject;
                if (motion != null && (string)motion["format"] != "procedural") {
#if GMGN_UNIVRM
                    if (nextVrm != null && (string)motion["format"] == "vrma") {
                        await nextVrm.PlayMotionAsync(Required(motion, "id"), Required(motion, "path"),
                            (bool?)motion["loop"] ?? true, (float?)motion["playbackRate"] ?? 1, cancellation);
                    } else {
#endif
                    if (next == null || (string)motion["format"] != "vmd")
                        throw new NotSupportedException("这个动作与当前角色不兼容，保留原角色和动作。");
                    await next.PlayMotionAsync(Required(motion, "id"), Required(motion, "path"),
                        (bool?)motion["loop"] ?? true, (float?)motion["playbackRate"] ?? 1, cancellation);
                    if (next.MotionId != (string)motion["id"]) throw new OperationCanceledException();
#if GMGN_UNIVRM
                    }
#endif
                }
                cancellation.ThrowIfCancellationRequested();
                if (generation != selectionGeneration) throw new OperationCanceledException();
                var previous = selectedContent;
                var previousRuntime = Runtime;
                activityMotionCancellation?.Cancel();
                activityMotionKey = null; activityMotionReady = false;
                if (previousRuntime != null) previousRuntime.Notice -= SetNotice;
                selectedContent = staging; staging = null;
                Runtime = next; CharacterId = id;
#if GMGN_UNIVRM
                VrmRuntime = nextVrm;
#endif
                currentModelPath = (string)avatar?["modelPath"];
                if (next != null) next.Notice += SetNotice;
                selectedContent.SetActive(true);
                if (previous != null) Destroy(previous);
                else if (previousRuntime != null) Destroy(previousRuntime);
                SetNotice("");
                Debug.Log($"[CharacterSelection] ready revision={revision} character={CharacterId} motion={MotionId}");
                LoadedSelectionRevision = revision;
                RememberManualMotion(requestedMotion);
                SelectionCompleted?.Invoke(new JObject { ["revision"] = revision, ["success"] = true,
                    ["characterID"] = CharacterId, ["motionID"] = MotionId });
            } catch (Exception error) {
                if (staging != null) Destroy(staging);
                if (generation == selectionGeneration) {
                    Debug.LogWarning($"[CharacterSelection] failed revision={revision} type={error.GetType().Name} reason={error.Message}");
                    SetNotice(error is OperationCanceledException ? "角色切换已取消。" : error.Message);
                    SelectionCompleted?.Invoke(new JObject { ["revision"] = revision, ["success"] = false,
                        ["code"] = error is OperationCanceledException ? "cancelled" : "character_load_failed",
                        ["characterID"] = CharacterId, ["motionID"] = MotionId });
                }
            }
        }

        public static async Task<CharacterWorldAdapter> RestoreAsync(JObject state, Transform parent, CancellationToken cancellation)
        {
            var manifestPath = Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
            if (string.IsNullOrWhiteSpace(manifestPath)) return null;
            cancellation.ThrowIfCancellationRequested();
            var manifest = JObject.Parse(File.ReadAllText(manifestPath));
            if ((string)manifest["engine"] != "pmx") {
                var selectionRoot = new GameObject("World Character");
                selectionRoot.transform.SetParent(parent, false);
                var selected = selectionRoot.AddComponent<CharacterWorldAdapter>();
                try {
                    selected.ApplyState(state);
                    var engine = Required(manifest, "engine");
                    var avatar = new JObject { ["id"] = Required(manifest, "id"), ["format"] = engine };
                    if (engine != "orb") avatar["modelPath"] = EntryPath(manifestPath, Required(manifest, "entry"));
                    var selection = new JObject { ["avatar"] = avatar };
                    var startupMotion = Environment.GetEnvironmentVariable("GMGN_UNITY_MOTION_MANIFEST");
                    if (!string.IsNullOrWhiteSpace(startupMotion)) {
                        var entry = JObject.Parse(File.ReadAllText(startupMotion));
                        selection["motion"] = new JObject { ["id"] = Required(entry,"id"), ["format"] = Required(entry,"format"),
                            ["path"] = EntryPath(startupMotion, Required(entry,"entry")), ["loop"] = entry["loop"] ?? true,
                            ["playbackRate"] = entry["playbackRate"] ?? 1 };
                    }
                    await selected.ApplySelectionAsync(selection, cancellation);
                    cancellation.ThrowIfCancellationRequested();
                    if (selected.CharacterId == null) throw new InvalidDataException(selected.Notice);
                    return selected;
                } catch { Destroy(selectionRoot); throw; }
            }
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
                adapter.CharacterId = id;
                adapter.currentModelPath = model;
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
            // Durable world readbacks lag the 30 Hz activity projection. They
            // still refresh objects, but must not reset the actor to an older
            // checkpoint between activity updates.
            if (hasActivityTarget && (string)state?["worldID"] == activityPoseWorldID &&
                activityPoseRevision.HasValue && (ulong?)state?["revision"] <= activityPoseRevision.Value) return;
            hasActivityTarget = false;
#if GMGN_UNIVRM
            VrmRuntime?.SetNavigationLocomotion(false);
#endif
            activityPoseRevision = (ulong?)state?["revision"]; activityPoseWorldID = (string)state?["worldID"];
            var pose = state?["agentTransform"];
            if (pose == null) throw new InvalidDataException("空间缺少角色位置。");
            transform.localPosition = WorldCoordinates.Position(pose["position"]);
            transform.localRotation = WorldCoordinates.Rotation(pose["rotation"]);
            var scale = WorldCoordinates.Scale(pose["scale"]);
            if (scale.x <= 0 || scale.y <= 0 || scale.z <= 0) throw new InvalidDataException("角色尺寸数据无效。");
            transform.localScale = scale;
        }

        void SetNotice(string value) { Notice = value; NoticeChanged?.Invoke(value); }
        string contactDiagnosticKey;
        int contactDiagnosticSamples;
        float contactDiagnosticClosest = float.PositiveInfinity;
        readonly CharacterSeatProjection seatProjection = new CharacterSeatProjection();
        Vector3? activitySeatTarget;
        string activitySeatObjectID;

        bool ApplySeatProjection(out Vector3 actualPelvis)
        {
            Transform pelvis = null;
            if (Runtime != null) Runtime.TryGetAttachmentBone("waist", out pelvis);
#if GMGN_UNIVRM
            else if (VrmRuntime != null) VrmRuntime.TryGetAttachmentBone("waist", out pelvis);
#endif
            var target = activityMotionReady ? activitySeatTarget : null;
            return seatProjection.Apply(selectedContent != null ? selectedContent.transform : null,
                pelvis, target, out actualPelvis);
        }

        void LateUpdate() { ApplySeatProjection(out _); }
        public JObject ApplyResidentActivity(JObject snapshot)
        {
            var snapshotWorld=(string)snapshot?["worldID"];
            var snapshotRevision=(ulong?)snapshot?["revision"];
            if(snapshotWorld==activityPoseWorldID && activityPoseRevision.HasValue &&
                snapshotRevision.HasValue && snapshotRevision.Value<activityPoseRevision.Value) return null;
            var pose = snapshot?["agentTransform"] ?? throw new InvalidDataException("空间缺少角色位置。");
            activityTargetPosition = WorldCoordinates.Position(pose["position"]);
            var locomoting = (string)snapshot?["activeActivity"]?["phase"] == "approach"
                || (snapshot?["movement"] != null && snapshot["movement"].Type != JTokenType.Null);
#if GMGN_UNIVRM
            VrmRuntime?.SetNavigationLocomotion(locomoting);
#endif
            activityTargetRotation = CharacterActivityHeading.Resolve(pose["rotation"], locomoting);
            var scale = WorldCoordinates.Scale(pose["scale"]);
            if (scale.x <= 0 || scale.y <= 0 || scale.z <= 0) throw new InvalidDataException("角色尺寸数据无效。");
            transform.localScale = scale;
            hasActivityTarget = true;
            activityPoseWorldID=snapshotWorld; activityPoseRevision=snapshotRevision;
            var activity = snapshot?["activeActivity"];
            var phase = (string)snapshot?["phase"] ?? (string)activity?["phase"] ?? "idle";
            var request = (string)snapshot?["requestID"] ?? "";
            var motion = snapshot?["motion"] as JObject;
            activitySeatTarget = null;
            activitySeatObjectID = null;
            if ((bool?)snapshot?["seatRequired"] == true && phase == "loop"
                && motion != null && (string)motion["id"] == MotionId
                && ((string)motion["id"] == "gmgn.motion.bones.chair-sit-loop-pmx"
                    || (string)motion["id"] == "gmgn.motion.bones.chair-sit-loop-vrm")) {
                var seat = WorldCoordinates.Position(snapshot["seatTarget"]);
                activitySeatTarget = transform.parent != null ? transform.parent.TransformPoint(seat) : seat;
                activitySeatObjectID = (string)snapshot["seatObjectID"];
                // Seat facing is the inspected front/approach direction. Its
                // native vector avoids the stationary quaternion +Z ambiguity.
                var outward = Vector3.ProjectOnPlane(activityTargetPosition-seat,Vector3.up);
                if (outward.sqrMagnitude > .000001f)
                    activityTargetRotation = Quaternion.LookRotation(outward,Vector3.up);
            }
            var seatReady = ApplySeatProjection(out var seatedPelvis);
            var localPelvis = transform.parent != null
                ? transform.parent.InverseTransformPoint(seatedPelvis) : seatedPelvis;
            bool contactReady = false;
            Vector3 contactHand = default;
            float contactDistance = float.PositiveInfinity;
            var contactToken = snapshot?["contactTarget"];
            Vector3? interactionTarget = null;
            if ((bool?)snapshot?["contactRequired"] == true && contactToken != null && phase != "approach") {
                var localTarget = WorldCoordinates.Position(contactToken);
                interactionTarget = transform.parent != null ? transform.parent.TransformPoint(localTarget) : localTarget;
                // The durable pose can retain the last route segment's yaw.
                // Only a stationary, explicitly targeted device interaction
                // faces its real contact point; never alter route or idle yaw,
                // standing position, imported bones, or the contact threshold.
                if(!locomoting)
                    activityTargetRotation = CharacterActivityHeading.FaceInteractionContact(
                        activityTargetRotation,activityTargetPosition,localTarget);
            }
            if (Runtime != null) {
                Runtime.SetInteractionContact(interactionTarget);
                contactReady = Runtime.TryReadInteractionContact(out contactHand, out contactDistance);
                if (transform.parent != null) contactHand = transform.parent.InverseTransformPoint(contactHand);
            }
#if GMGN_UNIVRM
            if (VrmRuntime != null) {
                VrmRuntime.SetInteractionDiagnosticContext(interactionTarget.HasValue ? request + ":" + phase : null);
                VrmRuntime.SetInteractionContact(interactionTarget);
                contactReady = VrmRuntime.TryReadInteractionContact(out contactHand, out contactDistance);
                if (transform.parent != null) contactHand = transform.parent.InverseTransformPoint(contactHand);
            }
#endif
            if(interactionTarget.HasValue) {
                var diagnosticKey = request + ":" + phase;
                if(contactDiagnosticKey != diagnosticKey) {
                    contactDiagnosticKey = diagnosticKey; contactDiagnosticSamples=0;contactDiagnosticClosest=float.PositiveInfinity;
                }
                if(contactDiagnosticSamples<12 && (contactDiagnosticSamples<3 || contactDistance<contactDiagnosticClosest-.05f || contactReady)) {
                    contactDiagnosticSamples++;
                    contactDiagnosticClosest=Mathf.Min(contactDiagnosticClosest,contactDistance);
                    Debug.Log($"[InteractionReceiptFrame] projection={diagnosticKey} frame={Time.frameCount} rootLocal={transform.localPosition:F4} rootWorld={transform.position:F4} heading={transform.localRotation.eulerAngles:F3} rootScale={transform.lossyScale:F4} poseTarget={activityTargetPosition:F4} contactLocal={WorldCoordinates.Position(contactToken):F4} contactWorld={interactionTarget.Value:F4} handLocal={contactHand:F4} distance={contactDistance:F4} ready={contactReady} loadedMotion={MotionId} motionReady={activityMotionReady}");
                }
            }
            // Idle authority snapshots still carry the old activity's motion.
            // Keep the explicit settings selection until a new activity begins.
            if (selectedMotionOwnsIdle && !locomoting && (activity == null || activity.Type == JTokenType.Null)) {
                return new JObject { ["requestID"] = snapshot["requestID"]?.DeepClone(),
                    ["phase"] = phase, ["worldID"] = snapshot["worldID"]?.DeepClone(),
                    ["positionReady"] = true, ["motionReady"] = false, ["motionID"] = MotionId,
                    ["selectionRevision"] = LoadedSelectionRevision };
            }
            selectedMotionOwnsIdle = false;
            var key = request + ":" + phase + ":" + ((string)motion?["id"] ?? "idle");
            if (activityMotionKey != key) {
                activityMotionCancellation?.Cancel(); activityMotionCancellation?.Dispose();
                activityMotionCancellation = new CancellationTokenSource();
                activityMotionKey = key; activityMotionReady = false;
                _ = ApplyActivityMotionAsync(key, motion, (bool?)snapshot["motionRequired"] == true,
                    activityMotionCancellation.Token);
            }
            // Read the actual scene transform, not the authority's requested pose.
            // The parent is the world coordinate frame used by ApplyState.
            var actual = transform.parent != null ? transform.parent.InverseTransformPoint(transform.position) : transform.position;
            return new JObject { ["requestID"] = snapshot["requestID"]?.DeepClone(),
                ["phase"] = phase, ["worldID"] = snapshot["worldID"]?.DeepClone(),
                ["position"] = new JArray(actual.x,actual.y,-actual.z),
                ["positionReady"] = Vector3.Distance(actual,activityTargetPosition) <= .05f,
                ["seatReady"] = seatReady,
                ["seatObjectID"] = activitySeatObjectID,
                ["seatPosition"] = new JArray(localPelvis.x,localPelvis.y,-localPelvis.z),
                ["contactReady"] = contactReady,
                ["contactDistance"] = float.IsFinite(contactDistance) ? contactDistance : -1,
                ["contactPosition"] = new JArray(contactHand.x, contactHand.y, -contactHand.z),
                ["motionReady"] = activityMotionReady && ((bool?)snapshot["motionRequired"] != true || motion != null),
                ["motionPlaying"] = Runtime != null ? Runtime.IsMotionPlaying :
#if GMGN_UNIVRM
                    VrmRuntime != null ? VrmRuntime.IsMotionPlaying :
#endif
                    false,
                ["motionCompleted"] = activityMotionReady && motion != null &&
                    (bool?)motion["loop"] == false && MotionId == (string)motion["id"] &&
                    !(Runtime != null ? Runtime.IsMotionPlaying :
#if GMGN_UNIVRM
                        VrmRuntime != null ? VrmRuntime.IsMotionPlaying :
#endif
                        false),
                ["motionID"] = MotionId };
        }
        void Update()
        {
            if (finiteSelectedMotionID != null && selectedMotionOwnsIdle &&
                LoadedSelectionRevision == finiteSelectedRevision && MotionId == finiteSelectedMotionID) {
                if (IsCurrentMotionPlaying) finiteSelectedWasPlaying = true;
                else if (finiteSelectedWasPlaying) {
                    var completed = finiteSelectedMotionID;
                    finiteSelectedMotionID = null;
                    ManualMotionCompleted?.Invoke(new JObject { ["revision"] = finiteSelectedRevision,
                        ["motionID"] = completed, ["characterID"] = CharacterId });
                }
            }
            if (!hasActivityTarget) return;
            // Authority still owns navigation. This only interpolates displayed
            // transforms between its snapshots; it never writes a new world pose.
            var blend = 1 - Mathf.Exp(-30 * Time.deltaTime);
            transform.localPosition = Vector3.Lerp(transform.localPosition,activityTargetPosition,blend);
            transform.localRotation = Quaternion.Slerp(transform.localRotation,activityTargetRotation,blend);
        }
        async Task ApplyActivityMotionAsync(string key, JObject motion, bool required, CancellationToken cancellation)
        {
            try {
                // World projection can arrive before the asynchronous model
                // selection commits. Its receipt must remain unready until
                // that commit resets the motion key and retries the projection.
                if (CharacterId == null) return;
                // Missing required authority motion is not an explicit reset.
                // Keep the last real clip visible while refusing readiness.
                if (required && (motion == null || (string)motion["format"] == "procedural")) {
                    if (activityMotionKey == key) activityMotionReady = false;
                    return;
                }
                if (motion == null || (string)motion["format"] == "procedural") {
                    if (Runtime != null) Runtime.StopMotion();
#if GMGN_UNIVRM
                    if (VrmRuntime != null) VrmRuntime.StopMotion();
#endif
                } else if (Runtime != null && (string)motion["format"] == "vmd") {
                    await Runtime.PlayMotionAsync(Required(motion,"id"),Required(motion,"path"),
                        (bool?)motion["loop"] ?? true,(float?)motion["playbackRate"] ?? 1,cancellation);
                }
#if GMGN_UNIVRM
                else if (VrmRuntime != null && (string)motion["format"] == "vrma") {
                    await VrmRuntime.PlayMotionAsync(Required(motion,"id"),Required(motion,"path"),
                        (bool?)motion["loop"] ?? true,(float?)motion["playbackRate"] ?? 1,cancellation);
                }
#endif
                else throw new NotSupportedException("活动动作与当前角色不兼容。");
                cancellation.ThrowIfCancellationRequested();
                if (activityMotionKey == key) {
                    activityMotionReady = motion == null ||
                        (string)motion["format"] == "procedural" || MotionId == (string)motion["id"];
                    Debug.Log($"[ResidentMotion] projection={key} character={CharacterId} motion={MotionId} ready={activityMotionReady}");
                }
            } catch (OperationCanceledException) { }
            catch (Exception error) { if(activityMotionKey == key) SetNotice(error.Message); }
        }
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
        void OnDestroy() { seatProjection.Clear(); ++selectionGeneration; activityMotionCancellation?.Cancel();activityMotionCancellation?.Dispose();if (Runtime != null) Runtime.Notice -= SetNotice; }
    }
}
