using System;
using System.Reflection;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class CompactOrbitChecks
    {
        public static void Verify()
        {
            var go = new GameObject("Compact orbit direction check");
            try {
                var compact = go.AddComponent<UnityCompactWindowController>();
                compact.enabled = false;
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                var pitch = typeof(UnityCompactWindowController).GetField("pitch",flags);
                var yaw = typeof(UnityCompactWindowController).GetField("yaw",flags);
                var drag = typeof(UnityCompactWindowController).GetMethod("ApplyOrbitDrag",flags);
                void Require(bool value,string message) { if (!value) throw new Exception(message); }
                pitch.SetValue(compact,0f); yaw.SetValue(compact,0f);
                drag.Invoke(compact,new object[]{new Vector2(0,10)});
                Require(Mathf.Abs((float)pitch.GetValue(compact)-.08f)<.00001f,"Upward mouse must increase original LiveCam pitch");
                Require(-Mathf.Sin((float)pitch.GetValue(compact))<0,"Upward drag must lower portrait camera relative to target");
                drag.Invoke(compact,new object[]{new Vector2(0,-10)});
                Require(Mathf.Abs((float)pitch.GetValue(compact))<.00001f,"Downward drag must reverse upward drag");
                drag.Invoke(compact,new object[]{new Vector2(10,0)});
                Require(Mathf.Abs((float)yaw.GetValue(compact)-.08f)<.00001f,"Horizontal portrait mapping must remain unchanged");
                drag.Invoke(compact,new object[]{new Vector2(0,1000)});
                Require((float)pitch.GetValue(compact)==.35f,"Upper pitch limit must remain unchanged");
                drag.Invoke(compact,new object[]{new Vector2(0,-1000)});
                Require((float)pitch.GetValue(compact)==-.75f,"Lower pitch limit must remain unchanged");
                Debug.Log("CompactOrbitChecks PASS: up/down original screen-point mapping, horizontal unchanged, pitch limits");
                UnityEngine.Object.DestroyImmediate(go); EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error); UnityEngine.Object.DestroyImmediate(go); EditorApplication.Exit(1);
            }
        }
    }
}
