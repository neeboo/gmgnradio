#if GMGN_UMT
using System;
using System.IO;
using System.Reflection;
using System.Collections.Generic;
using System.Text;
using UnityEditor;
using UnityEngine;
using UMT;
using GMGN.UnityPlayer.Characters;

namespace GMGN.UnityPlayer.Editor
{
    public static class PmxLowerBodyChecks
    {
        public static async void Run()
        {
            GameObject root=null;
            try {
                root=new GameObject("Original 2B lower-body check");
                var runtime=root.AddComponent<PmxCharacterRuntime>();
                var modelPath=Environment.GetEnvironmentVariable("GMGN_PMX_LEG_MODEL");
                var motionPath=Environment.GetEnvironmentVariable("GMGN_PMX_LEG_MOTION");
                await runtime.LoadAsync("pmx.2b-miss-0414-standard",modelPath);
                var flags=BindingFlags.NonPublic|BindingFlags.Instance;
                var imported=(PMXImportResult)typeof(PmxCharacterRuntime).GetField("imported",flags).GetValue(runtime);
                var rigBefore=RigSignature(imported.model);
                var budget=new UMTFrameBudget(double.PositiveInfinity);
                var raw=await VMDReader.ReadAsync(budget,File.ReadAllBytesAsync(motionPath));
                Debug.Log("[PmxLowerBodyChecks] sourceKeys="+raw.boneFrames.Length+" ikToggleFrames="+raw.showIKFrames.Length);
                foreach(var name in new[]{"左足","左ひざ","右足","右ひざ","センター","左足ＩＫ","右足ＩＫ"}) {
                    var keys=0;var rotation=0f;var translation=0f;var first=Quaternion.identity;
                    foreach(var frame in raw.boneFrames)if(frame.boneName.ToString()==name){
                        var q=frame.rotation.value;var current=new Quaternion(q.x,q.y,q.z,q.w);
                        if(keys++==0)first=current;
                        rotation=Mathf.Max(rotation,Quaternion.Angle(first,current));translation=Mathf.Max(translation,((Vector3)frame.position).magnitude);
                    }
                    Debug.Log($"[PmxLowerBodyChecks] source {name} keys={keys} rotationRange={rotation:F3} positionMagnitude={translation:F3}");
                }
                await runtime.PlayMotionAsync("gmgn.motion.bones.jumping-jacks-pmx",motionPath,true);
                var baked=(VMDModelClipData)typeof(PmxCharacterRuntime).GetField("motion",flags).GetValue(runtime);
                var bakedTravel=Sample(imported,baked,"production-baked-IK");
                var rawFk=await VMDReader.ReadAsync(budget,File.ReadAllBytesAsync(motionPath));
                typeof(PmxCharacterRuntime).Assembly.GetType("GMGN.UnityPlayer.Characters.GeneratedHumanoidRetarget",true)
                    .GetMethod("Apply",BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,new object[]{rawFk,imported.model});
                var fk=await VMDAnimationClipConverter.ConvertAsync(budget,rawFk,imported.model,null,new VMDAnimationClipOptions{bakeIKToFK=false,bakePhysicsToFK=false});
                typeof(PmxCharacterRuntime).GetMethod("ResetBones",flags).Invoke(runtime,null);
                var fkTravel=Sample(imported,fk,"comparison-authored-FK");
                if(rigBefore!=RigSignature(imported.model))throw new Exception("Generated clip changed shared model IK rig");
                if(bakedTravel<.05f&&fkTravel>.15f)throw new Exception($"Production lower legs pinned: baked={bakedTravel:F4}m authoredFK={fkTravel:F4}m");
                if(bakedTravel<.05f)throw new Exception("Production feet do not move sufficiently: "+bakedTravel);
                Debug.Log($"[PmxLowerBodyChecks] PASS original 2B jumping jacks production horizontal feet travel={bakedTravel:F4}m authoredFK={fkTravel:F4}m");
                UnityEngine.Object.DestroyImmediate(root);EditorApplication.Exit(0);
            }catch(Exception error){Debug.LogException(error);if(root!=null)UnityEngine.Object.DestroyImmediate(root);EditorApplication.Exit(1);}
        }
        static float Sample(PMXImportResult imported,VMDModelClipData clip,string label)
        {
            var names=new[]{"左足首","右足首","左ひざ","右ひざ","下半身","センター"};
            var tracked=new Dictionary<string,Transform>();
            for(var i=0;i<imported.model.bones.Length;i++)foreach(var name in names)if(imported.model.bones[i].originalName.ToString()==name)tracked[name]=imported.bones[i];
            var targets=new Transform[clip.bones.paths.Length];
            for(var i=0;i<targets.Length;i++)if(!string.IsNullOrEmpty(clip.bones.paths[i]))targets[i]=imported.root.transform.Find(clip.bones.paths[i]);
            var duration=0f;foreach(var curve in clip.bones.curves)if(curve!=null&&curve.length>0)duration=Mathf.Max(duration,curve[curve.length-1].time);
            var bounds=new Dictionary<string,Bounds>();var initial=new Dictionary<string,Quaternion>();var angles=new Dictionary<string,float>();
            for(var frame=0;frame<=120;frame++){
                var t=duration*frame/120;
                for(var i=0;i<targets.Length;i++){
                    var bone=targets[i];if(bone==null)continue;
                    var c=i*(clip.baked?7:6);var p=bone.localPosition;var q=bone.localRotation;
                    float At(int n,float fallback)=>clip.bones.curves[n]?.Evaluate(t)??fallback;
                    bone.localPosition=new Vector3(At(c,p.x),At(c+1,p.y),At(c+2,p.z));
                    if(clip.baked)bone.localRotation=new Quaternion(At(c+3,q.x),At(c+4,q.y),At(c+5,q.z),At(c+6,q.w)).normalized;
                    else {var e=bone.localEulerAngles*Mathf.Deg2Rad;bone.localRotation=Quaternion.Euler(new Vector3(At(c+3,e.x),At(c+4,e.y),At(c+5,e.z))*Mathf.Rad2Deg);}
                }
                foreach(var pair in tracked){
                    if(frame==0){bounds[pair.Key]=new Bounds(pair.Value.position,Vector3.zero);initial[pair.Key]=pair.Value.rotation;angles[pair.Key]=0;}
                    var range=bounds[pair.Key];range.Encapsulate(pair.Value.position);bounds[pair.Key]=range;
                    angles[pair.Key]=Mathf.Max(angles[pair.Key],Quaternion.Angle(initial[pair.Key],pair.Value.rotation));
                }
            }
            var feet=0f;
            foreach(var pair in bounds){
                Debug.Log($"[PmxLowerBodyChecks] {label} {pair.Key} worldTravel={pair.Value.size.magnitude:F4}m xyz={pair.Value.size} rotationRange={angles[pair.Key]:F2}");
                if(pair.Key.EndsWith("足首"))feet=Mathf.Max(feet,new Vector2(pair.Value.size.x,pair.Value.size.z).magnitude);
            }
            return feet;
        }
        public static async void RunAuthoredIK()
        {
            GameObject root=null;
            try {
                root=new GameObject("Original 2B authored IK check");
                var runtime=root.AddComponent<PmxCharacterRuntime>();
                await runtime.LoadAsync("pmx.2b-miss-0414-standard",Environment.GetEnvironmentVariable("GMGN_PMX_LEG_MODEL"));
                // projectPath is not process working directory in batch runs.
                var path=Path.GetFullPath(Path.Combine(Application.dataPath,"../../macos/Resources/MMDMotions/iluvslapbass_motion.vmd"));
                var budget=new UMTFrameBudget(double.PositiveInfinity);
                var original=await VMDReader.ReadAsync(budget,File.ReadAllBytesAsync(path));
                var authoredIK=0;foreach(var frame in original.boneFrames)if(frame.boneName.ToString().Contains("ＩＫ")||frame.boneName.ToString().Contains("IK"))authoredIK++;
                if(authoredIK==0)throw new Exception("Original SlapBass fixture lacks authored IK");
                await runtime.PlayMotionAsync("builtin.motion.iluvslapbass",path,true);
                var flags=BindingFlags.NonPublic|BindingFlags.Instance;
                var imported=(PMXImportResult)typeof(PmxCharacterRuntime).GetField("imported",flags).GetValue(runtime);
                var clip=(VMDModelClipData)typeof(PmxCharacterRuntime).GetField("motion",flags).GetValue(runtime);
                if(!clip.baked)throw new Exception("Original authored IK stopped baking");
                var travel=Sample(imported,clip,"original-SlapBass-authored-IK");
                if(travel<.05f)throw new Exception("Original dance feet lost authored IK travel");
                var rigBefore=RigSignature(imported.model);
                var generatedPath=Environment.GetEnvironmentVariable("GMGN_PMX_LEG_MOTION");
                await runtime.PlayMotionAsync("gmgn.motion.bones.jumping-jacks-pmx",generatedPath,true);
                if(rigBefore!=RigSignature(imported.model))throw new Exception("FK clip permanently changed PMX IK settings");
                await runtime.PlayMotionAsync("builtin.motion.iluvslapbass",path,true);
                var restored=(VMDModelClipData)typeof(PmxCharacterRuntime).GetField("motion",flags).GetValue(runtime);
                if(!restored.baked||restored.bones.curves.Length!=clip.bones.curves.Length)throw new Exception("Original IK clip changed after FK switch");
                for(var c=0;c<clip.bones.curves.Length;c++){
                    var before=clip.bones.curves[c];var after=restored.bones.curves[c];
                    if((before==null)!=(after==null))throw new Exception("Original IK curve disappeared");
                    if(before==null||before.length==0)continue;
                    var end=before[before.length-1].time;
                    for(var sample=0;sample<=5;sample++)if(Mathf.Abs(before.Evaluate(end*sample/5)-after.Evaluate(end*sample/5))>.0001f)
                        throw new Exception("Original IK curve changed after generated FK clip");
                }
                var restoredTravel=Sample(imported,restored,"restored-SlapBass-after-generated-FK");
                if(Mathf.Abs(restoredTravel-travel)>.0001f)throw new Exception("Original dance foot travel changed after FK switch");
                Debug.Log($"[PmxLowerBodyChecks] PASS original SlapBass authoredIKKeys={authoredIK} still baked; feet horizontal travel={travel:F4}m");
                Debug.Log("[PmxLowerBodyChecks] PASS SlapBass -> generated FK -> SlapBass: model IK unchanged and every original curve restored");
                UnityEngine.Object.DestroyImmediate(root);EditorApplication.Exit(0);
            }catch(Exception error){Debug.LogException(error);if(root!=null)UnityEngine.Object.DestroyImmediate(root);EditorApplication.Exit(1);}
        }
        static string RigSignature(PMXModel model)
        {
            var result=new StringBuilder();
            for(var i=0;i<model.bones.Length;i++){
                var bone=model.bones[i];result.Append(i).Append(':').Append((int)bone.flags).Append(';');
                if(bone.ik==null)continue;
                result.Append(bone.ik.targetBoneIndex).Append(',').Append(bone.ik.iterations).Append(',').Append(bone.ik.angleLimit);
                foreach(var link in bone.ik.links)result.Append('|').Append(link.boneIndex).Append(',').Append(link.hasAngleLimit).Append(',').Append(link.lowerLimit).Append(',').Append(link.upperLimit);
            }
            return result.ToString();
        }
    }
}
#endif
