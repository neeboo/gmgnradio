using UnityEditor;
using UnityEditor.Build;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.UIElements;
using UnityEngine.TextCore.Text;
using UnityEngine.TextCore.LowLevel;

namespace GMGN.UnityPlayer.Editor
{
    public static class PlayerBuild
    {
        public static void Prepare()
        {
            GMGN.UnityPlayer.World.Editor.WorldShaderBuild.Prepare();
            PlayerSettings.productName = "GMGN Unity Sample";
            PlayerSettings.runInBackground = true;
            var meshSymbols = PlayerSettings.GetScriptingDefineSymbols(NamedBuildTarget.Standalone);
            if (!System.Array.Exists(meshSymbols.Split(';'), symbol => symbol == "GLTFAST_KEEP_MESH_DATA"))
                PlayerSettings.SetScriptingDefineSymbols(NamedBuildTarget.Standalone, string.IsNullOrEmpty(meshSymbols) ? "GLTFAST_KEEP_MESH_DATA" : meshSymbols + ";GLTFAST_KEEP_MESH_DATA");
            PlayerSettings.SetApplicationIdentifier(NamedBuildTarget.Standalone, "ai.gmgn.unity-sample.player");
            PlayerSettings.fullScreenMode = FullScreenMode.Windowed;
            PlayerSettings.enableFrameTimingStats = true;
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
            panel.scaleMode = PanelScaleMode.ConstantPixelSize;
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
            PrepareLyricsFonts();
            EditorUtility.SetDirty(panel); AssetDatabase.SaveAssets();
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            EditorSceneManager.SaveScene(scene, "Assets/GMGN/Player.unity");
            EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene("Assets/GMGN/Player.unity", true) };
        }
        public static void PrepareLyricsFonts()
        {
            foreach (var style in new[] { "Light", "Medium", "Semibold", "Bold", "Black" }) foreach(var latin in new[]{false,true}) {
                var sourcePath = $"Assets/GMGN/Fonts/{(latin?"GMGNLyricsLatin":"GMGNLyricsSansSC")}-{style}.ttf";
                var source = AssetDatabase.LoadAssetAtPath<Font>(sourcePath);
                if (source == null) throw new System.InvalidOperationException("Missing lyric font source: " + sourcePath);
                var path = $"Assets/GMGN/Resources/PlayerLyrics{style}{(latin?"Latin":"")}Font.asset";
                var asset = AssetDatabase.LoadAssetAtPath<FontAsset>(path);
                if (asset == null) {
                    asset = FontAsset.CreateFontAsset(source, 90, 9, GlyphRenderMode.SDFAA, 1024, 1024, AtlasPopulationMode.Dynamic, true);
                    if (asset == null) throw new System.InvalidOperationException("Failed to create lyric font: " + style);
                    asset.name = "PlayerLyrics" + style + (latin?"Latin":"") + "Font";
                    AssetDatabase.CreateAsset(asset, path);
                    if (asset.material != null) AssetDatabase.AddObjectToAsset(asset.material, asset);
                    foreach (var texture in asset.atlasTextures) if (texture != null) AssetDatabase.AddObjectToAsset(texture, asset);
                }
                asset.isMultiAtlasTexturesEnabled = true;
                // TextCore exposes this build-cleanup setting in serialized data.
                var serialized = new SerializedObject(asset);
                var clear = serialized.FindProperty("m_ClearDynamicDataOnBuild");
                if (clear != null) { clear.boolValue = true; serialized.ApplyModifiedPropertiesWithoutUndo(); }
                EditorUtility.SetDirty(asset);
            }
        }
        public static void BuildMac()
        {
            LocalizationSetup.PrepareForBuild();
            Prepare();
            GpuLyricsValidation.Validate();
            StagePointsValidation.Validate();
            GaussianWorldBootstrap.ValidateRenderPath();
            if (AssetDatabase.LoadAssetAtPath<GameObject>("Assets/GMGN/GaussianWorld/Resources/GaussianWorld/Cabin.prefab") == null)
                throw new System.InvalidOperationException("Prepare the Gaussian cabin with GaussianWorldBootstrap.PrepareCabin before building; missing assets must not produce an empty space.");
            var output = System.Environment.GetEnvironmentVariable("GMGN_UNITY_BUILD_PATH");
            if (string.IsNullOrEmpty(output)) throw new System.InvalidOperationException("Set GMGN_UNITY_BUILD_PATH to an isolated .app output.");
            var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions { scenes = new[] { "Assets/GMGN/Player.unity" }, locationPathName = output, target = BuildTarget.StandaloneOSX, options = BuildOptions.None });
            if (report.summary.result != UnityEditor.Build.Reporting.BuildResult.Succeeded) throw new System.InvalidOperationException("Unity release build failed: " + report.summary.result);
        }
    }
}
