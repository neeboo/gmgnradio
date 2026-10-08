#import <Foundation/Foundation.h>
#import "OverlayHost.h"
#include <stdio.h>
// Headless negative checks only: do not create NSApplication, windows or views.
int main(void) {
    @autoreleasepool {
        uint64_t initial = probe_native_geometry_revision();
        float x = 1, y = 1, width = 1, height = 1;
        if (probe_native_register_unity_window(NULL) != 0 ||
            probe_attach_view(NULL,NULL,420,300) != 0 ||
            probe_detach_view(NULL) != 0 ||
            probe_native_unity_content_view() != NULL ||
            probe_native_backing_scale() != 0 ||
            probe_native_owns_input() != 0 ||
            probe_native_set_panel_expanded(0) != 0 ||
            probe_native_normalize_chat_rect(0, 0, 1, 1, &x, &y, &width, &height) != 0 ||
            x != 0 || y != 0 || width != 0 || height != 0 ||
            probe_native_geometry_revision() != initial) return 1;
        puts("PASS native ABI null rejection; no NSApplication/window/GPUI started");
        return 0;
    }
}
