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
        WorldInteractionController interactions;
        WorldPlacementGeometry.PlacementGeometry placementGeometry;
        WorldPlacementGeometry.PlacementGridView placementView;
        string placementDeriveID;
        JObject placementGrid;
        GMGN.UnityPlayer.Characters.CharacterWorldAdapter character;
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
            backend.PlacementDerived += OnPlacementDerived;
            if (Configured) backend.RequestWorldSnapshot(worldID);
        }

        void OnWorldUpdated(JObject update)
        {
            if ((string)update["status"] == "failed") { Status?.Invoke((string)update["message"]); return; }
            if (update["result"]?["record"] is JObject record) {
                AuthorityProjection = (JObject)record.DeepClone();
                if (character != null && record["state"] is JObject currentState) character.ApplyState(currentState);
            }
        }

        public async void Toggle()
        {
            Debug.Log($"World toggle requested: configured={Configured}; loading={loading}; visible={visible}; recovered={worldRoot != null}");
            if (loading) return;
            if (!Configured) { Status?.Invoke("请先指定空间备份目录和空间编号，再打开空间。"); return; }
            if (worldRoot != null) { SetVisible(!visible); return; }
            loading = true;
            Status?.Invoke("");
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
                interactions = gameObject.AddComponent<WorldInteractionController>();
                interactions.Configure(backend, worldID, items, GetComponent<UnityEngine.UIElements.UIDocument>().rootVisualElement);
                interactions.Status += value => Status?.Invoke(value);
                try { await PreparePlacement(package, token); }
                catch (OperationCanceledException) { throw; }
                catch (Exception error) { Debug.LogWarning("Placement geometry unavailable: " + error.Message); }
                try {
                    character = await GMGN.UnityPlayer.Characters.CharacterWorldAdapter.RestoreAsync(
                        AuthorityProjection?["state"] as JObject ?? package.State(worldID), worldRoot.transform, token);
                    if (character != null) character.NoticeChanged += value => Status?.Invoke(value);
                } catch (OperationCanceledException) { throw; }
                catch (Exception error) {
                    Debug.LogError($"Character restore failed: type={error.GetType().Name}");
                    Status?.Invoke("角色恢复失败，空间物件已保留，原角色包未修改。");
                }
                token.ThrowIfCancellationRequested();
                var restored = 0; foreach (var item in items) if (item.Status == "restored") restored++;
                Debug.Log($"World recovery completed: restored={restored}; items={items.Count}");
                SetVisible(true);
                worldRoot.AddComponent<WorldLighting>().Initialize(Camera.main.transform.position);
                if (!backgroundEnabled) Status?.Invoke("空间背景未能载入，已恢复的物件仍保留。");
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
            interactions?.SetActive(value);
            if (!value) placementView?.Hide();
            ModeChanged?.Invoke(value);
        }

        void OnDestroy()
        {
            lifetime.Cancel(); lifetime.Dispose();
            if (backend != null) backend.WorldUpdated -= OnWorldUpdated;
            if (backend != null) backend.PlacementDerived -= OnPlacementDerived;
            if (worldRoot != null) Destroy(worldRoot);
        }
        async Task PreparePlacement(PortableWorldPackage package, CancellationToken token)
        {
            var reference = Environment.GetEnvironmentVariable("GMGN_UNITY_WORLD_COLLIDER_REFERENCE");
            if (string.IsNullOrEmpty(reference) && worldID == VerifiedCabinWorldID) {
                placementGeometry = await WorldPlacementGeometry.PlacementGeometry.LoadBundledCabin(package, token);
            } else {
                if (string.IsNullOrEmpty(reference)) return;
                var calibrationJSON = Environment.GetEnvironmentVariable("GMGN_UNITY_WORLD_COLLIDER_TRANSFORM");
                if (string.IsNullOrEmpty(calibrationJSON)) throw new System.IO.InvalidDataException("真实碰撞模型缺少明确校准，摆放尚未启用。");
                var calibration = JObject.Parse(calibrationJSON);
                var matrix = Matrix4x4.TRS(WorldCoordinates.Position(calibration["position"]),
                    WorldCoordinates.Rotation(calibration["rotation"]), WorldCoordinates.Scale(calibration["scale"]));
                var seed = WorldCoordinates.Position((AuthorityProjection?["state"] ?? package.State(worldID))["agentTransform"]?["position"]);
                placementGeometry = await WorldPlacementGeometry.PlacementGeometry.Load(package, reference, matrix, seed, token);
            }
            placementDeriveID = "unity-grid:" + Guid.NewGuid().ToString("D");
            for (int attempt = 0; attempt < 50; attempt++) {
                if (backend.RequestPlacementDerivation(placementGeometry.DeriveRequest, placementDeriveID)) return;
                await Task.Delay(100, token);
            }
            throw new InvalidOperationException("空间网格校验服务忙，摆放尚未启用。");
        }
        void OnPlacementDerived(JObject update)
        {
            if ((string)update["requestID"] != placementDeriveID || placementGeometry == null) return;
            placementDeriveID = null;
            placementGrid = update["result"]?["grid"] as JObject;
            if ((string)update["status"] != "completed" || placementGrid == null) {
                Status?.Invoke("真实空间网格生成失败，摆放尚未启用。"); return;
            }
            Debug.Log($"Placement grid derived: layers={(placementGrid["layers"] as JArray)?.Count ?? 0}");
            interactions.ConfigurePlacementGeometry(placementGrid, (JArray)placementGeometry.DeriveRequest["triangles"],
                (JArray)placementGeometry.DeriveRequest["blockingVolumes"]);
            var shader = Resources.Load<Shader>("PlacementGrid");
            if (shader == null) { Status?.Invoke("摆放网格着色器缺失，预览暂不可用。"); return; }
            var display = new GameObject("Placement footprint"); display.transform.SetParent(worldRoot.transform, false);
            placementView = display.AddComponent<WorldPlacementGeometry.PlacementGridView>();
            placementView.Initialize(shader);
            interactions.PreviewStarted += () => placementView.ShowGrid(placementGrid);
            interactions.PreviewChanged += result => {
                if (result?["columns"] is not JArray) { placementView.Hide(); return; }
                var volume = result["volume"];
                var support = (float?)result["previewSupportHeight"];
                if (volume == null && !support.HasValue) { placementView.Hide(); return; }
                var height = volume == null ? support.Value : (float)volume["center"][1] - (float)volume["halfExtents"][1];
                placementView.ShowPreview(result, (float)placementGrid["spacing"], height);
            };
            interactions.PreviewEnded += placementView.Hide;
        }
    }
}
