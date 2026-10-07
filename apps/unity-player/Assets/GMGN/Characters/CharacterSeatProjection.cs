using UnityEngine;

namespace GMGN.UnityPlayer.Characters
{
    /// The authority capsule remains on the verified approach ground. The
    /// actual animated pelvis, not a guessed character height, locates the
    /// rendered body on the immutable asset's calibrated seat contact.
    public sealed class CharacterSeatProjection
    {
        Transform content;
        Vector3 restingLocalPosition;
        float pelvisClearance;
        bool clearanceMeasured;
        Transform measuredPelvis;

        public void Clear()
        {
            if (content != null) content.localPosition = restingLocalPosition;
            content = null;
            clearanceMeasured = false; measuredPelvis = null;
        }

        public bool Apply(Transform nextContent, Transform pelvis, Vector3? target,
            out Vector3 actualContact)
        {
            actualContact = default;
            if (nextContent != content) {
                Clear();
                if (nextContent != null) {
                    content = nextContent;
                    restingLocalPosition = content.localPosition;
                }
            }
            if (content == null) return false;
            content.localPosition = restingLocalPosition;
            if (!target.HasValue || pelvis == null || !pelvis.IsChildOf(content)) return false;
            var point = target.Value;
            if (!float.IsFinite(point.x) || !float.IsFinite(point.y) || !float.IsFinite(point.z)) return false;
            if (!clearanceMeasured || measuredPelvis != pelvis) {
                if (!TryMeasurePelvisClearance(content,pelvis,out pelvisClearance)) return false;
                clearanceMeasured = true; measuredPelvis = pelvis;
            }
            content.position += point + Vector3.up*pelvisClearance - pelvis.position;
            actualContact = pelvis.position-Vector3.up*pelvisClearance;
            return Vector3.Distance(actualContact, point) <= .01f;
        }

        /// Measure the animated, pelvis-weighted lower body surface once per
        /// seated model, in world metres. No fixed avatar/seat height offset.
        /// The local hip neighbourhood excludes remote skirt hems and feet.
        public static bool TryMeasurePelvisClearance(Transform content, Transform pelvis, out float clearance)
        {
            clearance = 0;
            var lower = float.PositiveInfinity;
            var samples = 0;
            foreach (var skin in content.GetComponentsInChildren<SkinnedMeshRenderer>()) {
                var source = skin.sharedMesh;
                if (source == null) continue;
                var weights = source.boneWeights;
                var bones = skin.bones;
                if (weights.Length == 0) continue;
                var mesh = new Mesh();
                try {
                    skin.BakeMesh(mesh);
                    var vertices = mesh.vertices;
                    for (var i=0;i<vertices.Length && i<weights.Length;i++) {
                        var w = weights[i];
                        bool NearPelvis(int index, float weight) => weight >= .25f && index >= 0 && index < bones.Length
                            && bones[index] != null && (bones[index] == pelvis || bones[index].IsChildOf(pelvis));
                        if (!NearPelvis(w.boneIndex0,w.weight0) && !NearPelvis(w.boneIndex1,w.weight1)
                            && !NearPelvis(w.boneIndex2,w.weight2) && !NearPelvis(w.boneIndex3,w.weight3)) continue;
                        var p = skin.transform.TransformPoint(vertices[i]);
                        var d = p-pelvis.position;
                        if (d.y > 0 || d.y < -.20f || new Vector2(d.x,d.z).magnitude > .20f) continue;
                        lower = Mathf.Min(lower,p.y); ++samples;
                    }
                } finally { if (Application.isPlaying) Object.Destroy(mesh); else Object.DestroyImmediate(mesh); }
            }
            if (samples < 8 || !float.IsFinite(lower)) return false;
            clearance = pelvis.position.y-lower;
            return clearance >= 0 && clearance <= .20f;
        }
    }
}
