#!/usr/bin/env python3
"""Private production consumer fixture; no application, model, audio or Cargo."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
flags = subprocess.check_output(["bash", "tools/world-runtime-harness-flags.sh"], cwd=repo, text=True).splitlines()
with tempfile.TemporaryDirectory(prefix="gmgn-private-device-") as temporary:
    binary = str(Path(temporary) / "fixture")
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *flags,
        "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift",
        "apps/macos/Sources/GMGNRadio/Presence/RustWorldPropClient.swift",
        "apps/macos/UnityHost/UnityDevicePlacementBridge.swift",
        "tools/test-unity-device-placement.swift", "-o", binary], cwd=repo, check=True)
    subprocess.run([binary], cwd=repo, check=True)
