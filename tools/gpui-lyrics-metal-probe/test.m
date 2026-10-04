#import "lyrics_layer.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <assert.h>
#include <math.h>
int main(void){@autoreleasepool{
    [NSApplication sharedApplication];
    NSWindow*w=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,128,96) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.backgroundColor=NSColor.clearColor;w.opaque=NO;
    NSView*scene=[[NSView alloc]initWithFrame:w.contentView.bounds];scene.wantsLayer=YES;scene.layer.backgroundColor=NSColor.greenColor.CGColor;[w.contentView addSubview:scene];
    NSView*gpui=[[NSView alloc]initWithFrame:w.contentView.bounds];gpui.wantsLayer=YES;gpui.layer.opaque=NO;[w.contentView addSubview:gpui];
    void*c=gmgn_lyrics_layer_create((__bridge void*)gpui);assert(c);
    assert(gmgn_lyrics_layer_capture(c,1));
    NSView*layer=w.contentView.subviews[1];assert(w.contentView.subviews[0]==scene&&w.contentView.subviews[2]==gpui);assert(!layer.isOpaque&&[layer hitTest:NSMakePoint(40,40)]==nil);
    uint8_t atlas[16*16*4]={0};for(int y=4;y<12;y++)for(int x=4;x<12;x++){size_t i=(y*16+x)*4;atlas[i]=255;atlas[i+3]=255;}
    assert(gmgn_lyrics_layer_atlas(c,1,16,16,atlas,sizeof(atlas)));assert(!gmgn_lyrics_layer_atlas(c,2,4097,1,atlas,sizeof(atlas)));
    GMGNLyricsGlyph g={.atlas_id=1,.width=32,.height=32,.matrix={1,0,32,0,1,24,0,0,1},.uv={0,0,1,1},.rgba={1,1,1,0.5}};
    double glow[4]={0,0,1,0};assert(gmgn_lyrics_layer_render(c,&g,1,1,0,glow));
    uint8_t pixels[128*96*4];uint32_t width=0,height=0;assert(gmgn_lyrics_layer_readback(c,pixels,sizeof(pixels),&width,&height));assert(width==128&&height==96);size_t center=(40*128+48)*4;assert(abs(pixels[center]-128)<=1&&abs(pixels[center+3]-128)<=1);assert(pixels[3]==0);
    uint8_t presented[sizeof(pixels)];assert(gmgn_lyrics_layer_readback_presented(c,presented,sizeof(presented)));assert(presented[3]==0&&abs(presented[center+3]-128)<=1&&abs(presented[center+2]-128)<=1);
    glow[3]=1;assert(gmgn_lyrics_layer_render(c,&g,1,1,2,glow));assert(gmgn_lyrics_layer_readback(c,pixels,sizeof(pixels),&width,&height));size_t outside=(40*128+38)*4;assert(pixels[outside+2]>0&&pixels[outside+3]>0&&pixels[3]==0);
    glow[3]=0;assert(gmgn_lyrics_layer_render_effects(c,&g,1,1,2,glow,1));assert(gmgn_lyrics_layer_readback(c,pixels,sizeof(pixels),&width,&height));assert(pixels[outside]>0&&pixels[outside+2]==0);assert(!gmgn_lyrics_layer_render_effects(c,&g,1,1,2,glow,NAN));
    uint8_t white[4]={255,255,255,255};assert(gmgn_lyrics_layer_atlas(c,2,1,1,white,sizeof(white)));assert(gmgn_lyrics_layer_has_atlas(c,2,1,1));assert(!gmgn_lyrics_layer_has_atlas(c,2,2,1));
    GMGNLyricsGlyph red=g,blue=g;red.atlas_id=2;blue.atlas_id=2;red.rgba[0]=1;red.rgba[1]=red.rgba[2]=0;red.rgba[3]=1;blue.rgba[0]=blue.rgba[1]=0;blue.rgba[2]=1;blue.rgba[3]=0.5;
    GMGNLyricsBatch tree[3]={{.opacity=0.5,.parent_index=-1},{.glyphs=&red,.count=1,.opacity=1,.parent_index=0},{.glyphs=&blue,.count=1,.opacity=1,.parent_index=0}};
    assert(gmgn_lyrics_layer_render_frame(c,tree,3,1));assert(gmgn_lyrics_layer_readback(c,pixels,sizeof(pixels),&width,&height));fprintf(stderr,"nested_pixel=%u,%u,%u,%u\n",pixels[center],pixels[center+1],pixels[center+2],pixels[center+3]);assert(abs(pixels[center]-64)<=1&&abs(pixels[center+2]-64)<=1&&abs(pixels[center+3]-128)<=1);
    uint8_t saved[sizeof(pixels)];memcpy(saved,pixels,sizeof(pixels));tree[2].parent_index=2;assert(!gmgn_lyrics_layer_render_frame(c,tree,3,1));assert(gmgn_lyrics_layer_readback(c,pixels,sizeof(pixels),&width,&height));assert(memcmp(saved,pixels,sizeof(pixels))==0);tree[2].parent_index=0;
    tree[0].sigma=2;tree[0].glow[1]=tree[0].glow[3]=1;assert(gmgn_lyrics_layer_render_frame(c,tree,3,1));assert(gmgn_lyrics_layer_readback(c,pixels,sizeof(pixels),&width,&height));assert(pixels[(23*128+48)*4+1]>0);
    g.matrix[6]=0.004;assert(gmgn_lyrics_layer_render(c,&g,1,2,2,glow));uint8_t *retina=malloc(256*192*4);assert(gmgn_lyrics_layer_readback(c,retina,256*192*4,&width,&height));assert(width==256&&height==192);free(retina);
    g.matrix[8]=-1;assert(!gmgn_lyrics_layer_render(c,&g,1,1,0,glow));
    for(uint64_t id=2;id<=18;id++)assert(gmgn_lyrics_layer_atlas(c,id,16,16,atlas,sizeof(atlas)));g.matrix[8]=1;assert(!gmgn_lyrics_layer_render(c,&g,1,1,0,glow));g.atlas_id=18;assert(gmgn_lyrics_layer_render(c,&g,1,1,0,glow));
    assert(gmgn_lyrics_layer_readback_presented(c,presented,sizeof(presented)));
    assert(gmgn_lyrics_layer_render_effects(c,&g,1,1,88,glow,1));assert(gmgn_lyrics_layer_readback_presented(c,presented,sizeof(presented)));
    GMGNLyricsBatch deep[17]={0};for(int i=0;i<16;i++){deep[i].parent_index=i-1;deep[i].opacity=0.99;}
    deep[8].glyphs=&g;deep[8].count=1;assert(gmgn_lyrics_layer_render_frame(c,deep,9,1));assert(gmgn_lyrics_layer_readback_presented(c,presented,sizeof(presented)));deep[8].glyphs=NULL;deep[8].count=0;deep[15].glyphs=&g;deep[15].count=1;assert(gmgn_lyrics_layer_render_frame(c,deep,16,1));assert(gmgn_lyrics_layer_readback_presented(c,presented,sizeof(presented)));size_t visible=0;for(size_t i=3;i<sizeof(presented);i+=4)visible+=presented[i]>0;assert(visible>0);deep[16].parent_index=15;deep[16].opacity=1;assert(!gmgn_lyrics_layer_render_frame(c,deep,17,1));
    gpui.frame=NSMakeRect(0,0,2400,1500);assert(gmgn_lyrics_layer_render_frame(c,NULL,0,2));assert(gmgn_lyrics_layer_dimensions(c,&width,&height));assert((uint64_t)width*height<=4194304&&width<4800&&height<3000);uint8_t*large=malloc((size_t)width*height*4);assert(gmgn_lyrics_layer_readback_presented(c,large,(size_t)width*height*4));assert(large[3]==0);fprintf(stderr,"fullscreen_budget width=%u height=%u sigma88=true\n",width,height);free(large);
    assert(gmgn_lyrics_layer_render_frame(c,deep,16,2));assert(gmgn_lyrics_layer_dimensions(c,&width,&height));assert((uint64_t)width*height*4*21<=256*1024*1024);large=malloc((size_t)width*height*4);assert(gmgn_lyrics_layer_readback_presented(c,large,(size_t)width*height*4));free(large);fprintf(stderr,"nested_depth9=true nested_depth16=true depth17_rejected=true full_depth16_budget=%ux%u\n",width,height);
    assert(gmgn_lyrics_layer_clear(c)&&layer.hidden);assert(!gmgn_lyrics_layer_render(c,&g,1,1,0,glow));
    NSDate*deadline=[NSDate dateWithTimeIntervalSinceNow:0.1];while(deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];assert(layer.hidden);
    assert(gmgn_lyrics_layer_render_frame(c,NULL,0,1));assert(gmgn_lyrics_layer_destroy(c));assert(w.contentView.subviews.count==2);
    deadline=[NSDate dateWithTimeIntervalSinceNow:0.2];while(deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];assert(w.contentView.subviews.count==2);
    fprintf(stderr,"LYRICS_METAL_TEST gpu_pixels=true premultiplied_alpha=true glow=true perspective=true scale=true passive=true lifecycle=true product_acceptance=false\n");
}return 0;}
