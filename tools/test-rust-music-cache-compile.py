#!/usr/bin/env python3
"""Compile actual cache consumer; endpoint is unavailable and no RPC is executed."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = repo / "apps/macos/Sources/GMGNRadio"
http = (source / "MusicSources/MusicProviderHTTPTransport.swift").read_text()
http = http.split("extension MusicProviderSession", 1)[0] + "func checkedProviderResponse" + http.split("func checkedProviderResponse", 1)[1]
leaves = '''import Foundation
enum WorldAuthorityError: Error { case invalidResponse }
struct TaskdHTTPAuthorityClient: Sendable {
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: Double) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] {
        throw WorldAuthorityError.invalidResponse
    }
}
'''
with tempfile.TemporaryDirectory(prefix="gmgn-music-cache-compile-") as directory:
    root = Path(directory)
    leaf = root / "Leaves.swift"
    leaf.write_text(leaves)
    raw = root / "HTTP.swift"
    raw.write_text(http)
    result = subprocess.run(["swiftc", "-swift-version", "6", "-typecheck", str(leaf), str(raw),
        str(source / "MusicSources/RustMusicCacheClient.swift"),
        str(source / "MusicSources/StreamingMusicCache.swift")])
    if result.returncode:
        raise SystemExit(result.returncode)
    print("PASS actual music cache/client/HTTP Swift6 typecheck; no RPC/provider/audio")
