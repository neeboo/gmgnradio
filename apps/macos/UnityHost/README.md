# Unity macOS media / chat host

Build with `bash tools/build-unity-media-host.sh` from the repository root.
Output: `tmp/unity-media-host/DerivedData/Build/Products/Release/UnityMediaHost.dylib`.
The build reuses the existing package lock and never installs an application.

This host constructs `AudioGraphController`, `LocalMusicPlayer`, and the real
`RenderHostResidentConversation` DSH adapter. It does not construct `AppDelegate`,
`GPUIProductHost`, `GPUIRenderHost`, SceneKit surfaces, or world autonomy loops.
Existing renderer sources remain compile-time dependencies in this first sample.

Call the C ABI in `UnityMediaHost.h` on the macOS main thread. Supply an explicit
absolute sample data root and a dedicated `ai.gmgn.unity-sample.*` defaults suite.
No production music session store or Keychain is constructed. DSH uses its existing
managed native transport and credentials; the UI accepts no API key.

Commands are UTF-8 JSON, at most 256 KiB:

- `music.load`: absolute `path`, optional real local `lyricPath` (LRC), `autoplay`.
- `music.choose`: nonblocking native audio-file picker; automatically loads and
  plays selected real files as a queue and adjacent same-basename `.lrc` files.
- `music.queue`: `paths` of absolute real files, optional `index` (default 0),
  `autoplay`. `music.next` and `music.previous` switch this retained queue.
- `music.play`, `music.pause`, `music.stop`.
- `music.volume`: numeric `value` in 0–1.
- `chat.send`: integer `requestID`, string `text`.
- `chat.cancel`: integer `requestID`.

Snapshot shape: `{version:1,music:{playbackSessionID,title,duration,position,
isPlaying,volume,seekSupported,lyricRevision,features,notice},chat:{events,state}}`.
Music features are `amplitude/low/mid/high/beat/onset`. Position comes from the
actual AVAudioPlayerNode sample clock. `lines:[{id,text,start,end}]` appears once
per lyric revision, including an empty array to clear the previous song. Unity
must retain the timeline until the next revision. Every snapshot consumes chat
events; use one polling owner and dispatch to UI consumers. Free every returned
UTF-8 snapshot with `gmgn_unity_host_string_free`.

Known sample gaps: seeking is explicitly unsupported; provider library/search selection and streaming reply deltas
are not implemented here. Chat currently reports accepted/final reply/failure/
cancelled with request IDs and sequence numbers. These gaps are not represented
as successful or simulated functionality.

Validation: Release host build passed. `abi-smoke.c` passed real dylib load,
creation, isolated snapshot, volume bounds, unsupported-seek rejection and
destruction. It sends no chat request and plays no audio, so this check does not
replace real Unity playback/chat acceptance. Compile the smoke executable with
`clang apps/macos/UnityHost/abi-smoke.c -o tmp/unity-media-host/abi-smoke`; pass the
absolute dylib path and a fresh isolated root, with `DYLD_FRAMEWORK_PATH` set to
the Release products directory.

Package a fresh sample App using `bash tools/package-unity-media-host.sh` followed
by its absolute path inside this repository's `tmp` directory. The script rejects
installed/non-sample Apps and repeated host overwrites. Unity CLI's optional
`unity-build.provenance.json` at the App root is preserved byte-for-byte in a
unique adjacent `tmp/unity-build.provenance.*.json` before signing; root-level
extra files otherwise cause Apple's unsealed-bundle signature rejection.

Optional fourth smoke-test argument is a real local audio path. It validates the
actual audio graph play/pause/resume/stop clock, briefly producing audio. The
pause regression check passed with the existing real music cache: 0.673 seconds
before pause, 0.673 while paused, 0.998 after resume, 0 after stop. Unity window
acceptance remains a separate check.

Snapshot also exposes `canNext`, `canPrevious`, `queueIndex`, `queueCount` and
`queue:[{index,title}]`; boundary commands fail without wrapping. Each queue
switch increments playback session and lyric revision and clears previous lyrics.
Actual-component smoke tests with two different existing music-cache MP3s passed
next/previous, real sample-clock advancement, session changes and boundaries.
