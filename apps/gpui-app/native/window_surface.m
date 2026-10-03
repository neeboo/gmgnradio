#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// This is only window composition/input routing. The Swift ProductHost owns
// the actual production render surface; there is no alternate scene/store.
static const void *containerKey = &containerKey;
static const void *compactKey = &compactKey;

int gmgn_gpui_set_outer_size(void *viewPointer, double width, double height, double minWidth, double minHeight) {
    if (![NSThread isMainThread] || !viewPointer) return 0;
    NSWindow *window = ((__bridge NSView *)viewPointer).window;
    if (!window) return 0;
    NSRect frame = window.frame;
    // Preserve the upper-left corner. AppKit computes the actual content rect
    // for this window style; no fixed titlebar-height assumption is involved.
    frame.origin.y += frame.size.height - height;
    frame.size = NSMakeSize(width, height);
    window.minSize = NSMakeSize(minWidth, minHeight);
    [window setFrame:frame display:YES];
    fprintf(stderr,"GMGN_GPUI_OUTER_SIZE width=%.0f height=%.0f content_width=%.0f content_height=%.0f\n",window.frame.size.width,window.frame.size.height,window.contentView.bounds.size.width,window.contentView.bounds.size.height);
    return 1;
}
static const void *originalHitKey = &originalHitKey;
static const void *originalMouseKey = &originalMouseKey;
static const void *regionsKey = &regionsKey;
static const void *bitmapRegionKey = &bitmapRegionKey;
static const void *bitmapQueueKey = &bitmapQueueKey;
static const void *dragOriginalKey = &dragOriginalKey;

static BOOL bitmapDrag(id<NSDraggingInfo> sender) {
    NSPasteboard *board = sender.draggingPasteboard;
    // File drags stay on GPUI's existing ExternalPaths route, even when they
    // also advertise an image representation.
    if ([board canReadObjectForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}]) return NO;
    return [board availableTypeFromArray:@[NSPasteboardTypePNG, NSPasteboardTypeTIFF]] != nil
        || [board canReadObjectForClasses:@[NSImage.class] options:@{}];
}

static BOOL insideBitmapRegion(NSView *view, id<NSDraggingInfo> sender) {
    NSValue *region = objc_getAssociatedObject(view, bitmapRegionKey);
    if (!region) return NO;
    NSPoint point = [view convertPoint:sender.draggingLocation fromView:nil];
    if (!view.isFlipped) point.y = view.bounds.size.height - point.y;
    return NSPointInRect(point, region.rectValue);
}

static IMP originalDrag(NSView *view, SEL selector) {
    return [objc_getAssociatedObject(view, dragOriginalKey)[NSStringFromSelector(selector)] pointerValue];
}

static NSDragOperation productDragging(NSView *view, SEL selector, id<NSDraggingInfo> sender) {
    if (bitmapDrag(sender)) return insideBitmapRegion(view, sender) ? NSDragOperationCopy : NSDragOperationNone;
    IMP original = originalDrag(view, selector);
    return original ? ((NSDragOperation (*)(id,SEL,id))original)(view,selector,sender) : NSDragOperationNone;
}

static BOOL productDrop(NSView *view, SEL selector, id<NSDraggingInfo> sender) {
    if (!bitmapDrag(sender)) {
        IMP original = originalDrag(view, selector);
        return original ? ((BOOL (*)(id,SEL,id))original)(view,selector,sender) : NO;
    }
    if (!insideBitmapRegion(view, sender)) return NO;
    NSPasteboard *board = sender.draggingPasteboard;
    NSString *type = [board availableTypeFromArray:@[NSPasteboardTypePNG, NSPasteboardTypeTIFF]];
    NSData *data = type ? [board dataForType:type] : nil;
    if (!data) {
        NSImage *image = [[board readObjectsForClasses:@[NSImage.class] options:@{}] firstObject];
        data = image.TIFFRepresentation;
        type = NSPasteboardTypeTIFF;
    }
    if (!data.length || data.length > 64 * 1024 * 1024) return NO;
    NSMutableArray *queue = objc_getAssociatedObject(view, bitmapQueueKey);
    if (!queue) {
        queue = [NSMutableArray array];
        objc_setAssociatedObject(view, bitmapQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (queue.count >= 4) return NO;
    NSDictionary *command = @{ @"op":@"chat.attachments.bitmap", @"dataBase64":[data base64EncodedStringWithOptions:0],
        @"encoding":[type isEqualToString:NSPasteboardTypePNG] ? @"png" : @"tiff" };
    NSData *json = [NSJSONSerialization dataWithJSONObject:command options:0 error:nil];
    if (!json) return NO;
    [queue addObject:json];
    return YES;
}

void gmgn_gpui_bitmap_drop_region(void *pointer, double x, double y, double width, double height, int enabled) {
    if (![NSThread isMainThread] || !pointer) return;
    objc_setAssociatedObject((__bridge NSView *)pointer, bitmapRegionKey,
        enabled ? [NSValue valueWithRect:NSMakeRect(x,y,width,height)] : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Caller owns the returned C string. Bytes are the actual dragging pasteboard
// snapshot, never a later read of the general clipboard.
char *gmgn_gpui_take_bitmap_drop(void *pointer) {
    if (![NSThread isMainThread] || !pointer) return NULL;
    NSMutableArray *queue = objc_getAssociatedObject((__bridge NSView *)pointer, bitmapQueueKey);
    NSData *data = queue.firstObject;
    if (!data) return NULL;
    char *result = malloc(data.length + 1);
    if (!result) return NULL;
    memcpy(result, data.bytes, data.length);
    result[data.length] = 0;
    [queue removeObjectAtIndex:0];
    return result;
}

void gmgn_gpui_bitmap_drop_string_free(char *value) {
    free(value);
}

static NSView *productHitTest(NSView *self, SEL selector, NSPoint point) {
    CGFloat topY = self.isFlipped ? point.y : self.bounds.size.height - point.y;
    BOOL interface = NO;
    for (NSValue *region in objc_getAssociatedObject(self, regionsKey)) {
        if (NSPointInRect(NSMakePoint(point.x,topY),region.rectValue)) {interface=YES;break;}
    }
    if (!interface) return nil;
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
    objc_setAssociatedObject(gpui, compactKey, @(compact != 0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    window.level = compact ? NSFloatingWindowLevel : NSNormalWindowLevel;
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
        for (NSString *selectorName in @[@"draggingEntered:", @"draggingUpdated:", @"performDragOperation:"]) {
            SEL selector = NSSelectorFromString(selectorName);
            Method method = class_getInstanceMethod(originalClass, selector);
            class_addMethod(routed, selector, [selectorName isEqualToString:@"performDragOperation:"] ? (IMP)productDrop : (IMP)productDragging,
                method ? method_getTypeEncoding(method) : ([selectorName isEqualToString:@"performDragOperation:"] ? "c@:@" : "Q@:@"));
        }
        objc_registerClassPair(routed);
    }
    objc_setAssociatedObject(gpui, originalHitKey,
        [NSValue valueWithPointer:class_getMethodImplementation(originalClass, @selector(hitTest:))], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gpui, originalMouseKey,
        [NSValue valueWithPointer:class_getMethodImplementation(originalClass, @selector(mouseDown:))], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    object_setClass(gpui, routed);
    NSMutableDictionary *dragMethods = [NSMutableDictionary dictionary];
    for (NSString *selectorName in @[@"draggingEntered:", @"draggingUpdated:", @"performDragOperation:"]) {
        IMP implementation = class_getMethodImplementation(originalClass, NSSelectorFromString(selectorName));
        if (implementation) dragMethods[selectorName] = [NSValue valueWithPointer:implementation];
    }
    objc_setAssociatedObject(gpui, dragOriginalKey, dragMethods, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gpui registerForDraggedTypes:@[NSPasteboardTypeFileURL, @"NSFilenamesPboardType", NSPasteboardTypePNG, NSPasteboardTypeTIFF]];
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

void gmgn_gpui_hit_regions(void *viewPointer,const double *regions,size_t count) {
    if (![NSThread isMainThread] || !viewPointer || count>32) return;
    NSMutableArray *values=[NSMutableArray arrayWithCapacity:count];
    for(size_t i=0;i<count;i++) {
        const double *r=regions+i*4;
        [values addObject:[NSValue valueWithRect:NSMakeRect(r[0],r[1],r[2],r[3])]];
    }
    objc_setAssociatedObject((__bridge NSView *)viewPointer,regionsKey,values,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
