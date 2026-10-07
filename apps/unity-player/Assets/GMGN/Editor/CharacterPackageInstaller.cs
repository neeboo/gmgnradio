using System.Linq;
using UnityEditor;
using UnityEditor.PackageManager;
using UnityEditor.PackageManager.Requests;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class CharacterPackageInstaller
    {
        static AddAndRemoveRequest request;
        static double deadline;
        public static void Install()
        {
            request = Client.AddAndRemove(new[] {
                "https://github.com/vrm-c/UniVRM.git?path=/Packages/UniGLTF#v0.131.3",
                "https://github.com/vrm-c/UniVRM.git?path=/Packages/VRM#v0.131.3",
                "https://github.com/vrm-c/UniVRM.git?path=/Packages/VRM10#v0.131.3"
            });
            deadline = EditorApplication.timeSinceStartup + 600;
            EditorApplication.update += Poll;
        }
        static void Poll()
        {
            if (!request.IsCompleted && EditorApplication.timeSinceStartup < deadline) return;
            EditorApplication.update -= Poll;
            if (!request.IsCompleted || request.Status != StatusCode.Success) {
                Debug.LogError(request.Error?.message ?? "Character package installation timed out");
                EditorApplication.Exit(1); return;
            }
            Debug.Log("Character packages installed");
            EditorApplication.Exit(0);
        }
        public static void Enable()
        {
            var target = UnityEditor.Build.NamedBuildTarget.Standalone;
            var symbols = PlayerSettings.GetScriptingDefineSymbols(target);
            if (!symbols.Split(';').Contains("GMGN_UNIVRM"))
                PlayerSettings.SetScriptingDefineSymbols(target, symbols + ";GMGN_UNIVRM");
            AssetDatabase.SaveAssets();
        }
    }
}
