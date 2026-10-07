using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;

namespace GMGN.UnityPlayer.Editor
{
    /// Ships the original complete package so the native validator checks exactly
    /// the same authored declarations/assets as the previous application.
    public sealed class BuiltinDevicePackageBuild : IPostprocessBuildWithReport
    {
        public int callbackOrder => 10;
        public void OnPostprocessBuild(BuildReport report)
        {
            if (report.summary.platform != BuildTarget.StandaloneOSX) return;
            var source = Path.GetFullPath(Path.Combine(UnityEngine.Application.dataPath,
                "../../macos/Resources/Worlds/marble-living-cabin"));
            if (!File.Exists(Path.Combine(source, "world.json")))
                throw new BuildFailedException("The authored device world package is missing.");
            var target = Path.Combine(report.summary.outputPath, "Contents/Resources/Worlds/marble-living-cabin");
            foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
            {
                var relative = file.Substring(source.Length + 1);
                if (relative.EndsWith(".meta")) continue;
                var destination = Path.Combine(target, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(destination));
                File.Copy(file, destination, false);
            }
            var devices = Path.GetFullPath(Path.Combine(UnityEngine.Application.dataPath,"../../../assets/device-designs"));
            var deviceTarget = Path.Combine(report.summary.outputPath,"Contents/Resources/Devices");
            foreach(var name in new[]{"jukebox-v1","wish-tray-v2"}) {
                var model = Path.Combine(devices,name+".glb"); var receipt = Path.Combine(devices,name+".receipt.json");
                if (!File.Exists(model) || !File.Exists(receipt)) continue;
                World.BuiltinWorldDevice.VerifyReceipt(model,receipt);
                Directory.CreateDirectory(deviceTarget);
                File.Copy(model,Path.Combine(deviceTarget,name+".glb"),false);
                File.Copy(receipt,Path.Combine(deviceTarget,name+".receipt.json"),false);
            }
        }
    }
}
