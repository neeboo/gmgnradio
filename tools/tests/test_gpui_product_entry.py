"""Pure metadata and dry-run wiring checks; no compiler, signing or App launch."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("gpui_product_plist", ROOT / "tools/gpui-product-plist.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProductEntryTests(unittest.TestCase):
    def carrier(self):
        with (ROOT / "apps/macos/Resources/Info.plist").open("rb") as handle:
            source = plistlib.load(handle)
        replacements = {"$(DEVELOPMENT_LANGUAGE)": "en", "$(EXECUTABLE_NAME)": "gmgn radio",
                        "$(PRODUCT_BUNDLE_IDENTIFIER)": "ai.gmgn.radio", "$(PRODUCT_NAME)": "gmgn radio",
                        "$(PRODUCT_BUNDLE_PACKAGE_TYPE)": "APPL", "$(MACOSX_DEPLOYMENT_TARGET)": "26.0"}
        return {key: replacements.get(value, value) if isinstance(value, str) else value
                for key, value in source.items()}

    def test_formal_metadata_preserved(self):
        carrier = self.carrier()
        carrier["CFBundleVersion"] = "321"
        carrier["NSCustomFutureUsageDescription"] = "must survive"
        output = module.product_metadata(carrier)
        self.assertEqual(output["CFBundleExecutable"], "gmgn-gpui-app")
        self.assertEqual({key: value for key, value in output.items() if key != "CFBundleExecutable"},
                         {key: value for key, value in carrier.items() if key != "CFBundleExecutable"})

    def test_e2e_carrier_cannot_become_formal(self):
        carrier = self.carrier()
        carrier["CFBundleIdentifier"] = "ai.gmgn.radio.e2e"
        with self.assertRaises(ValueError):
            module.product_metadata(carrier)
        output = module.product_metadata(carrier, e2e=True)
        self.assertEqual(output["CFBundleIdentifier"], "ai.gmgn.radio.e2e")
        with self.assertRaises(ValueError):
            module.product_metadata(self.carrier(), e2e=True)

    def test_unresolved_or_missing_privacy_rejected(self):
        for key in ("NSMicrophoneUsageDescription", "NSAppleMusicUsageDescription",
                    "NSLocalNetworkUsageDescription", "CFBundleVersion"):
            carrier = self.carrier()
            carrier.pop(key)
            with self.assertRaises(ValueError):
                module.product_metadata(carrier)
        carrier = self.carrier()
        carrier["CFBundleVersion"] = "$(CURRENT_PROJECT_VERSION)"
        with self.assertRaises(ValueError):
            module.product_metadata(carrier)

    def test_formal_make_chain_is_unity_embedded_not_standalone(self):
        plan = subprocess.check_output(["make", "-n", "build", "TEST_ICON="], cwd=ROOT, text=True)
        self.assertIn("bash tools/build-unity-product-app.sh", plan)
        self.assertNotIn("build-gpui-product-host.sh", plan)
        self.assertNotIn("build-gpui-product-app.sh", plan)
        self.assertNotIn("xcodebuild", plan)
        self.assertNotIn("e2e-app-build", plan)
        self.assertNotIn("install-macos.py", plan)
        self.assertNotIn("$(MAKE)", plan)

    def test_debug_and_universal_are_explicit(self):
        plan = subprocess.check_output(["make", "-n", "build-gpui-experimental", "CONFIGURATION=Debug",
                                        "ARCH_FLAGS=ONLY_ACTIVE_ARCH=NO", "TEST_ICON="], cwd=ROOT, text=True)
        self.assertIn('GMGN_GPUI_CONFIGURATION="Debug"', plan)
        self.assertIn('GMGN_GPUI_ARCHS="arm64 x86_64"', plan)
        self.assertIn('GMGN_GPUI_ONLY_ACTIVE_ARCH="NO"', plan)


if __name__ == "__main__":
    unittest.main()
