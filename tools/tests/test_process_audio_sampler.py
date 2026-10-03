#!/usr/bin/env python3
"""End-to-end gates for the acceptance-only, PID-scoped system-output audio sampler.

Covers the 2026-10-03 rework item "solve the Core Audio process-tap hang, bound the
setup, only capture the specified PID (not the whole system), and prove real HLS
output with a play/stop contrast instead of accepting file PCM or a declared track".

The tests actually build `tools/probe-scoped-process-audio.swift` and run it against
real `afplay` processes on the host, so they exercise the same Core Audio path the
main agent uses against the isolated `ai.gmgn.radio.e2e` app:

  * `--self-check` advertises the scoping safety flags;
  * `--self-test` captures a 440 Hz tone by PID and silence by PID;
  * `--ab` confirms a real on/off contrast and rejects a no-change run;
  * the test-host mailbox driver sends real `play_screen` / `stop_screen` calls and
    the sampler binds only to the target PID.

No network, no production data, no installed app, no TCC prompt: the target is a
locally spawned `afplay` and the mailbox responder is a local fake.
"""
from __future__ import annotations

import json
import math
import os
import signal
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import wave
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BUILD_SCRIPT = REPO_ROOT / "tools/build-scoped-audio-sampler.sh"


def build_sampler(build_dir: Path) -> Path:
    """Compile the sampler once into an isolated temp build dir and return the binary."""
    env = dict(os.environ)
    env["GMGN_SCOPED_AUDIO_BUILD_DIR"] = str(build_dir)
    result = subprocess.run(
        ["bash", str(BUILD_SCRIPT), "--no-app", "--print-path"],
        capture_output=True, text=True, timeout=600, cwd=REPO_ROOT, env=env, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"sampler build failed:\n{result.stdout}\n{result.stderr}")
    binary = Path(result.stdout.strip().splitlines()[-1])
    if not binary.is_file():
        raise RuntimeError(f"sampler binary not produced: {binary}")
    return binary


def write_tone(path: Path, seconds: float, frequency: float, amplitude: float) -> None:
    sample_rate = 48000
    frame_count = int(sample_rate * seconds)
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        frames = bytearray()
        for index in range(frame_count):
            value = int(max(-1.0, min(1.0, amplitude * math.sin(
                2.0 * math.pi * frequency * index / sample_rate))) * 32767.0)
            frames += struct.pack("<h", value)
        handle.writeframes(bytes(frames))


class FakeE2EHost:
    """Minimal responder for the isolated test app's `control/inbox` file mailbox."""

    def __init__(self, root: Path, on_play, on_stop) -> None:
        self.inbox = root / "control" / "inbox"
        self.outbox = root / "control" / "outbox"
        self.inbox.mkdir(parents=True, exist_ok=True)
        self.outbox.mkdir(parents=True, exist_ok=True)
        self.on_play = on_play
        self.on_stop = on_stop
        self.commands: list[str] = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def start(self) -> "FakeE2EHost":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=5)

    def _loop(self) -> None:
        while not self._stop.is_set():
            for request_path in sorted(self.inbox.glob("*.json")):
                try:
                    request = json.loads(request_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    continue
                request_path.unlink(missing_ok=True)
                name = (request.get("params") or {}).get("name") or ""
                self.commands.append(name)
                if name == "play_screen":
                    self.on_play()
                elif name == "stop_screen":
                    self.on_stop()
                response = {"id": request.get("id"), "ok": True, "result": {"ok": True}}
                tmp = self.outbox / f"{request.get('id')}.json.tmp"
                tmp.write_text(json.dumps(response), encoding="utf-8")
                tmp.rename(self.outbox / f"{request.get('id')}.json")
            time.sleep(0.05)


class ScopedAudioSamplerTests(unittest.TestCase):
    binary: Path
    temporary: tempfile.TemporaryDirectory
    tone_path: Path
    silence_path: Path

    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(prefix="gmgn-scoped-audio-tests-")
        root = Path(cls.temporary.name)
        cls.binary = build_sampler(root / "build")
        cls.tone_path = root / "tone.wav"
        cls.silence_path = root / "silence.wav"
        write_tone(cls.tone_path, seconds=60.0, frequency=440.0, amplitude=0.4)
        write_tone(cls.silence_path, seconds=60.0, frequency=440.0, amplitude=0.0)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    # -- helpers -------------------------------------------------------------

    def run_sampler(self, arguments: list[str], timeout: float = 90.0):
        return subprocess.run(
            [str(self.binary), *arguments],
            capture_output=True, text=True, timeout=timeout, cwd=REPO_ROOT, check=False,
        )

    def parse_single_json(self, completed: subprocess.CompletedProcess) -> dict:
        lines = [line for line in completed.stdout.splitlines() if line.strip().startswith("{")]
        self.assertTrue(lines, f"no JSON on stdout:\n{completed.stdout}\n{completed.stderr}")
        return json.loads(lines[-1])

    def spawn_player(self, path: Path) -> subprocess.Popen:
        player = subprocess.Popen(
            ["/usr/bin/afplay", str(path)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        time.sleep(1.5)  # let it register a Core Audio process object
        return player

    @staticmethod
    def stop_player(player: subprocess.Popen) -> None:
        try:
            os.kill(player.pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
        player.terminate()
        try:
            player.wait(timeout=5)
        except subprocess.TimeoutExpired:
            player.kill()

    # -- tests ---------------------------------------------------------------

    def test_self_check_advertises_scoping_safety(self) -> None:
        completed = self.run_sampler(["--self-check"])
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = self.parse_single_json(completed)
        self.assertTrue(report["globalTapRefused"])
        self.assertTrue(report["coreAudioProcessTapAvailable"])
        self.assertEqual(report["defaultTargetBundleID"], "ai.gmgn.radio.e2e")

    def test_self_test_captures_tone_and_silence_by_pid(self) -> None:
        completed = self.run_sampler(["--self-test"], timeout=180.0)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("SELF-TEST PASS", completed.stdout)
        self.assertIn("只绑定目标 PID", completed.stdout)
        self.assertIn("没有创建全系统 tap", completed.stdout)

    def test_ab_confirms_real_on_off_contrast(self) -> None:
        player = self.spawn_player(self.tone_path)
        try:
            completed = self.run_sampler([
                "--pid", str(player.pid), "--ab", "--target-wait", "3",
                "--off-cmd", f"kill -STOP {player.pid}",
                "--on-cmd", f"kill -CONT {player.pid}",
                "--ab-baseline-seconds", "2", "--seconds", "3", "--ab-quiet-seconds", "2",
            ], timeout=120.0)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            report = self.parse_single_json(completed)
            self.assertEqual(report["verdict"], "HLS_OUTPUT_CONFIRMED")
            self.assertEqual(report["targetPid"], player.pid)
            self.assertFalse(report["globalTap"])
            self.assertEqual(report["scopedProcesses"], [player.pid])
            playing = report["ab"]["playing"]
            self.assertGreater(playing["rms"], 0.05)
            self.assertEqual(report["ab"]["baseline"]["rms"], 0.0)
            self.assertEqual(report["ab"]["quiet"]["rms"], 0.0)
            self.assertGreater(report["ab"]["contrast"], 4.0)
        finally:
            self.stop_player(player)

    def test_ab_rejects_playback_that_never_changes(self) -> None:
        player = self.spawn_player(self.tone_path)
        try:
            completed = self.run_sampler([
                "--pid", str(player.pid), "--ab", "--target-wait", "3",
                "--off-cmd", "true", "--on-cmd", "true",
                "--ab-baseline-seconds", "2", "--seconds", "3", "--ab-quiet-seconds", "2",
            ], timeout=120.0)
            self.assertEqual(completed.returncode, 4, completed.stderr)
            report = self.parse_single_json(completed)
            self.assertEqual(report["verdict"], "HLS_OUTPUT_NOT_CONFIRMED")
            self.assertGreater(report["ab"]["baseline"]["rms"], 0.05)
            self.assertLess(report["ab"]["contrast"], 1.5)
        finally:
            self.stop_player(player)

    def test_host_mailbox_drives_play_and_stop(self) -> None:
        player = self.spawn_player(self.tone_path)
        host_root = Path(self.temporary.name) / "fake-host-root"
        # Start suspended so the sampler's baseline is quiet; the fake host then
        # resolves play_screen -> SIGCONT and stop_screen -> SIGSTOP.
        os.kill(player.pid, signal.SIGSTOP)
        host = FakeE2EHost(
            host_root,
            on_play=lambda: os.kill(player.pid, signal.SIGCONT),
            on_stop=lambda: os.kill(player.pid, signal.SIGSTOP),
        ).start()
        try:
            completed = self.run_sampler([
                "--pid", str(player.pid), "--ab", "--target-wait", "3",
                "--host-root", str(host_root),
                "--object-id", "wish-prop-fake",
                "--hls-url", "https://example.invalid/page",
                "--ab-baseline-seconds", "2", "--seconds", "3", "--ab-quiet-seconds", "2",
            ], timeout=120.0)
            self.assertIn("play_screen", host.commands)
            self.assertIn("stop_screen", host.commands)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            report = self.parse_single_json(completed)
            self.assertEqual(report["driver"], "e2e-host-mailbox")
            self.assertEqual(report["verdict"], "HLS_OUTPUT_CONFIRMED")
            self.assertEqual(report["scopedProcesses"], [player.pid])
            self.assertFalse(report["globalTap"])
        finally:
            host.stop()
            self.stop_player(player)

    def test_missing_target_reports_no_signal_not_a_hang(self) -> None:
        player = subprocess.Popen(
            ["/bin/sleep", "30"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            completed = self.run_sampler([
                "--pid", str(player.pid), "--seconds", "2", "--target-wait", "2",
                "--expect", "audible",
            ], timeout=30.0)
            self.assertEqual(completed.returncode, 4, completed.stderr)
            report = self.parse_single_json(completed)
            self.assertFalse(report["targetPresent"])
            self.assertEqual(report["tapBuffers"], 0)
            self.assertEqual(report["verdict"], "NO_SIGNAL")
        finally:
            player.terminate()
            player.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
