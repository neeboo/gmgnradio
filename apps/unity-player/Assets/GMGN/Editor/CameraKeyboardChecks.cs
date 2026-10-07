using System;

namespace GMGN.UnityPlayer.Editor
{
    public static class CameraKeyboardChecks
    {
#if CAMERA_KEYBOARD_STANDALONE
        public static void Main() => Validate();
#endif
        public static void Validate()
        {
            var gate = new CameraKeyboardGate();
            Require(gate.Read(1) == 1 && gate.Read(1) == 1, "Normal held W must continue moving.");
            foreach (var owner in new[] { "lost focus", "text input", "panel", "inactive camera", "paused app" }) {
                gate.Suspend();
                Require(gate.Read(1) == 0 && gate.Read(1) == 0, owner + " must not replay a key held across suspension.");
                // Native state becomes zero after physical release even if Unity
                // still caches W as pressed because its key-up was lost.
                Require(gate.Read(0) == 0 && gate.Read(0) == 0, owner + " must stay still after release without key-up.");
                Require(gate.Read(4) == 4 && gate.Read(4) == 4, owner + " must accept a fresh held D.");
            }
            gate.Suspend(); gate.Suspend();
            Require(gate.Read(9) == 0 && gate.Read(8) == 0, "All movement keys must release before rearming.");
            Require(gate.Read(0) == 0 && gate.Read(9) == 9, "Diagonal movement must resume after release.");
#if !CAMERA_KEYBOARD_STANDALONE
            ValidateControllerLifecycle();
#endif
            Console.WriteLine("PASS camera keyboard: normal held keys; focus/text/panel/disable/pause release without key-up; fresh press and diagonal rearm.");
        }
#if !CAMERA_KEYBOARD_STANDALONE
        static void ValidateControllerLifecycle()
        {
            var host = new UnityEngine.GameObject("camera-keyboard-fixture");
            try {
                var controller = host.AddComponent<WorldCameraController>();
                const System.Reflection.BindingFlags flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
                var type = typeof(WorldCameraController);
                var gate = (CameraKeyboardGate)type.GetField("keyboardGate", flags).GetValue(controller);
                void CheckSuspended(string callback, object value)
                {
                    Require(gate.Read(1) == 1, callback + " fixture starts with a held key.");
                    type.GetMethod(callback, flags).Invoke(controller, new[] { value });
                    Require(gate.Read(1) == 0, callback + " must suspend actual controller keyboard input.");
                    Require(gate.Read(0) == 0 && gate.Read(4) == 4, callback + " must allow a fresh press after release.");
                }
                CheckSuspended("OnApplicationFocus", false);
                CheckSuspended("OnApplicationPause", true);
                controller.SetActive(false);
                Require(gate.Read(4) == 0, "SetActive(false) must suspend actual controller keyboard input.");
                gate.Read(0);
                // Non-ExecuteAlways MonoBehaviours do not receive lifecycle
                // callbacks in EditMode; invoke the actual callback explicitly.
                type.GetMethod("OnDisable", flags).Invoke(controller, null);
                Require(gate.Read(4) == 0, "OnDisable must suspend actual controller keyboard input.");
                gate.Read(0);
                type.GetMethod("OnApplicationFocus", flags).Invoke(controller, new object[] { true });
                type.GetMethod("OnApplicationPause", flags).Invoke(controller, new object[] { false });
                Require(gate.Read(1) == 1 && gate.Read(1) == 1, "Focus gain and unpause must preserve normal held input.");
                Console.WriteLine("PASS camera keyboard Unity integration: actual focus/pause/inactive/disable callbacks and fresh input recovery.");
            } finally { UnityEngine.Object.DestroyImmediate(host); }
        }
#endif
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    }
}
