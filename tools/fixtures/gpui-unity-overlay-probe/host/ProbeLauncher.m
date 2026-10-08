#import <AppKit/AppKit.h>
#include <dlfcn.h>
// Private external-AppKit-host test; never creates a world, audio engine, or Unity.
static void *library;
static void (*unmountProbe)(void);
@interface GMGNProbeDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(strong) NSWindow *window;
@end
@implementation GMGNProbeDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)windowWillClose:(NSNotification *)note { (void)note; if (unmountProbe) unmountProbe(); }
- (void)applicationWillTerminate:(NSNotification *)note { (void)note; if (unmountProbe) unmountProbe(); }
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2 || argv[1][0] != '/') { fprintf(stderr,"Pass an absolute probe dylib path.\n"); return 2; }
        library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library) { fprintf(stderr,"Probe library unavailable.\n"); return 3; }
        int (*registerWindow)(void *) = dlsym(library,"gmgn_overlay_register_unity_window");
        int (*mountProbe)(void *) = dlsym(library,"gmgn_gpui_probe_mount");
        unmountProbe = dlsym(library,"gmgn_gpui_probe_unmount");
        if (!registerWindow || !mountProbe || !unmountProbe) { fprintf(stderr,"Probe ABI missing.\n"); return 4; }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        GMGNProbeDelegate *delegate = [GMGNProbeDelegate new];
        app.delegate = delegate;
        delegate.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,600)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        delegate.window.title = @"聊天2 — 外部 AppKit 宿主实验（非 Unity）";
        delegate.window.delegate = delegate;
        delegate.window.releasedWhenClosed = NO;
        if (registerWindow((__bridge void *)delegate.window) != 1 ||
            mountProbe((__bridge void *)delegate.window.contentView) != 0) {
            fprintf(stderr,"Probe mount failed.\n"); unmountProbe(); return 5;
        }
        [delegate.window center];
        [delegate.window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        [app run];
        unmountProbe();
        // Keep the Rust library loaded until process exit: retained GPUI objects
        // may still own code pointers while native teardown unwinds.
        return 0;
    }
}
