using System;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Rendering;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer
{
    /// Explicit read-only recovery entry. Backup assets remain immutable and Rust
    /// remains the write authority; no autonomous actions or import are implied.
    public sealed class WorldRuntimeBridge : MonoBehaviour
    {
        public event Action<string> Status;
        public event Action<bool> ModeChanged;
        NativePlayerBackend backend;
        AudioSculpture sculpture;
        GameObject worldRoot;
        CancellationTokenSource lifetime = new();
        string worldID, packageDirectory;
        bool loading, visible;
        Vector3 playerPosition;
        Quaternion playerRotation;
        JObject recoveredCamera;
        float playerFieldOfView;
        float playerNearPlane, playerFarPlane;
        GaussianWorldView gaussianBackground;
        bool backgroundEnabled;
        const string VerifiedCabinWorldID = "84503420-3010-4944-8fde-2f383cd08ebe";
        WorldCameraController cameraControls;
        AmbientMode playerAmbientMode;
        Color playerAmbientLight;
        SphericalHarmonicsL2 playerAmbientProbe;
        public JObject AuthorityProjection { get; private set; }
        public bool Configured => !string.IsNullOrEmpty(worldID) && !string.IsNullOrEmpty(packageDirectory);

        public void Initialize(NativePlayerBackend native, AudioSculpture player)
        {
            backend = native; sculpture = player;
            cameraControls = gameObject.AddComponent<WorldCameraController>();
            cameraControls.Configure(Camera.main, GetComponent<UnityEngine.UIElements.UIDocument>());
            worldID = Environment.GetEnvironmentVariable("GMGN_UNITY_WORLD_ID");
            packageDirectory = Environment.GetEnvironmentVariable("GMGN_UNITY_WORLD_PACKAGE");
            backend.WorldUpdated += OnWorldUpdated;
            if (Configured) backend.RequestWorldSnapshot(worldID);
        }

        void OnWorldUpdated(JObject update)
        {
            if ((string)update["status"] == "failed") { Status?.Invoke((string)update["message"]); return; }
            if (update["result"]?["record"] is JObject record) AuthorityProjection = (JObject)record.DeepClone();
        }

        public async void Toggle()
        {
            Debug.Log($"World toggle requested: configured={Configured}; loading={loading}; visible={visible}; recovered={worldRoot != null}");
            if (loading) return;
            if (!Configured) { Status?.Invoke("请先指定空间备份目录和空间编号，再打开空间。"); return; }
            if (worldRoot != null) { SetVisible(!visible); return; }
            loading = true;
            Status?.Invoke("正在读取空间备份…");
            try
            {
                var token = lifetime.Token;
                // Integrity hashing and manifest IO do not occupy the UI thread.
                var package = await Task.Run(() => PortableWorldPackage.Open(packageDirectory), token);
                Debug.Log("World backup verified; starting real model recovery");
                token.ThrowIfCancellationRequested();
                recoveredCamera = package.State(worldID)["liveCamera"] as JObject;
                var loader = new GltfWorldAssetLoader();
                worldRoot = new GameObject("Recovered world " + worldID);
                if (string.Equals(worldID, VerifiedCabinWorldID, StringComparison.OrdinalIgnoreCase))
                    gaussianBackground = worldRoot.AddComponent<GaussianWorldView>();
                var light = new GameObject("Recovery lighting").AddComponent<Light>();
                light.transform.SetParent(worldRoot.transform, false);
                light.type = LightType.Directional; light.intensity = 1;
                light.color = new Color(1, .78f, .56f);
                light.intensity = .88f;
                light.transform.rotation = Quaternion.Euler(41.25f, -27.5f, 0);
                var fill = new GameObject("Recovery fill lighting").AddComponent<Light>();
                fill.transform.SetParent(worldRoot.transform, false);
                fill.type = LightType.Directional; fill.intensity = .24f;
                fill.color = new Color(.46f, .58f, .82f);
                fill.transform.rotation = Quaternion.Euler(16, 49.27f, 0);
                var sceneReference = Environment.GetEnvironmentVariable("GMGN_UNITY_WORLD_SCENE_REFERENCE");
                if (!string.IsNullOrEmpty(sceneReference)) {
                    var scene = await loader.LoadSceneAsset(package.ResolveReference(sceneReference), token);
                    scene.transform.SetParent(worldRoot.transform, false);
                    backgroundEnabled = true;
                }
                var recovery = new WorldSceneRecovery(loader);
                var items = await recovery.Restore(package, worldID, worldRoot.transform, token);
                token.ThrowIfCancellationRequested();
                var restored = 0; foreach (var item in items) if (item.Status == "restored") restored++;
                Debug.Log($"World recovery completed: restored={restored}; items={items.Count}");
                SetVisible(true);
                Status?.Invoke(backgroundEnabled
                    ? $"空间背景已启用，已恢复 {restored} 个真实物件；人物与设备功能仍在迁移。"
                    : $"已恢复 {restored} 个真实物件；空间背景未成功载入，人物与设备功能仍在迁移。");
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                Debug.LogError($"World recovery failed: type={error.GetType().Name}");
                if (worldRoot != null) Destroy(worldRoot);
                worldRoot = null;
                Status?.Invoke(error is System.IO.InvalidDataException || error is InvalidOperationException
                    ? error.Message : "空间恢复失败，原备份数据未修改。");
            }
            finally { loading = false; }
        }

        void SetVisible(bool value)
        {
            var camera = Camera.main;
            if (value && !visible && camera != null) {
                playerPosition = camera.transform.position; playerRotation = camera.transform.rotation;
                playerFieldOfView = camera.fieldOfView;
                playerNearPlane = camera.nearClipPlane; playerFarPlane = camera.farClipPlane;
                playerAmbientMode = RenderSettings.ambientMode;
                playerAmbientLight = RenderSettings.ambientLight;
                playerAmbientProbe = RenderSettings.ambientProbe;
            }
            visible = value;
            if (value) {
                // Match the original room's warm ambient/key/cool-fill palette.
                RenderSettings.ambientMode = AmbientMode.Flat;
                RenderSettings.ambientLight = new Color(.90f, .69f, .48f) * .125f;
                var probe = new SphericalHarmonicsL2();
                probe.AddAmbientLight(RenderSettings.ambientLight);
                RenderSettings.ambientProbe = probe;
            } else {
                RenderSettings.ambientMode = playerAmbientMode;
                RenderSettings.ambientLight = playerAmbientLight;
                RenderSettings.ambientProbe = playerAmbientProbe;
            }
            worldRoot.SetActive(value);
            if (gaussianBackground != null) {
                if (value) backgroundEnabled = gaussianBackground.ShowCabin();
                else gaussianBackground.Hide();
            }
            sculpture.enabled = !value;
            // Both components share PlayerScreen's object. Disable the GPU
            // dispatch/draw component too, without disabling chat or UIDocument.
            var cloud = sculpture.GetComponent<GpuPointCloud>();
            if (cloud != null) cloud.enabled = !value;
            if (camera != null)
            {
                if (value && recoveredCamera != null) {
                    camera.transform.SetPositionAndRotation(WorldCoordinates.Position(recoveredCamera["transform"]?["position"]),
                        WorldCoordinates.Rotation(recoveredCamera["transform"]?["rotation"]));
                    camera.fieldOfView = (float?)recoveredCamera["fieldOfViewDegrees"] ?? 60;
                    camera.nearClipPlane = (float?)recoveredCamera["nearPlane"] ?? .05f;
                    camera.farClipPlane = (float?)recoveredCamera["farPlane"] ?? 250;
                } else if (value) { camera.transform.position = new Vector3(0, 1.6f, -4); camera.transform.LookAt(new Vector3(0, 1, 0)); }
                else {
                    camera.transform.SetPositionAndRotation(playerPosition, playerRotation); camera.fieldOfView = playerFieldOfView;
                    camera.nearClipPlane = playerNearPlane; camera.farClipPlane = playerFarPlane;
                }
            }
            cameraControls.Configure(camera, GetComponent<UnityEngine.UIElements.UIDocument>());
            cameraControls.SetActive(value);
            ModeChanged?.Invoke(value);
        }

        void OnDestroy()
        {
            lifetime.Cancel(); lifetime.Dispose();
            if (backend != null) backend.WorldUpdated -= OnWorldUpdated;
            if (worldRoot != null) Destroy(worldRoot);
        }
    }
}
