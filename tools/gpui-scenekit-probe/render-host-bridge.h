#import <AppKit/AppKit.h>
int probe_production_requested(void);
void probe_production_attach(NSView *container, BOOL fullStage);
void probe_production_rotate(float yaw, float pitch);
void probe_production_visibility(BOOL visible, BOOL occluded);
void probe_production_diagnostics(void);
void probe_production_destroy(void);
