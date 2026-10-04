#import "lyrics_layer.h"
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#include <math.h>

static NSString *const shader = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V{float4 p;float2 uv;float4 color;};struct O{float4 p[[position]];float2 uv;float4 color;};"
"vertex O vertex_main(uint i[[vertex_id]],constant V*v[[buffer(0)]]){return {v[i].p,v[i].uv,v[i].color};}"
"fragment float4 fragment_main(O o[[stage_in]],texture2d<float> t[[texture(0)]]){constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);float4 c=t.sample(s,o.uv);float a=c.a*o.color.a;return float4(c.rgb*o.color.rgb*o.color.a,a);}"
"struct B{float sigma;uint axis;uint width;uint height;uint4 roi;};"
"kernel void blur_main(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant B&b[[buffer(0)]],uint2 p[[thread_position_in_grid]]){p+=b.roi.xy;if(p.x>=b.roi.z||p.y>=b.roi.w)return; if(b.sigma<=0){dst.write(src.read(p),p);return;}int r=min(384,int(ceil(b.sigma*3)));float4 c=0;float total=0;for(int k=-r;k<=r;k++){float w=exp(-float(k*k)/(2*b.sigma*b.sigma));int2 q=int2(p)+(b.axis==0?int2(k,0):int2(0,k));if(q.x>=int(b.roi.x)&&q.y>=int(b.roi.y)&&q.x<int(b.roi.z)&&q.y<int(b.roi.w))c+=src.read(uint2(q))*w;total+=w;}dst.write(c/total,p);}"
"struct E{float4 glow;float blur_mix;uint4 roi;};kernel void composite_main(texture2d<float,access::read> sharp[[texture(0)]],texture2d<float,access::read> blurred[[texture(1)]],texture2d<float,access::write> dst[[texture(2)]],constant E&e[[buffer(0)]],uint2 p[[thread_position_in_grid]]){p+=e.roi.xy;if(p.x>=e.roi.z||p.y>=e.roi.w)return;float4 s=mix(sharp.read(p),blurred.read(p),e.blur_mix);float a=blurred.read(p).a*e.glow.a;float4 g=float4(e.glow.rgb*a,a);dst.write(s+g*(1-s.a),p);}"
"fragment float4 display_main(O o[[stage_in]],texture2d<float> t[[texture(0)]]){constexpr sampler s(coord::normalized,filter::linear);return t.sample(s,o.uv)*o.color.a;}"
;
typedef struct { simd_float4 p; simd_float2 uv; simd_float4 color; } Vertex;
typedef struct { float sigma; uint32_t axis,width,height; simd_uint4 roi; } Blur;
typedef struct { simd_float4 glow; float blur_mix; simd_uint4 roi; } Effects;
typedef struct { double left,top,right,bottom; } ROI;
@interface GMGNLyricsView:NSView @end
@implementation GMGNLyricsView
- (BOOL)isFlipped{return YES;}
- (BOOL)isOpaque{return NO;}
- (NSView *)hitTest:(NSPoint)p{(void)p;return nil;}
@end
@interface GMGNLyricsContext:NSObject
@property(nonatomic,weak) NSView *gpui;
@property(nonatomic,strong) GMGNLyricsView *view;
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) id<MTLRenderPipelineState> glyphPipeline;
@property(nonatomic,strong) id<MTLRenderPipelineState> displayPipeline;
@property(nonatomic,strong) id<MTLRenderPipelineState> accumulationPipeline;
@property(nonatomic,strong) id<MTLComputePipelineState> blurPipeline;
@property(nonatomic,strong) id<MTLComputePipelineState> compositePipeline;
@property(nonatomic,strong) NSMutableDictionary<NSNumber*,id<MTLTexture>> *atlases;
@property(nonatomic,strong) NSMutableArray<NSNumber*> *order;
@property(nonatomic,strong) NSArray<id<MTLTexture>> *targets;
@property(nonatomic) NSUInteger atlasBytes;
@property(nonatomic,strong) id<MTLCommandBuffer> lastBuffer;
@property(nonatomic,strong) dispatch_semaphore_t inflight;
@property(nonatomic) BOOL capture;
@property(nonatomic,strong) id<MTLTexture> presentation;
@property(nonatomic) BOOL roiEnabled;
@property(nonatomic) double effectScale;
@property(nonatomic,strong) dispatch_queue_t presentationQueue;
@property(nonatomic) BOOL presentationPending;
@end
@implementation GMGNLyricsContext @end
static id<MTLRenderPipelineState> pipeline(id<MTLDevice>d,id<MTLLibrary>l,NSString*f,MTLPixelFormat format){
    MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new];p.vertexFunction=[l newFunctionWithName:@"vertex_main"];p.fragmentFunction=[l newFunctionWithName:f];p.colorAttachments[0].pixelFormat=format;
    p.colorAttachments[0].blendingEnabled=YES;p.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorOne;p.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;p.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;p.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    return [d newRenderPipelineStateWithDescriptor:p error:nil];
}
void *gmgn_lyrics_layer_create(void *pointer){
    if(!NSThread.isMainThread||!pointer)return NULL;NSView *gpui=(__bridge NSView*)pointer;
    if(!gpui.window||gpui.superview!=gpui.window.contentView)return NULL;
    GMGNLyricsContext *c=[GMGNLyricsContext new];c.device=MTLCreateSystemDefaultDevice();if(!c.device)return NULL;
    NSError *error=nil;id<MTLLibrary> lib=[c.device newLibraryWithSource:shader options:nil error:&error];if(!lib)return NULL;
    c.glyphPipeline=pipeline(c.device,lib,@"fragment_main",MTLPixelFormatRGBA8Unorm);c.displayPipeline=pipeline(c.device,lib,@"display_main",MTLPixelFormatBGRA8Unorm);
    c.accumulationPipeline=pipeline(c.device,lib,@"display_main",MTLPixelFormatRGBA8Unorm);
    c.blurPipeline=[c.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"blur_main"] error:nil];c.compositePipeline=[c.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"composite_main"] error:nil];
    if(!c.glyphPipeline||!c.displayPipeline||!c.accumulationPipeline||!c.blurPipeline||!c.compositePipeline)return NULL;
    c.queue=[c.device newCommandQueue];c.presentationQueue=dispatch_queue_create("ai.gmgn.lyrics.drawable",DISPATCH_QUEUE_SERIAL);c.roiEnabled=YES;c.inflight=dispatch_semaphore_create(2);c.atlases=[NSMutableDictionary new];c.order=[NSMutableArray new];c.gpui=gpui;
    c.view=[[GMGNLyricsView alloc]initWithFrame:gpui.frame];c.view.wantsLayer=YES;CAMetalLayer *layer=[CAMetalLayer layer];layer.device=c.device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.opaque=NO;layer.framebufferOnly=YES;c.view.layer=layer;c.view.hidden=YES;c.view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [gpui.superview addSubview:c.view positioned:NSWindowBelow relativeTo:gpui];return (__bridge_retained void*)c;
}
int gmgn_lyrics_layer_atlas(void *pointer,uint64_t identifier,uint32_t w,uint32_t h,const uint8_t *pixels,size_t bytes){
    if(!NSThread.isMainThread||!pointer||!pixels||!w||!h||w>4096||h>4096||bytes!=(size_t)w*h*4||bytes>16*1024*1024)return 0;
    GMGNLyricsContext*c=(__bridge GMGNLyricsContext*)pointer;NSNumber *key=@(identifier);id<MTLTexture>old=c.atlases[key];NSUInteger oldBytes=old.width*old.height*4;
    while(c.order.count&&(c.order.count>=16||c.atlasBytes-oldBytes+bytes>64*1024*1024)){NSNumber*k=c.order.firstObject;if([k isEqual:key]){[c.order removeObjectAtIndex:0];continue;}id<MTLTexture>t=c.atlases[k];c.atlasBytes-=t.width*t.height*4;[c.atlases removeObjectForKey:k];[c.order removeObjectAtIndex:0];}
    MTLTextureDescriptor*d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];d.usage=MTLTextureUsageShaderRead;d.storageMode=MTLStorageModeShared;id<MTLTexture>t=[c.device newTextureWithDescriptor:d];if(!t)return 0;
    uint8_t*premultiplied=malloc(bytes);if(!premultiplied)return 0;for(size_t i=0;i<bytes;i+=4){for(size_t channel=0;channel<3;channel++)premultiplied[i+channel]=(uint8_t)(((unsigned)pixels[i+channel]*pixels[i+3]+127)/255);premultiplied[i+3]=pixels[i+3];}
    [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:premultiplied bytesPerRow:w*4];free(premultiplied);c.atlasBytes=c.atlasBytes-oldBytes+bytes;c.atlases[key]=t;[c.order removeObject:key];[c.order addObject:key];return 1;
}
static void vertices(Vertex out[6],const GMGNLyricsGlyph *g,double w,double h){
    const int xy[6][2]={{0,0},{1,0},{0,1},{1,0},{1,1},{0,1}};
    for(int i=0;i<6;i++){double x=xy[i][0]*g->width,y=xy[i][1]*g->height;const double*m=g->matrix;double X=m[0]*x+m[1]*y+m[2],Y=m[3]*x+m[4]*y+m[5],W=m[6]*x+m[7]*y+m[8];out[i].p=(simd_float4){(float)(2*X/w-W),(float)(W-2*Y/h),0,(float)W};out[i].uv=(simd_float2){g->uv[0]+xy[i][0]*g->uv[2],g->uv[1]+xy[i][1]*g->uv[3]};out[i].color=(simd_float4){g->rgba[0],g->rgba[1],g->rgba[2],g->rgba[3]};}
}
static void compute(id<MTLCommandBuffer>b,id<MTLComputePipelineState>p,NSArray<id<MTLTexture>>*textures,const void*data,size_t size,NSUInteger w,NSUInteger h){id<MTLComputeCommandEncoder>e=[b computeCommandEncoder];[e setComputePipelineState:p];for(NSUInteger i=0;i<textures.count;i++)[e setTexture:textures[i] atIndex:i];[e setBytes:data length:size atIndex:0];[e dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[e endEncoding];}
static MTLRenderPassDescriptor *pass(id<MTLTexture>t,BOOL clear){MTLRenderPassDescriptor*r=[MTLRenderPassDescriptor new];r.colorAttachments[0].texture=t;r.colorAttachments[0].loadAction=clear?MTLLoadActionClear:MTLLoadActionLoad;r.colorAttachments[0].storeAction=MTLStoreActionStore;r.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);return r;}
static void appendTexture(GMGNLyricsContext*c,id<MTLCommandBuffer>b,id<MTLTexture>source,id<MTLTexture>target,double opacity){
    id<MTLRenderCommandEncoder>e=[b renderCommandEncoderWithDescriptor:pass(target,NO)];[e setRenderPipelineState:c.accumulationPipeline];
    GMGNLyricsGlyph g={.width=c.view.bounds.size.width,.height=c.view.bounds.size.height,.matrix={1,0,0,0,1,0,0,0,1},.uv={0,0,1,1},.rgba={1,1,1,opacity}};Vertex v[6];vertices(v,&g,g.width,g.height);[e setVertexBytes:v length:sizeof(v) atIndex:0];[e setFragmentTexture:source atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];[e endEncoding];
}
static void displayTexture(GMGNLyricsContext*c,id<MTLCommandBuffer>b,id<MTLTexture>target){
    // All presentation targets must start with alpha zero. Metal's descriptor
    // default clearColor is black with alpha ONE and would hide SceneKit.
    id<MTLRenderCommandEncoder>e=[b renderCommandEncoderWithDescriptor:pass(target,YES)];[e setRenderPipelineState:c.displayPipeline];
    GMGNLyricsGlyph g={.width=c.view.bounds.size.width,.height=c.view.bounds.size.height,.matrix={1,0,0,0,1,0,0,0,1},.uv={0,0,1,1},.rgba={1,1,1,1}};Vertex v[6];vertices(v,&g,g.width,g.height);[e setVertexBytes:v length:sizeof(v) atIndex:0];[e setFragmentTexture:c.targets[4] atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];[e endEncoding];
}
static void requestPresentation(GMGNLyricsContext*c){
    if(c.presentationPending||c.view.hidden||c.targets.count<5)return;
    c.presentationPending=YES;CAMetalLayer*layer=(CAMetalLayer*)c.view.layer;__weak GMGNLyricsContext*weak=c;
    // nextDrawable can wait for the compositor/GPU. Never call it on the App
    // event loop. One outstanding request, then present the latest complete
    // canvas on the same command queue; hidden/destroyed contexts discard it.
    dispatch_async(c.presentationQueue,^{id<CAMetalDrawable>drawable=[layer nextDrawable];dispatch_async(dispatch_get_main_queue(),^{GMGNLyricsContext*live=weak;if(!live)return;live.presentationPending=NO;if(!drawable||live.view.hidden||!live.view.superview||live.targets.count<5)return;
        if(drawable.texture.width!=live.targets[4].width||drawable.texture.height!=live.targets[4].height){requestPresentation(live);return;}
        id<MTLCommandBuffer>b=[live.queue commandBuffer];displayTexture(live,b,drawable.texture);[b presentDrawable:drawable];[b commit];
    });});
}
static ROI mergeROI(ROI a,ROI b){return (ROI){MIN(a.left,b.left),MIN(a.top,b.top),MAX(a.right,b.right),MAX(a.bottom,b.bottom)};}
static ROI renderNode(GMGNLyricsContext*c,id<MTLCommandBuffer>b,const GMGNLyricsBatch*batches,size_t count,size_t index,size_t depth){
    ROI region={INFINITY,INFINITY,-INFINITY,-INFINITY};
    if(batches[index].opacity==0)return region;
    const GMGNLyricsBatch*batch=&batches[index];BOOL direct=batch->opacity==1&&batch->sigma==0&&batch->glow[3]==0&&batch->blur_mix==0;id<MTLTexture>target=c.targets[4+depth-(direct?1:0)];id<MTLRenderCommandEncoder>e=[b renderCommandEncoderWithDescriptor:pass(target,!direct)];[e setRenderPipelineState:c.glyphPipeline];
    for(size_t i=0;i<batch->count;i++){const GMGNLyricsGlyph*g=&batch->glyphs[i];Vertex v[6];vertices(v,g,c.view.bounds.size.width,c.view.bounds.size.height);[e setVertexBytes:v length:sizeof(v) atIndex:0];[e setFragmentTexture:c.atlases[@(g->atlas_id)] atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];if(g->rgba[3]>0){for(int y=0;y<2;y++)for(int x=0;x<2;x++){const double*m=g->matrix;double X=x*g->width,Y=y*g->height,W=m[6]*X+m[7]*Y+m[8];double px=(m[0]*X+m[1]*Y+m[2])/W*target.width/c.view.bounds.size.width,py=(m[3]*X+m[4]*Y+m[5])/W*target.height/c.view.bounds.size.height;region=mergeROI(region,(ROI){px,py,px,py});}}}[e endEncoding];
    for(size_t child=index+1;child<count;child++)if(batches[child].parent_index==(int64_t)index)region=mergeROI(region,renderNode(c,b,batches,count,child,depth+(direct?0:1)));
    if(direct)return region;
    id<MTLTexture>source=target;NSUInteger w=target.width,h=target.height;
    if(region.right<region.left||region.bottom<region.top)return region;
    float sigma=(float)(batch->sigma*c.effectScale);
    double radius=ceil(sigma*3)+2;
    region=(ROI){MAX(0.,floor(region.left)-radius),MAX(0.,floor(region.top)-radius),MIN((double)w,ceil(region.right)+radius),MIN((double)h,ceil(region.bottom)+radius)};
    if(region.right<=region.left||region.bottom<=region.top)return (ROI){INFINITY,INFINITY,-INFINITY,-INFINITY};
    simd_uint4 roi=c.roiEnabled?(simd_uint4){region.left,region.top,region.right,region.bottom}:(simd_uint4){0,0,w,h};
    NSUInteger dispatchW=roi.z-roi.x,dispatchH=roi.w-roi.y;
    if(batch->sigma>0){Blur blur={.sigma=sigma,.axis=0,.width=(uint32_t)w,.height=(uint32_t)h,.roi=roi};compute(b,c.blurPipeline,@[target,c.targets[1]],&blur,sizeof(blur),dispatchW,dispatchH);blur.axis=1;compute(b,c.blurPipeline,@[c.targets[1],c.targets[2]],&blur,sizeof(blur),dispatchW,dispatchH);}
    if(batch->sigma>0||batch->glow[3]>0||batch->blur_mix>0){id<MTLRenderCommandEncoder>clear=[b renderCommandEncoderWithDescriptor:pass(c.targets[3],YES)];[clear endEncoding];Effects effects={.glow={batch->glow[0],batch->glow[1],batch->glow[2],batch->glow[3]},.blur_mix=(float)batch->blur_mix,.roi=roi};compute(b,c.compositePipeline,@[target,batch->sigma>0?c.targets[2]:target,c.targets[3]],&effects,sizeof(effects),dispatchW,dispatchH);source=c.targets[3];}
    appendTexture(c,b,source,c.targets[4+depth-1],batch->opacity);
    return region;
}
int gmgn_lyrics_layer_render_frame(void *pointer,const GMGNLyricsBatch*batches,size_t batch_count,double scale){
    if(!NSThread.isMainThread||!pointer||(batch_count&&!batches)||batch_count>256||!isfinite(scale)||scale<=0||scale>4)return 0;
    GMGNLyricsContext*c=(__bridge GMGNLyricsContext*)pointer;if(!c.gpui.window||c.view.superview!=c.gpui.superview)return 0;
    size_t total=0,maxdepth=0;size_t depths[256]={0};
    for(size_t k=0;k<batch_count;k++){const GMGNLyricsBatch*batch=&batches[k];if(batch->parent_index < -1 || batch->parent_index >=(int64_t)k)return 0;depths[k]=batch->parent_index==-1?1:depths[batch->parent_index]+1;if(depths[k]>16)return 0;maxdepth=MAX(maxdepth,depths[k]);if((batch->count&&!batch->glyphs)||batch->count>4096||total>4096-batch->count||!isfinite(batch->sigma)||batch->sigma<0||batch->sigma>128||!isfinite(batch->blur_mix)||batch->blur_mix<0||batch->blur_mix>1||!isfinite(batch->opacity)||batch->opacity<0||batch->opacity>1)return 0;total+=batch->count;
    for(int j=0;j<4;j++)if(!isfinite(batch->glow[j])||batch->glow[j]<0||batch->glow[j]>1)return 0;
    for(size_t i=0;i<batch->count;i++){const GMGNLyricsGlyph*g=&batch->glyphs[i];if(!isfinite(g->width)||!isfinite(g->height)||g->width<=0||g->height<=0||!c.atlases[@(g->atlas_id)])return 0;for(int j=0;j<9;j++)if(!isfinite(g->matrix[j]))return 0;for(int j=0;j<4;j++)if(!isfinite(g->uv[j])||!isfinite(g->rgba[j])||g->rgba[j]<0||g->rgba[j]>1)return 0;for(int y=0;y<2;y++)for(int x=0;x<2;x++)if(g->matrix[6]*x*g->width+g->matrix[7]*y*g->height+g->matrix[8]<=1e-8)return 0;}}
    c.view.frame=c.gpui.frame;double logicalW=c.view.bounds.size.width,logicalH=c.view.bounds.size.height;if(!isfinite(logicalW)||!isfinite(logicalH)||logicalW<=0||logicalH<=0)return 0;
    NSUInteger targetCount=5+maxdepth;double budget=MIN(4194304.,floor(256.*1024*1024/(4*targetCount)));double effectiveScale=scale;NSUInteger w=ceil(logicalW*scale),h=ceil(logicalH*scale);
    if((double)w*h>budget){effectiveScale=sqrt(budget/(logicalW*logicalH));w=floor(logicalW*effectiveScale);h=floor(logicalH*effectiveScale);}if(!w||!h)return 0;c.effectScale=effectiveScale/scale;
    if(dispatch_semaphore_wait(c.inflight,DISPATCH_TIME_NOW)!=0)return 0;
    BOOL sameSize=c.targets.count&&c.targets[0].width==w&&c.targets[0].height==h;
    if(!sameSize||c.targets.count<targetCount){NSMutableArray*a=sameSize?[c.targets mutableCopy]:[NSMutableArray new];for(NSUInteger i=a.count;i<targetCount;i++){MTLTextureDescriptor*d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget;d.storageMode=MTLStorageModeShared;id<MTLTexture>t=[c.device newTextureWithDescriptor:d];if(!t){dispatch_semaphore_signal(c.inflight);return 0;}[a addObject:t];}c.targets=a;}
    dispatch_semaphore_t inflight=c.inflight;
    id<MTLCommandBuffer>b=[c.queue commandBuffer];[b addCompletedHandler:^(id<MTLCommandBuffer>done){(void)done;dispatch_semaphore_signal(inflight);}];
    MTLRenderPassDescriptor*r=[MTLRenderPassDescriptor new];r.colorAttachments[0].texture=c.targets[4];r.colorAttachments[0].loadAction=MTLLoadActionClear;r.colorAttachments[0].storeAction=MTLStoreActionStore;r.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);id<MTLRenderCommandEncoder>clear=[b renderCommandEncoderWithDescriptor:r];[clear endEncoding];
    for(size_t k=0;k<batch_count;k++)if(batches[k].parent_index==-1)renderNode(c,b,batches,batch_count,k,1);
    CAMetalLayer*layer=(CAMetalLayer*)c.view.layer;layer.contentsScale=effectiveScale;layer.drawableSize=CGSizeMake(w,h);c.view.hidden=NO;
    if(c.capture){if(!c.presentation||c.presentation.width!=w||c.presentation.height!=h){MTLTextureDescriptor*d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget;c.presentation=[c.device newTextureWithDescriptor:d];}if(c.presentation)displayTexture(c,b,c.presentation);}
    c.lastBuffer=b;[b commit];requestPresentation(c);return 1;
}
int gmgn_lyrics_layer_readback(void*pointer,uint8_t*pixels,size_t bytes,uint32_t*w,uint32_t*h){if(!NSThread.isMainThread||!pointer||!pixels||!w||!h)return 0;GMGNLyricsContext*c=(__bridge GMGNLyricsContext*)pointer;if(c.targets.count<5)return 0;[c.lastBuffer waitUntilCompleted];if(c.lastBuffer.status!=MTLCommandBufferStatusCompleted)return 0;id<MTLTexture>t=c.targets[4];if(bytes!=t.width*t.height*4)return 0;[t getBytes:pixels bytesPerRow:t.width*4 fromRegion:MTLRegionMake2D(0,0,t.width,t.height) mipmapLevel:0];*w=(uint32_t)t.width;*h=(uint32_t)t.height;return 1;}
int gmgn_lyrics_layer_render_effects(void*p,const GMGNLyricsGlyph*g,size_t n,double scale,double sigma,const double glow[4],double mix){if(!glow)return 0;GMGNLyricsBatch batch={.glyphs=g,.count=n,.sigma=sigma,.blur_mix=mix,.glow={glow[0],glow[1],glow[2],glow[3]},.opacity=1,.parent_index=-1};return gmgn_lyrics_layer_render_frame(p,&batch,1,scale);}
int gmgn_lyrics_layer_has_atlas(void*p,uint64_t identifier,uint32_t w,uint32_t h){if(!NSThread.isMainThread||!p)return 0;GMGNLyricsContext*c=(__bridge GMGNLyricsContext*)p;NSNumber*key=@(identifier);id<MTLTexture>t=c.atlases[key];if(!t||t.width!=w||t.height!=h)return 0;[c.order removeObject:key];[c.order addObject:key];return 1;}
int gmgn_lyrics_layer_render(void*p,const GMGNLyricsGlyph*g,size_t n,double scale,double sigma,const double glow[4]){return gmgn_lyrics_layer_render_effects(p,g,n,scale,sigma,glow,0);}
int gmgn_lyrics_layer_capture(void*p,int enabled){if(!NSThread.isMainThread||!p)return 0;GMGNLyricsContext*c=(__bridge GMGNLyricsContext*)p;c.capture=enabled!=0;if(!enabled)c.presentation=nil;return 1;}
int gmgn_lyrics_layer_set_roi(void*p,int enabled){if(!NSThread.isMainThread||!p)return 0;GMGNLyricsContext*c=(__bridge GMGNLyricsContext*)p;c.roiEnabled=enabled!=0;return 1;}
int gmgn_lyrics_layer_dimensions(void*p,uint32_t*w,uint32_t*h){if(!NSThread.isMainThread||!p||!w||!h)return 0;GMGNLyricsContext*c=(__bridge GMGNLyricsContext*)p;if(c.targets.count<5)return 0;*w=(uint32_t)c.targets[4].width;*h=(uint32_t)c.targets[4].height;return 1;}
int gmgn_lyrics_layer_readback_presented(void*p,uint8_t*bytes,size_t n){if(!NSThread.isMainThread||!p||!bytes)return 0;GMGNLyricsContext*c=(__bridge GMGNLyricsContext*)p;if(!c.presentation||n!=c.presentation.width*c.presentation.height*4)return 0;[c.lastBuffer waitUntilCompleted];if(c.lastBuffer.status!=MTLCommandBufferStatusCompleted)return 0;[c.presentation getBytes:bytes bytesPerRow:c.presentation.width*4 fromRegion:MTLRegionMake2D(0,0,c.presentation.width,c.presentation.height) mipmapLevel:0];return 1;}
int gmgn_lyrics_layer_clear(void*pointer){if(!NSThread.isMainThread||!pointer)return 0;GMGNLyricsContext*c=(__bridge GMGNLyricsContext*)pointer;c.view.hidden=YES;c.targets=nil;c.presentation=nil;[c.atlases removeAllObjects];[c.order removeAllObjects];c.atlasBytes=0;return 1;}
int gmgn_lyrics_layer_destroy(void*pointer){if(!NSThread.isMainThread||!pointer)return 0;GMGNLyricsContext*c=(__bridge_transfer GMGNLyricsContext*)pointer;[c.view removeFromSuperview];return 1;}
