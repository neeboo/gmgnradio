using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.SceneManagement;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer
{
    /// Owned isolated PhysX geometry. No synthetic floor or visual collider mutation.
    public sealed class WorldPhysicsProbeBridge : IDisposable
    {
        Scene scene;
        PhysicsScene physics;
        readonly List<Mesh> meshes = new();
        string world, signature;
        ulong layout, generation;
        bool ready;
        public ulong RegisteredGeneration => generation;
        public static Vector3 ToUnity(Vector3 rightHanded) => new(rightHanded.x, rightHanded.y, -rightHanded.z);
        public static Vector3 ToGameplay(Vector3 unity) => new(unity.x, unity.y, -unity.z);
        static Vector3 Point(JToken token) {
            var p = token is JArray a ? new Vector3((float)a[0], (float)a[1], (float)a[2])
                : new Vector3((float)token["x"], (float)token["y"], (float)token["z"]);
            if (!Finite(p)) throw new InvalidOperationException("world_physics_invalid_probe"); return p;
        }
        static bool Finite(Vector3 p) => float.IsFinite(p.x) && float.IsFinite(p.y) && float.IsFinite(p.z);
        static JObject Value(Vector3 p) => new() { ["x"]=p.x,["y"]=p.y,["z"]=p.z };
        public void Register(string worldID, ulong layoutRevision, string geometrySignature,
            JArray environmentTriangles, Transform presentationRoot, IEnumerable<RecoveryItem> items, string heldObjectID)
        {
            if (ready && signature == geometrySignature && world == worldID && layout == layoutRevision) return;
            ready = false;
            var next = SceneManager.CreateScene("GMGN.Physics." + Guid.NewGuid().ToString("N"),
                new CreateSceneParameters(LocalPhysicsMode.Physics3D));
            var owned = new List<Mesh>();
            try {
                var vertices = new List<Vector3>(); var indices = new List<int>();
                if (environmentTriangles == null || environmentTriangles.Count == 0) throw new InvalidOperationException("world_physics_not_ready");
                foreach (JArray face in environmentTriangles) {
                    if (face.Count != 3) throw new InvalidOperationException("world_physics_invalid_geometry");
                    int start = vertices.Count;
                    foreach (var point in face) vertices.Add(ToUnity(Point(point)));
                    indices.Add(start); indices.Add(start+2); indices.Add(start+1);
                }
                Add(next, "environment", vertices.ToArray(), indices.ToArray(), owned);
                foreach (var item in items) {
                    if (item.ObjectID == heldObjectID || item.Status != "restored") continue;
                    if (item.Instance == null) throw new InvalidOperationException("world_physics_not_ready");
                    var filters = item.Instance.GetComponentsInChildren<MeshFilter>(true);
                    if (filters.Length == 0) throw new InvalidOperationException("world_physics_not_ready");
                    foreach (var filter in filters) {
                        var mesh = filter.sharedMesh;
                        if (mesh == null || !mesh.isReadable) throw new InvalidOperationException("world_physics_not_ready");
                        var matrix = presentationRoot.worldToLocalMatrix * filter.transform.localToWorldMatrix;
                        var points = mesh.vertices;
                        for (int i=0;i<points.Length;i++) { points[i]=matrix.MultiplyPoint3x4(points[i]); if(!Finite(points[i])) throw new InvalidOperationException("world_physics_invalid_geometry"); }
                        Add(next,item.ObjectID,points,mesh.triangles,owned);
                    }
                }
                var nextPhysics = next.GetPhysicsScene();
                if (!nextPhysics.IsValid()) throw new InvalidOperationException("world_physics_not_ready");
                // Flush collider insertion before publishing this atomic geometry generation.
                nextPhysics.Simulate(0.000001f);
                Release(); scene=next;physics=nextPhysics;meshes.AddRange(owned);
                world=worldID;layout=layoutRevision;signature=geometrySignature;generation++;ready=true;
            } catch {
                foreach(var mesh in owned) UnityEngine.Object.Destroy(mesh);
                SceneManager.UnloadSceneAsync(next); throw;
            }
        }
        static void Add(Scene target,string id,Vector3[] points,int[] indices,List<Mesh> owned) {
            if(points.Length==0 || indices.Length==0 || points.Length>2000000) throw new InvalidOperationException("world_physics_invalid_geometry");
            var mesh = new Mesh { indexFormat=UnityEngine.Rendering.IndexFormat.UInt32,name="physics:"+id };
            owned.Add(mesh);mesh.vertices=points;mesh.triangles=indices;mesh.RecalculateBounds();
            var host = new GameObject(id);SceneManager.MoveGameObjectToScene(host,target);
            var collider=host.AddComponent<MeshCollider>();collider.sharedMesh=mesh;collider.convex=false;
        }
        public JObject Measure(JObject request) {
            var reply = new JObject { ["op"]="world.physics.receipt",["requestID"]=request["requestID"],
                ["worldID"]=request["worldID"],["hostSessionID"]=request["hostSessionID"],
                ["layoutRevision"]=request["layoutRevision"],["physicsGeneration"]=request["physicsGeneration"] };
            try {
                if(!ready || (string)request["worldID"]!=world || (ulong?)request["layoutRevision"]!=layout || (ulong?)request["physicsGeneration"]!=generation) throw new InvalidOperationException("world_physics_not_ready");
                var probes=request["probes"] as JArray;
                if(probes==null || probes.Count==0 || probes.Count>1025) throw new InvalidOperationException("world_physics_invalid_probe");
                var keys=new HashSet<string>();var facts=new JArray();
                foreach(JObject probe in probes) {
                    var key=(string)probe["key"];if(string.IsNullOrEmpty(key)||!keys.Add(key)) throw new InvalidOperationException("world_physics_invalid_probe");
                    var point=Point(probe["position"]);var unity=ToUnity(point);
                    float radius=(float)request["capsuleRadius"],height=(float)request["capsuleHeight"];
                    if(!float.IsFinite(radius)||!float.IsFinite(height)||radius<=0||height<2*radius||height>10) throw new InvalidOperationException("world_physics_invalid_probe");
                    bool hit=physics.Raycast(unity+Vector3.up*0.5f,Vector3.down,out var ground,2f,~0,QueryTriggerInteraction.Ignore);
                    JToken grounded=JValue.CreateNull();bool occupiable=false,traversable=false;
                    if(hit) {
                        var target=new Vector3(unity.x,ground.point.y,unity.z);grounded=Value(ToGameplay(target));
                        var bottom=target+Vector3.up*(radius+0.002f);var top=target+Vector3.up*(height-radius);
                        var overlaps=new Collider[1];occupiable=physics.OverlapCapsule(bottom,top,radius,overlaps,~0,QueryTriggerInteraction.Ignore)==0;
                        if(occupiable && probe["from"]!=null) {
                            var from=ToUnity(Point(probe["from"]));var delta=target-from;float distance=delta.magnitude;
                            traversable=distance<=0.000001f || !physics.CapsuleCast(from+Vector3.up*(radius+0.002f),from+Vector3.up*(height-radius),radius,delta/distance,out _,distance,~0,QueryTriggerInteraction.Ignore);
                        }
                    }
                    facts.Add(new JObject { ["key"]=key,["position"]=probe["position"],
                        ["grounded"]=grounded,["occupiable"]=occupiable,["canTraverse"]=traversable,
                        ["groundHit"]=hit,["groundNormal"]=hit?Value(ToGameplay(ground.normal)):JValue.CreateNull(),
                        ["colliderID"]=hit?ground.collider.gameObject.name:null });
                }
                reply["status"]="completed";reply["measurements"]=facts;reply["registeredGeneration"]=generation;
            } catch {reply["status"]="failed";reply["code"]="world_physics_not_ready";}
            return reply;
        }
        void Release() {
            ready=false;if(scene.IsValid()) SceneManager.UnloadSceneAsync(scene);
            foreach(var mesh in meshes) UnityEngine.Object.Destroy(mesh);meshes.Clear();
        }
        public void Dispose()=>Release();
    }
}
