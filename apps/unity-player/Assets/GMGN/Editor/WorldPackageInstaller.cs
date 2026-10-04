using UnityEditor;
using UnityEditor.PackageManager;
using UnityEditor.PackageManager.Requests;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class WorldPackageInstaller
    {
        static AddAndRemoveRequest request;
        static double deadline;
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
            EditorApplication.Exit(0);
        }
    }
}
