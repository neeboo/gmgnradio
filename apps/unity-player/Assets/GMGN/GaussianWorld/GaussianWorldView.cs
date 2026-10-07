using UnityEngine;
using UnityEngine.Rendering;
using GaussianSplatting.Runtime;
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using GMGN.UnityPlayer.World;
using Newtonsoft.Json.Linq;

namespace GMGN.UnityPlayer
{
    public sealed class GaussianWorldView : MonoBehaviour
    {
        public string Status { get; private set; } = "Not loaded";
        GameObject instance;
        GaussianSplatRenderer[] renderers;
        bool drawing;
        RuntimeMarbleSplatLoader.RuntimeAsset runtimeAsset;
        public static bool FormalMarbleSupported {
            get {
                if (!SystemInfo.supportsComputeShaders ||
                    (SystemInfo.graphicsDeviceType != GraphicsDeviceType.Metal && SystemInfo.graphicsDeviceType != GraphicsDeviceType.Direct3D12 && SystemInfo.graphicsDeviceType != GraphicsDeviceType.Vulkan)) return false;
                var prefab = Resources.Load<GameObject>("GaussianWorld/Cabin");
                var composite = Resources.Load<Shader>("GaussianWorld/GuardedGaussianComposite");
                var template = prefab != null ? prefab.GetComponentInChildren<GaussianSplatRenderer>(true) : null;
                return template != null && template.m_CSSplatUtilities != null
                    && template.m_ShaderSplats != null && template.m_ShaderSplats.isSupported
                    && template.m_ShaderDebugPoints != null && template.m_ShaderDebugPoints.isSupported
                    && template.m_ShaderDebugBoxes != null && template.m_ShaderDebugBoxes.isSupported
                    && composite != null && composite.isSupported;
            }
        }
        public async Task<bool> ShowFormalMarble(FormalWorldPackage package, CancellationToken cancellation)
        {
            if (instance != null) throw new InvalidOperationException("Marble 画面已绑定其他空间。");
            var document = package.ReadMarbleRuntime() ?? throw new InvalidDataException("空间缺少正式 Marble 环境配置。");
            if (!SystemInfo.supportsComputeShaders ||
                (SystemInfo.graphicsDeviceType != GraphicsDeviceType.Metal && SystemInfo.graphicsDeviceType != GraphicsDeviceType.Direct3D12 && SystemInfo.graphicsDeviceType != GraphicsDeviceType.Vulkan))
                throw new NotSupportedException("Marble 画面需要 Metal、D3D12 或 Vulkan。");
            var decoded = await RuntimeMarbleSplatLoader.DecodeAsync(package.ResolveResourcePath((string)document["splatPath"], "environment.spz"), cancellation);
            cancellation.ThrowIfCancellationRequested();
            string expectedHash = null;
            foreach (JObject entry in (JArray)package.Manifest["resources"])
                if ((string)entry["path"] == (string)document["splatPath"] && (string)entry["kind"] == "environment.spz") expectedHash = (string)entry["sha256"];
            if (decoded.SourceHash != expectedHash) throw new InvalidDataException("Marble 环境文件在载入期间发生变化。");
            var prefab = Resources.Load<GameObject>("GaussianWorld/Cabin");
            var composite = Resources.Load<Shader>("GaussianWorld/GuardedGaussianComposite");
            if (prefab == null || composite == null || !composite.isSupported)
                throw new InvalidDataException("Marble Gaussian 渲染资源尚未准备好。");
            var staging = new GameObject("Marble Gaussian initialization"); staging.SetActive(false);
            try {
                runtimeAsset = new RuntimeMarbleSplatLoader.RuntimeAsset(decoded);
                instance = Instantiate(prefab, staging.transform);
                instance.SetActive(false);
                var renderer = instance.GetComponentInChildren<GaussianSplatRenderer>(true);
                if (renderer == null) throw new InvalidDataException("Marble Gaussian 渲染模板缺失。");
                renderer.m_Asset = runtimeAsset.Asset; renderer.m_SHOrder = decoded.SHDegree;
                renderer.m_ShaderComposite = composite;
                var scale = (float)document["uniformScale"]; var origin = document["origin"];
                instance.transform.SetParent(transform, false);
                // SPZ RUB -> source RDF -> Unity: the net axis conversion flips Y.
                instance.transform.localScale = new Vector3(scale, -scale, scale);
                instance.transform.localPosition = new Vector3(-(float)origin[0], -(float)origin[1], (float)origin[2]) * scale;
                instance.transform.localRotation = Quaternion.identity;
                instance.transform.SetParent(null, true);
                instance.SetActive(true);
                renderers = instance.GetComponentsInChildren<GaussianSplatRenderer>(true); drawing = true;
                if (!gameObject.activeInHierarchy) Hide();
                Status = $"Marble Gaussian renderer prepared: {decoded.Count} splats";
                Debug.Log($"[GaussianWorld] formal world={(string)document["worldID"]} splats={decoded.Count} sha256={decoded.SourceHash}");
                return true;
            } catch {
                if (instance != null) Destroy(instance); instance = null;
                runtimeAsset?.Dispose(); runtimeAsset = null; throw;
            } finally { Destroy(staging); }
        }
        public bool ShowCabin()
        {
            var started = Time.realtimeSinceStartupAsDouble;
            var warm = instance != null;
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
                // Keep GPU resources resident while the containing world is
                // hidden. OnDisable in the upstream renderer destroys them.
                instance.transform.SetParent(transform,false);
                instance.transform.SetParent(null,true);
                Destroy(staging);
                instance.SetActive(true);
                renderers = instance.GetComponentsInChildren<GaussianSplatRenderer>(true);
                drawing = true;
            }
            if (!drawing && gameObject.activeInHierarchy) {
                foreach (var renderer in renderers) GaussianVisibility.SetDrawing(renderer, true);
                drawing = true;
            }
            if (!gameObject.activeInHierarchy) Hide();
            Status = "Cabin Gaussian renderer enabled (visual acceptance pending)";
            Debug.Log($"[GaussianWorld] show cached={warm} cpuMs={(Time.realtimeSinceStartupAsDouble-started)*1000:F2}");
            return true;
        }
        public void Hide() {
            if (!drawing || renderers == null) return;
            foreach (var renderer in renderers) GaussianVisibility.SetDrawing(renderer, false);
            drawing = false;
        }
        void OnDisable() => Hide();
        void OnDestroy() { if (instance != null) Destroy(instance); runtimeAsset?.Dispose(); runtimeAsset = null; }
    }
}
