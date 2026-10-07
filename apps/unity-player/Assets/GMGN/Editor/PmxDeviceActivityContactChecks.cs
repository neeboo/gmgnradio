#if GMGN_UMT
using System;
using System.IO;
using System.Reflection;
using GMGN.UnityPlayer.Characters;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class PmxDeviceActivityContactChecks
    {
        static readonly BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
        static string Entry(string variable) {
            var path = Environment.GetEnvironmentVariable(variable);
            var manifest = JObject.Parse(File.ReadAllText(path));
            return Path.Combine(Path.GetDirectoryName(path),(string)manifest["entry"]);
        }
        public static async void Run()
        {
            GameObject root = null;
            try {
                root = new GameObject("Actual v176 PMX jukebox contact");
                var runtime = root.AddComponent<PmxCharacterRuntime>();
                await runtime.LoadAsync("actual-v176-pmx",Entry("GMGN_UNITY_CHARACTER_MANIFEST"));
                var motionManifest = JObject.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("GMGN_UNITY_MOTION_MANIFEST")));
                // The real package ID selects generated-humanoid retargeting.
                // A fixture-only ID would incorrectly sample raw source VMD.
                await runtime.PlayMotionAsync((string)motionManifest["id"],Entry("GMGN_UNITY_MOTION_MANIFEST"),false);
                root.transform.position = new Vector3(-4.95f,.016619667f,1.54f);
                root.transform.rotation = Quaternion.Euler(0,89.5529f,0);
                var standing = root.transform.position;
                var target = new Vector3(-4.49f,.41706035f,1.54358971f);
                runtime.SetInteractionContact(target);
                var type = typeof(PmxCharacterRuntime);
                var elapsed = type.GetField("elapsed",Private);
                var completed = type.GetField("completed",Private);
                var duration = (float)type.GetField("motionDuration",Private).GetValue(runtime);
                var update = type.GetMethod("Update",Private);
                var late = type.GetMethod("LateUpdate",Private);
                var imported = (UMT.PMXImportResult)type.GetField("imported",Private).GetValue(runtime);
                Transform upper=null,lower=null,hand=null;
                for(var i=0;i<imported.model.bones.Length;i++) {
                    var name=imported.model.bones[i].originalName.ToString();
                    if(name=="右腕")upper=imported.bones[i];
                    if(name=="右ひじ")lower=imported.bones[i];
                    if(name=="右手首")hand=imported.bones[i];
                }
                if(upper==null || lower==null || hand==null)throw new Exception("Actual PMX right arm missing");
                var minimum=float.PositiveInfinity;var authoredMinimum=float.PositiveInfinity;var accepted=false;var pressAccepted=false;
                for(var pass=0;pass<2;pass++) {
                    root.transform.position=standing+Vector3.up*(pass==0?0:2);
                    for(var step=0;step<=200;step++) {
                        completed.SetValue(runtime,false);
                        elapsed.SetValue(runtime,duration*step/200-Time.deltaTime);
                        update.Invoke(runtime,null);
                        var first=Vector3.Distance(upper.position,lower.position);
                        var second=Vector3.Distance(lower.position,hand.position);
                        var authoredOffset=Vector3.Distance(hand.position,target);
                        if(pass==0)authoredMinimum=Mathf.Min(authoredMinimum,authoredOffset);
                        late.Invoke(runtime,null);
                        var ready=runtime.TryReadInteractionContact(out _,out var distance);
                        if(Mathf.Abs(Vector3.Distance(upper.position,lower.position)-first)>.00001f ||
                           Mathf.Abs(Vector3.Distance(lower.position,hand.position)-second)>.00001f)
                            throw new Exception("Contact IK changed arm lengths");
                        if(Vector3.Distance(root.transform.position,standing+Vector3.up*(pass==0?0:2))>.000001f)
                            throw new Exception("Contact IK moved standing position");
                        if(pass==0){
                            if(distance<minimum-.005f)
                                Debug.Log($"[PmxDeviceContactFrame] t={duration*step/200:F4} root={root.transform.position:F4} importScale={imported.root.transform.lossyScale:F4} shoulder={upper.position:F4} elbow={lower.position:F4} hand={hand.position:F4} authoredOffset={authoredOffset:F5} measured={distance:F5} reach={Vector3.Distance(upper.position,target):F5} arm={first+second:F5}");
                            minimum=Mathf.Min(minimum,distance);accepted|=ready;
                            var time=duration*step/200;
                            if(ready && time>=1.54f && time<=1.84f)pressAccepted=true;
                        }
                        else if(ready)throw new Exception("Unreachable raised PMX contact accepted");
                    }
                }
                if(!accepted || !pressAccepted || minimum>.1f)throw new Exception($"Actual PMX contact fails unchanged 10 cm press gate: {minimum:F5}, pressAccepted={pressAccepted}");
                Debug.Log($"[PmxDeviceContact] PASS authoredMinimum={authoredMinimum:F5} actualMinimum={minimum:F5} pressAccepted={pressAccepted}; real finite PMX clip, unchanged standing/bone lengths; raised unreachable rejected");
                UnityEngine.Object.DestroyImmediate(root);EditorApplication.Exit(0);
            } catch(Exception error) {
                Debug.LogException(error);if(root!=null)UnityEngine.Object.DestroyImmediate(root);EditorApplication.Exit(1);
            }
        }
    }
}
#endif
