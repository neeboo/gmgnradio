# GPUI Kit / SceneKit native overlay probe

This is an isolated macOS executable. It does not use the production App's data,
settings, helpers, microphone, or credentials. It is outside the parent Cargo
workspace. Dependencies: GPUI Kit **0.7.0**, GPUI snapshot **0.3.7** (lockfile),
Rust **1.95.0**, Apple AppKit / SceneKit / Metal.

```sh
bash tools/gpui-scenekit-probe/build-app.sh
"tools/gpui-scenekit-probe/target/GPUI SceneKit Probe.app/Contents/MacOS/GPUI SceneKit Probe" > /tmp/gpui-scenekit-probe-runtime.log 2>&1
```

Bundle ID: `ai.gmgn.gpui-scenekit-probe`. Cmd-Q must be verified before relying on
it; the launching terminal's Ctrl-C always stops only this probe process.
Closing the sole probe window uses Kit's window-close callback to release the
native SceneKit delegate / view, invalidate its timer, and quit the probe. The
status timer holds only a weak window reference. The build script uses the
lockfile and accepts an optional destination bundle path as its first argument,
so a final build can be made without replacing the bundle currently running.

The rotating SceneKit cube and floor are live native SCNView rendering. Its
NSView is a sibling below the actual transparent GPUI renderer in one NSWindow.
GPUI stays inside its original AccessKit content-view wrapper, without
reparenting or replacing `NSWindow.contentView`. The earlier custom-host experiment broke native keyboard
equivalents and accessibility; GPUI-only control confirmed the bridge as cause.
Both the native window and Base Root instance background must be transparent;
the component plugin's default Root background is otherwise opaque even when
`WindowBackgroundAppearance::Transparent` is selected.
The upper-left panel, text input, button, and modal are GPUI Kit components.

Drag / scroll in the **right-hand region (x > 420 logical pixels)** to orbit / zoom
SceneKit. The default probe-only Objective-C subclass routes hit testing in that
region to the native view. “Raw GPUI hit testing” disables routing, allowing a
direct control comparison. “Enable SceneKit hit routing” restores it. During a
GPUI modal the native region is blocked. This fixed boundary is intentionally
not a general production hit-region integration. The runtime subclass depends
on GPUI's native NSView implementation and requires maintenance or a supported
upstream adapter before production use. Window resizing and modal
closure need actual verification.

“Reset SceneKit camera” restores the original point of view after orbiting.
The dialog has an explicit Kit button “Close dialog” in its footer. The text
field has a separate visible character-count diagnostic; log files never
include its content. For a **GPUI-only diagnostic control**, launch the same
binary with `GMGN_PROBE_NATIVE=0`; this skips all native scene and NSView bridge
code and must never count as SceneKit overlay acceptance.

## Compact floating window

```sh
bash tools/gpui-scenekit-probe/build-app.sh "$PWD/tools/gpui-scenekit-probe/target/GPUI SceneKit Compact Probe.app" compact
GMGN_PROBE_COMPACT=1 "tools/gpui-scenekit-probe/target/GPUI SceneKit Compact Probe.app/Contents/MacOS/GPUI SceneKit Probe" > /tmp/gpui-scenekit-probe-compact-runtime.log 2>&1
```

Separate bundle ID: `ai.gmgn.gpui-scenekit-probe.compact`. The window is 224×336
logical pixels, floating, transparent, rounded to 28px, and not resizable.
GPUI Kit's built-in dark theme and small Input/Button components are used.
The upper 32px strip is draggable, y=32..192 is the live native SceneKit area
for orbit / zoom, and the lower 144px panel contains chat input, send counter,
camera reset, and a close button. Click the chat input to return keyboard focus
after manipulating SceneKit. This compact mode requires its own actual UI
acceptance; large-window success alone does not establish it.
The focus-parity revision creates GPUI's native nonactivating NSPanel through
the PopUp backend, then sets its native level to Floating (3). It neither
requests startup focus nor activates the app. A compact-only native panel
subclass reports `canBecomeMainWindow=NO`; chat-region clicks enable key status,
while native scene / title-region clicks disable it and resign key. GPUI /
AccessKit content-view hierarchy and Kit input remain intact. Actual focus
parity must be verified separately; these runtime subclasses remain probe
adapters rather than an approved production integration. Send increments a
local diagnostic counter; it does not submit a real taskd chat message.

Build focus validation into a separate bundle with the second script argument
`compact-focus` and destination `target/GPUI SceneKit Compact Focus Probe.app`.
Its bundle ID is `ai.gmgn.gpui-scenekit-probe.compact.focus`, and its launch
environment remains `GMGN_PROBE_COMPACT=1`. Periodic status logs expose
chatActive / key / main / canKey / canMain / appActive / nonactivating / level.

SceneKit pointer events and its independently running frame count are emitted
to stderr (`PROBE_SCENE_POINTER`). They supplement visual acceptance, never
replace screenshots or an actual animation observation. No texture readback,
screenshots, WebView, SwiftUI, or extra overlay window is used as a rendering
substitute. Production MTKView / SCNRenderer composition is not covered by this
SCNView proof alone.
