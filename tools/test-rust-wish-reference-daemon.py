#!/usr/bin/env python3
"""Offline actual reference consumers: no fabricated positive run, no Commons HTTP."""
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="gmgn-private-reference-") as temporary:
    fixture = Path(temporary).resolve()
    root = fixture / "taskd"
    root.mkdir()
    endpoint = root / "endpoint.json"
    production = (REPO / "apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift").read_text()
    error = production[production.index("enum WorldAuthorityError:"):production.index("/// 一条权威事实")]
    http = production[production.index("/// Local HTTP authority transport"):production.index("/// 世界状态权威的门面")]
    session = (REPO / "apps/macos/Sources/GMGNRadio/Agent/ResidentWorldToolSession.swift").read_text()
    authority = session[session.index("    struct RustDispatchAuthority:"):session.index("    /// Supplied by the host's real request")]
    additional = session[session.index("    struct AdditionalTool {"):session.index("    struct CallRecord:")]
    result = (REPO / "apps/macos/Sources/GMGNRadio/VoiceSession/RealtimeDJSession.swift").read_text()
    result = result[result.index("struct RealtimeDJToolResult:"):result.index("struct RealtimeDJFailure:")]
    extracted = fixture / "ProductionBoundaries.swift"
    extracted.write_text("import Foundation\nimport OSLog\n" + error + http + result
        + "\n@MainActor final class ResidentWorldToolSession {\n" + authority + additional + "}\n")
    binary = fixture / "consumer"
    sources = ["apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift",
               "apps/macos/Sources/GMGNRadio/Agent/RustWishReferenceClient.swift",
               "apps/macos/Sources/GMGNRadio/Agent/ResidentWishReferenceTools.swift",
               "apps/macos/Sources/GMGNRadio/Agent/ResidentWishReferenceDiagnosis.swift",
               "tools/test-rust-wish-reference-client.swift"]
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(extracted)]
        + [str(REPO / source) for source in sources] + ["-o", str(binary)], check=True, timeout=120)
    log = (fixture / "daemon.log").open("wb")
    daemon = subprocess.Popen([str(REPO / "target/debug/gmgn-taskd"), "--root", str(root),
        "--endpoint-file", str(endpoint), "--concurrency", "1"], stdout=log, stderr=log, start_new_session=True)
    try:
        for _ in range(200):
            if endpoint.exists() and json.loads(endpoint.read_text()).get("version") == 2:
                break
            if daemon.poll() is not None:
                raise RuntimeError("Private daemon startup failed")
            time.sleep(0.025)
        else:
            raise RuntimeError("Private daemon startup timeout")
        subprocess.run([str(binary), str(endpoint)], check=True, timeout=30)
        with sqlite3.connect(root / "tasks.sqlite3") as db:
            for table in ["wish_reference_urls", "wish_reference_calls", "wish_reference_cooldown"]:
                assert db.execute("SELECT COUNT(*) FROM " + table).fetchone()[0] == 0
        print("PASS: private SQLite has no reference effects from unclaimed requests", flush=True)
    finally:
        if daemon.poll() is None:
            os.killpg(daemon.pid, signal.SIGTERM)
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(daemon.pid, signal.SIGKILL)
                daemon.wait(timeout=5)
        log.close()
        print("CLEANUP: only private reference daemon PGID terminated; temporary files removed", flush=True)
