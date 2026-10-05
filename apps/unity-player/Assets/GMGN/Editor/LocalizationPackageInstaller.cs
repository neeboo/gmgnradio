using UnityEditor;
using UnityEditor.PackageManager;
using UnityEditor.PackageManager.Requests;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class LocalizationPackageInstaller
    {
        static AddRequest request;
        static double deadline;
        public static void Install()
        {
            request = Client.Add("com.unity.localization");
            deadline = EditorApplication.timeSinceStartup + 600;
            EditorApplication.update += Poll;
        }
        static void Poll()
        {
            if (!request.IsCompleted && EditorApplication.timeSinceStartup < deadline) return;
            EditorApplication.update -= Poll;
            if (!request.IsCompleted || request.Status != StatusCode.Success) {
                Debug.LogError(request.Error?.message ?? "Localization package resolution timed out");
                EditorApplication.Exit(1);
                return;
            }
            Debug.Log($"Localization dependency: {request.Result.name}@{request.Result.version}");
            EditorApplication.Exit(0);
        }
    }
}
