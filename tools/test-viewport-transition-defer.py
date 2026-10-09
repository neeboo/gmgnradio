#!/usr/bin/env python3
"""Gate: a fullscreen transition must not carry a whole-content GPU rebuild.

2026-10-09, build 229, 4096x2304 (8.1x the windowed pixels). The reported
transition is one synchronous main-thread stall, and the only view in the
player that rebuilds on the moved framebuffer is the GPU lyrics layer:

    [LiveCamPointer] fullscreen clicked transitioning=False compact=False fullscreen=False
    Metal RecreateSurface[0x108151260]: surface size 4096x2304
    ...
    GPU lyric font atlas: 1024x1024 pages=15; uploads=1; uploadMs=5.253
    GPU monet_poster lyrics: 57 glyphs; ... rebuilds=1; atlasUploads=1;
        rebuildMs=422.807; warmFontsMs=411.747; glyphLayoutMs=4.724;
        bufferUploadMs=0.058; atlasBindMs=6.162
    GPU lyric glow targets: 1024x576 ARGBHalf; allocations=1; allocationMs=0.446

On the same resize once the warm is already done the whole rebuild is
`rebuildMs=0.698; warmFontsMs=0.016` -- so 411.7 of the 422.8 ms is the
one-time font warm, and the cheap relayout is not worth deferring. The GPUI
overlay is an NSView mounted inside the same process
(`GPUIChat2Probe.gmgn_gpui_probe_mount` into the Unity window's content view),
so that stall is also what stops overlay frames.

The gate pins both halves:
  * compiled: `ViewportTransition.cs` -- a pure value type the Unity-bundled
    Roslyn compiler builds and this script drives against the measured
    timeline (request, Metal RecreateSurface at +1 ms, didEnterFullScreen at
    +795 ms). Its window has to cover that animation and still be bounded, and
    the one-time warm has to land outside it;
  * structure: the window is opened on the only path that moves the framebuffer
    (`NativeUIScale.ToggleFullscreen`), driven from a component that runs every
    frame, and read by `GpuLyricsView` before it starts a whole-content rebuild
    and before it grows the glow render targets.

The negative control is the pre-fix revision itself: every structural check is
run against `git show HEAD:<path>` and has to be red there, and the harness runs
a literal transcription of HEAD's unconditional rebuild on the same timeline,
which has to put the warm inside the transition. Both sides are asserted, so
the gate cannot pass by being vacuous. The gate also re-hashes every source it
read and fails if any byte moved.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TRANSITION = "apps/unity-player/Assets/GMGN/ViewportTransition.cs"
SCALE = "apps/unity-player/Assets/GMGN/NativeUIScale.cs"
LYRICS = "apps/unity-player/Assets/GMGN/Lyrics/GpuLyricsView.cs"
COMPACT = "apps/unity-player/Assets/GMGN/UnityCompactWindowController.cs"
HARNESS = "tools/fixtures/viewport-transition-defer/Harness.cs"

#: the reported machine never animated the window longer than this; the window
#: is allowed margin above it but must stay bounded.
MEASURED_ANIMATION_MS = 795.0

#: absolute ceiling on the window, so inflating the constant cannot keep every
#: relative assertion true while the deferral grows into a visible freeze.
MAXIMUM_WINDOW_MS = 3000.0


def read(path):
    """The file's text, or "" when it is missing: a deleted owner is red, not a crash."""
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        return ""


def head_revision(path):
    """The file as HEAD has it, or "" when HEAD does not have it at all."""
    result = subprocess.run(["git", "show", "HEAD:" + path], cwd=ROOT,
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
# path -> text so the same checks run against the working tree and against HEAD.
def check_window_opens_before_the_move(source):
    body = function_body(source[SCALE], "public static void ToggleFullscreen()")
    if "BeginViewportTransition()" not in body:
        return "NativeUIScale.ToggleFullscreen must open the transition window"
    moves = [index for index in range(len(body)) if body.startswith("Screen.SetResolution(", index)]
    opens = [index for index in range(len(body)) if body.startswith("BeginViewportTransition()", index)]
    if not moves:
        return "NativeUIScale.ToggleFullscreen no longer moves the framebuffer, so nothing is pinned"
    if len(opens) < len(moves):
        return "every Screen.SetResolution branch must open the window first"
    if any(not any(open_at < move for open_at in opens) for move in moves):
        return "a Screen.SetResolution runs before the window opens"
    return None


def check_window_is_driven_every_frame(source):
    body = function_body(source[SCALE], "void Update()")
    if "viewport.Observe(Screen.width, Screen.height" not in body:
        return "NativeUIScale.Update must observe the framebuffer, not only the lyrics layer"
    return None


def check_window_is_bounded(source):
    text = source[TRANSITION]
    if not text:
        return "%s does not exist, so nothing bounds the transition" % TRANSITION
    body = function_body(text, "public bool Observe(")
    if "MinimumSeconds" not in body or "MaximumSeconds" not in body:
        return "ViewportTransition.Observe must floor and bound the window"
    if "public const double MaximumSeconds" not in text or "public const double MinimumSeconds" not in text:
        return "ViewportTransition must declare both bounds as constants"
    return None


def check_whole_rebuild_is_gated(source):
    body = function_body(source[LYRICS], "void LateUpdate()")
    gate = body.find("if (!ViewportTransition.DeferFullRebuild(")
    if gate < 0:
        return "GpuLyricsView.LateUpdate must rebuild only under the negated gate"
    if body.count("Rebuild();") != 1:
        return "LateUpdate must have exactly one rebuild, under that gate"
    if body.find("Rebuild();", gate) < 0:
        return "the rebuild must happen inside the gate, not beside it"
    return None


def check_the_gate_is_about_the_warm(source):
    text = source[LYRICS]
    if "warmedSession != session || warmedRevision != revision" not in text:
        return "GpuLyricsView must expose the pending-warm condition the deferral keys on"
    return None


def check_glow_does_not_grow_while_moving(source):
    body = function_body(source[LYRICS], "bool RenderGlow()")
    if "&&!(glowA!=null&&NativeUIScale.FramebufferMoving)" not in body:
        return "RenderGlow must grow the glow targets only when the framebuffer is still"
    return None


def check_fullscreen_path_opens_window(source):
    body = function_body(source[COMPACT], "IEnumerator ChangeFullscreen()")
    if "NativeUIScale.BeginViewportTransition()" not in body:
        return "the fullscreen coroutine must open the window before its native moves"
    return None


CHECKS = [
    ("window opens before the framebuffer moves", check_window_opens_before_the_move),
    ("window is driven every frame", check_window_is_driven_every_frame),
    ("window is floored and bounded", check_window_is_bounded),
    ("whole-content rebuild is gated", check_whole_rebuild_is_gated),
    ("the gate keys on the pending warm", check_the_gate_is_about_the_warm),
    ("glow targets do not grow mid-move", check_glow_does_not_grow_while_moving),
    ("the fullscreen coroutine opens the window", check_fullscreen_path_opens_window),
]

COMPILED = [
    # key, required value, what it pins
    ("window.closedBeforeBegin", "false", "the window starts closed"),
    ("window.opensOnBegin", "true", "Begin opens the window"),
    ("window.nanClockClosed", "true", "a bad clock cannot hold the window open forever"),
    ("window.coversAnimation", "true", "the window is open at didEnterFullScreen (+795 ms)"),
    ("window.changingFramebufferBounded", "true", "a framebuffer that never settles is still bounded"),
    ("shipped.warm.insideTransition", "false", "the one-time warm never runs inside the transition"),
    ("prefix.warm.insideTransition", "true", "negative control: HEAD's rule does run it inside"),
    ("shipped.defersCheapRebuild", "false", "the 0.698 ms relayout is never deferred"),
    ("shipped.defersWarmOutsideTransition", "false", "the warm runs as soon as the framebuffer settles"),
]


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


def run_harness():
    """Compile the shipped pure type with the Unity-bundled compiler and run it."""
    scripting = find_scripting_dir()
    if scripting is None:
        return None, "no Unity Scripting directory (set UNITY_SCRIPTING_DIR)"
    dotnet = os.path.join(scripting, "DotNetSdk/dotnet")
    sdk_root = os.path.join(scripting, "DotNetSdk/sdk")
    if not os.path.isdir(sdk_root):
        return None, "no DotNetSdk/sdk under the Unity Scripting directory"
    version = sorted(os.listdir(sdk_root), reverse=True)[0]
    csc = os.path.join(sdk_root, version, "Roslyn/bincore/csc.dll")
    if not os.path.isfile(csc):
        return None, "no csc.dll under %s" % sdk_root
    refs = []
    packs = os.path.join(scripting, "DotNetSdk/packs/Microsoft.NETCore.App.Ref")
    if not os.path.isdir(packs):
        return None, "no Microsoft.NETCore.App.Ref reference pack"
    ref_root = os.path.join(packs, sorted(os.listdir(packs), reverse=True)[0], "ref/net8.0")
    refs.extend(os.path.join(ref_root, name) for name in sorted(os.listdir(ref_root)) if name.endswith(".dll"))
    with tempfile.TemporaryDirectory(prefix="gmgn-viewport-transition.") as work:
        out = os.path.join(work, "Harness.dll")
        command = [dotnet, csc, "-nologo", "-nostdlib+", "-target:exe", "-langversion:latest",
                   "-out:" + out]
        command += ["-r:" + ref for ref in refs]
        command += [os.path.join(ROOT, TRANSITION), os.path.join(ROOT, HARNESS)]
        built = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if built.returncode != 0:
            return None, "harness compile failed:\n" + built.stdout.decode("utf-8", "replace")
        with open(os.path.join(work, "Harness.runtimeconfig.json"), "w", encoding="utf-8") as handle:
            json.dump({"runtimeOptions": {"tfm": "net8.0",
                                          "framework": {"name": "Microsoft.NETCore.App", "version": "8.0.0"}}},
                      handle)
        executed = subprocess.run([dotnet, out], cwd=work,
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


def hashes(paths):
    result = {}
    for path in paths:
        full = os.path.join(ROOT, path)
        if os.path.isfile(full):
            with open(full, "rb") as handle:
                result[path] = hashlib.sha256(handle.read()).hexdigest()
    return result


def main():
    paths = [TRANSITION, SCALE, LYRICS, COMPACT, HARNESS]
    before = hashes(paths)
    shipped = {path: read(path) for path in paths}
    prefix = {path: head_revision(path) for path in paths}

    failures = []
    for name, check in CHECKS:
        shipped_reason = check(shipped)
        prefix_reason = check(prefix)
        if shipped_reason is not None:
            failures.append("shipped: " + shipped_reason)
        if prefix_reason is None:
            failures.append("negative control: %s already holds at HEAD, so it pins nothing" % name)

    fields, error = run_harness()
    if fields is None:
        failures.append("compiled harness: " + str(error))
    else:
        for key, expected, what in COMPILED:
            if fields.get(key) != expected:
                failures.append("compiled: %s is %r, expected %r (%s)"
                                % (key, fields.get(key), expected, what))
        try:
            bound = float(fields["window.boundMs"])
            closed = float(fields["window.maxCloseMs"])
            floor = float(fields["window.minimumMs"])
        except (KeyError, ValueError):
            failures.append("compiled: the harness did not report both window bounds")
        else:
            if not 0 < closed <= bound:
                failures.append("compiled: the slowest close is %.1f ms against a %.1f ms bound"
                                % (closed, bound))
            if closed < MEASURED_ANIMATION_MS:
                failures.append("compiled: the window closes at %.1f ms, before the measured "
                                "%.0f ms animation" % (closed, MEASURED_ANIMATION_MS))
            # A floor above the bound would mean the early close never fires and
            # only the bound is doing the work; a floor below the animation would
            # let the window end inside it.
            if not MEASURED_ANIMATION_MS <= floor <= bound:
                failures.append("compiled: the floor is %.1f ms, which does not sit between the "
                                "measured %.0f ms animation and the %.1f ms bound"
                                % (floor, MEASURED_ANIMATION_MS, bound))
            # Absolute sanity: a transition window is sub-second work. Inflating
            # the constant keeps every relative assertion true, so pin the scale.
            if bound > MAXIMUM_WINDOW_MS:
                failures.append("compiled: the bound is %.1f ms, past the %.1f ms ceiling for a "
                                "transition window" % (bound, MAXIMUM_WINDOW_MS))

    if hashes(paths) != before:
        failures.append("the gate moved a source file; it must be read-only")

    if failures:
        sys.stderr.write("viewport transition defer gate: FAIL\n")
        for failure in failures:
            sys.stderr.write("  - %s\n" % failure)
        return 1
    print("viewport transition defer gate: PASS")
    print("  structural checks: %d, red on HEAD for all of them" % len(CHECKS))
    print("  compiled window: floor %s ms, bound %s ms, slowest close %s ms "
          "(measured animation %.0f ms)"
          % (fields["window.minimumMs"], fields["window.boundMs"], fields["window.maxCloseMs"],
             MEASURED_ANIMATION_MS))
    print("  one-time warm: HEAD %s ms inside the transition -> shipped %s ms outside it"
          % (fields["prefix.warm.atMs"], fields["shipped.warm.atMs"]))
    print("  cheap relayout (0.698 ms measured) deferred: %s"
          % fields["shipped.defersCheapRebuild"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
