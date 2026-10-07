#if UNITY_EDITOR && GMGN_UMT
using System;
using System.IO;
using System.Reflection;
using System.Threading;
using Newtonsoft.Json.Linq;
using GMGN.UnityPlayer.Characters;
using GMGN.UnityPlayer.World;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

namespace GMGN.UnityPlayer.Editor
{
    public static class ActualSofaSeatChecks
    {
        static readonly BindingFlags Private = BindingFlags.Instance|BindingFlags.NonPublic;
        public static async void Run()
        {
            GameObject character = null,sofa = null,lampObject = null,cameraObject = null;
            try {
                var manifestPath = Environment.GetEnvironmentVariable("GMGN_UNITY_CHARACTER_MANIFEST");
                var manifest = JObject.Parse(File.ReadAllText(manifestPath));
                var output = Environment.GetEnvironmentVariable("GMGN_SOFA_SEAT_OUTPUT");
                Directory.CreateDirectory(output);
                sofa = await new GltfWorldAssetLoader(new GLTFast.UninterruptedDeferAgent())
                    .LoadSceneAsset(Environment.GetEnvironmentVariable("GMGN_SOFA_GLB"),CancellationToken.None);
                var content = sofa.transform.GetChild(0);
                var declaration = new JObject { ["sizeIntent"] = new JObject { ["axis"] = "longest" },
                    ["size"] = new JObject { ["x"] = 2f,["y"] = 1.0159059f,["z"] = 1.1296002f } };
                GltfWorldAssetLoader.Prepare(sofa.transform,content,declaration);
                var normalization = sofa.transform.Find("Authoritative size");
                if (normalization == null) throw new Exception("Production sofa normalization missing");
                character = new GameObject("Actual 2B seated projection");
                var adapter = character.AddComponent<CharacterWorldAdapter>();
                await adapter.ApplySelectionAsync(new JObject { ["revision"] = 1,
                    ["avatar"] = new JObject { ["id"] = (string)manifest["id"], ["format"] = "pmx",
                        ["modelPath"] = Path.Combine(Path.GetDirectoryName(manifestPath),(string)manifest["entry"]) } },CancellationToken.None);
                var runtime = adapter.Runtime;
                var motionPath = Environment.GetEnvironmentVariable("GMGN_SOFA_SIT_MOTION");
                await runtime.PlayMotionAsync("gmgn.motion.bones.chair-sit-loop-pmx",motionPath,true);
                var visual = runtime.transform;
                var projection = new CharacterSeatProjection();
                var update = typeof(PmxCharacterRuntime).GetMethod("Update",Private);
                var elapsed = typeof(PmxCharacterRuntime).GetField("elapsed",Private);
                RenderSettings.ambientMode = AmbientMode.Flat;
                RenderSettings.ambientLight = new Color(.7f,.7f,.7f);
                lampObject = new GameObject("Seat inspection lamp");
                var lamp = lampObject.AddComponent<Light>();
                lamp.type = LightType.Directional; lamp.intensity = 1.2f;
                lamp.transform.rotation = Quaternion.Euler(30,-30,0);
                cameraObject = new GameObject("Seat inspection camera");
                var camera = cameraObject.AddComponent<Camera>();
                camera.orthographic = true; camera.orthographicSize = 1.8f;
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = new Color(.12f,.14f,.18f);
                camera.nearClipPlane = .001f; camera.farClipPlane = 100;
                var scale = new Vector3(2f/1.006890178f,1.0159059f/.511452764f,1.1296002f/.568691671f);
                foreach (var yaw in new[] {0f,90f,180f}) {
                    projection.Clear();
                    sofa.transform.position = new Vector3(-1,-.008364648f,-.3148002f);
                    sofa.transform.rotation = Quaternion.Euler(0,-yaw,0);
                    // Actual imported glTF raw seat point, through the production
                    // normalization. This is independent of the Swift convention.
                    var contact = normalization.TransformPoint(new Vector3(0,.0335244902f,.16f));
                    var persistentLocal = Vector3.Scale(new Vector3(-.000149548054f,.286568887f,-.160351936f),scale);
                    var sourcePoint = Quaternion.Euler(0,yaw,0)*persistentLocal + new Vector3(-1,-.008364648f,.3148002f);
                    var sourceToken = new JObject { ["x"] = sourcePoint.x,["y"] = sourcePoint.y,["z"] = sourcePoint.z };
                    if (Vector3.Distance(WorldCoordinates.Position(sourceToken),contact) > .001f)
                        throw new Exception("Persistent/source seat reflection does not hit the rendered seat");
                    var approach = normalization.TransformPoint(new Vector3(0,-.2530443966f,.45f));
                    character.transform.position = approach;
                    character.transform.rotation = Quaternion.LookRotation(sofa.transform.forward,Vector3.up);
                    var resting = visual.localPosition;
                    foreach (var time in new[] {0f,.5f,1f}) {
                        elapsed.SetValue(runtime,time); update.Invoke(runtime,null);
                        if (!runtime.TryGetAttachmentBone("waist",out var pelvis)) throw new Exception("Actual 2B animated pelvis unavailable");
                        if (!projection.Apply(visual,pelvis,contact,out var measured)
                            || Vector3.Distance(measured,contact) > .01f)
                            throw new Exception("Actual animated pelvis/body lower surface failed seat contact");
                        if (!CharacterSeatProjection.TryMeasurePelvisClearance(visual,pelvis,out var clearance)
                            || Mathf.Abs(pelvis.position.y-clearance-contact.y) > .01f)
                            throw new Exception("Real skinned pelvis-weighted lower surface does not rest on sofa");
                        Debug.Log($"[ActualSofaSeat] yaw={yaw:F0} t={time:F2} seat={contact:F5} pelvis={pelvis.position:F5} measuredSkinClearance={clearance:F5} bodyContact={measured:F5} boneFacing={character.transform.forward:F3}");
                        if (time == .5f) {
                            var centre = sofa.transform.position+Vector3.up*.85f;
                            SaveView(camera,centre,sofa.transform.forward,Path.Combine(output,$"yaw-{yaw:F0}-front.png"));
                            SaveView(camera,centre,sofa.transform.right,Path.Combine(output,$"yaw-{yaw:F0}-side.png"));
                        }
                    }
                    projection.Apply(visual,null,null,out _);
                    if (visual.localPosition != resting) throw new Exception("Stopping seat leaves visual displaced");
                    projection.Clear();
                }
                Debug.Log("PASS ActualSofaSeatChecks real 2B chair-loop, exact GLB seat, actual skinned contact clearance, source/world reflection, three yaws, three times and exit restoration; silent");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
            finally {
                if (character != null) UnityEngine.Object.DestroyImmediate(character);
                if (sofa != null) UnityEngine.Object.DestroyImmediate(sofa);
                if (lampObject != null) UnityEngine.Object.DestroyImmediate(lampObject);
                if (cameraObject != null) UnityEngine.Object.DestroyImmediate(cameraObject);
            }
        }
        static void SaveView(Camera camera,Vector3 centre,Vector3 axis,string path)
        {
            camera.transform.position = centre+axis*6;
            camera.transform.LookAt(centre,Vector3.up);
            var target = new RenderTexture(1024,1024,24);
            camera.targetTexture = target;
            camera.Render();
            var previous = RenderTexture.active;
            RenderTexture.active = target;
            var texture = new Texture2D(1024,1024,TextureFormat.RGB24,false);
            texture.ReadPixels(new Rect(0,0,1024,1024),0,0); texture.Apply();
            RenderTexture.active = previous;
            File.WriteAllBytes(path,texture.EncodeToPNG());
            camera.targetTexture = null; target.Release();
            UnityEngine.Object.DestroyImmediate(target); UnityEngine.Object.DestroyImmediate(texture);
        }
    }
}
#endif
