#!/usr/bin/env python3
"""Typecheck the real Library/HTTP/client with UI and endpoint leaf stubs only.

This never executes a provider request or claims runtime acceptance.
"""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = repo / "apps/macos/Sources/GMGNRadio"
spatial = (source / "VisualEngine/SpatialStageStore.swift").read_text()
preset = "enum SpatialScenePreset" + spatial.split("enum SpatialScenePreset", 1)[1].split("enum SpatialMovement", 1)[0]
stubs = '''import Foundation
@MainActor final class SpatialStageStore {
    func selectScene(_ scene: SpatialScenePreset) {}
    func selectWorld(id: String?) {}
}
enum LivingWorldBootstrap { static let marbleCabinDirectoryName = "fixture-cabin" }
enum WorldAuthorityError: Error { case invalidResponse, daemon(String) }
struct TaskdHTTPAuthorityClient: Sendable {
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: Double) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] {
        throw RustMarbleControlError.unavailable
    }
}
'''
with tempfile.TemporaryDirectory(prefix="gmgn-marble-library-typecheck-") as raw:
    root = Path(raw)
    fixture = root / "Leaves.swift"
    fixture.write_text(stubs + preset)
    module = repo / "apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug/Modules"
    paths = ["VisualEngine/MarbleWorld.swift", "VisualEngine/MarbleWorldCache.swift",
             "VisualEngine/MarbleWorldClient.swift", "VisualEngine/MarbleWorldLibrary.swift",
             "Presence/RustMarbleControlClient.swift", "Presence/RustMarbleGeometryClient.swift"]
    result = subprocess.run(["swiftc", "-swift-version", "6", "-typecheck", "-I", str(module),
                             str(fixture), *[str(source / path) for path in paths]])
    if result.returncode:
        raise SystemExit(result.returncode)
    print("PASS actual Marble Library/HTTP/client Swift6 typecheck; no network or runtime claim")
