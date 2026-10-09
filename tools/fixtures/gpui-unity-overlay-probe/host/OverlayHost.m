#import <AppKit/AppKit.h>
#import "OverlayHost.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface GMGNProbeEvent : NSProxy
@property(strong) NSEvent *event;
@property(strong) NSWindow *donor;
@property NSPoint local;
@end
@implementation GMGNProbeEvent
- (NSPoint)locationInWindow { return self.local; }
- (NSWindow *)window { return self.donor; }
- (NSInteger)windowNumber { return self.donor.windowNumber; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [self.event methodSignatureForSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.event]; }
@end

// Experimental native mount only. The child must be a real GPUI view supplied by Rust.
static NSArray<NSValue *> *hitRegions;
static unsigned inputTraceCount;
static BOOL inputDiagnostics;
static double traceClock(void) { return [NSDate date].timeIntervalSince1970 * 1000.0; }
static double traceLastGeometryMs;
static void releaseOutsideFocus(NSView *view);
static BOOL hitsUI(NSView *view, NSPoint local) {
    if (!NSPointInRect(local, view.bounds)) return NO;
    if (!view.flipped) local.y = NSMaxY(view.bounds) - local.y;
    for (NSValue *value in hitRegions) if (NSPointInRect(local, value.rectValue)) return YES;
    return NO;
}
@interface GMGNProbeContainer : NSView
@end
@implementation GMGNProbeContainer
// Diagnostics only: proves whether a real left-mouse-down reached the mounted
// container and whether the painted hit regions cover the point.
static void traceHitTest(NSView *view, NSPoint local, BOOL hit) {
    static double lastMs;
    if (!inputDiagnostics) return;
    NSEvent *event = NSApp.currentEvent;
    if (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeRightMouseDown) return;
    double now = traceClock();
    if (now - lastMs < 150) return;
    lastMs = now;
    NSMutableString *regions = [NSMutableString string];
    for (NSUInteger index = 0; index < hitRegions.count && index < 8; index++) {
        NSRect rect = hitRegions[index].rectValue;
        [regions appendFormat:@"(%.0f,%.0f,%.0fx%.0f)", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
    }
    NSLog(@"[GPUIOverlayTrace] ms=%.1f event=hitTest hit=%d local=%.0f,%.0f bounds=%.0fx%.0f regions=%lu %@",
        now, hit, local.x, local.y, view.bounds.size.width, view.bounds.size.height,
        (unsigned long)hitRegions.count, regions);
}
- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (self.hidden) return nil;
    BOOL hit = hitsUI(self, local);
    traceHitTest(self, local, hit);
    if (!hit) { releaseOutsideFocus(self); return nil; }
    return [super hitTest:point];
}
@end

static __weak NSWindow *registeredWindow;
static GMGNProbeContainer *container;
static NSView *mountedView;
static NSArray *observers;
static uint64_t geometryRevision;
static NSWindow *donorWindow;
static Class originalViewClass;
static Class originalDonorClass;
static NSTimer *frameTimer;
static NSTimeInterval frameUntil;
static BOOL frameQueued;
static void drawMountedFrame(void) {
    if (!mountedView || !originalViewClass || !registeredWindow.visible || registeredWindow.miniaturized) return;
    if (inputDiagnostics && traceClock() - traceLastGeometryMs < 400) {
        double ms = traceClock();
        NSLog(@"[GPUIOverlayTrace] ms=%.1f event=drawMountedFrame sinceGeometryMs=%.0f mounted=%.0fx%.0f",
            ms, ms - traceLastGeometryMs, mountedView.frame.size.width, mountedView.frame.size.height);
    }
    Method method = class_getInstanceMethod(originalViewClass, @selector(displayLayer:));
    if (method) ((void (*)(id, SEL, id))method_getImplementation(method))(mountedView, @selector(displayLayer:), mountedView.layer);
}
static void wakeFrames(void);
// GPUI retains its original window as its activation authority after its view
// is embedded. Reflect the real host's key state without activating or showing
// the hidden donor, which would steal focus from Unity or the settings window.
static BOOL mountedDonorIsKey(id window, SEL selector) {
    (void)window; (void)selector;
    return registeredWindow.isKeyWindow;
}
static void syncHostActivation(void) {
    if (!donorWindow || !mountedView) return;
    SEL selector = registeredWindow.isKeyWindow ? @selector(windowDidBecomeKey:) : @selector(windowDidResignKey:);
    id delegate = donorWindow.delegate;
    if (![delegate respondsToSelector:selector]) return;
    NSNotificationName name = registeredWindow.isKeyWindow ? NSWindowDidBecomeKeyNotification : NSWindowDidResignKeyNotification;
    ((void (*)(id, SEL, id))objc_msgSend)(delegate, selector,
        [NSNotification notificationWithName:name object:donorWindow]);
    wakeFrames();
}
static BOOL installDonorActivationAdapter(void) {
    originalDonorClass = object_getClass(donorWindow);
    NSString *name = [NSString stringWithFormat:@"GMGNMountedWindow_%@", NSStringFromClass(originalDonorClass)];
    Class adapter = NSClassFromString(name);
    if (!adapter) {
        adapter = objc_allocateClassPair(originalDonorClass, name.UTF8String, 0);
        if (!adapter) return NO;
        Method method = class_getInstanceMethod(originalDonorClass, @selector(isKeyWindow));
        class_addMethod(adapter, @selector(isKeyWindow), (IMP)mountedDonorIsKey, method_getTypeEncoding(method));
        objc_registerClassPair(adapter);
    }
    object_setClass(donorWindow, adapter);
    return YES;
}
static void transparentMountedLayer(void) {
    mountedView.layer.opaque = NO;
    mountedView.layer.backgroundColor = NSColor.clearColor.CGColor;
    donorWindow.opaque = NO;
    donorWindow.backgroundColor = NSColor.clearColor;
}
static void traceInput(id view, const char *phase, NSEvent *event, NSUInteger length) {
    if (!inputDiagnostics || inputTraceCount >= 128) return;
    inputTraceCount++;
    BOOL focused = [view window].firstResponder == view;
    NSLog(@"[Chat2Input] n=%u phase=%s focused=%d keyCode=%u type=%lu length=%lu",
        inputTraceCount, phase, focused, event ? event.keyCode : 0,
        (unsigned long)(event ? event.type : 0), (unsigned long)length);
}
static void wakeFrames(void) {
    frameUntil = NSProcessInfo.processInfo.systemUptime + 2;
    if (frameQueued) return;
    frameQueued = YES;
    // GPUI may call wake while rendering. Defer to avoid a nested frame callback.
    dispatch_async(dispatch_get_main_queue(), ^{ frameQueued = NO; drawMountedFrame(); });
}
static NSView *unityResponder(NSView *view) {
    Class playerView = NSClassFromString(@"PlayerWindowView");
    if (playerView && [view isKindOfClass:playerView] && view.acceptsFirstResponder) return view;
    for (NSView *child in view.subviews) {
        if (child == container) continue;
        NSView *responder = unityResponder(child);
        if (responder) return responder;
    }
    return nil;
}
static void releaseOutsideFocus(NSView *view) {
    NSEvent *event = NSApp.currentEvent;
    // Hit tests also occur during pointer motion. Keep text/IME focus until an
    // actual outside click, matching normal AppKit text-field behavior.
    if (event.window != view.window ||
        (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeRightMouseDown &&
         event.type != NSEventTypeOtherMouseDown)) return;
    NSResponder *focus = registeredWindow.firstResponder;
    if (focus != mountedView && !([focus isKindOfClass:NSView.class] &&
        [(NSView *)focus isDescendantOf:mountedView])) return;
    NSView *target = unityResponder(registeredWindow.contentView) ?: registeredWindow.contentView;
    [registeredWindow makeFirstResponder:target];
    wakeFrames();
}
static void mountedMouse(id view, SEL selector, NSEvent *event) {
    BOOL focusing = event.type == NSEventTypeLeftMouseDown;
    if (focusing) {
        BOOL accepted = [[view window] makeFirstResponder:view];
        traceInput(view, accepted ? "hostFocus:accepted" : "hostFocus:rejected", nil, 0);
    }
    NSPoint local = [view convertPoint:event.locationInWindow fromView:nil];
    if ([view isFlipped]) local.y = [view bounds].size.height - local.y;
    GMGNProbeEvent *proxy = [GMGNProbeEvent alloc];
    proxy.event = event; proxy.donor = donorWindow; proxy.local = local;
    wakeFrames();
    struct objc_super call = { view, originalViewClass };
    ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&call, selector, proxy);
    if (focusing && [view window].firstResponder != view) {
        BOOL accepted = [[view window] makeFirstResponder:view];
        traceInput(view, accepted ? "hostFocus:restored" : "hostFocus:restoreRejected", nil, 0);
    }
}
static BOOL mountedAcceptsFirstResponder(id view, SEL selector) { (void)view; (void)selector; return YES; }
static void mountedKey(id view, SEL selector, NSEvent *event) {
    NSUInteger length = (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) ? event.characters.length : 0;
    traceInput(view, sel_getName(selector), event, length);
    wakeFrames();
    struct objc_super call = { view, originalViewClass };
    ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&call, selector, event);
}
static BOOL mountedKeyEquivalent(id view, SEL selector, NSEvent *event) {
    traceInput(view, "performKeyEquivalent:before", event, event.characters.length);
    wakeFrames();
    struct objc_super call = { view, originalViewClass };
    BOOL handled = ((BOOL (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&call, selector, event);
    traceInput(view, handled ? "performKeyEquivalent:handled" : "performKeyEquivalent:unhandled", nil, 0);
    return handled;
}
static id mountedInputContext(id view, SEL selector) {
    struct objc_super call = { view, originalViewClass };
    id context = ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&call, selector);
    traceInput(view, context ? "inputContext:present" : "inputContext:nil", nil, 0);
    return context;
}
static NSUInteger textLength(id text) {
    return [text respondsToSelector:@selector(length)] ? [text length] : 0;
}
static void mountedInsertText(id view, SEL selector, id text, NSRange replacement) {
    traceInput(view, "insertText:replacementRange:", nil, textLength(text));
    struct objc_super call = { view, originalViewClass };
    ((void (*)(struct objc_super *, SEL, id, NSRange))objc_msgSendSuper)(&call, selector, text, replacement);
}
static void mountedMarkedText(id view, SEL selector, id text, NSRange selected, NSRange replacement) {
    traceInput(view, "setMarkedText:selectedRange:replacementRange:", nil, textLength(text));
    struct objc_super call = { view, originalViewClass };
    ((void (*)(struct objc_super *, SEL, id, NSRange, NSRange))objc_msgSendSuper)(&call, selector, text, selected, replacement);
}
static void mountedCommand(id view, SEL selector, SEL command) {
    (void)command;
    traceInput(view, "doCommandBySelector:", nil, 0);
    struct objc_super call = { view, originalViewClass };
    ((void (*)(struct objc_super *, SEL, SEL))objc_msgSendSuper)(&call, selector, command);
}
static NSRect mountedFirstRect(id view, SEL selector, NSRange range, NSRange *actual) {
    struct objc_super call = { view, originalViewClass };
    NSRect rect = ((NSRect (*)(struct objc_super *, SEL, NSRange, NSRange *))objc_msgSendSuper)(&call, selector, range, actual);
    if (NSIsEmptyRect(rect)) return rect;
    rect.origin.x -= donorWindow.frame.origin.x;
    rect.origin.y -= donorWindow.frame.origin.y;
    if ([view isFlipped]) rect.origin.y = [view bounds].size.height - NSMaxY(rect);
    return [[view window] convertRectToScreen:[view convertRect:rect toView:nil]];
}
static BOOL installAdapter(NSView *view) {
    originalViewClass = object_getClass(view);
    NSString *name = [NSString stringWithFormat:@"GMGNMounted_%@", NSStringFromClass(originalViewClass)];
    Class adapter = NSClassFromString(name);
    if (!adapter) {
        adapter = objc_allocateClassPair(originalViewClass, name.UTF8String, 0);
        if (!adapter) return NO;
        Method accepts = class_getInstanceMethod(originalViewClass, @selector(acceptsFirstResponder));
        if (accepts) class_addMethod(adapter, @selector(acceptsFirstResponder), (IMP)mountedAcceptsFirstResponder, method_getTypeEncoding(accepts));
        for (NSString *name in @[@"mouseDown:",@"mouseUp:",@"mouseMoved:",@"mouseDragged:",
                                @"rightMouseDown:",@"rightMouseUp:",@"rightMouseDragged:",
                                @"otherMouseDown:",@"otherMouseUp:",@"otherMouseDragged:",@"scrollWheel:"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod(originalViewClass, selector);
            if (method) class_addMethod(adapter, selector, (IMP)mountedMouse, method_getTypeEncoding(method));
        }
        for (NSString *name in @[@"keyDown:",@"keyUp:",@"flagsChanged:"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod(originalViewClass, selector);
            if (method) class_addMethod(adapter, selector, (IMP)mountedKey, method_getTypeEncoding(method));
        }
        struct { SEL selector; IMP implementation; } traces[] = {
            { @selector(performKeyEquivalent:), (IMP)mountedKeyEquivalent },
            { @selector(inputContext), (IMP)mountedInputContext },
            { @selector(insertText:replacementRange:), (IMP)mountedInsertText },
            { @selector(setMarkedText:selectedRange:replacementRange:), (IMP)mountedMarkedText },
            { @selector(doCommandBySelector:), (IMP)mountedCommand }
        };
        for (unsigned i=0; i<sizeof(traces)/sizeof(traces[0]); i++) {
            Method method = class_getInstanceMethod(originalViewClass, traces[i].selector);
            if (method) class_addMethod(adapter, traces[i].selector, traces[i].implementation, method_getTypeEncoding(method));
        }
        SEL selector = @selector(firstRectForCharacterRange:actualRange:);
        Method method = class_getInstanceMethod(originalViewClass, selector);
        if (method) class_addMethod(adapter, selector, (IMP)mountedFirstRect, method_getTypeEncoding(method));
        objc_registerClassPair(adapter);
    }
    object_setClass(view, adapter);
    return YES;
}
// Read-only resize tracing. `GMGN_GPUI_INPUT_DIAGNOSTICS=1` prints the real
// ordering of the host window notifications, the applied viewport and the
// 30 Hz pulse so a late/absent geometry update can be measured instead of
// guessed. It never resizes or draws by itself.
static void traceFacts(const char *event) {
    if (!inputDiagnostics || !registeredWindow || !container) return;
    NSRect window = registeredWindow.frame;
    NSRect content = registeredWindow.contentView.bounds;
    NSLog(@"[GPUIOverlayTrace] ms=%.1f event=%s win=%.0fx%.0f content=%.0fx%.0f container=%.0fx%.0f mounted=%.0fx%.0f donor=%.0fx%.0f rev=%llu",
        traceClock(), event, window.size.width, window.size.height,
        content.size.width, content.size.height,
        container.frame.size.width, container.frame.size.height,
        mountedView.frame.size.width, mountedView.frame.size.height,
        donorWindow.contentView.frame.size.width, donorWindow.contentView.frame.size.height,
        geometryRevision);
}
static void traceWindowSizeChange(void) {
    static NSSize observed;
    static BOOL haveObserved;
    if (!inputDiagnostics || !registeredWindow || !container) return;
    NSSize window = registeredWindow.contentView.bounds.size;
    if (haveObserved && NSEqualSizes(window, observed)) return;
    observed = window;
    haveObserved = YES;
    traceFacts("pulseWindowSize");
}
static void traceGeometryGap(void) {
    static double lastGapMs;
    if (!inputDiagnostics || !registeredWindow || !container) return;
    NSSize window = registeredWindow.contentView.bounds.size;
    if (NSEqualSizes(window, container.frame.size)) return;
    double now = traceClock();
    if (now - lastGapMs < 100) return;
    lastGapMs = now;
    traceFacts("pulseGeometryGap");
}
static void updateGeometry(void) {
    if (!registeredWindow || !container) return;
    NSRect bounds = registeredWindow.contentView.bounds;
    NSRect frame = bounds;
    BOOL changed = !NSEqualSizes(container.frame.size, frame.size);
    container.frame = frame;
    // Resize the real donor's viewport too, so GPUI receives its native resize
    // callback and Metal drawable dimensions match the visible mounted view.
    if (!NSEqualSizes(donorWindow.contentView.frame.size, frame.size)) [donorWindow setContentSize:frame.size];
    donorWindow.contentView.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height);
    [mountedView setFrameOrigin:NSZeroPoint];
    // GPUI's callback reads donor.contentView.frame, and its override updates
    // the Metal drawable. Invoke that override explicitly after donor sizing.
    Method resize = class_getInstanceMethod(originalViewClass, @selector(setFrameSize:));
    if (resize) ((void (*)(id, SEL, NSSize))method_getImplementation(resize))(mountedView, @selector(setFrameSize:), frame.size);
    else [mountedView setFrameSize:frame.size];
    transparentMountedLayer();
    traceLastGeometryMs = traceClock();
    if (inputDiagnostics) NSLog(@"[GPUIOverlay] geometry host=%@ donor=%@ mounted=%@ layerOpaque=%d scale=%.2f changed=%d ms=%.1f",
        NSStringFromSize(frame.size), NSStringFromSize(donorWindow.contentView.frame.size),
        NSStringFromSize(mountedView.frame.size), mountedView.layer.opaque, registeredWindow.backingScaleFactor,
        changed, traceLastGeometryMs);
    wakeFrames();
    geometryRevision++;
}
int32_t probe_native_host_size(float *width, float *height) {
    if (![NSThread isMainThread] || !width || !height || !registeredWindow || !container) return 0;
    NSSize host = registeredWindow.contentView.bounds.size;
    if (!isfinite(host.width) || !isfinite(host.height) || host.width <= 0 || host.height <= 0) return 0;
    *width = (float)host.width;
    *height = (float)host.height;
    return 1;
}
int32_t probe_native_sync_geometry(void) {
    if (![NSThread isMainThread] || !registeredWindow || !container || !mountedView) return 0;
    NSSize host = registeredWindow.contentView.bounds.size;
    if (!isfinite(host.width) || !isfinite(host.height) || host.width <= 0 || host.height <= 0) return 0;
    // The host window owns the viewport. A missed or late AppKit resize
    // notification must not leave the mounted view on the old size, so the
    // host poll re-asserts it: nothing is touched while all three views
    // already match, which is what keeps a steady frame free of resizes.
    if (NSEqualSizes(host, container.frame.size) &&
        NSEqualSizes(host, donorWindow.contentView.frame.size) &&
        NSEqualSizes(host, mountedView.frame.size)) return 0;
    updateGeometry();
    return 1;
}
int32_t probe_native_set_panel_expanded(int32_t expanded) {
    if (![NSThread isMainThread] || !mountedView || !registeredWindow || (expanded != 0 && expanded != 1)) return 0;
    // Panel expansion belongs to GPUI layout; the native viewport stays full size.
    wakeFrames();
    return 1;
}
int32_t probe_native_register_unity_window(void *pointer) {
    if (![NSThread isMainThread] || !pointer || mountedView) return 0;
    NSWindow *window = (__bridge NSWindow *)pointer;
    // Explicit same-process registration is a trusted host call. Automatic
    // discovery below remains restricted to an unambiguous Unity window.
    if (![window isKindOfClass:NSWindow.class] || !window.contentView) return 0;
    registeredWindow = window;
    geometryRevision++;
    return 1;
}
static BOOL hasPlayerWindowView(NSView *view, Class playerViewClass) {
    if ([view isKindOfClass:playerViewClass]) return YES;
    for (NSView *child in view.subviews) if (hasPlayerWindowView(child, playerViewClass)) return YES;
    return NO;
}
int32_t probe_native_register_current_unity_window(void) {
    if (![NSThread isMainThread]) return 0;
    // Verified in this SDK's UnityPlayer ObjC metadata. Never match window titles.
    Class playerWindowClass = NSClassFromString(@"PlayerWindow");
    Class playerViewClass = NSClassFromString(@"PlayerWindowView");
    if (!playerWindowClass || !playerViewClass) return 0;
    NSWindow *match = nil;
    for (NSWindow *window in NSApp.windows) {
        if (window.visible && ![window isKindOfClass:NSPanel.class] &&
            [window isKindOfClass:playerWindowClass] &&
            hasPlayerWindowView(window.contentView, playerViewClass)) {
            if (match) return 0; // Ambiguous identity is not resolved by title guessing.
            match = window;
        }
    }
    if (match) NSLog(@"[Chat2] window registered class=%@ contentClass=%@ number=%ld",
        NSStringFromClass(match.class), NSStringFromClass(match.contentView.class), (long)match.windowNumber);
    return probe_native_register_unity_window((__bridge void *)match);
}
void *probe_native_unity_content_view(void) {
    return [NSThread isMainThread] ? (__bridge void *)registeredWindow.contentView : NULL;
}
int32_t probe_attach_view(void *parentPointer, void *childPointer, float width, float height) {
    if (![NSThread isMainThread] || !parentPointer || !childPointer || mountedView ||
        !isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) return 0;
    NSView *parent = (__bridge NSView *)parentPointer;
    NSView *child = (__bridge NSView *)childPointer;
    if (parent != registeredWindow.contentView || ![child isKindOfClass:NSView.class] ||
        child == parent || [parent isDescendantOf:child]) return 0;
    container = [[GMGNProbeContainer alloc] initWithFrame:parent.bounds];
    hitRegions = @[];
    container.wantsLayer = YES;
    container.layer.masksToBounds = YES;
    container.layer.backgroundColor = NSColor.clearColor.CGColor;
    mountedView = child;
    inputTraceCount = 0;
    inputDiagnostics = [NSProcessInfo.processInfo.environment[@"GMGN_GPUI_INPUT_DIAGNOSTICS"] isEqualToString:@"1"];
    donorWindow = child.window;
    if (!donorWindow || !installAdapter(child)) { mountedView = nil; container = nil; donorWindow = nil; return 0; }
    if (!installDonorActivationAdapter()) {
        object_setClass(child, originalViewClass);
        originalViewClass = Nil; mountedView = nil; container = nil; donorWindow = nil;
        originalDonorClass = Nil;
        return 0;
    }
    // Preserve a donor viewport for GPUI's MacWindowState after moving its real
    // drawing view into Unity. Do not let a stale original 1280x720 root survive.
    if (donorWindow.contentView == child) {
        donorWindow.contentView = [[NSView alloc] initWithFrame:child.frame];
    }
    [child removeFromSuperview];
    [container addSubview:child];
    [parent addSubview:container positioned:NSWindowAbove relativeTo:nil];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSNotificationName name in @[NSWindowDidResizeNotification, NSWindowDidChangeBackingPropertiesNotification,
                                     NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification,
                                     NSWindowDidChangeScreenNotification]) {
        [tokens addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:registeredWindow
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                traceFacts(note.name.UTF8String);
                updateGeometry();
            }]];
    }
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
        [tokens addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:registeredWindow
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; syncHostActivation(); }]];
    }
    observers = tokens;
    // attach is called from inside GPUI Window::update. Its native resize
    // callback re-enters handle.update(bounds_changed), so resize only after
    // the outer GPUI update has returned and the window is available again.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (mountedView == child) { updateGeometry(); syncHostActivation(); }
    });
    // Bounded activity pulses; use the visible host, not the hidden donor's occlusion.
    frameTimer = [NSTimer timerWithTimeInterval:1.0/30 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        if (mountedView && registeredWindow.visible && !registeredWindow.miniaturized) {
            traceWindowSizeChange();
            traceGeometryGap();
            if (NSProcessInfo.processInfo.systemUptime < frameUntil) drawMountedFrame();
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:frameTimer forMode:NSRunLoopCommonModes];
    return 1;
}
int32_t probe_detach_view(void *pointer) {
    if (![NSThread isMainThread] || !pointer || (__bridge NSView *)pointer != mountedView) return 0;
    [frameTimer invalidate]; frameTimer = nil;
    if (registeredWindow.firstResponder == mountedView ||
        ([registeredWindow.firstResponder isKindOfClass:NSView.class] &&
         [(NSView *)registeredWindow.firstResponder isDescendantOf:mountedView]))
        [registeredWindow makeFirstResponder:registeredWindow.contentView];
    for (id token in observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    observers = nil;
    [mountedView removeFromSuperview];
    if (originalViewClass) object_setClass(mountedView, originalViewClass);
    if (originalDonorClass && donorWindow) object_setClass(donorWindow, originalDonorClass);
    originalDonorClass = Nil;
    originalViewClass = Nil; donorWindow = nil;
    [container removeFromSuperview];
    mountedView = nil;
    container = nil;
    hitRegions = @[];
    geometryRevision++;
    return 1;
}
uint64_t probe_native_geometry_revision(void) { return [NSThread isMainThread] ? geometryRevision : 0; }
double probe_native_backing_scale(void) { return [NSThread isMainThread] ? registeredWindow.backingScaleFactor : 0; }
int32_t probe_native_owns_input(void) {
    if (![NSThread isMainThread] || !mountedView || !registeredWindow.visible || container.hidden) return 0;
    NSPoint point = [registeredWindow convertPointFromScreen:NSEvent.mouseLocation];
    point = [container convertPoint:point fromView:nil];
    return hitsUI(container, point) ? 1 : 0;
}
int32_t probe_native_text_input_focused(void) {
    if (![NSThread isMainThread] || !mountedView || !registeredWindow.visible ||
        !registeredWindow.keyWindow || container.hidden) return 0;
    NSResponder *focus = registeredWindow.firstResponder;
    return focus == mountedView || ([focus isKindOfClass:NSView.class] && [(NSView *)focus isDescendantOf:mountedView]) ? 1 : 0;
}
void probe_native_wake_frames(void) {
    if ([NSThread isMainThread] && mountedView && registeredWindow.visible) wakeFrames();
}
void probe_native_set_hit_regions(const float *rects, int32_t count) {
    if (![NSThread isMainThread] || count < 0 || (count > 0 && !rects)) return;
    NSMutableArray<NSValue *> *regions = [NSMutableArray array];
    for (int32_t i = 0; i < count; i++) {
        const float *r = rects + (size_t)i * 4;
        if (!isfinite(r[0]) || !isfinite(r[1]) || !isfinite(r[2]) || !isfinite(r[3]) || r[2] <= 0 || r[3] <= 0) continue;
        [regions addObject:[NSValue valueWithRect:NSMakeRect(r[0], r[1], r[2], r[3])]];
    }
    hitRegions = regions;
}
int32_t probe_native_normalize_chat_rect(float x, float y, float width, float height,
    float *nx, float *ny, float *nw, float *nh) {
    if (!nx || !ny || !nw || !nh) return 0;
    *nx = *ny = *nw = *nh = 0;
    if (![NSThread isMainThread] || !mountedView || !registeredWindow.visible || container.hidden ||
        !isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) ||
        x < 0 || y < 0 || width <= 0 || height <= 0) return 0;
    NSRect local = NSMakeRect(x, y, width, height);
    if (NSMaxX(local) > mountedView.bounds.size.width || NSMaxY(local) > mountedView.bounds.size.height) return 0;
    if (!mountedView.flipped) local.origin.y = mountedView.bounds.size.height - NSMaxY(local);
    NSView *content = registeredWindow.contentView;
    NSRect rect = [mountedView convertRect:local toView:content];
    NSRect bounds = content.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return 0;
    *nx = (rect.origin.x - bounds.origin.x) / bounds.size.width;
    *ny = (content.flipped ? rect.origin.y - bounds.origin.y : NSMaxY(bounds) - NSMaxY(rect)) / bounds.size.height;
    *nw = rect.size.width / bounds.size.width; *nh = rect.size.height / bounds.size.height;
    return 1;
}
