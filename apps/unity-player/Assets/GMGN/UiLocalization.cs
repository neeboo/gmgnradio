using System;
using UnityEngine;
using UnityEngine.Localization;
using UnityEngine.Localization.Settings;
using UnityEngine.Localization.Tables;
using UnityEngine.ResourceManagement.AsyncOperations;

namespace GMGN.UnityPlayer
{
    // UI Toolkit consumes official String Tables; the host owns the persisted preference.
    public static class UiLocalization
    {
        public const string TableName = "GMGN UI";
        public static event Action Changed;
        static StringTable table;
        static string requestedLocale;
        static bool started;
        public static string LocaleCode => table == null ? null : table.LocaleIdentifier.Code;
        public static string Get(string key) => table == null ? "" : table.GetEntry(key)?.LocalizedValue ?? "";
        // Existing panel callers may pass the host preference; selection is centralized above.
        public static string Get(string key, string locale) => Get(key);

        public static void SelectHostLocale(string code)
        {
            if (code != "en" && code != "ja") code = "zh-CN";
            requestedLocale = code;
            if (!started) {
                started = true;
                LocalizationSettings.StartupLocaleSelectors.Clear();
                LocalizationSettings.StartupLocaleSelectors.Add(new SpecificLocaleSelector {
                    LocaleId = new LocaleIdentifier(code)
                });
                LocalizationSettings.SelectedLocaleChanged += LoadTable;
                LocalizationSettings.InitializationOperation.Completed += operation => {
                    if (operation.Status != AsyncOperationStatus.Succeeded) {
                        Debug.LogError("Localization initialization failed"); return;
                    }
                    SelectRequestedLocale();
                };
            } else if (LocalizationSettings.InitializationOperation.IsDone) SelectRequestedLocale();
        }

        static void SelectRequestedLocale()
        {
            var selected = LocalizationSettings.AvailableLocales.GetLocale(requestedLocale);
            if (selected == null) { Debug.LogError($"Locale is unavailable: {requestedLocale}"); return; }
            if (LocalizationSettings.SelectedLocale == selected) { if (table == null) LoadTable(selected); }
            else LocalizationSettings.SelectedLocale = selected;
        }

        static void LoadTable(Locale selected)
        {
            // Locale changes release the previous Addressables table. Do not
            // read that Unity object while the replacement is loading.
            table = null;
            LocalizationSettings.StringDatabase.GetTableAsync(TableName, selected).Completed += operation => {
                if (LocalizationSettings.SelectedLocale != selected) return;
                if (operation.Status != AsyncOperationStatus.Succeeded || operation.Result == null) {
                    Debug.LogError("UI String Table could not be loaded"); return;
                }
                table = operation.Result;
                Changed?.Invoke();
            };
        }
    }
}
