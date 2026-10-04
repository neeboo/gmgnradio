using UnityEditor;
using UnityEditor.Build;
using UnityEditor.PackageManager;
using UnityEditor.PackageManager.Requests;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class WorldPackageInstaller
    {
        static AddAndRemoveRequest request;
        static double deadline;
        static bool characterInstall;
        public static void InstallCharacters()
        {
            characterInstall = true;
            request = Client.AddAndRemove(new[] { "https://github.com/CandidumGames/UnityMMDTools.git#db35d9cb80ad57a8b2cbd40ad737a3c7bbe2d6c4" });
            deadline = EditorApplication.timeSinceStartup + 600;
            EditorApplication.update += Poll;
        }
        public static void Install()
        {
            request = Client.AddAndRemove(new[] { "com.unity.cloud.gltfast", "com.unity.nuget.newtonsoft-json" });
            deadline = EditorApplication.timeSinceStartup + 600;
            EditorApplication.update += Poll;
        }
        static void Poll()
        {
            if (!request.IsCompleted) {
                if (EditorApplication.timeSinceStartup < deadline) return;
                Debug.LogError("World package resolution timed out"); EditorApplication.Exit(2); return;
            }
            EditorApplication.update -= Poll;
            if (request.Status != StatusCode.Success) { Debug.LogError(request.Error.message); EditorApplication.Exit(1); return; }
            foreach (var package in request.Result) Debug.Log($"World dependency: {package.name}@{package.version}");
            if (characterInstall) {
                var symbols = PlayerSettings.GetScriptingDefineSymbols(NamedBuildTarget.Standalone);
                if (!System.Array.Exists(symbols.Split(';'), symbol => symbol == "GMGN_UMT"))
                    PlayerSettings.SetScriptingDefineSymbols(NamedBuildTarget.Standalone, string.IsNullOrEmpty(symbols) ? "GMGN_UMT" : symbols + ";GMGN_UMT");
                AssetDatabase.SaveAssets();
            }
            EditorApplication.Exit(0);
        }
    }
}
