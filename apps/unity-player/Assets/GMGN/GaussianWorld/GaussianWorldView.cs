using UnityEngine;
using UnityEngine.Rendering;

namespace GMGN.UnityPlayer
{
    public sealed class GaussianWorldView : MonoBehaviour
    {
        public string Status { get; private set; } = "Not loaded";
        GameObject instance;
        public bool ShowCabin()
        {
            if (!SystemInfo.supportsComputeShaders ||
                (SystemInfo.graphicsDeviceType != GraphicsDeviceType.Metal &&
                 SystemInfo.graphicsDeviceType != GraphicsDeviceType.Direct3D12 &&
                 SystemInfo.graphicsDeviceType != GraphicsDeviceType.Vulkan))
            { Status = "Gaussian renderer requires Metal, D3D12 or Vulkan"; Debug.LogError(Status, this); return false; }
            if (instance == null) {
                var prefab = Resources.Load<GameObject>("GaussianWorld/Cabin");
                if (prefab == null) { Status = "Cabin Gaussian asset not prepared"; Debug.LogError(Status, this); return false; }
                instance = Instantiate(prefab, transform);
            }
            instance.SetActive(true);
            Status = "Cabin Gaussian renderer enabled (visual acceptance pending)";
            return true;
        }
        public void Hide() { if (instance != null) instance.SetActive(false); }
        void OnDestroy() { if (instance != null) Destroy(instance); }
    }
}
