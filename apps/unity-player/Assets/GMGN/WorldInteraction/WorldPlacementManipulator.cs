using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    /// Captures only gestures which begin on an actual restored prop.
    sealed class WorldPlacementManipulator : PointerManipulator
    {
        readonly WorldInteractionController owner;
        Vector2 start;
        int pointerID, button;
        bool changed, releasing;
        public bool Dragging { get; private set; }
        public WorldPlacementManipulator(WorldInteractionController owner) { this.owner = owner; }
        protected override void RegisterCallbacksOnTarget()
        {
            target.RegisterCallback<PointerDownEvent>(Down, TrickleDown.TrickleDown);
            target.RegisterCallback<PointerMoveEvent>(Move);
            target.RegisterCallback<PointerUpEvent>(Up);
            target.RegisterCallback<PointerCaptureOutEvent>(Lost);
        }
        protected override void UnregisterCallbacksFromTarget()
        {
            Abort();
            target.UnregisterCallback<PointerDownEvent>(Down, TrickleDown.TrickleDown);
            target.UnregisterCallback<PointerMoveEvent>(Move);
            target.UnregisterCallback<PointerUpEvent>(Up);
            target.UnregisterCallback<PointerCaptureOutEvent>(Lost);
        }
        void Down(PointerDownEvent e)
        {
            if (Dragging || !owner.BeginGesture(e)) return;
            pointerID = e.pointerId; button = e.button; start = e.position;
            changed = false; Dragging = true; target.CapturePointer(pointerID); e.StopPropagation();
        }
        void Move(PointerMoveEvent e)
        {
            if (!Dragging || e.pointerId != pointerID) return;
            Vector2 point = e.position;
            if ((point - start).sqrMagnitude >= 9) changed = true;
            if (changed) owner.MoveGesture(start, point, button);
            e.StopPropagation();
        }
        void Up(PointerUpEvent e)
        {
            if (!Dragging || e.pointerId != pointerID || e.button != button) return;
            Release(); owner.EndGesture(changed); e.StopPropagation();
        }
        void Lost(PointerCaptureOutEvent e) { if (!releasing && Dragging) Abort(); }
        void Release()
        {
            Dragging = false; releasing = true;
            if (target.HasPointerCapture(pointerID)) target.ReleasePointer(pointerID);
            releasing = false;
        }
        public void Abort() { Release(); owner.AbortGesture(); }
    }
}
