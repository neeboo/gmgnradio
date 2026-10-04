using UnityEditor;
using UnityEditor.Build;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.UIElements;
using UnityEngine.TextCore.Text;

namespace GMGN.UnityPlayer.Editor
{
    public static class PlayerBuild
    {
        public static void Prepare()
        {
            PlayerSettings.productName = "GMGN Unity Sample";
            PlayerSettings.SetApplicationIdentifier(NamedBuildTarget.Standalone, "ai.gmgn.unity-sample.player");
            PlayerSettings.fullScreenMode = FullScreenMode.Windowed;
            PlayerSettings.defaultScreenWidth = 1440;
            PlayerSettings.defaultScreenHeight = 900;
            const string materialPath = "Assets/GMGN/Resources/AudioMaterial.mat";
            if (AssetDatabase.LoadAssetAtPath<Material>(materialPath) == null) {
                var material = new Material(Shader.Find("Universal Render Pipeline/Unlit"));
                material.color = new Color(.23f, .73f, .9f);
                AssetDatabase.CreateAsset(material, materialPath);
            }
            const string panelPath = "Assets/GMGN/Resources/PlayerPanel.asset";
            var panel = AssetDatabase.LoadAssetAtPath<PanelSettings>(panelPath);
            if (panel == null) { panel = ScriptableObject.CreateInstance<PanelSettings>(); AssetDatabase.CreateAsset(panel, panelPath); }
            panel.scaleMode = PanelScaleMode.ScaleWithScreenSize;
            panel.referenceResolution = new Vector2Int(1440, 900);
            var theme = AssetDatabase.LoadAssetAtPath<ThemeStyleSheet>("Assets/GMGN/Resources/PlayerTheme.tss");
            panel.themeStyleSheet = theme;
            var font = AssetDatabase.LoadAssetAtPath<Font>("Assets/GMGN/Fonts/NotoSansSC-Regular.ttf");
            if (font != null) {
                const string textPath = "Assets/GMGN/Resources/PlayerTextSettings.asset";
                var settings = AssetDatabase.LoadAssetAtPath<PanelTextSettings>(textPath);
                if (settings == null) { settings = ScriptableObject.CreateInstance<PanelTextSettings>(); AssetDatabase.CreateAsset(settings, textPath); }
                const string fontPath = "Assets/GMGN/Resources/PlayerRegularFont.asset";
                var fontAsset = AssetDatabase.LoadAssetAtPath<FontAsset>(fontPath);
                if (fontAsset == null) {
                    fontAsset = FontAsset.CreateFontAsset(font);
                    AssetDatabase.CreateAsset(fontAsset, fontPath);
                    if (fontAsset.material != null) AssetDatabase.AddObjectToAsset(fontAsset.material, fontAsset);
                    foreach (var texture in fontAsset.atlasTextures) if (texture != null) AssetDatabase.AddObjectToAsset(texture, fontAsset);
                }
                settings.defaultFontAsset = fontAsset; panel.textSettings = settings;
                EditorUtility.SetDirty(settings);
            }
            EditorUtility.SetDirty(panel); AssetDatabase.SaveAssets();
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            EditorSceneManager.SaveScene(scene, "Assets/GMGN/Player.unity");
            EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene("Assets/GMGN/Player.unity", true) };
        }
        public static void BuildMac()
        {
            Prepare();
            var output = System.Environment.GetEnvironmentVariable("GMGN_UNITY_BUILD_PATH");
            if (string.IsNullOrEmpty(output)) throw new System.InvalidOperationException("Set GMGN_UNITY_BUILD_PATH to an isolated .app output.");
            var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions { scenes = new[] { "Assets/GMGN/Player.unity" }, locationPathName = output, target = BuildTarget.StandaloneOSX, options = BuildOptions.None });
            if (report.summary.result != UnityEditor.Build.Reporting.BuildResult.Succeeded) throw new System.InvalidOperationException("Unity release build failed: " + report.summary.result);
        }
    }
}
