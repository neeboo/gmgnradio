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
// Optional real conversation adapter. Never starts a backend by default.
// backend: "dsh" (the existing native ACP Agent). No headless fallback or keys.
// No world tools; final response, not tokens.
int32_t gmgn_render_host_chat_configure(void *handle, const char *backend);
int32_t gmgn_render_host_chat_send(void *handle, uint64_t request_id, const char *text);
int32_t gmgn_render_host_chat_cancel(void *handle, uint64_t request_id);
// Owned UTF-8 JSON; release via gmgn_render_host_string_free.
char *gmgn_render_host_chat_poll(void *handle);
char *gmgn_render_host_chat_context(void *handle);
