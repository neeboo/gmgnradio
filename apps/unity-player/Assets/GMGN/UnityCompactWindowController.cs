using System;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.UIElements;
using UnityEngine.InputSystem;
using GMGN.UnityPlayer.Characters;
using UnityEngine.Rendering.Universal;

namespace GMGN.UnityPlayer
{
    /// <summary>One rendering/player instance, two native window layouts.</summary>
    public sealed class UnityCompactWindowController : MonoBehaviour
    {
        [DllImport("UnityMediaHost")] static extern int gmgn_unity_window_set_compact(int compact);
        [DllImport("UnityMediaHost")] static extern int gmgn_unity_window_is_compact();
        [DllImport("UnityMediaHost")] static extern void gmgn_unity_window_drag_compact(double x, double y);
        [DllImport("UnityMediaHost")] static extern void gmgn_unity_window_compact_regions([In] double[] regions, int count);
        [DllImport("UnityMediaHost")] static extern int gmgn_unity_window_take_compact_click();
        [DllImport("UnityMediaHost")] static extern double gmgn_unity_window_scale();
        [DllImport("UnityMediaHost")] static extern void gmgn_unity_window_refresh_compact_transparency();
        public event Action<bool> ModeChanged;
        public event Action EnterSpaceRequested;
        public bool IsCompact { get; private set; }
        bool transitioning;
        VisualElement root;
        Camera liveCamera;
        Vector3 normalPosition;
        Quaternion normalRotation;
        float normalFov, normalNear, normalFar, normalOrthoSize;
        bool normalOrthographic;
        bool normalHdr;
        Color normalBackground;
        CameraClearFlags normalClearFlags;
        UniversalAdditionalCameraData urpCamera;
        bool normalPostProcessing;
        readonly Dictionary<Renderer, bool> hiddenRenderers = new();
        readonly Dictionary<Behaviour, bool> suspendedControls = new();
        readonly List<GameObject> activatedParents = new();
        CharacterWorldAdapter character;
        CharacterPortraitLighting portraitLighting;
        Renderer[] characterRenderers;
        CharacterWorldAdapter framedCharacter;
        Bounds portraitBounds;
        bool portraitBoundsReady;
        float yaw = .35f, pitch = -.18f, nextSceneCheck;
        bool rotating;
        float nextRegionUpdate;
        readonly List<double> regionValues = new();

        public void Initialize(VisualElement panelRoot) { root = panelRoot; }
        public void Toggle() { SetCompact(!IsCompact); }
        public void Restore() { SetCompact(false); }
        public void ToggleFullscreen()
        {
            Debug.Log($"[LiveCamPointer] fullscreen clicked transitioning={transitioning} compact={IsCompact} fullscreen={Screen.fullScreen}");
            if (!transitioning) StartCoroutine(ChangeFullscreen());
        }
        IEnumerator ChangeFullscreen()
        {
            // The framebuffer can move twice on the compact path (native window
            // resize first, fullscreen resolution second). One bounded window
            // covers both so a whole-content GPU rebuild is never started
            // mid-move; `NativeUIScale.ToggleFullscreen` restarts it at the
            // resolution change, which is the authoritative move.
            NativeUIScale.BeginViewportTransition();
            if (IsCompact) {
                yield return ChangeMode(false);
                // Unity updates its framebuffer dimensions after NSWindow's resize event.
                yield return null;
                yield return null;
            }
            NativeUIScale.ToggleFullscreen();
        }
        public void SetCompact(bool compact)
        {
            if (transitioning || compact == IsCompact) return;
            StartCoroutine(ChangeMode(compact));
        }
        IEnumerator ChangeMode(bool compact)
        {
            transitioning = true;
            if (compact && Screen.fullScreen) {
                NativeUIScale.ToggleFullscreen();
                float deadline = Time.realtimeSinceStartup + 5;
                while (Screen.fullScreen && Time.realtimeSinceStartup < deadline) yield return null;
                // Native fullscreen exit is asynchronous; do not save its fullscreen frame.
                yield return null;
            }
            // Screen.fullScreen changes before AppKit completes its animation.
            // Retry the native request while the old fullscreen window settles.
            float nativeDeadline = Time.realtimeSinceStartup + 5;
            int applied = 0;
            while (!Screen.fullScreen && applied == 0 && Time.realtimeSinceStartup < nativeDeadline) {
                applied = gmgn_unity_window_set_compact(compact ? 1 : 0);
                if (applied == 0) yield return new WaitForSecondsRealtime(.1f);
            }
            if (applied == 1) {
                IsCompact = gmgn_unity_window_is_compact() == 1;
                Debug.Log($"[LiveCamFocus] modeChanged compact={IsCompact} applicationFocused={Application.isFocused}");
                if (IsCompact) BeginLiveCam(); else EndLiveCam();
                root?.EnableInClassList("compact-window", IsCompact);
                ModeChanged?.Invoke(IsCompact);
            } else Debug.LogWarning("Native window mode change was not applied.");
            transitioning = false;
        }
        void BeginLiveCam()
        {
            liveCamera = Camera.main;
            if (liveCamera == null) return;
            normalPosition = liveCamera.transform.position;
            normalRotation = liveCamera.transform.rotation;
            normalFov = liveCamera.fieldOfView;
            normalNear = liveCamera.nearClipPlane;
            normalFar = liveCamera.farClipPlane;
            normalOrthographic = liveCamera.orthographic;
            normalOrthoSize = liveCamera.orthographicSize;
            normalBackground = liveCamera.backgroundColor;
            normalClearFlags = liveCamera.clearFlags;
            normalHdr = liveCamera.allowHDR;
            // URP desktop transparency requires an alpha-preserving SDR output.
            // Keep the normal scene's HDR setting intact when LiveCam closes.
            liveCamera.allowHDR = false;
            urpCamera = liveCamera.GetComponent<UniversalAdditionalCameraData>();
            if (urpCamera != null) {
                normalPostProcessing = urpCamera.renderPostProcessing;
                // The original URP scene enables post processing while the PC
                // pipeline disables post-processing alpha output.
                urpCamera.renderPostProcessing = false;
            }
            liveCamera.orthographic = false;
            liveCamera.fieldOfView = 30;
            liveCamera.nearClipPlane = .03f;
            liveCamera.clearFlags = CameraClearFlags.SolidColor;
            liveCamera.backgroundColor = Color.clear;
            nextSceneCheck = 0;
            framedCharacter = null;
            portraitBoundsReady = false;
            portraitLighting = new CharacterPortraitLighting();
            ApplyLiveCamProfile();
            StartCoroutine(RefreshCompactTransparencyAfterResize());
        }
        IEnumerator RefreshCompactTransparencyAfterResize()
        {
            // Native window resize and the Metal drawable resize happen on
            // different frames. Wait until Unity finishes configuring its layer.
            int stableFrames = 0;
            for (int attempt = 0; attempt < 20 && stableFrames < 2; attempt++) {
                yield return new WaitForEndOfFrame();
                if (!IsCompact || liveCamera == null) yield break;
                double scale = 1;
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
                scale = gmgn_unity_window_scale();
                gmgn_unity_window_refresh_compact_transparency();
#endif
                int expectedWidth = Mathf.RoundToInt(224 * (float)scale);
                int expectedHeight = Mathf.RoundToInt(336 * (float)scale);
                stableFrames = Screen.width == expectedWidth && Screen.height == expectedHeight ? stableFrames + 1 : 0;
                if (stableFrames < 2) yield return new WaitForSecondsRealtime(.1f);
            }
            if (!IsCompact || liveCamera == null) yield break;
            if (stableFrames < 2) { Debug.LogWarning($"[LiveCam] compact framebuffer did not settle: {Screen.width}x{Screen.height}"); yield break; }
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            gmgn_unity_window_refresh_compact_transparency();
#endif
        }
        void ApplyLiveCamProfile()
        {
            var characters = FindObjectsByType<CharacterWorldAdapter>(FindObjectsInactive.Include);
            character = characters.Length > 0 ? characters[0] : null;
            if (character != framedCharacter) {
                framedCharacter = character;
                portraitBoundsReady = false;
            }
            // Player mode hides the world presentation parent, including its shared
            // role. Make that presentation hierarchy available while masking every
            // non-role renderer below; preserve and restore its original visibility.
            if (character != null)
                for (var parent = character.transform.parent; parent != null; parent = parent.parent)
                    if (!parent.gameObject.activeSelf) {
                        if (!activatedParents.Contains(parent.gameObject)) activatedParents.Add(parent.gameObject);
                        parent.gameObject.SetActive(true);
                    }
            var portraitRenderers = new List<Renderer>();
            if (character != null) {
                portraitRenderers.AddRange(character.GetComponentsInChildren<Renderer>(false));
                foreach (var world in FindObjectsByType<WorldRuntimeBridge>(FindObjectsInactive.Include))
                    portraitRenderers.AddRange(world.GetHeldPresentationRenderers(character));
            }
            var allowed = new HashSet<Renderer>(portraitRenderers);
            if (characterRenderers == null || characterRenderers.Length != allowed.Count)
                portraitBoundsReady = false;
            else foreach (var prior in characterRenderers)
                if (!allowed.Contains(prior)) { portraitBoundsReady = false; break; }
            characterRenderers = portraitRenderers.ToArray();
            // Preserve the actual shared character and its motions. Only rendering
            // and spatial input are suspended; no world object/record is moved.
            foreach (var renderer in FindObjectsByType<Renderer>(FindObjectsInactive.Include)) {
                if (allowed.Contains(renderer)) {
                    if (hiddenRenderers.TryGetValue(renderer, out var originalEnabled)) {
                        renderer.enabled = originalEnabled;
                        hiddenRenderers.Remove(renderer);
                    }
                    continue;
                }
                if (!hiddenRenderers.ContainsKey(renderer)) hiddenRenderers.Add(renderer, renderer.enabled);
                renderer.enabled = false;
            }
            foreach (var behaviour in FindObjectsByType<MonoBehaviour>(FindObjectsInactive.Include)) {
                string type = behaviour.GetType().Name;
                if (type != "WorldCameraController" && type != "WorldInteractionController" &&
                    type != "AudioSculpture" && type != "GpuPointCloud" &&
                    type != "GaussianSplatRenderer" && type != "StagePointRotationController") continue;
                if (!suspendedControls.ContainsKey(behaviour)) suspendedControls.Add(behaviour, behaviour.enabled);
                behaviour.enabled = false;
            }
            nextSceneCheck = Time.unscaledTime + .5f;
            portraitLighting?.Apply();
        }
        void Update()
        {
            // A desktop floating panel accepts first mouse without requiring the
            // application to have already become foreground.
            if (!IsCompact) return;
            if (Time.unscaledTime >= nextRegionUpdate) {
                UpdateNativeInteractiveRegions();
                nextRegionUpdate = Time.unscaledTime + .1f;
            }
            if (gmgn_unity_window_take_compact_click() != 0) {
                Restore(); EnterSpaceRequested?.Invoke(); return;
            }
            if (Mouse.current == null) return;
            var mouse = Mouse.current;
            var position = mouse.position.ReadValue();
            bool uiOwnsPointer = UIControlsOwnPointer(position);
            if (mouse.leftButton.wasPressedThisFrame || mouse.leftButton.wasReleasedThisFrame)
                Debug.Log($"[LiveCamFocus] unityMouse down={mouse.leftButton.wasPressedThisFrame} up={mouse.leftButton.wasReleasedThisFrame} position={position} ui={uiOwnsPointer} applicationFocused={Application.isFocused}");
            if (mouse.rightButton.wasPressedThisFrame && !uiOwnsPointer) rotating = true;
            var delta = mouse.delta.ReadValue() / Mathf.Max(1, Screen.width / 224f);
            if (rotating && mouse.rightButton.isPressed) {
                ApplyOrbitDrag(delta);
            }
            if (mouse.rightButton.wasReleasedThisFrame) rotating = false;
        }
        void ApplyOrbitDrag(Vector2 delta)
        {
            yaw += delta.x * .008f;
            // Input System delta Y points up, matching the original screen-point
            // translation. The portrait orbit already negates sin(pitch).
            pitch = Mathf.Clamp(pitch + delta.y * .008f, -.75f, .35f);
        }
        void UpdateNativeInteractiveRegions()
        {
            if (root?.panel == null) return;
            regionValues.Clear();
            root.Query<VisualElement>().ForEach(element => {
                if (element is not Button && element is not TextField && element is not ScrollView &&
                    element is not ListView && element is not Slider) return;
                for (var parent = element; parent != null; parent = parent.parent)
                    if (parent.resolvedStyle.display == DisplayStyle.None || parent.resolvedStyle.visibility == Visibility.Hidden) return;
                var rectangle = element.worldBound;
                if (rectangle.width <= 0 || rectangle.height <= 0) return;
                var origin = root.WorldToLocal(rectangle.position);
                regionValues.Add(origin.x); regionValues.Add(origin.y);
                regionValues.Add(rectangle.width); regionValues.Add(rectangle.height);
            });
            gmgn_unity_window_compact_regions(regionValues.ToArray(), regionValues.Count / 4);
        }
        bool UIControlsOwnPointer(Vector2 screen)
        {
            if (root?.panel == null) return false;
            var point = RuntimePanelUtils.ScreenToPanel(root.panel, new Vector2(screen.x, Screen.height - screen.y));
            for (var hit = root.panel.Pick(point); hit != null; hit = hit.parent)
                if (hit is Button || hit is TextField || hit is ScrollView || hit is ListView || hit is Slider) return true;
            return false;
        }
        void LateUpdate()
        {
            if (!IsCompact || liveCamera == null) return;
            if (Time.unscaledTime >= nextSceneCheck) ApplyLiveCamProfile();
            if (character == null || characterRenderers == null) return;
            bool found = false;
            Bounds bounds = default;
            foreach (var renderer in characterRenderers) {
                if (renderer == null || !renderer.enabled || !renderer.gameObject.activeInHierarchy) continue;
                if (!found) { bounds = renderer.bounds; found = true; } else bounds.Encapsulate(renderer.bounds);
            }
            if (!found || bounds.size.y < .001f) return;
            // Animated skinned bounds change with every gesture. Capture a stable
            // portrait once per imported character, never zoom to each pose.
            if (!portraitBoundsReady) {
                portraitBounds = new Bounds(character.transform.InverseTransformPoint(bounds.center), bounds.size);
                portraitBoundsReady = true;
            }
            var center = character.transform.TransformPoint(portraitBounds.center);
            float height = Mathf.Max(portraitBounds.size.y, .5f);
            float width = Mathf.Max(portraitBounds.size.x, height * .28f);
            float tangent = Mathf.Tan(15 * Mathf.Deg2Rad);
            float distance = Mathf.Max(height * 1.18f / (2 * tangent),
                width * 1.12f / (2 * tangent * Mathf.Max(liveCamera.aspect, .001f)), 1.2f);
            var orbit = new Vector3(Mathf.Sin(yaw) * Mathf.Cos(pitch), -Mathf.Sin(pitch),
                Mathf.Cos(yaw) * Mathf.Cos(pitch));
            // PMX keeps vertex coordinates; VRM10 uses Axes.X import, preserving Z.
            // A world yaw must not turn the desktop portrait backwards.
            orbit = character.transform.TransformDirection(orbit);
            liveCamera.transform.position = center + orbit * distance;
            liveCamera.transform.LookAt(center, Vector3.up);
            portraitLighting?.FollowCamera(liveCamera.transform);
        }
        void EndLiveCam()
        {
            rotating = false;
            portraitLighting?.Dispose();
            portraitLighting = null;
            foreach (var item in hiddenRenderers) if (item.Key != null) item.Key.enabled = item.Value;
            hiddenRenderers.Clear();
            foreach (var item in suspendedControls) if (item.Key != null) item.Key.enabled = item.Value;
            suspendedControls.Clear();
            if (liveCamera != null) {
                liveCamera.transform.SetPositionAndRotation(normalPosition, normalRotation);
                liveCamera.fieldOfView = normalFov;
                liveCamera.nearClipPlane = normalNear;
                liveCamera.farClipPlane = normalFar;
                liveCamera.orthographic = normalOrthographic;
                liveCamera.orthographicSize = normalOrthoSize;
                liveCamera.backgroundColor = normalBackground;
                liveCamera.clearFlags = normalClearFlags;
                liveCamera.allowHDR = normalHdr;
            }
            if (urpCamera != null) urpCamera.renderPostProcessing = normalPostProcessing;
            RestorePresentationParents();
            urpCamera = null;
            liveCamera = null;
            character = null;
            characterRenderers = null;
        }
        public void RestorePresentationParents()
        {
            var worlds = FindObjectsByType<WorldRuntimeBridge>(FindObjectsInactive.Include);
            foreach (var parent in activatedParents) {
                if (parent == null) continue;
                bool owned = false;
                foreach (var world in worlds)
                    if (world.PresentationRoot == parent) { owned = true; break; }
                if (!owned) parent.SetActive(false);
            }
            activatedParents.Clear();
            // The world may have changed mode while compact owned its render mask.
            foreach (var world in worlds)
                if (world.PresentationRoot != null) {
                    world.PresentationRoot.SetActive(world.PresentationVisible);
                    Debug.Log($"[LiveCamRestore] root={world.PresentationRoot.name} visibleIntent={world.PresentationVisible} active={world.PresentationRoot.activeInHierarchy}");
                }
            if (character != null) {
                var renderers = character.GetComponentsInChildren<Renderer>(true);
                var planes = liveCamera != null ? GeometryUtility.CalculateFrustumPlanes(liveCamera) : null;
                int enabled = 0, inFrustum = 0;
                foreach (var renderer in renderers) {
                    if (renderer.enabled && renderer.gameObject.activeInHierarchy) enabled++;
                    if (planes != null && GeometryUtility.TestPlanesAABB(planes, renderer.bounds)) inFrustum++;
                }
                Debug.Log($"[LiveCamRestore] character={character.CharacterId} active={character.gameObject.activeInHierarchy} enabledRenderers={enabled}/{renderers.Length} frustumRenderers={inFrustum}/{renderers.Length}");
            }
        }
        void OnDestroy()
        {
            if (IsCompact) { EndLiveCam(); gmgn_unity_window_set_compact(0); }
        }
    }
}
