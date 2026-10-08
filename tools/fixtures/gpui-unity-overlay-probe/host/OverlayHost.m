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
@interface GMGNProbeContainer : NSView
@end
@implementation GMGNProbeContainer
- (NSView *)hitTest:(NSPoint)point {
    if (self.hidden || !NSPointInRect(point, self.frame)) return nil;
    return [super hitTest:point];
}
@end

static __weak NSWindow *registeredWindow;
static GMGNProbeContainer *container;
static NSView *mountedView;
static NSArray *observers;
static uint64_t geometryRevision;
static NSSize requestedSize;
static NSWindow *donorWindow;
static Class originalViewClass;
static NSTimer *frameTimer;
static NSTimeInterval frameUntil;
static unsigned inputTraceCount;
static BOOL inputDiagnostics;
static void traceInput(id view, const char *phase, NSEvent *event, NSUInteger length) {
    if (!inputDiagnostics || inputTraceCount >= 128) return;
    inputTraceCount++;
    BOOL focused = [view window].firstResponder == view;
    NSLog(@"[Chat2Input] n=%u phase=%s focused=%d keyCode=%u type=%lu length=%lu",
        inputTraceCount, phase, focused, event ? event.keyCode : 0,
        (unsigned long)(event ? event.type : 0), (unsigned long)length);
}
static void wakeFrames(void) { frameUntil = NSProcessInfo.processInfo.systemUptime + 2; }
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
static void updateGeometry(void) {
    if (!registeredWindow || !container) return;
    NSRect bounds = registeredWindow.contentView.bounds;
    NSRect frame = container.frame;
    frame.size.width = MIN(requestedSize.width, MAX(0, bounds.size.width - 32));
    frame.size.height = MIN(requestedSize.height, MAX(0, bounds.size.height - 32));
    frame.origin = NSMakePoint(MAX(16, bounds.size.width - frame.size.width - 16), 16);
    container.frame = frame;
    // Resize the real donor's viewport too, so GPUI receives its native resize
    // callback and Metal drawable dimensions match the visible mounted view.
    if (!NSEqualSizes(donorWindow.contentView.bounds.size, frame.size)) [donorWindow setContentSize:frame.size];
    mountedView.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height);
    wakeFrames();
    geometryRevision++;
}
int32_t probe_native_set_panel_expanded(int32_t expanded) {
    if (![NSThread isMainThread] || !mountedView || !registeredWindow || (expanded != 0 && expanded != 1)) return 0;
    requestedSize = NSMakeSize(620, expanded ? 760 : 240);
    updateGeometry();
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
    container = [[GMGNProbeContainer alloc] initWithFrame:NSMakeRect(20, 20, width, height)];
    requestedSize = NSMakeSize(width, height);
    container.wantsLayer = YES;
    container.layer.masksToBounds = YES;
    container.layer.backgroundColor = NSColor.clearColor.CGColor;
    mountedView = child;
    inputTraceCount = 0;
    inputDiagnostics = [NSProcessInfo.processInfo.environment[@"GMGN_GPUI_INPUT_DIAGNOSTICS"] isEqualToString:@"1"];
    donorWindow = child.window;
    if (!donorWindow || !installAdapter(child)) { mountedView = nil; container = nil; donorWindow = nil; return 0; }
    [child removeFromSuperview];
    [container addSubview:child];
    [parent addSubview:container positioned:NSWindowAbove relativeTo:nil];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSNotificationName name in @[NSWindowDidResizeNotification, NSWindowDidChangeBackingPropertiesNotification,
                                     NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification]) {
        [tokens addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:registeredWindow
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; updateGeometry(); }]];
    }
    observers = tokens;
    updateGeometry();
    // Local-echo probe only: bounded activity pulses; no permanent 60fps redraw.
    frameTimer = [NSTimer timerWithTimeInterval:1.0/30 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        if (mountedView && registeredWindow.visible && !registeredWindow.miniaturized &&
            (registeredWindow.occlusionState & NSWindowOcclusionStateVisible) &&
            NSProcessInfo.processInfo.systemUptime < frameUntil &&
            [mountedView respondsToSelector:@selector(displayLayer:)]) {
            ((void (*)(id,SEL,id))objc_msgSend)(mountedView,@selector(displayLayer:),mountedView.layer);
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
    originalViewClass = Nil; donorWindow = nil;
    [container removeFromSuperview];
    mountedView = nil;
    container = nil;
    geometryRevision++;
    return 1;
}
uint64_t probe_native_geometry_revision(void) { return [NSThread isMainThread] ? geometryRevision : 0; }
double probe_native_backing_scale(void) { return [NSThread isMainThread] ? registeredWindow.backingScaleFactor : 0; }
int32_t probe_native_owns_input(void) {
    if (![NSThread isMainThread] || !mountedView || !registeredWindow.visible || container.hidden) return 0;
    NSResponder *focus = registeredWindow.firstResponder;
    if (focus == mountedView || ([focus isKindOfClass:NSView.class] && [(NSView *)focus isDescendantOf:mountedView])) return 1;
    NSPoint point = [registeredWindow convertPointFromScreen:NSEvent.mouseLocation];
    point = [container convertPoint:point fromView:nil];
    return NSPointInRect(point, container.bounds) ? 1 : 0;
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
