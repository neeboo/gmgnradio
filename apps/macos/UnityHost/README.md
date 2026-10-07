# Unity macOS host

Unity owns rendering and simple chat/playback controls. The independent GPUI settings
window owns product configuration; `settings.open` opens it. The host reuses original
music, conversation, presence, shortcuts, speech, screens and world services. It does
not start a second AppDelegate/GPUI product host/SceneKit renderer. The resident loop
is connected to the shared world session; construction alone does not prove activity.

## Build and data boundaries

Run `bash tools/build-unity-media-host.sh` from the repository root. Output:
`tmp/unity-media-host/DerivedData/Build/Products/Release/UnityMediaHost.dylib`.
Package only a fresh sample App with `bash tools/package-unity-media-host.sh <absolute-app-path>`.
This includes newly built GPUI settings and Rust `gmgn-taskd`, reuses resolved packages,
rejects installed/non-sample Apps and repeated host overwrites, preserves Unity
provenance before signing, and does not launch the App.

macOS Unity now defaults to the product Application Support base
(`~/Library/Application Support`), not a per-build world tree. Services retain their
own existing subdirectories. `GMGN_UNITY_DATA_ROOT` explicitly overrides this base.
The ABI requires an absolute non-root path and an `ai.gmgn.unity-sample.*` defaults
suite. The current UI uses `ai.gmgn.unity-sample.player.preferences`. A dedicated
defaults suite does **not** isolate filesystem data. Tests must use a fresh explicit
root and must not connect production sockets or replay production jobs.

Music reads existing account/library sources (optionally
`GMGN_UNITY_MUSIC_LIBRARY_ROOT`) with a Unity session overlay and nonpersistent web
cookies. Explicit Unity disconnects preserve original sessions. Speech reads original
TTS/ASR preferences only as fallback when no local override exists; explicit saves
use the supplied defaults. Snapshot credentials are presence-only. DSH uses its
existing native credentials; Codex uses the formal installed adapter and current CLI
identity. Backend selection neither logs in nor copies identity; login/logout are
explicit GPUI actions. No second production write authority or Keychain-backed
account store is created by the Unity host.

## ABI and connected interfaces

Call `UnityMediaHost.h` on the macOS main thread. Commands are UTF-8 JSON, at most
256 KiB. Free returned strings with `gmgn_unity_host_string_free`. Use one native
snapshot polling owner: chat events and changed lyric timelines are consumed on
publication. Retain/distribute them to consumers. GPUI's separate settings snapshot
does not drain these events.

- Music: local load/file picker/queue/play/pause/stop/volume/next/previous, actual
  provider library/playlist selection and playback, account connection and sync.
  Provider libraries are no longer placeholders. Queue bounds fail without wrapping.
  Seeking remains unsupported.
- Chat: `chat.send {requestID,text}`, `chat.cancel {requestID}`; DSH/Codex selection
  changes the real backend. Installed choices are probed; unavailable saved choices
  are not reported active. Genuine cumulative deltas replace current message text.
  Cancellation confirms local invalidation, not remote acknowledgement/process exit.
  Read actual streamed/final delivery capabilities; do not invent streamed deltas.
- Speech: Rust TTS/ASR settings/catalog/preview, reply reading and microphone
  `voice.press/release/cancel`. Permission/capture/recognition failures are explicit.
  Transcript delivery is not evidence of completed resident action.
- Presence: original package/motion import/select/remove/catalog/download and orb
  appearance. `selection` carries revision, actual avatar/motion paths and appearance;
  Unity returns `presence.runtime.result {revision,success}`. Pending failures restore
  original selection. Orb, PMX/VMD and official UniVRM VRM/VRMA adapters are present;
  successful Unity compilation does not establish visual correctness for user assets.
- Shortcuts: formal coordinator/capture/reset/global/media controls. Music actions
  use the real player. Ordered UI toggles use `uiIntents` and `ui.intent.ack`.
- Lyrics/visuals: original parser/12 themes/eight point-cloud choices, actual rhythm,
  artwork and particle scale. Retain real translated/word-timed data only when present.
  Lyrics use the actual AVAudioPlayerNode clock, not a synthetic playback clock.
- Video/screens: `video.load/choose/select/remove/play/pause/stop/mode/brightness` and
  `screen.list/play/stop`. Select starts playback through the original video store.
  GPUI reads `settings.video`; Unity reads `screenVideo` with borrowed Metal textures.
  Screens must be placed/enabled in the current authoritative world. Original native
  link resolution is reused. Destroy Unity texture consumers before host teardown.
- Basic objects/wishes: formal device templates/authority placement, wish coordinator,
  generation configuration and inventory receipts. `generation.load/save/check`
  configures the same store as the wish machine; save/check does not start generation.
  Generated output, claim, inventory registration, resident arrival and rendered-loop
  receipts remain distinct stages.

## Authority and remaining gaps

Rust remains the sole world persistence authority. Swift adopts/projects its real
state and Unity renders it; there is no parallel writable world archive. Resident
music/wish/screen/autonomy tools share the same world context and current-session
leases. A tool success or authority commit does not prove visible arrival/placement.

The space bridge accepts explicit registered complete package roots and uses formal
`WorldPackageValidator` manifest/resource hash/path validation. A selection request
does not persist preference; actual world-session and renderer success must acknowledge
the matching revision. Host switch/ack and GPUI capability/key alignment are still
being integrated, and arbitrary user-world switching is not runtime-accepted here.

Old `MarbleWorldLibrary` public/account SPZ caches are not complete authority packages.
`LivingWorldBootstrap` reads an already-adopted Marble cabin, but provides no automatic
SPZ-to-complete-package exporter. Full old Marble selection/generation parity remains
incomplete until conversion, validation, registration and renderer acknowledgement are
implemented. Screen geometry calibration also lacks formal metadata/CAS persistence;
the bridge reports failure rather than saving a private in-memory override.

## Verification boundaries

Bridge regressions, GPUI tests and Release builds passed during migration; these are
source/service checks, not acceptance of the latest packaged App. Earlier ABI/audio
clock smoke results are historical. Current integration is debugging startup and still
requires fresh runtime evidence for world/GPU/speech/VRM/screen/resident workflows.

Compile `abi-smoke.c` with
`clang apps/macos/UnityHost/abi-smoke.c -o tmp/unity-media-host/abi-smoke`.
Pass the absolute dylib path and fresh explicit root with `DYLD_FRAMEWORK_PATH` set to
Release products. Ordinary smoke sends no chat and plays no audio; its optional real
audio argument produces sound and requires deliberate runtime-test authorization.
