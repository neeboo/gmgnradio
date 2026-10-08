using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    // Rotate only the point draw matrix: the shared player/world GameObject stays unchanged.
    public sealed class StagePointRotationController : MonoBehaviour
    {
        AudioSculpture sculpture;
        GpuPointCloud cloud;
        UIDocument document;
        bool dragging;
        float yaw, pitch;
        public void Configure(AudioSculpture source, GpuPointCloud renderer)
        {
            sculpture = source; cloud = renderer;
            document = GetComponent<UIDocument>();
            if (document == null) document = FindAnyObjectByType<UIDocument>();
        }

        void Update()
        {
            if (sculpture == null || !sculpture.isActiveAndEnabled || cloud == null || !cloud.isActiveAndEnabled ||
                !Application.isFocused || Mouse.current == null || sculpture.Choice == "void") {
                dragging = false; return;
            }
            var mouse = Mouse.current;
            if (!mouse.leftButton.isPressed && !mouse.rightButton.isPressed) dragging = false;
            if (UIOwnsInput(mouse.position.ReadValue())) { dragging = false; return; }
            if (mouse.leftButton.wasPressedThisFrame || mouse.rightButton.wasPressedThisFrame) dragging = true;
            if (!dragging) return;
            var delta = mouse.delta.ReadValue();
            yaw = Mathf.Repeat(yaw - delta.x * .24f, 360);
            pitch = Mathf.Clamp(pitch + delta.y * .24f, -85, 85);
            cloud.StageRotation = Quaternion.Euler(pitch, yaw, 0);
        }

        bool UIOwnsInput(Vector2 screen)
        {
            if (GetComponent<GPUIChat2Probe>()?.BlocksWorldInput == true) return true;
            var root = document?.rootVisualElement;
            if (root?.panel == null) return false;
            for (var focus = root.focusController?.focusedElement as VisualElement; focus != null; focus = focus.parent) {
                if (focus.resolvedStyle.display == DisplayStyle.None) break;
                if (focus is TextField) return true;
            }
            var point = RuntimePanelUtils.ScreenToPanel(root.panel, new Vector2(screen.x, Screen.height - screen.y));
            for (var hit = root.panel.Pick(point); hit != null; hit = hit.parent)
                if (hit is Button || hit is TextField || hit is Slider || hit is ScrollView || hit is ListView) return true;
            return false;
        }
    }
}
