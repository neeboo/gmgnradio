using System;
using System.Reflection;
using System.Runtime.CompilerServices;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer
{
    // Unity 6000.6 keeps IMEEvent internal. Forward New Input System composition
    // through the same editor path as native events; never edit the draft value.
    public static class ChatImeBridge
    {
        const BindingFlags Instance = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
        static readonly Type EventType = typeof(TextField).Assembly.GetType("UnityEngine.UIElements.IMEEvent", true);
        static readonly MethodInfo Pool = EventType.GetMethod("GetPooled", BindingFlags.Static | BindingFlags.Public,
            null, new[] { typeof(string) }, null);
        static readonly PropertyInfo Manipulator = typeof(TextElement).GetProperty("editingManipulator", Instance);
        static readonly FieldInfo CompositionGetter = typeof(TextField).Assembly
            .GetType("UnityEngine.UIElements.BaseVisualElementPanel", true).GetField("IMEGetCompositionString", Instance);
        static readonly ConditionalWeakTable<IPanel, CompositionBinding> Bindings = new();
        static readonly ConditionalWeakTable<TextField, VisualElement> Carets = new();
        sealed class CursorAppearance { public Color color; }
        static readonly ConditionalWeakTable<TextField, CursorAppearance> NativeCursors = new();

        static int PreviewCursorIndex(TextElement input, string composition)
        {
            var manipulator = Manipulator.GetValue(input);
            var editing = manipulator.GetType().GetField("editingUtilities", Instance).GetValue(manipulator);
            var index = (int)editing.GetType().GetProperty("cursorIndexNoValidation", Instance).GetValue(editing);
            if (string.IsNullOrEmpty(composition)) return index;
            // Unity's preview cursor is temporary: native editing restores it to
            // the committed insertion point between IME events. Do not depend on
            // whether this frame happens to observe that temporary state.
            var saved = (int)editing.GetType().GetField("m_CursorIndexSavedState", Instance).GetValue(editing);
            return (saved >= 0 ? saved : index) + composition.Length;
        }

        public static void UpdateCompositionCaret(TextField field, string composition)
        {
            if (field == null) return;
            var active = !string.IsNullOrEmpty(composition) && FocusedField(field) == field;
            var input = field.Q<TextElement>(className:"unity-text-element");
            if (input == null) return;
            if (active) {
                NativeCursors.GetValue(field, _ => new CursorAppearance { color = input.selection.cursorColor });
                input.selection.cursorColor = Color.clear;
            } else if (NativeCursors.TryGetValue(field, out var appearance)) {
                input.selection.cursorColor = appearance.color;
                NativeCursors.Remove(field);
            }
            field.EnableInClassList("ime-composing", active);
            if (!active) {
                if (Carets.TryGetValue(field,out var old)) old.style.display = DisplayStyle.None;
                return;
            }
            var index = PreviewCursorIndex(input, composition);
            var position = input.selection.GetCursorPositionFromStringIndex(index);
            var caret = Carets.GetValue(field, _ => {
                var result = new VisualElement { name="ime-preview-caret", pickingMode=PickingMode.Ignore };
                result.style.position = Position.Absolute; result.style.width = 1;
                result.style.backgroundColor = new Color(.9f,.92f,.94f);
                input.Add(result); return result;
            });
            var height = input.resolvedStyle.fontSize;
            caret.style.display = DisplayStyle.Flex;
            caret.style.left = position.x; caret.style.top = position.y-height;
            caret.style.height = height;
        }

        // 6000.6's panel still reads legacy Input.compositionString even when
        // activeInputHandler is Input System only. The editor and its event must
        // read the same composition source (including an empty committed draft).
        sealed class CompositionBinding : IDisposable
        {
            readonly IPanel panel;
            readonly object original;
            public string composition = "";
            public CompositionBinding(IPanel panel) {
                this.panel = panel; original = CompositionGetter.GetValue(panel);
                CompositionGetter.SetValue(panel, (Func<string>)(() => composition));
            }
            public void Dispose() {
                CompositionGetter.SetValue(panel, original); Bindings.Remove(panel);
            }
        }

        public static IDisposable BindComposition(VisualElement root)
        {
            if (root?.panel == null) throw new InvalidOperationException("IME binding requires an attached panel");
            return Bindings.GetValue(root.panel, panel => new CompositionBinding(panel));
        }

        public static void SetComposition(VisualElement root, string composition)
        {
            if (root?.panel != null && Bindings.TryGetValue(root.panel, out var binding))
                binding.composition = composition ?? "";
        }

        public static TextField FocusedField(VisualElement root)
            => FieldForElement(root?.focusController?.focusedElement as VisualElement);

        public static TextField FieldForElement(VisualElement element)
        {
            TextField result = null;
            for (var focus = element; focus != null; focus = focus.parent) {
                if (focus.ClassListContains("hidden") || focus.style.display.value == DisplayStyle.None ||
                    focus.resolvedStyle.display == DisplayStyle.None) return null;
                if (focus is TextField text) result = text;
            }
            return result;
        }

        // Input System uses bottom-left screen pixels, while UI Toolkit uses
        // top-left panel points. Panel corner samples include Retina/UI scale.
        public static Vector2 CandidateScreenPosition(Vector2 caret, Vector2 panelOrigin, Vector2 panelExtent, Vector2 screenSize)
            => new Vector2((caret.x - panelOrigin.x) * screenSize.x / panelExtent.x,
                screenSize.y - (caret.y - panelOrigin.y) * screenSize.y / panelExtent.y);

        public static bool TryCandidatePosition(TextField field, Vector2 screenSize, out Vector2 position)
        {
            position = default;
            var input = field?.Q<TextElement>(className: "unity-text-element");
            if (input == null || field.panel == null) return false;
            var manipulator = Manipulator.GetValue(input);
            var editing = manipulator?.GetType().GetField("editingUtilities", Instance)?.GetValue(manipulator);
            if (editing == null) return false;
            var composition = Bindings.TryGetValue(field.panel, out var binding) ? binding.composition : "";
            var index = PreviewCursorIndex(input, composition);
            var local = input.selection.GetCursorPositionFromStringIndex(index);
            var caret = input.LocalToWorld(local);
            var origin = RuntimePanelUtils.ScreenToPanel(field.panel, Vector2.zero);
            var extent = RuntimePanelUtils.ScreenToPanel(field.panel, screenSize) - origin;
            if (extent.x <= 0 || extent.y <= 0) return false;
            position = CandidateScreenPosition(caret, origin, extent, screenSize);
            return float.IsFinite(position.x) && float.IsFinite(position.y);
        }

        public static bool Forward(TextField field, string composition)
        {
            SetComposition(field, composition);
            var input = field?.Q<TextElement>(className: "unity-text-element");
            if (input == null || field.panel == null) return false;
            var focused = field.panel.focusController.focusedElement as VisualElement;
            if (focused != field && !field.Contains(focused)) return false;
            var manipulator = Manipulator.GetValue(input);
            var handler = manipulator?.GetType().GetProperty("keyboardEditingEventHandler", Instance)?.GetValue(manipulator);
            var current = handler?.GetType().GetField("m_compositionString", Instance)?.GetValue(handler) as string;
            if (current == (composition ?? "")) {
                UpdateCompositionCaret(field, composition);
                return false; // Native provider has already delivered it.
            }
            using var evt = (EventBase)Pool.Invoke(null, new object[] { composition ?? "" });
            input.SendEvent(evt);
            UpdateCompositionCaret(field, composition);
            return true;
        }

        public static bool BlocksSubmit(string composition, int frame, int endedFrame)
            => !string.IsNullOrEmpty(composition) || frame <= endedFrame + 1;

        public static bool ShouldSubmit(KeyDownEvent evt, string composition, int frame, int endedFrame)
        {
            if ((evt.keyCode != KeyCode.Return && evt.keyCode != KeyCode.KeypadEnter) || evt.shiftKey) return false;
            evt.StopImmediatePropagation(); evt.PreventDefault();
            return !BlocksSubmit(composition, frame, endedFrame);
        }
    }
}
