#if GMGN_UNIVRM
using System;
using System.IO;
using System.Reflection;
using System.Threading;
using GMGN.UnityPlayer.Characters;
using Newtonsoft.Json.Linq;
using UniGLTF;
using UniVRM10;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class ActualDeviceActivityContactChecks
    {
        static readonly BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
        // Exact v162 scene readback: preserve the actual standing position,
        // source quaternion, contact point, normalized avatar and real clip.
        static JObject Activity(bool contact = true, string phase = "enter") => new JObject {
            ["worldID"] = "actual-v162-contact-fixture", ["revision"] = 1,
            ["requestID"] = "actual-v162-jukebox", ["phase"] = phase,
            ["activeActivity"] = new JObject { ["id"] = "music.listen", ["phase"] = phase },
            ["contactRequired"] = contact,
            ["contactTarget"] = new JObject { ["x"] = -4.49f, ["y"] = .41706035f, ["z"] = -1.54358971f },
            ["agentTransform"] = new JObject {
                ["position"] = new JObject { ["x"] = -4.95f, ["y"] = .016619667f, ["z"] = -1.54f },
                ["rotation"] = new JObject { ["x"] = 0, ["y"] = -.9499506f, ["z"] = 0, ["w"] = .31240025f },
                ["scale"] = new JObject { ["x"] = 1, ["y"] = 1, ["z"] = 1 } },
            ["motionRequired"] = false };
        static JObject Motion() {
            var path = Environment.GetEnvironmentVariable("GMGN_REACH_MOTION_MANIFESTS").Split('|')[0];
            var manifest = JObject.Parse(File.ReadAllText(path));
            return new JObject { ["id"] = (string)manifest["id"], ["format"] = "vrma",
                ["path"] = Path.Combine(Path.GetDirectoryName(path),(string)manifest["entry"]),
                ["loop"] = false, ["playbackRate"] = 1 };
        }
        public static async void Run()
        {
            GameObject root = null;
            RuntimeGltfInstance owner = null;
            try {
                var modelPath = Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
                var model = JObject.Parse(File.ReadAllText(modelPath));
                root = new GameObject("Actual v162 contact projection");
                var adapter = root.AddComponent<CharacterWorldAdapter>();
                await adapter.ApplySelectionAsync(new JObject { ["revision"] = 1,
                    ["avatar"] = new JObject { ["id"] = (string)model["id"], ["format"] = "vrm",
                        ["modelPath"] = Path.Combine(Path.GetDirectoryName(modelPath),(string)model["entry"]) } },CancellationToken.None);
                var activity = Activity();
                adapter.ApplyState(new JObject { ["worldID"] = activity["worldID"].DeepClone(),
                    ["revision"] = 0, ["agentTransform"] = activity["agentTransform"].DeepClone() });
                var standing = root.transform.localPosition;
                adapter.ApplyResidentActivity(activity);
                var headingField = typeof(CharacterWorldAdapter).GetField("activityTargetRotation",Private);
                // Measure the stationary pose reached by the production heading
                // target, without introducing a different authored anchor yaw.
                root.transform.localRotation = (Quaternion)headingField.GetValue(adapter);
                var runtime = adapter.VrmRuntime;
                var avatar = root.GetComponentInChildren<Vrm10Instance>();
                // Animation.Play is unavailable in EditMode. Import/sample the
                // same real finite clip as the existing reach fixture; contact
                // readiness still comes solely from production bone geometry.
                var motion = Motion();
                using var data = new AutoGltfFileParser((string)motion["path"]).Parse();
                using var importer = new VrmAnimationImporter(new VrmAnimationData(data));
                // UniGLTF.Utils deliberately is not auto-referenced by the
                // predefined Editor assembly. Keep this fixture's dependency
                // local without changing runtime assembly references.
                var caller = Activator.CreateInstance(Type.GetType("UniGLTF.ImmediateCaller, UniGLTF.Utils",true));
                owner = await (System.Threading.Tasks.Task<RuntimeGltfInstance>)typeof(VrmAnimationImporter)
                    .GetMethod("LoadAsync").Invoke(importer,new object[] {caller,null});
                avatar.Runtime.VrmAnimation = owner.GetComponent<Vrm10AnimationInstance>();
                var clip = owner.GetComponent<Animation>().clip;
                var applyContact = typeof(VrmCharacterRuntime).GetMethod("ApplyInteractionContactAfterRetarget",Private);
                var minimum = float.PositiveInfinity; var minimumTime = -1f;
                var accepted = false; var pressAccepted = false;
                for(int step=0;step<=100;step++) {
                    var time = clip.length*step/100;
                    clip.SampleAnimation(owner.gameObject,time); avatar.Runtime.Process();
                    applyContact.Invoke(runtime,null);
                    var receipt = adapter.ApplyResidentActivity(activity);
                    var distance = (float)receipt["contactDistance"];
                    if(distance>=0 && distance<minimum) {minimum=distance;minimumTime=time;}
                    if((bool)receipt["contactReady"]) {accepted=true;if(time>=1.54f && time<=1.84f)pressAccepted=true;}
                    if(Vector3.Distance(root.transform.localPosition,standing)>.000001f)
                        throw new Exception("Interaction projection moved the authoritative standing position");
                }
                Debug.Log($"[ActualDeviceContact] heading={root.transform.localRotation.eulerAngles.y:F5} minimum={minimum:F5} time={minimumTime:F4} accepted={accepted} pressAccepted={pressAccepted} position={standing:F5}");
                if(!accepted || !pressAccepted || minimum>.1f) throw new Exception("Actual v162 stationary interaction fails the unchanged 10 cm contact gate");
                // Facing a device must not authorize an impossible vertical
                // contact. Use the same real clip/bones at a raised world pose.
                var raised = Activity(); raised["revision"] = 2;
                raised["agentTransform"]["position"]["y"] = standing.y+2;
                root.transform.localPosition = standing+Vector3.up*2;
                adapter.ApplyResidentActivity(raised);
                var raisedMinimum = float.PositiveInfinity;
                for(int step=0;step<=100;step++) {
                    clip.SampleAnimation(owner.gameObject,clip.length*step/100);avatar.Runtime.Process();
                    applyContact.Invoke(runtime,null);
                    var receipt = adapter.ApplyResidentActivity(raised);
                    if((bool)receipt["contactReady"]) throw new Exception("Raised unreachable contact was incorrectly accepted");
                    var distance = (float)receipt["contactDistance"];
                    if(distance>=0)raisedMinimum=Mathf.Min(raisedMinimum,distance);
                }
                Debug.Log($"[ActualDeviceContact] offGroundMinimum={raisedMinimum:F5} contactReady=False");
                root.transform.localPosition = standing;
                foreach(var negative in new[] {Activity(false),Activity(true,"approach")}) {
                    negative["revision"] = 3;
                    adapter.ApplyResidentActivity(negative);
                    var expected = CharacterActivityHeading.Resolve(negative["agentTransform"]["rotation"],(string)negative["phase"]=="approach");
                    if(Quaternion.Angle((Quaternion)headingField.GetValue(adapter),expected)>.001f)
                        throw new Exception("No-contact or navigation heading was altered");
                }
                var moving = Activity(); moving["revision"] = 3; moving["movement"] = new JObject { ["id"] = "actual-route" };
                adapter.ApplyResidentActivity(moving);
                if(Quaternion.Angle((Quaternion)headingField.GetValue(adapter),CharacterActivityHeading.Resolve(moving["agentTransform"]["rotation"],true))>.001f)
                    throw new Exception("Active route heading was altered by interaction target");
                Debug.Log("[ActualDeviceContact] PASS actual v162 standing pose, source yaw, real normalized VRM and finite button clip; no-contact/approach/active-route headings preserved; position unchanged");
                UnityEngine.Object.DestroyImmediate(owner.gameObject);owner=null;
                UnityEngine.Object.DestroyImmediate(root); root=null; EditorApplication.Exit(0);
            } catch(Exception error) {Debug.LogException(error);if(owner!=null)UnityEngine.Object.DestroyImmediate(owner.gameObject);if(root!=null)UnityEngine.Object.DestroyImmediate(root);EditorApplication.Exit(1);}
        }
    }
}
#endif
