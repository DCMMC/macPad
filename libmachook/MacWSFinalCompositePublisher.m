#import "MacWSFinalCompositePublisher.h"

#import <IOSurface/IOSurfaceRef.h>
#import <Foundation/Foundation.h>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/bootstrap.h>
#include <limits.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "macws_final_composite_protocol.h"

extern void MacWSHideNativeCursorAfterFirstComposite(void);
extern pid_t audit_token_to_pid(audit_token_t token);

static _Atomic uint64_t PublishedSequence;
static _Atomic bool ContentValidated;
static pthread_mutex_t ServiceLock = PTHREAD_MUTEX_INITIALIZER;
static mach_port_t CachedService = MACH_PORT_NULL;
static uint64_t ServiceRefreshDeadlineNS;
static _Atomic uint32_t FailureWitnesses;
static _Atomic uint32_t LookupWitnesses;
static NSObject *CompletionLock;
static dispatch_once_t CompletionLockOnce;
static id<MTLCommandQueue> ReplayMetalCommandQueue;
static id<MTLTexture> ReplaySourceTexture;
static uint32_t ReplayPixelFormat;
static uint64_t ReplaySourceCompletionTime;
static mach_port_t ReplayReceivePort = MACH_PORT_NULL;
static pthread_mutex_t ReplayReceiverLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic bool ReplayReceiverStarted;
static _Atomic uint32_t ReplayFailureWitnesses;
static pthread_mutex_t ReplayWorkLock = PTHREAD_MUTEX_INITIALIZER;
static pid_t PendingReplayRequesterPID;
static uint64_t PendingReplayMinimumCompletionTime;
static bool ReplayWorkScheduled;
static _Atomic uint64_t ReplayReceivedRequests;

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

static void StartReplayRequestReceiver(void);
static bool SnapshotAndPublish(id<MTLCommandQueue> queue,
                               id<MTLTexture> sourceTexture,
                               uint32_t pixelFormat,
                               uint64_t minimumCompletionTime);

// The SkyLight display target is intentionally reused by WindowServer. A
// completion callback proves that one render finished, but it does not stop a
// later command buffer from modifying that same IOSurface while Host samples
// it. Preserve presentation effects (blur, shadows, Dock magnification) by
// queueing the snapshot copy on the producer's exact AGX queue before the
// EndUpdate hook returns. This places the copy between the completed render
// and the next reuse without blocking the render thread. displayd marks a
// published surface in-use while it or Host holds a lease, and `reserved`
// covers the earlier submitted-but-not-yet-published interval, so a pool slot
// is never overwritten under either the GPU or a consumer.
enum { MacWSFinalCompositeSnapshotSlotCount = 4 };
typedef struct {
    IOSurfaceRef surface;
    id<MTLTexture> texture;
    id<MTLDevice> device;
    size_t width;
    size_t height;
    uint64_t lastPublishedNS;
    bool reserved;
} MacWSFinalCompositeSnapshotSlot;
static MacWSFinalCompositeSnapshotSlot SnapshotSlots[
    MacWSFinalCompositeSnapshotSlotCount];
static NSUInteger NextSnapshotSlot;
static pthread_mutex_t SnapshotSlotLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint32_t SnapshotFailureWitnesses;

static bool DirectCompositeTransportRequested(void) {
    static bool direct;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *value = getenv("MACWS_FINAL_COMPOSITE_DIRECT");
        direct = value && value[0] && strcmp(value, "0") != 0;
    });
    return direct;
}

static void SnapshotLogFailure(const char *stage, id object) {
    uint32_t witness = atomic_fetch_add_explicit(
        &SnapshotFailureWitnesses, 1, memory_order_relaxed) + 1;
    if (witness <= 12) {
        dprintf(STDERR_FILENO,
            "#### FINAL-COMPOSITE snapshot-failed stage=%s witness=%u "
            "object=%p\n", stage, witness, (__bridge void *)object);
    }
}

static uint64_t MonotonicNanoseconds(void) {
    struct timespec now = {0};
    return clock_gettime(CLOCK_MONOTONIC, &now) == 0
        ? (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec : 0;
}

static uint64_t MachDurationNanoseconds(uint64_t ticks) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
            timebase.numer == 0 || timebase.denom == 0) {
            timebase.numer = 1;
            timebase.denom = 1;
        }
    });
    __uint128_t nanoseconds = (__uint128_t)ticks * timebase.numer /
        timebase.denom;
    return nanoseconds > UINT64_MAX ? UINT64_MAX : (uint64_t)nanoseconds;
}

// Returns a caller-owned reference. CachedService remains an independent
// lookup anchor so concurrent publishers cannot invalidate a borrowed name.
static mach_port_t AcquireService(void) {
    uint64_t nowNS = MonotonicNanoseconds();
    pthread_mutex_lock(&ServiceLock);
    bool refreshDue = !MACH_PORT_VALID(CachedService) || nowNS == 0 ||
        nowNS >= ServiceRefreshDeadlineNS;
    if (refreshDue) {
        mach_port_t service = MACH_PORT_NULL;
        kern_return_t result = bootstrap_look_up(
            bootstrap_port, MACWS_FINAL_COMPOSITE_MACH_SERVICE, &service);
        if (result == BOOTSTRAP_SUCCESS && MACH_PORT_VALID(service)) {
            if (service == CachedService) {
                (void)mach_port_deallocate(mach_task_self(), service);
            } else {
                mach_port_t previous = CachedService;
                CachedService = service;
                if (MACH_PORT_VALID(previous))
                    (void)mach_port_deallocate(mach_task_self(), previous);
            }
        } else {
            uint32_t witness = atomic_fetch_add_explicit(
                &LookupWitnesses, 1, memory_order_relaxed) + 1;
            if (witness <= 8) {
                dprintf(STDERR_FILENO,
                    "#### FINAL-COMPOSITE bootstrap-lookup-failed "
                    "witness=%u bootstrap=%u cached=%u returned=%u kr=%#x\n",
                    witness, bootstrap_port, CachedService, service, result);
            }
        }
        // displayd may replace its receive right while an old send right still
        // accepts queued messages. Refresh once per second even without an
        // INVALID_DEST result so a static desktop recovers after a relaunch.
        ServiceRefreshDeadlineNS = nowNS ? nowNS + NSEC_PER_SEC : 0;
    }
    mach_port_t result = CachedService;
    if (MACH_PORT_VALID(result) && mach_port_mod_refs(
            mach_task_self(), result, MACH_PORT_RIGHT_SEND, 1) !=
            KERN_SUCCESS) {
        (void)mach_port_deallocate(mach_task_self(), result);
        CachedService = MACH_PORT_NULL;
        ServiceRefreshDeadlineNS = 0;
        result = MACH_PORT_NULL;
    }
    pthread_mutex_unlock(&ServiceLock);
    return result;
}

static void InvalidateService(mach_port_t failedService) {
    pthread_mutex_lock(&ServiceLock);
    if (CachedService == failedService) {
        (void)mach_port_deallocate(mach_task_self(), failedService);
        CachedService = MACH_PORT_NULL;
        ServiceRefreshDeadlineNS = 0;
    }
    pthread_mutex_unlock(&ServiceLock);
}

static mach_msg_return_t SendMessage(
        MacWSFinalCompositeMachMessage *message, mach_port_t service) {
    if (!message || !MACH_PORT_VALID(service)) return MACH_SEND_INVALID_DEST;
    message->header.msgh_remote_port = service;
    return mach_msg(&message->header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                    sizeof(*message), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
}

void MacWSFinalCompositePublisherMarkContentValidated(void) {
    atomic_store_explicit(&ContentValidated, true, memory_order_release);
    StartReplayRequestReceiver();
    MacWSHideNativeCursorAfterFirstComposite();
}

bool MacWSFinalCompositePublisherCanPublish(void) {
    return atomic_load_explicit(&ContentValidated, memory_order_acquire);
}

uint64_t MacWSFinalCompositePublisherPublishedSequence(void) {
    return atomic_load_explicit(&PublishedSequence, memory_order_relaxed);
}

bool MacWSFinalCompositePublisherPublishSurface(
        IOSurfaceRef surface, uint32_t metalPixelFormat) {
    if (!surface || metalPixelFormat !=
            MACWS_FINAL_COMPOSITE_METAL_BGRA8_UNORM) return false;
    StartReplayRequestReceiver();

    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    uint32_t ioSurfacePixelFormat = IOSurfaceGetPixelFormat(surface);
    if (ioSurfacePixelFormat == 0)
        ioSurfacePixelFormat = MACWS_FINAL_COMPOSITE_BGRA;
    MacWSFinalCompositeRecord record = {
        .magic = MACWS_FINAL_COMPOSITE_MAGIC,
        .version = MACWS_FINAL_COMPOSITE_VERSION,
        .size = sizeof(MacWSFinalCompositeRecord),
        .producerPID = getpid(),
        .surfaceID = IOSurfaceGetID(surface),
        .sequence = atomic_fetch_add_explicit(
            &PublishedSequence, 1, memory_order_relaxed) + 1,
        .completionTime = mach_absolute_time(),
        .width = width <= UINT32_MAX ? (uint32_t)width : 0,
        .height = height <= UINT32_MAX ? (uint32_t)height : 0,
        .bytesPerRow = bytesPerRow <= UINT32_MAX
            ? (uint32_t)bytesPerRow : 0,
        .ioSurfacePixelFormat = ioSurfacePixelFormat,
        .metalPixelFormat = metalPixelFormat,
    };
    if (!MacWSFinalCompositeRecordIsValid(&record, sizeof(record)))
        return false;

    mach_port_t service = AcquireService();
    if (!MACH_PORT_VALID(service)) {
        uint32_t witness = atomic_fetch_add_explicit(
            &FailureWitnesses, 1, memory_order_relaxed) + 1;
        if (witness <= 8) {
            dprintf(STDERR_FILENO,
                "#### FINAL-COMPOSITE publish-failed stage=bootstrap-lookup "
                "witness=%u sequence=%llu surface=%u\n",
                witness, (unsigned long long)record.sequence,
                record.surfaceID);
        }
        return false;
    }
    mach_port_t surfacePort = IOSurfaceCreateMachPort(surface);
    if (!MACH_PORT_VALID(surfacePort)) {
        uint32_t witness = atomic_fetch_add_explicit(
            &FailureWitnesses, 1, memory_order_relaxed) + 1;
        if (witness <= 8) {
            dprintf(STDERR_FILENO,
                "#### FINAL-COMPOSITE publish-failed stage=surface-port "
                "witness=%u sequence=%llu surface=%u service=%u\n",
                witness, (unsigned long long)record.sequence,
                record.surfaceID, service);
        }
        (void)mach_port_deallocate(mach_task_self(), service);
        return false;
    }

    MacWSFinalCompositeMachMessage message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS(
        MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = service;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = MACWS_FINAL_COMPOSITE_MACH_MESSAGE_ID;
    message.body.msgh_descriptor_count = 1;
    message.surfacePort.name = surfacePort;
    message.surfacePort.disposition = MACH_MSG_TYPE_COPY_SEND;
    message.surfacePort.type = MACH_MSG_PORT_DESCRIPTOR;
    message.record = record;
    mach_msg_return_t result = SendMessage(&message, service);
    if (result == MACH_SEND_INVALID_DEST) {
        InvalidateService(service);
        (void)mach_port_deallocate(mach_task_self(), service);
        service = AcquireService();
        if (MACH_PORT_VALID(service)) result = SendMessage(&message, service);
    }
    (void)mach_port_deallocate(mach_task_self(), surfacePort);
    if (result == MACH_SEND_INVALID_DEST) InvalidateService(service);
    if (MACH_PORT_VALID(service))
        (void)mach_port_deallocate(mach_task_self(), service);
    if (result != MACH_MSG_SUCCESS) {
        uint32_t witness = atomic_fetch_add_explicit(
            &FailureWitnesses, 1, memory_order_relaxed) + 1;
        if (witness <= 8) {
            dprintf(STDERR_FILENO,
                "#### FINAL-COMPOSITE publish-failed stage=mach-msg "
                "witness=%u sequence=%llu surface=%u service=%u kr=%d\n",
                witness, (unsigned long long)record.sequence,
                record.surfaceID, service, result);
        }
    }
    if (result == MACH_MSG_SUCCESS)
        MacWSHideNativeCursorAfterFirstComposite();
    return result == MACH_MSG_SUCCESS;
}

static dispatch_queue_t CompletionQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.macwsguide.final-composite-observer",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static dispatch_queue_t ReplayQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Replay snapshotting can wait on AGX. Keep that work off the
        // permanent Mach receive thread, and coalesce topology bursts before
        // they reach this serial queue.
        queue = dispatch_queue_create(
            "com.macwsguide.final-composite-replay",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static id RetainObject(id object) {
#if __has_feature(objc_arc)
    return object;
#else
    return [object retain];
#endif
}

static void ReleaseObject(id object) {
#if __has_feature(objc_arc)
    (void)object;
#else
    [object release];
#endif
}

static NSObject *PublisherStateLock(void) {
    dispatch_once(&CompletionLockOnce, ^{ CompletionLock = [NSObject new]; });
    return CompletionLock;
}

static void ResetSnapshotSlot(MacWSFinalCompositeSnapshotSlot *slot) {
    if (!slot) return;
    ReleaseObject(slot->texture);
    ReleaseObject(slot->device);
    if (slot->surface) CFRelease(slot->surface);
    memset(slot, 0, sizeof(*slot));
}

static MacWSFinalCompositeSnapshotSlot *AcquireSnapshotSlot(
        id<MTLDevice> device, size_t width, size_t height,
        id<MTLTexture> excludedTexture) {
    if (!device || width == 0 || height == 0 || width > UINT32_MAX ||
        height > UINT32_MAX || width > SIZE_MAX / 4) return NULL;
    size_t tightBytesPerRow = width * 4;
    size_t bytesPerRow = (tightBytesPerRow + 63) & ~(size_t)63;
    if (bytesPerRow < tightBytesPerRow || height > SIZE_MAX / bytesPerRow)
        return NULL;

    uint64_t nowNS = MonotonicNanoseconds();
    pthread_mutex_lock(&SnapshotSlotLock);
    for (NSUInteger attempt = 0;
         attempt < MacWSFinalCompositeSnapshotSlotCount; attempt++) {
        NSUInteger index = (NextSnapshotSlot + attempt) %
            MacWSFinalCompositeSnapshotSlotCount;
        MacWSFinalCompositeSnapshotSlot *slot = &SnapshotSlots[index];
        // Replay reads from a texture in this same pool. Never choose that
        // texture as the blit destination: a source/destination alias is not
        // a valid snapshot and would destroy the recovery witness.
        if (slot->texture && slot->texture == excludedTexture) continue;
        BOOL compatible = slot->surface && slot->texture &&
            slot->device == device && slot->width == width &&
            slot->height == height;
        if (slot->surface && !compatible) {
            if (slot->reserved || IOSurfaceIsInUse(slot->surface)) continue;
            ResetSnapshotSlot(slot);
        }
        if (slot->surface) {
            // Four 120-Hz frames already provide ~33 ms for displayd to take
            // its cross-process use-count. Keep the explicit minimum as a
            // handoff guard if frames were coalesced unusually quickly.
            if (slot->reserved || IOSurfaceIsInUse(slot->surface) ||
                (nowNS && slot->lastPublishedNS &&
                 nowNS - slot->lastPublishedNS < 30 * NSEC_PER_MSEC)) {
                continue;
            }
            slot->reserved = true;
            NextSnapshotSlot = (index + 1) %
                MacWSFinalCompositeSnapshotSlotCount;
            pthread_mutex_unlock(&SnapshotSlotLock);
            return slot;
        }

        NSDictionary *properties = @{
            (__bridge id)kIOSurfaceWidth: @(width),
            (__bridge id)kIOSurfaceHeight: @(height),
            (__bridge id)kIOSurfaceBytesPerElement: @4,
            (__bridge id)kIOSurfaceBytesPerRow: @(bytesPerRow),
            (__bridge id)kIOSurfaceAllocSize: @(bytesPerRow * height),
            (__bridge id)kIOSurfacePixelFormat:
                @(MACWS_FINAL_COMPOSITE_BGRA),
        };
        IOSurfaceRef surface = IOSurfaceCreate(
            (__bridge CFDictionaryRef)properties);
        if (!surface) {
            pthread_mutex_unlock(&SnapshotSlotLock);
            SnapshotLogFailure("iosurface-create", device);
            return NULL;
        }
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead |
            MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [device
            newTextureWithDescriptor:descriptor iosurface:surface plane:0];
        if (!texture) {
            CFRelease(surface);
            pthread_mutex_unlock(&SnapshotSlotLock);
            SnapshotLogFailure("texture-create", device);
            return NULL;
        }
        slot->surface = surface;
        slot->texture = RetainObject(texture);
        slot->device = RetainObject(device);
        slot->width = width;
        slot->height = height;
        slot->reserved = true;
        ReleaseObject(texture);
        NextSnapshotSlot = (index + 1) %
            MacWSFinalCompositeSnapshotSlotCount;
        pthread_mutex_unlock(&SnapshotSlotLock);
        return slot;
    }
    pthread_mutex_unlock(&SnapshotSlotLock);
    return NULL;
}

static void ReleaseSnapshotSlot(MacWSFinalCompositeSnapshotSlot *slot,
                                bool published) {
    if (!slot) return;
    pthread_mutex_lock(&SnapshotSlotLock);
    if (published) slot->lastPublishedNS = MonotonicNanoseconds();
    slot->reserved = false;
    pthread_mutex_unlock(&SnapshotSlotLock);
}

static bool SnapshotAndPublish(id<MTLCommandQueue> queue,
                               id<MTLTexture> sourceTexture,
                               uint32_t pixelFormat,
                               uint64_t minimumCompletionTime) {
    if (!queue || !sourceTexture ||
        pixelFormat != MACWS_FINAL_COMPOSITE_METAL_BGRA8_UNORM)
        return false;
    id<MTLDevice> device = sourceTexture.device;
    size_t width = sourceTexture.width;
    size_t height = sourceTexture.height;
    if (!queue || !device || width == 0 || height == 0) {
        SnapshotLogFailure("source", sourceTexture);
        return false;
    }
    MacWSFinalCompositeSnapshotSlot *slot = AcquireSnapshotSlot(
        device, width, height, sourceTexture);
    if (!slot) return false;

    id<MTLCommandBuffer> copyCommand = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [copyCommand blitCommandEncoder];
    if (!copyCommand || !blit) {
        SnapshotLogFailure("command", queue);
        ReleaseSnapshotSlot(slot, false);
        return false;
    }
    [blit copyFromTexture:sourceTexture
              sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:slot->texture
         destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [copyCommand commit];

    // Replay is a rare recovery operation on its own serial queue. Let Metal
    // block that worker until the real GPU terminal state instead of waking a
    // thread every 500 us. The ordinary frame path remains callback-driven.
    [copyCommand waitUntilCompleted];
    MTLCommandBufferStatus status = copyCommand.status;
    if (status != MTLCommandBufferStatusCompleted || copyCommand.error) {
        SnapshotLogFailure("copy-completion", copyCommand);
        // An error is terminal and releases the destination normally. If a
        // broken driver returned from waitUntilCompleted without a terminal
        // state, keep the slot reserved rather than race a still-running GPU.
        if (status == MTLCommandBufferStatusError)
            ReleaseSnapshotSlot(slot, false);
        return false;
    }
    // This copy is submitted on the retained source queue. Metal's
    // queue ordering makes its completion the causal freshness witness: it is
    // after every desktop update already submitted when the replay request
    // arrived. The remembered snapshot may legitimately be old on a static
    // desktop, but the newly completed copy is not.
    uint64_t snapshotCompletionTime = mach_absolute_time();
    if (minimumCompletionTime != 0 &&
        snapshotCompletionTime < minimumCompletionTime) {
        SnapshotLogFailure("copy-freshness", copyCommand);
        ReleaseSnapshotSlot(slot, false);
        return false;
    }
    bool published = MacWSFinalCompositePublisherPublishSurface(
        slot->surface, pixelFormat);
    ReleaseSnapshotSlot(slot, published);
    return published;
}

static BOOL ReplayRequesterIsDisplayd(pid_t pid) {
    if (pid <= 1) return NO;
    char path[PATH_MAX] = {0};
    int length = proc_pidpath(pid, path, sizeof(path));
    if (length > 0 && length < (int)sizeof(path)) {
        path[sizeof(path) - 1] = '\0';
        if (strcmp(path, "/usr/local/bin/macwsdisplayd") == 0 ||
            strcmp(path,
                   "/var/mnt/rootfs/usr/local/bin/macwsdisplayd") == 0)
            return YES;
    }
    // Runtime-confirmed from the native root context on 2026-08-22:
    // `pid=37829 name=macwsdisplayd path=<unavailable>`. Cross-chroot vnode
    // resolution is therefore not a valid admission prerequisite. The Mach
    // audit trailer still binds this exact PID to the sender; use the bounded
    // kernel command name only when the preferred full path is unavailable.
    char name[64] = {0};
    int nameLength = proc_name(pid, name, sizeof(name));
    return nameLength > 0 && nameLength < (int)sizeof(name) &&
        strcmp(name, "macwsdisplayd") == 0;
}

static uint32_t NextReplayFailureWitness(void) {
    return atomic_fetch_add_explicit(
        &ReplayFailureWitnesses, 1, memory_order_relaxed) + 1;
}

static void RememberReplaySource(id<MTLCommandQueue> queue,
                                 id<MTLTexture> sourceTexture,
                                 uint32_t pixelFormat) {
    if (!queue || !sourceTexture || pixelFormat !=
            MACWS_FINAL_COMPOSITE_METAL_BGRA8_UNORM) return;
    id retainedQueue = RetainObject(queue);
    id retainedSource = RetainObject(sourceTexture);
    @synchronized (PublisherStateLock()) {
        id oldQueue = ReplayMetalCommandQueue;
        id oldSource = ReplaySourceTexture;
        ReplayMetalCommandQueue = retainedQueue;
        ReplaySourceTexture = retainedSource;
        ReplayPixelFormat = pixelFormat;
        ReplaySourceCompletionTime = mach_absolute_time();
        ReleaseObject(oldQueue);
        ReleaseObject(oldSource);
    }
}

static void PublishReplaySnapshot(pid_t requesterPID,
                                  uint64_t minimumCompletionTime) {
    id<MTLCommandQueue> queue = nil;
    id<MTLTexture> sourceTexture = nil;
    uint32_t pixelFormat = 0;
    uint64_t sourceCompletionTime = 0;
    @synchronized (PublisherStateLock()) {
        queue = RetainObject(ReplayMetalCommandQueue);
        sourceTexture = RetainObject(ReplaySourceTexture);
        pixelFormat = ReplayPixelFormat;
        sourceCompletionTime = ReplaySourceCompletionTime;
    }
    uint64_t sourceLagNS = sourceCompletionTime < minimumCompletionTime
        ? MachDurationNanoseconds(
            minimumCompletionTime - sourceCompletionTime) : 0;
    BOOL sourceFresh = sourceCompletionTime >= minimumCompletionTime;
    BOOL sourceReady = queue && sourceTexture &&
        MacWSFinalCompositePublisherCanPublish();
    // The copy command proves that the retained texture can still be read; it
    // does not prove that SkyLight rendered the topology change which caused
    // this replay request.  Re-copying an older texture advances the transport
    // sequence and completion timestamp while preserving stale desktop pixels.
    // Require the remembered compositor source itself to postdate the caller's
    // mutation witness.  A wedged WindowServer will now leave displayd in its
    // typed fallback state, allowing Repair Desktop to rebuild the session
    // instead of falsely reporting success from a replayed old frame.
    BOOL published = sourceReady && sourceFresh && SnapshotAndPublish(
        queue, sourceTexture, pixelFormat, minimumCompletionTime);
    uint32_t witness = published ? 0 : NextReplayFailureWitness();
    if (published || witness <= 12) {
        dprintf(STDERR_FILENO,
            "#### FINAL-COMPOSITE replay-request requester=%d "
            "min-completion=%llu source-completion=%llu source=%s "
            "source-lag-ns=%llu freshness=%s published=%s sequence=%llu\n",
            requesterPID, (unsigned long long)minimumCompletionTime,
            (unsigned long long)sourceCompletionTime,
            sourceReady ? "ready" : "unavailable",
            (unsigned long long)sourceLagNS,
            published ? "source-fresh-replay-copy-completed"
                : (!sourceReady ? "source-unavailable"
                    : (!sourceFresh ? "source-stale"
                                    : "replay-copy-failed")),
            published ? "YES" : "NO",
            (unsigned long long)MacWSFinalCompositePublisherPublishedSequence());
    }
    ReleaseObject(queue);
    ReleaseObject(sourceTexture);
}

static void DrainReplaySnapshotWork(void) {
    for (;;) {
        pid_t requesterPID = 0;
        uint64_t minimumCompletionTime = 0;
        pthread_mutex_lock(&ReplayWorkLock);
        requesterPID = PendingReplayRequesterPID;
        minimumCompletionTime = PendingReplayMinimumCompletionTime;
        PendingReplayRequesterPID = 0;
        PendingReplayMinimumCompletionTime = 0;
        if (requesterPID <= 1 || minimumCompletionTime == 0) {
            ReplayWorkScheduled = false;
            pthread_mutex_unlock(&ReplayWorkLock);
            return;
        }
        pthread_mutex_unlock(&ReplayWorkLock);
        PublishReplaySnapshot(requesterPID, minimumCompletionTime);
    }
}

static void ScheduleReplaySnapshot(pid_t requesterPID,
                                   uint64_t minimumCompletionTime) {
    bool startWorker = false;
    pthread_mutex_lock(&ReplayWorkLock);
    if (PendingReplayRequesterPID != requesterPID) {
        // A displayd relaunch starts a new authenticated request generation;
        // its startup minimum of 1 must not be shadowed by the old process's
        // larger graph timestamp.
        PendingReplayRequesterPID = requesterPID;
        PendingReplayMinimumCompletionTime = minimumCompletionTime;
    } else if (minimumCompletionTime >
               PendingReplayMinimumCompletionTime) {
        PendingReplayMinimumCompletionTime = minimumCompletionTime;
    }
    if (!ReplayWorkScheduled) {
        ReplayWorkScheduled = true;
        startWorker = true;
    }
    pthread_mutex_unlock(&ReplayWorkLock);
    if (startWorker) {
        dispatch_async(ReplayQueue(), ^{
            DrainReplaySnapshotWork();
        });
    }
}

static void *ReplayReceiveThreadMain(void *context) {
    (void)context;
    pthread_setname_np("macws.final-replay-rx");
    for (;;) {
        @autoreleasepool {
            _Alignas(8) uint8_t bytes[
                sizeof(MacWSFinalCompositeReplayMachMessage) +
                MAX_TRAILER_SIZE] = {0};
            MacWSFinalCompositeReplayMachMessage *message =
                (MacWSFinalCompositeReplayMachMessage *)bytes;
            mach_msg_return_t received = mach_msg(
                &message->header,
                MACH_RCV_MSG |
                    MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                0, sizeof(bytes), ReplayReceivePort,
                MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
            if (received == MACH_RCV_INTERRUPTED) continue;
            if (received != MACH_MSG_SUCCESS) {
                uint32_t witness = NextReplayFailureWitness();
                if (witness <= 12) {
                    dprintf(STDERR_FILENO,
                        "#### FINAL-COMPOSITE replay-receive-failed "
                        "witness=%u kr=%d\n", witness, received);
                }
                break;
            }

            mach_msg_audit_trailer_t *trailer =
                (mach_msg_audit_trailer_t *)(bytes +
                    round_msg(message->header.msgh_size));
            BOOL trailerValid = (uint8_t *)(trailer + 1) <=
                    bytes + sizeof(bytes) &&
                trailer->msgh_trailer_type == MACH_MSG_TRAILER_FORMAT_0 &&
                trailer->msgh_trailer_size >= sizeof(*trailer);
            pid_t senderPID = trailerValid
                ? audit_token_to_pid(trailer->msgh_audit) : -1;
            BOOL envelopeValid = message->header.msgh_id ==
                    MACWS_FINAL_COMPOSITE_REPLAY_MACH_MESSAGE_ID &&
                message->header.msgh_size == sizeof(*message) &&
                !(message->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
                trailerValid;
            BOOL recordValid = MacWSFinalCompositeReplayRecordIsValid(
                &message->record, sizeof(message->record));
            BOOL identityValid = recordValid &&
                message->record.requesterPID == senderPID &&
                ReplayRequesterIsDisplayd(senderPID);
            if (!envelopeValid || !identityValid) {
                uint32_t witness = NextReplayFailureWitness();
                if (witness <= 12) {
                    dprintf(STDERR_FILENO,
                        "#### FINAL-COMPOSITE replay-rejected witness=%u "
                        "sender=%d envelope=%s record=%s identity=%s\n",
                        witness, senderPID,
                        envelopeValid ? "valid" : "invalid",
                        recordValid ? "valid" : "invalid",
                        identityValid ? "valid" : "invalid");
                }
                continue;
            }
            uint64_t receiveCount = atomic_fetch_add_explicit(
                &ReplayReceivedRequests, 1, memory_order_relaxed) + 1;
            if (receiveCount <= 12 || receiveCount % 64 == 0) {
                dprintf(STDERR_FILENO,
                    "#### FINAL-COMPOSITE replay-received count=%llu "
                    "requester=%d min-completion=%llu\n",
                    (unsigned long long)receiveCount, senderPID,
                    (unsigned long long)
                        message->record.minimumCompletionTime);
            }
            ScheduleReplaySnapshot(
                senderPID, message->record.minimumCompletionTime);
        }
    }
    return NULL;
}

static void StartReplayRequestReceiver(void) {
    if (atomic_load_explicit(&ReplayReceiverStarted, memory_order_acquire))
        return;
    pthread_mutex_lock(&ReplayReceiverLock);
    if (atomic_load_explicit(&ReplayReceiverStarted,
                             memory_order_relaxed)) {
        pthread_mutex_unlock(&ReplayReceiverLock);
        return;
    }
    mach_port_t receivePort = MACH_PORT_NULL;
    kern_return_t result = bootstrap_check_in(
        bootstrap_port, MACWS_FINAL_COMPOSITE_REPLAY_MACH_SERVICE,
        &receivePort);
    if (result != BOOTSTRAP_SUCCESS || !MACH_PORT_VALID(receivePort)) {
        uint32_t witness = NextReplayFailureWitness();
        if (witness <= 12) {
            dprintf(STDERR_FILENO,
                "#### FINAL-COMPOSITE replay-check-in-failed "
                "witness=%u service=%s kr=%#x port=%u\n", witness,
                MACWS_FINAL_COMPOSITE_REPLAY_MACH_SERVICE, result,
                receivePort);
        }
        pthread_mutex_unlock(&ReplayReceiverLock);
        return;
    }
    ReplayReceivePort = receivePort;
    pthread_t receiverThread;
    int threadResult = pthread_create(&receiverThread, NULL,
                                      ReplayReceiveThreadMain, NULL);
    if (threadResult != 0) {
        uint32_t witness = NextReplayFailureWitness();
        dprintf(STDERR_FILENO,
            "#### FINAL-COMPOSITE replay-thread-create-failed "
            "witness=%u errno=%d port=%u\n", witness, threadResult,
            receivePort);
        pthread_mutex_unlock(&ReplayReceiverLock);
        return;
    }
    (void)pthread_detach(receiverThread);
    atomic_store_explicit(&ReplayReceiverStarted, true,
                          memory_order_release);
    dprintf(STDERR_FILENO,
        "#### FINAL-COMPOSITE replay-receiver-ready service=%s port=%u "
        "transport=pthread-blocking work=latest-coalesced\n",
        MACWS_FINAL_COMPOSITE_REPLAY_MACH_SERVICE, receivePort);
    pthread_mutex_unlock(&ReplayReceiverLock);
}

void MacWSFinalCompositePublisherEnqueueCompletion(
        id<MTLCommandBuffer> commandBuffer, id<MTLTexture> sourceTexture,
        IOSurfaceRef surface,
        uint32_t metalPixelFormat) {
    if (!commandBuffer || !sourceTexture || !surface || metalPixelFormat !=
            MACWS_FINAL_COMPOSITE_METAL_BGRA8_UNORM) return;
    (void)PublisherStateLock();
    if (!MacWSFinalCompositePublisherCanPublish()) return;

    id<MTLCommandQueue> queue = commandBuffer.commandQueue;
    id<MTLDevice> device = sourceTexture.device;
    size_t width = sourceTexture.width;
    size_t height = sourceTexture.height;
    if (!queue || !device || width == 0 || height == 0) {
        SnapshotLogFailure("enqueue-source", sourceTexture);
        return;
    }

    // The direct path is a diagnostic which deliberately exposes the reused
    // producer IOSurface. Keep it off the production snapshot-slot protocol.
    if (DirectCompositeTransportRequested()) {
        id<MTLCommandBuffer> retainedCommand = RetainObject(commandBuffer);
        id<MTLTexture> retainedSource = RetainObject(sourceTexture);
        IOSurfaceRef retainedSurface = (IOSurfaceRef)CFRetain(surface);
        dispatch_async(CompletionQueue(), ^{
            @autoreleasepool {
                MTLCommandBufferStatus status = retainedCommand.status;
                unsigned polls = 0;
                while (status != MTLCommandBufferStatusCompleted &&
                       status != MTLCommandBufferStatusError && polls < 2000) {
                    usleep(1000);
                    status = retainedCommand.status;
                    polls++;
                }
                if (status == MTLCommandBufferStatusCompleted &&
                    retainedCommand.error == nil) {
                    RememberReplaySource(retainedCommand.commandQueue,
                                         retainedSource,
                                         metalPixelFormat);
                    (void)MacWSFinalCompositePublisherPublishSurface(
                        retainedSurface, metalPixelFormat);
                }
                ReleaseObject(retainedCommand);
                ReleaseObject(retainedSource);
                CFRelease(retainedSurface);
            }
        });
        return;
    }

    MacWSFinalCompositeSnapshotSlot *slot = AcquireSnapshotSlot(
        device, width, height, sourceTexture);
    if (!slot) return;
    id<MTLCommandBuffer> copyCommand = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [copyCommand blitCommandEncoder];
    if (!copyCommand || !blit) {
        SnapshotLogFailure("enqueue-command", queue);
        ReleaseSnapshotSlot(slot, false);
        return;
    }
    [blit copyFromTexture:sourceTexture
              sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:slot->texture
         destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    // EndUpdate has already committed `commandBuffer`, and this function is
    // still executing on the producer thread. Commit the blit now so queue
    // ordering places it before WindowServer can submit the next reuse of the
    // display target. Only completion observation and Mach publication run on
    // the background serial queue.
    IOSurfaceRef retainedSurface = (IOSurfaceRef)CFRetain(slot->surface);
    [copyCommand addCompletedHandler:^(id<MTLCommandBuffer> completedCopy) {
        // The driver completion callback is the terminal-state witness. Move
        // service lookup and Mach publication onto the existing serial queue
        // so the AGX callback thread does not perform transport work, while
        // avoiding the former 500-us status polling wakeups on every frame.
        id<MTLCommandBuffer> retainedCopy = RetainObject(completedCopy);
        dispatch_async(CompletionQueue(), ^{
            @autoreleasepool {
                MTLCommandBufferStatus status = retainedCopy.status;
                bool clean = status == MTLCommandBufferStatusCompleted &&
                    retainedCopy.error == nil;
                bool published = false;
                if (clean) {
                    // The completed independent snapshot, not WindowServer's
                    // producer command graph, is the recovery source. This
                    // releases the producer texture and all command-buffer
                    // dependencies after Metal's own completion lifetime.
                    RememberReplaySource(retainedCopy.commandQueue,
                                         slot->texture,
                                         metalPixelFormat);
                    published = MacWSFinalCompositePublisherPublishSurface(
                        retainedSurface, metalPixelFormat);
                } else {
                    SnapshotLogFailure("ordered-copy-completion",
                                       retainedCopy);
                }
                ReleaseSnapshotSlot(slot, published);
                ReleaseObject(retainedCopy);
                CFRelease(retainedSurface);
            }
        });
    }];
    [copyCommand commit];
}
