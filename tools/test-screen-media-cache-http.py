#!/usr/bin/env python3
"""Isolated authenticated HTTP fixture -> production Swift cache client/player.

This does not operate the installed application or Unity. Rust download behavior
is tested separately; this verifies the native consumer contract and local PCM.
"""
import argparse
import http.server
import json
import pathlib
import subprocess
import tempfile
import threading
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", default="/opt/homebrew/bin/ffmpeg")
    parser.add_argument("--downloading", action="store_true", help="Never publish ready; require real frames/audio through the authenticated streaming descriptor")
    parser.add_argument("--live", action="store_true", help="Unterminated HLS playlist; cache remains streaming")
    parser.add_argument("--rust", action="store_true", help="Use the real isolated Rust taskd HTTP test server rather than the RPC fixture")
    parser.add_argument("--fragmented", action="store_true", help="Use fragmented MP4 sources like real YouTube DASH rather than faststart MP4")
    parser.add_argument("--real-assets-prefix", help="Read-only prefix for already cached .video.mp4 and .audio.m4a; no formal task or DB access")
    parser.add_argument("--source-delay", type=float, default=.08, help="Seconds per 16 KiB upstream response chunk")
    parser.add_argument("--ready-db", help="Read-only existing ready descriptor fixture from a SQLite cache; never calls its daemon")
    parser.add_argument("--request-page", help="Original user page URL, including share/tracking parameters")
    parser.add_argument("--descriptor-page", help="Canonical page identity reported by the isolated fixture")
    args = parser.parse_args()
    pending = args.downloading or args.live or args.rust
    if args.rust and not args.live:
        args.downloading = True
    with tempfile.TemporaryDirectory(prefix="gmgn-cache-http-") as temporary:
        directory = pathlib.Path(temporary)
        video, audio = directory / "video.mp4", directory / "audio.m4a"
        if args.real_assets_prefix:
            assert args.rust and not args.live, "Real assets are only an isolated Rust VOD upstream"
            video = pathlib.Path(args.real_assets_prefix + ".video.mp4")
            audio = pathlib.Path(args.real_assets_prefix + ".audio.m4a")
            assert video.is_file() and audio.is_file()
        for source, destination, options in [
            ("testsrc2=size=640x360:rate=30", video, ["-c:v", "libx264", "-pix_fmt", "yuv420p"]),
            ("sine=frequency=440:sample_rate=48000", audio, ["-c:a", "aac"]),
        ]:
            if args.real_assets_prefix:
                continue
            subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", source,
                            "-t", "120" if pending else "26", *options, "-movflags",
                            "+frag_keyframe+empty_moov+dash+global_sidx" if args.fragmented else "+faststart", str(destination)], check=True)
        token, calls = str(uuid.uuid4()), []
        page = "https://www.youtube.com/watch?v=abcdefghijk"
        def stream(path, is_video):
            return dict(url=path.as_uri(), formatID="137" if is_video else "140", container="mp4" if is_video else "m4a",
                        videoCodec="avc1" if is_video else None, audioCodec=None if is_video else "mp4a",
                        width=640 if is_video else None, height=360 if is_video else None,
                        isManifest=False, hasVideo=is_video, hasAudio=not is_video, headers={})
        descriptor = dict(pageURL=page, site="youtube", title="isolated cache fixture", durationSeconds=26,
                          isLive=False, video=stream(video, True), audio=stream(audio, False))
        if args.ready_db:
            assert not pending, "Existing ready fixture cannot be combined with streaming modes"
            import sqlite3
            with sqlite3.connect(pathlib.Path(args.ready_db).absolute().as_uri() + "?mode=ro", uri=True) as database:
                row = database.execute("SELECT payload FROM media_cache WHERE state='ready' ORDER BY last_used DESC LIMIT 1").fetchone()
            assert row, "No existing ready descriptor"
            descriptor = json.loads(row[0])
            page = descriptor["pageURL"]
        if args.request_page:
            page = args.request_page
        if args.descriptor_page:
            descriptor["pageURL"] = args.descriptor_page
        if args.downloading:
            descriptor["durationSeconds"] = 120
            descriptor["video"]["url"] = "/media/fixture-cache/video"
            descriptor["audio"]["url"] = "/media/fixture-cache/audio"
        live_resources = {}
        if args.live:
            playlist = directory / "live.m3u8"
            subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-i", str(video), "-i", str(audio),
                            "-c", "copy", "-f", "hls", "-hls_time", "2", "-hls_list_size", "0",
                            "-hls_flags", "omit_endlist", str(playlist)], check=True)
            capability = str(uuid.uuid4())
            def live_route():
                return "/media-live/" + capability + "/" + str(uuid.uuid4())
            lines = []
            for line in playlist.read_text().splitlines():
                if line and not line.startswith("#"):
                    route = live_route()
                    live_resources[route] = ((directory / line).read_bytes(), "video/mp2t")
                    line = route
                lines.append(line)
            manifest_route = live_route()
            live_resources[manifest_route] = (("\n".join(lines) + "\n").encode(), "application/vnd.apple.mpegurl")
            descriptor.update(isLive=True, durationSeconds=None, audio=None)
            descriptor["video"].update(url=manifest_route, isManifest=True, hasAudio=True, audioCodec="mp4a")
        media_reads = []
        sent_bytes = {"video": 0, "audio": 0}
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *unused):
                pass
            def do_GET(self):
                if args.live:
                    payload, mime = live_resources[self.path]
                    media_reads.append((self.path, 0, len(payload) - 1))
                    self.send_response(200)
                    self.send_header("Content-Type", mime)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    try:
                        self.wfile.write(payload)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                assert args.downloading
                if not args.rust:
                    assert self.headers.get("Authorization") == "Bearer " + token
                path = {"/media/fixture-cache/video": video, "/media/fixture-cache/audio": audio,
                        "/source/video": video, "/source/audio": audio}[self.path]
                total = path.stat().st_size
                start, end = 0, total - 1
                requested = self.headers.get("Range")
                if requested:
                    import re
                    match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested)
                    assert match, requested
                    start = int(match[1]); end = min(int(match[2]) if match[2] else end, end)
                media_reads.append((self.path, start, end))
                self.send_response(206 if requested else 200)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Type", "video/mp4" if path == video else "audio/mp4")
                self.send_header("Content-Length", str(end - start + 1))
                if requested:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
                self.end_headers()
                import time
                try:
                    with path.open("rb") as source:
                        source.seek(start)
                        for offset in range(start, end + 1, 16384):
                            payload = source.read(min(16384, end + 1 - offset))
                            self.wfile.write(payload)
                            self.wfile.flush()
                            sent_bytes["video" if path == video else "audio"] += len(payload)
                            time.sleep(args.source_delay if args.rust else .02)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def do_POST(self):
                assert self.path == "/rpc"
                assert self.headers.get("Authorization") == "Bearer " + token
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                method, params = body["method"], body["params"]
                calls.append((method, params))
                if method == "media_prepare":
                    assert params["pageURL"] == page and params["maxHeight"] == 2160 and params["pin"] is True
                    result = dict(cacheKey="fixture-cache", state="streaming" if args.live else "downloading" if args.downloading else "ready",
                                  **{"streamingDescriptor" if pending else "descriptor": descriptor})
                elif method == "media_status" and pending:
                    result = dict(cacheKey="fixture-cache", state="streaming" if args.live else "downloading", streamingDescriptor=descriptor)
                elif method == "media_release" or (method == "media_cancel" and pending):
                    result = dict(released=True)
                else:
                    raise AssertionError("unexpected RPC " + method)
                data = json.dumps(dict(id=body["id"], result=result)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        if args.rust:
            source_base = "http://127.0.0.1:" + str(server.server_port)
            info = dict(title="isolated real Rust consumer fixture", duration=3626 if args.real_assets_prefix else 120,
                        is_live=args.live, availability="public")
            common = dict(http_headers={}, height=1076 if args.real_assets_prefix else 360,
                          width=1920 if args.real_assets_prefix else 640, vcodec="avc1.64001e")
            if args.live:
                info["formats"] = [dict(common, url=source_base + manifest_route, protocol="m3u8_native",
                                         acodec="mp4a.40.2", format_id="hls")]
            else:
                info["requested_formats"] = [dict(common, url=source_base + "/source/video", protocol="http",
                                                   ext="mp4", acodec="none", format_id="137"),
                                              dict(url=source_base + "/source/audio", protocol="http", ext="m4a",
                                                   vcodec="none", acodec="mp4a.40.2", format_id="140", http_headers={})]
            info_path = directory / "yt-dlp-info.json"
            info_path.write_text(json.dumps(info))
            import os
            environment = dict(os.environ, GMGN_MEDIA_FIXTURE_INFO=str(info_path), GMGN_NATIVE_LINK_SILENT="1")
            result = subprocess.Popen(["cargo", "test", "--manifest-path", "services/gmgn-taskd/Cargo.toml",
                                     "native_consumer_streaming_http_fixture", "--", "--ignored", "--nocapture",
                                     "--test-threads=1"], env=environment, stdout=subprocess.PIPE, text=True, bufsize=1)
            first_frame_bytes = None
            for line in result.stdout:
                print(line.rstrip(), flush=True)
                if "CACHE_FIRST_FRAME " in line:
                    first_frame_bytes = dict(sent_bytes)
                    print("FIRST_FRAME_BYTES " + json.dumps({kind: dict(sent=first_frame_bytes[kind], total=path.stat().st_size,
                          fraction=first_frame_bytes[kind] / path.stat().st_size)
                          for kind, path in [("video", video), ("audio", audio)]}), flush=True)
            result.wait()
            server.shutdown()
            assert result.returncode == 0, "real Rust producer -> native consumer failed"
            assert media_reads, "Rust did not request source media"
            if args.real_assets_prefix:
                assert first_frame_bytes and all(first_frame_bytes[kind] < path.stat().st_size * .25
                    for kind, path in [("video", video), ("audio", audio)]), "First frame consumed too much of the real source"
            print("PASS real isolated Rust resolve/cache/HTTP producer -> silent native decoder consumer")
            return
        endpoint = directory / "taskd.endpoint.json"
        endpoint.write_text(json.dumps(dict(version=2, address="127.0.0.1:" + str(server.server_port), token=token)))
        import os
        environment = dict(os.environ, GMGN_MEDIA_CACHE_ENDPOINT=str(endpoint), GMGN_CACHE_FIRST_FRAME_TIMEOUT="3" if args.ready_db else "30",
                           GMGN_NATIVE_LINK_SILENT="1")
        if args.live:
            environment["GMGN_CACHE_LIVE_FIXTURE"] = "1"
        result = subprocess.run(["swift", "tools/probe-native-link-playback.swift", page, "20"], env=environment)
        server.shutdown()
        assert result.returncode == 0, "native cache probe failed"
        methods = [method for method, _ in calls]
        assert methods.count("media_prepare") == 1 and methods.count("media_release") == 1, methods
        assert calls[0][1]["consumerID"] == next(params["consumerID"] for method, params in calls if method == "media_release")
        if pending:
            assert methods.count("media_status") > 0 and media_reads, "No streaming reads/status tracking"
            assert methods.count("media_cancel") == 1, "Stop must cancel the unfinished cache owner"
            assert calls[0][1]["consumerID"] == next(params["consumerID"] for method, params in calls if method == "media_cancel")
            if args.live:
                assert len({path for path, _, _ in media_reads}) >= 2, "Manifest loaded without segments"
                print("PASS unterminated live HLS: decoded frames/GPU/time advance while streaming never reaches ready; manifest and segments read; owner cancellation/release")
            else:
                assert {path for path, _, _ in media_reads} == {"/media/fixture-cache/video", "/media/fixture-cache/audio"}
                print("PASS real decoded frames, GPU copies, PCM audio and time advance while cache remains downloading; authenticated split-stream reads, background status tracking, matching owner release")
        else:
            assert methods == ["media_prepare", "media_release"], methods
            print("PASS HTTP ready cache hit: one prepare, zero status polls, one matching-owner release; no repeated fetch")


if __name__ == "__main__":
    main()
