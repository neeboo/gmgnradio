# GPUI production render-host probe

This isolated dynamic library compiles the actual production Swift sources and
uses `StageRenderSurfaceController` / `MarbleSpatialView` unchanged. It excludes
`GMGNRadioApp.swift` and never calls application bootstrap. The tiny compile
support types replace menu declarations otherwise located beside `@main`;
they are not an application-business bridge.

Build from the repository root:

```sh
bash tools/build-gpui-render-host.sh
```

Outputs are exclusively under `tmp/gpui-render-host`. Dependencies are locked
to the production `Package.resolved` and reused from existing package checkouts.
The script does not install or launch any App, upgrade packages, build Rust
daemons, access Keychain, or request microphone access.

## C ABI contract

See `RenderHost.h`. All handle/view operations require the AppKit main thread;
wrong-thread operations fail (`0` / null). The caller owns a valid handle and
must not use it after destroy. `create` returns one retained handle; call
`destroy` exactly once. `view` returns a borrowed `NSView *`, not a retained
object. The caller provides a live `NSView *` container in the same process.
`attach(..., 0)` selects Live Cam; nonzero selects full stage. Visibility must
be updated on window minimize/restore/close and owner switches. Rotation uses
the production Live Cam orbit implementation.

Diagnostics returns an owned UTF-8 JSON string; release it with
`gmgn_render_host_string_free` (no thread restriction on string free). The
timing telemetry is renderer/main-actor instrumentation, not physical display
or input-to-photon timing.

Create requires an explicit absolute isolated data directory and a unique
defaults suite prefixed `ai.gmgn.gpui-probe.`. Avatar/motion stores and Marble
cache are injected from that root. No shared avatar runtime is used. The
initial selected world is the production local Living Pod; this avoids catalog
prewarming and network world downloads. No resident chat state is constructed.

## Test-App packaging

Copy `GPUIRenderHost.dylib` from `DerivedData/Build/Products/Debug` into the
independent GPUI test App's `Contents/Frameworks` (never the installed App).
The renderer uses `device.makeDefaultLibrary()`, so copy the actual generated
`Debug/default.metallib` into that test App's `Contents/Resources`, together
with the staged `resources/Worlds` and `resources/MMDMotions`. Package resource
bundles from `Debug/*.bundle` must also be available at the bundle lookup
locations used by their generated SwiftPM accessors, and any linked dynamic
frameworks must retain their expected runpaths.

`tools/package-gpui-render-host.sh /absolute/path/to/probe.app` performs this
packaging, adds the dylib's `@loader_path` framework search path, and ad-hoc
signs the isolated copies. It refuses paths outside the repository's isolated
build roots and requires bundle ID `ai.gmgn.gpui-scenekit-probe.production`.
Generated SwiftPM accessors were inspected: their first normal candidate is
`Bundle.main.resourceURL/<package>.bundle`, hence `Contents/Resources`.

Build/symbol success alone does not establish rendered output, character,
music effects, video/audio, small-window behavior, or UI migration readiness.
The GPUI process must attach this real surface and undergo visual/interaction
validation before any production migration gate is declared passed.

## Optional real resident conversation

The five `gmgn_render_host_chat_*` functions expose the existing
`AgentConversationService.send` pipeline. `chat_configure` accepts only `dsh`,
connecting the existing DeepSeek Harness Agent over production native ACP.
The GPUI test host defaults to this connection; explicit offline mode is a
caller-side option. There is no Codex/Claude/custom API provider, key field,
environment key guard, or headless CLI fallback. `chat_send` and `chat_cancel`
take the caller's `uint64_t request_id`; event request IDs remain identical.
All calls require the main thread and returned JSON strings use the existing
string-free function. `chat_poll` drains bounded events and includes a complete
state snapshot; `chat_context` reads state without draining events.

Events are `accepted`, `reply`, `failure`, and `cancelled`. The service returns
a whole final response, so `deliveryMode` is `final-response`: there is no
token streaming or fabricated progress. Acceptance means a request entered
the adapter, not successful model delivery. Busy and empty requests return
zero with a failure event; a disconnected adapter returns zero without
launching anything. Late results from a cancelled generation are discarded.
The bounded transcript contains only completed actual user/reply pairs.
Cancellation and failure restore the submitted draft.

The lifecycle wrapper constructs the real `ResidentDSHConnector` using
`ResidentDSHComposition.makeResidentSandbox`, with the production composition,
model/provider selection, mounted-module verification and managed-credential
service unchanged. The bridge does not read, copy or specify any key or auth
file. It passes no connector environment overrides or stderr log destination;
the existing production allowlist excludes provider-key and boot-mode overrides.
The new sandbox is rooted under the caller's isolated `dataRoot/chat` via
the optional `rootDirectory` seam. The wrapper's `openSession` ignores the
service's generic injected-connector cwd and uses that sandbox's workspace
for the actual Process and ACP session. No shared conversation/world scope
or Keychain access is introduced.

The injected connector forces text messages through native ACP. A fail-closed
runner explicitly rejects any attempted headless fallback. Ordinary stop,
reconfigure and host destroy close the actual connector and remove only its
owned sandbox; a later send can create a new production sandbox/connector and
bootstrap only the bounded actual transcript. There are no fake Agent replies
or substituted model requests.

`StageResidentChatState` is not constructed: its attachment store currently
has a fixed root. The bridge instead reuses `ResidentChatSubmission` and
`ResidentDraftRecovery`; image attachment UI is outside this first text-only
bridge. There are no world tools, world persistence scope, memory adapter,
automatic speech, microphone, or ASR in this lane. Real GPUI/cloud reply and
cancellation verification remains an end-to-end gate distinct from ABI/build
checks.

## Offline diagnostics check

After building the Debug render host, run these commands from the repository
root. This imports the actual compiled module and exercises production DSH
environment exclusions/invariants plus safe connection messages. It does not create
a render host, launch a backend, send a model request, or read credentials.

```sh
probe_products="$PWD/tmp/gpui-render-host/DerivedData/Build/Products/Debug"
xcrun swiftc \
  -I "$probe_products" -F "$probe_products" \
  -Xcc "-fmodule-map-file=$PWD/tmp/gpui-render-host/DerivedData/Build/Intermediates.noindex/GeneratedModuleMaps/CNanoem.modulemap" \
  -Xcc "-I$PWD/apps/macos/Packages/NanoemCore/Sources/CNanoem/include" \
  tools/gpui-render-host-diagnostics-check.swift \
  -Xlinker "$probe_products/GPUIRenderHost.dylib" \
  -o tmp/gpui-render-host/diagnostics-check
DYLD_LIBRARY_PATH="$probe_products" DYLD_FRAMEWORK_PATH="$probe_products" \
  tmp/gpui-render-host/diagnostics-check
```

Expected successful output:

```text
PASS: 8 blocked environment overrides; 3 production environment invariants; 3 safe DSH messages; no Agent/request/credential access
```

The executable is `tmp/gpui-render-host/diagnostics-check`; it is a local
build artifact and must not be committed. These checks do not establish a
successful cloud reply or a passed GUI end-to-end conversation.
