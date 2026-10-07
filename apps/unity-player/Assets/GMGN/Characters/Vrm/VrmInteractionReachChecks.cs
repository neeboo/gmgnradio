#if GMGN_UNIVRM && UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using UniGLTF;
using UniVRM10;
using UnityEditor;
using UnityEngine;
using Newtonsoft.Json.Linq;

namespace GMGN.UnityPlayer.Characters
{
    // Measure the imported clip on the real normalized character. These are
    // observations, not a substitute for device-space contact verification.
    public static class VrmInteractionReachChecks
    {
        [Serializable] sealed class Manifest { public string id; public string entry; }
        public static async void Run()
        {
            GameObject root = null;
            RuntimeGltfInstance owner = null;
            try {
                var modelPath = Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
                var model = JsonUtility.FromJson<Manifest>(File.ReadAllText(modelPath));
                root = new GameObject("Real character reach measurement");
                var runtime = root.AddComponent<VrmCharacterRuntime>();
                await runtime.LoadAsync(model.id, Path.Combine(Path.GetDirectoryName(modelPath), model.entry), CancellationToken.None);
                var avatar = root.GetComponentInChildren<Vrm10Instance>();
                foreach (var manifestPath in Environment.GetEnvironmentVariable("GMGN_REACH_MOTION_MANIFESTS").Split('|')) {
                    var manifest = JsonUtility.FromJson<Manifest>(File.ReadAllText(manifestPath));
                    using var data = new AutoGltfFileParser(Path.Combine(Path.GetDirectoryName(manifestPath), manifest.entry)).Parse();
                    using var importer = new VrmAnimationImporter(new VrmAnimationData(data));
                    owner = await importer.LoadAsync(new ImmediateCaller());
                    avatar.Runtime.VrmAnimation = owner.GetComponent<Vrm10AnimationInstance>();
                    var clip = owner.GetComponent<Animation>().clip;
                    if (clip == null || clip.length <= 0) throw new Exception("Missing real interaction clip: " + manifest.id);
                    var devicePath = Environment.GetEnvironmentVariable("GMGN_REACH_DEVICE_DECLARATION");
                    GameObject device = null;
                    Transform contact = null;
                    float closest = float.PositiveInfinity, closestTime = 0;
                    HumanBodyBones closestBone = HumanBodyBones.RightHand;
                    bool productionContactAccepted = false;
                    bool pressContactAccepted = false;
                    var firstLegRotation = new Dictionary<HumanBodyBones, Quaternion>();
                    float leftLegDegrees = 0, rightLegDegrees = 0;
                    float hipsMin = float.PositiveInfinity, hipsMax = float.NegativeInfinity;
                    if (!string.IsNullOrEmpty(devicePath)) {
                        // The VRM assembly cannot reference the world assembly.
                        // Use the authored anchors, applying the same source-Z
                        // handedness conversion as the world renderer.
                        var declaration = JObject.Parse(File.ReadAllText(devicePath));
                        device = new GameObject("Authored contact measurement");
                        foreach (var point in declaration["functionPoints"] as JArray ?? new JArray()) {
                            var values = point["position"] as JArray;
                            var anchor = new GameObject("function." + (string)point["role"]);
                            anchor.transform.SetParent(device.transform, false);
                            anchor.transform.localPosition = new Vector3((float)values[0], (float)values[1], -(float)values[2]);
                            anchor.transform.localRotation = Quaternion.Euler(0, -((float?)point["yaw"] ?? 0) * Mathf.Rad2Deg, 0);
                        }
                        var standing = device.transform.Find("function.pickup") ?? device.transform.Find("function.interact");
                        contact = device.transform.Find("function.button") ?? device.transform.Find("function.interact");
                        if (standing == contact) throw new Exception("Standing anchor cannot substitute for hand contact");
                        if (standing == null || contact == null) throw new Exception("Device requires distinct standing/contact anchors");
                        root.transform.SetPositionAndRotation(standing.position, standing.rotation);
                        runtime.SetInteractionContact(contact.position);
                    }
                    Debug.Log($"[InteractionReach] motion={manifest.id} duration={clip.length:F3}");
                    var jumping = manifest.id.Contains("jumping-jacks");
                    var samples = contact == null && !jumping ? 10 : 100;
                    for (int step = 0; step <= samples; step++) {
                        var time = clip.length * step / samples;
                        clip.SampleAnimation(owner.gameObject, time);
                        avatar.Runtime.Process();
                        // Execute the production post-retarget IK, then measure
                        // actual bone transforms. This never relaxes the 10 cm gate.
                        if (contact != null) runtime.ApplyInteractionContactAfterRetarget();
                        if (jumping) {
                            foreach (var leg in new[] { HumanBodyBones.LeftUpperLeg, HumanBodyBones.RightUpperLeg }) {
                                if (!avatar.TryGetBoneTransform(leg, out var actualLeg)) throw new Exception("Missing jumping leg: " + leg);
                                if (!firstLegRotation.ContainsKey(leg)) firstLegRotation[leg] = actualLeg.localRotation;
                                var degrees = Quaternion.Angle(firstLegRotation[leg], actualLeg.localRotation);
                                if (leg == HumanBodyBones.LeftUpperLeg) leftLegDegrees = Mathf.Max(leftLegDegrees, degrees);
                                else rightLegDegrees = Mathf.Max(rightLegDegrees, degrees);
                            }
                            if (!avatar.TryGetBoneTransform(HumanBodyBones.Hips, out var hips)) throw new Exception("Missing jumping hips");
                            var height = root.transform.InverseTransformPoint(hips.position).y;
                            hipsMin = Mathf.Min(hipsMin, height); hipsMax = Mathf.Max(hipsMax, height);
                        }
                        if (contact != null && runtime.TryReadInteractionContact(out var actualHand, out var actualDistance)) {
                            productionContactAccepted = true;
                            if (time >= 1.54f && time <= 1.84f) pressContactAccepted = true;
                            if (actualDistance > .1f || Vector3.Distance(actualHand,contact.position) > .1f)
                                throw new Exception("Production hand receipt does not match actual device contact");
                        }
                        foreach (var bone in new[] { HumanBodyBones.LeftHand, HumanBodyBones.RightHand, HumanBodyBones.Hips,
                            HumanBodyBones.RightIndexDistal, HumanBodyBones.RightMiddleDistal }) {
                            if (!avatar.TryGetBoneTransform(bone, out var transform)) {
                                if (bone == HumanBodyBones.RightIndexDistal || bone == HumanBodyBones.RightMiddleDistal) continue;
                                throw new Exception("Missing interaction bone: " + bone);
                            }
                            var point = root.transform.InverseTransformPoint(transform.position);
                            if (!float.IsFinite(point.x) || !float.IsFinite(point.y) || !float.IsFinite(point.z))
                                throw new Exception("Invalid imported interaction pose");
                            Debug.Log($"[InteractionReach] motion={manifest.id} t={time:F3} bone={bone} position={point:F4}");
                            if (contact != null && bone != HumanBodyBones.LeftHand && bone != HumanBodyBones.Hips) {
                                var distance = Vector3.Distance(transform.position, contact.position);
                                if (distance < closest) { closest = distance; closestTime = time; closestBone = bone; }
                            }
                        }
                    }
                    avatar.Runtime.VrmAnimation = null;
                    if (jumping) {
                        Debug.Log($"[JumpingLegs] motion={manifest.id} leftDegrees={leftLegDegrees:F3} rightDegrees={rightLegDegrees:F3} hipsRangeMeters={hipsMax-hipsMin:F5}");
                        if (leftLegDegrees < 5 || rightLegDegrees < 5) throw new Exception("Actual retargeted jumping legs do not move");
                        if (hipsMax-hipsMin < .01f) throw new Exception("Actual jumping hips height remains glued to ground");
                    }
                    runtime.SetInteractionContact(null);
                    UnityEngine.Object.DestroyImmediate(owner.gameObject); owner = null;
                    if (device != null) {
                        UnityEngine.Object.DestroyImmediate(device);
                        Debug.Log($"[InteractionContact] motion={manifest.id} closestMeters={closest:F4} t={closestTime:F3} bone={closestBone}");
                        if (closest > .1f) throw new Exception("Real hand misses authored device contact by more than 10 cm");
                        if (!productionContactAccepted) throw new Exception("Production RightHand contact receipt never reached the 10 cm gate");
                        if (manifest.id == "gmgn.motion.device.jukebox-low-button-vrm") {
                            if (!pressContactAccepted) throw new Exception("Low-button press phase never contacted real button");
                            Debug.Log("[InteractionContact] PASS low-button press-window real wrist receipt; finite clip sampled to end");
                        }
                    }
                }
                Debug.Log("[InteractionReach] PASS real interaction clips measured on imported character");
                UnityEngine.Object.DestroyImmediate(root); EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error);
                if (owner != null) UnityEngine.Object.DestroyImmediate(owner.gameObject);
                if (root != null) UnityEngine.Object.DestroyImmediate(root);
                EditorApplication.Exit(1);
            }
        }
    }
}
#endif
