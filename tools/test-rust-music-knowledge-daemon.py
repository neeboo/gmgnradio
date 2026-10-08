#!/usr/bin/env python3
"""Actual production Swift knowledge consumers -> private built taskd -> SQLite.

No production application-support access, external provider request or audio.
Production HTTP/error classes are extracted verbatim into the isolated compilation;
only the default endpoint primitive is a fail-fast boundary double.
"""
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="gmgn-private-knowledge-") as temporary:
    fixture = Path(temporary).resolve()
    root = fixture / "taskd"
    root.mkdir()
    endpoint = root / "endpoint.json"
    binary = fixture / "consumer"
    production = (REPO / "apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift").read_text()
    error = production[production.index("enum WorldAuthorityError:"):production.index("/// 一条权威事实")]
    transport = production[production.index("/// Local HTTP authority transport"):production.index("/// 世界状态权威的门面")]
    extracted = fixture / "ProductionHTTP.swift"
    extracted.write_text("import Foundation\nimport OSLog\n" + error + transport)
    original_tests = REPO / "apps/macos/Tests/GMGNRadioTests/MusicKnowledge/MusicLibraryIndexTests.swift"
    legacy = original_tests.read_text().replace("import Testing\n", "").replace("@testable import GMGNRadio\n", "").replace("@Test\n", "").replace("#expect(", "precondition(").replace("#filePath", json.dumps(str(original_tests)))
    extracted_tests = fixture / "OriginalKnowledgeChecks.swift"
    extracted_tests.write_text(legacy)
    sources = [
        "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift",
        "apps/macos/Sources/GMGNRadio/MusicSources/MusicSource.swift",
        "apps/macos/Sources/GMGNRadio/MusicKnowledge/TrackKnowledge.swift",
        "apps/macos/Sources/GMGNRadio/MusicKnowledge/MusicLibraryIndex.swift",
        "apps/macos/Sources/GMGNRadio/MusicKnowledge/RustMusicKnowledgeClient.swift",
        "tools/test-rust-music-knowledge-client.swift",
    ]
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(extracted), str(extracted_tests)]
        + [str(REPO / p) for p in sources] + ["-o", str(binary)], check=True, timeout=120)
    daemon = None
    log = (fixture / "daemon.log").open("wb")
    def start():
        global daemon
        daemon = subprocess.Popen([str(REPO / "target/debug/gmgn-taskd"), "--root", str(root),
            "--endpoint-file", str(endpoint), "--concurrency", "1"], stdout=log, stderr=log, start_new_session=True)
        for _ in range(200):
            if endpoint.exists():
                descriptor = json.loads(endpoint.read_text())
                if descriptor.get("version") == 2:
                    return
            if daemon.poll() is not None:
                log.flush()
                detail = (fixture / "daemon.log").read_text(errors="replace")
                raise RuntimeError("Private taskd exited before ready: " + detail[:1200])
            time.sleep(0.025)
        raise RuntimeError("Private taskd startup timeout")
    def stop():
        global daemon
        if daemon is not None and daemon.poll() is None:
            os.killpg(daemon.pid, signal.SIGTERM)
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(daemon.pid, signal.SIGKILL)
                daemon.wait(timeout=5)
        daemon = None
        endpoint.unlink(missing_ok=True)
    def consume(scope, phase):
        child = subprocess.Popen([str(binary), str(endpoint), scope, phase], start_new_session=True)
        try:
            assert child.wait(timeout=60) == 0, "Native consumer failed"
        finally:
            # This group was created by this harness and includes only its
            # consumer + private unit-fixture daemons, even on an assertion trap.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if child.poll() is None:
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
    try:
        start()
        scope = str(fixture / "knowledge")
        consume(scope, "write")
        stop()
        dbfile = root / "tasks.sqlite3"
        with sqlite3.connect(dbfile) as db:
            rows = db.execute("SELECT identity,payload FROM music_knowledge_tracks WHERE scope=?", (scope,)).fetchall()
            assert len(rows) == 1 and rows[0][0] == "canonical:isrc:one"
            facts = json.loads(rows[0][1])
            assert facts["playCount"] == facts["completedPlayCount"] == facts["skipCount"] == 1
            assert len(facts["sources"]) == 3
            assert db.execute("SELECT COUNT(*) FROM music_knowledge_commands WHERE scope=?", (scope,)).fetchone()[0] == 7
        print("PASS: private SQLite persisted only Rust-owned merged knowledge and 7 actual command facts", flush=True)
        start()
        consume(scope, "read")
        consume(str(fixture / "golden"), "golden")
        consume(str(fixture / "legacy"), "legacy")
        print("PASS: schema27 actual production consumers, private restart, Unicode golden; no provider/audio", flush=True)
    finally:
        stop()
        log.close()
        print("CLEANUP: terminated only fixture-owned daemon process group; private temporary files removed", flush=True)
