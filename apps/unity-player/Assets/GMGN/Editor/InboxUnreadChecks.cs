using System;
using System.Reflection;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace GMGN.UnityPlayer.Editor
{
    public static class InboxUnreadChecks
    {
        public static void Run()
        {
            try {
                var update = typeof(PlayerScreen).GetMethod("UpdateInboxUnreadIndicators", BindingFlags.Static | BindingFlags.NonPublic);
                if (update == null) throw new Exception("Unread state has no toolbar projection");
                var root = new VisualElement();
                foreach (var name in new[] { "inbox", "livecamInbox" }) root.Add(new Button { name = name });
                foreach (var count in new[] { 2, 0, 105, 1 }) {
                    update.Invoke(null, new object[] { root, count });
                    foreach (var name in new[] { "inbox", "livecamInbox" }) {
                        var button = root.Q<Button>(name);
                        var badge = button.Q<Label>(className: "inbox-unread-badge");
                        if (badge == null || button.Query<Label>(className: "inbox-unread-badge").ToList().Count != 1)
                            throw new Exception("Missing or duplicated unread indicator: " + name);
                        if (badge.style.display.value != (count > 0 ? DisplayStyle.Flex : DisplayStyle.None))
                            throw new Exception("Unread visibility mismatch: " + name);
                        if (badge.text != (count > 99 ? "99+" : count.ToString()))
                            throw new Exception("Unread count mismatch: " + name);
                    }
                }
                Debug.Log("[InboxUnreadChecks] PASS both toolbar entries reflect unread/read transitions");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
        }
    }
}
