#import "program_backdrop.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

@interface GMGNProgramBackdropRoot : NSView
@end
@implementation GMGNProgramBackdropRoot
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

@interface GMGNProgramBackdropContext : NSObject
@property(nonatomic, weak) NSView *gpui;
@property(nonatomic, strong) GMGNProgramBackdropRoot *root;
@property(nonatomic, strong) NSMutableArray<NSVisualEffectView *> *cards;
@property(nonatomic) double fadeFraction;
@end
@implementation GMGNProgramBackdropContext
@end

void *gmgn_gpui_program_backdrop_create(void *pointer) {
    if (![NSThread isMainThread] || !pointer) return NULL;
    NSView *gpui = (__bridge NSView *)pointer;
    NSView *parent = gpui.superview;
    if (!gpui.window || !parent || parent != gpui.window.contentView) return NULL;
    GMGNProgramBackdropContext *context = [GMGNProgramBackdropContext new];
    context.gpui = gpui;
    context.cards = [NSMutableArray array];
    context.fadeFraction = 0.08;
    context.root = [[GMGNProgramBackdropRoot alloc] initWithFrame:gpui.frame];
    context.root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    context.root.wantsLayer = YES;
    context.root.layer.opaque = NO;
    context.root.hidden = YES;
    // A sibling over the real renderer but below all GPUI overlays/modals.
    [parent addSubview:context.root positioned:NSWindowBelow relativeTo:gpui];
    return (__bridge_retained void *)context;
}

static BOOL validCard(const GMGNProgramBackdropCard *card) {
    if (!isfinite(card->width) || !isfinite(card->height) || card->width <= 0 || card->height <= 0
        || !isfinite(card->radius) || card->radius < 0 || !isfinite(card->opacity)
        || card->opacity < 0 || card->opacity > 1 || !isfinite(card->priority)) return NO;
    for (size_t i = 0; i < 9; i++) if (!isfinite(card->matrix[i])) return NO;
    for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) {
        double w = card->matrix[6] * x * card->width + card->matrix[7] * y * card->height + card->matrix[8];
        if (w <= 1e-8) return NO;
    }
    return YES;
}

int gmgn_gpui_program_backdrop_apply(void *pointer, const GMGNProgramBackdropCard *cards,
                                    size_t count, const double viewport[4]) {
    if (![NSThread isMainThread] || !pointer || !viewport || count > 128 || (count && !cards)) return 0;
    GMGNProgramBackdropContext *context = (__bridge GMGNProgramBackdropContext *)pointer;
    if (!context.gpui.window || context.root.superview != context.gpui.superview) return 0;
    for (size_t i = 0; i < 4; i++) if (!isfinite(viewport[i])) return 0;
    if (viewport[2] <= 0 || viewport[3] <= 0) return 0;
    for (size_t i = 0; i < count; i++) if (!validCard(&cards[i])) return 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    while (context.cards.count > count) {
        [context.cards.lastObject removeFromSuperview];
        [context.cards removeLastObject];
    }
    while (context.cards.count < count) {
        NSVisualEffectView *view = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        // Public AppKit candidate, not a claimed mapping of SwiftUI ultraThinMaterial.
        view.material = NSVisualEffectMaterialHUDWindow;
        view.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        view.state = NSVisualEffectStateActive;
        view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        view.wantsLayer = YES;
        view.layer.opaque = NO;
        view.layer.masksToBounds = YES;
        [context.root addSubview:view];
        [context.cards addObject:view];
    }
    context.root.frame = context.gpui.frame;
    CALayer *mask;
    if (context.fadeFraction > 0) {
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.startPoint = CGPointMake(0.5, 0); gradient.endPoint = CGPointMake(0.5, 1);
        gradient.colors = @[(id)NSColor.clearColor.CGColor, (id)NSColor.blackColor.CGColor,
                           (id)NSColor.blackColor.CGColor, (id)NSColor.clearColor.CGColor];
        gradient.locations = @[@0, @(context.fadeFraction), @(1-context.fadeFraction), @1];
        mask = gradient;
    } else {
        mask = [CALayer layer];
        mask.backgroundColor = NSColor.blackColor.CGColor;
    }
    mask.frame = CGRectMake(viewport[0], viewport[1], viewport[2], viewport[3]);
    context.root.layer.mask = mask;
    for (size_t i = 0; i < count; i++) {
        NSVisualEffectView *view = context.cards[i];
        const GMGNProgramBackdropCard *card = &cards[i];
        view.layer.transform = CATransform3DIdentity;
        view.frame = NSMakeRect(0, 0, card->width, card->height);
        view.layer.anchorPoint = CGPointZero;
        view.layer.position = CGPointZero;
        view.layer.cornerRadius = card->radius;
        view.layer.opacity = (float)card->opacity;
        view.layer.zPosition = card->priority;
        CATransform3D t = CATransform3DIdentity;
        t.m11 = card->matrix[0]; t.m21 = card->matrix[1]; t.m41 = card->matrix[2];
        t.m12 = card->matrix[3]; t.m22 = card->matrix[4]; t.m42 = card->matrix[5];
        t.m14 = card->matrix[6]; t.m24 = card->matrix[7]; t.m44 = card->matrix[8];
        view.layer.transform = t;
    }
    context.root.hidden = count == 0;
    [CATransaction commit];
    return 1;
}

int gmgn_gpui_program_backdrop_clear(void *pointer) {
    if (![NSThread isMainThread] || !pointer) return 0;
    GMGNProgramBackdropContext *context = (__bridge GMGNProgramBackdropContext *)pointer;
    for (NSVisualEffectView *view in context.cards) [view removeFromSuperview];
    [context.cards removeAllObjects]; context.root.hidden = YES; context.root.layer.mask = nil;
    return 1;
}

int gmgn_gpui_program_backdrop_set_fade_fraction(void *pointer, double fraction) {
    if (![NSThread isMainThread] || !pointer || !isfinite(fraction) || fraction < 0 || fraction > 0.5) return 0;
    GMGNProgramBackdropContext *context = (__bridge GMGNProgramBackdropContext *)pointer;
    context.fadeFraction = fraction;
    return 1;
}

int gmgn_gpui_program_backdrop_destroy(void *pointer) {
    if (![NSThread isMainThread] || !pointer) return 0;
    GMGNProgramBackdropContext *context = (__bridge_transfer GMGNProgramBackdropContext *)pointer;
    [context.root removeFromSuperview]; [context.cards removeAllObjects];
    return 1;
}

int gmgn_gpui_program_backdrop_diagnostics(void *pointer, double values[6]) {
    if (![NSThread isMainThread] || !pointer || !values) return 0;
    GMGNProgramBackdropContext *context = (__bridge GMGNProgramBackdropContext *)pointer;
    values[0] = context.cards.count;
    values[1] = context.root.window != nil;
    values[2] = context.root.hidden;
    values[3] = context.cards.count ? context.cards[0].blendingMode == NSVisualEffectBlendingModeWithinWindow : 0;
    values[4] = context.root.layer.mask != nil;
    values[5] = [context.root hitTest:NSMakePoint(1, 1)] == nil;
    return 1;
}
