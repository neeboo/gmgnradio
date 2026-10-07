using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
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
    [DefaultExecutionOrder(12000)]
    public sealed class WorldRuntimeBridge : MonoBehaviour
    {
        public event Action<string> Status;
        public event Action<string> Error;
        public event Action<string> ErrorCleared;
        public event Action<bool> ModeChanged;
        public event Action<string> DeviceActivated;
        public event Action<JArray> InventoryUpdated;
        public event Action<JObject> SelectionPrepared;
        public Func<JObject, bool> PlaceDevice;
        NativePlayerBackend backend;
        AudioSculpture sculpture;
        GameObject worldRoot;
        public GameObject PresentationRoot => worldRoot;
        public bool PresentationVisible => visible;
        public string PresentationWorldID => worldID;
        public Transform GetPlacedObjectTransform(string objectID)
            => recoveredItems.TryGetValue(objectID, out var item) && item.Status == "restored" && item.Instance != null ? item.Instance.transform : null;
        public Renderer[] GetHeldPresentationRenderers(GMGN.UnityPlayer.Characters.CharacterWorldAdapter resident)
        {
            var held = AuthorityProjection?["state"]?["heldProp"];
            var id = (string)held?["objectID"];
            if (resident == null || resident != character || id == null
                || (string)held?["avatarAssetID"] != resident.CharacterId
                || !recoveredItems.TryGetValue(id, out var item)
                || item.Instance == null || item.Status != "attached") return Array.Empty<Renderer>();
            return item.Instance.GetComponentsInChildren<Renderer>(true);
        }
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
        Transform characterParent;
        PortableWorldPackage verifiedPackage;
        FormalWorldPackage formalPackage;
        GameObject stagedRoot;
        IReadOnlyList<RecoveryItem> stagedItems;
        FormalWorldPackage stagedPackage;
        JObject stagedSelection;
        bool selectionLoading;
        GeneratedAssetResolver generatedAssets;
        JObject pendingGeneratedAssets;
        readonly Dictionary<string, RecoveryItem> recoveredItems = new(StringComparer.Ordinal);
        bool refreshPending, refreshing;
        ulong projectionEpoch;
        JArray deviceTemplates;
        JObject outputPreviewManifest;
        GeneratedAssetResolver outputPreviewAssets;
        public Func<JObject,bool> OutputProjectionAck;
        public JObject AuthorityProjection { get; private set; }
        public bool Configured => !string.IsNullOrEmpty(worldID);

        // Selection and activity share the adapter owned by PlayerScreen. Never
        // create another character from fixture environment variables here.
        public void BindCharacter(GMGN.UnityPlayer.Characters.CharacterWorldAdapter adapter)
        {
            if (character == adapter) { ApplyCharacterProjection(); return; }
            DetachCharacter();
            character = adapter;
            if (character == null) return;
            if (character.gameObject == gameObject) {
                Debug.LogError("World character must use a dedicated GameObject, not the UI host.");
                character = null; return;
            }
            characterParent = character.transform.parent;
            character.NoticeChanged += OnCharacterNotice;
            character.SelectionCompleted += OnCharacterSelection;
            ApplyCharacterProjection();
        }
        void OnCharacterNotice(string value) => Status?.Invoke(value);
        void OnCharacterSelection(JObject _) => ApplyCharacterProjection();
        void ApplyCharacterProjection()
        {
            cameraControls?.BindResident(character?.transform, worldID,
                () => visible && !IsEditing && GetComponent<UnityCompactWindowController>()?.IsCompact != true);
            if (character == null) return;
            if (worldRoot != null && character.transform.parent != worldRoot.transform)
                character.transform.SetParent(worldRoot.transform, true);
            if (AuthorityProjection?["state"] is JObject state) character.ApplyState(state);
        }
        void DetachCharacter()
        {
            if (character == null) return;
            character.NoticeChanged -= OnCharacterNotice;
            character.SelectionCompleted -= OnCharacterSelection;
            if (worldRoot != null && character.transform.parent == worldRoot.transform)
                character.transform.SetParent(characterParent, true);
            character = null;
        }

        public void Initialize(NativePlayerBackend native, AudioSculpture player)
        {
            backend = native; sculpture = player;
            backend.SendCommand(new JObject { ["op"] = "world.runtime.capabilities",
                ["marbleSPZVersion"] = GaussianWorldView.FormalMarbleSupported ? 2 : 0 });
            cameraControls = gameObject.AddComponent<WorldCameraController>();
            cameraControls.Configure(Camera.main, GetComponent<UnityEngine.UIElements.UIDocument>());
            worldID = Environment.GetEnvironmentVariable("GMGN_UNITY_WORLD_ID");
            packageDirectory = Environment.GetEnvironmentVariable("GMGN_UNITY_WORLD_PACKAGE");
            var root = backend.DataRoot;
            if (!string.IsNullOrEmpty(root) && Configured) generatedAssets = new GeneratedAssetResolver(root, worldID);
            backend.WorldUpdated += OnWorldUpdated;
            backend.PlacementDerived += OnPlacementDerived;
            if (Configured) backend.RequestWorldSnapshot(worldID);
        }

        void OnWorldUpdated(JObject update)
        {
            if ((string)update["status"] == "failed") { Error?.Invoke((string)update["message"]); return; }
            if (update["result"]?["record"] is JObject record) {
                if (AuthorityProjection != null && (ulong?)record["recordRevision"] < (ulong?)AuthorityProjection["recordRevision"]) return;
                bool poseRevisionAdvanced=AuthorityProjection==null ||
                    (ulong?)record["recordRevision"]>(ulong?)AuthorityProjection["recordRevision"];
                AuthorityProjection = (JObject)record.DeepClone();
                projectionEpoch++; refreshPending = true;
                if(poseRevisionAdvanced) ApplyCharacterProjection();
            }
        }

        /// Called only with the native host's matching task-receipt/inventory
        /// projection. No arbitrary paths, web URLs or scans are accepted.
        public void SetGeneratedAssets(JObject manifest)
        {
            if (manifest == null || string.IsNullOrEmpty((string)manifest["worldID"])) return;
            pendingGeneratedAssets = (JObject)manifest.DeepClone();
            // Startup pulses can precede formal selection. Retain the exact
            // capability without adopting its world or publishing a false error.
            if (!Configured || generatedAssets == null || (string)manifest["worldID"] != worldID) return;
            try { generatedAssets.SetCatalog(manifest); projectionEpoch++; refreshPending = true; }
            catch (InvalidDataException error) { Error?.Invoke(error.Message); }
        }
        public void SetDeviceTemplates(JArray templates)
        {
            deviceTemplates = templates == null ? null : (JArray)templates.DeepClone();
            if (interactions != null) {
                interactions.ConfigureDeviceTemplates(deviceTemplates);
                refreshPending = true;
            }
        }
        // Separate receipt capability scope: a ready output is not inventory.
        public void SetWishOutputPreview(JObject manifest)
        {
            if (manifest == null || string.IsNullOrEmpty((string)manifest["worldID"])) return;
            outputPreviewManifest = (JObject)manifest.DeepClone();
            if (!Configured || (string)manifest["worldID"] != worldID) return;
            try {
                var root=backend.DataRoot;
                var resolver=new GeneratedAssetResolver(root,worldID);
                resolver.SetCatalog(manifest);
                outputPreviewAssets=resolver;outputPreviewManifest=(JObject)manifest.DeepClone();
                ApplyWishOutputPreview();
            } catch(InvalidDataException error) { Error?.Invoke(error.Message); }
        }
        void ApplyWishOutputPreview()
        {
            if (!recoveredItems.TryGetValue("wish_machine.device",out var item) || item.Instance==null) return;
            var device=item.Instance.GetComponent<BuiltinWorldDevice>();if(device==null) return;
            device.OutputProjectionAcknowledged=ack=>OutputProjectionAck?.Invoke(ack);
            if ((string)outputPreviewManifest?["worldID"] != worldID || outputPreviewManifest?["entries"] is not JArray entries) { device.HideOutputPreview();return; }
            JObject selected=null;
            foreach(var entry in entries) if((string)entry["stage"]=="ready") { selected=entry as JObject;break; }
            if(selected==null) device.HideOutputPreview();else device.ShowOutputPreview(selected,outputPreviewAssets,worldID);
        }
        public bool BeginInventoryPlacement(string objectID)
            => visible && interactions != null && interactions.BeginInventoryPlacement(objectID, InitialPlacementPosition());
        public bool DeleteInventoryObject(string objectID)
        {
            var state = AuthorityProjection?["state"];
            if (!visible || state?["objectStates"]?[objectID]?["metadata"]?["gmgn.generated-prop.v1"] == null ||
                (string)state?["heldProp"]?["objectID"] == objectID) return false;
            return backend.SendCommand(new JObject { ["op"] = "inventory.delete", ["worldID"] = worldID,
                ["objectID"] = objectID, ["layoutRevision"] = state["layoutRevision"] });
        }
        public void ApplyInventoryMutation(JObject mutation)
        {
            if ((string)mutation["status"] == "completed") backend.RequestWorldSnapshot(worldID);
            else if ((string)mutation["status"] == "failed") Error?.Invoke((string)mutation["message"]);
        }
        public void PulseDeviceButton(string objectID)
        {
            if(recoveredItems.TryGetValue(objectID,out var item) && item.Instance!=null)
                item.Instance.GetComponent<BuiltinWorldDevice>()?.PulseButton();
        }
        public bool IsEditing => visible && interactions?.IsEditing == true;
        public void SetEditing(bool value) => interactions?.SetEditing(value && visible);
        public bool BeginDevicePlacement(JObject template)
        {
            if (!visible || interactions == null) return false;
            interactions.PlaceDevice = payload => PlaceDevice?.Invoke(payload) == true;
            return interactions.BeginDevicePlacement(template, InitialPlacementPosition());
        }
        public void ApplyDevicePlacement(JObject pulse)
        {
            // The device receipt already includes a separate authority readback.
            // Adopt it before refresh can remove the newly restored instance
            // against the pre-placement object list.
            if ((string)pulse?["status"] == "completed" && pulse["result"]?["record"] is JObject)
                OnWorldUpdated(pulse);
            interactions?.ApplyDevicePlacement(pulse);
        }
        Vector3 InitialPlacementPosition()
        {
            var camera = Camera.main;
            if (camera == null) return Vector3.zero;
            var position = camera.transform.position + camera.transform.forward * 2;
            if (Physics.Raycast(camera.transform.position, camera.transform.forward, out var hit, 8)) position = hit.point;
            // A tentative pointer pose only: the Rust support grid determines
            // the final floor/layer; this position never bypasses evaluation.
            return position;
        }
        void OnDeviceRestored(BuiltinWorldDevice device)
        {
            if (device == null) return;
            device.transform.SetParent(worldRoot.transform, true);
            recoveredItems[device.ObjectID] = new RecoveryItem { ObjectID = device.ObjectID, Instance = device.gameObject, Status = "restored", AssetMetadata = "builtin" };
            device.Activated += identity => DeviceActivated?.Invoke(identity);
            if(device.RendererID == "builtin.wish_machine") ApplyWishOutputPreview();
        }
        async Task<string> ResolveAsset(JObject prop, CancellationToken token)
        {
            if (formalPackage != null) {
                try { return formalPackage.ResolveAssetID((string)prop["assetID"]); }
                catch (InvalidDataException) { if (generatedAssets?.Contains((string)prop["objectID"]) != true) throw; }
            }
            if (verifiedPackage != null) {
                try { return verifiedPackage.ResolveAssetID((string)prop["assetID"]); }
                catch (InvalidDataException) {
                    if (generatedAssets?.Contains((string)prop["objectID"]) != true) throw;
                }
            }
            if (generatedAssets == null) throw new InvalidDataException("生成资产清单尚未同步，原库存记录已保留。");
            return await generatedAssets.Resolve(prop, token);
        }
        public async void ApplyWorldSelection(JObject selection)
        {
            if (selection == null) return;
            var phase = (string)selection["phase"];
            Debug.Log($"World selection received: world={(string)selection["worldID"]}; phase={phase}; revision={(string)selection["revision"]}; code={(string)selection["code"]}");
            if (phase == "failed") { if (stagedRoot != null) Destroy(stagedRoot); stagedRoot = null; Error?.Invoke((string)selection["message"] ?? "空间暂时无法打开，请重新选择空间。"); return; }
            if (phase == "activate") {
                if (stagedRoot == null || stagedSelection == null || !JToken.DeepEquals(selection["revision"], stagedSelection["revision"])) return;
                if (visible) SetVisible(false);
                if (character != null && worldRoot != null && character.transform.parent == worldRoot.transform)
                    character.transform.SetParent(characterParent, true);
                if (interactions != null) { interactions.DeviceRestored -= OnDeviceRestored; Destroy(interactions); interactions = null; }
                if (worldRoot != null) Destroy(worldRoot);
                worldRoot = stagedRoot; stagedRoot = null;
                worldID = (string)selection["worldID"]; packageDirectory = null; verifiedPackage = null;
                formalPackage = stagedPackage; AuthorityProjection = (JObject)selection["record"].DeepClone();
                recoveredCamera = AuthorityProjection["state"]?["liveCamera"] as JObject;
                gaussianBackground = worldRoot.GetComponent<GaussianWorldView>(); backgroundEnabled = true;
                generatedAssets = new GeneratedAssetResolver(backend.DataRoot, worldID);
                generatedAssets.SetCatalog((JObject)selection["generatedAssets"]);
                if ((string)pendingGeneratedAssets?["worldID"] == worldID) SetGeneratedAssets(pendingGeneratedAssets);
                recoveredItems.Clear(); foreach (var item in stagedItems) recoveredItems[item.ObjectID] = item;
                interactions = gameObject.AddComponent<WorldInteractionController>();
                interactions.Configure(backend, worldID, stagedItems, GetComponent<UnityEngine.UIElements.UIDocument>().rootVisualElement);
                interactions.Status += value => Status?.Invoke(value);
                interactions.DeviceRestored += OnDeviceRestored;
                interactions.PlaceDevice = payload => PlaceDevice?.Invoke(payload) == true;
                interactions.ConfigureDeviceTemplates(deviceTemplates);
                interactions.RestoreDevices(AuthorityProjection, worldRoot.transform);
                if ((string)outputPreviewManifest?["worldID"] == worldID) SetWishOutputPreview(outputPreviewManifest);
                placementGrid = null; placementDeriveID = null; placementGeometry = null; placementView?.Hide();
                ApplyCharacterProjection(); SetVisible(true); Error?.Invoke(null);
                worldRoot.AddComponent<WorldLighting>().Initialize(Camera.main.transform.position);
                PublishInventory((JObject)AuthorityProjection["state"]["objectStates"]);
                PrepareFormalPlacement(formalPackage, worldID);
                stagedSelection = null; stagedItems = null; projectionEpoch++;
                return;
            }
            if (phase != "prepare" || selectionLoading) return;
            selectionLoading = true;
            var receipt = new JObject { ["revision"] = selection["revision"], ["worldID"] = selection["worldID"], ["success"] = false };
            try {
                if (loading || refreshing || interactions?.OwnsPointer == true) throw new InvalidOperationException("请完成当前摆放后再切换空间。");
                var requested = (JObject)selection.DeepClone(); var token = lifetime.Token;
                stagedPackage = await Task.Run(() => FormalWorldPackage.Open((string)requested["packageRoot"], (string)requested["worldID"], (string)requested["manifestSHA256"]), token);
                if (!(requested["record"]?["state"] is JObject state) || (string)state["worldID"] != (string)requested["worldID"])
                    throw new InvalidDataException("空间权威快照身份不一致。");
                stagedRoot = new GameObject("Prepared world " + (string)requested["worldID"]);
                stagedRoot.SetActive(false);
                var loader = new GltfWorldAssetLoader(); bool sceneLoaded = false;
                if (stagedPackage.ReadMarbleRuntime() != null)
                    sceneLoaded = await stagedRoot.AddComponent<GaussianWorldView>().ShowFormalMarble(stagedPackage, token);
                else foreach (var resource in (JArray)stagedPackage.Manifest["resources"]) {
                    if ((string)resource["kind"] == "scene.glb") {
                        var scene = await loader.LoadSceneAsset(stagedPackage.ResolveResource((string)resource["id"]), token);
                        scene.transform.SetParent(stagedRoot.transform, false); sceneLoaded = true;
                    }
                    // This compiled GPU asset was prepared from this exact SPZ.
                    // A matching world ID alone cannot substitute another scene.
                    if ((string)requested["worldID"] == VerifiedCabinWorldID && (string)resource["kind"] == "scene.spz" &&
                        (string)resource["sha256"] == "2f82fe6f4c8437e407170de4f945455058ff464729e09366ca1f4942930efc52")
                        sceneLoaded = stagedRoot.AddComponent<GaussianWorldView>().ShowCabin();
                }
                if (!sceneLoaded) throw new NotSupportedException("这个空间的背景格式尚未接入运行时切换，当前空间已保留。");
                var stagedAssets = new GeneratedAssetResolver(backend.DataRoot, (string)requested["worldID"]);
                stagedAssets.SetCatalog((JObject)requested["generatedAssets"]);
                stagedItems = await new WorldSceneRecovery(loader).RestoreState(state, stagedRoot.transform,
                    async (prop, ct) => {
                        try { return stagedPackage.ResolveAssetID((string)prop["assetID"]); }
                        catch (InvalidDataException) { return await stagedAssets.Resolve(prop, ct); }
                    }, token, true);
                foreach (var item in stagedItems) if (item.Status == "failed") throw new InvalidDataException("空间物件尚未完整载入。");
                token.ThrowIfCancellationRequested();
                stagedRoot.SetActive(false); stagedSelection = requested; receipt["success"] = true;
            } catch (Exception error) {
                Debug.LogWarning($"World selection prepare failed: world={(string)selection["worldID"]}; type={error.GetType().Name}");
                if (stagedRoot != null) Destroy(stagedRoot); stagedRoot = null; stagedSelection = null;
                receipt["message"] = error is InvalidDataException || error is NotSupportedException || error is InvalidOperationException ? error.Message : "空间载入失败，当前空间已保留。";
            } finally { selectionLoading = false; }
            SelectionPrepared?.Invoke(receipt);
            Debug.Log($"World selection prepared: world={(string)receipt["worldID"]}; success={(bool)receipt["success"]}");
        }
        void Update()
        {
            if (refreshPending && !refreshing && !loading && worldRoot != null && interactions?.OwnsPointer != true)
                RefreshObjects();
        }
        string heldCalibrationRaw, heldProjectionCode;
        string projectedHeldObjectID;
        JObject heldCalibration;
        float attachmentReceiptAt;
        float attachmentReceiptSentAt;
        string attachmentReceiptRaw;
        void ClearHeldProjectionError()
        {
            var previous = heldProjectionCode;
            heldProjectionCode = null;
            if (previous != null) ErrorCleared?.Invoke(previous);
        }
        void PublishAttachmentReadiness()
        {
            if (backend == null || Time.unscaledTime < attachmentReceiptAt) return;
            attachmentReceiptAt = Time.unscaledTime + .5f;
            var receipt = BuildAttachmentReadinessReceipt();
            var raw = receipt.ToString(Newtonsoft.Json.Formatting.None);
            if ((raw != attachmentReceiptRaw || Time.unscaledTime - attachmentReceiptSentAt >= 5)
                && backend.SendCommand(receipt)) {
                attachmentReceiptRaw = raw; attachmentReceiptSentAt = Time.unscaledTime;
            }
        }
        JObject BuildAttachmentReadinessReceipt()
        {
            var slots = new JArray();
            if (visible && character != null)
                foreach (var slot in new[] { "rightHand", "back", "waist" })
                    if (character.TryGetAttachmentBone(slot, out var bone) && bone != null) slots.Add(slot);
            var assets = new JObject();
            // Presentation visibility does not unload prepared assets. Returning
            // a held prop still requires this evidence while the world is hidden.
            foreach (var item in recoveredItems.Values) {
                if (item.Instance == null || item.Instance.GetComponent<PreparedPropGrip>() == null || item.AssetMetadata == null) continue;
                try { assets[item.ObjectID] = (string)JObject.Parse(item.AssetMetadata)["assetID"]; }
                catch (Newtonsoft.Json.JsonException) { }
            }
            return new JObject { ["op"] = "world.attachment.ready", ["worldID"] = worldID,
                ["avatarID"] = character?.CharacterId,
                ["avatarFormat"] = character?.LoadedAvatarFormat,
                ["selectionRevision"] = character?.LoadedSelectionRevision ?? 0,
                ["layoutRevision"] = (long?)AuthorityProjection?["state"]?["layoutRevision"] ?? 0,
                ["slots"] = slots, ["assets"] = assets };
        }
        void LateUpdate()
        {
            PublishAttachmentReadiness();
            var state = AuthorityProjection?["state"];
            var held = state?["heldProp"];
            var id = (string)held?["objectID"];
            character?.ClearHeldFingerPose();
            if (projectedHeldObjectID != null && projectedHeldObjectID != id
                && recoveredItems.TryGetValue(projectedHeldObjectID, out var previous)
                && previous.Instance != null && previous.Status == "attached") {
                // Do not leave the released model floating at its last bone pose
                // while the authoritative world placement is being restored.
                previous.Instance.SetActive(false);
                previous.Status = "attachment_pending";
            }
            projectedHeldObjectID = id;
            if (id == null) ClearHeldProjectionError();
            if (id == null || !recoveredItems.TryGetValue(id, out var item) || item.Instance == null) return;
            try {
                var raw = (string)state["objectStates"]?[id]?["metadata"]?["gmgn.prop-grip.v1"];
                if (raw == null) throw new InvalidDataException("手持物件缺少握持标定。");
                if (raw != heldCalibrationRaw) {
                    heldCalibration = JObject.Parse(raw); heldCalibrationRaw = raw;
                }
                var slot = (string)held["hand"];
                if (character == null || character.CharacterId != (string)held["avatarAssetID"]
                    || character.CharacterId != (string)heldCalibration["avatarAssetID"]
                    || slot != (string)heldCalibration["hand"])
                    throw new InvalidDataException("手持标定与当前角色或挂点不一致。");
                if (!character.TryGetAttachmentBone(slot, out var bone))
                    throw new InvalidDataException("当前角色缺少所选物件挂点。");
                var grip = item.Instance.GetComponent<PreparedPropGrip>();
                if (grip == null) throw new InvalidDataException("手持模型的握持坐标尚未准备。");
                var normalized = WorldCoordinates.Scale(heldCalibration["normalizedGrip"]);
                grip.ApplyToBone(bone, normalized, WorldCoordinates.Position(heldCalibration["localOffset"]),
                    WorldCoordinates.Rotation(heldCalibration["localRotation"]));
                if(slot=="rightHand" && grip.TryHandleGeometry(normalized,out var centre,out var shaft,out var radius))
                    character.ApplyHeldFingerPose(centre,shaft,radius);
                item.Instance.SetActive(true); item.Status = "attached";
                item.Message = null;
                ClearHeldProjectionError();
            } catch (Exception error) when (error is InvalidDataException || error is Newtonsoft.Json.JsonException) {
                item.Instance.SetActive(false);
                item.Status = "attachment_failed";
                item.Message = error is InvalidDataException ? error.Message : "物件握持标定无法读取。";
                if (heldProjectionCode != item.Message) { heldProjectionCode = item.Message; Error?.Invoke(item.Message); }
            }
        }
        async void RefreshObjects()
        {
            if (!(AuthorityProjection?["state"] is JObject current)) return;
            refreshPending = false; refreshing = true;
            var epoch = projectionEpoch; var token = lifetime.Token;
            try {
                var state = (JObject)current.DeepClone();
                var objects = state["objectStates"] as JObject ?? throw new InvalidDataException("空间物件状态不完整。");
                var changes = new JObject();
                foreach (var entry in objects.Properties()) {
                    var raw = (string)entry.Value["metadata"]?["gmgn.generated-prop.v1"];
                    if (raw == null) continue;
                    if (!recoveredItems.TryGetValue(entry.Name, out var old) || old.Instance == null || old.AssetMetadata != raw)
                        changes[entry.Name] = entry.Value.DeepClone();
                }
                var subset = (JObject)state.DeepClone(); subset["objectStates"] = changes;
                var loaded = await new WorldSceneRecovery(new GltfWorldAssetLoader()).RestoreState(subset,
                    worldRoot.transform, ResolveAsset, token, true);
                if (epoch != projectionEpoch || interactions?.OwnsPointer == true) {
                    foreach (var item in loaded) if (item.Instance != null) Destroy(item.Instance);
                    refreshPending = true; return;
                }
                foreach (var item in loaded) {
                    if (recoveredItems.TryGetValue(item.ObjectID, out var old) && old.Instance != null) Destroy(old.Instance);
                    recoveredItems[item.ObjectID] = item;
                }
                foreach (var id in recoveredItems.Keys.ToArray()) {
                    if (!(objects[id] is JObject saved)) {
                        if (recoveredItems[id].Instance != null) Destroy(recoveredItems[id].Instance);
                        recoveredItems.Remove(id); continue;
                    }
                    var item = recoveredItems[id];
                    if (item.Instance == null) continue;
                    var enabled = (bool?)saved["isEnabled"] == true;
                    item.Instance.transform.localPosition = WorldCoordinates.Position(saved["transform"]?["position"]);
                    item.Instance.transform.localRotation = WorldCoordinates.Rotation(saved["transform"]?["rotation"]);
                    var held = id == (string)state["heldProp"]?["objectID"];
                    item.Instance.SetActive(enabled && !held);
                    item.Status = held ? "attachment_pending" : enabled ? "restored" : "inventory";
                }
                interactions.UpdateRecoveredItems(recoveredItems.Values.ToList());
                interactions.RestoreDevices(AuthorityProjection, worldRoot.transform);
                PublishInventory(objects);
            } catch (OperationCanceledException) { }
            catch (Exception error) { Debug.LogWarning("World dynamic recovery failed: " + error.GetType().Name); Error?.Invoke("新物件暂未载入，原库存和空间数据已保留。"); }
            finally { refreshing = false; }
        }
        void PublishInventory(JObject objects)
        {
            var inventory = new JArray();
            foreach (var entry in objects.Properties()) {
                if (AuthorityProjection?["state"]?["propTombstones"]?[entry.Name] != null) continue;
                var raw = (string)entry.Value["metadata"]?["gmgn.generated-prop.v1"];
                if (raw == null) continue;
                var prop = JObject.Parse(raw);
                recoveredItems.TryGetValue(entry.Name, out var item);
                inventory.Add(new JObject { ["objectID"] = entry.Name, ["name"] = (string)prop["displayName"],
                    ["modelReady"] = item?.Instance != null && (item.Status == "inventory" || item.Status == "restored"),
                    ["held"] = (string)AuthorityProjection?["state"]?["heldProp"]?["objectID"] == entry.Name,
                    ["placed"] = (bool?)entry.Value["isEnabled"] == true,
                    ["status"] = item?.Status ?? "pending" });
            }
            InventoryUpdated?.Invoke(inventory);
        }

        public async void Toggle()
        {
            Debug.Log($"World toggle requested: configured={Configured}; loading={loading}; visible={visible}; recovered={worldRoot != null}");
            if (loading) return;
            if (!Configured) { Status?.Invoke("请先选择空间，再打开空间。"); return; }
            if (worldRoot != null) { SetVisible(!visible); return; }
            loading = true;
            Status?.Invoke("");
            try
            {
                var token = lifetime.Token;
                // Integrity hashing and manifest IO do not occupy the UI thread.
                var package = string.IsNullOrEmpty(packageDirectory) ? null : await Task.Run(() => PortableWorldPackage.Open(packageDirectory), token);
                verifiedPackage = package;
                Debug.Log("World source ready; starting authority model recovery");
                token.ThrowIfCancellationRequested();
                var state = AuthorityProjection?["state"] as JObject ?? package?.State(worldID)
                    ?? throw new InvalidDataException("空间权威快照尚未读取，请稍后打开。");
                recoveredCamera = state["liveCamera"] as JObject;
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
                if (!string.IsNullOrEmpty(sceneReference) && package != null) {
                    var scene = await loader.LoadSceneAsset(package.ResolveReference(sceneReference), token);
                    scene.transform.SetParent(worldRoot.transform, false);
                    backgroundEnabled = true;
                }
                var recovery = new WorldSceneRecovery(loader);
                var items = await recovery.RestoreState(state, worldRoot.transform, ResolveAsset, token, true);
                recoveredItems.Clear(); foreach (var item in items) recoveredItems[item.ObjectID] = item;
                interactions = gameObject.AddComponent<WorldInteractionController>();
                interactions.Configure(backend, worldID, items, GetComponent<UnityEngine.UIElements.UIDocument>().rootVisualElement);
                interactions.Status += value => Status?.Invoke(value);
                interactions.DeviceRestored += OnDeviceRestored;
                interactions.PlaceDevice = payload => PlaceDevice?.Invoke(payload) == true;
                interactions.ConfigureDeviceTemplates(deviceTemplates);
                if (AuthorityProjection != null) interactions.RestoreDevices(AuthorityProjection, worldRoot.transform);
                PublishInventory((JObject)state["objectStates"]);
                try { if (package != null) await PreparePlacement(package, token); }
                catch (OperationCanceledException) { throw; }
                catch (Exception error) { Debug.LogWarning("Placement geometry unavailable: " + error.Message); }
                ApplyCharacterProjection();
                token.ThrowIfCancellationRequested();
                var restored = 0; foreach (var item in items) if (item.Status == "restored") restored++;
                Debug.Log($"World recovery completed: restored={restored}; items={items.Count}");
                SetVisible(true);
                worldRoot.AddComponent<WorldLighting>().Initialize(Camera.main.transform.position);
                if (!backgroundEnabled) Error?.Invoke("空间背景未能载入，已恢复的物件仍保留。");
                else Error?.Invoke(null);
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                Debug.LogError($"World recovery failed: type={error.GetType().Name}");
                if (character != null && worldRoot != null && character.transform.parent == worldRoot.transform)
                    character.transform.SetParent(characterParent, true);
                if (worldRoot != null) Destroy(worldRoot);
                worldRoot = null;
                recoveredItems.Clear();
                if (interactions != null) { interactions.DeviceRestored -= OnDeviceRestored; Destroy(interactions); interactions = null; }
                Error?.Invoke(error is System.IO.InvalidDataException || error is InvalidOperationException
                    ? error.Message : "空间恢复失败，原备份数据未修改。");
            }
            finally { loading = false; }
        }

        void SetVisible(bool value)
        {
            var switchStarted = Time.realtimeSinceStartupAsDouble;
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
            if (value) worldRoot.GetComponent<WorldLighting>()?.ApplyCapturedAmbient();
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
            Debug.Log($"[WorldMode] visible={value} cpuMs={(Time.realtimeSinceStartupAsDouble-switchStarted)*1000:F2} cachedWorld=true ambient={RenderSettings.ambientMode}");
        }

        void OnDestroy()
        {
            lifetime.Cancel(); lifetime.Dispose();
            if (backend != null) backend.WorldUpdated -= OnWorldUpdated;
            if (backend != null) backend.PlacementDerived -= OnPlacementDerived;
            if (interactions != null) interactions.DeviceRestored -= OnDeviceRestored;
            DetachCharacter();
            if (worldRoot != null) Destroy(worldRoot);
            if (stagedRoot != null) Destroy(stagedRoot);
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
        async void PrepareFormalPlacement(FormalWorldPackage package, string identity)
        {
            try {
                var token = lifetime.Token;
                var geometry = await WorldPlacementGeometry.PlacementGeometry.LoadFormalPackage(package, token);
                if (formalPackage != package || worldID != identity) return;
                placementGeometry = geometry;
                placementDeriveID = "unity-grid:" + Guid.NewGuid().ToString("D");
                for (int attempt = 0; attempt < 100; attempt++) {
                    token.ThrowIfCancellationRequested();
                    if (formalPackage != package || worldID != identity) return;
                    if ((string)backend.WorldProjection?["worldID"] == identity && backend.RequestPlacementDerivation(geometry.DeriveRequest, placementDeriveID)) return;
                    await Task.Delay(100, token);
                }
                throw new InvalidOperationException("空间网格校验服务忙，摆放尚未启用。");
            } catch (OperationCanceledException) { }
            catch (Exception error) {
                if (formalPackage != package || worldID != identity) return;
                Debug.LogWarning("Formal placement geometry unavailable: " + error.GetType().Name);
                Error?.Invoke("空间已载入，真实摆放网格尚未就绪；不会保存未经校验的摆放。");
            }
        }
        void OnPlacementDerived(JObject update)
        {
            if ((string)update["requestID"] != placementDeriveID || placementGeometry == null) return;
            placementDeriveID = null;
            placementGrid = update["result"]?["grid"] as JObject;
            if ((string)update["status"] != "completed" || placementGrid == null) {
                Error?.Invoke("真实空间网格生成失败，摆放尚未启用。"); return;
            }
            Debug.Log($"Placement grid derived: layers={(placementGrid["layers"] as JArray)?.Count ?? 0}");
            interactions.ConfigurePlacementGeometry(placementGrid, (JArray)placementGeometry.DeriveRequest["triangles"],
                (JArray)placementGeometry.DeriveRequest["blockingVolumes"]);
            var shader = Resources.Load<Shader>("PlacementGrid");
            if (shader == null) { Error?.Invoke("摆放网格着色器缺失，预览暂不可用。"); return; }
            var display = new GameObject("Placement footprint"); display.transform.SetParent(worldRoot.transform, false);
            placementView = display.AddComponent<WorldPlacementGeometry.PlacementGridView>();
            placementView.Initialize(shader);
            // Only show the selected item's evaluated footprint, never every
            // supported floor cell while a placement preview is starting.
            interactions.PreviewStarted += placementView.Hide;
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
