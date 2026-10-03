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
`AgentConversationService.send` pipeline. The adapter is disconnected until
`chat_configure` explicitly selects `codex` or `claude-code`; it never chooses
DSH headless or a discovered CLI automatically. `chat_send` and `chat_cancel`
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

Codex uses an injected bounded cancellable process operation with explicit
isolated cwd, read-only sandbox, ephemeral sessions, no inherited user config
or exec rules, and a private `CODEX_HOME` under the isolated data root. The
current host's CLI help/feature list was checked for the actual flags; shell,
plugins, hooks, apps, image generation, and multi-agent features are disabled,
and the MCP server table is empty. Credentials can only come from an already
provided process environment key, with credential storage explicitly set to
file; no auth/config file is copied and no Keychain lookup is requested.
The Codex probe now explicitly selects an OpenAI Responses provider with
`env_key = "OPENAI_API_KEY"` and `requires_openai_auth = false`, avoiding the
built-in provider's stored-auth selection. Failed CLI results are classified
in memory into `auth`, `model`, `network`, `rate`, `config`, or `unknown`;
only the category and fixed safe user text appear in failure events. Raw
output never enters UI, logs or documents. The existing bounded process runner
discards stderr, so a stderr-only failure is honestly classified `unknown`.
Claude uses the existing dedicated safe runner and environment whitelist.

`StageResidentChatState` is not constructed: its attachment store currently
has a fixed root. The bridge instead reuses `ResidentChatSubmission` and
`ResidentDraftRecovery`; image attachment UI is outside this first text-only
bridge. There are no world tools, world persistence scope, memory adapter,
automatic speech, microphone, or ASR in this lane. Real GPUI/cloud reply and
cancellation verification remains an end-to-end gate distinct from ABI/build
checks.

## Offline diagnostics check

After building the Debug render host, run these commands from the repository
root. This imports the actual compiled module and exercises 11 synthetic
failure classifications plus all 6 fixed user messages. It does not create
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
PASS: 11 safe failure classifications; 6 fixed user messages; no network/model request
```

The executable is `tmp/gpui-render-host/diagnostics-check`; it is a local
build artifact and must not be committed. These checks do not establish a
successful cloud reply or a passed GUI end-to-end conversation.
