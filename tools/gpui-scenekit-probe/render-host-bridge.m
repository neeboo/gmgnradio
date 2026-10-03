#import "render-host-bridge.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static void *libraryHandle;
static void *hostHandle;
static void *(*createHost)(const char *, const char *);
static int32_t (*attachHost)(void *, void *, int32_t);
static void *(*hostView)(void *);
static int32_t (*setVisibility)(void *, int32_t, int32_t);
static int32_t (*rotateHost)(void *, float, float);
static char *(*hostDiagnostics)(void *);
static void (*freeHostString)(char *);
static int32_t (*destroyHost)(void *);
static BOOL lastVisible;
static BOOL lastOccluded;
static BOOL hasVisibilityState;
static BOOL chatConfigured;
static uint64_t activeChatRequest;
static int32_t (*configureChat)(void *, const char *);
static int32_t (*sendChat)(void *, uint64_t, const char *);
static int32_t (*cancelChat)(void *, uint64_t);
static char *(*pollChat)(void *);
static char *(*chatContext)(void *);

static void failConfiguration(const char *reason) {
    fprintf(stderr, "PROBE_RENDER_HOST_ERROR %s; no SceneKit fixture fallback\n", reason);
    exit(78);
}

int probe_production_requested(void) {
    const char *library = getenv("GMGN_RENDER_HOST_LIBRARY");
    const char *root = getenv("GMGN_RENDER_HOST_DATA_ROOT");
    const char *suite = getenv("GMGN_RENDER_HOST_DEFAULTS_SUITE");
    const char *backend = getenv("GMGN_PROBE_CHAT_BACKEND");
    if (backend && strcmp(backend, "codex") != 0 && strcmp(backend, "claude-code") != 0)
        failConfiguration("chat backend must explicitly be codex or claude-code");
    BOOL required = [NSBundle.mainBundle objectForInfoDictionaryKey:@"GMGNProductionRenderHostRequired"] != nil;
    BOOL any = library || root || suite || required || backend;
    if (!any) return 0;
    if (!library || !*library || !root || !*root || !suite || !*suite)
        failConfiguration("all three explicit isolated host settings are required");
    if (library[0] != '/' || root[0] != '/' || strcmp(root, "/") == 0 ||
        strncmp(suite, "ai.gmgn.gpui-probe.", strlen("ai.gmgn.gpui-probe.")) != 0)
        failConfiguration("invalid isolated host paths or defaults namespace");
    if (getenv("GMGN_PROBE_NATIVE") && strcmp(getenv("GMGN_PROBE_NATIVE"), "0") == 0)
        failConfiguration("production host cannot run in GPUI-only control mode");
    return 1;
}

void probe_production_attach(NSView *container, BOOL fullStage) {
    if (!probe_production_requested()) failConfiguration("host was requested without complete configuration");
    libraryHandle = dlopen(getenv("GMGN_RENDER_HOST_LIBRARY"), RTLD_NOW | RTLD_LOCAL);
    if (!libraryHandle) failConfiguration("unable to load host library");
#define LOAD_HOST_SYMBOL(variable, symbol) \
    variable = (void *)dlsym(libraryHandle, symbol); \
    if (!variable) failConfiguration("host ABI symbol missing: " symbol)
    LOAD_HOST_SYMBOL(createHost, "gmgn_render_host_create");
    LOAD_HOST_SYMBOL(attachHost, "gmgn_render_host_attach");
    LOAD_HOST_SYMBOL(hostView, "gmgn_render_host_view");
    LOAD_HOST_SYMBOL(setVisibility, "gmgn_render_host_visibility");
    LOAD_HOST_SYMBOL(rotateHost, "gmgn_render_host_rotate");
    LOAD_HOST_SYMBOL(hostDiagnostics, "gmgn_render_host_diagnostics");
    LOAD_HOST_SYMBOL(freeHostString, "gmgn_render_host_string_free");
    LOAD_HOST_SYMBOL(destroyHost, "gmgn_render_host_destroy");
    if (getenv("GMGN_PROBE_CHAT_BACKEND")) {
        LOAD_HOST_SYMBOL(configureChat, "gmgn_render_host_chat_configure");
        LOAD_HOST_SYMBOL(sendChat, "gmgn_render_host_chat_send");
        LOAD_HOST_SYMBOL(cancelChat, "gmgn_render_host_chat_cancel");
        LOAD_HOST_SYMBOL(pollChat, "gmgn_render_host_chat_poll");
        LOAD_HOST_SYMBOL(chatContext, "gmgn_render_host_chat_context");
    }
#undef LOAD_HOST_SYMBOL
    hostHandle = createHost(getenv("GMGN_RENDER_HOST_DATA_ROOT"), getenv("GMGN_RENDER_HOST_DEFAULTS_SUITE"));
    if (!hostHandle) failConfiguration("host creation failed");
    if (attachHost(hostHandle, (__bridge void *)container, fullStage ? 1 : 0) != 1) {
        probe_production_destroy();
        failConfiguration("host attachment failed");
    }
    if (setVisibility(hostHandle, 1, 0) != 1) failConfiguration("host visibility activation failed");
    lastVisible = YES; lastOccluded = NO; hasVisibilityState = YES;
    NSView *view = (__bridge NSView *)hostView(hostHandle);
    if (!view || ![view isKindOfClass:NSView.class] || ![view isDescendantOf:container])
        failConfiguration("host view is not attached to the isolated container");
    NSLog(@"PROBE_RENDER_HOST_ATTACHED mode=%@ fixtureFallback=0", fullStage ? @"fullStage" : @"liveCam");
    if (configureChat) {
        if (configureChat(hostHandle, getenv("GMGN_PROBE_CHAT_BACKEND")) != 1)
            failConfiguration("explicit chat backend configuration failed");
        chatConfigured = YES;
        NSLog(@"PROBE_CHAT_BACKEND_CONFIGURED deliveryMode=final-response");
    }
}

int32_t probe_chat_enabled(void) { return chatConfigured && hostHandle ? 1 : 0; }
int32_t probe_chat_send(uint64_t requestID, const char *text) {
    if (!probe_chat_enabled()) return 0;
    int32_t result = sendChat(hostHandle, requestID, text);
    if (result == 1) activeChatRequest = requestID;
    return result;
}
int32_t probe_chat_cancel(uint64_t requestID) {
    return probe_chat_enabled() ? cancelChat(hostHandle, requestID) : 0;
}
char *probe_chat_poll(void) { return probe_chat_enabled() ? pollChat(hostHandle) : NULL; }
void probe_chat_string_free(char *string) { if (string && freeHostString) freeHostString(string); }

void probe_production_rotate(float yaw, float pitch) {
    if (!hostHandle) return;
    int32_t accepted = rotateHost(hostHandle, yaw, pitch);
    NSLog(@"PROBE_RENDER_HOST_ROTATE accepted=%d", accepted);
}

void probe_production_visibility(BOOL visible, BOOL occluded) {
    if (!hostHandle) return;
    if (hasVisibilityState && lastVisible == visible && lastOccluded == occluded) return;
    int32_t accepted = setVisibility(hostHandle, visible ? 1 : 0, occluded ? 1 : 0);
    if (accepted != 1) failConfiguration("host lifecycle visibility update failed");
    lastVisible = visible; lastOccluded = occluded; hasVisibilityState = YES;
    NSLog(@"PROBE_RENDER_HOST_VISIBILITY visible=%d occluded=%d accepted=%d", visible, occluded, accepted);
}

// Numeric render telemetry only; no arbitrary nested strings or provider data.
static id numericTelemetry(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *output = [NSMutableDictionary dictionary];
        for (id key in value) {
            if (![key isKindOfClass:NSString.class]) continue;
            id safe = numericTelemetry(value[key]);
            if (safe) output[key] = safe;
        }
        return output;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *output = [NSMutableArray array];
        for (id item in value) { id safe = numericTelemetry(item); if (safe) [output addObject:safe]; }
        return output;
    }
    return nil;
}
void probe_production_diagnostics(void) {
    if (!hostHandle) return;
    char *string = hostDiagnostics(hostHandle);
    if (!string) return;
    size_t length = strnlen(string, 65536);
    NSData *data = length < 65536 ? [NSData dataWithBytes:string length:length] : nil;
    freeHostString(string);
    NSDictionary *diagnostics = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![diagnostics isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"attached", @"hasWindow", @"drawableWidth", @"drawableHeight", @"scheduling", @"performance"])
        if (diagnostics[key]) { id value = numericTelemetry(diagnostics[key]); if (value) safe[key] = value; }
    for (NSString *key in @[@"owner", @"surfaceClass"]) {
        id value = diagnostics[key];
        if ([value isKindOfClass:NSString.class] && [value length] < 128) safe[key] = value;
    }
    NSData *safeData = [NSJSONSerialization dataWithJSONObject:safe options:NSJSONWritingSortedKeys error:nil];
    if (safeData) NSLog(@"PROBE_RENDER_HOST_DIAGNOSTICS %@", [[NSString alloc] initWithData:safeData encoding:NSUTF8StringEncoding]);
}
void probe_production_destroy(void) {
    if (!hostHandle) return;
    if (chatConfigured) cancelChat(hostHandle, activeChatRequest);
    chatConfigured = NO;
    setVisibility(hostHandle, 0, 1);
    int32_t destroyed = destroyHost(hostHandle);
    hostHandle = NULL;
    // Swift Tasks may still unwind: keep dlopen's reference for the process lifetime.
    // Calling dlclose here could unmap code that those Tasks are still executing.
    NSLog(@"PROBE_RENDER_HOST_DESTROYED accepted=%d libraryRetainedUntilProcessExit=1", destroyed);
}
