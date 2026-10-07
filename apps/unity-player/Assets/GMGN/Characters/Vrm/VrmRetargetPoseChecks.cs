#if GMGN_UNIVRM && UNITY_EDITOR
using System;
using System.IO;
using System.Threading;
using UniGLTF;
using UniVRM10;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Characters
{
    public static class VrmRetargetPoseChecks
    {
        [Serializable] sealed class Manifest { public string id; public string entry; }
        // The same imported idle must produce the same model-local pose at any
        // world heading. In particular, facing the camera must not raise the arms.
        public static async void Run()
        {
            GameObject first = null, turned = null;
            RuntimeGltfInstance motionOwner = null;
            try {
                var path = Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
                var manifest = JsonUtility.FromJson<Manifest>(File.ReadAllText(path));
                var motionPath = Environment.GetEnvironmentVariable("GMGN_UNITY_MOTION_MANIFEST");
                var motion = JsonUtility.FromJson<Manifest>(File.ReadAllText(motionPath));
                using var data = new AutoGltfFileParser(Path.Combine(Path.GetDirectoryName(motionPath), motion.entry)).Parse();
                using var importer = new VrmAnimationImporter(new VrmAnimationData(data));
                motionOwner = await importer.LoadAsync(new ImmediateCaller());
                var clip = motionOwner.GetComponent<Animation>().clip;
                var animation = motionOwner.GetComponent<Vrm10AnimationInstance>();
                first = new GameObject("Reference heading");
                turned = new GameObject("Turned world heading");
                turned.transform.rotation = Quaternion.Euler(0, 180, 0);
                var avatars = new Vrm10Instance[2];
                var roots = new[] { first, turned };
                for (int i = 0; i < roots.Length; i++) {
                    var runtime = roots[i].AddComponent<VrmCharacterRuntime>();
                    await runtime.LoadAsync(manifest.id, Path.Combine(Path.GetDirectoryName(path), manifest.entry), CancellationToken.None);
                    avatars[i] = roots[i].GetComponentInChildren<Vrm10Instance>();
                    avatars[i].Runtime.VrmAnimation = animation;
                }
                foreach (var time in new[] { 0f, clip.length * .35f, clip.length * .7f }) {
                    clip.SampleAnimation(motionOwner.gameObject, time);
                    foreach (var avatar in avatars) avatar.Runtime.Process();
                    foreach (var bone in new[] { HumanBodyBones.Head, HumanBodyBones.LeftUpperArm,
                        HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand, HumanBodyBones.RightUpperArm,
                        HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand }) {
                        avatars[0].TryGetBoneTransform(bone, out var a);
                        avatars[1].TryGetBoneTransform(bone, out var b);
                        var localA = first.transform.InverseTransformPoint(a.position);
                        var localB = turned.transform.InverseTransformPoint(b.position);
                        Debug.Log($"[CharacterPoseCheck] t={time:F2} bone={bone} reference={localA:F3} turned={localB:F3}");
                        if (Vector3.Distance(localA, localB) > .005f)
                            throw new Exception($"World heading changed the retargeted {bone} pose by {Vector3.Distance(localA, localB):F3}m.");
                    }
                    foreach (var avatar in avatars) {
                        avatar.TryGetBoneTransform(HumanBodyBones.Head, out var head);
                        foreach (var bone in new[] { HumanBodyBones.LeftHand, HumanBodyBones.RightHand }) {
                            avatar.TryGetBoneTransform(bone, out var hand);
                            if (hand.position.y >= head.position.y)
                                throw new Exception($"Idle {bone} is stuck above the head.");
                        }
                    }
                }
                Debug.Log("[CharacterPoseCheck] PASS real idle at both world headings; hands below head");
                UnityEngine.Object.DestroyImmediate(first); UnityEngine.Object.DestroyImmediate(turned);
                UnityEngine.Object.DestroyImmediate(motionOwner.gameObject); EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error);
                if (first != null) UnityEngine.Object.DestroyImmediate(first);
                if (turned != null) UnityEngine.Object.DestroyImmediate(turned);
                if (motionOwner != null) UnityEngine.Object.DestroyImmediate(motionOwner.gameObject);
                EditorApplication.Exit(1);
            }
        }
    }
}
#endif
