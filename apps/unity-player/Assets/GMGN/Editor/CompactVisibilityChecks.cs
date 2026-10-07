using System;
using System.Collections.Generic;
using System.Reflection;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class CompactVisibilityChecks
    {
        public static void Validate()
        {
            var host = new GameObject("compact-visibility-fixture");
            var root = new GameObject("fixture-world-presentation");
            var unrelated = new GameObject("fixture-unowned-parent");
            const BindingFlags fields = BindingFlags.Instance | BindingFlags.NonPublic;
            try {
                var world = host.AddComponent<WorldRuntimeBridge>();
                var compact = host.AddComponent<UnityCompactWindowController>();
                typeof(WorldRuntimeBridge).GetField("worldRoot", fields).SetValue(world, root);
                var visible = typeof(WorldRuntimeBridge).GetField("visible", fields);
                var activated = (List<GameObject>)typeof(UnityCompactWindowController)
                    .GetField("activatedParents", fields).GetValue(compact);
                // Enter compact from hidden world: the portrait activates its parent.
                root.SetActive(false); root.SetActive(true); activated.Add(root);
                unrelated.SetActive(true); activated.Add(unrelated);
                // World becomes visible before exiting compact.
                visible.SetValue(world, true);
                compact.RestorePresentationParents();
                if (!root.activeSelf || unrelated.activeSelf || activated.Count != 0)
                    throw new Exception("Compact exit lost latest visible world intent or unowned-parent restoration.");
                // The unchanged hidden-world case must still restore hidden.
                visible.SetValue(world, false); root.SetActive(true); activated.Add(root);
                compact.RestorePresentationParents();
                if (root.activeSelf) throw new Exception("Compact exit exposed a world whose latest intent is hidden.");
                // Also preserve a mode change to hidden when root was originally active.
                root.SetActive(true);
                compact.RestorePresentationParents();
                if (root.activeSelf) throw new Exception("Originally active root overrode latest hidden world intent.");
                Debug.Log("PASS compact visibility: latest visible/hidden intent wins; unowned parents restore; no authority writes.");
            } finally {
                UnityEngine.Object.DestroyImmediate(host);
                UnityEngine.Object.DestroyImmediate(root);
                UnityEngine.Object.DestroyImmediate(unrelated);
            }
        }
    }
}
