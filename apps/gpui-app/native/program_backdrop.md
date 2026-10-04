# Program background material bridge

This is an unintegrated, public-AppKit material candidate. `HUDWindow` with
`DarkAqua` is **not a verified mapping** of the original SwiftUI
`ultraThinMaterial`. Structural tests do not establish visual parity or prove
the live SceneKit/Metal backdrop is sampled correctly.

## Integration contract

- Only call on the main thread. `create` borrows a live GPUI NSView, whose
  parent must be the window content view. It returns an owned context.
- The passive root is inserted above the existing render container and below
  GPUI. GPUI retains all text, icons, modal layers, accessibility and input.
- Each card uses original logical width/height, rounded radius, opacity and
  priority. Its row-major 3×3 matrix maps source-local coordinates to GPUI-view
  top-left coordinates; reuse the exact matrix used for foreground projection.
- The viewport is the actual scroll viewport `[left, top, width, height]`, in
  the same coordinate system. The material alpha is 0→1 over the top 8%, stays
  1 until 92%, then fades to 0. This is a transparency mask, not black paint.
- The foreground must not contain an opaque simulated-material rectangle;
  keep the original translucent tint, border and foreground content.
- `clear` hides/removes material cards on panel close. Destroy the context
  before changing native windows, then create a new one for the new view.
  Do not retain its borrowed view pointer across window destruction.
- `ProgramBackdrop` is deliberately neither Send nor Sync. Its Drop calls
  destroy. No configuration, scene state, clock or user data is created here.

## Repeatable structural verification

```sh
clang -fobjc-arc -Wall -Wextra -Werror \
  apps/gpui-app/native/program_backdrop.m \
  apps/gpui-app/native/program_backdrop_test.m \
  -framework AppKit -framework QuartzCore \
  -o /tmp/gmgn-program-backdrop-structural-test
/tmp/gmgn-program-backdrop-structural-test
cargo +1.95.0 test --manifest-path apps/gpui-app/Cargo.toml \
  --locked --offline --test program_backdrop \
  --target-dir tools/gpui-scenekit-probe/target
```

The native test creates only a hidden isolated NSWindow. It verifies sibling
order, actual NSVisualEffectView configuration, mask, input pass-through,
invalid-data rejection, wrong-thread rejection, clear and destroy. It does not
launch the product, start its runtime or perform a pixel-level material test.
