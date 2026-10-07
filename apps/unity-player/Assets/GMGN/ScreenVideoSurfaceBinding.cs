using UnityEngine;

namespace GMGN.UnityPlayer
{
    /// Measured display aperture of this immutable receipt-authorized GLB, not the whole prop bounds.
    /// The original mesh combines display, bezel and feet in one primitive/material.
    public static class ScreenVideoSurfaceBinding
    {
        public const string TelevisionAssetID = "sha256:dffb417b8b2e83edf85c44c8ce64d4f04d474e0278764e1da63e02b4320cab54";
        public static bool TryBind(string assetID, Transform prop, out Transform mesh, out Vector3[] corners)
        {
            mesh = null; corners = null;
            if (assetID != TelevisionAssetID || prop == null) return false;
            foreach (var filter in prop.GetComponentsInChildren<MeshFilter>(true)) {
                if (filter.sharedMesh == null || filter.sharedMesh.vertexCount != 14008) continue;
                mesh = filter.transform;
                // glTFast preserves source Z. Native +Z is Unity -Z in the world contract.
                // Stay inside the measured inner bezel and 0.55 mm outside the front skin.
                corners = new[] { new Vector3(-.493f, -.257f, -.5045f), new Vector3(.493f, -.257f, -.5045f),
                    new Vector3(.493f, .3035f, -.5045f), new Vector3(-.493f, .3035f, -.5045f) };
                return true;
            }
            return false;
        }
    }
}
