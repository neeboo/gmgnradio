#import <AppKit/AppKit.h>
#include "system_symbol.h"
unsigned int gmgn_system_color_rgba(int color) {
    NSColor *c = [(color == 1 ? NSColor.systemCyanColor : NSColor.systemBlueColor) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return ((unsigned int)round(c.redComponent*255)<<24)|((unsigned int)round(c.greenComponent*255)<<16)|((unsigned int)round(c.blueComponent*255)<<8)|255;
}
unsigned char *gmgn_system_symbol_rgba(const char *name, int tint, int *width, int *height) {
    if (!name || !width || !height || ![NSThread isMainThread]) return NULL;
    *width = 0; *height = 0;
    NSImage *image = [[NSImage imageWithSystemSymbolName:[NSString stringWithUTF8String:name]
        accessibilityDescription:nil] imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold]];
    if (!image) return NULL;
    image.template = NO;
    int w = (int)ceil(image.size.width * 2), h = (int)ceil(image.size.height * 2);
    // AppKit cannot create a drawing CGContext for a nonpremultiplied bitmap.
    // Draw into its supported premultiplied format, then export tint + coverage as RGBA.
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bitmapFormat:0 bytesPerRow:w*4 bitsPerPixel:32];
    if (!bitmap) return NULL;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    if (!context) { [NSGraphicsContext restoreGraphicsState]; return NULL; }
    [NSGraphicsContext setCurrentContext:context];
    [image drawInRect:NSMakeRect(0,0,w,h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [NSGraphicsContext.currentContext flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
    unsigned char *result = malloc(w*h*4);
    if (!result) return NULL;
    unsigned int color = tint == 1 ? gmgn_system_color_rgba(1) : tint == 2 ? 0xffffffb8 : 0x7af2ffff;
    BOOL visible = NO;
    for (int y=0;y<h;y++) for(int x=0;x<w;x++) {
        NSColor *c = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        size_t i = (y*w+x)*4;
        result[i]=color>>24; result[i+1]=(color>>16)&255; result[i+2]=(color>>8)&255; result[i+3]=(unsigned char)round(c.alphaComponent*(color&255));
        visible |= result[i+3] != 0;
    }
    if (!visible) { free(result); return NULL; }
    *width=w; *height=h; return result;
}
void gmgn_system_symbol_free(void *data) { free(data); }
