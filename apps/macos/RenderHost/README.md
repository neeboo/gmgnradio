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
