#pragma once
#include <stdint.h>
// All pointers are borrowed, same-process AppKit objects; all calls main-thread only.
// Native register/attach/detach: 1 success, 0 rejection. Geometry/scale: 0 unavailable.
// Rust public gmgn_gpui_probe_mount (not defined here): 0 success, negative failure.
int32_t probe_native_register_unity_window(void *window);
int32_t probe_native_register_current_unity_window(void);
void *probe_native_unity_content_view(void);
int32_t probe_attach_view(void *parent, void *actual_gpui_view, float width, float height);
int32_t probe_detach_view(void *actual_gpui_view);
uint64_t probe_native_geometry_revision(void);
double probe_native_backing_scale(void);
// Read-only native focus/pointer fact; 1 means the mounted panel currently owns input.
int32_t probe_native_owns_input(void);
int32_t probe_native_text_input_focused(void);
void probe_native_wake_frames(void);
// Main-thread only. Rectangles are viewport logical points, top-left origin.
// Each rectangle contains x, y, width, height. count=0 clears all hit regions.
void probe_native_set_hit_regions(const float *rects, int32_t count);
// Local UI layout only; native 1 success/0 unavailable or invalid argument.
int32_t probe_native_set_panel_expanded(int32_t expanded);
int32_t probe_native_normalize_chat_rect(float x, float y, float width, float height,
    float *normalized_x, float *normalized_y, float *normalized_width, float *normalized_height);
