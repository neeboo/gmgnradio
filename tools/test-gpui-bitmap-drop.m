// AppKit adapter unit regression, not a product App/business E2E test.
// Uses a unique pasteboard; never reads the user's general clipboard.
#import "../apps/gpui-app/native/window_surface.m"

@interface BitmapDragProbe : NSObject
@property(nonatomic,strong) NSPasteboard *draggingPasteboard;
@property(nonatomic) NSPoint draggingLocation;
@end
@implementation BitmapDragProbe
@end

int main(void) { @autoreleasepool {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,640,480)];
    BitmapDragProbe *sender = [BitmapDragProbe new];
    sender.draggingPasteboard = [NSPasteboard pasteboardWithUniqueName];
    NSData *bytes = [@"actual drag bitmap" dataUsingEncoding:NSUTF8StringEncoding];
    [sender.draggingPasteboard setData:bytes forType:NSPasteboardTypePNG];
    sender.draggingLocation = NSMakePoint(30,450);
    gmgn_gpui_bitmap_drop_region((__bridge void *)view,10,10,200,100,1);
    NSCAssert(productDrop(view,@selector(performDragOperation:),(id)sender),@"bitmap inside chat");
    char *json = gmgn_gpui_take_bitmap_drop((__bridge void *)view);
    NSDictionary *command = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSCAssert([command[@"op"] isEqual:@"chat.attachments.bitmap"],@"production command");
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:command[@"dataBase64"] options:0];
    NSCAssert([decoded isEqualToData:bytes],@"actual pasteboard bytes");
    gmgn_gpui_bitmap_drop_string_free(json);
    NSCAssert(!gmgn_gpui_take_bitmap_drop((__bridge void *)view),@"queue drains once");
    sender.draggingLocation = NSMakePoint(400,450);
    NSCAssert(!productDrop(view,@selector(performDragOperation:),(id)sender),@"outside chat rejected");
    sender.draggingLocation = NSMakePoint(30,450);
    gmgn_gpui_bitmap_drop_region((__bridge void *)view,10,10,200,100,0);
    NSCAssert(!productDrop(view,@selector(performDragOperation:),(id)sender),@"hidden chat rejected");
    gmgn_gpui_bitmap_drop_region((__bridge void *)view,10,10,200,100,1);
    for (int i=0;i<4;i++) NSCAssert(productDrop(view,@selector(performDragOperation:),(id)sender),@"bounded enqueue");
    NSCAssert(!productDrop(view,@selector(performDragOperation:),(id)sender),@"full queue rejected");
    for (int i=0;i<4;i++) gmgn_gpui_bitmap_drop_string_free(gmgn_gpui_take_bitmap_drop((__bridge void *)view));
    [sender.draggingPasteboard clearContents];
    [sender.draggingPasteboard writeObjects:@[[NSURL fileURLWithPath:@"/tmp/image.png"]]];
    [sender.draggingPasteboard setData:bytes forType:NSPasteboardTypePNG];
    NSCAssert(!bitmapDrag((id)sender),@"file image preserves ExternalPaths");
    [sender.draggingPasteboard releaseGlobally];
    puts("bitmap adapter regression passed");
    return 0;
} }
