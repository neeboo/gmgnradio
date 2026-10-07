#if GMGN_UNIVRM
using System;
using System.Reflection;
using GMGN.UnityPlayer.Characters;
using UniGLTF.SpringBoneJobs.InputPorts;
using UniVRM10;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class VrmSkirtPhysicsChecks
    {
        public static async void Check()
        {
            Vrm10Instance instance = null;
            try {
                var path = Environment.GetEnvironmentVariable("GMGN_SKIRT_VRM");
                var load = typeof(Vrm10).GetMethod("LoadPathAsync", BindingFlags.Public | BindingFlags.Static);
                var parameters = load.GetParameters();
                var arguments = new object[parameters.Length];
                arguments[0] = path;
                for (int i = 1; i < arguments.Length; i++) arguments[i] = parameters[i].DefaultValue;
                instance = await (System.Threading.Tasks.Task<Vrm10Instance>)load.Invoke(null, arguments);
                var spring = instance.Runtime.SpringBone;
                spring.ReconstructSpringBone();
                var before = Measure(spring);
                typeof(VrmCharacterRuntime).GetMethod("NormalizePresentation", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { instance.transform });
                var stale = Measure(spring);
                spring.ReconstructSpringBone();
                var rebuilt = Measure(spring);
                Debug.Log($"[SkirtPhysicsEvidence] scale={instance.transform.localScale.x:F6} dressJoints={before.count} beforeCached={before.cached:F6} beforeGeometry={before.geometry:F6} staleCached={stale.cached:F6} staleGeometry={stale.geometry:F6} rebuiltCached={rebuilt.cached:F6} rebuiltGeometry={rebuilt.geometry:F6}");
                if (before.count < 20 || Math.Abs(before.cached - before.geometry) > .0001f ||
                    stale.geometry / stale.cached < 1.8f || Math.Abs(rebuilt.cached - rebuilt.geometry) > .0001f)
                    throw new InvalidOperationException("Actual Kipfel cached bone-length evidence did not match the scale hypothesis.");
                Debug.Log("PASS: actual Kipfel presentation scaling leaves stale skirt lengths; reconstruction matches scaled geometry.");
                UnityEngine.Object.DestroyImmediate(instance.gameObject); instance = null;
                EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error);
                if (instance != null) UnityEngine.Object.DestroyImmediate(instance.gameObject);
                EditorApplication.Exit(1);
            }
        }
        static (int count, float cached, float geometry) Measure(IVrm10SpringBoneRuntime spring)
        {
            var field = spring.GetType().GetField("m_fastSpringBoneBuffer", BindingFlags.Instance | BindingFlags.NonPublic);
            var buffer = (FastSpringBoneBuffer)field.GetValue(spring);
            int count = 0; float cached = 0, geometry = 0;
            foreach (var logic in buffer.Logics) {
                var head = buffer.Transforms[logic.headTransformIndex];
                if (!head.name.StartsWith("Dress", StringComparison.Ordinal)) continue;
                var tail = buffer.Transforms[logic.tailTransformIndex];
                count++; cached += logic.length; geometry += Vector3.Distance(head.position, tail.position);
            }
            return (count, cached, geometry);
        }
    }
}
#endif
