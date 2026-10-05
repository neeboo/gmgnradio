using System;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class ChatUiChecks
    {
        public static void Verify()
        {
            GameObject owner = null;
            try {
                void Require(bool value, string message) { if (!value) throw new Exception(message); }
                var viewport = new Vector2(800, 600);
                Require(ResidentThinkingCloud.TryAnchor(new Vector2(400, 300), 100, viewport, out var far), "Far character anchor missing");
                Require(far == new Vector2(360, 214), "Far character gap differs from SceneKit geometry");
                Require(ResidentThinkingCloud.TryAnchor(new Vector2(400, 300), 500, viewport, out var near), "Near character anchor missing");
                Require(near == new Vector2(360, 196), "Near character gap must clamp to 38");
                Require(!ResidentThinkingCloud.TryAnchor(new Vector2(400, 40), 100, viewport, out _), "Offscreen cloud must not clamp into view");
                Require(!ResidentThinkingCloud.TryAnchor(new Vector2(-10, 300), 100, viewport, out _), "Offscreen character must not show cloud");
                owner = new GameObject("Chat UI Check");
                var cloud = owner.AddComponent<ResidentThinkingCloud>();
                cloud.Initialize(new VisualElement());
                cloud.SetPending(true); Require(cloud.IsPending, "Pending request must enable thinking state");
                cloud.SetPending(false); Require(!cloud.IsPending, "Completion/failure/cancel must clear thinking state");
                Debug.Log("Chat UI checks PASS: 8 cloud geometry and lifecycle checks; real scrolling remains runtime acceptance");
                UnityEngine.Object.DestroyImmediate(owner);
                EditorApplication.Exit(0);
            } catch (Exception error) { if (owner != null) UnityEngine.Object.DestroyImmediate(owner); Debug.LogException(error); EditorApplication.Exit(1); }
        }
    }
}
