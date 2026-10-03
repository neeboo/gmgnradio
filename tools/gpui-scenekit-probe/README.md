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

## Actual production render-host integration

```sh
bash tools/gpui-scenekit-probe/build-app.sh "$PWD/tools/gpui-scenekit-probe/target/GPUI Production RenderHost Probe.app" production
```

Bundle ID: `ai.gmgn.gpui-scenekit-probe.production`. This bundle requires the
three explicit settings `GMGN_RENDER_HOST_LIBRARY` (absolute Swift dylib path),
`GMGN_RENDER_HOST_DATA_ROOT` (absolute isolated data directory), and
`GMGN_RENDER_HOST_DEFAULTS_SUITE` (prefix `ai.gmgn.gpui-probe.`). Required-mode
metadata is checked in native preflight **before** GPUI startup; a missing
setting, invalid isolated path / suite, `GMGN_PROBE_NATIVE=0`, missing ABI,
load / create / attach failure exits 78. There is no SceneKit cube fallback.

Use the separate packaging script `tools/package-gpui-render-host.sh` to stage
the actual host library, required frameworks, original Metal library and asset
bundles. The parent owns packaging and actual app acceptance. The render host
ABI is documented in `apps/macos/RenderHost/RenderHost.h` and is loaded using
`dlopen` / `dlsym`, without a link-time production dependency in the probe.

The actual host is attached to a native sibling container below GPUI, keeping
the AccessKit wrapper and GPUI view intact. Full-stage events are forwarded to
the actual production view, without substitute controls. Compact dragging and
scrolling call the host's explicit **orbit** ABI; scrolling is not a zoom
acceptance claim. The fixture-only camera-reset button is disabled in production
mode. A small-window avatar is not guaranteed: the host uses an isolated empty
avatar store. No rendered character or animation acceptance follows from attach.

`PROBE_RENDER_HOST_DIAGNOSTICS` logs a whitelist of attachment / drawable data,
owner / surface class, and numeric scheduling / performance telemetry. No
credentials or arbitrary provider strings are included. Closing invalidates the
probe timer, invokes host visibility-off / destroy, and detaches the container.
The loader reference is intentionally kept until process exit: Swift Tasks may
still unwind after destroy, so **no `dlclose` is performed while the process is
running**. Actual visuals, pointer behavior, Kit input and close lifecycle still
require the parent's computer-use validation.

Production lifecycle synchronization observes minimize, restore and native
occlusion-state changes, plus rechecks window visibility in the telemetry timer.
It mirrors the existing production policy: hidden or minimized suspends the
render loop; merely overlapping with another ordinary window does not. The
diagnostic Kit panel includes native minimize and “hide for four seconds then
restore” actions. `PROBE_RENDER_HOST_VISIBILITY` records each actual state change,
and numeric host diagnostics expose `loopActive`. Close removes all observers
and cancels the hidden-window restore timer before destroying the host. These
actions are window-lifecycle probes, not production world manipulation; full
StageWorldInteraction binding remains outside this prototype.

## First reusable chat UI slice

The probe consumes the `gmgn-gpui-ui` path dependency at `apps/gpui-ui` and mounts
its actual `ResidentChatPane`, with `.compact(true)` in the 144px compact chat
region. Production mode enables this pane automatically; the fixture diagnostic
can enable it explicitly with `GMGN_PROBE_CHAT_UI=1`. All production preflight
guards, real rendering, native focus rules and AccessKit hierarchy remain intact.

A foreground `spawn_in` task uses a weak entity and drains `take_commands` every
100ms, outside rendering. There is deliberately no chat transport in this
validation host: it shows “对话服务尚未接入此验证窗口”, and a Send command calls the
component's `failed` API with that actual not-connected condition. It never
calls `accepted`, invents a resident response, or clears the draft on send.
Only request ID / character count are logged, never message text. The owned
poller is cancelled when its view drops and stops if the window/entity disappears.

The component's `reset_context` invalidates old pending callbacks and retains
the current draft; it is not a general input-clear API and is not invoked in
this transport-free probe. Actual Enter / send failure / preserved draft UI
acceptance remains separate from business chat end-to-end acceptance.

Build to `target/GPUI Chat Migration Probe.app` with the `production` packaging
option. Its bundle ID remains `ai.gmgn.gpui-scenekit-probe.production`; bind the
explicit new artifact path for testing rather than confusing it with older
production probe processes.

SceneKit pointer events and its independently running frame count are emitted
to stderr (`PROBE_SCENE_POINTER`). They supplement visual acceptance, never
replace screenshots or an actual animation observation. No texture readback,
screenshots, WebView, SwiftUI, or extra overlay window is used as a rendering
substitute. Production MTKView / SCNRenderer composition is not covered by this
SCNView proof alone.
