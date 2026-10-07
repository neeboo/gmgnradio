using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Editor
{
    public static class SofaRestingSupportChecks
    {
        public static async void RunIsolatedRoom()
        {
            var root = new GameObject("read-only-current-room-sofa-probe");
            try {
                var fixture = JObject.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("GMGN_SOFA_FIXTURE")));
                var resolver = new GeneratedAssetResolver((string)fixture["dataRoot"], (string)fixture["worldID"]);
                resolver.SetCatalog((JObject)fixture["catalog"]);
                var loader = new GltfWorldAssetLoader(new GLTFast.UninterruptedDeferAgent());
                var recovered = await new WorldSceneRecovery(loader).RestoreState((JObject)fixture["state"], root.transform,
                    resolver.Resolve, CancellationToken.None, true);
                var items = recovered.ToList();
                Require(items.Count == 6 && items.All(item => item.Instance != null), "All receipt-authorized current generated meshes must recover.");
                foreach (var entry in ((JObject)fixture["state"]["objectStates"]).Properties()) {
                    var raw = (string)entry.Value["metadata"]?["gmgn.builtin-device.v1"];
                    if (raw == null || (bool?)entry.Value["isEnabled"] != true) continue;
                    var declaration = JObject.Parse(raw);
                    var device = BuiltinWorldDevice.CreateMarker(declaration, root.transform);
                    var dimensions = declaration["size"] as JArray;
                    var name = (string)declaration["renderer"] == "builtin.jukebox" ? "jukebox-v1.glb" : "wish-tray-v2.glb";
                    var visual = await loader.LoadSceneAsset(Path.Combine(Environment.GetEnvironmentVariable("GMGN_SOFA_DEVICE_DIRECTORY"), name), CancellationToken.None);
                    visual.transform.SetParent(device.transform, false);
                    BuiltinWorldDevice.FitVisual(visual.transform, new Vector3((float)dimensions[0], (float)dimensions[1], (float)dimensions[2]));
                    device.transform.SetPositionAndRotation(WorldCoordinates.Position(entry.Value["transform"]["position"]), WorldCoordinates.Rotation(entry.Value["transform"]["rotation"]));
                    items.Add(new RecoveryItem { ObjectID = entry.Name, Status = "restored", Instance = device.gameObject });
                }
                var sofa = items.Single(item => item.ObjectID == "wish-prop-72c0e260-3789-4bd7-8fc3-0ecbcb3867b1");
                sofa.Instance.SetActive(true);
                var source = JObject.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("GMGN_SOFA_ROOM_GEOMETRY")));
                var mesh = source["triangles"];
                var triangles = new JArray();
                foreach (JArray face in mesh["indices"])
                    triangles.Add(new JArray(face.Select(index => mesh["vertices"][(int)index].DeepClone())));
                var grid = (JObject)JObject.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("GMGN_SOFA_ROOM_GRID")))["grid"];
                var builder = new PlacementRequestBuilder(grid, triangles, (JArray)source["blockingVolumes"], items);
                if (Environment.GetEnvironmentVariable("GMGN_SOFA_SWEEP") == "1") {
                    await Sweep(builder, grid, sofa, (JObject)fixture["authority"]);
                    UnityEditor.EditorApplication.Exit(0); return;
                }
                var authority = (JObject)fixture["authority"];
                var position = new Vector3(-2.5f, .0134996176f, -5.0648001f);
                var payload = await builder.BuildAsync(sofa.ObjectID, position, Quaternion.identity, authority);
                payload = JObject.Parse(payload.ToString(Newtonsoft.Json.Formatting.None));
                Require(((JArray)payload["placedObstacles"]).Count == 7, "All five placed generated meshes and both current devices must remain obstacles.");
                var size = (JArray)payload["footprint"]["size"];
                Require(Mathf.Abs((float)size[0] - 2) < .00001f && Mathf.Abs((float)size[1] - 1.1296002f) < .00001f
                    && Mathf.Abs((float)payload["height"] - 1.0159059f) < .00001f, "Real sofa size must remain authoritative.");
                var result = await Evaluate(payload);
                Require((bool?)result["canPlace"] == true, "Current room with every actual obstacle must accept the real sofa's shared resting plane.");
                builder.Apply(result, sofa.Instance.transform);
                var bounds = new Bounds(); bool first = true;
                foreach (var renderer in sofa.Instance.GetComponentsInChildren<Renderer>()) {
                    if (first) { bounds = renderer.bounds; first = false; } else bounds.Encapsulate(renderer.bounds);
                }
                var volume = result["volume"];
                float support = (float)volume["center"][1] - (float)volume["halfExtents"][1];
                Require(Mathf.Abs(bounds.min.y - support) < .00001f && Mathf.Abs(bounds.size.x - 2) < .00001f,
                    "Apply must put the real prepared mesh bottom on the accepted plane without changing size.");
                var original = await builder.BuildAsync(sofa.ObjectID, new Vector3(-.75f, -.0181239f, -4.5648001f), Quaternion.identity, authority);
                Require((bool?) (await Evaluate(original))["canPlace"] == false, "The original unsupported footprint must still be rejected.");
                var missing = (JObject)payload.DeepClone();
                var cells = (JArray)missing["grid"]["layers"];
                foreach (var cell in cells.ToArray())
                    if ((int)cell["column"]["x"] == -14 && (int)cell["column"]["z"] == 18) cell.Remove();
                Require((string)(await Evaluate(missing))["reason"]?["code"] == "noSupport", "Missing support must still reject the entire footprint.");
                var step = (JObject)payload.DeepClone();
                foreach (var cell in (JArray)step["grid"]["layers"])
                    if ((int)cell["column"]["x"] == -14 && (int)cell["column"]["z"] == 18) cell["supportHeight"] = support + .05f;
                Require((string)(await Evaluate(step))["reason"]?["code"] == "noSupport", "A five-centimetre step must still reject.");
                var wall = (JObject)payload.DeepClone(); var center = (JArray)volume["center"];
                ((JArray)wall["triangles"]).Add(new JArray(new JArray(center[0],support,center[2]),
                    new JArray(center[0],support + 1,center[2]), new JArray((float)center[0] + .2f,support + .5f,(float)center[2] + .2f)));
                Require((string)(await Evaluate(wall))["reason"]?["code"] == "blockedByMesh", "A wall intersecting the accepted real footprint must still reject.");
                Debug.Log($"PASS actual full current room sofa: six receipt-authorized generated GLBs, two current device visuals, seven obstacle meshes, accepted shared support={support:F8}, full 2x1.1296m footprint, actual mesh Apply/bottom/size, original noSupport, missing support, 5cm step, wall collision; no formal writes/audio.");
                UnityEditor.EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); UnityEditor.EditorApplication.Exit(1); }
            finally { UnityEngine.Object.DestroyImmediate(root); }
        }
        static async Task Sweep(PlacementRequestBuilder builder, JObject grid, RecoveryItem sofa, JObject authority)
        {
            var columns = new[] { (-1,-34), (-14,18), (-7,16), (-4,-20), (-8,-12), (0,-8),
                (-8,-20), (-8,-28), (-4,-28), (0,-28), (-12,12), (-10,18), (-16,18), (-4,12), (0,12) };
            var reasons = new Dictionary<string,int>();
            int checkedCount=0, planes=0, accepted=0;
            var size = new Vector2(1.99999976f,1.12960029f);
            var spacing = (float)grid["spacing"];
            foreach(var column in columns) for(int angle=0;angle<8;angle++) {
                checkedCount++;
                var anchor = ((JArray)grid["layers"]).OfType<JObject>().FirstOrDefault(value =>
                    (int)value["column"]["x"]==column.Item1 && (int)value["column"]["z"]==column.Item2 && (int)value["layer"]==0);
                var yaw = angle*Mathf.PI/4;
                if(anchor==null || !PlacementRequestBuilder.TryResolveFootprintSupportHeight(grid,anchor,size,yaw,out var height)) {
                    reasons["noSharedSupportPlane"] = reasons.TryGetValue("noSharedSupportPlane",out var count) ? count+1 : 1;
                    continue;
                }
                planes++;
                var centerX=column.Item1*spacing+Mathf.Cos(yaw)*size.x/2+Mathf.Sin(yaw)*size.y/2;
                var centerZ=column.Item2*spacing-Mathf.Sin(yaw)*size.x/2+Mathf.Cos(yaw)*size.y/2;
                var payload = await builder.BuildAsync(sofa.ObjectID,new Vector3(centerX,height,-centerZ),
                    Quaternion.Euler(0,-yaw*Mathf.Rad2Deg,0),authority);
                var result=await Evaluate(payload);
                var reason=(bool?)result["canPlace"]==true ? "accepted" : (string)result["reason"]?["code"] ?? "unknown";
                reasons[reason]=reasons.TryGetValue(reason,out var previous) ? previous+1 : 1;
                if(reason=="accepted") accepted++;
                Debug.Log($"[SofaSupportSweep] column=({column.Item1},{column.Item2}) yaw={angle*45} resolvedSupport={height:F8} reason={reason}");
            }
            Debug.Log($"[SofaSupportSweep] checked={checkedCount} sharedPlanes={planes} accepted={accepted} reasons={JObject.FromObject(reasons).ToString(Newtonsoft.Json.Formatting.None)}; real current meshes/obstacles, isolated authority, no formal writes/audio");
        }
        static async Task<JObject> Evaluate(JObject payload)
        {
            var endpoint = JObject.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("GMGN_SOFA_ISOLATED_ENDPOINT")));
            using var client = new HttpClient(new HttpClientHandler { UseProxy = false });
            client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", (string)endpoint["token"]);
            var request = new JObject { ["id"] = Guid.NewGuid().ToString("D"), ["method"] = "placement_evaluate", ["params"] = payload };
            var response = await client.PostAsync("http://" + (string)endpoint["address"] + "/rpc", new StringContent(request.ToString(Newtonsoft.Json.Formatting.None), System.Text.Encoding.UTF8, "application/json"));
            var value = JObject.Parse(await response.Content.ReadAsStringAsync());
            Require(value["error"] == null && value["result"] is JObject, "Isolated authority evaluation must return a valid result.");
            return (JObject)value["result"];
        }
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    }
}
