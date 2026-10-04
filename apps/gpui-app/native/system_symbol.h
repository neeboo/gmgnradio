#include <stddef.h>
// Main-thread only. Owned, nonpremultiplied RGBA tint/coverage pixels;
// NULL with zero dimensions when the symbol cannot be drawn visibly.
unsigned char *gmgn_system_symbol_rgba(const char *name, int tint, int *width, int *height);
unsigned int gmgn_system_color_rgba(int color);
void gmgn_system_symbol_free(void *data);
