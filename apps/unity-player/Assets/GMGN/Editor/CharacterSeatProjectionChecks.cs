#if UNITY_EDITOR
using System;
using GMGN.UnityPlayer.Characters;
using UnityEditor;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class CharacterSeatProjectionChecks
    {
        public static void Run()
        {
            var root = new GameObject("Seat projection checks");
            try {
                root.transform.position = new Vector3(9,2,-11);
                root.transform.rotation = Quaternion.Euler(0,90,0);
                var content = new GameObject("Actual animated content").transform;
                content.SetParent(root.transform,false);
                var pelvis = new GameObject("Waist bone").transform;
                pelvis.SetParent(content,false);
                pelvis.localPosition = new Vector3(.05f,.47f,-.13f);
                var mesh = new Mesh();
                var vertices = new Vector3[8];
                var weights = new BoneWeight[8];
                for (var i=0;i<8;i++) {
                    vertices[i] = pelvis.localPosition+new Vector3((i%2-.5f)*.02f,-.1f,(i/2%2-.5f)*.02f);
                    weights[i] = new BoneWeight { boneIndex0 = 0,weight0 = 1 };
                }
                mesh.vertices = vertices; mesh.boneWeights = weights;
                mesh.bindposes = new[] { pelvis.worldToLocalMatrix*content.localToWorldMatrix };
                mesh.triangles = new[] {0,1,2,1,3,2};
                var skin = content.gameObject.AddComponent<SkinnedMeshRenderer>();
                skin.sharedMesh = mesh; skin.bones = new[] {pelvis}; skin.rootBone = pelvis;
                var seat = new Vector3(9.32f,2.57f,-11.1f);
                var projection = new CharacterSeatProjection();
                if (!projection.Apply(content,pelvis,seat,out var actual)
                    || Vector3.Distance(actual,seat) > .001f) throw new Exception("Measured pelvis must contact rotated actual seat");
                pelvis.localPosition += new Vector3(0,.02f,.01f);
                if (!projection.Apply(content,pelvis,seat,out actual)
                    || Vector3.Distance(actual,seat) > .001f) throw new Exception("Animated bone change must not drift from sofa");
                projection.Apply(content,pelvis,null,out _);
                if (content.localPosition != Vector3.zero) throw new Exception("Stop must restore original visual approach transform");
                projection.Clear();
                if (content.localPosition != Vector3.zero) throw new Exception("Session retirement must clear seat projection");
                UnityEngine.Object.DestroyImmediate(mesh);
                Debug.Log("PASS: CharacterSeatProjectionChecks measured pelvis, rotated world seat, animated pose and stop cleanup");
                EditorApplication.Exit(0);
            } catch (Exception error) {
                Debug.LogException(error);
                EditorApplication.Exit(1);
            } finally { UnityEngine.Object.DestroyImmediate(root); }
        }
    }
}
#endif
