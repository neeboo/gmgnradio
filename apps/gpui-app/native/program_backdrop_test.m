// Standalone structural test; never launches the product or reads user data.
#import "program_backdrop.h"
#include <assert.h>
#include <math.h>
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,500)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        NSView *renderer = [[NSView alloc] initWithFrame:window.contentView.bounds];
        NSView *gpui = [[NSView alloc] initWithFrame:window.contentView.bounds];
        [window.contentView addSubview:renderer]; [window.contentView addSubview:gpui];
        size_t originalCount = window.contentView.subviews.count;
        void *context = gmgn_gpui_program_backdrop_create((__bridge void *)gpui);
        assert(context);
        GMGNProgramBackdropCard card = {.width=306,.height=74,.radius=22,.opacity=0.8,.priority=20,
            .matrix={1,0,270, 0,1,120, 0.0002,0,1}};
        double viewport[4]={250,100,340,400};
        assert(gmgn_gpui_program_backdrop_apply(context,&card,1,viewport));
        double values[6]; assert(gmgn_gpui_program_backdrop_diagnostics(context,values));
        assert(values[0]==1 && values[1]==1 && values[2]==0 && values[3]==1 && values[4]==1 && values[5]==1);
        NSArray *siblings=window.contentView.subviews;
        assert([siblings indexOfObject:renderer] < [siblings indexOfObject:gpui]-1);
        card.matrix[0]=NAN;
        assert(!gmgn_gpui_program_backdrop_apply(context,&card,1,viewport));
        assert(gmgn_gpui_program_backdrop_diagnostics(context,values) && values[0]==1);
        __block int offThread=1;
        dispatch_semaphore_t completed=dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{offThread=gmgn_gpui_program_backdrop_clear(context);dispatch_semaphore_signal(completed);});
        assert(dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
        assert(offThread==0);
        assert(gmgn_gpui_program_backdrop_clear(context));
        assert(gmgn_gpui_program_backdrop_diagnostics(context,values) && values[0]==0 && values[2]==1 && values[4]==0);
        assert(gmgn_gpui_program_backdrop_destroy(context));
        assert(window.contentView.subviews.count==originalCount);
        fprintf(stderr,"GMGN_BACKDROP_STRUCTURAL_TEST passed=8 visual_acceptance=false\n");
    }
    return 0;
}
