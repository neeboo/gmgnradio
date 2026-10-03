#pragma once
#include <stdint.h>
// Main thread only. Handles/views are borrowed except create's retained handle.
void *gmgn_render_host_create(const char *absolute_data_root, const char *isolated_defaults_suite);
int32_t gmgn_render_host_attach(void *handle, void *nsview_container, int32_t full_stage);
void *gmgn_render_host_view(void *handle);
int32_t gmgn_render_host_visibility(void *handle, int32_t visible, int32_t occluded);
int32_t gmgn_render_host_rotate(void *handle, float yaw, float pitch);
char *gmgn_render_host_diagnostics(void *handle);
void gmgn_render_host_string_free(char *string);
int32_t gmgn_render_host_destroy(void *handle);
