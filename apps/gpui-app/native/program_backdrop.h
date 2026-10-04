#import <AppKit/AppKit.h>
typedef struct {
    double width, height, radius, opacity, priority;
    // Row-major source-local -> GPUI-window top-left homography.
    double matrix[9];
} GMGNProgramBackdropCard;
void *gmgn_gpui_program_backdrop_create(void *gpuiView);
int gmgn_gpui_program_backdrop_apply(void *context, const GMGNProgramBackdropCard *cards,
                                    size_t count, const double viewport[4]);
int gmgn_gpui_program_backdrop_clear(void *context);
int gmgn_gpui_program_backdrop_destroy(void *context);
// Read-only structural diagnostics; no scene pixels or configuration are exposed.
int gmgn_gpui_program_backdrop_diagnostics(void *context, double values[6]);
