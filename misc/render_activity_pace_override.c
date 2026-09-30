/*
 * Diagnostic A/B helper for the versioned Stray -> WindowServer render
 * activity record.  It changes only targetPaceUS while preserving the
 * producer's freshness/identity fields.  This is intentionally not a
 * production policy: use it to establish whether the direct CAMetalDrawable
 * path remains independent when redundant full-desktop composition is paced
 * more slowly.
 */

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "../include/macws_host_protocol.h"

static uint64_t monotonic_ns(void) {
    struct timespec value = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) +
        (uint64_t)value.tv_nsec;
}

static unsigned long parse_positive(const char *text, const char *label) {
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno != 0 || !end || end == text || *end != '\0' || value == 0) {
        fprintf(stderr, "invalid %s: %s\n", label, text);
        exit(64);
    }
    return value;
}

int main(int argc, char **argv) {
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "usage: %s PACE_US DURATION_SECONDS [PATH]\n",
                argv[0]);
        return 64;
    }
    unsigned long pace = parse_positive(argv[1], "pace");
    unsigned long duration = parse_positive(argv[2], "duration");
    if (pace < 8333 || pace > 500000 || duration > 600) {
        fprintf(stderr, "pace/duration outside diagnostic bounds\n");
        return 64;
    }
    const char *path = argc == 4 ? argv[3] :
        "/var/mnt/rootfs/private/tmp/macws_render_activity";
    int descriptor = open(path, O_RDWR | O_CLOEXEC);
    if (descriptor < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 66;
    }

    MacWSRenderActivityRecord record = {0};
    if (pread(descriptor, &record, sizeof(record), 0) != sizeof(record) ||
        record.magic != MACWS_RENDER_ACTIVITY_MAGIC ||
        (record.version != MACWS_RENDER_ACTIVITY_VERSION &&
         record.version != MACWS_RENDER_ACTIVITY_AUTHORITY_VERSION &&
         record.version != MACWS_RENDER_ACTIVITY_LEGACY_VERSION) ||
        record.size != sizeof(record)) {
        fprintf(stderr, "render activity record is absent or invalid\n");
        close(descriptor);
        return 65;
    }

    uint32_t target = (uint32_t)pace;
    uint64_t deadline = monotonic_ns() +
        (uint64_t)duration * UINT64_C(1000000000);
    unsigned long writes = 0;
    while (monotonic_ns() < deadline) {
        if (pwrite(descriptor, &target, sizeof(target),
                   offsetof(MacWSRenderActivityRecord, targetPaceUS)) !=
            sizeof(target)) {
            fprintf(stderr, "pwrite %s: %s\n", path, strerror(errno));
            close(descriptor);
            return 74;
        }
        writes++;
        struct timespec pause = {.tv_nsec = 5 * 1000 * 1000};
        (void)nanosleep(&pause, NULL);
    }
    close(descriptor);
    printf("pace-override pace-us=%u duration-s=%lu writes=%lu\n",
           target, duration, writes);
    return 0;
}
