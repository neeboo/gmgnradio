using System;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    // Pointer capture keeps release reliable even when the mouse leaves the button.
    public sealed class UnityPushToTalkControl : IDisposable
    {
        readonly VisualElement button;
        readonly Action<string> command;
        int pointer = -1;
        public UnityPushToTalkControl(VisualElement button, Action<string> command)
        {
            this.button = button; this.command = command;
            button.RegisterCallback<PointerDownEvent>(Down);
            button.RegisterCallback<PointerUpEvent>(Up);
            button.RegisterCallback<PointerCaptureOutEvent>(Lost);
            button.RegisterCallback<DetachFromPanelEvent>(Detached);
        }
        void Down(PointerDownEvent e)
        {
            if (e.button != 0 || pointer >= 0) return;
            pointer = e.pointerId; button.CapturePointer(pointer);
            command("voice.press"); e.StopPropagation();
        }
        void Up(PointerUpEvent e)
        {
            if (e.pointerId != pointer) return;
            int old = pointer; pointer = -1;
            command("voice.release"); button.ReleasePointer(old); e.StopPropagation();
        }
        void Lost(PointerCaptureOutEvent e) { Cancel(); }
        void Detached(DetachFromPanelEvent e) { Cancel(); }
        public void Cancel()
        {
            if (pointer < 0) return;
            int old = pointer; pointer = -1;
            command("voice.cancel"); button.ReleasePointer(old);
        }
        public void Dispose()
        {
            Cancel();
            button.UnregisterCallback<PointerDownEvent>(Down);
            button.UnregisterCallback<PointerUpEvent>(Up);
            button.UnregisterCallback<PointerCaptureOutEvent>(Lost);
            button.UnregisterCallback<DetachFromPanelEvent>(Detached);
        }
    }
}
