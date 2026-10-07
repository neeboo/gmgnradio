using System;
using System.IO;
using System.Threading;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using GMGN.UnityPlayer.Characters;

namespace GMGN.UnityPlayer.Editor
{
    public static class CharacterRuntimeChecks
    {
        // The caller provides real installed package manifests. No synthetic
        // replacement clip or model can satisfy these runtime checks.
        public static void Run() => RunChecks(false);
        public static void RunPresentationSize() => RunChecks(true);

        public static void CheckIndependentMovementReleasesIdleSelection()
        {
            var root = new GameObject("Independent movement idle ownership check");
            try {
                var adapter = root.AddComponent<CharacterWorldAdapter>();
                var ownership = typeof(CharacterWorldAdapter).GetField("selectedMotionOwnsIdle",
                    System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                ownership.SetValue(adapter, true);
                var projection = new JObject {
                    ["worldID"]="walk.test", ["revision"]=1, ["requestID"]="",
                    ["movement"]=new JObject { ["destinationID"]="object.television" },
                    ["agentTransform"]=new JObject {
                        ["position"]=new JObject { ["x"]=1,["y"]=0,["z"]=1 },
                        ["rotation"]=new JObject { ["x"]=0,["y"]=0,["z"]=0,["w"]=1 },
                        ["scale"]=new JObject { ["x"]=1,["y"]=1,["z"]=1 } }
                };
                var receipt = adapter.ApplyResidentActivity(projection);
                if ((bool)ownership.GetValue(adapter) || receipt["position"] == null)
                    throw new Exception("Standalone navigation retained the manual idle selection and skipped locomotion projection");
                ownership.SetValue(adapter, true);
                projection["movement"] = JValue.CreateNull();
                adapter.ApplyResidentActivity(projection);
                if (!(bool)ownership.GetValue(adapter))
                    throw new Exception("Stationary idle lost its explicit manual selection");
                Debug.Log("[CharacterRuntimeChecks] PASS navigation overrides manual idle only while actually moving");
            } finally { UnityEngine.Object.DestroyImmediate(root); }
        }

        public static async void RunPmxSpeech()
        {
            GameObject root = null;
            try {
                root = new GameObject("Real PMX speech check");
                var runtime = root.AddComponent<PmxCharacterRuntime>();
                await runtime.LoadAsync("real-pmx-speech-check", Environment.GetEnvironmentVariable("GMGN_PMX_SPEECH_MODEL"));
                var setSpeech = typeof(PmxCharacterRuntime).GetMethod("SetSpeechLevel");
                if (setSpeech == null) throw new Exception("PMX speech playback has no character mouth binding");
                var imported = (UMT.PMXImportResult)typeof(PmxCharacterRuntime).GetField("imported", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic).GetValue(runtime);
                var mouthName = "";
                foreach (var morph in imported.model.morphs)
                    if (morph.originalName.ToString() == "あ") mouthName = morph.renamedName.ToString();
                if (mouthName.Length == 0) {
                    var names = new System.Collections.Generic.List<string>();
                    foreach (var morph in imported.model.morphs) names.Add(morph.originalName.ToString() + "=" + morph.renamedName.ToString());
                    throw new Exception("Original PMX mouth mapping missing: " + string.Join(", ", names));
                }
                foreach (var moving in new[] { false, true }) {
                if (moving) {
                    await runtime.PlayMotionAsync("original-music-speech-check", Environment.GetEnvironmentVariable("GMGN_PMX_SPEECH_MOTION"), true);
                    if (runtime.MotionId != "original-music-speech-check") throw new Exception("Original VMD did not bind after PMX name initialization");
                }
                foreach (var level in new[] { .01f, .03f, .06f, .4f })
                foreach (var playing in new[] { true, false }) {
                    var lateUpdate = typeof(PmxCharacterRuntime).GetMethod("LateUpdate", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                    if (playing) for (var silentFrame = 0; silentFrame < 12; ++silentFrame) {
                        setSpeech.Invoke(runtime, new object[] { true, 0f });
                        lateUpdate.Invoke(runtime, null);
                    }
                    setSpeech.Invoke(runtime, new object[] { playing, level });
                    typeof(PmxCharacterRuntime).GetMethod("Update", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)?.Invoke(runtime, null);
                    typeof(PmxCharacterRuntime).GetMethod("LateUpdate", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)?.Invoke(runtime, null);
                    Transform expectedHead = null;
                    for (var i = 0; i < imported.model.bones.Length; i++)
                        if (imported.model.bones[i].originalName.ToString() == "頭") expectedHead = imported.bones[i];
                    if (expectedHead == null || !runtime.TryGetHeadPosition(out var headPosition) ||
                        Vector3.Distance(headPosition, expectedHead.position) > .0001f)
                        throw new Exception("PMX head projection does not follow the real head bone");
                    var found = false;
                    foreach (var skin in root.GetComponentsInChildren<SkinnedMeshRenderer>()) {
                        var index = skin.sharedMesh.GetBlendShapeIndex(mouthName);
                        if (index < 0) continue;
                        found = true;
                        var weight = skin.GetBlendShapeWeight(index);
                        if (Mathf.Abs(weight - (playing ? Mathf.Clamp01(level * 2f) * 100f : 0)) > .01f)
                            throw new Exception($"PMX mouth did not follow speech playback: playing={playing} weight={weight}");
                        Debug.Log($"[PmxSpeechChecks] moving={moving} playing={playing} rawLevel={level:F3} morph={weight:F3}");
                    }
                    if (!found) throw new Exception("Real PMX has no speech morph");
                    if (!playing && (Mathf.Abs(runtime.SpeechDiagnosticMaxRawLevel - level) > .0001f ||
                        Mathf.Abs(runtime.SpeechDiagnosticMaxAppliedPercent - Mathf.Clamp01(level * 2f) * 100f) > .01f))
                        throw new Exception("PMX speech stop summary lost active maxima after leading silence");
                }
                }
                Debug.Log("[PmxSpeechChecks] PASS real PMX mouth opens and closes during idle and original VMD playback");
                UnityEngine.Object.DestroyImmediate(root); EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error); if (root != null) UnityEngine.Object.DestroyImmediate(root); EditorApplication.Exit(1);
            }
        }


        public static void CheckActivityBeforeCharacterLoaded()
        {
            var root = new GameObject("Activity before character load regression");
            try {
                var adapter = root.AddComponent<CharacterWorldAdapter>();
                var receipt = adapter.ApplyResidentActivity(new JObject {
                    ["worldID"]="test", ["requestID"]="startup", ["phase"]="idle", ["motionRequired"]=true,
                    ["motion"]=new JObject { ["id"]="startup-idle", ["format"]="vrma", ["path"]="/not-loaded-yet" },
                    ["agentTransform"]=new JObject {
                        ["position"]=new JObject { ["x"]=0,["y"]=0,["z"]=0 },
                        ["rotation"]=new JObject { ["x"]=0,["y"]=0,["z"]=0,["w"]=1 },
                        ["scale"]=new JObject { ["x"]=1,["y"]=1,["z"]=1 } }
                });
                if (!string.IsNullOrEmpty(adapter.Notice))
                    throw new Exception("Pending character load was reported as incompatible: " + adapter.Notice);
                if ((bool)receipt["motionReady"] || (bool)receipt["motionPlaying"])
                    throw new Exception("Unloaded character claimed activity readiness");
                Debug.Log("[CharacterRuntimeChecks] PASS pending character load does not report incompatibility or readiness");
            } finally { UnityEngine.Object.DestroyImmediate(root); }
        }

        static async void RunChecks(bool presentationOnly)
        {
            GameObject root=null;
            try {
                var manifestPath=Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
                var manifest=JObject.Parse(File.ReadAllText(manifestPath));
                var engine=(string)manifest["engine"];
                root=new GameObject("Character runtime check");
                var adapter=root.AddComponent<CharacterWorldAdapter>();
                var modelPath=Path.Combine(Path.GetDirectoryName(manifestPath),(string)manifest["entry"]);
                var selection=new JObject { ["revision"]=1,["avatar"]=new JObject{
                    ["id"]=(string)manifest["id"],["format"]=engine,["modelPath"]=modelPath } };
                await adapter.ApplySelectionAsync(selection,CancellationToken.None);
                if(adapter.CharacterId!=(string)manifest["id"] || root.GetComponentsInChildren<Renderer>().Length==0)
                    throw new Exception("Real character did not produce renderer meshes.");
                ValidatePresentationSize(root);
                foreach(var renderer in root.GetComponentsInChildren<Renderer>())foreach(var material in renderer.sharedMaterials)
                    if(material==null || material.shader==null || material.shader.name=="Hidden/InternalErrorShader")
                        throw new Exception("Character material shader is unavailable.");
                if (presentationOnly) {
                    Debug.Log("[CharacterRuntimeChecks] PASS real character presentation height and grounding");
                    UnityEngine.Object.DestroyImmediate(root); EditorApplication.Exit(0); return;
                }
                foreach(var variable in new[]{"GMGN_CHARACTER_CHECK_WALK_MANIFEST","GMGN_UNITY_MOTION_MANIFEST"}) {
                    var path=Environment.GetEnvironmentVariable(variable);
                    if(string.IsNullOrEmpty(path))throw new Exception(variable+" must reference an installed motion.");
                    var motion=JObject.Parse(File.ReadAllText(path));
                    selection["revision"]=(long)selection["revision"]+1;
                    selection["motion"]=new JObject{["id"]=(string)motion["id"],["format"]=(string)motion["format"],
                        ["path"]=Path.Combine(Path.GetDirectoryName(path),(string)motion["entry"]),
                        ["loop"]=true,["playbackRate"]=(float?)motion["playbackRate"]??1};
                    await adapter.ApplySelectionAsync(selection,CancellationToken.None);
                    if(adapter.MotionId!=(string)motion["id"])throw new Exception("Real motion did not bind to the character.");
                    Debug.Log("[CharacterRuntimeChecks] Real motion loaded: "+adapter.MotionId);
                }
                var previous=adapter.MotionId;
                using var cancel=new CancellationTokenSource();cancel.Cancel();
                await adapter.ApplySelectionAsync(selection,cancel.Token);
                if(adapter.MotionId!=previous)throw new Exception("Cancelled selection changed the active motion.");
                selection["motion"]=new JObject{["id"]="invalid-check",["format"]=engine=="pmx"?"vmd":"vrma",["path"]="/missing-character-check-motion"};
                await adapter.ApplySelectionAsync(selection,CancellationToken.None);
                if(adapter.MotionId!=previous)throw new Exception("Failed motion changed the active motion.");
                root.transform.position=new Vector3(1,0,2);
                var projection=adapter.ApplyResidentActivity(new JObject {
                    ["requestID"]="readback-check",["phase"]="approach",["worldID"]="test",["motionRequired"]=true,
                    ["agentTransform"]=new JObject {
                        ["position"]=new JObject{["x"]=5,["y"]=0,["z"]=-6},
                        ["rotation"]=new JObject{["x"]=0,["y"]=0,["z"]=0,["w"]=1},
                        ["scale"]=new JObject{["x"]=1,["y"]=1,["z"]=1} } });
                if((float)projection["position"][0]!=1 || (float)projection["position"][2]!=-2 || (bool)projection["positionReady"])
                    throw new Exception("Projection receipt copied requested target instead of actual scene position.");
                if(adapter.MotionId!=previous || (bool)projection["motionReady"])
                    throw new Exception("Missing required activity motion reset the real clip or claimed readiness.");
                selection.Remove("motion");
                await adapter.ApplySelectionAsync(selection,CancellationToken.None);
                if(adapter.MotionId!=null)throw new Exception("Explicit motion reset did not clear playback.");
                Debug.Log("[CharacterRuntimeChecks] PASS real character/walk/idle/cancel/failure-preservation");
                UnityEngine.Object.DestroyImmediate(root);EditorApplication.Exit(0);
            } catch(Exception error) {
                Debug.LogException(error);if(root!=null)UnityEngine.Object.DestroyImmediate(root);EditorApplication.Exit(1);
            }
        }

        static void ValidatePresentationSize(GameObject root)
        {
            var bounds = new Bounds();
            bool initialized = false;
            var baked = new Mesh();
            try {
                foreach (var skin in root.GetComponentsInChildren<SkinnedMeshRenderer>()) {
                    if (!skin.enabled) continue;
                    baked.Clear();
                    skin.BakeMesh(baked);
                    foreach (var vertex in baked.vertices) {
                        var point = root.transform.InverseTransformPoint(skin.transform.position + skin.transform.rotation * vertex);
                        if (!initialized) { bounds = new Bounds(point, Vector3.zero); initialized = true; }
                        else bounds.Encapsulate(point);
                    }
                }
            } finally { UnityEngine.Object.DestroyImmediate(baked); }
            if (!initialized || Mathf.Abs(bounds.size.y - 1.65f) > .03f || Mathf.Abs(bounds.min.y) > .03f)
                throw new Exception($"Character presentation must be 1.65m tall and grounded: {bounds}");
            Debug.Log($"[CharacterRuntimeChecks] normalized height={bounds.size.y:F4} feet={bounds.min.y:F4}");
        }
    }
}
