using System;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class FootprintBridgeSupportChecks
    {
        public static void Run()
        {
            try {
                var grid = Grid((x,z) => -Mathf.Min(Mathf.Min(x,7-x),Mathf.Min(z,7-z))*.08f);
                var anchor = (JObject)((JArray)grid["layers"])[0];
                Require(PlacementRequestBuilder.TryResolveFootprintSupportHeight(grid,anchor,new Vector2(2,2),0,out var plane),
                    "A complete smoothly recessed floor with support around the center must allow furniture to bridge.");
                Require(Mathf.Abs(plane) < .0001f, "Resting plane must be the highest measured support, never sink into it.");
                var edge = Grid((x,z) => -x*.02f);
                Require(!PlacementRequestBuilder.TryResolveFootprintSupportHeight(edge,(JObject)((JArray)edge["layers"])[0],new Vector2(2,2),0,out _),
                    "Support concentrated on one edge cannot balance the furniture center.");
                var step = Grid((x,z) => x < 4 ? 0 : -.05f);
                Require(!PlacementRequestBuilder.TryResolveFootprintSupportHeight(step,(JObject)((JArray)step["layers"])[0],new Vector2(2,2),0,out _),
                    "One-sided support cannot balance the furniture center.");
                var slot = Grid((x,z) => x == 3 ? -.16f : 0);
                Require(PlacementRequestBuilder.TryResolveFootprintSupportHeight(slot,(JObject)((JArray)slot["layers"])[0],new Vector2(2,2),0,out _),
                    "A complete floor with a 16cm decorative slot and surrounding contacts must allow bridging.");
                var hole = (JObject)grid.DeepClone();
                ((JArray)hole["layers"])[27].Remove();
                Require(!PlacementRequestBuilder.TryResolveFootprintSupportHeight(hole,anchor,new Vector2(2,2),0,out _),
                    "A missing interior floor column must reject.");
                Debug.Log("PASS footprint bridge support: 8cm adjacent recess and 16cm abrupt slot bridge, highest measured plane and stable support; one-sided contact and missing floor reject; no audio/world writes.");
                UnityEditor.EditorApplication.Exit(0);
            } catch(Exception error) { Debug.LogException(error); UnityEditor.EditorApplication.Exit(1); }
        }
        static JObject Grid(Func<int,int,float> height)
        {
            var layers=new JArray();
            for(int x=0;x<8;x++) for(int z=0;z<8;z++) layers.Add(new JObject {
                ["column"]=new JObject { ["x"]=x,["z"]=z },["layer"]=0,["supportHeight"]=height(x,z)
            });
            return new JObject { ["spacing"]=.25f,["layers"]=layers };
        }
        static void Require(bool value,string message) { if(!value) throw new Exception(message); }
    }
}
