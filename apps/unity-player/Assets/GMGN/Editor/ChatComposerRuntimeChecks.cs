using System;
using System.Reflection;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class ChatComposerRuntimeChecks
    {
        public static void Verify()
        {
            var go = new GameObject("Actual Player composer check"); var document = go.AddComponent<UIDocument>();
            var settings = UnityEngine.Object.Instantiate(Resources.Load<PanelSettings>("PlayerPanel")); settings.scale = 2; document.panelSettings = settings;
            var root = document.rootVisualElement; var frame = new VisualElement(); root.Add(frame);
            frame.style.width = 1280; frame.style.height = 720; frame.style.flexShrink = 0;
            Resources.Load<VisualTreeAsset>("Player").CloneTree(frame); frame.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            var chat = frame.Q("chatPanel"); chat.RemoveFromClassList("hidden"); frame.Q<Label>("emptyChat").AddToClassList("hidden");
            var draft = frame.Q<TextField>("draft"); draft.value = "你好 · hello"; draft.verticalScrollerVisibility = ScrollerVisibility.Auto;
            var player = go.AddComponent<PlayerScreen>(); player.enabled = false;
            void Set(string field, object value) => typeof(PlayerScreen).GetField(field, BindingFlags.Instance | BindingFlags.NonPublic).SetValue(player, value);
            void Call(string method, params object[] args) => typeof(PlayerScreen).GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(player, args);
            bool Following() => (bool)typeof(PlayerScreen).GetField("follow", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(player);
            Set("draft", draft); Set("chatPanel", chat);
            void MeasureDraft() => typeof(PlayerScreen).GetMethod("MeasureDraftText", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(player, null);
            frame.Q<Label>("chatVoiceStatus").text = "语音输入 · 确认文字后发送";
            frame.Q<Button>("cancel").RemoveFromClassList("hidden");
            frame.Q<Button>("send").AddToClassList("hidden");
            foreach (var name in new[] { "compactHistory", "closeChat", "chatVoice", "send" }) frame.Q<Button>(name).Add(new PlayerScreen.ToolbarIcon("close"));
            var scroll = frame.Q<ScrollView>("messages"); scroll.horizontalScrollerVisibility = ScrollerVisibility.Hidden;
            Set("list", scroll); Set("chatScroll", scroll);
            Call("InstallChatScrollTracking");
            for (int i = 0; i < 40; i++) { var row = new VisualElement(); row.AddToClassList("message"); row.style.height = 80; row.style.flexShrink = 0; row.Add(new Label("Long chat history · 第" + i + "条回复")); scroll.Add(row); }
            draft.Focus(); var binding = ChatImeBridge.BindComposition(root);
            var deadline = EditorApplication.timeSinceStartup + 1; int mode = 0, phase = 0, scrollPhase = 0;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
                    var input = draft.Q(className: "unity-text-field__input"); var text = draft.Q<TextElement>(className: "unity-text-element");
                    Debug.Log($"Composer mode={mode} outer={draft.worldBound} input={input.worldBound} text={text.worldBound} font={text.resolvedStyle.fontSize}");
                    Require(root.panel.contextType == ContextType.Player, "Must use real PlayerPanel, not EditorWindow theme");
                    Require(Mathf.Abs(draft.worldBound.height - 72) < .5f, "Composer outer height must retain fixed design size");
                    Require(input.worldBound.height >= 64, "Inner input must stretch to composer, not collapse to one clipped line");
                    var lineHeight = text.MeasureTextSize("M", text.contentRect.width, VisualElement.MeasureMode.AtMost, 0, VisualElement.MeasureMode.Undefined).y;
                    Require((input.worldBound.height - input.resolvedStyle.paddingTop - input.resolvedStyle.paddingBottom - 2) / lineHeight >= 3, "Input must show at least three actual measured text lines");
                    Require(frame.Q<Button>("microphone") == null && frame.Q<Button>("livecamVoice") == null && frame.Q<Button>("chatVoice") != null, "ASR microphone must exist only inside chat composer");
                    Require(text.worldBound.height >= text.resolvedStyle.fontSize, "Text content must retain a full line height");
                    var footer = chat.Q(className: "composer-footer");
                    Require(draft.worldBound.yMax <= footer.worldBound.yMin + 1 && footer.worldBound.yMax <= chat.worldBound.yMax + 1, $"Input and send controls must not overlap or escape card: input={draft.worldBound}, footer={footer.worldBound}, card={chat.worldBound}");
                    var microphone = frame.Q<Button>("chatVoice"); var send = frame.Q<Button>("cancel");
                    Require(microphone.worldBound.xMax <= send.worldBound.xMin && microphone.worldBound.yMin >= footer.worldBound.yMin && send.worldBound.yMax <= footer.worldBound.yMax,
                        "Composer microphone/send must not overlap and must remain inside footer");
                    Require(scroll.contentViewport.worldBound.height >= (mode >= 3 ? 40 : 64) && scroll.contentViewport.worldBound.yMax <= draft.worldBound.yMin + 1, $"Busy chat history must retain usable remaining height: mode={mode} viewport={scroll.contentViewport.worldBound}, card={chat.worldBound}");
                    Require(frame.Q<Label>("chatVoiceStatus").resolvedStyle.flexGrow == 0, "Voice caption must not compete with history for remaining height");
                    Require(frame.Q("newMessages") == null, "History follows without a view-new-messages button");
                    if (mode == 4) {
                        if (scrollPhase == 0) {
                            Set("follow", true); Call("ScrollToLatest"); scrollPhase++; deadline = EditorApplication.timeSinceStartup + .3; return;
                        }
                        if (scrollPhase == 1) {
                            Require(scroll.scrollOffset.y >= scroll.verticalScroller.highValue - 2, "Default follow reaches bottom");
                            Call("OnChatWheel", -1f); scroll.scrollOffset = Vector2.zero; Call("ScrollToLatest");
                            scrollPhase++; deadline = EditorApplication.timeSinceStartup + .6; return;
                        }
                        if (scrollPhase == 2) {
                            Require(!Following() && scroll.scrollOffset.y < 1, "Intentional upward wheel retains reading position");
                            scroll.scrollOffset = new Vector2(0, scroll.verticalScroller.highValue); Call("OnChatWheel", 1f);
                            scrollPhase++; deadline = EditorApplication.timeSinceStartup + .3; return;
                        }
                        if (scrollPhase == 3) {
                            Require(Following(), "Downward wheel at bottom restores follow");
                            Call("ScrollToLatest"); scroll.contentContainer[39].schedule.Execute(() => scroll.contentContainer[39].style.height = 480).StartingIn(32);
                            scrollPhase++; deadline = EditorApplication.timeSinceStartup + .6; return;
                        }
                        Require(Following() && scroll.scrollOffset.y >= scroll.verticalScroller.highValue - 2, $"Streaming row growth with delayed layout retains automatic bottom follow: offset={scroll.scrollOffset.y}, bottom={scroll.verticalScroller.highValue}, follow={Following()}");
                        Debug.Log("ChatComposerRuntimeChecks PASS: real PlayerPanel scale=2 normal/fullscreen/narrow/224x336, composer geometry/caret/internal scroll; default follow, intentional up-wheel pause, bottom-wheel resume, delayed streaming growth");
                        EditorApplication.update -= check; binding.Dispose(); UnityEngine.Object.DestroyImmediate(go); UnityEngine.Object.DestroyImmediate(settings); EditorApplication.Exit(0); return;
                    }
                    if (phase == 0) {
                        phase++; draft.SelectRange(draft.value.Length, draft.value.Length); ChatImeBridge.Forward(draft, " shuo"); MeasureDraft();
                        scroll.ScrollTo(scroll.contentContainer[39]); deadline = EditorApplication.timeSinceStartup + .4; return;
                    }
                    var caret = text.Q("ime-preview-caret");
                    if (phase == 1 || phase == 3) Require(caret != null && caret.worldBound.height > 0 && caret.worldBound.yMin >= input.worldBound.yMin - 1 && caret.worldBound.yMax <= input.worldBound.yMax + 1,
                        $"Composition caret must fit inside input: caret={caret?.worldBound}, input={input.worldBound}");
                    Require(scroll.contentContainer[39].worldBound.yMax <= scroll.contentViewport.worldBound.yMax + 2, "Long history must reach bottom");
                    if (phase == 1) {
                        ChatImeBridge.Forward(draft, ""); draft.value = string.Join("\n", new string[] { "第一行 hello", "第二行", "第三行", "第四行", "第五行", "第六行", "第七行", "第八行", "第九行", "第十行" }); MeasureDraft();
                        phase++; deadline = EditorApplication.timeSinceStartup + .4; return;
                    }
                    if (phase == 2) {
                        var innerScroll = draft.Q<ScrollView>();
                        Require(innerScroll != null && innerScroll.verticalScroller.highValue > 0, "Long draft must scroll vertically inside fixed input");
                        innerScroll.scrollOffset = new Vector2(0, innerScroll.verticalScroller.highValue);
                        draft.SelectRange(draft.value.Length, draft.value.Length); ChatImeBridge.Forward(draft, " shuo"); MeasureDraft();
                        phase++; deadline = EditorApplication.timeSinceStartup + .4; return;
                    }
                    Require(draft.Q<ScrollView>().scrollOffset.y > 0, "Multiline input must retain internal scroll position");
                    ChatImeBridge.Forward(draft, "");
                    if (++mode < 4) {
                        draft.value = "你好 · hello"; MeasureDraft();
                        phase = 0; frame.style.width = mode == 1 ? 2048 : mode == 2 ? 760 : 224; frame.style.height = mode == 1 ? 1152 : mode == 2 ? 580 : 336;
                        frame.EnableInClassList("compact", mode >= 2);
                        frame.EnableInClassList("compact-window", mode == 3); deadline = EditorApplication.timeSinceStartup + .6; return;
                    }
                    deadline = EditorApplication.timeSinceStartup + .1;
                } catch (Exception error) { Debug.LogException(error); EditorApplication.update -= check; binding.Dispose(); UnityEngine.Object.DestroyImmediate(go); UnityEngine.Object.DestroyImmediate(settings); EditorApplication.Exit(1); }
            }; EditorApplication.update += check;
        }
    }
}
