#if GMGN_UMT
using System.Collections.Generic;
using UnityEngine;
using Unity.Mathematics;
using UMT;

namespace GMGN.UnityPlayer.Characters
{
    // Same generated-motion bind-frame contract as Swift's
    // PMXStageAvatarRenderer.generatedHumanoidAnimationCopy. Apply before
    // UMT bakes append-rotation and IK, so helper bones inherit the adapted pose.
    internal static class GeneratedHumanoidRetarget
    {
        static readonly string[] Names = { "上半身", "上半身2", "首", "左肩", "左腕", "左ひじ", "右肩", "右腕", "右ひじ", "左足", "左ひざ", "右足", "右ひざ" };
        static readonly string[] Children = { "上半身2", "首", "頭", "左腕", "左ひじ", "左手首", "右腕", "右ひじ", "右手首", "左ひざ", "左足首", "右ひざ", "右足首" };
        static readonly string[] Parents = { null, "上半身", "上半身2", "上半身2", "左肩", "左腕", "上半身2", "右肩", "右腕", null, "左足", null, "右足" };
        static readonly Vector3[] SourceDirections = {
            new(0,.08f,0), new(0,.12f,0), new(0,.13f,0),
            new(.06f,0,0), new(.24f,0,0), new(.22f,0,0),
            new(-.06f,0,0), new(-.24f,0,0), new(-.22f,0,0),
            new(0,-.38f,0), new(0,-.42f,0), new(0,-.38f,0), new(0,-.42f,0)
        };

        internal static void Apply(VMDAnimation animation, PMXModel model)
        {
            var positions = new Dictionary<string, Vector3>();
            foreach (var bone in model.bones) positions[bone.originalName.ToString()] = bone.position;
            var bases = new Dictionary<string, Quaternion>();
            var parents = new Dictionary<string, string>();
            for (var i = 0; i < Names.Length; i++) {
                if (!positions.TryGetValue(Names[i], out var position)) continue;
                if (!positions.TryGetValue(Children[i], out var child)) {
                    if (Names[i] != "上半身" || !positions.TryGetValue("上半身b", out child)) continue;
                }
                var direction = child - position;
                if (direction.sqrMagnitude < .000001f) continue;
                // UMT PMX parsing rotates MMD positions 180 degrees around Y.
                var source = SourceDirections[i]; source.x = -source.x; source.z = -source.z;
                bases[Names[i]] = Quaternion.FromToRotation(source.normalized, direction.normalized);
                parents[Names[i]] = Parents[i];
            }
            var adapted = 0;
            for (var i = 0; i < animation.boneFrames.Length; i++) {
                var frame = animation.boneFrames[i];
                var name = frame.boneName.ToString();
                if (!bases.TryGetValue(name, out var basis)) continue;
                var parent = Quaternion.identity;
                if (parents[name] != null && bases.TryGetValue(parents[name], out var value)) parent = value;
                var q = frame.rotation.value;
                var unityDelta = new Quaternion(-q.x, q.y, -q.z, q.w);
                var adaptedDelta = (parent * unityDelta * Quaternion.Inverse(basis)).normalized;
                // VMDReader retains MMD coordinates; converter performs this
                // same involutive Y rotation once when resolving each frame.
                frame.rotation = new quaternion(-adaptedDelta.x, adaptedDelta.y, -adaptedDelta.z, adaptedDelta.w);
                animation.boneFrames[i] = frame;
                adapted++;
            }
            Debug.Log($"[CharacterRetarget] generatedBindFrames={bases.Count} adaptedKeys={adapted}");
        }
    }
}
#endif
