using System.IO;
using UnityEngine;

namespace GMGN.UnityPlayer.World
{
    // Calibration refers to original source bounds, not the rotated/normalized
    // presentation bounds. Keep the source frame through asset preparation.
    public sealed class PreparedPropGrip : MonoBehaviour
    {
        Transform content;
        Bounds sourceBounds;
        Vector3[] sourceVertices;
        public void Initialize(Transform source, Bounds bounds)
        {
            content = source; sourceBounds = bounds;
            var vertices=new System.Collections.Generic.List<Vector3>();
            foreach(var mesh in source.GetComponentsInChildren<MeshFilter>(true)) {
                if(mesh.sharedMesh==null||!mesh.sharedMesh.isReadable)continue;
                foreach(var vertex in mesh.sharedMesh.vertices)
                    vertices.Add(source.InverseTransformPoint(mesh.transform.TransformPoint(vertex)));
            }
            sourceVertices=vertices.ToArray();
        }
        public bool TryHandleGeometry(Vector3 normalized,out Vector3 centre,out Vector3 axis,out float radius)
        {
            centre=transform.TransformPoint(LocalPoint(normalized));axis=Vector3.zero;radius=0;
            if(sourceVertices==null||sourceVertices.Length==0)return false;
            var size=sourceBounds.size;
            var component=size.x>=size.y&&size.x>=size.z?0:size.y>=size.z?1:2;
            var length=size[component];
            var transverse=Mathf.Max(size[(component+1)%3],size[(component+2)%3]);
            if(length<transverse*3)return false;
            var direction=Vector3.zero;direction[component]=1;
            axis=content.TransformVector(direction).normalized;
            var native=new Vector3(1-normalized.x,normalized.y,normalized.z);
            var point=sourceBounds.min+Vector3.Scale(size,native);
            var count=0;
            foreach(var vertex in sourceVertices) {
                if(Mathf.Abs(vertex[component]-point[component])>length*.015f)continue;
                radius=Mathf.Max(radius,Vector3.ProjectOnPlane(content.TransformPoint(vertex)-centre,axis).magnitude);count++;
            }
            return count>=12&&float.IsFinite(radius)&&radius>.001f&&radius<.08f;
        }

        public Vector3 LocalPoint(Vector3 normalized)
        {
            if (content == null || !Valid(normalized.x) || !Valid(normalized.y) || !Valid(normalized.z))
                throw new InvalidDataException("物件握持标定无效。");
            // glTFast reflects source X when importing mesh vertices. This is
            // independent of the world-state Z reflection in WorldCoordinates.
            var native = new Vector3(1 - normalized.x, normalized.y, normalized.z);
            var point = sourceBounds.min + Vector3.Scale(sourceBounds.size, native);
            return transform.InverseTransformPoint(content.TransformPoint(point));
        }
        static bool Valid(float value) => float.IsFinite(value) && value >= 0 && value <= 1;
        // Read-only source GLB axis projection. glTFast reflects X on import;
        // content contains the verified orientation and metre normalization.
        public Vector3 LocalDirection(Vector3 rawSourceDirection)
        {
            if (content == null || !float.IsFinite(rawSourceDirection.x) || !float.IsFinite(rawSourceDirection.y)
                || !float.IsFinite(rawSourceDirection.z) || rawSourceDirection.sqrMagnitude < .000001f)
                throw new InvalidDataException("物件源方向无效。");
            var importedDirection = new Vector3(-rawSourceDirection.x, rawSourceDirection.y, rawSourceDirection.z);
            return transform.InverseTransformVector(content.TransformVector(importedDirection)).normalized;
        }
        public void ApplyToBone(Transform bone, Vector3 normalized, Vector3 offset, Quaternion rotation)
        {
            if (bone == null || !float.IsFinite(offset.x) || !float.IsFinite(offset.y) || !float.IsFinite(offset.z)
                || Mathf.Abs(offset.x) > 2 || Mathf.Abs(offset.y) > 2 || Mathf.Abs(offset.z) > 2
                || !float.IsFinite(Quaternion.Dot(rotation, rotation)) || Mathf.Abs(Quaternion.Dot(rotation, rotation) - 1) > .01f)
                throw new InvalidDataException("物件挂点标定无效。");
            var point = LocalPoint(normalized);
            transform.rotation = bone.rotation * rotation;
            transform.position = bone.position + bone.rotation * offset - transform.TransformVector(point);
        }
    }
}
