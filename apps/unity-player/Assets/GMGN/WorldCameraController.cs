using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    /// Read-only free view; never updates authoritative object/camera records.
    public sealed class WorldCameraController : MonoBehaviour
    {
        Camera view;
        UIDocument document;
        bool active, dragging;
        float yaw, pitch;
        const float WalkSpeed = 3f;
        const float FastSpeed = 8f;
        const float LookSensitivity = .24f;
        public void Configure(Camera camera, UIDocument ui) { view = camera; document = ui; }
        public void SetActive(bool value)
        {
            active = value; dragging = false;
            if (value && view != null) {
                var angles = view.transform.eulerAngles;
                yaw = angles.y; pitch = Mathf.DeltaAngle(0, angles.x);
            }
        }

        void Update()
        {
            if (!active || !Application.isFocused || view == null || Mouse.current == null) return;
            var mouse = Mouse.current;
            var interaction = GetComponent<WorldInteractionController>();
            if (interaction?.OwnsPointer == true || (mouse.rightButton.isPressed && interaction?.BlocksCameraAt(mouse.position.ReadValue()) == true)) {
                dragging = false; return;
            }
            if (mouse.rightButton.wasReleasedThisFrame) dragging = false;
            if (UIOwnsInput(mouse.position.ReadValue())) { dragging = false; return; }
            if (mouse.rightButton.wasPressedThisFrame) dragging = true;
            if (dragging && mouse.rightButton.isPressed) {
                var delta = mouse.delta.ReadValue();
                // Mouse delta is already accumulated for this frame; do not
                // multiply it by deltaTime and make dragging frame-rate dependent.
                yaw += delta.x * LookSensitivity; pitch = Mathf.Clamp(pitch - delta.y * LookSensitivity, -85, 85);
                view.transform.rotation = Quaternion.Euler(pitch, yaw, 0);
            }
            var movement = Vector3.zero;
            var keyboard = Keyboard.current;
            if (keyboard != null) {
                if (keyboard.wKey.isPressed) movement += view.transform.forward;
                if (keyboard.sKey.isPressed) movement -= view.transform.forward;
                if (keyboard.dKey.isPressed) movement += view.transform.right;
                if (keyboard.aKey.isPressed) movement -= view.transform.right;
                if (movement.sqrMagnitude > 0) movement = movement.normalized * Time.unscaledDeltaTime * (keyboard.shiftKey.isPressed ? FastSpeed : WalkSpeed);
            }
            movement += view.transform.forward * Mathf.Clamp(mouse.scroll.ReadValue().y / 120f, -4, 4) * 1.2f;
            view.transform.position += movement;
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
                if (hit is Button || hit is TextField || hit is Slider || hit is ScrollView || hit is ListView ||
                    hit.name == "chatPanel" || hit.name == "worldInteraction" || hit.ClassListContains("queue-panel")) return true;
            return false;
        }
    }
}
