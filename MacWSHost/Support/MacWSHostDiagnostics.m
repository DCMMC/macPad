#import "MacWSHostDiagnostics.h"

#include <mach/mach_time.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include "macws_diagnostics_policy.h"

static NSString *const MacWSLogPath =
    @"/var/mobile/Library/Logs/MacWSHost.log";

BOOL MacWSHostDiagnosticsEnabled(void) {
    static dispatch_once_t onceToken;
    static BOOL enabled;
    dispatch_once(&onceToken, ^{
        enabled = MacWSDiagnosticSwitchEnabled(
                getenv("MACWS_HOST_DIAGNOSTICS")) ||
            MacWSDiagnosticSwitchEnabled(getenv("MACWS_RUNTIME_DIAGNOSTICS")) ||
            access("/var/mnt/rootfs/private/tmp/macws_runtime_diagnostics",
                   F_OK) == 0;
    });
    return enabled;
}

BOOL MacWSHostTouchDiagnosticsEnabled(void) {
    // Deliberately independent from macws_runtime_diagnostics. That shared
    // switch also enables expensive AGX/app flight recorders in newly born
    // chroot processes. This Host-only witness is checked dynamically so one
    // physical gesture can be traced without restarting MacWSHost or changing
    // the macOS GUI generation; callers log transaction edges only.
    return access(
        "/tmp/com.macwsguide.host.touch-diagnostics",
        F_OK) == 0;
}

BOOL MacWSHostKeyboardLatencyDiagnosticsEnabled(void) {
    // Dynamic and keyboard-only: this can be enabled for one physical WASD
    // sample without turning on the expensive renderer/AppInput flight
    // recorders that would perturb the latency under measurement.
    return access(
        "/var/mnt/rootfs/private/tmp/macws_keyboard_latency_diagnostics",
        F_OK) == 0;
}

BOOL MacWSHostGamePointerDiagnosticsEnabled(void) {
    // Dynamic and relative-pointer-only.  The global runtime switch also
    // enables AGX/JIT recorders in the chroot and materially perturbs a game
    // workload, so a pointer-lock witness must not depend on it.
    return MacWSHostDiagnosticsEnabled() || access(
        "/var/mnt/rootfs/private/tmp/macws_game_pointer_diagnostics",
        F_OK) == 0;
}

double MacWSMachMilliseconds(uint64_t start, uint64_t end) {
    if (!start || end < start) return -1.0;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
    if (!timebase.denom) return -1.0;
    long double nanoseconds = (long double)(end - start) *
        timebase.numer / timebase.denom;
    return (double)(nanoseconds / 1000000.0L);
}

void MacWSLog(NSString *format, ...) {
    // Never block input/render callbacks on file I/O, and never build an
    // unbounded dispatch backlog during a disconnected-service error storm.
    static atomic_uint pending;
    static atomic_uint dropped;
    if (atomic_fetch_add_explicit(&pending, 1, memory_order_relaxed) >= 128) {
        atomic_fetch_sub_explicit(&pending, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&dropped, 1, memory_order_relaxed);
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:args];
    va_end(args);
    if (message.length > 4096)
        message = [[message substringToIndex:4096]
            stringByAppendingString:@" [truncated]"];
    NSTimeInterval timestamp = NSDate.date.timeIntervalSince1970;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.macwsguide.host.log",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                    QOS_CLASS_UTILITY, 0));
    });
    dispatch_async(queue, ^{
        @autoreleasepool {
            const char *path = MacWSLogPath.fileSystemRepresentation;
            struct stat status;
            BOOL canAppend = YES;
            if (stat(path, &status) == 0 && status.st_size >= 4 * 1024 * 1024) {
                NSString *previous = [MacWSLogPath stringByAppendingString:@".previous"];
                // rename replaces only the bounded previous log, never user data.
                canAppend = rename(path, previous.fileSystemRepresentation) == 0;
            }
            // A failed rotation must not turn the size budget into an
            // unbounded file. Account for lost messages until writing resumes.
            int fd = canAppend ? open(path,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600) : -1;
            if (fd >= 0) {
                unsigned lost = atomic_exchange_explicit(&dropped, 0,
                                                         memory_order_relaxed);
                if (lost) dprintf(fd, "%.3f log-overflow dropped=%u\n", timestamp, lost);
                dprintf(fd, "%.3f %s\n", timestamp, message.UTF8String);
                close(fd);
            } else {
                atomic_fetch_add_explicit(&dropped, 1, memory_order_relaxed);
            }
        }
        atomic_fetch_sub_explicit(&pending, 1, memory_order_relaxed);
    });
}
