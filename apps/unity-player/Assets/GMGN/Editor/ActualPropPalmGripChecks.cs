#if UNITY_EDITOR && GMGN_UMT
using System;
using System.IO;
using System.Threading;
using System.Reflection;
using UMT;
using Newtonsoft.Json.Linq;
using UnityEngine;
using GMGN.UnityPlayer.Characters;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Editor
{
    public static class ActualPropPalmGripChecks
    {
#if GMGN_UNIVRM
        public static async void RunVrm()
        {
            GameObject root=null,prop=null;GLTFast.GltfImport importer=null;
            try {
                var path=Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
                var manifest=JObject.Parse(File.ReadAllText(path));
                root=new GameObject("Actual VRM grasp");var runtime=root.AddComponent<VrmCharacterRuntime>();
                await runtime.LoadAsync((string)manifest["id"],Path.Combine(Path.GetDirectoryName(path),(string)manifest["entry"]),CancellationToken.None);
                prop=new GameObject("Actual source GLB");var content=new GameObject("Model").transform;content.SetParent(prop.transform,false);
                importer=new GLTFast.GltfImport(deferAgent:new GLTFast.UninterruptedDeferAgent());
                if(!await importer.LoadFile(Environment.GetEnvironmentVariable("GMGN_GRIP_PROP_GLB"))||!await importer.InstantiateMainSceneAsync(content))throw new Exception("Actual GLB import failed");
                GltfWorldAssetLoader.Prepare(prop.transform,content,JObject.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("GMGN_GRIP_PROP_DECLARATION"))));
                var calibration=JObject.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("GMGN_GRIP_CALIBRATION")));
                var normalized=WorldCoordinates.Scale(calibration["normalizedGrip"]);var grip=prop.GetComponent<PreparedPropGrip>();
                var avatar=root.GetComponentInChildren<UniVRM10.Vrm10Instance>();
                foreach(var id in new[]{HumanBodyBones.RightIndexProximal,HumanBodyBones.RightIndexIntermediate,HumanBodyBones.RightIndexDistal,
                    HumanBodyBones.RightMiddleProximal,HumanBodyBones.RightMiddleIntermediate,HumanBodyBones.RightMiddleDistal,
                    HumanBodyBones.RightRingProximal,HumanBodyBones.RightRingIntermediate,HumanBodyBones.RightRingDistal,
                    HumanBodyBones.RightLittleProximal,HumanBodyBones.RightLittleIntermediate,HumanBodyBones.RightLittleDistal}) {
                    if(!avatar.TryGetBoneTransform(id,out var bone)){Debug.Log("[VrmFingerBone] missing="+id);continue;}
                    Debug.Log($"[VrmFingerBone] bone={id} name={bone.name} pos={bone.position:F5} children={bone.childCount}");
                    foreach(var skin in avatar.GetComponentsInChildren<SkinnedMeshRenderer>()) {
                        var index=Array.IndexOf(skin.bones,bone);if(index<0)continue;
                        var count=0;foreach(var w in skin.sharedMesh.boneWeights)
                            if((w.boneIndex0==index&&w.weight0>.35f)||(w.boneIndex1==index&&w.weight1>.35f)||(w.boneIndex2==index&&w.weight2>.35f)||(w.boneIndex3==index&&w.weight3>.35f))count++;
                        Debug.Log($"[VrmFingerBone] mesh={skin.name} weighted={count}");
                    }
                }
                var poses=new System.Collections.Generic.Dictionary<Transform,Quaternion>();
                foreach(var id in new[]{HumanBodyBones.RightIndexProximal,HumanBodyBones.RightIndexIntermediate,HumanBodyBones.RightIndexDistal,
                    HumanBodyBones.RightMiddleProximal,HumanBodyBones.RightMiddleIntermediate,HumanBodyBones.RightMiddleDistal,
                    HumanBodyBones.RightRingProximal,HumanBodyBones.RightRingIntermediate,HumanBodyBones.RightRingDistal,
                    HumanBodyBones.RightLittleProximal,HumanBodyBones.RightLittleIntermediate,HumanBodyBones.RightLittleDistal})
                    if(avatar.TryGetBoneTransform(id,out var bone))poses.Add(bone,bone.localRotation);
                for(var frame=0;frame<120;frame++) {
                    runtime.ClearHeldFingerPose();
                    if(!runtime.TryGetAttachmentBone("rightHand",out var palm))throw new Exception("Actual VRM palm missing");
                    palm.parent.rotation=Quaternion.Euler(frame*.5f,frame,frame*.2f);
                    grip.ApplyToBone(palm,normalized,WorldCoordinates.Position(calibration["localOffset"]),WorldCoordinates.Rotation(calibration["localRotation"]));
                    if(!grip.TryHandleGeometry(normalized,out var centre,out var axis,out var radius))throw new Exception("Actual handle geometry missing");
                    runtime.ApplyHeldFingerPose(centre,axis,radius);
                    if(frame==0) {
                        Debug.Log($"[ActualVrmFingerGrip] radius={radius:F5} contacts={runtime.HeldFingerContactCount} maxError={runtime.HeldFingerMaximumContactError:F5}");
                        foreach(var result in runtime.HeldFingerDiagnostics)Debug.Log("[ActualVrmFingerGrip] "+result);
                    }
                    if(runtime.HeldFingerContactCount<3)throw new Exception("Actual VRM fingers do not contact measured handle");
                }
                runtime.ClearHeldFingerPose();
                foreach(var pose in poses)if(Quaternion.Angle(pose.Key.localRotation,pose.Value)>.01f)throw new Exception("Released VRM finger layer persists");
                Debug.Log("[ActualVrmFingerGrip] PASS real avatar fingers, real GLB handle, 120 hand projections, release restores authored pose");
                UnityEditor.EditorApplication.Exit(0);
            }catch(Exception error){Debug.LogException(error);UnityEditor.EditorApplication.Exit(1);}
            finally{if(prop!=null)UnityEngine.Object.DestroyImmediate(prop);importer?.Dispose();if(root!=null)UnityEngine.Object.DestroyImmediate(root);}
        }
#endif
        public static async void Run()
        {
            GameObject character = null, prop = null;
            GLTFast.GltfImport importer = null;
            try {
                var manifestPath = Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
                var manifest = JObject.Parse(File.ReadAllText(manifestPath));
                character = new GameObject("Actual hand rig");
                var runtime = character.AddComponent<PmxCharacterRuntime>();
                await runtime.LoadAsync((string)manifest["id"],Path.Combine(Path.GetDirectoryName(manifestPath),(string)manifest["entry"]));
                if (!runtime.TryGetAttachmentBone("rightHand",out var palm) || palm.parent == null)
                    throw new Exception("Actual PMX requires anatomical palm attachment");
                var wrist = palm.parent;
                Transform middle = null;
                var imported = (PMXImportResult)typeof(PmxCharacterRuntime).GetField("imported",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(runtime);
                for (var index=0;index<imported.model.bones.Length;index++)
                    if (imported.model.bones[index].originalName.ToString() == "右中指１") { middle=imported.bones[index];break; }
                if (middle == null) throw new Exception("Actual middle-finger proximal joint missing");
                if (Vector3.Distance(palm.position,(wrist.position+middle.position)*.5f)>.0001f)
                    throw new Exception("Palm attachment is not at anatomical centre");
                if (Vector3.Distance(palm.position,wrist.position)<.01f)
                    throw new Exception("Palm attachment remains at wrist");
                var declaration = JObject.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("GMGN_GRIP_PROP_DECLARATION")));
                prop = new GameObject("Actual source GLB");
                var content = new GameObject("Model").transform;
                content.SetParent(prop.transform,false);
                // Editor fixture uses an immediate defer agent; runtime's
                // frame-budget component requires a running player scene.
                importer = new GLTFast.GltfImport(deferAgent:new GLTFast.UninterruptedDeferAgent());
                if (!await importer.LoadFile(Environment.GetEnvironmentVariable("GMGN_GRIP_PROP_GLB")) ||
                    !await importer.InstantiateMainSceneAsync(content)) throw new Exception("Actual GLB import failed");
                GltfWorldAssetLoader.Prepare(prop.transform,content,declaration);
                var calibration = JObject.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("GMGN_GRIP_CALIBRATION")));
                var normalized = WorldCoordinates.Scale(calibration["normalizedGrip"]);
                var grip = prop.GetComponent<PreparedPropGrip>();
                var fingerRotations=new System.Collections.Generic.Dictionary<Transform,Quaternion>();
                for(var index=0;index<imported.model.bones.Length;index++) {
                    var name=imported.model.bones[index].originalName.ToString();
                    if(name.StartsWith("右人指")||name.StartsWith("右中指")||name.StartsWith("右薬指")||name.StartsWith("右小指"))
                        fingerRotations.Add(imported.bones[index],imported.bones[index].localRotation);
                }
                for (var frame=0;frame<120;frame++) {
                    runtime.ClearHeldFingerPose();
                    wrist.rotation=Quaternion.Euler(frame*.5f,frame,frame*.2f);
                    runtime.TryGetAttachmentBone("rightHand",out palm);
                    grip.ApplyToBone(palm,normalized,WorldCoordinates.Position(calibration["localOffset"]),WorldCoordinates.Rotation(calibration["localRotation"]));
                    var projected=prop.transform.TransformPoint(grip.LocalPoint(normalized));
                    var expected=palm.position+palm.rotation*WorldCoordinates.Position(calibration["localOffset"]);
                    if (Vector3.Distance(projected,expected)>.0001f) throw new Exception("Actual mesh handle drifts from palm");
                    if(!grip.TryHandleGeometry(normalized,out var centre,out var axis,out var radius))
                        throw new Exception("Actual handle cross-section could not be measured");
                    runtime.ApplyHeldFingerPose(centre,axis,radius);
                    if(frame==0) {
                        Debug.Log($"[ActualFingerGrip] radius={radius:F5} contacts={runtime.HeldFingerContactCount} maxError={runtime.HeldFingerMaximumContactError:F5}");
                        foreach(var result in runtime.HeldFingerDiagnostics)Debug.Log("[ActualFingerGrip] "+result);
                    }
                    if(runtime.HeldFingerContactCount<3)throw new Exception("Actual fingers do not contact measured handle");
                }
                runtime.ClearHeldFingerPose();
                foreach(var pair in fingerRotations)
                    if(Quaternion.Angle(pair.Key.localRotation,pair.Value)>.01f)throw new Exception("Released grip retains transient finger pose");
                Debug.Log("[ActualPalmGrip] PASS real PMX joints, real GLB source grip, 120 rotated hand projections; palm-wrist="+Vector3.Distance(palm.position,wrist.position));
                UnityEditor.EditorApplication.Exit(0);
            } catch(Exception error) { Debug.LogException(error);UnityEditor.EditorApplication.Exit(1); }
            finally { if(prop!=null)UnityEngine.Object.DestroyImmediate(prop);importer?.Dispose();if(character!=null)UnityEngine.Object.DestroyImmediate(character); }
        }
    }
}
#endif
