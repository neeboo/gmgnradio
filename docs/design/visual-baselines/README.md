# Visual baselines

Captured from the native Metal renderers on 2026-07-28 using Xcode 26.6,
macOS 26, and an Apple Silicon display at 2× scale.

## Orb states

- `idle.png` — awake / quiet breathing
- `listening.png` — receptive cyan edge and listening ring
- `thinking.png` — tighter internal motion
- `speaking.png` — higher energy voice motion
- `playing.png` — music-reactive base state
- `reconnecting.png` — reduced-energy connection recovery
- `privacy-off.png` — visually quiet microphone-off state
- `failed.png` — error state

`dormant` intentionally renders no visible pixels. The `wake` event resolves to
the `idle` state, so `idle.png` is also its visual baseline.

## Immersive scene

- `immersive.png` — expanded low-contrast desktop field on the orb's display
- `playing-10s.mov` — 10.0017 seconds, 336×336, 60 FPS

The recording is the live Metal playing state with a neutral black comparison
backdrop. It contains no generated or composited concept art.

## Reproduce

Build:

```bash
xcodebuild build \
  -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio \
  -destination 'platform=macOS'
```

Launch a deterministic baseline state:

```bash
open -n -g \
  --env GMGN_BASELINE=1 \
  --env GMGN_ORB_STATE=listening \
  'apps/macos/build/Debug/gmgn radio.app'
```

Supported values for `GMGN_ORB_STATE` match `DJState.rawValue`.
`GMGN_BASELINE_IMMERSIVE=1` enters the display-wide scene for baseline capture.
At runtime the scene stays behind ordinary application windows and passes
through all pointer input.
