#!/usr/bin/env python3
"""Private actual taskd HTTP/SQLite receipt -> production Unity notification consumer.

No provider request, model, application, renderer or audio is started. Archive
imports represent existing legacy facts; they are not new generation grants.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services/gmgn-taskd/tests"))
from process import Daemon


def identity():
    return str(uuid.uuid4()).upper()


def main():
    with tempfile.TemporaryDirectory(prefix="gmgn-continuation-proof-") as scratch:
        binary = Path(scratch) / "notification-consumer"
        subprocess.run(["swiftc", "-parse-as-library",
                        str(ROOT / "tools/test-unity-wish-agent-inbox.swift"),
                        str(ROOT / "apps/macos/UnityHost/UnityWorldNotifications.swift"),
                        "-o", str(binary)], check=True)
        daemon = Daemon(Path(scratch) / "private-taskd")
        try:
            wish, grant, current_resume = identity(), identity(), identity()
            events = []
            expected = set()
            for kind in ["stateChanged", "submitted", "unknown", "outputReady", "failed", "cancelled", "interrupted", "placed"]:
                event = dict(id=identity(), wishID=wish, worldID="world.origin",
                             residentScope="resident.origin", objectID="prop.output",
                             kind=kind, acknowledged=False)
                events.append(event)
                if kind in {"outputReady", "failed", "cancelled", "interrupted", "placed"}:
                    expected.add(event["id"])
            for resume in [identity(), current_resume]:
                event = dict(id=identity(), wishID=wish, worldID="world.origin",
                             residentScope="resident.origin", objectID="prop.output",
                             kind="stateChanged", acknowledged=False,
                             continuationResumeAuthorizationID=resume)
                events.append(event)
                if resume == current_resume:
                    expected.add(event["id"])
            base = dict(authorizations=[dict(id=grant)], jobs=[dict(id=wish,
                        worldID="world.origin", residentScope="resident.origin",
                        authorizationID=grant, stage="ready",
                        continuationResumeAuthorizationIDs=[current_resume])], events=events)
            checks = 0

            def verify(archive, allowed, consume=True):
                nonlocal checks
                owner, session = identity(), identity()
                params = dict(ownerID=owner, hostSessionID=session, expectedRevision=0)
                opened = daemon.request("wish_control_open", dict(params, legacyArchive=archive))
                assert "result" in opened, opened.get("error")
                receipt = daemon.request("wish_control_read", params)["result"]
                actual = {row["id"] for row in receipt["views"]["continuationEvents"]}
                assert receipt["revision"] == 0 and actual == allowed, (actual, allowed)
                checks += 1
                if consume:
                    env = dict(os.environ, GMGN_CONTINUATION_RECEIPT=json.dumps(receipt),
                               GMGN_EXPECTED_CONTINUATION_IDS=",".join(sorted(allowed)))
                    subprocess.run([str(binary)], env=env, check=True)
                return params, receipt

            params, receipt = verify(base, expected)
            daemon.stop()
            daemon.start()
            restarted = daemon.request("wish_control_read", params)["result"]
            assert restarted == receipt, "restart must preserve exact revision/authority projection"
            checks += 1
            paused = copy.deepcopy(base)
            paused["jobs"][0]["autoContinuationPaused"] = True
            verify(paused, set())
            claimed = copy.deepcopy(base)
            claimed["jobs"][0]["stage"] = "claimed"
            verify(claimed, {row["id"] for row in events if row["id"] in expected and row["kind"] != "outputReady"})
            placed = copy.deepcopy(base)
            placed["delegations"] = [dict(id=identity(), authorizationID=grant,
                worldID="world.origin", residentScope="resident.origin", state="placed")]
            verify(placed, set())
            acknowledged = copy.deepcopy(base)
            for row in acknowledged["events"]:
                row["acknowledged"] = True
            _, value = verify(acknowledged, set(), consume=False)
            assert value["views"]["pendingEvents"] == []
            checks += 1
            foreign = copy.deepcopy(base)
            for row in foreign["events"]:
                row["residentScope"] = "foreign"
            verify(foreign, set(), consume=False)
            print(f"PASS: {checks} actual private Rust continuation authority/restart checks; production Swift consumers passed")
        finally:
            daemon.stop()


if __name__ == "__main__":
    main()
