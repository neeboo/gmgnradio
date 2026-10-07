using System;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class CompactChatLayoutChecks
    {
        public static void Verify()
        {
            var window = ScriptableObject.CreateInstance<EditorWindow>(); window.minSize = new Vector2(224, 336); window.position = new Rect(0, 0, 224, 336);
            var root = window.rootVisualElement; Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player")); root.AddToClassList("compact-window");
            var chat = root.Q("chatPanel"); chat.RemoveFromClassList("hidden");
            root.Q<Label>("chatVoiceStatus").text = "语音输入 · 确认文字后发送";
            foreach (var name in new[] { "compactHistory", "closeChat", "chatVoice", "send" }) root.Q<Button>(name).Add(new PlayerScreen.ToolbarIcon("close"));
            var scroll = root.Q<ScrollView>("messages"); scroll.horizontalScrollerVisibility = ScrollerVisibility.Hidden;
            for (int i = 0; i < 30; i++) { var row = new VisualElement(); row.AddToClassList("message"); row.style.height = 72; row.style.flexShrink = 0; var label = new Label("这是一条需要换行并滚动查看的聊天回复。"); label.AddToClassList("message-text"); row.Add(label); scroll.Add(row); }
            window.Show(); var deadline = EditorApplication.timeSinceStartup + 1; int phase = 0;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
                    var header = chat.Q(className: "chat-header"); var draft = root.Q<TextField>("draft"); var controls = root.Q(className: "livecam-controls"); var viewport = scroll.contentViewport;
                    Require(chat.worldBound.xMin >= root.worldBound.xMin && chat.worldBound.yMin >= root.worldBound.yMin, "Compact card must remain inside window");
                    Require(chat.worldBound.xMax < controls.worldBound.xMin, "Compact chat must not cover side toolbar");
                    Require(header.Q<Label>().resolvedStyle.display == DisplayStyle.Flex && header.worldBound.height >= 28, "Compact header title and controls must be visible");
                    Require(header.worldBound.yMax <= viewport.worldBound.yMin + 1 && viewport.worldBound.yMax <= draft.worldBound.yMin + 1, "History viewport must stay between header and composer");
                    Require(viewport.worldBound.height > 40, "Compact history must have usable scrolling height");
                    Require(draft.worldBound.yMax <= chat.worldBound.yMax && chat.worldBound.yMax <= root.worldBound.yMax, "Composer must remain inside card/window");
                    if (phase == 0) { phase++; scroll.scrollOffset = new Vector2(0, scroll.verticalScroller.highValue); deadline = EditorApplication.timeSinceStartup + .5; return; }
                    Require(scroll.contentContainer[29].worldBound.yMax <= viewport.worldBound.yMax + 2, "Compact history must reach last reply");
                    if (phase == 1) { phase++; chat.AddToClassList("compact-history"); deadline = EditorApplication.timeSinceStartup + .5; return; }
                    Debug.Log("CompactChatLayoutChecks PASS: 224x336 title/controls, bounded composer and toolbar, 30 replies bottom reachable, expanded layout");
                    EditorApplication.update -= check; window.Close(); EditorApplication.Exit(0);
                } catch (Exception error) { Debug.LogException(error); EditorApplication.update -= check; window.Close(); EditorApplication.Exit(1); }
            }; EditorApplication.update += check;
        }
    }
}
