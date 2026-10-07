#!/usr/bin/env python3
"""Import legacy music archives through authenticated taskd RPC, never SQLite writes.

Source files remain byte-for-byte intact. No endpoint credentials or music payloads
are printed. Migration is idempotent per canonical source path.
"""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import uuid


class Client:
    def __init__(self, endpoint_path):
        endpoint = json.loads(endpoint_path.read_bytes())
        host, port = endpoint["address"].rsplit(":", 1)
        if endpoint["version"] != 2 or host != "127.0.0.1" or not 0 < int(port) < 65536:
            raise RuntimeError("invalid local endpoint")
        self.address = (host, int(port))
        self.token = endpoint["token"]

    def call(self, method, params):
        identity = str(uuid.uuid4())
        frame = json.dumps(dict(id=identity, method=method, params=params),
                           ensure_ascii=False, allow_nan=False).encode()
        if len(frame) > 12 * 1024 * 1024:
            raise RuntimeError("migration exceeds taskd frame limit")
        connection = http.client.HTTPConnection(*self.address, timeout=30)
        try:
            connection.request("POST", "/rpc", body=frame, headers={
                "Authorization": "Bearer " + self.token,
                "Content-Type": "application/json"})
            response = connection.getresponse()
            line = response.read(12 * 1024 * 1024 + 1)
            if len(line) > 12 * 1024 * 1024:
                raise RuntimeError("taskd response exceeds size limit")
            status = response.status
        finally:
            connection.close()
        reply = json.loads(line)
        if "error" in reply:
            raise RuntimeError(reply["error"]["code"])
        if status != 200 or reply.get("id") != identity:
            raise RuntimeError("invalid taskd response identity")
        return reply["result"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", type=Path, required=True)
    parser.add_argument("--programs", type=Path, action="append", default=[])
    parser.add_argument("--library", type=Path, action="append", default=[])
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    client = Client(args.endpoint)
    previous_programs = client.call("music_program_list", {})["programs"]
    previous_library = client.call("music_library_read", {})["playlists"]
    expected_programs = {item["plan"]["brief"]["id"]: item for item in previous_programs}
    expected_library = {item["id"]: item for item in previous_library}
    sources = []
    for kind, paths in (("programs", args.programs), ("playlists", args.library)):
        for path in paths:
            path = path.resolve(strict=True)
            original = path.read_bytes()
            payload = json.loads(original)
            if payload.get("version") != 1 or not isinstance(payload.get(kind), list):
                raise RuntimeError("unsupported legacy archive")
            entries = payload[kind]
            target = expected_programs if kind == "programs" else expected_library
            for item in entries:
                identity = item["plan"]["brief"]["id"] if kind == "programs" else item["id"]
                target.setdefault(identity, item)
            sources.append((path, hashlib.sha256(original).digest(), kind, entries))
    if not args.check_only:
        for path, _, kind, entries in sources:
            client.call("music_import", dict(source=str(path),
                programs=entries if kind == "programs" else [],
                playlists=entries if kind == "playlists" else []))
    actual_programs = {item["plan"]["brief"]["id"]: item
                       for item in client.call("music_program_list", {})["programs"]}
    actual_library = {item["id"]: item
                      for item in client.call("music_library_read", {})["playlists"]}
    for expected, actual in ((expected_programs, actual_programs), (expected_library, actual_library)):
        for identity, item in expected.items():
            if actual.get(identity) != item:
                raise RuntimeError("migration readback mismatch; source preserved")
    for path, checksum, _, _ in sources:
        if hashlib.sha256(path.read_bytes()).digest() != checksum:
            raise RuntimeError("legacy source changed during migration")
    print(json.dumps(dict(verified=True, sourceFiles=len(sources),
        programs=len(actual_programs), programTracks=sum(len(p["plan"]["slots"]) for p in actual_programs.values()),
        playlists=len(actual_library), playlistTracks=sum(len(p["tracks"]) for p in actual_library.values()),
        legacyFilesUnchanged=True, mode="readback" if args.check_only else "migration")))


if __name__ == "__main__":
    main()
