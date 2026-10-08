using System;
using System.Reflection;
using System.Runtime.Serialization;
using GMGN.UnityPlayer;
class GPUIVoiceRouteChecks
{
    static int Main()
    {
        // Reflection-only production contract: no GameObject, host, UI or audio device.
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var panel = (GPUIChat2Probe)FormatterServices.GetUninitializedObject(typeof(GPUIChat2Probe));
        typeof(GPUIChat2Probe).GetField("mounted", flags).SetValue(panel, true);
        typeof(GPUIChat2Probe).GetField("projectionReady", flags).SetValue(panel, true);
        if (!panel.IsProjectionReady) return 1;
        foreach (var field in new[] { "draft", "chatPanel", "messages", "toolbar", "volume", "settingsPanel", "composition" })
            if (typeof(PlayerScreen).GetField(field, flags) != null) return 2;
        foreach (var method in new[] { "OnVoiceTranscript", "ReportTextInputState", "RetireLegacyUI", "AddIcon" })
            if (typeof(PlayerScreen).GetMethod(method, flags) != null) return 3;
        string Op(string state) => (string)typeof(PlayerScreen).GetMethod("ChatVoiceOperation", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { state });
        if (Op("idle") != "voice.press" || Op("error") != "voice.press" || Op("listening") != "voice.release" ||
            Op("connecting") != "voice.cancel" || Op("transcribing") != "voice.cancel") return 4;
        if (typeof(GPUIChat2Probe).GetMethod("Shutdown") == null || typeof(GPUIChat2Probe).GetMethod("Toggle") != null) return 5;
        var escape = typeof(GPUIChat2Probe).GetMethod("gmgn_gpui_take_escape_consumed", BindingFlags.Static | BindingFlags.NonPublic);
        if (escape == null || escape.ReturnType != typeof(int)) return 6;
        typeof(GPUIChat2Probe).GetField("projectionReady", flags).SetValue(panel, false);
        if (panel.IsProjectionReady) return 7;
        typeof(GPUIChat2Probe).GetField("mounted", flags).SetValue(panel, false);
        typeof(GPUIChat2Probe).GetField("projectionReady", flags).SetValue(panel, true);
        if (panel.IsProjectionReady) return 8;
        Console.WriteLine("PASS actual ready-only projection, voice policy, removed old controls and escape ABI; no native UI/audio/host started");
        return 0;
    }
}
