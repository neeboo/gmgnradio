using System;
using System.IO;
using System.Threading;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
namespace GMGN.UnityPlayer.Editor
{
    public static class CharacterSpeechChecks
    {
        public static void RunManualMotionProjection()
        {
            var root = new GameObject("Manual motion projection check");
            try {
                // The world adapter lives in Assembly-CSharp; an asmdef cannot
                // statically reference that assembly. Exercise its real component.
                var adapterType = Type.GetType("GMGN.UnityPlayer.Characters.CharacterWorldAdapter, Assembly-CSharp", true);
                var adapter = root.AddComponent(adapterType);
                var apply = adapterType.GetMethod("ApplyResidentActivity");
                var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance;
                var manual = adapter.GetType().GetField("selectedMotionOwnsIdle", flags);
                var key = adapter.GetType().GetField("activityMotionKey", flags);
                manual.SetValue(adapter, true);
                key.SetValue(adapter, "manual-selection-marker");
                var snapshot = JObject.Parse("{\"agentTransform\":{\"position\":{\"x\":0,\"y\":0,\"z\":0},\"rotation\":{\"x\":0,\"y\":0,\"z\":0,\"w\":1},\"scale\":{\"x\":1,\"y\":1,\"z\":1}},\"requestID\":\"\",\"phase\":\"idle\",\"motion\":{\"id\":\"stale-idle\",\"format\":\"procedural\"}}");
                for (var frame = 0; frame < 120; ++frame) apply.Invoke(adapter, new object[] { snapshot });
                if (!(bool)manual.GetValue(adapter) || (string)key.GetValue(adapter) != "manual-selection-marker")
                    throw new Exception("Idle authority overwrote manual selection");
                snapshot["activeActivity"] = new JObject { ["id"] = "music.listen", ["phase"] = "loop" };
                snapshot["requestID"] = "new-authority-request";
                apply.Invoke(adapter, new object[] { snapshot });
                if ((bool)manual.GetValue(adapter)) throw new Exception("New activity did not regain motion ownership");
                Debug.Log("[ManualMotionProjectionChecks] PASS 120 idle projections preserve manual motion; new activity regains ownership");
                UnityEngine.Object.DestroyImmediate(root); EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error); UnityEngine.Object.DestroyImmediate(root); EditorApplication.Exit(1);
            }
        }
        public static async void Run()
        {
            GameObject root = null;
            UniGLTF.RuntimeGltfInstance motion = null;
            try {
                var manifestPath = Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
                var manifest = JObject.Parse(File.ReadAllText(manifestPath));
                root = new GameObject("Real VRM speech check");
                var runtime = root.AddComponent<GMGN.UnityPlayer.Characters.VrmCharacterRuntime>();
                await runtime.LoadAsync((string)manifest["id"],
                    Path.Combine(Path.GetDirectoryName(manifestPath), (string)manifest["entry"]), CancellationToken.None);
                var avatar = root.GetComponentInChildren<UniVRM10.Vrm10Instance>();
                if (avatar == null) throw new Exception("Real VRM unavailable");
                var attachmentMethod = runtime.GetType().GetMethod("TryGetAttachmentBone");
                if (attachmentMethod == null) throw new Exception("Real VRM attachment slots are not connected");
                foreach (var slot in new[] { "rightHand", "back", "waist" }) {
                    object[] arguments = { slot, null };
                    if (!(bool)attachmentMethod.Invoke(runtime, arguments) || !(arguments[1] is Transform))
                        throw new Exception("Real VRM attachment bone missing: " + slot);
                }
                if (Environment.GetEnvironmentVariable("GMGN_CHECK_ALBEDO_SHADE") == "1") {
                    foreach (var renderer in avatar.GetComponentsInChildren<Renderer>())
                        foreach (var material in renderer.sharedMaterials)
                            if (material.GetTexture("_ShadeTex") != material.GetTexture("_MainTex"))
                                throw new Exception("Converted albedo shade binding was not preserved: " + material.name);
                    Debug.Log("[CharacterSpeech] real imported albedo/shade texture bindings PASS");
                }
                var key = UniVRM10.ExpressionKey.CreateFromPreset(UniVRM10.ExpressionPreset.aa);
                var expression = avatar.Vrm.Expression.Aa;
                if (expression == null || expression.MorphTargetBindings.Length == 0)
                    throw new Exception("Imported avatar has no bound speech morph target");
                foreach (var moving in new[] { false, true }) {
                    if (moving) {
                        // Editor check uses the importer-supported immediate caller;
                        // the production runtime frame scheduler requires play mode.
                        using var data = new UniGLTF.AutoGltfFileParser(Environment.GetEnvironmentVariable("GMGN_SPEECH_CHECK_MOTION")).Parse();
                        using var importer = new UniVRM10.VrmAnimationImporter(new UniVRM10.VrmAnimationData(data));
                        motion = await importer.LoadAsync(new UniGLTF.ImmediateCaller());
                        motion.transform.SetParent(root.transform, false);
                        avatar.Runtime.VrmAnimation = motion.GetComponent<UniVRM10.Vrm10AnimationInstance>();
                        if (avatar.Runtime.VrmAnimation == null) throw new Exception("Real music motion not loaded");
                        var clip = motion.GetComponent<Animation>().clip;
                        clip.SampleAnimation(motion.gameObject, clip.length * .35f);
                    }
                    foreach (var level in new[] { .01f, .03f, .06f, .4f })
                    foreach (var speaking in new[] { true, false }) {
                        var sampleDiagnostic = runtime.GetType().GetMethod("LogSpeechDiagnosticAfterExpression", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
                        if (speaking) for (var silentFrame = 0; silentFrame < 12; ++silentFrame) {
                            runtime.SetSpeechLevel(true, 0f);
                            avatar.Runtime.Process();
                            sampleDiagnostic.Invoke(runtime, null);
                        }
                        runtime.SetSpeechLevel(speaking, level);
                        avatar.Runtime.Process();
                        // Editor has no LateUpdate scheduler; invoke the same
                        // post-UniVRM diagnostic sampler used by the Player.
                        sampleDiagnostic.Invoke(runtime, null);
                        var headMethod = runtime.GetType().GetMethod("TryGetHeadPosition");
                        if (headMethod == null) throw new Exception("Character head projection is fixed-height, not bound to the real head bone");
                        if (!avatar.TryGetBoneTransform(HumanBodyBones.Head, out var headBone)) throw new Exception("Real head bone missing");
                        object[] headArguments = { Vector3.zero };
                        if (!(bool)headMethod.Invoke(runtime, headArguments) ||
                            Vector3.Distance((Vector3)headArguments[0], headBone.position) > .0001f)
                            throw new Exception("Head projection does not follow the current animated head bone");
                        root.transform.SetPositionAndRotation(new Vector3(2, .5f, -3), Quaternion.Euler(0, 135, 0));
                        root.transform.localScale = Vector3.one * .7f;
                        headArguments[0] = Vector3.zero;
                        if (!(bool)headMethod.Invoke(runtime, headArguments) ||
                            Vector3.Distance((Vector3)headArguments[0], headBone.position) > .0001f)
                            throw new Exception("Head projection lost placement rotation or scale");
                        root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
                        root.transform.localScale = Vector3.one;
                        var weight = avatar.Runtime.Expression.GetWeight(key);
                        var expected = speaking ? Mathf.Clamp01(level * 2f) : 0f;
                        if (Mathf.Abs(weight - expected) > .001f)
                            throw new Exception($"Speech weight overwritten: moving={moving} speaking={speaking} weight={weight}");
                        foreach (var binding in expression.MorphTargetBindings) {
                            var skin = avatar.transform.Find(binding.RelativePath).GetComponent<SkinnedMeshRenderer>();
                            var applied = skin.GetBlendShapeWeight(binding.Index);
                            if (Mathf.Abs(applied - expected * binding.Weight * 100f) > .01f)
                                throw new Exception($"Speech morph not applied: moving={moving} speaking={speaking} weight={applied}");
                            Debug.Log($"[CharacterSpeechChecks] moving={moving} speaking={speaking} rawLevel={level:F3} aaTarget={expected:F3} morph={applied:F3}");
                        }
                        if (!speaking && (Mathf.Abs(runtime.SpeechDiagnosticMaxRawLevel - level) > .0001f ||
                            Mathf.Abs(runtime.SpeechDiagnosticMaxAppliedPercent - Mathf.Clamp01(level * 2f) * 100f) > .01f))
                            throw new Exception($"Speech stop summary lost active maxima: raw={runtime.SpeechDiagnosticMaxRawLevel} applied={runtime.SpeechDiagnosticMaxAppliedPercent}");
                    }
                }
                Debug.Log("[CharacterSpeechChecks] PASS real VRM speech morph and animated head anchor; placement rotation/scale preserved; stop clears mouth");
                UnityEngine.Object.DestroyImmediate(root); EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error); if (root != null) UnityEngine.Object.DestroyImmediate(root); EditorApplication.Exit(1);
            }
        }
    }
}
