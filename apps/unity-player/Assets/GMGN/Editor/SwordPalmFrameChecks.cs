#if UNITY_EDITOR && GMGN_UMT
using System;
using System.IO;
using System.Reflection;
using System.Threading;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using GMGN.UnityPlayer.Characters;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Editor
{
    // Read the actual imported palm frame after the authored holding clip.
    // No authority writes, character replacement, playback audio or axis guesses.
    public static class SwordPalmFrameChecks
    {
        public static async void Run()
        {
            GameObject character = null, prop = null;
            GLTFast.GltfImport importer = null;
            try {
                var path = Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
                var manifest = JObject.Parse(File.ReadAllText(path));
                character = new GameObject("Actual holding palm XYZ");
                var runtime = character.AddComponent<PmxCharacterRuntime>();
                await runtime.LoadAsync((string)manifest["id"],
                    Path.Combine(Path.GetDirectoryName(path), (string)manifest["entry"]));
                await runtime.PlayMotionAsync("gmgn.motion.bones.hold-display-pmx",
                    Environment.GetEnvironmentVariable("GMGN_SWORD_HOLD_MOTION"), true);
                var declarationPath = Environment.GetEnvironmentVariable("GMGN_GRIP_PROP_DECLARATION");
                var calibrationPath = Environment.GetEnvironmentVariable("GMGN_GRIP_CALIBRATION");
                var calibration = JObject.Parse(File.ReadAllText(calibrationPath));
                prop = new GameObject("Actual forward-facing sword");
                var content = new GameObject("Source GLB content").transform;
                content.SetParent(prop.transform, false);
                importer = new GLTFast.GltfImport(deferAgent: new GLTFast.UninterruptedDeferAgent());
                if (!await importer.LoadFile(Environment.GetEnvironmentVariable("GMGN_GRIP_PROP_GLB"))
                    || !await importer.InstantiateMainSceneAsync(content)) throw new Exception("Actual sword GLB import failed");
                GltfWorldAssetLoader.Prepare(prop.transform, content,
                    JObject.Parse(File.ReadAllText(declarationPath)));
                var grip = prop.GetComponent<PreparedPropGrip>();
                var normalized = WorldCoordinates.Scale(calibration["normalizedGrip"]);
                var offset = WorldCoordinates.Position(calibration["localOffset"]);
                var rotation = WorldCoordinates.Rotation(calibration["localRotation"]);
                // Source mesh -X is handle→tip, -Y is the inspected cutting edge.
                var tipInProp = grip.LocalDirection(Vector3.left);
                var edgeInProp = grip.LocalDirection(Vector3.down);
                var flags = BindingFlags.Instance | BindingFlags.NonPublic;
                var update = typeof(PmxCharacterRuntime).GetMethod("Update", flags);
                var elapsed = typeof(PmxCharacterRuntime).GetField("elapsed", flags);
                foreach (var time in new[] { 0f, .5f, 1f }) {
                    elapsed.SetValue(runtime, time);
                    update.Invoke(runtime, null);
                    foreach (var yaw in new[] { 0f, 90f, 180f }) {
                        character.transform.rotation = Quaternion.Euler(0, yaw, 0);
                        if (!runtime.TryGetAttachmentBone("rightHand", out var palm))
                            throw new Exception("Actual PMX palm attachment missing");
                        var forward = palm.InverseTransformDirection(character.transform.forward);
                        var up = palm.InverseTransformDirection(character.transform.up);
                        var right = palm.InverseTransformDirection(character.transform.right);
                        var reconstructed = palm.TransformDirection(forward);
                        if (Vector3.Dot(reconstructed.normalized, character.transform.forward) < .99999f)
                            throw new Exception("Body-relative palm frame does not follow character yaw");
                        grip.ApplyToBone(palm, normalized, offset, rotation);
                        if (Vector3.Distance(prop.transform.TransformPoint(grip.LocalPoint(normalized)),
                            palm.position + palm.rotation * offset) > .0001f)
                            throw new Exception("Real sword handle drifts from actual palm");
                        var edgeForward = Vector3.Dot(prop.transform.TransformDirection(edgeInProp), character.transform.forward);
                        var tipUp = Vector3.Dot(prop.transform.TransformDirection(tipInProp), character.transform.up);
                        if (edgeForward < .99f || tipUp < .99f)
                            throw new Exception($"Confirmed cutting edge/tip pose is wrong: forward={edgeForward:F6} up={tipUp:F6}");
                        if (!grip.TryHandleGeometry(normalized, out var centre, out var handleAxis, out var radius))
                            throw new Exception("Actual sword handle cross-section missing");
                        runtime.ApplyHeldFingerPose(centre, handleAxis, radius);
                        if (runtime.HeldFingerContactCount < 3)
                            throw new Exception("New cutting-edge orientation loses actual finger contacts");
                        Debug.Log($"[SwordForwardGrip] t={time:F2} yaw={yaw:F0} cuttingEdgeBodyForward={edgeForward:F6} tipBodyUp={tipUp:F6} contacts={runtime.HeldFingerContactCount}");
                        Debug.Log($"[SwordPalmFrame] t={time:F2} yaw={yaw:F0} bodyForwardInPalm=({forward.x:F7},{forward.y:F7},{forward.z:F7}) bodyUpInPalm=({up.x:F7},{up.y:F7},{up.z:F7}) bodyRightInPalm=({right.x:F7},{right.y:F7},{right.z:F7}) palmQuaternion=({palm.rotation.x:F7},{palm.rotation.y:F7},{palm.rotation.z:F7},{palm.rotation.w:F7})");
                    }
                    character.transform.rotation = Quaternion.identity;
                }
                runtime.ClearHeldFingerPose();
                runtime.TryGetAttachmentBone("rightHand", out var animatedPalm);
                var wrist = animatedPalm.parent;
                var originalWrist = wrist.rotation;
                var edgeInPalm = rotation * edgeInProp;
                for (var frame = 0; frame < 120; frame++) {
                    runtime.ClearHeldFingerPose();
                    wrist.rotation = originalWrist * Quaternion.Euler(frame * .5f, frame, frame * .2f);
                    runtime.TryGetAttachmentBone("rightHand", out animatedPalm);
                    grip.ApplyToBone(animatedPalm, normalized, offset, rotation);
                    if (Vector3.Distance(prop.transform.TransformPoint(grip.LocalPoint(normalized)),
                        animatedPalm.position + animatedPalm.rotation * offset) > .0001f)
                        throw new Exception("Animated XYZ calibration detaches real handle from palm");
                    if (Vector3.Dot(prop.transform.TransformDirection(edgeInProp),
                        animatedPalm.TransformDirection(edgeInPalm)) < .99999f)
                        throw new Exception("Sword cutting edge is locked to world Z instead of following the palm");
                }
                wrist.rotation = originalWrist;
                runtime.ClearHeldFingerPose();
                Debug.Log("PASS actual PMX holding clip, verified GLB cutting edge body-forward and tip-up at 3 times x 3 yaw; actual finger contact, handle XYZ and 120 animated palm projections");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
            finally {
                if (prop != null) UnityEngine.Object.DestroyImmediate(prop);
                importer?.Dispose();
                if (character != null) UnityEngine.Object.DestroyImmediate(character);
            }
        }
    }
}
#endif
