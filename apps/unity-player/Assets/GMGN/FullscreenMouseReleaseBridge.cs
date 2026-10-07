using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;

namespace GMGN.UnityPlayer
{
    /// Repairs the native release position before UI Toolkit sees the event.
    /// Keeps Clickable's normal press/release and drag-out cancellation semantics.
    public sealed class FullscreenMouseReleaseBridge : MonoBehaviour
    {
        [DllImport("UnityMediaHost")] static extern double gmgn_unity_cursor_content(int axis);
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Register()
        {
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            DontDestroyOnLoad(new GameObject("Fullscreen mouse release bridge").AddComponent<FullscreenMouseReleaseBridge>());
#endif
        }
        void OnEnable() => InputSystem.onEvent += OnInput;
        void OnDisable() => InputSystem.onEvent -= OnInput;
        public static bool IsBrokenRelease(bool fullscreen, Vector2 position, bool wasPressed, bool pressed)
            => fullscreen && position.x == 0 && position.y == 0 && wasPressed && !pressed;
        public static Vector2 ContentToFramebuffer(Vector2 normalized, Vector2 framebuffer)
            => Vector2.Scale(normalized, framebuffer);
        void OnInput(InputEventPtr input, InputDevice device)
        {
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            RepairInput(input,device,Screen.fullScreen,new Vector2(Screen.width,Screen.height),
                () => new Vector2((float)gmgn_unity_cursor_content(0), (float)gmgn_unity_cursor_content(1)));
#endif
        }
        public static bool RepairInput(InputEventPtr input, InputDevice device, bool fullscreen, Vector2 framebuffer,
            System.Func<Vector2> nativeCursor)
        {
            if (!fullscreen || device is not Mouse mouse || (!input.IsA<StateEvent>() && !input.IsA<DeltaStateEvent>())) return false;
            bool hasPosition=mouse.position.ReadValueFromEvent(input,out var position);
            if(!hasPosition) position=mouse.position.ReadValue();
            if(position.x!=0 || position.y!=0) return false;
            bool leftRelease=mouse.leftButton.ReadValueFromEvent(input,out var left) && mouse.leftButton.isPressed && left<=.5f;
            bool rightRelease=mouse.rightButton.ReadValueFromEvent(input,out var right) && mouse.rightButton.isPressed && right<=.5f;
            // Native full state and split delta events both exist. A zero position
            // delta can arrive before a button-only release; repair it while held
            // so InputForUI never caches the invalid pointer position.
            bool heldPosition=hasPosition && (mouse.leftButton.isPressed || mouse.rightButton.isPressed);
            if(!leftRelease && !rightRelease && !heldPosition) return false;
            var normalized=nativeCursor();
            if(!float.IsFinite(normalized.x) || !float.IsFinite(normalized.y)) return false;
            var corrected=ContentToFramebuffer(normalized,framebuffer);
            if(corrected==position) return false; // Genuine native bottom-left remains zero.
            if(hasPosition) mouse.position.WriteValueIntoEvent(corrected,input);
            else {
                // A button delta cannot hold extra position bytes. Update the
                // device BEFORE its release is processed. This fires the point
                // action first, refreshing InputForUI's cached LastPosition.
                InputState.Change(mouse.position,corrected);
            }
            Debug.Log($"Fullscreen mouse release position repaired: native={position}; framebuffer={corrected}; positionDelta={hasPosition}");
            return true;
        }
    }
}
