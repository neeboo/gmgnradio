using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Localization;
using UnityEditor.AddressableAssets.Settings;
using UnityEngine;
using UnityEngine.Localization;
using UnityEngine.Localization.Settings;
using UnityEngine.Localization.Tables;

namespace GMGN.UnityPlayer.Editor
{
    public static class LocalizationSetup
    {
        public static void Prepare()
        {
            try {
                var type = Type.GetType("UnityEngine.Localization.Settings.LocalizationSettings, Unity.Localization");
                if (type == null) throw new Exception("Localization assemblies are not loaded");
                Directory.CreateDirectory("Assets/GMGN/Localization");
                var settings = LocalizationEditorSettings.ActiveLocalizationSettings;
                if (settings == null) {
                    var guid = AssetDatabase.FindAssets("t:LocalizationSettings", new[] { "Assets" }).FirstOrDefault();
                    settings = guid == null ? ScriptableObject.CreateInstance<LocalizationSettings>() : AssetDatabase.LoadAssetAtPath<LocalizationSettings>(AssetDatabase.GUIDToAssetPath(guid));
                    if (guid == null) AssetDatabase.CreateAsset(settings, "Assets/GMGN/Localization/LocalizationSettings.asset");
                    LocalizationEditorSettings.ActiveLocalizationSettings = settings;
                }
                var codes = new[] { "zh-CN", "en", "ja" };
                foreach (var code in codes) {
                    if (LocalizationEditorSettings.GetLocales().Any(locale => locale.Identifier.Code == code)) continue;
                    var locale = Locale.CreateLocale(code);
                    AssetDatabase.CreateAsset(locale, $"Assets/GMGN/Localization/Locale-{code}.asset");
                    LocalizationEditorSettings.AddLocale(locale);
                }
                LocalizationSettings.StartupLocaleSelectors.Clear();
                LocalizationSettings.StartupLocaleSelectors.Add(new SpecificLocaleSelector { LocaleId = new LocaleIdentifier("zh-CN") });
                var collection = LocalizationEditorSettings.GetStringTableCollection(UiLocalization.TableName)
                    ?? LocalizationEditorSettings.CreateStringTableCollection(UiLocalization.TableName, "Assets/GMGN/Localization");
                foreach (var code in codes) {
                    var table = collection.GetTable(code) as StringTable ?? collection.AddNewTable(code) as StringTable;
                    var column = Array.IndexOf(codes, code);
                    foreach (var entry in LocalizationTableSeed.Strings) table.AddEntry(entry.Key, entry.Value[column]);
                    LocalizationEditorSettings.SetPreloadTableFlag(table, true);
                    EditorUtility.SetDirty(table);
                }
                EditorUtility.SetDirty(settings); EditorUtility.SetDirty(collection); EditorUtility.SetDirty(collection.SharedData);
                LocalizationEditorSettings.EditorEvents.RaiseCollectionModified(typeof(LocalizationSetup), collection);
                AssetDatabase.SaveAssets();
                int checkedCount = 0;
                foreach (var key in collection.SharedData.Entries)
                    foreach (var code in codes) {
                        var table = collection.GetTable(code) as StringTable;
                        if (string.IsNullOrWhiteSpace(table?.GetEntry(key.Id)?.Value)) throw new Exception($"Missing translation: {code}/{key.Key}");
                        checkedCount++;
                    }
                if (checkedCount == 0) throw new Exception("No localization entries were verified");
                Debug.Log($"Localization COMPLETE: {checkedCount} entries checked, no gaps; loaded type={type.FullName}");
                AddressableAssetSettings.BuildPlayerContent(out var build);
                if (!string.IsNullOrEmpty(build.Error)) throw new Exception(build.Error);
                Debug.Log("Localization Addressables content prepared");
                EditorApplication.Exit(0);
            } catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
        }
    }
}
