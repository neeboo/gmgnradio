#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// This is only window composition/input routing. The Swift ProductHost owns
// the actual production render surface; there is no alternate scene/store.
static const void *containerKey = &containerKey;
static const void *compactKey = &compactKey;
static const void *originalHitKey = &originalHitKey;
static const void *originalMouseKey = &originalMouseKey;
static const void *overlayKey = &overlayKey;

static NSView *productHitTest(NSView *self, SEL selector, NSPoint point) {
    BOOL compact = [objc_getAssociatedObject(self, compactKey) boolValue];
    CGFloat topY = self.isFlipped ? point.y : self.bounds.size.height - point.y;
    BOOL scene = ![objc_getAssociatedObject(self, overlayKey) boolValue] && (compact ? (topY < 168 && !(topY<36 && point.x>118)) : point.x >= 340);
    if (scene) return nil;
    IMP original = [objc_getAssociatedObject(self, originalHitKey) pointerValue];
    return ((NSView *(*)(id, SEL, NSPoint))original)(self, selector, point);
}

static void productMouseDown(NSView *self, SEL selector, NSEvent *event) {
    [self.window makeFirstResponder:self];
    IMP original = [objc_getAssociatedObject(self, originalMouseKey) pointerValue];
    ((void (*)(id, SEL, NSEvent *))original)(self, selector, event);
}

void *gmgn_gpui_surface_container(void *viewPointer, int compact) {
    if (![NSThread isMainThread] || !viewPointer) return NULL;
    NSView *gpui = (__bridge NSView *)viewPointer;
    NSWindow *window = gpui.window;
    // GPUI pre 0.3.7 creates its GPUIView as a child of the NSWindow contentView
    // (window.rs content_view.addSubview_(native_view)), and the raw handle
    // points at that child, not the wrapper. Preserve both original roles.
    NSView *content = window.contentView;
    NSView *parent = gpui.superview;
    BOOL validParent = window && content && parent && (gpui == content || parent == content);
    if (!validParent) {
        static NSUInteger diagnosticCount = 0;
        if (diagnosticCount++ < 3) fprintf(stderr,
            "GMGN_GPUI_MOUNT_STRUCTURE view=%s window=%d content=%s parent=%s view_is_content=%d parent_is_content=%d\n",
            class_getName(object_getClass(gpui)), window != nil,
            content ? class_getName(object_getClass(content)) : "nil",
            parent ? class_getName(object_getClass(parent)) : "nil",
            gpui == content, parent == content);
        return NULL;
    }
    NSView *existing = objc_getAssociatedObject(gpui, containerKey);
    if (existing) return (__bridge void *)existing;
    NSView *container = [[NSView alloc] initWithFrame:gpui.frame];
    container.wantsLayer = YES;
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [parent addSubview:container positioned:NSWindowBelow relativeTo:gpui];
    fprintf(stderr, "GMGN_GPUI_MOUNT_STRUCTURE accepted=true view=%s content=%s parent=%s direct_child=%d\n",
        class_getName(object_getClass(gpui)), class_getName(object_getClass(content)),
        class_getName(object_getClass(parent)), parent == content);
    objc_setAssociatedObject(gpui, containerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gpui, compactKey, @(compact != 0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Class originalClass = object_getClass(gpui);
    NSString *name = [NSString stringWithFormat:@"GMGNProductInput_%s", class_getName(originalClass)];
    Class routed = objc_getClass(name.UTF8String);
    if (!routed) {
        routed = objc_allocateClassPair(originalClass, name.UTF8String, 0);
        Method hit = class_getInstanceMethod(originalClass, @selector(hitTest:));
        Method down = class_getInstanceMethod(originalClass, @selector(mouseDown:));
        class_addMethod(routed, @selector(hitTest:), (IMP)productHitTest, method_getTypeEncoding(hit));
        class_addMethod(routed, @selector(mouseDown:), (IMP)productMouseDown, method_getTypeEncoding(down));
        objc_registerClassPair(routed);
    }
    objc_setAssociatedObject(gpui, originalHitKey,
        [NSValue valueWithPointer:class_getMethodImplementation(originalClass, @selector(hitTest:))], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gpui, originalMouseKey,
        [NSValue valueWithPointer:class_getMethodImplementation(originalClass, @selector(mouseDown:))], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    object_setClass(gpui, routed);
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    if (compact) window.level = NSFloatingWindowLevel;
    return (__bridge void *)container;
}

int gmgn_gpui_window_visible(void *viewPointer) {
    if (![NSThread isMainThread] || !viewPointer) return 0;
    NSView *view = (__bridge NSView *)viewPointer;
    return view.window.isVisible && !view.window.isMiniaturized;
}

int gmgn_gpui_has_visible_windows(void) {
    for (NSWindow *window in NSApp.windows) {
        if (window.isVisible && !window.isMiniaturized) return 1;
    }
    return 0;
}

void gmgn_gpui_ui_overlay(void *viewPointer, int visible) {
    if (![NSThread isMainThread] || !viewPointer) return;
    objc_setAssociatedObject((__bridge NSView *)viewPointer, overlayKey, @(visible != 0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
