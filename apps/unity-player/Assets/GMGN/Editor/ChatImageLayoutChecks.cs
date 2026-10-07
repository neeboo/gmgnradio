using System;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class ChatImageLayoutChecks
    {
        public static void Verify()
        {
            var window = ScriptableObject.CreateInstance<EditorWindow>();
            window.position = new Rect(0, 0, 224, 336); window.minSize = new Vector2(224, 336);
            var root = window.rootVisualElement; Resources.Load<VisualTreeAsset>("Player").CloneTree(root);
            root.styleSheets.Add(Resources.Load<StyleSheet>("Player")); root.AddToClassList("compact-window");
            var chat = root.Q("chatPanel"); chat.RemoveFromClassList("hidden");
            root.Q("emptyChat").AddToClassList("hidden");
            var draft = root.Q<TextField>("draft");
            var host = new GameObject("Image layout fixture"); host.SetActive(false);
            var screen = host.AddComponent<PlayerScreen>();
            void Set(string field, object value) => typeof(PlayerScreen).GetField(field, BindingFlags.Instance | BindingFlags.NonPublic).SetValue(screen, value);
            void Call(string method, params object[] values) => typeof(PlayerScreen).GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(screen, values);
            Set("root", root); Set("chatPanel", chat); Set("draft", draft); Set("send", root.Q<Button>("send")); Set("cancel", root.Q<Button>("cancel"));
            var native = (NativePlayerBackend)System.Runtime.Serialization.FormatterServices.GetUninitializedObject(typeof(NativePlayerBackend));
            void Snapshot(JObject value) => typeof(NativePlayerBackend).GetMethod("ApplyChatAttachmentsSnapshot", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(native, new object[] { value });
            int attachmentUpdates = 0, removeClicks = 0;
            native.ChatAttachmentsUpdated += value => { attachmentUpdates++; Call("OnChatAttachmentsUpdated", value); };
            Call("InstallChatImageControls", native);
            var previews = root.Q<ScrollView>("chatImageDrafts");
            var texture = new Texture2D(8, 8); string png = Convert.ToBase64String(texture.EncodeToPNG()); UnityEngine.Object.DestroyImmediate(texture);
            var images = new JArray();
            for (int i = 0; i < 4; i++) images.Add(new JObject { ["id"] = Guid.NewGuid().ToString(), ["name"] = "很长的图片文件名称应保持单行并且省略尾部文字-" + i + ".png", ["thumbnailPNG"] = png });
            Snapshot(new JObject { ["generation"] = 7UL, ["count"] = 4, ["canSubmit"] = true, ["attachments"] = images });
            var removeButton = previews.contentContainer[0].Q<Button>(); removeButton.clicked += () => removeClicks++;
            var history = root.Q<ScrollView>("messages");
            for (int i = 0; i < 20; i++) { var row = new Label("可滚动的聊天历史 " + i); row.style.height = 36; row.style.flexShrink = 0; history.Add(row); }
            window.Show(); window.position = new Rect(0, 0, 224, 336);
            int phase = 0; double deadline = EditorApplication.timeSinceStartup + 1;
            EditorApplication.CallbackFunction check = null;
            check = () => {
                if (EditorApplication.timeSinceStartup < deadline) return;
                try {
                    void Require(bool valid, string message) { if (!valid) throw new Exception(message); }
                    Debug.Log($"ChatImageLayout geometry phase={phase} root={root.worldBound} chat={chat.worldBound} history={history.contentViewport.worldBound} images={previews.worldBound} draft={draft.worldBound}");
                    Require(Mathf.Abs(draft.worldBound.height - 72) < 1, "72px multiline input is preserved");
                    var footer = root.Q(className: "composer-footer");
                    Require(footer[0] == root.Q<Button>("chooseChatImages") && root.Q<Button>("chooseChatImages").text == "+", "Single + attachment entry is on the left");
                    Require(root.Q("pasteChatImages") == null && root.Q("chatHint") == null, "No standalone paste entry or keyboard hint");
                    Require(root.Q<Button>("chatVoice").worldBound.xMax <= root.Q<Button>("send").worldBound.xMin + 1, "Microphone sits before send on the right");
                    Require(draft.parent == footer.parent && draft.parent.ClassListContains("chat-composer"), "Input and action row share one composer container");
                    Require(history.contentViewport.worldBound.height >= 40, "Image previews must preserve visible history");
                    Require(previews.worldBound.height <= (phase < 3 ? 37 : 73), "Image preview height is bounded");
                    Require(Mathf.Abs(root.worldBound.width - (phase < 3 ? 224 : 960)) < 1, "Actual fixture width matches target window");
                    Require(previews.contentContainer.childCount == 4, "Four production image rows exist");
                    Require(previews.Q<Image>()?.image is Texture2D, "Production PNG decoded into real thumbnail");
                    Require(previews.contentContainer[0].Q<Label>().resolvedStyle.whiteSpace == WhiteSpace.NoWrap, "Filename is single line");
                    Require(previews.contentContainer[0].Q<Image>().worldBound.width <= (phase < 3 ? 29 : 45), "Thumbnail adapts to compact mode");
                    Require(draft.worldBound.yMax <= chat.worldBound.yMax + 1, "Composer remains inside chat");
                    if (phase == 0) {
                        using (var down = PointerDownEvent.GetPooled(new Event { type = EventType.MouseDown, button = 0, mousePosition = removeButton.worldBound.center })) removeButton.SendEvent(down);
                        for (int i = 0; i < 20; i++) Snapshot(new JObject { ["attachments"] = images.DeepClone(), ["canSubmit"] = true, ["count"] = 4, ["generation"] = 7UL });
                        Require(attachmentUpdates == 1 && ReferenceEquals(removeButton, previews.contentContainer[0].Q<Button>()), "Same generation with reordered JSON must preserve pressed remove button");
                        phase++; deadline = EditorApplication.timeSinceStartup + .4; return;
                    }
                    if (phase == 1) {
                        for (int i = 0; i < 20; i++) Snapshot(new JObject { ["generation"] = 7UL, ["attachments"] = images.DeepClone(), ["count"] = 4, ["canSubmit"] = true });
                        using (var up = PointerUpEvent.GetPooled(new Event { type = EventType.MouseUp, button = 0, mousePosition = removeButton.worldBound.center })) removeButton.SendEvent(up);
                        Require(removeClicks == 1 && attachmentUpdates == 1, "Remove click survives snapshots between real pointer down/up");
                        previews.scrollOffset = new Vector2(0, previews.verticalScroller.highValue); phase++; deadline = EditorApplication.timeSinceStartup + .4; return;
                    }
                    if (phase != 3) Require(previews.contentContainer[3].worldBound.yMax <= previews.contentViewport.worldBound.yMax + 2, "Last image is reachable by scrolling");
                    if (phase == 2) { root.RemoveFromClassList("compact-window"); window.position = new Rect(0, 0, 960, 720); phase++; deadline = EditorApplication.timeSinceStartup + .7; return; }
                    if (phase == 3) { previews.scrollOffset = new Vector2(0, previews.verticalScroller.highValue); phase++; deadline = EditorApplication.timeSinceStartup + .4; return; }
                    Snapshot(new JObject { ["generation"] = 8UL, ["count"] = 0, ["canSubmit"] = true, ["attachments"] = new JArray() });
                    Require(attachmentUpdates == 2, "New generation updates draft exactly once");
                    Require(previews.ClassListContains("hidden") && previews.contentContainer.childCount == 0, "Removed image previews release their layout");
                    var cached = (System.Collections.ICollection)typeof(PlayerScreen).GetField("chatImageTextures", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(screen);
                    Require(cached.Count == 0, "Removed image textures are released");
                    Debug.Log("ChatImageLayoutChecks PASS: compact224x336 and normal960x720 four thumbnails, bounded scroll, 72px input and visible history; removal releases layout/textures");
                    EditorApplication.update -= check; Call("ReleaseChatImageTextures"); UnityEngine.Object.DestroyImmediate(host); window.Close(); EditorApplication.Exit(0);
                } catch (Exception error) { Debug.LogException(error); EditorApplication.update -= check; Call("ReleaseChatImageTextures"); UnityEngine.Object.DestroyImmediate(host); window.Close(); EditorApplication.Exit(1); }
            }; EditorApplication.update += check;
        }
    }
}
