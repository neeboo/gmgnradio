#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

static double number(char *json, const char *name) {
    char quoted[128]; snprintf(quoted, sizeof(quoted), "\"%s\"", name);
    char *key = strstr(json, quoted);
    return key ? strtod(strchr(key, ':') + 1, NULL) : -1;
}
static double position(char *json) { return number(json, "position"); }

int main(int argc, char **argv) {
    if (argc < 3 || argc > 5) return 64;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "Host load failed: %s\n", dlerror()); return 1; }
    void *(*create)(const char *, const char *) = dlsym(library, "gmgn_unity_host_create");
    char *(*snapshot)(void *) = dlsym(library, "gmgn_unity_host_snapshot");
    int (*command)(void *, const char *) = dlsym(library, "gmgn_unity_host_command");
    int (*destroy)(void *) = dlsym(library, "gmgn_unity_host_destroy");
    void (*release)(char *) = dlsym(library, "gmgn_unity_host_string_free");
    if (!create || !snapshot || !command || !destroy || !release) return 2;
    if (create("/", "ai.gmgn.unity-sample.smoke") != NULL) return 3;
    if (create(argv[2], "invalid-suite") != NULL) return 4;
    void *host = create(argv[2], "ai.gmgn.unity-sample.smoke");
    if (!host) { fputs("Real DSH host initialization unavailable\n", stderr); return 5; }
    char *value = snapshot(host);
    if (!value || !strstr(value, "playbackSessionID") || !strstr(value, "seekSupported")) return 6;
    release(value);
    if (command(host, "{\"op\":\"music.seek\",\"value\":10}") != 0) return 7;
    if (command(host, "{\"op\":\"music.volume\",\"value\":0.5}") != 1) return 8;
    if (command(host, "{\"op\":\"music.volume\",\"value\":2}") != 0) return 9;
    if (argc >= 4) {
        if (strchr(argv[3], '"') || strchr(argv[3], '\\')) return 64;
        char load[4096];
        // Unity JsonUtility serializes an unset string as an empty string.
        // Match that actual ABI boundary, not an omitted-field approximation.
        if (snprintf(load, sizeof(load), "{\"op\":\"music.load\",\"path\":\"%s\",\"lyricPath\":\"\",\"autoplay\":true}", argv[3]) >= sizeof(load)) return 64;
        if (!command(host, load)) return 11;
        usleep(700000);
        value = snapshot(host); double before = position(value); release(value);
        if (before < 0.05) return 12;
        if (!command(host, "{\"op\":\"music.pause\"}")) return 13;
        value = snapshot(host); double paused = position(value); release(value);
        usleep(300000);
        value = snapshot(host); double later = position(value); release(value);
        if (paused < before || fabs(later - paused) > 0.001) return 14;
        if (!command(host, "{\"op\":\"music.play\"}")) return 15;
        usleep(350000);
        value = snapshot(host); double resumed = position(value); release(value);
        if (resumed <= paused) return 16;
        if (!command(host, "{\"op\":\"music.stop\"}")) return 17;
        value = snapshot(host); double stopped = position(value); release(value);
        if (fabs(stopped) > 0.001) return 18;
        printf("PASS actual audio sample clock: before=%.3f paused=%.3f later=%.3f resumed=%.3f stopped=%.3f\n", before, paused, later, resumed, stopped);
        char queued[8192];
        const char *secondPath = argc == 5 ? argv[4] : argv[3];
        if (strchr(secondPath, '"') || strchr(secondPath, '\\')) return 64;
        if (snprintf(queued, sizeof(queued), "{\"op\":\"music.queue\",\"paths\":[\"%s\",\"%s\"],\"autoplay\":true}", argv[3], secondPath) >= sizeof(queued)) return 64;
        if (!command(host, queued)) return 19;
        value = snapshot(host); double firstSession = number(value, "playbackSessionID"); release(value);
        if (!command(host, "{\"op\":\"music.next\"}")) return 20;
        usleep(350000);
        value = snapshot(host);
        double secondSession = number(value, "playbackSessionID"), secondIndex = number(value, "queueIndex");
        int sentLines = strstr(value, "\"lines\"") != NULL;
        double nextPosition = position(value);
        release(value);
        if (secondSession <= firstSession || secondIndex != 1 || !sentLines || nextPosition <= 0.05) return 21;
        if (command(host, "{\"op\":\"music.next\"}") != 0) return 22;
        if (!command(host, "{\"op\":\"music.previous\"}")) return 23;
        usleep(350000);
        value = snapshot(host); double previousIndex = number(value, "queueIndex"); release(value);
        if (previousIndex != 0 || command(host, "{\"op\":\"music.previous\"}") != 0) return 24;
        command(host, "{\"op\":\"music.stop\"}");
        printf("PASS real local queue next/previous: sessions %.0f→%.0f, second-song clock=%.3f; lyric clear and queue boundaries\n", firstSession, secondSession, nextPosition);
    }
    if (destroy(host) != 1) return 10;
    puts("PASS real host lifecycle, snapshot, volume and unsupported seek; no chat submitted");
    // Do not dlclose: asynchronous Swift cancellation cleanup may still run.
    return 0;
}
