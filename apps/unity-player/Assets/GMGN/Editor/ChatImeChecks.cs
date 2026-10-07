using System;
using System.Reflection;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class ChatImeChecks
    {
        public static void VerifyRuntime()
        {
            var go = new GameObject("Runtime IME panel check");
            var document = go.AddComponent<UIDocument>();
            var settings = UnityEngine.Object.Instantiate(Resources.Load<PanelSettings>("PlayerPanel"));
            settings.scale = 2; document.panelSettings = settings;
            var root = document.rootVisualElement;
            root.AddToClassList("document-root"); root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            var field = new TextField { value = "prefix ", multiline = true };
            field.textEdition.placeholder = "和角色聊聊…";
            field.AddToClassList("draft");
            field.style.width = 450; field.style.height = 60; field.style.marginLeft = 40; field.style.marginTop = 50;
            root.Add(field); field.Focus();
            var deadline = EditorApplication.timeSinceStartup + 1;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    void Require(bool value, string message) { if (!value) throw new Exception(message); }
                    Require(root.panel != null && root.panel.contextType == ContextType.Player, "Must test an actual runtime panel");
                    using var binding = ChatImeBridge.BindComposition(root);
                    field.SelectRange(7,7);
                    var nativeInput = field.Q<TextElement>(className:"unity-text-element");
                    var cursorColor = new Color(.23f,.48f,.77f);
                    nativeInput.selection.cursorColor = cursorColor;
                    var screen = new Vector2(Screen.width, Screen.height);
                    Require(screen.x > 0 && screen.y > 0, "Runtime screen geometry must be available");
                    Require(ChatImeBridge.TryCandidatePosition(field, screen, out var initial), "Runtime caret coordinates must be available");
                    Require(ChatImeBridge.Forward(field, "shuo hua"), "Runtime composition must reach text editing");
                    Require(nativeInput.selection.cursorColor == Color.clear, "Actual native caret color must become transparent");
                    var previewCaret = nativeInput.Q<VisualElement>("ime-preview-caret");
                    previewCaret.style.left = -100;
                    Require(!ChatImeBridge.Forward(field, "shuo hua"), "Duplicate native composition must not be delivered twice");
                    Require(previewCaret.style.left.value.value >= 0 && nativeInput.selection.cursorColor == Color.clear,
                        "Duplicate composition callback must refresh preview geometry and hide native caret immediately");
                    var getter = typeof(TextField).Assembly.GetType("UnityEngine.UIElements.BaseVisualElementPanel",true)
                        .GetField("IMEGetCompositionString",BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                    Require(((Func<string>)getter.GetValue(root.panel))() == "shuo hua", "Runtime native editor must read Input System composition, not legacy Input");
                    Require(ChatImeBridge.TryCandidatePosition(field, screen, out var composing), "Runtime composition caret coordinates must be available");
                    Require(composing.x > initial.x, $"Runtime candidate anchor must follow composition: initial={initial}, composing={composing}");
                    Require(composing.x > 0 && composing.y > 0 && composing.x < screen.x && composing.y < screen.y,
                        $"Runtime candidate anchor must remain inside window: {composing}, screen={screen}");
                    Require(ChatImeBridge.Forward(field, ""), "Runtime cancellation must clear preview");
                    Require(nativeInput.selection.cursorColor == cursorColor, "Composition end must restore original native caret color");
                    Require(ChatImeBridge.TryCandidatePosition(field, screen, out var restored) && (restored-initial).sqrMagnitude < .01f,
                        "Runtime cancellation must restore candidate anchor");
                    field.value = ""; field.SelectRange(0,0);
                    Require(ChatImeBridge.TryCandidatePosition(field,screen,out var empty), "Empty input caret must be available");
                    Require(ChatImeBridge.Forward(field,"shuo hua"), "Empty-input composition must be displayed");
                    Require(ChatImeBridge.TryCandidatePosition(field,screen,out var emptyComposing) && emptyComposing.x > empty.x,
                        "Empty-input candidate anchor must follow typing");
                    var input = field.Q<TextElement>(className:"unity-text-element");
                    var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
                    var manip = typeof(TextElement).GetProperty("editingManipulator",flags).GetValue(input);
                    var edit = manip.GetType().GetField("editingUtilities",flags).GetValue(manip);
                    var select = typeof(TextElement).GetProperty("selectingManipulator",flags).GetValue(input);
                    var utils = select.GetType().GetField("m_SelectingUtilities",flags).GetValue(select);
                    var handle = typeof(TextElement).GetProperty("uitkTextHandle",flags).GetValue(input);
                    Debug.Log($"IME internals: raw={edit.GetType().GetProperty("cursorIndexNoValidation",flags).GetValue(edit)} selectraw={utils.GetType().GetProperty("cursorIndex",flags).GetValue(utils)} placeholder={handle.GetType().GetProperty("IsPlaceholder",flags).GetValue(handle)}");
                    Debug.Log($"Empty composition diagnostics: preview={input.text}, committed={field.value}, drawIndex={input.selection.cursorIndex}, drawPosition={input.selection.cursorPosition}, explicitEnd={input.selection.GetCursorPositionFromStringIndex(8)}");
                    var overlay = input.Q<VisualElement>("ime-preview-caret");
                    var actualEnd = input.selection.GetCursorPositionFromStringIndex(8);
                    Require(overlay != null && overlay.style.display.value == DisplayStyle.Flex &&
                        Mathf.Abs(overlay.style.left.value.value-actualEnd.x) < .01f,
                        "Visible composition caret must draw at preview end even when native selection remains committed index 0");
                    Require(field.ClassListContains("ime-composing"), "Composition must hide stale native caret");
                    Require(ChatImeBridge.Forward(field,""), "Empty-input cancellation must clear preview");
                    Require(!field.ClassListContains("ime-composing") && overlay.style.display.value == DisplayStyle.None,
                        "Cancellation must restore native caret and remove preview caret");
                    // Native key handling may restore the temporary preview cursor
                    // before the next PlayerScreen.Update. Reproduce the reported
                    // Chinese-prefix + Latin-composition sequence in that state.
                    field.value = "自己找点"; field.SelectRange(4,4);
                    Require(ChatImeBridge.TryCandidatePosition(field,screen,out var chinesePrefix), "Chinese-prefix insertion position must be available");
                    Require(ChatImeBridge.Forward(field,"er"), "Chinese-prefix composition must reach editing");
                    Require(input.text == "自己找点er", "Composition must preserve Chinese prefix in the rendered preview");
                    edit.GetType().GetMethod("RestoreCursorState",flags).Invoke(edit,null);
                    Require((int)edit.GetType().GetProperty("cursorIndexNoValidation",flags).GetValue(edit) == 4,
                        "Regression must exercise restored committed cursor, not temporary preview cursor");
                    ChatImeBridge.UpdateCompositionCaret(field,"er");
                    var chineseEnd = input.selection.GetCursorPositionFromStringIndex(6);
                    Require(Mathf.Abs(overlay.style.left.value.value-chineseEnd.x) < .01f,
                        "Visible caret must stay after er when native cursor has been restored before update");
                    Require(ChatImeBridge.TryCandidatePosition(field,screen,out var chineseComposing) && chineseComposing.x > chinesePrefix.x,
                        "Candidate anchor must stay after er when native cursor has been restored before update");
                    Require(ChatImeBridge.Forward(field,"ers"), "Composition growth must update preview");
                    ChatImeBridge.UpdateCompositionCaret(field,"ers");
                    Require(Mathf.Abs(overlay.style.left.value.value-input.selection.GetCursorPositionFromStringIndex(7).x) < .01f,
                        "Temporary preview index must not count composition length twice");
                    Require(ChatImeBridge.Forward(field,""), "Chinese-prefix cancellation must restore committed draft");
                    Require(field.value == "自己找点" && !field.ClassListContains("ime-composing"), "Cancellation must preserve Chinese draft and restore native caret");
                    Require(nativeInput.selection.cursorColor == cursorColor, "Repeated composition must preserve original caret appearance");
                    ChatImeBridge.Forward(field,"er");
                    field.Blur();
                    ChatImeBridge.UpdateCompositionCaret(field,"er");
                    Require(nativeInput.selection.cursorColor == cursorColor && overlay.style.display.value == DisplayStyle.None,
                        "Blur must restore native caret and hide preview even while composition is nonempty");
                    Debug.Log($"ChatImeRuntimeChecks PASS: actual Player panel scale=2, preview caret and candidate anchor initial={initial}, composing={composing}, restored={restored}");
                    EditorApplication.update -= check; UnityEngine.Object.DestroyImmediate(go); UnityEngine.Object.DestroyImmediate(settings); EditorApplication.Exit(0);
                } catch (Exception error) {
                    Debug.LogException(error); EditorApplication.update -= check; UnityEngine.Object.DestroyImmediate(go); UnityEngine.Object.DestroyImmediate(settings); EditorApplication.Exit(1);
                }
            };
            EditorApplication.update += check;
        }
        public static void Verify()
        {
            var window = ScriptableObject.CreateInstance<EditorWindow>();
            window.position = new Rect(0, 0, 600, 300);
            var field = new TextField { multiline = true, value = "prefix " };
            window.rootVisualElement.Add(field); window.Show(); field.Focus();
            var deadline = EditorApplication.timeSinceStartup + 1;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    void Require(bool value, string message) { if (!value) throw new Exception(message); }
                    using var binding = ChatImeBridge.BindComposition(window.rootVisualElement);
                    field.SelectRange(7, 7);
                    foreach (var text in new[] { "shuo hua", "说话", "はなす" }) {
                        Require(ChatImeBridge.Forward(field, text), "Composition must reach TextField");
                        var element = field.Q<TextElement>(className: "unity-text-element");
                        Require(element.text == "prefix " + text, $"Preview must keep prefix: {element.text}");
                        var manipulator = typeof(TextElement).GetProperty("editingManipulator", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(element);
                        var editing = manipulator.GetType().GetField("editingUtilities", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public).GetValue(manipulator);
                        var cursor = (int)editing.GetType().GetProperty("cursorIndexNoValidation", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public).GetValue(editing);
                        Require(cursor == 7 + text.Length, $"Render caret must follow composition preview: {cursor}, text={element.text}");
                        Require(!ChatImeBridge.Forward(field, text), "Already-delivered native composition must not be injected twice");
                        Require(ChatImeBridge.BlocksSubmit(text, 10, -10), "Chinese/Japanese confirmation must not submit");
                    }
                    Require(ChatImeBridge.Forward(field, ""), "Composition cancellation must clear preview");
                    Require(field.Q<TextElement>(className: "unity-text-element").text == "prefix ", "Cancellation must restore original text");
                    Require(ChatImeBridge.BlocksSubmit("", 11, 10), "Same-frame/next-frame confirm cannot send");
                    Require(!ChatImeBridge.BlocksSubmit("", 12, 10), "Fresh Enter may send after confirmation");
                    using (var evt = KeyDownEvent.GetPooled(new Event { type = EventType.KeyDown, character = 'a', keyCode = KeyCode.A })) field.SendEvent(evt);
                    Require(field.value == "prefix a", "ASCII insertion remains native");
                    using (var evt = KeyDownEvent.GetPooled(new Event { type = EventType.KeyDown, character = '说', keyCode = KeyCode.None })) field.SendEvent(evt);
                    using (var evt = KeyDownEvent.GetPooled(new Event { type = EventType.KeyDown, character = '话', keyCode = KeyCode.None })) field.SendEvent(evt);
                    Require(field.value == "prefix a说话", "Committed Chinese must remain in native text editing");
                    var sends = 0; var activeComposition = "shuo hua"; var frame = 10; var ended = -10;
                    field.RegisterCallback<KeyDownEvent>(evt => { if (ChatImeBridge.ShouldSubmit(evt,activeComposition,frame,ended)) sends++; },TrickleDown.TrickleDown);
                    void Enter() { using var evt = KeyDownEvent.GetPooled(new Event { type = EventType.KeyDown, character = '\n', keyCode = KeyCode.Return }); field.SendEvent(evt); }
                    Enter(); Require(sends == 0 && field.value == "prefix a说话", "IME confirmation Enter must neither send nor insert newline");
                    activeComposition = ""; ended = 10; frame = 11;
                    Enter(); Require(sends == 0 && field.value == "prefix a说话", "Composition commit frame must not send or insert newline");
                    frame = 12; Enter(); Require(sends == 1 && field.value == "prefix a说话", "Fresh Enter must invoke exactly one send");
                    Require(ChatImeBridge.FocusedField(window.rootVisualElement) == field, "Input focus must block shortcuts before composition begins");
                    field.AddToClassList("hidden");
                    Require(ChatImeBridge.FocusedField(window.rootVisualElement) == null, "Closing must release shortcut gate without waiting for style layout");
                    field.RemoveFromClassList("hidden");
                    Require(ChatImeBridge.FocusedField(window.rootVisualElement) == field, "Reopening focused input must gate shortcuts");
                    Require(ChatImeBridge.CandidateScreenPosition(new Vector2(100,150),Vector2.zero,new Vector2(1000,600),new Vector2(1000,600)) == new Vector2(100,450), "1x candidate coordinates");
                    Require(ChatImeBridge.CandidateScreenPosition(new Vector2(100,150),Vector2.zero,new Vector2(1000,600),new Vector2(2000,1200)) == new Vector2(200,900), "Retina candidate coordinates");
                    Require(ChatImeBridge.CandidateScreenPosition(new Vector2(120,190),new Vector2(20,40),new Vector2(1000,600),new Vector2(2000,1200)) == new Vector2(200,900), "Viewport offset must be respected");
                    Require(ChatImeBridge.CandidateScreenPosition(new Vector2(100,150),Vector2.zero,new Vector2(1920,1080),new Vector2(3840,2160)) == new Vector2(200,1860), "Fullscreen logical size must retain Retina caret position");
                    Debug.Log("ChatImeChecks PASS: Chinese/Japanese preview/render caret, native Chinese commit, cancellation, duplicate suppression, Enter gate, focus/close shortcut gate, 1x/Retina/fullscreen candidate coordinates");
                    EditorApplication.update -= check; window.Close(); EditorApplication.Exit(0);
                } catch (Exception error) {
                    Debug.LogException(error); EditorApplication.update -= check; window.Close(); EditorApplication.Exit(1);
                }
            };
            EditorApplication.update += check;
        }
    }
}
