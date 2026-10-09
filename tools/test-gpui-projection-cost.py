#!/usr/bin/env python3
"""Gate: one GPUI poll must parse the host envelope once and write the payload once.

2026-10-09 regression (build 228). `sample` on the live player, with the Unity JIT
addresses resolved through `mono_pmip`, put 71 % of the main thread in
`PlayerScreen.Update` -> `NativePlayerBackend.Tick` (20 Hz) -> `PublishGPUIProjection`
-> `GPUIChat2Probe.ApplySnapshot`, all of it Newtonsoft Json.NET tree work, none of it
rendering:

    Tick                 gmgn_unity_host_snapshot            12.8 %   (host builds the JSON)
    Tick                 JObject.Parse(json)                 13.1 %   parse 1
    PublishGPUIProjection (JObject)original.DeepClone()       9.3 %   whole-tree clone
    PublishGPUIProjection projection.ToString(None)           4.1 %   write 1
    ApplySnapshot        JObject.Parse(serialized)           11.8 %   parse 2 (of our own output)
    ApplySnapshot        projection.ToString(None)            4.1 %   write 2 (through UTF-16)
    gmgn_gpui_chat_snapshot (native)                         12.2 %   overlay parses it again

and the cost scales with the envelope: windowed idle (points=0) measured cpuMs≈39.5,
windowed with the stage active (points=22536, music+lyrics+queue in the envelope)
measured cpuMs≈80–92 — which is the reported "启动后切全屏会卡" frame.

This gate pins both halves of the fix:
  * structure: exactly one `JObject.Parse` in `GPUIProjectionPayload.Parse`, no
    whole-envelope clone, no string round trip between the backend and the probe, no
    UTF-16 write at the boundary;
  * cost: the shipped path is compiled and run against a literal transcription of the
    pre-fix path on one envelope, must produce byte-identical payloads (including no
    UTF-8 BOM) and must stay under a share of the pre-fix time.

The negative control is the pre-fix revision itself: the same structural checks are run
against the pre-fix source and every one of them has to be red there, and the pre-fix
shape has to blow the cost budget. Both sides are asserted, so the gate cannot pass by
being vacuous.

**Which revision is "pre-fix"?** Not simply `HEAD`. The fix shipped in `e474e0a`
(build 229), so at that commit -- and at every later one, `HEAD` included -- the working
source *is* the fixed shape, and reading `HEAD:<path>` made all six structural controls
"already hold", i.e. pin nothing. That is the build-230 failure this script used to
report. `pre_fix_revision()` therefore walks back from `HEAD` to the most recent ancestor
at which the structural controls are still red; that ancestor is both the structural
control (`prefix`) and the cost baseline. The method is the one the sibling gate
`test-viewport-transition-defer.py` already uses ("red on HEAD for all of them"), and the
assertions themselves are unchanged.

Set GMGN_GPUI_ENVELOPE=<path> to measure a real captured host envelope instead of the
synthetic one; the default is deterministic and carries no user data.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: shipped path must be at most this share of the pre-fix path's median poll.
COST_SHARE = 0.60

PAYLOAD = "apps/unity-player/Assets/GMGN/GPUIProjectionPayload.cs"
BACKEND = "apps/unity-player/Assets/GMGN/NativePlayerBackend.cs"
PROBE = "apps/unity-player/Assets/GMGN/GPUIChat2Probe.cs"


def read(path):
    """The file's text, or "" when it is missing: a deleted payload owner is a red gate, not a crash."""
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        return ""


def revision(path, reference):
    """The file as `reference` has it, or "" when that revision does not have it.

    A revision that predates `GPUIProjectionPayload.cs` returns "" for it, which is a
    red gate rather than a crash -- exactly the meaning `read()` gives a deleted file.
    """
    result = subprocess.run(["git", "show", "%s:%s" % (reference, path)], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return result.stdout.decode("utf-8") if result.returncode == 0 else ""


def function_body(source, signature):
    start = source.find(signature)
    if start < 0:
        return ""
    depth = 0
    opened = False
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
            opened = True
        elif source[index] == "}":
            depth -= 1
            if opened and depth == 0:
                return source[start:index + 1]
    return source[start:]


# Each check returns a failure reason, or None when it holds. `source` is a dict of
# path -> text so the same checks can run against the working tree and against HEAD.
def check_one_parse(source):
    if not source[PAYLOAD]:
        return "%s does not exist, so the poll has no single owner for its parse" % PAYLOAD
    body = function_body(source[PAYLOAD], "public static JObject Parse(")
    if body.count("JObject.Parse(") != 1:
        return "GPUIProjectionPayload.Parse must parse the envelope exactly once"
    return None


def check_one_write(source):
    if not source[PAYLOAD]:
        return "%s does not exist, so the boundary write is not pinned" % PAYLOAD
    body = function_body(source[PAYLOAD], "public static byte[] Encode(")
    if "GetBytes(" in body:
        return "Encode must write UTF-8 bytes directly, not through a UTF-16 string"
    if "ToString(Formatting.None)" in body:
        return "Encode must not materialize the whole payload as a string"
    return None


def check_augment_in_place(source):
    if not source[PAYLOAD]:
        return "%s does not exist, so the adjunct pass is not pinned" % PAYLOAD
    body = function_body(source[PAYLOAD], "public static void Augment(")
    if "DeepClone" in body:
        return "Augment must not clone the whole projection; the tick owns that tree"
    return None


def check_backend_parses_once(source):
    if "GPUIProjectionPayload.Parse(json)" not in source[BACKEND]:
        return "Tick must parse the envelope through GPUIProjectionPayload.Parse"
    if re.search(r"JObject\.Parse\(json\)\s*\[", source[BACKEND]):
        return "Tick must not re-parse the envelope JSON for later subtrees"
    return None


def check_backend_hands_the_tree(source):
    body = function_body(source[BACKEND], "void PublishGPUIProjection(")
    if "DeepClone()" in body and "original.DeepClone()" in body:
        return "PublishGPUIProjection must not deep-clone the whole envelope"
    if "GPUIHostProjection.Invoke(projection)" not in body:
        return "PublishGPUIProjection must hand the parsed tree to the probe"
    if "ToString(" in body:
        return "PublishGPUIProjection must not serialize the projection to a string"
    return None


def check_probe_never_reparses(source):
    if "void ApplySnapshot(JObject projection)" not in source[PROBE]:
        return "ApplySnapshot must take the parsed projection"
    body = function_body(source[PROBE], "void ApplySnapshot(JObject projection)")
    if "JObject.Parse(" in body:
        return "ApplySnapshot must not re-parse our own serialized output"
    if "Encoding.UTF8.GetBytes(projection" in body:
        return "ApplySnapshot must not encode the payload through a UTF-16 string"
    if "GPUIProjectionPayload.Encode(projection)" not in body:
        return "ApplySnapshot must write the payload through GPUIProjectionPayload.Encode"
    if "projection.ToString(" in body:
        return "ApplySnapshot must not serialize the payload to a string"
    if "GPUIHostSnapshot" in source[PROBE] or "GPUIHostSnapshot" in source[BACKEND]:
        return "the string-typed GPUIHostSnapshot event must be gone"
    return None


CHECKS = [
    ("payload parses once", check_one_parse),
    ("payload writes once", check_one_write),
    ("adjuncts are in place", check_augment_in_place),
    ("Tick parses once", check_backend_parses_once),
    ("backend hands the tree over", check_backend_hands_the_tree),
    ("probe never re-parses", check_probe_never_reparses),
]

#: How far back `pre_fix_revision()` is willing to look before giving up.
PREFIX_SEARCH_DEPTH = 200


def structural_failures(source):
    """Every structural check that does not hold for `source` (path -> text)."""
    return [name for name, check in CHECKS if check(source) is not None]


def pre_fix_revision():
    """The most recent ancestor of HEAD at which all structural controls are red.

    Every control has to be red *there* or the gate pins nothing, so "pre-fix" is not a
    guess: it is the first revision walking back from HEAD whose source still has the old
    shape (no `GPUIProjectionPayload.Parse`, whole-envelope `DeepClone`, string round trip
    at the boundary). Returns the revision string, or None when the search runs out.
    """
    for step in range(1, PREFIX_SEARCH_DEPTH + 1):
        reference = "HEAD~%d" % step
        source = {path: revision(path, reference) for path in (PAYLOAD, BACKEND, PROBE)}
        if len(structural_failures(source)) == len(CHECKS):
            return reference
    return None


def synthetic_envelope(target_bytes=158472):
    """A deterministic envelope with the real host key set, sized like the captured one."""
    envelope = {
        "version": 228,
        "locale": "zh-CN",
        "chat": {"state": {"contextID": "ctx-1", "messages": []},
                 "events": [{"kind": "delta", "requestID": 7, "text": "x" * 400}]},
        "chatAttachments": {"attachments": [], "isPreparing": False, "error": None},
        "voice": {"state": "idle", "errorCode": None, "transcript": "", "transcriptRevision": 3},
        "replySpeech": {"isPlaying": False, "level": 0.0, "error": None},
        "music": {"playbackSessionID": 11, "title": "曲目", "position": 12.5, "duration": 200.0,
                  "isPlaying": True, "volume": 0.6, "queueIndex": 2, "queueCount": 9,
                  "lyricRevision": 4, "features": {"bass": 0.1, "vocal": 0.2, "treble": 0.3},
                  "lyricVisual": {"mode": "automatic", "revision": 4, "theme": {"name": "t"}},
                  "pointCloud": {"choice": "orbit", "intensity": 0.5, "particleSize": 0.02,
                                 "artworkURL": "https://example.invalid/a.png",
                                 "presetWeights": [0.1, 0.2, 0.3, 0.4], "rhythm": [0.1, 0.2, 0.3, 0.4],
                                 "waveA": [0.1, 0.2], "waveB": [0.3, 0.4]},
                  "lines": [{"startsAt": index, "endsAt": index + 1, "text": "行" * 40, "translation": ""}
                            for index in range(60)],
                  "queue": [{"index": index, "title": "曲目" + str(index)} for index in range(20)]},
        "settings": {"settings": {"presence": {"motions": ["m%d" % index for index in range(24)],
                                               "activeMotionID": "m1", "working": False, "notice": None,
                                               "hasError": False},
                                  "stage": {"worlds": ["w%d" % index for index in range(12)]},
                                  "characterPosition": {"revision": 5, "position": {"x": 0.0, "y": 1.0, "z": 0.0}},
                                  "spaceLibrary": {"spaces": ["s%d" % index for index in range(8)]},
                                  "generation": {"revision": 6}},
                     "supportedCommands": ["ui.window.fullscreen", "ui.window.compact", "presence.motion"]},
        "stage": {"mode": "automatic"},
        "screenVideo": {"screens": [{"objectID": "screen.%d" % index, "name": "屏幕", "state": "idle"}
                                    for index in range(4)],
                        "commandNotice": None},
        "musicLibrary": {"generation": 3, "playlists": [{"id": "p%d" % index, "tracks": 20} for index in range(6)]},
        "inbox": {"generation": 2, "events": [{"id": "e%d" % index} for index in range(10)]},
        "world": {"worldID": "space.living", "generation": 9, "status": "ready"},
        "worldSelection": {"worldID": "space.living", "revision": 1, "phase": "ready"},
        "worldPhysicsProbes": {},
        "selection": {"revision": 4, "objectID": "prop.1"},
        "activity": {"agentTransform": {"position": {"x": 0.0, "y": 0.0, "z": 0.0}},
                     "cameras": [{"id": "living.establishing", "fieldOfViewDegrees": 66.0}
                                 for _ in range(6)]},
        "spatialPresentation": {"revision": 2, "mode": "space"},
        "characterPosition": {"revision": 5, "position": {"x": 0.0, "y": 1.0, "z": 0.0}},
        "builtinDevices": {"templates": [{"id": "device.%d" % index, "name": "设备"} for index in range(12)]},
        "generatedAssets": {"generation": 1, "assets": []},
        "inventoryMutation": {"generation": 1},
        "wishOutputPreview": {"generation": 1, "worldID": "space.living"},
        "uiIntents": [],
        "visualSettingsCommand": None,
        "settingsCommandResult": None,
        "heldAvatarBindingNotice": None,
        "runtimeCapabilities": {"capabilities": ["space", "music", "props"]},
        "runtimeDiagnostics": {"phase": "ready"},
        # The bulk of a real envelope is world/grid geometry the overlay explicitly drops.
        "worldGrid": {"cells": [[index * 0.5, index * 0.25, -index * 0.125, 180, 0] for index in range(4000)]},
    }
    text = json.dumps(envelope, ensure_ascii=False, separators=(",", ":"))
    if len(text.encode("utf-8")) < target_bytes:
        envelope["worldGrid"]["padding"] = "p" * (target_bytes - len(text.encode("utf-8")))
        text = json.dumps(envelope, ensure_ascii=False, separators=(",", ":"))
    return text


def find_scripting_dir():
    override = os.environ.get("UNITY_SCRIPTING_DIR")
    candidates = [override] if override else []
    hub = "/Applications/Unity/Hub/Editor"
    if os.path.isdir(hub):
        for version in sorted(os.listdir(hub), reverse=True):
            candidates.append(os.path.join(hub, version, "Unity.app/Contents/Resources/Scripting"))
    for candidate in candidates:
        if candidate and os.path.isfile(os.path.join(candidate, "DotNetSdk/dotnet")):
            return candidate
    return None


def run_cost_harness(envelope_text, iterations):
    scripting = find_scripting_dir()
    if scripting is None:
        return None, "no Unity Scripting directory (set UNITY_SCRIPTING_DIR)"
    dotnet = os.path.join(scripting, "DotNetSdk/dotnet")
    csc = os.path.join(scripting, "DotNetSdk/sdk/8.0.318/Roslyn/bincore/csc.dll")
    refs = []
    packs = os.path.join(scripting, "DotNetSdk/packs/Microsoft.NETCore.App.Ref")
    versions = sorted(os.listdir(packs), reverse=True)
    ref_root = os.path.join(packs, versions[0], "ref/net8.0")
    refs.extend(os.path.join(ref_root, name) for name in sorted(os.listdir(ref_root)) if name.endswith(".dll"))
    newtonsoft = os.path.join(ROOT, "apps/unity-player/Library/PackageCache/"
                                    "com.unity.nuget.newtonsoft-json@4dfd81071c64/Runtime/Newtonsoft.Json.dll")
    if not os.path.isfile(newtonsoft):
        return None, "Newtonsoft.Json.dll not found under apps/unity-player/Library/PackageCache"
    refs.append(newtonsoft)
    with tempfile.TemporaryDirectory(prefix="gmgn-projection-cost.") as work:
        shutil.copyfile(newtonsoft, os.path.join(work, os.path.basename(newtonsoft)))
        harness = os.path.join(ROOT, "tools/fixtures/gpui-projection-cost/CostHarness.cs")
        out = os.path.join(work, "CostHarness.dll")
        command = [dotnet, csc, "-nologo", "-nostdlib+", "-target:exe", "-langversion:latest", "-unsafe+",
                   "-out:" + out, "-define:UNITY_STANDALONE_OSX,UNITY_STANDALONE,UNITY_6000_0_OR_NEWER"]
        command += ["-r:" + ref for ref in refs]
        command += [os.path.join(ROOT, PAYLOAD), harness]
        built = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if built.returncode != 0:
            return None, "harness compile failed:\n" + built.stdout.decode("utf-8", "replace")
        with open(os.path.join(work, "CostHarness.runtimeconfig.json"), "w", encoding="utf-8") as handle:
            json.dump({"runtimeOptions": {"tfm": "net8.0",
                                          "framework": {"name": "Microsoft.NETCore.App", "version": "8.0.0"}}}, handle)
        envelope_path = os.path.join(work, "envelope.json")
        with open(envelope_path, "w", encoding="utf-8") as handle:
            handle.write(envelope_text)
        executed = subprocess.run([dotnet, out, envelope_path, str(iterations)], cwd=work,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if executed.returncode != 0:
            return None, "harness failed (exit %d):\n%s" % (executed.returncode,
                                                            executed.stdout.decode("utf-8", "replace"))
        fields = {}
        for line in executed.stdout.decode("utf-8", "replace").splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                fields[key.strip()] = value.strip()
        return fields, None


def main():
    shipped = {path: read(path) for path in (PAYLOAD, BACKEND, PROBE)}

    failures = []
    reference = pre_fix_revision()
    if reference is None:
        failures.append("no ancestor of HEAD in the last %d revisions still has the "
                        "pre-fix shape, so the negative control has nothing to pin"
                        % PREFIX_SEARCH_DEPTH)
        prefix = {path: "" for path in (PAYLOAD, BACKEND, PROBE)}
    else:
        prefix = {path: revision(path, reference) for path in (PAYLOAD, BACKEND, PROBE)}

    for name, check in CHECKS:
        shipped_reason = check(shipped)
        prefix_reason = check(prefix)
        if shipped_reason is not None:
            failures.append("shipped: " + shipped_reason)
        if prefix_reason is None:
            failures.append("negative control: %s already holds at %s, so it pins nothing"
                            % (name, reference or "the searched ancestors"))

    envelope_text = None
    real = os.environ.get("GMGN_GPUI_ENVELOPE")
    if real:
        with open(real, encoding="utf-8") as handle:
            envelope_text = handle.read()
    fields, error = run_cost_harness(envelope_text if envelope_text is not None else synthetic_envelope(), 120)
    if fields is None:
        failures.append("cost harness: " + str(error))
    else:
        if fields.get("equal.full") != "true" or fields.get("equal.empty") != "true":
            failures.append("the payload is not byte-identical to the pre-fix payload")
        if fields.get("bom") != "true" and fields.get("bom") != "false":
            failures.append("cost harness did not report the BOM check")
        if fields.get("bom") == "true":
            failures.append("the payload starts with a UTF-8 BOM")
        ratio = float(fields["ratio"])
        if ratio > COST_SHARE:
            failures.append("shipped poll is %.1f%% of the pre-fix poll, budget is %.0f%%"
                            % (ratio * 100.0, COST_SHARE * 100.0))
        if ratio > 0.95:
            failures.append("negative control: the pre-fix shape does not exceed the budget, "
                            "so the cost half of the gate pins nothing")

    if failures:
        sys.stderr.write("gpui projection cost gate: FAIL\n")
        for failure in failures:
            sys.stderr.write("  - %s\n" % failure)
        return 1
    print("gpui projection cost gate: PASS")
    print("  structural checks: %d, red on %s (the located pre-fix revision) for all of them"
          % (len(CHECKS), reference))
    if real:
        print("  envelope: %s (%d bytes)" % (real, os.path.getsize(real)))
    else:
        print("  envelope: synthetic, %d bytes" % len(synthetic_envelope().encode("utf-8")))
    print("  payload:  %s bytes, byte-identical to the pre-fix payload, no BOM" % fields["payload.bytes"])
    print("  median poll: pre-fix %s ms -> shipped %s ms (%.1f%%), p95 %s -> %s ms"
          % (fields["prefix.medianMs"], fields["shipped.medianMs"], float(fields["ratio"]) * 100.0,
             fields["prefix.p95Ms"], fields["shipped.p95Ms"]))
    print("  allocated per poll: pre-fix %s B -> shipped %s B"
          % (fields["prefix.bytesPerPoll"], fields["shipped.bytesPerPoll"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
