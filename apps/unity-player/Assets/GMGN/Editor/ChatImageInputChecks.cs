using System;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class ChatImageInputChecks
    {
        public static void Run()
        {
            var host = new GameObject("Chat image input checks");
            host.SetActive(false);
            var screen = host.AddComponent<PlayerScreen>();
            var root = new VisualElement();
            Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player"));
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            void Set(string name, object value) => typeof(PlayerScreen).GetField(name, flags).SetValue(screen, value);
            var rows = new ScrollView();
            Set("root", root); Set("chatPanel", root.Q("chatPanel")); Set("draft", root.Q<TextField>("draft"));
            Set("send", root.Q<Button>("send")); Set("cancel", root.Q<Button>("cancel"));
            Set("chatImageRows", rows); Set("connected", true);
            var apply = typeof(PlayerScreen).GetMethod("OnChatAttachmentsUpdated", flags);
            var normalize = typeof(PlayerScreen).GetMethod("NormalizeChatImageDropRegion", BindingFlags.Static | BindingFlags.NonPublic);
            Rect Normalize(Rect bounds, int width, int height, float scale) =>
                (Rect)normalize.Invoke(null, new object[] { bounds, width, height, scale });
            void Snapshot(bool selecting, bool preparing) => apply.Invoke(screen, new object[] {
                new JObject { ["count"] = 0, ["attachments"] = new JArray(), ["isSelecting"] = selecting,
                    ["isPreparing"] = preparing, ["canSubmit"] = !selecting && !preparing }
            });
            try {
                Snapshot(true, false);
                Require(rows.Q<Label>()?.text == "请选择图片…", "selection is not image processing");
                Require(!rows.ClassListContains("hidden"), "selection status is visible");
                Snapshot(false, true);
                Require(rows.Q<Label>()?.text == "正在准备图片…", "only processing reports preparing");
                Snapshot(false, false);
                Require(rows.ClassListContains("hidden") && rows.contentContainer.childCount == 0, "cancel clears busy message");
                var window = Normalize(new Rect(72, 225, 360, 90), 1440, 900, 2);
                var retina = Normalize(new Rect(204.8f, 576, 1024, 230.4f), 4096, 2304, 2);
                Require(Near(window, new Rect(.1f, .5f, .5f, .2f)) && Near(window, retina), "window and native 4K Retina drop coordinates match");
                Require(Normalize(Rect.zero, 1440, 900, 2) == Rect.zero, "hidden input has no drop target");
                Debug.Log("PASS chat image input: selecting/processing/cancel states and actual normalized window/4K Retina drop region");
            } finally { UnityEngine.Object.DestroyImmediate(host); }
        }
        static bool Near(Rect a, Rect b) => Mathf.Abs(a.x-b.x)<.00001f && Mathf.Abs(a.y-b.y)<.00001f && Mathf.Abs(a.width-b.width)<.00001f && Mathf.Abs(a.height-b.height)<.00001f;
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    }
}
