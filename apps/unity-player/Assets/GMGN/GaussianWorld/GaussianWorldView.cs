using UnityEngine;
using UnityEngine.Rendering;
using GaussianSplatting.Runtime;

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
                var composite = Resources.Load<Shader>("GaussianWorld/GuardedGaussianComposite");
                if(composite==null || !composite.isSupported){Status="Guarded Gaussian composite shader unavailable";Debug.LogError(Status,this);return false;}
                // Bind before OnEnable creates renderer materials, without
                // changing the Resources prefab or upstream package files.
                var staging = new GameObject("Gaussian initialization");
                staging.SetActive(false);
                instance = Instantiate(prefab, staging.transform);
                foreach(var renderer in instance.GetComponentsInChildren<GaussianSplatRenderer>(true))renderer.m_ShaderComposite=composite;
                instance.SetActive(false);
                instance.transform.SetParent(transform,false);
                Destroy(staging);
            }
            instance.SetActive(true);
            Status = "Cabin Gaussian renderer enabled (visual acceptance pending)";
            return true;
        }
        public void Hide() { if (instance != null) instance.SetActive(false); }
        void OnDestroy() { if (instance != null) Destroy(instance); }
    }
}
