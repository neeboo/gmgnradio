# GPU lyrics drawing foundation

This isolated AppKit/Metal module does not start the product, touch its stores,
replace SceneKit or implement the eleven original lyric modes. It establishes
the drawing primitives needed to avoid full-window CPU SVG rasterization.

## Contract

All entry points are main-thread-only. `create` borrows a live GPUI NSView whose
parent is its window contentView. It inserts a passive, nonopaque CAMetalLayer
NSView sibling immediately below GPUI, above existing native renderer siblings.
All controls/accessibility/input stay in GPUI; `hitTest` always returns nil.
Destroy before the borrowed window/view disappears.

Upload straight RGBA glyph/shape atlas pixels only when their content changes.
The cache owns at most sixteen atlases, 64 MiB total; one atlas may occupy at
most 16 MiB. Each draw supplies actual source dimensions, UV bounds, tint,
opacity and row-major source-logical-to-window-top-left homography. Clip-space
W preserves perspective-correct interpolation. Near-plane crossings are rejected.
Use the actual lyric Scene's shape/transforms; the test rectangle is not product
content or an acceptance fixture.

`render_frame` validates and submits a complete ordered batch tree. A parent
must precede its children; `parent_index=-1` denotes a root. Children are
source-over composited in array order, then their complete parent group receives
Gaussian blur/glow and group opacity. Nodes render their own glyphs before their
children, so original mixed content should use ordered leaf children. One frame
has at most 256 nodes, 4096 total glyphs and depth sixteen. Invalid parent/cycle,
geometry, missing atlas or resource limits reject the whole frame before GPU work.
There is only one final CAMetalLayer present, never one present per batch.

`render_effects` remains a single-root convenience wrapper. Horizontal/vertical
Gaussian compute passes composite source blur and tinted glow. Sigma is
in requested-scale physical pixels (0…128), blur_mix is 0…1. Main render does not wait for GPU
completion: at most two submissions may be in flight, with a rejected busy
submission returning 0. Targets are reused until scale/size changes and capped
at 4,194,304 pixels and 256 MiB total for scratch/root/depth RGBA targets.
Larger real windows are internally downsampled to that budget while keeping
logical homography coordinates and proportionally scaling blur sigma; they are
not rejected solely for full-screen size. `dimensions` exposes actual target size.
At a fixed size, changing mode/depth retains target capacity and only adds missing
depth textures; busy submissions are rejected before target allocation.
`has_atlas(id,width,height)` allows static-content caching without re-uploading;
eviction returns false. Uploaded straight RGBA is premultiplied once, before GPU
linear filtering, preventing invisible colored pixels from adding edge halos.
`readback` is a blocking
test-only verification hook, never call it from the production frame path.

Each node has one sigma shared by its blur/glow. Independent effect radii must
use separate original effect nodes. Offset group shadows and arbitrary original
SVG filter composition still require explicit production semantic mapping and
pixel comparison; they must not be silently dropped. GPU completion diagnostics,
avoiding drawable acquisition stalls and real-window visual equivalence still
need production verification. It is not eleven-mode parity or real App FPS
acceptance. All limits describe retained targets; up to two prior submissions
may temporarily retain old-size targets during resize.

GPU blur/composite dispatches are restricted to the actual projected glyph and
child-group bounds plus the original three-sigma extent (with two conservative
pixels of sampling padding). Parent bounds include child effects, and transparent
scratch output is explicitly cleared before reuse. No-effect opacity-one nodes
draw directly into their parent without an unnecessary full-window copy. A
test-only `set_roi(0)` provides the same shader's full-viewport reference path.
The actual 70-batch Chinese luminous Scene frame at 2360×1520 was compared
channel-by-channel: zero differing RGBA channels, while synchronous completed
time fell from 105.63ms to 18.62ms in the recorded isolated run. These include
GPU wait/readback and are not production App FPS measurements.

CAMetalLayer drawable acquisition runs on a dedicated serial background queue,
with only one pending request. Its main-queue callback presents the latest canvas
on the existing ordered Metal queue; it discards late results when hidden,
destroyed or resized. The application event loop no longer calls `nextDrawable`.
The test pumps real main-runloop callbacks after clear/destroy to verify late
callbacks do not reattach or show a removed layer.

Depth boundary tests render nine/sixteen nested groups and reject seventeen.
The actual Chinese luminous Scene, wrapped to model deeper group transitions,
also passed full-output reference comparison at depth9 (2360×1520) and depth16
(budgeted2227×1434), with zero differing RGBA channels. Such isolated tests do not
establish interactive App performance or original-mode visual acceptance.

## Reproduce

```sh
clang -fobjc-arc -Wall -Wextra -Werror \
  tools/gpui-lyrics-metal-probe/lyrics_layer.m \
  tools/gpui-lyrics-metal-probe/test.m \
  -framework AppKit -framework Metal -framework QuartzCore \
  -o /tmp/gmgn-lyrics-metal-test
/tmp/gmgn-lyrics-metal-test
```

The isolated hidden NSWindow test actually compiles/executes Metal shaders and
reads GPU-generated pixels. It verifies premultiplied alpha, transparent outside
pixels, blur/glow color, Retina output size, atlas eviction, rejected invalid
geometry, nested source-over ordering/group opacity/parent glow, unchanged pixels
after invalid-tree rejection, sibling ordering, passive hit testing, clear and
destroy. It does not
prove visible SceneKit/GPUI compositing or original lyric visual equivalence.
