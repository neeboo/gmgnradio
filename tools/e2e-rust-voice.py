#!/usr/bin/env python3
"""Actual isolated App microphone/cloud/Rust/playback acceptance; no fixture server.

Requires inherited ElevenLabs credentials. Never copies or prints credentials.
Only the test App's own output engine may select the explicit speaker UID.
An empty physical microphone is BLOCKED, never counted as successful ASR.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--voice-id", required=True)
    parser.add_argument("--sampler", required=True, type=Path)
    parser.add_argument("--speaker-uid")
    parser.add_argument("--tts-only", action="store_true", help="Do not start recording or ASR; report the ASR gate as pending.")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("real_app", Path(__file__).with_name("e2e-real-app.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    root = args.root.resolve()
    module.assert_test_root_is_not_production(root)
    if root.exists():
        raise SystemExit("A fresh isolated test root is required; existing data is never overwritten.")
    environment = {
        "GMGN_VOICE_ASR_PROVIDER": "elevenlabs",
        "GMGN_VOICE_TTS_PROVIDER": "elevenlabs",
        "GMGN_VOICE_ELEVENLABS_VOICE_ID": args.voice_id,
    }
    if args.speaker_uid:
        environment["GMGN_E2E_VOICE_OUTPUT_DEVICE_UID"] = args.speaker_uid
    host = module.AppHost(args.app.resolve(), root, extra_env=environment)
    checks = []
    report = {"checks": checks, "status": "failed", "root": str(root)}

    def voice(action="status", **params):
        reply = host.command("voice_control", {"action": action, **params})
        if not reply.get("ok"):
            raise RuntimeError("App voice control rejected the request")
        return reply["result"]

    def wait(predicate, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            state = voice()
            if predicate(state):
                return state
            time.sleep(0.2)
        raise TimeoutError("Actual App voice state did not reach its acceptance condition")

    def sample(expect, name, seconds=4):
        result = subprocess.run([
            str(args.sampler.resolve()), "--pid", str(host.process.pid), "--seconds", str(seconds),
            "--expect", expect, "--output", str(root / "evidence" / name),
        ], capture_output=True)
        if result.returncode:
            raise RuntimeError("Scoped output audio did not satisfy " + expect)

    exit_code = 1
    try:
        host.launch()
        initial = voice()
        if not initial["ttsConfigured"] or (not args.tts_only and not initial["asrConfigured"]):
            report.update(status="blocked", reason="missing_voice_configuration")
            exit_code = 2
            return exit_code
        checks.append("actual_app_rust_core_configured")
        voice("speak", text="This is a real streaming audio test. The Rust core creates speech in small pieces, and the app plays each piece immediately.")
        sample("audible", "tts-audible.json", 8)
        drained = wait(lambda state: not state["isSpeaking"], 30)
        if drained["speechError"]:
            raise RuntimeError("Actual Rust TTS playback failed")
        checks.append("cloud_rust_device_audible_and_drained")
        voice("speak", text="This is the cancellation check. This is the cancellation check. This is the cancellation check.")
        time.sleep(1)
        voice("stop_speech")
        wait(lambda state: not state["isSpeaking"], 5)
        sample("silent", "tts-cancel-silent.json")
        checks.append("cancel_stops_own_process_output")
        if args.tts_only:
            report.update(status="partial", pending="asr_paused_by_user")
            exit_code = 2
            return exit_code
        voice("start")
        wait(lambda state: state["capturing"], 15)
        voice("speak", text="Hello. This is a microphone test. Please reply with the word hello. Hello. This is a microphone test.")
        wait(lambda state: not state["isSpeaking"], 30)
        voice("commit")
        final = wait(lambda state: state["lastFinalReceived"] or not state["requestActive"], 25)
        report["input"] = {key: final[key] for key in (
            "capturedPeak", "sentAudioBytes", "lastFinalReceived", "emptyFinalCount", "submittedFinalCount")}
        if not final["submittedFinalCount"]:
            report.update(status="blocked" if final["capturedPeak"] == 0 else "failed",
                          reason="physical_microphone_is_silent" if final["capturedPeak"] == 0 else "no_nonempty_final")
            exit_code = 2 if final["capturedPeak"] == 0 else 1
            return exit_code
        if "microphone test" not in final["lastFinal"].lower():
            raise RuntimeError("Final transcript does not contain the controlled spoken phrase")
        if final["submittedFinalCount"] != 1:
            raise RuntimeError("Final transcript was submitted more than once")
        checks.append("physical_microphone_cloud_rust_final_sent_once")
        # Agent reply is an independent required gate; a transcript alone is incomplete.
        deadline = time.monotonic() + 120
        reply_audio_sampled = False
        while time.monotonic() < deadline:
            if voice()["isSpeaking"] and not reply_audio_sampled:
                sample("audible", "agent-reply-audible.json", 6)
                reply_audio_sampled = True
            snapshot = host.command("status")["result"]
            turns = snapshot.get("chatTurns", [])
            if turns and any(turn.get("delivery") == "delivered" and turn.get("replyText", "").strip() for turn in turns):
                checks.append("actual_agent_reply_completed")
                break
            time.sleep(0.2)
        else:
            raise TimeoutError("Actual Agent reply did not complete")
        if not reply_audio_sampled:
            wait(lambda state: state["isSpeaking"], 15)
            sample("audible", "agent-reply-audible.json", 6)
        drained = wait(lambda state: not state["isSpeaking"], 30)
        if drained["speechError"]:
            raise RuntimeError("Actual Agent reply audio failed")
        checks.append("actual_agent_reply_rust_tts_audible_and_drained")
        report["status"] = "passed"
        exit_code = 0
    except Exception as error:
        report.update(status="failed", errorClass=type(error).__name__)
    finally:
        if host.process is not None:
            host.quit()
        root.mkdir(parents=True, exist_ok=True)
        (root / "voice-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
