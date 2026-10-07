#if GMGN_UMT && GMGN_UNIVRM
using System;
using System.IO;
using System.Linq;
using Newtonsoft.Json.Linq;
using UniGLTF;
using UniVRM10;
using UnityEditor;
using UnityEngine;
using UMT;

namespace GMGN.UnityPlayer.Editor
{
    // Offline conversion of the original music clip. The player still loads a
    // normal VRMA; no second animation engine or synthetic idle is introduced.
    public static class MmdMusicAnimationExport
    {
        public static async void Run()
        {
            GameObject source = null;
            PMXModel model = null;
            VMDAnimation vmd = null;
            Vrm10Instance target = null;
            Avatar sourceAvatar = null;
            try {
                Debug.Log("[MmdMusicAnimationExport] START");
                var sourcePath = Environment.GetEnvironmentVariable("GMGN_MUSIC_SOURCE_PMX");
                var clipPath = Environment.GetEnvironmentVariable("GMGN_MUSIC_SOURCE_VMD");
                var targetPath = Environment.GetEnvironmentVariable("GMGN_MUSIC_REFERENCE_VRM");
                var output = Environment.GetEnvironmentVariable("GMGN_MUSIC_OUTPUT_VRMA");
                if (!File.Exists(sourcePath) || !File.Exists(clipPath) || !File.Exists(targetPath)
                    || string.IsNullOrWhiteSpace(output)) throw new ArgumentException("Real PMX, VMD, VRM and output paths are required.");
                var budget = new UMTFrameBudget(4);
                using (var stream = File.OpenRead(sourcePath)) model = await PMXReader.ReadAsync(budget, stream, false);
                Debug.Log("[MmdMusicAnimationExport] PMX loaded");
                var resources = AssetDatabase.LoadAssetAtPath<UMTResources>(
                    "Packages/com.candidumgames.unitymmdtools/Resources/UMTResources.asset");
                var renameLists = PMXRenameUtilities.LoadRenameListsJson(resources.GetPMXRenameListsJson());
                await PMXRenameUtilities.RenameAsync(budget, model, renameLists, resources);
                source = new GameObject("Original music skeleton");
                var bones = PMXBoneBuilder.BuildBones(model, source.transform);
                var built = PMXAvatarBuilder.Build(model, source, bones, "Music source", resources);
                sourceAvatar = built.avatar;
                if (!built.hasHumanoidAvatar) throw new InvalidDataException("Original music skeleton is not a valid humanoid.");
                vmd = await VMDReader.ReadAsync(budget, File.ReadAllBytesAsync(clipPath));
                var clip = await VMDAnimationClipConverter.ConvertAsync(budget, vmd, model, null,
                    new VMDAnimationClipOptions { bakeIKToFK = true, bakePhysicsToFK = false });
                Debug.Log("[MmdMusicAnimationExport] VMD converted");
                var targets = clip.bones.paths.Select(path => string.IsNullOrEmpty(path) ? null : source.transform.Find(path)).ToArray();
                if (clip.bones.paths.Where((path, i) => !string.IsNullOrEmpty(path) && targets[i] == null).Any())
                    throw new InvalidDataException("Original motion contains an unbound bone path.");
                var duration = clip.bones.curves.Where(c => c != null && c.length > 0).Max(c => c.keys[^1].time);
                if (!float.IsFinite(duration) || duration <= 0) throw new InvalidDataException("Original motion has no duration.");
                var positions = targets.Select(t => t != null ? t.localPosition : Vector3.zero).ToArray();
                var rotations = targets.Select(t => t != null ? t.localRotation : Quaternion.identity).ToArray();
                target = await Vrm10.LoadPathAsync(targetPath, canLoadVrm0X: true, showMeshes: false);
                Debug.Log("[MmdMusicAnimationExport] VRM loaded");
                var rig = target.Runtime.ControlRig;
                if (rig == null || rig.ControlRigAnimator == null) throw new InvalidDataException("VRM reference has no normalized humanoid rig.");
                var skeleton = rig.GetBoneTransform(HumanBodyBones.Hips).parent;
                var data = new ExportingGltfData();
                using var exporter = new VrmAnimationExporter(data, new GltfExportSettings());
                using var sourcePose = new HumanPoseHandler(sourceAvatar, source.transform);
                using var targetPose = new HumanPoseHandler(rig.ControlRigAnimator.avatar, target.transform);
                var pose = new HumanPose();
                var frameCount = Mathf.CeilToInt(duration * 30) + 1;
                var initialArm = rig.GetBoneTransform(HumanBodyBones.LeftUpperArm).localRotation;
                float maxArmMotion = 0;
                exporter.Prepare(skeleton.gameObject);
                exporter.Export(vrma => {
                    vrma.SetPositionBoneAndParent(rig.GetBoneTransform(HumanBodyBones.Hips), skeleton);
                    foreach (var pair in rig.Bones) {
                        var bone = pair.Value.ControlBone;
                        vrma.AddRotationBoneAndParent(pair.Key, bone, bone.parent);
                    }
                    for (var frame = 0; frame < frameCount; frame++) {
                        var time = Mathf.Min(frame / 30f, duration);
                        for (var i = 0; i < targets.Length; i++) {
                            if (targets[i] == null) continue;
                            var c = i * 7;
                            var p = positions[i]; var q = rotations[i];
                            float Value(int index, float fallback) => clip.bones.curves[index]?.Evaluate(time) ?? fallback;
                            targets[i].localPosition = new Vector3(Value(c, p.x), Value(c + 1, p.y), Value(c + 2, p.z));
                            targets[i].localRotation = new Quaternion(Value(c + 3, q.x), Value(c + 4, q.y), Value(c + 5, q.z), Value(c + 6, q.w)).normalized;
                        }
                        sourcePose.GetHumanPose(ref pose);
                        if (pose.muscles == null || pose.muscles.Any(m => !float.IsFinite(m)))
                            throw new InvalidDataException("Retarget produced invalid humanoid muscles.");
                        targetPose.SetHumanPose(ref pose);
                        maxArmMotion = Mathf.Max(maxArmMotion,
                            Quaternion.Angle(initialArm, rig.GetBoneTransform(HumanBodyBones.LeftUpperArm).localRotation));
                        vrma.AddFrame(TimeSpan.FromSeconds(time));
                    }
                });
                if (maxArmMotion < 10) throw new InvalidDataException("Retarget lost the original arm motion.");
                var bytes = data.ToGlbBytes();
                using (var parsed = new GlbLowLevelParser(output, bytes).Parse()) {
                    var document = JObject.Parse(parsed.Json);
                    if (document["extensions"]?["VRMC_vrm_animation"] == null || document["animations"] == null)
                        throw new InvalidDataException("Export is not a VRM animation.");
                }
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output)));
                File.WriteAllBytes(output, bytes);
                Debug.Log($"[MmdMusicAnimationExport] PASS original clip duration={duration:F3} frames={frameCount} armMotion={maxArmMotion:F2} bytes={bytes.Length}");
                EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error); EditorApplication.Exit(1);
            } finally {
                if (source != null) UnityEngine.Object.DestroyImmediate(source);
                if (sourceAvatar != null) UnityEngine.Object.DestroyImmediate(sourceAvatar);
                if (model != null) UnityEngine.Object.DestroyImmediate(model);
                if (vmd != null) UnityEngine.Object.DestroyImmediate(vmd);
                if (target != null) UnityEngine.Object.DestroyImmediate(target.gameObject);
            }
        }
    }
}
#endif
