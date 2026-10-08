"""No GUI, compiler, real data, signing, install or launch."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("unity_metadata", ROOT / "tools/unity-product-metadata.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class UnityEntryTests(unittest.TestCase):
    def info(self):
        return {"CFBundleIdentifier": module.IDENTITY, "CFBundleExecutable": "GMGN Unity Sample",
                "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0",
                "UnityCustomMetadata": "preserved", **{key: "usage" for key in module.PRIVACY}}

    def test_identity_executable_and_source_version_preserved(self):
        output = module.product_metadata(self.info(), self.info())
        for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleVersion", "CFBundleShortVersionString", "UnityCustomMetadata"):
            self.assertEqual(output[key], self.info()[key])
        self.assertEqual(output["CFBundleName"], "gmgn radio")
        output = module.product_metadata(self.info(), self.info(), version="0.2.0", build="217")
        self.assertEqual(output["CFBundleVersion"], "217")

    def test_other_identity_and_unsafe_executable_rejected(self):
        for key, value in (("CFBundleIdentifier", "ai.gmgn.radio"), ("CFBundleIdentifier", "ai.gmgn.unity-sample.other"), ("CFBundleExecutable", "../bad")):
            info = self.info(); info[key] = value
            with self.assertRaises(ValueError): module.product_metadata(info, self.info())

    def test_actual_component_hashes_no_mcpd_required(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "candidate.app"
            for relative in (*module.COMPONENTS, "Contents/MacOS/GMGN Unity Sample"):
                path = app / relative; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(relative.encode()); path.chmod(0o755)
            resources = app / "Contents/Resources"; resources.mkdir()
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info()))
            (resources / "unity-product-manifest.json").write_text(json.dumps({p: hashlib.sha256((app / p).read_bytes()).hexdigest() for p in module.COMPONENTS}))
            module.verify(app)
            for relative in module.COMPONENTS:
                path = app / relative; original = path.read_bytes(); path.write_bytes(b"tamper")
                with self.assertRaises(ValueError): module.verify(app)
                path.write_bytes(original)

    def test_default_release_and_install_route(self):
        for target in ("build", "release", "install"):
            plan = subprocess.check_output(["make", "-n", target, "TEST_ICON="], cwd=ROOT, text=True)
            self.assertIn("build-unity-product-app.sh", plan)
            self.assertNotIn("build-gpui-product-app.sh", plan)
        source = (ROOT / "tools/build-unity-product-app.sh").read_text()
        self.assertIn("GMGN.UnityPlayer.Editor.PlayerBuild.BuildMac", source)
        self.assertNotIn("--editor-version", source)
        self.assertIn("package-gpui-chat2-probe.sh", source)
        self.assertNotIn("mcpd", source.replace("(no mcpd)", ""))
        self.assertIn('overlay_target="$root/tools/gpui-scenekit-probe/target"', source)
        self.assertIn('CARGO_TARGET_DIR="$overlay_target"', source)
        self.assertIn('build -j1 --release', source)
        self.assertNotIn('$overlay/target', source)
        self.assertIn('UNITY_CLI_BIN', source)
        self.assertIn('--non-interactive', source)
        for forbidden in ('--allow-install', 'GMGN_UNITY_DATA_ROOT=', 'GMGN_TASKD_ROOT=', 'open -a', 'install-macos.py', 'GPUIProductHost', 'GPUIRenderHost'):
            self.assertNotIn(forbidden, source)

    def release_wrapper_arguments(self, *make_overrides):
        plan = subprocess.check_output(["make", "-n", "release", "TEST_ICON=", *make_overrides], cwd=ROOT, text=True)
        commands = plan.replace("\\\n", " ").splitlines()
        wrapper_commands = [shlex.split(command) for command in commands if "bash tools/build-unity-product-app.sh" in command]
        self.assertEqual(len(wrapper_commands), 1)
        arguments = wrapper_commands[0]
        bash_index = arguments.index("bash")
        self.assertEqual(arguments[bash_index + 1], "tools/build-unity-product-app.sh")
        self.assertEqual(len(arguments[bash_index + 2:]), 1)
        return arguments[bash_index + 2:]

    def test_release_default_space_path_is_one_exact_argument(self):
        expected = str(ROOT / "apps/macos/Build.noindex/Build/Products/Release/gmgn radio.app")
        self.assertEqual(self.release_wrapper_arguments(), [expected])

    def test_release_absolute_space_path_is_not_rebased_or_split(self):
        expected = str(ROOT / "tmp/ReleaseArtifacts.noindex/custom release/gmgn radio.app")
        self.assertEqual(self.release_wrapper_arguments("PRODUCT_APP=" + expected), [expected])

    def test_unsupported_configuration_rejects_before_any_build(self):
        for overrides in ({"GMGN_UNITY_CONFIGURATION": "Debug"}, {"GMGN_UNITY_ONLY_ACTIVE_ARCH": "NO"}):
            result = subprocess.run(["bash", str(ROOT / "tools/build-unity-product-app.sh"), str(ROOT / "tmp/candidate.app")], env={**os.environ, **overrides}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("Release/active architecture only", result.stderr)

if __name__ == "__main__": unittest.main()
