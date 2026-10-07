#!/usr/bin/env python3
"""Execute the actual pre-sign MAIN plist packaging contract on temporary files.

No Player/App launch, codesigning, builds, TCC changes, or installed App writes.
"""
from pathlib import Path
import plistlib
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / "tools/package-unity-media-host.sh").read_text()
key = "NSMicrophoneUsageDescription"
fragment = source.split("# Use the product's final icon for every newly packaged Unity player.\n", 1)[1]
fragment = fragment.split('codesign --force --sign - "$app"', 1)[0]
original = plistlib.loads((repo / "apps/macos/Resources/Info.plist").read_bytes())
expected = original[key]
assert isinstance(expected, str) and expected.strip()

failed = False
with tempfile.TemporaryDirectory(prefix="gmgn-unity-microphone-contract-") as temporary:
    root = Path(temporary)
    resource = root / "apps/macos/Resources"
    resource.mkdir(parents=True)
    (resource / "AppIcon.icns").write_bytes(b"fixture-icon")
    for scenario, existing, format in [
        ("missing-add", None, plistlib.FMT_XML),
        ("existing-update", "old usage", plistlib.FMT_XML),
        ("empty-update-binary", "", plistlib.FMT_BINARY),
        ("empty-source-rejected", None, plistlib.FMT_XML),
        ("whitespace-source-rejected", None, plistlib.FMT_XML),
    ]:
        app = root / f"{scenario}.app"
        contents = app / "Contents"
        (contents / "Resources").mkdir(parents=True)
        main_plist = contents / "Info.plist"
        before = {"CFBundleIdentifier": "ai.gmgn.unity-sample.contract", "CFBundleIconFile": "AppIcon.icns",
                  "CFBundleExecutable": "GMGN Unity Sample", "fixtureKeep": {"value": 7}}
        if existing is not None:
            before[key] = existing
        main_plist.write_bytes(plistlib.dumps(before, fmt=format))
        product = dict(original)
        if scenario == "empty-source-rejected":
            product[key] = ""
        elif scenario == "whitespace-source-rejected":
            product[key] = " \t "
        (resource / "Info.plist").write_bytes(plistlib.dumps(product))
        try:
            for _ in range(2):
                result = subprocess.run(["bash", "-c", 'set -euo pipefail\nrepo_root="$1"\napp="$2"\n' + fragment,
                                         "fixture", str(root), str(app)], capture_output=True, text=True)
                after = plistlib.loads(main_plist.read_bytes())
                if scenario.endswith("rejected"):
                    assert result.returncode != 0, "empty source usage accepted"
                    assert after == before, "invalid source changed MAIN plist"
                else:
                    assert result.returncode == 0, result.stderr
                    assert after.get(key) == expected, "MAIN microphone usage missing or not updated"
                    assert {k: v for k, v in after.items() if k != key} == {k: v for k, v in before.items() if k != key}, "unrelated plist keys changed"
            print(f"{scenario}: PASS")
        except AssertionError as error:
            failed = True
            print(f"{scenario}: FAIL: {error}")
if failed:
    raise SystemExit(1)
print("Unity MAIN microphone disclosure: pre-sign real plist contract passed")
