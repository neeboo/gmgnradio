using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.UIElements;
using Newtonsoft.Json.Linq;
using System.Runtime.InteropServices;

namespace GMGN.UnityPlayer
{
    /// Read-only free view; never updates authoritative object/camera records.
    public sealed class WorldCameraController : MonoBehaviour
    {
        Camera view;
        UIDocument document;
        bool active, dragging;
        float yaw, pitch;
        Transform resident;
        string residentWorld;
        System.Func<bool> followAllowed;
        Vector3 previousResidentPosition;
        bool hasPreviousResident;
        float pendingFollowYaw;
        float lastUserInteraction = float.NegativeInfinity;
        Vector3 cameraHomePosition;
        Quaternion cameraHomeRotation;
        bool hasCameraHome;
        readonly CameraKeyboardGate keyboardGate = new CameraKeyboardGate();
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
        [DllImport("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")]
        [return: MarshalAs(UnmanagedType.I1)]
        static extern bool CGEventSourceKeyState(int state, ushort key);
#endif
        const float WalkSpeed = 3f;
        const float FastSpeed = 8f;
        const float LookSensitivity = .24f;
        public void Configure(Camera camera, UIDocument ui) { view = camera; document = ui; }
        public Camera PresentationCamera => view;
        public JObject ExecuteCommand(JObject command)
        {
            if (!active || !isActiveAndEnabled || view == null || !view.enabled)
                throw new System.InvalidOperationException("normal_world_camera_unavailable");
            string direction = (string)command?["direction"];
            float distance = (float?)command?["distance"] ?? 2;
            if (!float.IsFinite(distance)) throw new System.ArgumentException("invalid_camera_distance");
            distance = Mathf.Clamp(distance, .5f, 10);
            float radians = view.transform.eulerAngles.y * Mathf.Deg2Rad;
            var right = new Vector3(Mathf.Cos(radians), 0, -Mathf.Sin(radians));
            switch (direction) {
                case "forward": view.transform.position += view.transform.forward * distance; break;
                case "backward": view.transform.position -= view.transform.forward * distance; break;
                case "left": view.transform.position -= right * distance; break;
                case "right": view.transform.position += right * distance; break;
                case "reset":
                    if (!hasCameraHome) throw new System.InvalidOperationException("camera_home_unavailable");
                    view.transform.SetPositionAndRotation(cameraHomePosition, cameraHomeRotation);
                    break;
                default: throw new System.ArgumentException("invalid_camera_direction");
            }
            var angles = view.transform.eulerAngles;
            yaw = angles.y; pitch = Mathf.DeltaAngle(0, angles.x);
            RecordUserInteraction(Time.unscaledTime);
            return new JObject { ["direction"] = direction, ["distance"] = distance,
                ["camera"] = ReadCameraState() };
        }
        public JObject ReadCameraState()
        {
            if (view == null) return null;
            var position = view.transform.position; var rotation = view.transform.rotation;
            // Receipt uses the same right-handed world coordinates as authority.
            return new JObject {
                ["position"] = new JObject { ["x"] = position.x, ["y"] = position.y, ["z"] = -position.z },
                ["rotation"] = new JObject { ["x"] = -rotation.x, ["y"] = -rotation.y, ["z"] = rotation.z, ["w"] = rotation.w },
                ["fieldOfViewDegrees"] = view.fieldOfView,
                ["nearPlane"] = view.nearClipPlane, ["farPlane"] = view.farClipPlane
            };
        }
        public void BindResident(Transform value, string world, System.Func<bool> allowed)
        {
            if (resident != value || residentWorld != world) ResetFollow();
            resident = value; residentWorld = world; followAllowed = allowed;
        }
        void ResetFollow() { hasPreviousResident = false; pendingFollowYaw = 0; }
        void OnDisable() { ResetFollow(); keyboardGate.Suspend(); dragging = false; }
        void OnApplicationFocus(bool focused) { if (!focused) { keyboardGate.Suspend(); dragging = false; } }
        void OnApplicationPause(bool paused) { if (paused) { keyboardGate.Suspend(); dragging = false; } }
        public void RecordUserInteraction(float now)
        {
            lastUserInteraction = now;
            pendingFollowYaw = 0;
        }
        public void ObserveResident(float now)
        {
            if (!active || view == null || resident == null || followAllowed?.Invoke() != true) { ResetFollow(); return; }
            var current = resident.position;
            if (hasPreviousResident) {
                var before = previousResidentPosition - view.transform.position;
                var after = current - view.transform.position;
                if (before.x * before.x + before.z * before.z > .0001f &&
                    after.x * after.x + after.z * after.z > .0001f && now - lastUserInteraction >= 1) {
                    // Unity mirrors world Z: its positive yaw turns toward +X.
                    float previousBearing = Mathf.Atan2(before.x, before.z) * Mathf.Rad2Deg;
                    float currentBearing = Mathf.Atan2(after.x, after.z) * Mathf.Rad2Deg;
                    pendingFollowYaw += Mathf.DeltaAngle(previousBearing, currentBearing);
                }
            }
            previousResidentPosition = current; hasPreviousResident = true;
        }
        public void AdvanceFollow(float deltaTime)
        {
            if (!active || followAllowed?.Invoke() != true) { ResetFollow(); return; }
            if (deltaTime >= .5f) { pendingFollowYaw = 0; return; }
            if (deltaTime <= 0 || pendingFollowYaw == 0 || view == null) return;
            float applied = pendingFollowYaw * (1 - Mathf.Exp(-deltaTime / .030f));
            pendingFollowYaw -= applied;
            view.transform.rotation = Quaternion.AngleAxis(applied, Vector3.up) * view.transform.rotation;
            yaw = view.transform.eulerAngles.y;
        }
        void LateUpdate()
        {
            ObserveResident(Time.unscaledTime);
            AdvanceFollow(Time.unscaledDeltaTime);
        }
        public void SetActive(bool value)
        {
            active = value; dragging = false;
            if (!value) keyboardGate.Suspend();
            ResetFollow();
            if (value && view != null) {
                cameraHomePosition = view.transform.position;
                cameraHomeRotation = view.transform.rotation;
                hasCameraHome = true;
                var angles = view.transform.eulerAngles;
                yaw = angles.y; pitch = Mathf.DeltaAngle(0, angles.x);
            }
        }

        void Update()
        {
            if (GetComponent<GPUIChat2Probe>()?.BlocksWorldInput == true) {
                keyboardGate.Suspend(); dragging = false; return;
            }
            if (!active || !Application.isFocused || view == null || Mouse.current == null) {
                keyboardGate.Suspend(); dragging = false; return;
            }
            var mouse = Mouse.current;
            var interaction = GetComponent<WorldInteractionController>();
            if (interaction?.OwnsPointer == true || (mouse.rightButton.isPressed && interaction?.BlocksCameraAt(mouse.position.ReadValue()) == true)) {
                keyboardGate.Suspend(); dragging = false; return;
            }
            if (mouse.rightButton.wasReleasedThisFrame) dragging = false;
            if (UIOwnsInput(mouse.position.ReadValue())) { keyboardGate.Suspend(); dragging = false; return; }
            if (mouse.rightButton.wasPressedThisFrame) dragging = true;
            if (dragging && mouse.rightButton.isPressed) {
                var delta = mouse.delta.ReadValue();
                // Mouse delta is already accumulated for this frame; do not
                // multiply it by deltaTime and make dragging frame-rate dependent.
                yaw += delta.x * LookSensitivity; pitch = Mathf.Clamp(pitch - delta.y * LookSensitivity, -85, 85);
                view.transform.rotation = Quaternion.Euler(pitch, yaw, 0);
                RecordUserInteraction(Time.unscaledTime);
            }
            var movement = Vector3.zero;
            var keyboard = Keyboard.current;
            int keys = keyboardGate.Read(ReadMovementKeys(keyboard));
            if (keyboard != null) {
                if ((keys & 1) != 0) movement += view.transform.forward;
                if ((keys & 2) != 0) movement -= view.transform.forward;
                if ((keys & 4) != 0) movement += view.transform.right;
                if ((keys & 8) != 0) movement -= view.transform.right;
                if (movement.sqrMagnitude > 0) movement = movement.normalized * Time.unscaledDeltaTime * (keyboard.shiftKey.isPressed ? FastSpeed : WalkSpeed);
            }
            movement += view.transform.forward * Mathf.Clamp(mouse.scroll.ReadValue().y / 120f, -4, 4) * 1.2f;
            if (movement.sqrMagnitude > 0) RecordUserInteraction(Time.unscaledTime);
            view.transform.position += movement;
        }

        static int ReadMovementKeys(Keyboard keyboard)
        {
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            // Read the session's current key state: Unity's cached key state
            // can remain pressed when Cocoa routes key-up to a text/popup window.
            return (CGEventSourceKeyState(0, 13) ? 1 : 0) |
                (CGEventSourceKeyState(0, 1) ? 2 : 0) |
                (CGEventSourceKeyState(0, 2) ? 4 : 0) |
                (CGEventSourceKeyState(0, 0) ? 8 : 0);
#else
            if (keyboard == null) return 0;
            return (keyboard.wKey.isPressed ? 1 : 0) | (keyboard.sKey.isPressed ? 2 : 0) |
                (keyboard.dKey.isPressed ? 4 : 0) | (keyboard.aKey.isPressed ? 8 : 0);
#endif
        }

        bool UIOwnsInput(Vector2 screen)
        {
            var root = document?.rootVisualElement;
            if (root?.panel == null) return false;
            var textFocused = false;
            for (var focus = root.focusController?.focusedElement as VisualElement; focus != null; focus = focus.parent) {
                if (focus.resolvedStyle.display == DisplayStyle.None) { textFocused = false; break; }
                if (focus is TextField) textFocused = true;
            }
            if (textFocused) return true;
            var point = RuntimePanelUtils.ScreenToPanel(root.panel, new Vector2(screen.x, Screen.height - screen.y));
            for (var hit = root.panel.Pick(point); hit != null; hit = hit.parent)
                if (hit is Button || hit is TextField || hit is Slider || hit is ScrollView || hit is ListView) return true;
            return false;
        }
    }

}
