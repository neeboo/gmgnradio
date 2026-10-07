using System;
using System.Reflection;
using System.Runtime.Serialization;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.TextCore.Text;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class InboxDetailLayoutChecks
    {
        public static void Verify()
        {
            var window = ScriptableObject.CreateInstance<EditorWindow>(); window.minSize = new Vector2(224, 336);
            var root = window.rootVisualElement; root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            root.style.flexGrow = 1; root.AddToClassList("compact-window");
            var font = Resources.Load<FontAsset>("PlayerRegularFont");
            if (font == null || !font.HasCharacter('剑', true, true)) throw new Exception("Production font must render Chinese sword glyph");
            root.style.unityFontDefinition = new FontDefinition { fontAsset = font };
            var body = new VisualElement(); body.AddToClassList("body"); body.style.flexGrow = 1; root.Add(body);
            // No constructor, service connection, request or durable read mutation.
            var backend = (NativePlayerBackend)FormatterServices.GetUninitializedObject(typeof(NativePlayerBackend));
            var panel = new InboxPanel(body, backend); panel.Element.RemoveFromClassList("hidden");
            var show = typeof(InboxPanel).GetMethod("ShowDetail", BindingFlags.Instance | BindingFlags.NonPublic);
            string title = "「2B 白色长剑（外形摆件）」已摆放。" + new string('剑', 160) + "标题末尾";
            string text = string.Join("\n", System.Linq.Enumerable.Repeat("这段通知正文保持原样，完整内容应可以滚动查看。", 40)) + "\n正文末尾";
            var entry = new JObject { ["taskKey"] = "fixture", ["title"] = title, ["detail"] = text };
            show.Invoke(panel, new object[] { entry });
            var scroll = panel.Element.Q<ScrollView>(className: "inbox-detail");
            var heading = panel.Element.Q<Label>(className: "inbox-detail-title");
            var content = panel.Element.Q<Label>(className: "inbox-detail-text");
            window.Show(); window.position = new Rect(0, 0, 224, 336);
            int phase = 0; bool compactEmptyScrolled = false; double deadline = EditorApplication.timeSinceStartup + 1;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    void Require(bool valid, string message) { if (!valid) throw new Exception(message); }
                    Debug.Log($"InboxDetail geometry phase={phase} root={root.worldBound} panel={panel.Element.worldBound} viewport={scroll.contentViewport.worldBound} title={heading.worldBound} body={content.worldBound} scroll={scroll.verticalScroller.highValue}");
                    Require(Mathf.Abs(root.worldBound.width - (phase < 3 ? 224 : 960)) < 1, "Actual window target width");
                    Require(heading.text == title && content.text == (phase == 2 || phase >= 5 ? "" : text), "Original title/body preserved exactly");
                    Require(heading.resolvedStyle.whiteSpace == WhiteSpace.Normal && heading.resolvedStyle.textOverflow != TextOverflow.Ellipsis, "Detail heading wraps without ellipsis");
                    Require(heading.worldBound.height >= 2 * heading.resolvedStyle.fontSize, "Real Chinese long title occupies multiple lines");
                    Require(heading.worldBound.width <= scroll.contentViewport.worldBound.width + 1, "Wrapped title width fits visible viewport");
                    Require(scroll.contentViewport.worldBound.height >= 80, "Detail has usable scroll viewport");
                    if (content.text.Length > 0 || heading.worldBound.height > scroll.contentViewport.worldBound.height)
                        Require(scroll.verticalScroller.highValue > 0, "Real overflowing text is scrollable");
                    if (phase == 0 || phase == 3) { scroll.scrollOffset = new Vector2(0, scroll.verticalScroller.highValue); phase++; deadline = EditorApplication.timeSinceStartup + .4; return; }
                    if (phase == 1 || phase == 4) {
                        Require(content.worldBound.yMax <= scroll.contentViewport.worldBound.yMax + 2, "Full body end reachable");
                        entry["detail"] = ""; show.Invoke(panel, new object[] { entry }); scroll.scrollOffset = Vector2.zero; phase++; deadline = EditorApplication.timeSinceStartup + .4; return;
                    }
                    Require(content.text == "", "Empty authority body remains empty");
                    scroll.scrollOffset = new Vector2(0, scroll.verticalScroller.highValue);
                    if (phase == 2) {
                        if (!compactEmptyScrolled) { compactEmptyScrolled = true; deadline = EditorApplication.timeSinceStartup + .4; return; }
                        Require(heading.worldBound.yMax <= scroll.contentViewport.worldBound.yMax + 2, "Compact empty-body title end is scroll-reachable");
                        root.RemoveFromClassList("compact-window"); window.position = new Rect(0, 0, 960, 720);
                        entry["detail"] = text; show.Invoke(panel, new object[] { entry }); scroll.scrollOffset = Vector2.zero;
                        phase++; deadline = EditorApplication.timeSinceStartup + .6; return;
                    }
                    if (phase == 5) { phase++; deadline = EditorApplication.timeSinceStartup + .4; return; }
                    Require(heading.worldBound.yMax <= scroll.contentViewport.worldBound.yMax + 2, "Empty-body title end is visible or scroll-reachable");
                    Debug.Log("InboxDetailLayoutChecks PASS: real Chinese font, compact/normal long heading wraps, full body scroll reaches end, empty body preserved");
                    EditorApplication.update -= check; panel.Dispose(); window.Close(); EditorApplication.Exit(0);
                } catch (Exception error) { Debug.LogException(error); EditorApplication.update -= check; panel.Dispose(); window.Close(); EditorApplication.Exit(1); }
            }; EditorApplication.update += check;
        }
    }
}
