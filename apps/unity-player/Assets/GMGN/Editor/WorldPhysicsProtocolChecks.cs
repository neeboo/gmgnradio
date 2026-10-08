#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;
namespace GMGN.UnityPlayer.EditorChecks
{
    public static class WorldPhysicsProtocolChecks
    {
        [MenuItem("GMGN/Checks/World Physics Coordinates (No Scene Mutation)")]
        public static void Run()
        {
            foreach (var point in new[] { Vector3.zero,new Vector3(1,2,3),new Vector3(-4,.25f,-9) }) {
                var unity=WorldPhysicsProbeBridge.ToUnity(point);
                if(unity.x!=point.x||unity.y!=point.y||unity.z!=-point.z||WorldPhysicsProbeBridge.ToGameplay(unity)!=point)
                    throw new System.InvalidOperationException("world_physics_coordinate_conversion");
            }
            Debug.Log("PASS production physics coordinate conversion only; no scene/PhysX/audio operation.");
        }
    }
}
#endif
