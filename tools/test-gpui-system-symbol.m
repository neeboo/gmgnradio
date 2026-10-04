#import <AppKit/AppKit.h>
#include "../apps/gpui-app/native/system_symbol.h"
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        for (const char **name=(const char*[]){"circle.hexagongrid.fill","cube.transparent","bubble.left.fill","bubble.left",NULL}; *name; name++) {
          for (int tint=0;tint<3;tint++) {
            int width=0,height=0;
            unsigned char *data=gmgn_system_symbol_rgba(*name,tint,&width,&height);
            NSImage *reference=[[NSImage imageWithSystemSymbolName:[NSString stringWithUTF8String:*name] accessibilityDescription:nil]
                imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold]];
            NSCAssert(data && width==(int)ceil(reference.size.width*2) && height==(int)ceil(reference.size.height*2), @"original 12pt semibold Retina dimensions");
            int visible=0;
            unsigned int expected=tint==1 ? gmgn_system_color_rgba(1) : tint==2 ? 0xffffffb8 : 0x7af2ffff;
            for(int i=0;i<width*height;i++) {
                visible+=data[i*4+3]>0;
                NSCAssert(data[i*4]==(expected>>24) && data[i*4+1]==((expected>>16)&255)
                    && data[i*4+2]==((expected>>8)&255) && data[i*4+3]<=(expected&255), @"RGBA tint and alpha coverage");
            }
            NSCAssert(visible>0,@"real symbol contains visible pixels");
            printf("PASS: %s tint=%d %dx%d visible=%d\n",*name,tint,width,height,visible);
            gmgn_system_symbol_free(data);
          }
        }
        int width=1,height=1;
        NSCAssert(gmgn_system_symbol_rgba("gmgn.invalid.symbol",0,&width,&height)==NULL && width==0 && height==0,@"invalid symbol is explicit null");
        puts("PASS: four actual NSImage symbols across three tints, exact Retina dimensions, nonempty alpha and invalid symbol");
    }
}
