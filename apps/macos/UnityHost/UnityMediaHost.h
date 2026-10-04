#pragma once
#include <stdint.h>
// Lifecycle, command and snapshot require the macOS main thread.
// root must be an explicit absolute isolated path. suite starts with
// ai.gmgn.unity-sample. No default user data or Keychain is accessed.
void *gmgn_unity_host_create(const char *root, const char *suite);
int32_t gmgn_unity_host_command(void *handle, const char *json);
// Main-thread submission; copied, decoded and evaluated asynchronously. 64 MiB max.
int32_t gmgn_unity_host_placement(void *handle, const uint8_t *bytes, int32_t count);
char *gmgn_unity_host_snapshot(void *handle);
void gmgn_unity_host_string_free(char *json);
int32_t gmgn_unity_host_destroy(void *handle);
double gmgn_unity_window_scale(void);
double gmgn_unity_window_width(void);
double gmgn_unity_screen_pixels(int32_t axis);
