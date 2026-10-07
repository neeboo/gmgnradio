using System;
using System.IO;
using System.Linq;
using System.Reflection;
using UnityEditor;
using UnityEditor.PackageManager;
using UnityEditor.PackageManager.Requests;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace GMGN.UnityPlayer.Editor
{
    public static class GaussianWorldBootstrap
    {
        public const string Package = "https://github.com/aras-p/UnityGaussianSplatting.git?path=/package#2c6fed37da67a217367261fcfcd3316d34c73e76";
        const string Root = "Assets/GMGN/GaussianWorld/Resources/GaussianWorld";
        static AddRequest request;
        static double deadline;
        [Serializable] sealed class Framing { public float[] origin; public float scale; }
        [Serializable] sealed class CabinDocument { public Framing framing; }
        public static void Install()
        {
            Debug.Log("Installing Gaussian Splatting MIT package at pinned revision");
            request = Client.Add(Package);
            deadline = EditorApplication.timeSinceStartup + 600;
            EditorApplication.update += Poll;
        }
        static void Poll()
        {
            if (!request.IsCompleted && EditorApplication.timeSinceStartup < deadline) return;
            EditorApplication.update -= Poll;
            if (!request.IsCompleted || request.Status != StatusCode.Success) {
                Debug.LogError("Gaussian package install failed: " + request.Error?.message);
                EditorApplication.Exit(1); return;
            }
            Debug.Log("Gaussian package installed: " + request.Result.packageId);
            EditorApplication.Exit(0);
        }
        static Type Find(string name) => TypeCache.GetTypesDerivedFrom<UnityEngine.Object>().FirstOrDefault(t => t.FullName == name) ?? throw new InvalidOperationException("Install pinned Gaussian package first: " + name);
        const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
        public static void PrepareCabin()
        {
            var source = Environment.GetEnvironmentVariable("GMGN_UNITY_CABIN_SPZ");
            if (string.IsNullOrEmpty(source) || !File.Exists(source)) throw new FileNotFoundException("Set GMGN_UNITY_CABIN_SPZ to the real cabin SPZ", source);
            var input = CabinSpzConversion.ConvertSh0(source);
            Directory.CreateDirectory(Root);
            var creatorType = Find("GaussianSplatting.Editor.GaussianSplatAssetCreator");
            var creator = ScriptableObject.CreateInstance(creatorType);
            try {
                creatorType.GetField("m_InputFile", PrivateInstance).SetValue(creator, input);
                creatorType.GetField("m_OutputFolder", PrivateInstance).SetValue(creator, Root);
                creatorType.GetField("m_ImportCameras", PrivateInstance).SetValue(creator, false);
                var quality = creatorType.GetField("m_Quality", PrivateInstance);
                quality.SetValue(creator, Enum.Parse(quality.FieldType, "High"));
                creatorType.GetMethod("ApplyQualityLevel", PrivateInstance).Invoke(creator, null);
                creatorType.GetMethod("CreateAsset", PrivateInstance).Invoke(creator, null);
                var error = creatorType.GetField("m_ErrorMessage", PrivateInstance).GetValue(creator) as string;
                if (!string.IsNullOrEmpty(error)) throw new InvalidOperationException(error);
            } finally { UnityEngine.Object.DestroyImmediate(creator); EditorUtility.ClearProgressBar(); }
            var assetPath = Root + "/" + Path.GetFileNameWithoutExtension(source) + ".asset";
            var asset = AssetDatabase.LoadAssetAtPath<UnityEngine.Object>(assetPath);
            if (asset == null) throw new InvalidOperationException("Gaussian import did not produce an asset");
            var imported = new SerializedObject(asset);
            var size = imported.FindProperty("m_BoundsMax").vector3Value - imported.FindProperty("m_BoundsMin").vector3Value;
            if (size.sqrMagnitude < 1) throw new InvalidOperationException("Gaussian import produced invalid zero bounds");
            var go = new GameObject("Cabin Gaussian Splats");
            go.SetActive(false);
            try {
                var framing = JsonUtility.FromJson<CabinDocument>(File.ReadAllText(Path.Combine(Path.GetDirectoryName(source), "marble.json"))).framing;
                if (framing == null || framing.origin == null || framing.origin.Length != 3 || framing.scale <= 0)
                    throw new InvalidOperationException("Missing source cabin framing calibration");
                // SPZ stores RUB; Swift SplatIO converts RUB -> RDF (flip Y,Z).
                // WorldCoordinates then maps RDF -> Unity (flip Z). Net: flip Y.
                go.transform.localScale = new Vector3(framing.scale, -framing.scale, framing.scale);
                go.transform.localPosition = new Vector3(-framing.origin[0], -framing.origin[1], framing.origin[2]) * framing.scale;
                var component = go.AddComponent(Find("GaussianSplatting.Runtime.GaussianSplatRenderer"));
                var data = new SerializedObject(component);
                data.FindProperty("m_Asset").objectReferenceValue = asset;
                const string shaders = "Packages/org.nesnausk.gaussian-splatting/Shaders/";
                Bind(data, "m_ShaderSplats", shaders + "RenderGaussianSplats.shader");
                Bind(data, "m_ShaderComposite", "Assets/GMGN/GaussianWorld/Resources/GaussianWorld/GuardedGaussianComposite.shader");
                Bind(data, "m_ShaderDebugPoints", shaders + "GaussianDebugRenderPoints.shader");
                Bind(data, "m_ShaderDebugBoxes", shaders + "GaussianDebugRenderBoxes.shader");
                Bind(data, "m_CSSplatUtilities", shaders + "SplatUtilities.compute");
                data.FindProperty("m_RenderMode").enumValueIndex = 0; // True ellipsoid splats, never debug points.
                data.ApplyModifiedPropertiesWithoutUndo();
                go.SetActive(true);
                PrefabUtility.SaveAsPrefabAsset(go, Root + "/Cabin.prefab");
            } finally { UnityEngine.Object.DestroyImmediate(go); }
            ConfigureUrp();
            AssetDatabase.SaveAssets();
            Debug.Log("Cabin true Gaussian SPZ asset prepared; visual and 60fps acceptance pending");
        }
        static void Bind(SerializedObject data, string field, string path)
        {
            var asset = AssetDatabase.LoadAssetAtPath<UnityEngine.Object>(path);
            if (asset == null) throw new InvalidOperationException("Missing Gaussian shader: " + path);
            data.FindProperty(field).objectReferenceValue = asset;
        }
        public static void ValidateRenderPath()
        {
            var pipeline = GraphicsSettings.defaultRenderPipeline as UniversalRenderPipelineAsset;
            if (pipeline == null) throw new InvalidOperationException("Gaussian cabin requires active URP");
            var renderers = new SerializedObject(pipeline).FindProperty("m_RendererDataList");
            for (var i = 0; i < renderers.arraySize; i++) {
                var renderer = renderers.GetArrayElementAtIndex(i).objectReferenceValue as UniversalRendererData;
                if (renderer == null || !renderer.rendererFeatures.Any(f => f != null && f.GetType().FullName == "GaussianSplatting.Runtime.GaussianSplatURPFeature")) continue;
                // The pinned upstream splat pass assumes an intermediate color target.
                // Direct backbuffer rendering on Metal flips the Gaussian scene vertically.
                if (renderer.intermediateTextureMode != IntermediateTextureMode.Always)
                    throw new InvalidOperationException("Gaussian renderer requires Intermediate Texture = Always: " + renderer.name);
            }
        }
        static void ConfigureUrp()
        {
            var pipeline = GraphicsSettings.defaultRenderPipeline as UniversalRenderPipelineAsset;
            if (pipeline == null) throw new InvalidOperationException("Gaussian cabin requires active URP");
            pipeline.msaaSampleCount = 1;
            pipeline.supportsHDR = true;
            var serialized = new SerializedObject(pipeline);
            var renderers = serialized.FindProperty("m_RendererDataList");
            var featureType = Find("GaussianSplatting.Runtime.GaussianSplatURPFeature");
            for (var i = 0; i < renderers.arraySize; i++) {
                var renderer = renderers.GetArrayElementAtIndex(i).objectReferenceValue as ScriptableRendererData;
                if (renderer == null) continue;
                if (renderer is UniversalRendererData universal) {
                    universal.intermediateTextureMode = IntermediateTextureMode.Always;
                    EditorUtility.SetDirty(universal);
                }
                if (renderer.rendererFeatures.Any(f => f != null && f.GetType() == featureType)) continue;
                var feature = (ScriptableRendererFeature)ScriptableObject.CreateInstance(featureType);
                feature.name = "Cabin Gaussian Splats";
                AssetDatabase.AddObjectToAsset(feature, renderer);
                renderer.rendererFeatures.Add(feature);
                feature.Create(); renderer.SetDirty(); EditorUtility.SetDirty(renderer);
            }
            EditorUtility.SetDirty(pipeline);
        }
    }
}
