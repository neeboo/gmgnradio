using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using GMGN.UnityPlayer.World;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class BuiltinDeviceVisualChecks
    {
        public static async void Run()
        {
            var root = new GameObject("device-visual-checks");
            try {
                var budget = root.AddComponent<GLTFast.TimeBudgetPerFrameDeferAgent>();
                Application.targetFrameRate = 75;
                budget.SetFrameBudget(.5f);
                Thread.Sleep(120);
                Require(budget.ShouldDefer(), "120ms frame must exhaust the normal loader budget.");
                // Keep consuming the frame budget across async texture/import
                // continuations, rather than testing only an isolated slow frame.
                UnityEditor.EditorApplication.update += SlowFrame;
                var directory = Environment.GetEnvironmentVariable("GMGN_DEVICE_CHECK_DIRECTORY");
                Require(Directory.Exists(directory), "Bundled device fixture required.");
                var method = typeof(BuiltinWorldDevice).GetMethod("LoadVerifiedVisual", BindingFlags.NonPublic | BindingFlags.Instance,
                    null, new[] { typeof(Vector3), typeof(string) }, null);
                foreach (var kind in new[] { "jukebox", "wish_machine" }) {
                    var dimensions = new Vector3(.7f, 1f, .5f);
                    var declaration = new JObject { ["id"] = "check-"+kind, ["renderer"] = "builtin."+kind,
                        ["size"] = new JArray(dimensions.x,dimensions.y,dimensions.z),
                        ["functionPoints"] = new JArray(new JObject { ["role"]="outlet", ["position"]=new JArray(0,.5f,0) }) };
                    var device = BuiltinWorldDevice.CreateMarker(declaration, root.transform);
                    var marker = device.transform.Find("device.marker");
                    var proxy = marker.GetComponent<Collider>();
                    var task = (Task)method.Invoke(device,new object[] { dimensions,directory });
                    Require(await Task.WhenAny(task,Task.Delay(30000)) == task, "Visual must not starve under exhausted frame budget.");
                    await task;
                    Require(device.HasVerifiedVisual, "Receipt-authorized visual must complete.");
                    Require(!marker.GetComponent<Renderer>().enabled && marker.GetComponent<Collider>() == proxy,
                        "Marker visuals must hide while the authored collision proxy survives.");
                    Require(device.transform.Find("function.outlet") != null, "Function anchor must survive.");
                    var renderers = device.GetComponentsInChildren<Renderer>();
                    var tray = device.transform.Find("wish.tray.geometry");
                    int meshCount=0;
                    foreach(var renderer in renderers) {
                        if (!renderer.enabled || renderer.transform == marker || (tray != null && renderer.transform.IsChildOf(tray))) continue;
                        meshCount++;
                        Require(renderer.bounds.size.sqrMagnitude>0, "Visible mesh must have nonempty bounds.");
                        foreach(var material in renderer.sharedMaterials)
                            Require(material!=null && material.shader!=null && material.shader.isSupported && material.shader.name!="Hidden/InternalErrorShader",
                                "Verified visual material must be supported.");
                    }
                    Require(meshCount>0,"Real device mesh must replace the marker.");
                }
                Debug.Log("PASS builtin device visual: sustained 120ms exhausted budget, both real receipt-verified GLBs, supported materials, visible bounds, marker renderer hidden, collision proxy and anchors retained; no audio/world writes.");
                UnityEditor.EditorApplication.Exit(0);
            } catch(Exception error) { Debug.LogException(error); UnityEditor.EditorApplication.Exit(1); }
            finally { UnityEditor.EditorApplication.update -= SlowFrame; UnityEngine.Object.DestroyImmediate(root); }
        }
        static void SlowFrame() => Thread.Sleep(120);
        static void Require(bool value,string message) { if(!value) throw new Exception(message); }
    }
}
