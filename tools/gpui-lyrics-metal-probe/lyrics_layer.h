#pragma once
#include <stddef.h>
#include <stdint.h>
// Main-thread-only. Borrowed GPUI NSView; opaque context owns passive sibling.
typedef struct {
    uint64_t atlas_id;
    double width, height;
    double matrix[9]; // source logical→window top-left, actual homography
    double uv[4]; // normalized atlas x/y/width/height
    double rgba[4]; // tint and opacity; atlas must contain straight RGBA
} GMGNLyricsGlyph;
typedef struct {
    const GMGNLyricsGlyph *glyphs;
    size_t count;
    double sigma, blur_mix, glow[4], opacity;
    int64_t parent_index; // -1 root; otherwise parent must precede child
} GMGNLyricsBatch;
void *gmgn_lyrics_layer_create(void *gpui_view);
int gmgn_lyrics_layer_atlas(void *, uint64_t id, uint32_t width, uint32_t height, const uint8_t *rgba, size_t bytes);
// Effects apply to the submitted batch: sigma in physical pixels; glow straight RGBA.
int gmgn_lyrics_layer_render(void *, const GMGNLyricsGlyph *, size_t count, double scale, double sigma, const double glow[4]);
int gmgn_lyrics_layer_render_effects(void *, const GMGNLyricsGlyph *, size_t count, double scale, double sigma, const double glow[4], double blur_mix);
// All batches validated before any GPU submission. Ordered source-over; one present.
int gmgn_lyrics_layer_render_frame(void *, const GMGNLyricsBatch *, size_t count, double scale);
int gmgn_lyrics_layer_has_atlas(void *, uint64_t id, uint32_t width, uint32_t height);
int gmgn_lyrics_layer_readback(void *, uint8_t *rgba, size_t bytes, uint32_t *width, uint32_t *height);
// Test-only final display-pipeline capture; disabled by default, BGRA premultiplied.
int gmgn_lyrics_layer_capture(void *, int enabled);
int gmgn_lyrics_layer_readback_presented(void *, uint8_t *bgra, size_t bytes);
int gmgn_lyrics_layer_set_roi(void *, int enabled); // test reference switch; production defaults on
int gmgn_lyrics_layer_dimensions(void *, uint32_t *width, uint32_t *height);
int gmgn_lyrics_layer_clear(void *);
int gmgn_lyrics_layer_destroy(void *);
