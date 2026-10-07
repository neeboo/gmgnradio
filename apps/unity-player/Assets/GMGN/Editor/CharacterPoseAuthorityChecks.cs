using System;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;
using GMGN.UnityPlayer.Characters;

namespace GMGN.UnityPlayer.Editor
{
    public static class CharacterPoseAuthorityChecks
    {
        static JObject Pose(float x)=>JObject.Parse($"{{\"position\":{{\"x\":{x},\"y\":0,\"z\":0}},\"rotation\":{{\"x\":0,\"y\":0,\"z\":0,\"w\":1}},\"scale\":{{\"x\":1,\"y\":1,\"z\":1}}}}");
        public static void Validate()
        {
            var go=new GameObject("activity-pose-authority-fixture");
            try {
                var adapter=go.AddComponent<CharacterWorldAdapter>();
                JObject State(ulong revision,float x)=>new JObject { ["worldID"]="fixture-world",["revision"]=revision,["agentTransform"]=Pose(x) };
                JObject Activity(ulong revision,float x)=>new JObject { ["worldID"]="fixture-world",["revision"]=revision,
                    ["requestID"]="fixture-walk",["phase"]="approach",["activeActivity"]=new JObject { ["phase"]="approach" },["agentTransform"]=Pose(x) };
                adapter.ApplyState(State(1,0));
                adapter.ApplyResidentActivity(Activity(10,5));
                var displayed=new Vector3(1,0,0); go.transform.localPosition=displayed;
                var target=typeof(CharacterWorldAdapter).GetField("hasActivityTarget",BindingFlags.NonPublic|BindingFlags.Instance);
                for(int i=0;i<30;i++) {
                    adapter.ApplyState(State(1,0));
                    if(go.transform.localPosition!=displayed || !(bool)target.GetValue(adapter))
                        throw new Exception("Old durable readback reset the displayed walk pose/target.");
                }
                adapter.ApplyState(State(10,0));
                if(go.transform.localPosition!=displayed || !(bool)target.GetValue(adapter))
                    throw new Exception("Same-revision readback overrode the active projection.");
                if(adapter.ApplyResidentActivity(Activity(9,0))!=null)
                    throw new Exception("Stale activity projection was accepted.");
                adapter.ApplyState(State(20,8));
                if(go.transform.localPosition!=new Vector3(8,0,0) || (bool)target.GetValue(adapter))
                    throw new Exception("Newer authoritative pose did not replace activity target.");
                if(adapter.ApplyResidentActivity(Activity(10,0))!=null)
                    throw new Exception("Old activity reclaimed transform after newer authority readback.");
#if GMGN_UNIVRM
                var animated=new Vector3(3,1.2f,-4); var resting=new Vector3(.1f,.9f,.2f);
                if(VrmCharacterRuntime.NavigationHipsPosition(animated,resting,true)!=new Vector3(.1f,1.2f,.2f))
                    throw new Exception("Navigation did not remove horizontal root displacement while retaining vertical motion.");
                if(VrmCharacterRuntime.NavigationHipsPosition(animated,resting,false)!=animated)
                    throw new Exception("Non-navigation performance translation was modified.");
#endif
                Debug.Log("PASS character pose ownership: stale/same readbacks cannot reset active walk; newer authority wins; VRM navigation-only root XZ suppressed, Y/performance preserved.");
            } finally { UnityEngine.Object.DestroyImmediate(go); }
        }
    }
}
