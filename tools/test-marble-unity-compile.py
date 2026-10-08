#!/usr/bin/env python3
"""Typecheck production Marble Unity consumers; no UI, authority or provider execution."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = repo / "apps/macos/Sources/GMGNRadio"
spatial = (source / "VisualEngine/SpatialStageStore.swift").read_text()
preset = "enum SpatialScenePreset" + spatial.split("enum SpatialScenePreset", 1)[1].split("enum SpatialMovement", 1)[0]
marble = (source / "VisualEngine/Metal/MarbleSpatialView.swift").read_text()
framing = "struct MarbleSceneFraming" + marble.split("struct MarbleSceneFraming", 1)[1].split("    func recommendedCameraHome", 1)[0]
framing += "    func colliderTransform" + marble.split("    func colliderTransform", 1)[1].split("    func normalizedSample", 1)[0]
framing += "    private static func trimmedBounds" + marble.split("    private static func trimmedBounds", 1)[1].split("enum MarbleAvatarLoadError", 1)[0]
stubs = '''import Foundation
import WorldRuntime
struct BundledLivingWorldPackage: Sendable { let manifest: WorldManifest; let packageRoot: URL }
@MainActor protocol UnityMarbleWorldCommands: AnyObject {
    var snapshot: [String: Any] { get }
    func command(_ value: [String: Any]) -> Bool
    func close()
}
'''
with tempfile.TemporaryDirectory(prefix="gmgn-marble-unity-typecheck-") as raw:
    root = Path(raw)
    fixture = root / "Leaves.swift"
    fixture.write_text(stubs + preset + framing)
    flags = [value for value in subprocess.check_output(["sh", str(repo / "tools/world-runtime-harness-flags.sh")], text=True).splitlines() if not value.endswith(".o")]
    products = repo / "tmp/unity-media-host/DerivedData/Build/Products/Release"
    paths = [source / p for p in ["VisualEngine/MarbleWorld.swift", "VisualEngine/MarbleWorldCache.swift",
        "VisualEngine/MarbleWorldClient.swift", "Presence/RustMarbleControlClient.swift", "Presence/RustMarbleGeometryClient.swift",
        "Presence/WorldAuthorityClient.swift", "Presence/RetryBackoff.swift", "Presence/TaskdHTTPTransport.swift",
        "VisualEngine/MarblePackagePreparation.swift", "VisualEngine/UnityMarbleRuntimeDocument.swift",
        "VisualEngine/UnityMarbleSPZFormat.swift"]]
    paths += [repo / "apps/macos/UnityHost" / p for p in ["UnityMarbleWorldBridge.swift", "UnityMarbleAuthorityRegistration.swift"]]
    result = subprocess.run(["swiftc", "-swift-version", "6", "-typecheck", *flags,
        "-I", str(products), str(fixture), *map(str, paths)])
    raise SystemExit(result.returncode)
