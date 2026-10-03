#import <AppKit/AppKit.h>
#import <SceneKit/SceneKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#import "render-host-bridge.h"

static atomic_ulong sceneFrames;
static unsigned long scenePointerEvents;
static BOOL chatActive;
static BOOL compactMode;
static BOOL productionMode;
static void probeSetChatActive(NSWindow *window, BOOL enabled) {
    chatActive = enabled;
    if (enabled) [window makeKeyWindow];
    else [window resignKeyWindow];
}
@interface ProbeSceneView : SCNView <SCNSceneRendererDelegate>
@end

@interface ProbeProductionContainer : NSView
@end
@implementation ProbeProductionContainer
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    // Full-stage events stay with the actual production view / interaction system.
    // LiveCam uses its host's explicit orbit ABI, not an invented Metal scene.
    return compactMode && hit ? self : hit;
}
- (void)mouseDown:(NSEvent *)event {
    if (!compactMode) { [super mouseDown:event]; return; }
    probeSetChatActive(self.window, NO);
    scenePointerEvents++;
    NSLog(@"PROBE_RENDER_HOST_POINTER kind=mouseDown count=%lu", scenePointerEvents);
}
- (void)mouseDragged:(NSEvent *)event {
    if (!compactMode) { [super mouseDragged:event]; return; }
    scenePointerEvents++;
    probe_production_rotate((float)event.deltaX * 0.01f, (float)event.deltaY * 0.01f);
    NSLog(@"PROBE_RENDER_HOST_POINTER kind=drag count=%lu", scenePointerEvents);
}
- (void)scrollWheel:(NSEvent *)event {
    if (!compactMode) { [super scrollWheel:event]; return; }
    scenePointerEvents++;
    // Host ABI currently exposes orbit only; this is not a production zoom claim.
    probe_production_rotate(0, (float)event.scrollingDeltaY * 0.01f);
    NSLog(@"PROBE_RENDER_HOST_POINTER kind=scrollOrbit count=%lu", scenePointerEvents);
}
@end
@implementation ProbeSceneView
- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time {
    atomic_fetch_add(&sceneFrames, 1);
}
- (void)mouseDown:(NSEvent *)event {
    if (compactMode) probeSetChatActive(self.window, NO);
    scenePointerEvents++;
    NSLog(@"PROBE_SCENE_POINTER kind=mouseDown count=%lu frames=%lu", scenePointerEvents, atomic_load(&sceneFrames));
    [super mouseDown:event];
}
- (void)scrollWheel:(NSEvent *)event {
    scenePointerEvents++;
    NSLog(@"PROBE_SCENE_POINTER kind=scroll count=%lu frames=%lu", scenePointerEvents, atomic_load(&sceneFrames));
    [super scrollWheel:event];
}
- (void)mouseDragged:(NSEvent *)event {
    scenePointerEvents++;
    NSLog(@"PROBE_SCENE_POINTER kind=drag count=%lu frames=%lu", scenePointerEvents, atomic_load(&sceneFrames));
    [super mouseDragged:event];
}
@end

static BOOL routeScene = YES;
static BOOL modalOpen = NO;
static SCNView *activeSceneView;
static NSView *activeProductionContainer;
static NSTimer *statusTimer;
static id closeObserver;
static NSMutableArray *visibilityObservers;
static __weak NSWindow *attachedWindow;
static NSTimer *hideRestoreTimer;
static void probeSyncVisibility(NSWindow *window) {
    if (!productionMode || !window) return;
    // Match production: hidden/minimized stops; mere ordinary overlap does not.
    probe_production_visibility(window.visible, window.visible && window.miniaturized);
}
void probe_hide_briefly(void) {
    NSWindow *window = attachedWindow;
    if (!productionMode || !window) return;
    [window orderOut:nil];
    probeSyncVisibility(window);
    [hideRestoreTimer invalidate];
    __weak NSWindow *weakWindow = window;
    hideRestoreTimer = [NSTimer scheduledTimerWithTimeInterval:4 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        NSWindow *currentWindow = weakWindow;
        if (currentWindow) { [currentWindow orderFront:nil]; probeSyncVisibility(currentWindow); }
    }];
}
void probe_cleanup(void) {
    if (!statusTimer && !activeSceneView && !activeProductionContainer && !closeObserver) return;
    [statusTimer invalidate];
    statusTimer = nil;
    [hideRestoreTimer invalidate];
    hideRestoreTimer = nil;
    for (id observer in visibilityObservers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    visibilityObservers = nil;
    attachedWindow = nil;
    activeSceneView.playing = NO;
    activeSceneView.delegate = nil;
    [activeSceneView removeFromSuperview];
    activeSceneView = nil;
    if (productionMode) probe_production_destroy();
    [activeProductionContainer removeFromSuperview];
    activeProductionContainer = nil;
    if (closeObserver) [NSNotificationCenter.defaultCenter removeObserver:closeObserver];
    closeObserver = nil;
    NSLog(@"PROBE_SCENE_CLOSED timerInvalidated=1 sceneStopped=1");
}
void probe_reset_camera(void) {
    if (productionMode) return; // No reset-camera ABI: never substitute a fixture camera.
    SCNNode *camera = [SCNNode node];
    camera.camera = [SCNCamera camera];
    camera.position = SCNVector3Make(0, 2, 7);
    camera.eulerAngles = SCNVector3Make(-0.18, 0, 0);
    [activeSceneView.scene.rootNode addChildNode:camera];
    activeSceneView.pointOfView = camera;
}
static IMP originalHitTest;
static IMP originalMouseDown;
static BOOL probeCanBecomeKey(id self, SEL selector) {
    (void)self; (void)selector;
    return chatActive;
}
static BOOL probeCanBecomeMain(id self, SEL selector) {
    (void)self; (void)selector;
    return NO;
}
static void probeMouseDown(id self, SEL selector, NSEvent *event) {
    NSView *view = self;
    if (compactMode) {
        NSPoint local = [view convertPoint:event.locationInWindow fromView:nil];
        CGFloat topY = view.isFlipped ? local.y : NSHeight(view.bounds) - local.y;
        probeSetChatActive(view.window, topY >= 192);
    }
    if (!compactMode || chatActive) [view.window makeFirstResponder:view];
    ((void (*)(id, SEL, NSEvent *))originalMouseDown)(self, selector, event);
}
static NSView *probeHitTest(id self, SEL selector, NSPoint point) {
    NSView *view = self;
    NSPoint local = [view convertPoint:point fromView:view.superview];
    // Probe-only fixed panel boundary. Production requires dynamic GPUI hit regions.
    CGFloat topY = view.isFlipped ? local.y : NSHeight(view.bounds) - local.y;
    BOOL sceneRegion = compactMode ? (topY >= 32 && topY < 192) : local.x > 420;
    if (routeScene && !modalOpen && sceneRegion) return nil;
    return ((NSView *(*)(id, SEL, NSPoint))originalHitTest)(self, selector, point);
}
void probe_route(int enabled) { routeScene = enabled != 0; }
void probe_modal(int enabled) { modalOpen = enabled != 0; }

// Independent probe: SceneKit stays live in a sibling below the GPUI view.
void probe_attach(void *pointer) {
    NSView *gpui = (__bridge NSView *)pointer;
    NSWindow *window = gpui.window;
    attachedWindow = window;
    NSView *originalContentView = window.contentView;
    // Preserve GPUI's original content-view hierarchy, including AccessKit's
    // wrapper. Keyboard equivalents and accessibility depend on that wrapper.
    NSView *parent = gpui.superview;
    compactMode = getenv("GMGN_PROBE_COMPACT") && strcmp(getenv("GMGN_PROBE_COMPACT"), "1") == 0;
    productionMode = probe_production_requested() != 0;
    if (compactMode) {
        Class windowBase = object_getClass(window);
        Class panelAdapter = objc_allocateClassPair(windowBase, "GMGNProbeChatFocusPanel", 0);
        class_addMethod(panelAdapter, @selector(canBecomeKeyWindow), (IMP)probeCanBecomeKey,
            method_getTypeEncoding(class_getInstanceMethod(windowBase, @selector(canBecomeKeyWindow))));
        class_addMethod(panelAdapter, @selector(canBecomeMainWindow), (IMP)probeCanBecomeMain,
            method_getTypeEncoding(class_getInstanceMethod(windowBase, @selector(canBecomeMainWindow))));
        objc_registerClassPair(panelAdapter);
        object_setClass(window, panelAdapter);
        window.level = NSFloatingWindowLevel;
        if ([window isKindOfClass:NSPanel.class]) {
            NSPanel *panel = (NSPanel *)window;
            panel.becomesKeyOnlyIfNeeded = YES;
            panel.hidesOnDeactivate = NO;
        }
        parent.wantsLayer = YES;
        parent.layer.cornerRadius = 28;
        parent.layer.masksToBounds = YES;
    }
    NSRect nativeFrame = gpui.frame;
    if (compactMode) {
        CGFloat localY = gpui.isFlipped ? 32 : NSHeight(gpui.bounds) - 192;
        nativeFrame = [gpui convertRect:NSMakeRect(0, localY, NSWidth(gpui.bounds), 160) toView:parent];
    }
    if (productionMode) {
        ProbeProductionContainer *container = [[ProbeProductionContainer alloc] initWithFrame:nativeFrame];
        container.autoresizingMask = compactMode ? NSViewNotSizable : NSViewWidthSizable | NSViewHeightSizable;
        activeProductionContainer = container;
        [parent addSubview:container positioned:NSWindowBelow relativeTo:gpui];
        probe_production_attach(container, !compactMode);
    } else {
    ProbeSceneView *sceneView = [[ProbeSceneView alloc] initWithFrame:nativeFrame];
    sceneView.delegate = sceneView;
    activeSceneView = sceneView;
    sceneView.autoresizingMask = compactMode ? NSViewNotSizable : NSViewWidthSizable | NSViewHeightSizable;
    sceneView.backgroundColor = [NSColor colorWithRed:0.07 green:0.13 blue:0.18 alpha:1];
    sceneView.scene = [SCNScene scene];
    sceneView.allowsCameraControl = YES;
    sceneView.autoenablesDefaultLighting = YES;
    sceneView.playing = YES;
    SCNNode *camera = [SCNNode node];
    camera.camera = [SCNCamera camera];
    camera.position = SCNVector3Make(0, 2, 7);
    camera.eulerAngles = SCNVector3Make(-0.18, 0, 0);
    [sceneView.scene.rootNode addChildNode:camera];
    SCNNode *cube = [SCNNode nodeWithGeometry:[SCNBox boxWithWidth:1.8 height:1.8 length:1.8 chamferRadius:0.12]];
    cube.geometry.firstMaterial.diffuse.contents = [NSColor systemTealColor];
    [cube runAction:[SCNAction repeatActionForever:[SCNAction rotateByX:0.3 y:1 z:0 duration:2]]];
    [sceneView.scene.rootNode addChildNode:cube];
    SCNNode *floor = [SCNNode nodeWithGeometry:[SCNFloor floor]];
    floor.position = SCNVector3Make(0, -1.2, 0);
    floor.geometry.firstMaterial.diffuse.contents = [NSColor darkGrayColor];
    [sceneView.scene.rootNode addChildNode:floor];
    [parent addSubview:sceneView positioned:NSWindowBelow relativeTo:gpui];
    }
    gpui.layer.opaque = NO;
    window.opaque = NO;
    Class base = object_getClass(gpui);
    originalHitTest = class_getMethodImplementation(base, @selector(hitTest:));
    originalMouseDown = class_getMethodImplementation(base, @selector(mouseDown:));
    Class adapter = objc_allocateClassPair(base, "GMGNProbeGPUIHitRegionView", 0);
    class_addMethod(adapter, @selector(hitTest:), (IMP)probeHitTest,
                    method_getTypeEncoding(class_getInstanceMethod(base, @selector(hitTest:))));
    class_addMethod(adapter, @selector(mouseDown:), (IMP)probeMouseDown,
                    method_getTypeEncoding(class_getInstanceMethod(base, @selector(mouseDown:))));
    objc_registerClassPair(adapter);
    object_setClass(gpui, adapter);
    [window makeFirstResponder:gpui];
    NSLog(@"GPUI_SCENEKIT_PROBE source=%@ contentViewPreserved=%d parent=%@", productionMode ? @"productionRenderHost" : @"SceneKitFixture", window.contentView == originalContentView, NSStringFromClass(object_getClass(parent)));
    __weak NSWindow *weakWindow = window;
    if (productionMode) {
        visibilityObservers = [NSMutableArray array];
        for (NSNotificationName name in @[NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification, NSWindowDidChangeOcclusionStateNotification]) {
            id observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:window queue:nil usingBlock:^(NSNotification *notification) {
                (void)notification;
                probeSyncVisibility(weakWindow);
            }];
            [visibilityObservers addObject:observer];
        }
    }
    statusTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        NSWindow *currentWindow = weakWindow;
        if (!currentWindow) { [timer invalidate]; return; }
        NSLog(@"PROBE_SCENE_STATUS frames=%lu pointer=%lu routing=%d modal=%d firstResponder=%@ chatActive=%d key=%d main=%d appActive=%d canKey=%d canMain=%d level=%ld nonactivating=%d", atomic_load(&sceneFrames), scenePointerEvents, routeScene, modalOpen, NSStringFromClass(object_getClass(currentWindow.firstResponder)), chatActive, currentWindow.keyWindow, currentWindow.mainWindow, NSApp.active, currentWindow.canBecomeKeyWindow, currentWindow.canBecomeMainWindow, (long)currentWindow.level, (currentWindow.styleMask & NSWindowStyleMaskNonactivatingPanel) != 0);
        if (productionMode) { probeSyncVisibility(currentWindow); probe_production_diagnostics(); }
    }];
    closeObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:window queue:nil usingBlock:^(NSNotification *notification) {
        (void)notification;
        probe_cleanup();
    }];
}
