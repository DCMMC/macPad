#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <xpc/xpc.h>

#include "macws_menu_protocol.h"
#include "macws_display_geometry.h"
#include "macws_host_protocol.h"
#include "macws_stream_protocol.h"
#import "MacWSFinalCompositeReceiver.h"

// macOS 13.4 SkyLight RE witness (binary UUID
// 96676A53-B1E0-3D7E-B98B-B73873CD1880):
// SLSHWCaptureStreamCreateWithWindow at 0x185210714 preserves x0..x4 as
// window ID, frame-shape-selection flag, properties, dispatch queue, and frame
// handler. RE witness: x0 is passed to CGSLocalWindowByID during preflight;
// WindowServer's CGXHWCaptureStreamCreate stores x1 at WSCaptureStream+0x40,
// and WSCaptureStreamStart reads that byte to select
// CGXCopyScreenFrameShapeForWindow (true) instead of
// CGXCopyScreenContentShapeForWindow (false). The producer selects the content
// shape so non-content pixels are not deliberately added to the touch target;
// exact surface-to-NSWindow.frame congruence remains a device runtime gate.
// Keep this private dependency isolated here so the rest of the wire protocol
// and Host do not depend on SkyLight declarations.
typedef CGDisplayStreamRef (*MacWSSLSWindowStreamCreate)(
    uint32_t windowID, bool useScreenFrameShape, CFDictionaryRef properties,
    dispatch_queue_t queue, CGDisplayStreamFrameAvailableHandler handler);

static dispatch_queue_t DisplayQueue;
static dispatch_queue_t MenuQueue;
// Presentation-only SkyLight description calls can synchronously stall for
// 90+ ms at their tail even though their median cost is below 1 ms. Keep those
// calls off DisplayQueue: exact-window capture callbacks, leases and input-
// correlated content frames must remain drainable while WindowServer answers
// a Mission Control geometry query.
static dispatch_queue_t WorkspaceGeometryQueue;
static NSMutableSet *Clients;
static NSMutableDictionary<NSNumber *, id> *Leases;
// The latest WindowServer-owned final AGX composite is retained independently
// of any Host Scene. A foreground fullscreen subscriber can therefore acquire
// the current native desktop immediately without waiting for unrelated damage.
static IOSurfaceRef FinalCompositeSurface;
static MacWSFinalCompositeRecord FinalCompositeRecord;
// A final-composite frame remains authoritative while the desktop is static:
// expiring it merely because no new frame arrived discards SkyLight's native
// Dock/menu material and shadow pixels.  The exact-window graph provides the
// missing invalidation witness.  Only when that graph observes newer content,
// geometry or topology and WindowServer's final composite has not caught up
// within one second do we retire the obsolete snapshot.  A subsequent
// validated final snapshot naturally reacquires the base.
static dispatch_source_t FinalCompositeExpiryTimer;
static uint64_t WorkspaceGraphMutationTime;
static NSString *WorkspaceGraphMutationReason;
static uint64_t FinalCompositeReplayRequestedThroughMutationTime;
static const uint64_t FinalCompositeCatchUpNanoseconds = NSEC_PER_SEC;
// A SkyLight popup can disappear while its final AGX command buffer is still
// retiring.  Keep the capture object alive for a bounded grace period instead
// of synchronously stopping it from the catalog-removal stack.
static NSMutableArray *RetiredTransientLayers;
// A Mission Control transition removes several full-Retina Dock capture
// windows in the same catalog transaction.  Their five-second reuse grace
// therefore expires on the same DisplayQueue turn.  Stopping all of those
// streams in one call stack recreates the AGX/WindowServer teardown burst that
// RetireFullscreenClientStaggered already avoids.  Drain validated retirements
// one display interval apart while preserving the existing reuse grace.
static NSMutableArray *RetiredTransientStopBlocks;
static BOOL RetiredTransientStopDrainPending;
static uint64_t NextStreamID = 1;
static uint64_t NextLeaseToken = 1;
static int InvalidationSocket = -1;
static dispatch_source_t InvalidationSource;
static BOOL TransientReconcilePending;
// Every request receives a generation. An urgent event-driven reconcile can
// therefore supersede the slow correctness poll already queued for 100/250ms
// instead of being rejected by its pending bit.
static uint64_t TransientReconcileGeneration;
// A completed semantic pointer click is an authoritative catalog edge: the
// target process emits it only after AppKit's synchronous control/menu tracker
// has returned.  Keep two independent post-click CGWindow snapshots (one
// display interval apart) so a genuinely dismissed popup disappears promptly,
// while the ordinary recovery poll retains its more conservative three-miss
// policy for uncorrelated catalog churn.
static unsigned UrgentTransientRetirePasses;
// Dock's native Mission Control/App Expose/Spaces animations move existing
// SkyLight windows without sending the AppKit geometry sidecar datagrams used
// by ordinary window moves.  A one-second idle recovery scan therefore turns
// a continuous native gesture into a handful of Host compositor positions.
// Dock emits the lightweight 'a' invalidation only after its real
// DOCKGestures handler consumes a progress sample.  Keep the expensive desktop
// catalog scan at display cadence only while those samples are arriving, then
// retain a short tail so Dock's spring/settlement animation is captured too.
static CFTimeInterval WorkspaceAnimationSamplingDeadline;
// Dock owns a spring after the last input sample. Continue only while real
// SkyLight presentation geometry is still changing, with this hard bound so a
// noisy catalog can never turn one gesture into permanent high-rate polling.
static CFTimeInterval WorkspaceAnimationSettlementHardDeadline;
// AppKit window move/resize notifications are authoritative producer edges,
// unlike Dock's best-effort animation pulse. Give them a separate sliding
// sampling tail so a long title-bar drag stays smooth without weakening the
// immutable bound which protects against a noisy Dock animation source.
static CFTimeInterval WorkspaceAppKitGeometrySamplingDeadline;
static BOOL WorkspaceGeometryQueryInFlight;
static BOOL WorkspaceGeometryQueryPending;
static BOOL WorkspaceGeometryBurstActive;
static uint64_t WorkspaceGeometryQueryGeneration;
static uint64_t WorkspaceGeometryQuerySamples;
static uint64_t WorkspaceGeometryRecordsSent;
static double WorkspaceGeometryQueryDurationsMS[256];
static NSUInteger WorkspaceGeometryQueryDurationCount;
static NSUInteger WorkspaceGeometryQueryDurationCursor;
static BOOL CatalogBroadcastPending;
static _Atomic uint64_t GeometryRestartSerial;
static NSMutableDictionary<NSNumber *, NSValue *> *GeometryTargets;
static CGFloat ObservedWindowBackingScale;
static CGFloat AppKitMainDisplayBackingScale;

static inline CFTimeInterval WorkspaceGeometrySamplingDeadline(void) {
    return fmax(WorkspaceAnimationSamplingDeadline,
                WorkspaceAppKitGeometrySamplingDeadline);
}
// The heartbeat shares MacWSStreamClient's ordered queue with frame-lease
// releases from every workspace layer. Runtime-confirmed during Stray's
// first fullscreen graph transition: a 750 ms lease repeatedly expired even
// while completed direct drawables continued arriving at Host. Three seconds
// absorbs that bounded control-plane backlog while still restoring exact
// capture promptly after a game exit or producer failure.
static const CFTimeInterval MacWSDirectDrawableLeaseSeconds = 3.0;
static int DirectDrawableActivityDescriptor = -1;
static int FocusedRenderAuthorityDescriptor = -1;
static NSString *const FinalCompositeStatePath =
    @"/private/tmp/macws_final_composite.state";
// The final WindowServer composite is the preferred desktop-material source,
// but it is not the only pixel-valid presentation route.  A fullscreen Space
// teardown can leave the publisher without a compositor command newer than
// the topology mutation while the exact Dock wallpaper, Dock and WindowServer
// menubar IOSurfaces are all current. Those three layers are a complete
// visible desktop: the wallpaper is the opaque canvas and the latter two add
// the native glass surfaces. WindowServer's optional negative-level Desktop
// backing can disappear after a fullscreen Space teardown without removing
// visible pixels. Publish that independent graph witness so Repair Desktop
// can distinguish a verified layer fallback from a genuinely blank workspace
// instead of destructively rebuilding the whole WindowServer session.
static NSString *const WorkspaceGraphStatePath =
    @"/private/tmp/macws_workspace_graph.state";
static uint64_t WorkspaceGraphStateSignature;
@class MacWSDisplayClient;
@class MacWSTransientLayer;
static void ScheduleTransientReconcile(uint64_t delayNanoseconds);
static void RequestWorkspaceGeometrySample(void);
static void ScheduleGeometryStreamRestart(void);
static void ScheduleCatalogBroadcast(void);
static void EnqueueRetiredTransientStop(dispatch_block_t stopBlock);
static void SuspendFullscreenLayerCapturesForFinalComposite(void);
static void ResumeFullscreenLayerCapturesForFallback(void);
static void ClearDirectDrawableActivity(MacWSDisplayClient *client,
                                        NSString *reason);
static void StartClientStream(MacWSDisplayClient *client);
static NSDictionary<NSNumber *, NSData *> *CopyWindowMetrics(int32_t pid);

extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer,
                        int buffersize);

static uint64_t MonotonicNanoseconds(void) {
    struct timespec value = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * NSEC_PER_SEC + (uint64_t)value.tv_nsec;
}

static void PublishDirectDrawablePacingLease(
        int32_t ownerPID, uint32_t layerWindowID,
        uint32_t width, uint32_t height) {
    uint64_t now = MonotonicNanoseconds();
    if (!now || ownerPID <= 1 || !layerWindowID || !width || !height) return;
    if (DirectDrawableActivityDescriptor < 0) {
        DirectDrawableActivityDescriptor = open(
            MACWS_DIRECT_DRAWABLE_ACTIVITY_PATH,
            O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
    }
    if (DirectDrawableActivityDescriptor < 0) return;
    MacWSDirectDrawableActivityRecord record = {
        .magic = MACWS_DIRECT_DRAWABLE_ACTIVITY_MAGIC,
        .version = MACWS_DIRECT_DRAWABLE_ACTIVITY_VERSION,
        .size = sizeof(record),
        .timestampNS = now,
        .ownerPID = ownerPID,
        .layerWindowID = layerWindowID,
        .width = width,
        .height = height,
    };
    if (pwrite(DirectDrawableActivityDescriptor, &record,
               sizeof(record), 0) != sizeof(record) ||
        ftruncate(DirectDrawableActivityDescriptor, sizeof(record)) != 0) {
        close(DirectDrawableActivityDescriptor);
        DirectDrawableActivityDescriptor = -1;
        (void)unlink(MACWS_DIRECT_DRAWABLE_ACTIVITY_PATH);
    }
}

static void RetireDirectDrawablePacingLease(void) {
    if (DirectDrawableActivityDescriptor >= 0) {
        close(DirectDrawableActivityDescriptor);
        DirectDrawableActivityDescriptor = -1;
    }
    (void)unlink(MACWS_DIRECT_DRAWABLE_ACTIVITY_PATH);
}

static void RetireFocusedRenderAuthority(void) {
    if (FocusedRenderAuthorityDescriptor >= 0) {
        close(FocusedRenderAuthorityDescriptor);
        FocusedRenderAuthorityDescriptor = -1;
    }
    (void)unlink(MACWS_RENDER_AUTHORITY_PATH);
}

static BOOL PublishFocusedRenderAuthority(MacWSTransientLayer *layer);
static BOOL PublishFocusedWindowClientAuthorityIfAvailable(void);

static void DisplayLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static BOOL MacWSDisplayDiagnosticsEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *value = getenv("MACWS_DISPLAY_DIAGNOSTICS");
        enabled = value && value[0] && strcmp(value, "0") != 0;
    });
    return enabled;
}

static void DisplayLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "MACWS-DISPLAY %s\n", message.UTF8String);
    fflush(stderr);
}

static void WriteFinalCompositeState(NSString *state, pid_t producerPID,
                                     uint64_t sequence, NSString *reason) {
    // Runtime-confirmed disk-writes report C8090A4D-3011-4581-B452-
    // 2E5C461EDCCB maps its heaviest stack to this diagnostic atomic rename:
    // 1073.75 MB dirtied in 5257 seconds. XPC carries every completed frame;
    // this sidecar is only a human/pipeline status witness, not a frame fence.
    // Publish state/producer transitions immediately, but coalesce unchanged
    // status heartbeats BEFORE allocating/writing another payload.
    static NSString *lastState;
    static NSString *lastReason;
    static pid_t lastProducer;
    static NSTimeInterval lastAttempt;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL changed = ![lastState isEqualToString:state] ||
        ![lastReason isEqualToString:reason] || lastProducer != producerPID;
    if (!changed && now - lastAttempt < 5.0) return;
    lastState = [state copy];
    lastReason = [reason copy];
    lastProducer = producerPID;
    lastAttempt = now;
    NSString *payload = [NSString stringWithFormat:
        @"state=%@\nproducer=%d\nsequence=%llu\nupdated=%.6f\nreason=%@\n",
        state ?: @"missing", producerPID, (unsigned long long)sequence,
        NSDate.date.timeIntervalSince1970, reason ?: @""];
    NSError *error = nil;
    if (![payload writeToFile:FinalCompositeStatePath atomically:YES
                     encoding:NSUTF8StringEncoding error:&error]) {
        DisplayLog(@"final-composite-state-write-failed state=%@ error=%@",
                   state ?: @"missing", error.localizedDescription ?: @"");
    }
}

@interface MacWSDisplayLease : NSObject
@property(nonatomic) uint64_t token;
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic, weak) id owner;
@property(nonatomic) uint32_t layerWindowID;
@property(nonatomic) BOOL holdsSurfaceUseCount;
@end

@implementation MacWSDisplayLease
- (void)dealloc {
    if (_surface && _holdsSurfaceUseCount)
        IOSurfaceDecrementUseCount(_surface);
    if (_surface) CFRelease(_surface);
}
@end

@interface MacWSTransientLayer : NSObject {
    IOSurfaceRef _latestSurface;
    // One fixed, allocation-free ring is enough to score an active native
    // animation burst.  A gap is deliberately excluded: Mission Control can
    // remain open and static between its enter and exit animations, and the
    // old first-to-last calculation therefore reported 28 fps for a healthy
    // producer simply because the tester inspected the screen for a second.
    double _activeFrameIntervalsMS[512];
    NSUInteger _activeFrameIntervalCount;
    NSUInteger _activeFrameIntervalCursor;
}
@property(nonatomic, weak) MacWSDisplayClient *client;
@property(nonatomic) uint32_t windowID;
@property(nonatomic) int32_t ownerPID;
@property(nonatomic, copy) NSString *ownerName;
@property(nonatomic, copy) NSString *windowName;
@property(nonatomic) NSInteger skyLightLayer;
@property(nonatomic) int32_t level;
// AppInputBridge's semantic flags for this exact AppKit window. The final
// composite producer owns ordinary AppKit pixels and native effects; this
// exact layer remains the identity/geometry witness and the bounded fallback
// source if that final producer becomes unavailable.
@property(nonatomic) MacWSStreamWindowFlags windowFlags;
@property(nonatomic) CGRect destinationBounds;
@property(nonatomic) CGRect popupCompositeSource;
@property(nonatomic) uint64_t popupCompositeMinimumTime;
@property(nonatomic) BOOL popupCompositeEligible;
@property(nonatomic) BOOL popupCompositeReported;
@property(nonatomic) uint64_t lastPopupCompositeSequence;
@property(nonatomic) uint64_t streamID;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) uint64_t firstDisplayTime;
@property(nonatomic) uint64_t droppedFrames;
@property(nonatomic) NSUInteger missCount;
@property(nonatomic) CGDisplayStreamRef stream;
@property(nonatomic) IOSurfaceRef latestSurface;
@property(nonatomic) uint64_t latestDisplayTime;
@property(nonatomic) BOOL oneShotCapture;
@property(nonatomic) BOOL snapshotComplete;
// A completed WindowServer final composite contains desktop material. Keep
// catalog/geometry identity for every layer, but suspend full-resolution
// capture for layers outside the focused application until fallback needs it.
@property(nonatomic) BOOL finalCompositeCaptureSuspensionPending;
// The foreground Host is presenting this exact layer's completed
// CAMetalDrawable. Keep the last captured surface for fallback/hit testing,
// but stop its duplicate full-resolution SkyLight capture until the bounded
// activity lease expires.
@property(nonatomic) BOOL directDrawableCaptureSuspended;
@property(nonatomic) BOOL directDrawableCaptureSuspensionPending;
@property(nonatomic) BOOL reportedDirectDrawableFocusedLevelAcceptance;
// CGWindowListCreateDescriptionFromArray can expose a live presentation
// rectangle in backing pixels even though the ordinary window catalog uses
// AppKit points.  Record the first surface-backed normalization so the exact
// coordinate-space decision remains visible in runtime evidence.
@property(nonatomic) BOOL reportedPresentationScaleNormalization;
@property(nonatomic) BOOL retiring;
@property(nonatomic) uint64_t retirementGeneration;
- (void)recordActiveFrameAtDisplayTime:(uint64_t)displayTime;
- (void)finishActiveFrameBurstWithReason:(NSString *)reason;
- (void)stopCapturePreservingSurface;
- (void)stopStream;
@end

@implementation MacWSTransientLayer
- (void)dealloc {
    [self stopStream];
    self.latestSurface = NULL;
}
- (IOSurfaceRef)latestSurface { return _latestSurface; }
- (void)setLatestSurface:(IOSurfaceRef)surface {
    if (_latestSurface == surface) return;
    if (surface) CFRetain(surface);
    if (_latestSurface) CFRelease(_latestSurface);
    _latestSurface = surface;
}

static int MacWSCompareFrameInterval(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

- (void)finishActiveFrameBurstWithReason:(NSString *)reason {
    if (!MacWSDisplayDiagnosticsEnabled()) {
        _activeFrameIntervalCount = 0;
        _activeFrameIntervalCursor = 0;
        return;
    }
    NSUInteger count = MIN(_activeFrameIntervalCount,
                           sizeof(_activeFrameIntervalsMS) /
                               sizeof(_activeFrameIntervalsMS[0]));
    if (count >= 8) {
        double intervals[512];
        double total = 0.0;
        for (NSUInteger index = 0; index < count; index++) {
            intervals[index] = _activeFrameIntervalsMS[index];
            total += intervals[index];
        }
        qsort(intervals, count, sizeof(intervals[0]),
              MacWSCompareFrameInterval);
        NSUInteger p50Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.50) - 1);
        NSUInteger p99Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.99) - 1);
        double meanInterval = total / count;
        double p50 = intervals[p50Index];
        double p99 = intervals[p99Index];
        DisplayLog(@"active-frame-burst layer=%u owner=%@ reason=%@ "
                   "intervals=%lu average-fps=%.2f p50-ms=%.3f "
                   "p99-ms=%.3f one-percent-low-fps=%.2f",
                   self.windowID, self.ownerName ?: @"", reason ?: @"end",
                   (unsigned long)count,
                   meanInterval > 0.0 ? 1000.0 / meanInterval : 0.0,
                   p50, p99, p99 > 0.0 ? 1000.0 / p99 : 0.0);
    }
    _activeFrameIntervalCount = 0;
    _activeFrameIntervalCursor = 0;
}

- (void)recordActiveFrameAtDisplayTime:(uint64_t)displayTime {
    if (!MacWSDisplayDiagnosticsEnabled()) return;
    if (!_latestDisplayTime || displayTime <= _latestDisplayTime) return;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
    if (!timebase.denom) return;
    double intervalMS = (double)(displayTime - _latestDisplayTime) *
        timebase.numer / timebase.denom / 1.0e6;
    // A native animation produces no CGDisplayStream callback while its layer
    // is static.  Split at that real producer gap instead of counting idle
    // inspection time as dropped frames.  Very small/non-finite timestamps
    // are invalid timing samples, not zero-latency frames.
    if (!isfinite(intervalMS) || intervalMS < 0.05) return;
    if (intervalMS > 150.0) {
        [self finishActiveFrameBurstWithReason:@"producer-gap"];
        return;
    }
    NSUInteger capacity = sizeof(_activeFrameIntervalsMS) /
        sizeof(_activeFrameIntervalsMS[0]);
    _activeFrameIntervalsMS[_activeFrameIntervalCursor] = intervalMS;
    _activeFrameIntervalCursor = (_activeFrameIntervalCursor + 1) % capacity;
    if (_activeFrameIntervalCount < capacity) _activeFrameIntervalCount++;
}
- (void)stopCapturePreservingSurface {
    if (_stream) {
        CGDisplayStreamStop(_stream);
        CFRelease(_stream);
        _stream = NULL;
    }
    _sequence = 0;
}
- (void)stopStream {
    [self stopCapturePreservingSurface];
    self.latestSurface = NULL;
    _latestDisplayTime = 0;
    _snapshotComplete = NO;
}
@end

static BOOL PublishFocusedRenderAuthorityIdentity(
        int32_t ownerPID, uint32_t windowID, size_t width, size_t height) {
    uint64_t now = MonotonicNanoseconds();
    if (!now || ownerPID <= 1 || windowID == 0 || width == 0 ||
        height == 0 || width > UINT32_MAX || height > UINT32_MAX)
        return NO;
    if (FocusedRenderAuthorityDescriptor < 0) {
        FocusedRenderAuthorityDescriptor = open(
            MACWS_RENDER_AUTHORITY_PATH,
            O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
    }
    if (FocusedRenderAuthorityDescriptor < 0) return NO;
    MacWSRenderAuthorityRecord record = {
        .magic = MACWS_RENDER_AUTHORITY_MAGIC,
        .version = MACWS_RENDER_AUTHORITY_VERSION,
        .size = sizeof(record),
        .timestampNS = now,
        .ownerPID = ownerPID,
        .layerWindowID = windowID,
        .width = (uint32_t)width,
        .height = (uint32_t)height,
    };
    if (pwrite(FocusedRenderAuthorityDescriptor, &record,
               sizeof(record), 0) != sizeof(record) ||
        ftruncate(FocusedRenderAuthorityDescriptor, sizeof(record)) != 0) {
        RetireFocusedRenderAuthority();
        return NO;
    }
    return YES;
}

static BOOL PublishFocusedRenderAuthority(MacWSTransientLayer *layer) {
    if (!layer || layer.retiring || layer.ownerPID <= 1 ||
        layer.windowID == 0 || !layer.latestSurface)
        return NO;
    return PublishFocusedRenderAuthorityIdentity(
        layer.ownerPID, layer.windowID,
        IOSurfaceGetWidth(layer.latestSurface),
        IOSurfaceGetHeight(layer.latestSurface));
}

static BOOL LayerCanAuthorizeFocusedRender(MacWSTransientLayer *layer) {
    if (!layer || layer.retiring || layer.ownerPID <= 1 ||
        layer.skyLightLayer < 0 || !layer.latestSurface) return NO;
    MacWSStreamWindowFlags required = MacWSStreamWindowFocused |
        MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
    return (layer.windowFlags & required) == required;
}

static BOOL LayerNeedsIndependentFinalCompositeCapture(
        MacWSTransientLayer *layer) {
    if (!layer || layer.retiring || layer.ownerPID <= 1 ||
        layer.skyLightLayer < 0) return NO;
    // Stray's AppKit fullscreen transition runtime-publishes 0x140
    // (Focused|FullscreenCanvas) while the same window remains in the real
    // CGWindow desktop catalog. Requiring the ordinary Visible/OnScreen bits
    // here stopped its only pixel stream even though the bundle-level canvas
    // capability and live catalog identity were still authoritative.
    if ((layer.windowFlags & MacWSStreamWindowFullscreenCanvas) != 0)
        return YES;
    MacWSStreamWindowFlags visible =
        MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
    if ((layer.windowFlags & visible) != visible) return NO;
    // The owned-scanout FinalComposite contains ordinary focused AppKit
    // windows, their native external shadows and the desktop effects around
    // them. Capture one exact frame when a new focused window first appears
    // so Host retains its identity/geometry and Catalyst can join a separately
    // completed CAMetalLayer. Once that witness exists, continuing the
    // duplicate full-resolution stream only redraws pixels which the final
    // composite already owns. Runtime-confirmed on iPad14,5 with VS Code's
    // 60k-fish WebGL workload: retaining this exact stream doubled Host input
    // from 145 to 290 frames in 15.11 s, but both it and FinalComposite stayed
    // at 9.86 FPS and Host still presented only 147 frames. The common
    // WindowServer completion pace is upstream of both capture routes.
    // A final-composite expiry resumes every exact stream through
    // ResumeFullscreenLayerCapturesForFallback().
    return (layer.windowFlags & MacWSStreamWindowFocused) != 0 &&
        layer.latestSurface == NULL;
}

@interface MacWSDisplayClient : NSObject
@property(nonatomic) xpc_connection_t connection;
// A full-desktop subscription owns a complete SkyLight capture graph (menu
// bar, Dock, wallpaper and every visible window).  It is deliberately
// exclusive: duplicating that graph for two Host Scenes creates two sets of
// full-Retina capture streams inside the same WindowServer.
@property(nonatomic) BOOL subscriptionActive;
@property(nonatomic) MacWSStreamMode mode;
@property(nonatomic) uint32_t windowID;
@property(nonatomic) uint64_t streamID;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) CGDisplayStreamRef stream;
@property(nonatomic) IOSurfaceRef workspaceCanvas;
@property(nonatomic) uint64_t droppedFrames;
@property(nonatomic) uint64_t firstDisplayTime;
@property(nonatomic) CGFloat windowBackingScale;
@property(nonatomic) size_t lastSurfaceWidth;
@property(nonatomic) size_t lastSurfaceHeight;
// SendWindowList derives this exact identity from WindowServer's live
// front-to-back on-screen list joined to AppInput's focused-window metrics.
// A window-mode capture needs the same authority as the fullscreen layer
// graph; otherwise ordinary Chromium/video damage remains on WindowServer's
// 100-ms static-desktop completion cadence.
@property(nonatomic) int32_t catalogFrontmostOwnerPID;
@property(nonatomic) uint32_t catalogFrontmostWindowID;
// CGDisplayStreamStop is asynchronous.  A generation token keeps a delayed
// exact-window recreation from resurrecting an obsolete Scene subscription.
@property(nonatomic) uint64_t geometryRestartGeneration;
@property(nonatomic) NSMutableDictionary<NSNumber *, MacWSTransientLayer *> *transientLayers;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *outstandingByLayer;
// A release token is the end-to-end witness that this XPC client imported at
// least one IOSurface frame. Connection-ready and catalog messages contain no
// Mach surface right and therefore cannot establish this transport invariant.
@property(nonatomic) BOOL frameAcknowledged;
// A fullscreen Host can be relaunched or have its UIWindowScene recreated
// while WindowServer keeps producing the same desktop. Keep a generation for
// the bounded disconnect handoff instead of tearing down the whole capture
// graph synchronously from the XPC error callback.
@property(nonatomic) uint64_t disconnectGeneration;
@property(nonatomic) BOOL deliveryPaused;
@property(nonatomic) BOOL directDrawableActive;
@property(nonatomic) BOOL directDrawableExpiryPending;
@property(nonatomic) CFTimeInterval directDrawableDeadline;
@property(nonatomic) int32_t directDrawableOwnerPID;
@property(nonatomic) uint32_t directDrawableLayerWindowID;
@property(nonatomic) uint32_t directDrawableWidth;
@property(nonatomic) uint32_t directDrawableHeight;
@property(nonatomic) CFTimeInterval directDrawableLastRejectionLogTime;
// A focused exact-window subscription has no MacWSTransientLayer wrapper.
// Track ownership of its base CGDisplayStream suspension on the client so a
// lost/changed Host heartbeat can restart that exact stream independently.
@property(nonatomic) BOOL directDrawableBaseCaptureSuspended;
@property(nonatomic) BOOL directDrawableBaseCaptureSuspensionPending;
@property(nonatomic) BOOL directDrawablePacingLeasePublished;
// Exact focused identities from the last catalog this client received.
// Retain the decision that Host acted on even if SkyLight changes the same
// window's presentation level before the first direct drawable heartbeat.
@property(nonatomic) NSDictionary<NSNumber *, NSNumber *> *focusedWindowOwners;
- (void)stopStream;
- (void)stopTransientLayers;
@end

@implementation MacWSDisplayClient
- (void)dealloc {
    [self stopTransientLayers];
    [self stopStream];
}
- (void)stopTransientLayers {
    for (MacWSTransientLayer *layer in _transientLayers.allValues)
        [layer stopStream];
    [_transientLayers removeAllObjects];
}
- (void)stopStream {
    if (_stream) {
        CGDisplayStreamStop(_stream);
        CFRelease(_stream);
        _stream = NULL;
    }
    if (_workspaceCanvas) {
        CFRelease(_workspaceCanvas);
        _workspaceCanvas = NULL;
    }
    _sequence = 0;
}
@end

static BOOL PublishFocusedWindowClientAuthorityIfAvailable(void) {
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused ||
            client.mode != MacWSStreamModeWindow || client.windowID == 0 ||
            client.windowID != client.catalogFrontmostWindowID ||
            client.catalogFrontmostOwnerPID <= 1 ||
            client.lastSurfaceWidth == 0 || client.lastSurfaceHeight == 0)
            continue;
        return PublishFocusedRenderAuthorityIdentity(
            client.catalogFrontmostOwnerPID, client.windowID,
            client.lastSurfaceWidth, client.lastSurfaceHeight);
    }
    return NO;
}

static BOOL MacWSLayerSurfaceMatchesSize(MacWSTransientLayer *layer,
                                         size_t width, size_t height) {
    return layer.latestSurface &&
        IOSurfaceGetWidth(layer.latestSurface) == width &&
        IOSurfaceGetHeight(layer.latestSurface) == height;
}

static BOOL MacWSLayerDestinationMatchesCanvas(MacWSTransientLayer *layer,
                                               size_t width, size_t height) {
    CGRect destination = layer.destinationBounds;
    return !CGRectIsNull(destination) && !CGRectIsEmpty(destination) &&
        fabs(destination.origin.x) <= 0.5 &&
        fabs(destination.origin.y) <= 0.5 &&
        fabs(destination.size.width - width) <= 0.5 &&
        fabs(destination.size.height - height) <= 0.5;
}

// A fullscreen application's CGWindow can move above level zero while its
// drawable remains the workspace presentation. AppInput publishes the exact
// windowID+ownerPID identity and the Focused|FullscreenCanvas state for that
// transition. Once a direct-drawable heartbeat has arrived, the same exact
// identity remains authoritative through short AppKit focus-state changes.
// Neither path is PID-only, title-based, or geometry-based.
static BOOL MacWSLayerOwnsFullscreenCanvas(MacWSDisplayClient *client,
                                           MacWSTransientLayer *layer) {
    if (!client || !layer) return NO;
    MacWSStreamWindowFlags fullscreenAuthority =
        MacWSStreamWindowFocused | MacWSStreamWindowFullscreenCanvas;
    BOOL semanticAuthority =
        (layer.windowFlags & fullscreenAuthority) == fullscreenAuthority;
    BOOL directAuthority = client.directDrawableActive &&
        client.directDrawableOwnerPID == layer.ownerPID &&
        client.directDrawableLayerWindowID == layer.windowID;
    return semanticAuthority || directAuthority;
}

static CGRect MacWSWorkspaceLayerDestination(
        MacWSDisplayClient *client, MacWSTransientLayer *layer,
        CGRect windowBounds, CGRect desktopBounds, CGFloat presentationScale,
        BOOL usedSurfaceMeasurement) {
    BOOL coversDesktop = MacWSLayerCoversLogicalDisplay(
        windowBounds.origin.x, windowBounds.origin.y,
        windowBounds.size.width, windowBounds.size.height,
        desktopBounds.origin.x, desktopBounds.origin.y,
        desktopBounds.size.width, desktopBounds.size.height);
    if (client.workspaceCanvas &&
        (MacWSLayerOwnsFullscreenCanvas(client, layer) || coversDesktop)) {
        size_t width = IOSurfaceGetWidth(client.workspaceCanvas);
        size_t height = IOSurfaceGetHeight(client.workspaceCanvas);
        if (width && height)
            return CGRectMake(0.0, 0.0, width, height);
    }
    return CGRectMake(
        (windowBounds.origin.x - desktopBounds.origin.x) *
            presentationScale,
        (windowBounds.origin.y - desktopBounds.origin.y) *
            presentationScale,
        usedSurfaceMeasurement
            ? IOSurfaceGetWidth(layer.latestSurface)
            : windowBounds.size.width * presentationScale,
        usedSurfaceMeasurement
            ? IOSurfaceGetHeight(layer.latestSurface)
            : windowBounds.size.height * presentationScale);
}

static uint64_t MacWSWorkspaceGraphHash(NSString *payload) {
    const uint8_t *bytes = (const uint8_t *)payload.UTF8String;
    uint64_t hash = 1469598103934665603ULL;
    if (!bytes) return hash;
    for (size_t index = 0; bytes[index] != '\0'; index++) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static void UpdateWorkspaceGraphState(MacWSDisplayClient *client,
                                      NSString *reason) {
    if (!client || !client.subscriptionActive || client.deliveryPaused ||
        client.mode != MacWSStreamModeFullscreen || !client.workspaceCanvas)
        return;

    size_t canvasWidth = IOSurfaceGetWidth(client.workspaceCanvas);
    size_t canvasHeight = IOSurfaceGetHeight(client.workspaceCanvas);
    if (!canvasWidth || !canvasHeight) return;

    MacWSTransientLayer *wallpaper = nil;
    MacWSTransientLayer *dock = nil;
    MacWSTransientLayer *menubar = nil;
    MacWSTransientLayer *windowServerBacking = nil;
    for (MacWSTransientLayer *layer in client.transientLayers.allValues) {
        if (!layer || layer.retiring) continue;
        BOOL canvasDestination = MacWSLayerDestinationMatchesCanvas(
            layer, canvasWidth, canvasHeight);
        BOOL canvasSurface = MacWSLayerSurfaceMatchesSize(
            layer, canvasWidth, canvasHeight);
        if ([layer.ownerName isEqualToString:@"Dock"] &&
            layer.skyLightLayer < 0 &&
            [layer.windowName hasPrefix:@"Desktop Picture"] &&
            (!wallpaper || (canvasDestination && canvasSurface))) {
            wallpaper = layer;
        } else if ([layer.ownerName isEqualToString:@"Dock"] &&
                   layer.skyLightLayer > 0 &&
                   [layer.windowName isEqualToString:@"Dock"] &&
                   (!dock || (canvasDestination && canvasSurface))) {
            dock = layer;
        } else if ([layer.ownerName isEqualToString:@"Window Server"] &&
                   [layer.windowName isEqualToString:@"Menubar"] &&
                   (!menubar || (fabs(layer.destinationBounds.origin.x) <=
                                 0.5 && layer.latestSurface))) {
            menubar = layer;
        } else if ([layer.ownerName isEqualToString:@"Window Server"] &&
                   layer.skyLightLayer < 0 &&
                   [layer.windowName isEqualToString:@"Desktop"] &&
                   (!windowServerBacking ||
                    (canvasDestination && canvasSurface))) {
            windowServerBacking = layer;
        }
    }

    BOOL wallpaperReady = wallpaper &&
        MacWSLayerDestinationMatchesCanvas(wallpaper, canvasWidth,
                                           canvasHeight) &&
        MacWSLayerSurfaceMatchesSize(wallpaper, canvasWidth, canvasHeight);
    BOOL dockReady = dock &&
        MacWSLayerDestinationMatchesCanvas(dock, canvasWidth, canvasHeight) &&
        MacWSLayerSurfaceMatchesSize(dock, canvasWidth, canvasHeight);
    BOOL menubarReady = menubar && menubar.latestSurface &&
        fabs(menubar.destinationBounds.origin.x) <= 0.5 &&
        fabs(menubar.destinationBounds.origin.y) <= 0.5 &&
        fabs(menubar.destinationBounds.size.width - canvasWidth) <= 0.5 &&
        IOSurfaceGetWidth(menubar.latestSurface) == canvasWidth &&
        IOSurfaceGetHeight(menubar.latestSurface) > 0;
    BOOL backingReady = windowServerBacking &&
        MacWSLayerDestinationMatchesCanvas(windowServerBacking, canvasWidth,
                                           canvasHeight) &&
        MacWSLayerSurfaceMatchesSize(windowServerBacking, canvasWidth,
                                     canvasHeight) &&
        windowServerBacking.ownerPID > 1;
    // Runtime-confirmed after Stray fullscreen teardown on iPad13,6: the Host
    // automation screenshot at 1787730807 was pixel-complete while the graph
    // recorded wallpaper=571, Dock=357 and menubar=166 but backing=0. The
    // negative Desktop layer is compositor scaffolding, not a fourth visible
    // prerequisite. The menubar's real IOSurface supplies the exact
    // WindowServer generation required by the repair-side PID witness.
    BOOL ready = wallpaperReady && dockReady && menubarReady;
    pid_t windowServerPID = menubarReady
        ? menubar.ownerPID
        : (windowServerBacking ? windowServerBacking.ownerPID : 0);

#define MACWS_GRAPH_LAYER_FIELD(name, layer) \
    (layer ? [NSString stringWithFormat: \
        @"%s=%u/%d/%u/%d,%d,%u,%u", name, layer.windowID, \
        layer.ownerPID, layer.latestSurface \
            ? IOSurfaceGetID(layer.latestSurface) : 0, \
        (int)llround(layer.destinationBounds.origin.x), \
        (int)llround(layer.destinationBounds.origin.y), \
        (unsigned)llround(layer.destinationBounds.size.width), \
        (unsigned)llround(layer.destinationBounds.size.height)] \
      : [NSString stringWithFormat:@"%s=missing", name])
    NSString *identity = [NSString stringWithFormat:
        @"state=%@\nwindowserver=%d\ncanvas=%zux%zu\n%@\n%@\n%@\n%@\n",
        ready ? @"ready" : @"recovering", windowServerPID,
        canvasWidth, canvasHeight,
        MACWS_GRAPH_LAYER_FIELD("wallpaper", wallpaper),
        MACWS_GRAPH_LAYER_FIELD("dock", dock),
        MACWS_GRAPH_LAYER_FIELD("menubar", menubar),
        MACWS_GRAPH_LAYER_FIELD("backing", windowServerBacking)];
#undef MACWS_GRAPH_LAYER_FIELD
    uint64_t signature = MacWSWorkspaceGraphHash(identity);
    if (signature == WorkspaceGraphStateSignature) return;
    WorkspaceGraphStateSignature = signature;

    NSString *payload = [identity stringByAppendingFormat:
        @"publisher=%d\nsignature=%016llx\nupdated=%.6f\nreason=%@\n",
        getpid(), (unsigned long long)signature,
        NSDate.date.timeIntervalSince1970, reason ?: @"reconcile"];
    NSError *error = nil;
    if (![payload writeToFile:WorkspaceGraphStatePath atomically:YES
                      encoding:NSUTF8StringEncoding error:&error]) {
        DisplayLog(@"workspace-graph-state-write-failed state=%@ error=%@",
                   ready ? @"ready" : @"recovering",
                   error.localizedDescription ?: @"");
        return;
    }
    DisplayLog(@"workspace-graph-state state=%@ windowserver=%d "
               "canvas=%zux%zu wallpaper=%@ dock=%@ menubar=%@ backing=%@ "
               "signature=%016llx reason=%@",
               ready ? @"ready" : @"recovering", windowServerPID,
               canvasWidth, canvasHeight,
               wallpaperReady ? @"ready" : @"missing-or-shifted",
               dockReady ? @"ready" : @"missing-or-shifted",
               menubarReady ? @"ready" : @"missing-or-shifted",
               backingReady ? @"ready" : @"missing-or-shifted",
               (unsigned long long)signature, reason ?: @"reconcile");
}

static void SendStatus(MacWSDisplayClient *client, const char *eventName,
                       NSString *message, BOOL ok) {
    if (!client.connection || client.deliveryPaused) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT, eventName);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_dictionary_set_bool(event, MACWS_STREAM_KEY_OK, ok);
    if (message.length)
        xpc_dictionary_set_string(event, MACWS_STREAM_KEY_MESSAGE,
                                  message.UTF8String);
    xpc_connection_send_message(client.connection, event);
}

static void SendMenuResponse(MacWSDisplayClient *client, NSData *response) {
    if (!client || !response.length) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_MENU_XPC_EVENT_RESPONSE);
    xpc_dictionary_set_data(event, MACWS_MENU_XPC_KEY_RESPONSE,
                            response.bytes, response.length);
    xpc_connection_send_message(client.connection, event);
}

static NSData *MenuErrorResponse(const MacWSMenuRequest *request,
                                 MacWSMenuStatus status) {
    MacWSMenuResponseHeader header = {
        .magic = MACWS_MENU_MAGIC,
        .version = MACWS_MENU_VERSION,
        .size = sizeof(header),
        .status = status,
        .nonce = request->nonce,
        .ownerPID = request->ownerPID,
        .windowID = request->windowID,
        .generation = request->generation ? request->generation : 1,
        .totalBytes = sizeof(header),
    };
    return [NSData dataWithBytes:&header length:sizeof(header)];
}

static NSData *RelayMenuRequestToExactTarget(MacWSMenuRequest request) {
    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socketFD < 0)
        return MenuErrorResponse(&request, MacWSMenuStatusInternalError);
    struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
    (void)setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO,
                     &timeout, sizeof(timeout));
    char sourcePath[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    snprintf(sourcePath, sizeof(sourcePath),
             "/private/tmp/macws_menu_client.%d.%08x.sock",
             getpid(), arc4random());
    struct sockaddr_un source = {0};
    source.sun_family = AF_UNIX;
    strlcpy(source.sun_path, sourcePath, sizeof(source.sun_path));
    unlink(sourcePath);
    if (bind(socketFD, (const struct sockaddr *)&source, sizeof(source)) != 0) {
        close(socketFD);
        return MenuErrorResponse(&request, MacWSMenuStatusInternalError);
    }

    char targetPath[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    snprintf(targetPath, sizeof(targetPath),
             "/private/tmp/macws_app_input.%d.sock", request.ownerPID);
    struct stat targetStatus = {0};
    if (stat(targetPath, &targetStatus) != 0 ||
        !S_ISSOCK(targetStatus.st_mode) ||
        chown(sourcePath, targetStatus.st_uid, targetStatus.st_gid) != 0 ||
        chmod(sourcePath, 0600) != 0) {
        close(socketFD);
        unlink(sourcePath);
        return MenuErrorResponse(&request,
                                 MacWSMenuStatusTargetUnavailable);
    }
    struct sockaddr_un target = {0};
    target.sun_family = AF_UNIX;
    strlcpy(target.sun_path, targetPath, sizeof(target.sun_path));
    ssize_t sent = sendto(socketFD, &request, sizeof(request), 0,
                          (const struct sockaddr *)&target, sizeof(target));
    MacWSMenuResponseHeader acknowledgement = {0};
    ssize_t received = sent == sizeof(request)
        ? recv(socketFD, &acknowledgement, sizeof(acknowledgement), 0) : -1;
    int receiveError = errno;
    close(socketFD);
    unlink(sourcePath);

    MacWSMenuStatus failure = received < 0 &&
        (receiveError == EAGAIN || receiveError == EWOULDBLOCK)
        ? MacWSMenuStatusTimeout : MacWSMenuStatusTargetUnavailable;
    if (received != sizeof(acknowledgement) ||
        !MacWSMenuResponseIsValid(&acknowledgement,
                                  sizeof(acknowledgement)) ||
        acknowledgement.nonce != request.nonce ||
        acknowledgement.ownerPID != request.ownerPID ||
        acknowledgement.windowID != request.windowID) {
        return MenuErrorResponse(&request, failure);
    }
    if (request.operation != MacWSMenuOperationSnapshot ||
        acknowledgement.status != MacWSMenuStatusOK) {
        return [NSData dataWithBytes:&acknowledgement
                              length:sizeof(acknowledgement)];
    }

    NSString *snapshotPath = [NSString stringWithFormat:
        @"/private/tmp/macws_menu_snapshot.%d.%016llx.bin",
        request.ownerPID, (unsigned long long)request.nonce];
    NSData *snapshot = [NSData dataWithContentsOfFile:snapshotPath
        options:NSDataReadingMappedIfSafe error:nil];
    unlink(snapshotPath.fileSystemRepresentation);
    const MacWSMenuResponseHeader *header = snapshot.length >=
        sizeof(MacWSMenuResponseHeader) ? snapshot.bytes : NULL;
    if (!MacWSMenuResponseIsValid(header, snapshot.length) ||
        header->status != MacWSMenuStatusOK ||
        header->nonce != request.nonce ||
        header->ownerPID != request.ownerPID ||
        header->windowID != request.windowID ||
        header->generation != acknowledgement.generation) {
        return MenuErrorResponse(&request, MacWSMenuStatusInternalError);
    }
    return snapshot;
}

static pid_t ParentProcessPID(pid_t pid) {
    if (pid <= 1) return 0;
    struct proc_bsdinfo child = {0};
    int childBytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &child,
                                  sizeof(child));
    DisplayLog(@"menu-parent-query child=%d bytes=%d record-pid=%u "
               "parent=%u uid=%u expected=%lu", pid, childBytes,
               child.pbi_pid, child.pbi_ppid, child.pbi_uid,
               (unsigned long)sizeof(child));
    if (childBytes != sizeof(child) || child.pbi_pid != (uint32_t)pid ||
        child.pbi_ppid <= 1) return 0;
    struct proc_bsdinfo parent = {0};
    int parentBytes = proc_pidinfo((pid_t)child.pbi_ppid,
                                   PROC_PIDTBSDINFO, 0, &parent,
                                   sizeof(parent));
    DisplayLog(@"menu-parent-query parent=%u bytes=%d record-pid=%u "
               "uid=%u child-uid=%u expected=%lu", child.pbi_ppid,
               parentBytes, parent.pbi_pid, parent.pbi_uid, child.pbi_uid,
               (unsigned long)sizeof(parent));
    if (parentBytes != sizeof(parent) ||
        parent.pbi_pid != child.pbi_ppid || parent.pbi_uid != child.pbi_uid)
        return 0;
    return (pid_t)child.pbi_ppid;
}

static NSData *RelayMenuRequestWithSessionFallback(MacWSMenuRequest request) {
    NSData *response = RelayMenuRequestToExactTarget(request);
    const MacWSMenuResponseHeader *header =
        response.length >= sizeof(MacWSMenuResponseHeader)
        ? response.bytes : NULL;
    if (request.operation != MacWSMenuOperationSnapshot || !header ||
        header->status != MacWSMenuStatusTargetUnavailable) return response;

    int32_t visibleOwner = request.ownerPID;
    pid_t candidate = visibleOwner;
    for (NSUInteger depth = 1; depth <= 2; depth++) {
        candidate = ParentProcessPID(candidate);
        if (candidate <= 1) break;
        NSArray<NSNumber *> *windowIDs =
            [CopyWindowMetrics(candidate).allKeys
                sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *windowID in windowIDs) {
            if (windowID.unsignedIntValue == 0) continue;
            MacWSMenuRequest fallback = request;
            fallback.ownerPID = candidate;
            fallback.windowID = windowID.unsignedIntValue;
            NSData *candidateResponse =
                RelayMenuRequestToExactTarget(fallback);
            const MacWSMenuResponseHeader *candidateHeader =
                candidateResponse.length >= sizeof(MacWSMenuResponseHeader)
                    ? candidateResponse.bytes : NULL;
            if (!candidateHeader ||
                candidateHeader->status != MacWSMenuStatusOK) continue;
            DisplayLog(@"menu-provider-fallback visible-owner=%d "
                       "visible-window=%u provider=%d provider-window=%u "
                       "depth=%lu nodes=%u",
                       visibleOwner, request.windowID, candidate,
                       windowID.unsignedIntValue, (unsigned long)depth,
                       candidateHeader->nodeCount);
            return candidateResponse;
        }
    }
    return response;
}

static void RelayMenuRequest(MacWSDisplayClient *client,
                             MacWSMenuRequest request) {
    dispatch_async(MenuQueue, ^{
        @autoreleasepool {
            SendMenuResponse(client,
                RelayMenuRequestWithSessionFallback(request));
        }
    });
}

static NSArray<NSDictionary *> *CopyOnScreenWindowInfo(void) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static NSArray<NSDictionary *> *CopyCompleteDesktopWindowInfo(void) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static NSArray<NSDictionary *> *CopyWindowDescriptions(
        NSArray<NSNumber *> *windowIDs) {
    if (!windowIDs.count) return @[];
    // CGWindowListCreateDescriptionFromArray's historical ABI consumes each
    // element as an integer-sized CGWindowID, not as a retained CFNumber.
    // The target geometry probe runtime-confirmed that a callback-free array
    // of pointer-sized IDs exposes live presentation bounds; passing an
    // NSArray<NSNumber *> instead returns unrelated/model-only entries.
    const void *values[MACWS_STREAM_MAX_LAYER_GEOMETRY] = {0};
    CFIndex count = (CFIndex)MIN(windowIDs.count,
        (NSUInteger)MACWS_STREAM_MAX_LAYER_GEOMETRY);
    for (CFIndex index = 0; index < count; index++) {
        values[index] = (const void *)(uintptr_t)
            [windowIDs[(NSUInteger)index] unsignedIntValue];
    }
    CFArrayRef identifiers = CFArrayCreate(kCFAllocatorDefault, values,
                                            count, NULL);
    CFArrayRef raw = identifiers
        ? CGWindowListCreateDescriptionFromArray(identifiers) : NULL;
    if (identifiers) CFRelease(identifiers);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static NSArray<NSDictionary *> *CopyCatalogWindowInfo(void) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!raw) return @[];
    return CFBridgingRelease(raw);
}

static CGFloat MainDisplayBackingScale(void) {
    if (ObservedWindowBackingScale >= 0.5 &&
        ObservedWindowBackingScale <= 8.0)
        return ObservedWindowBackingScale;
    // NSScreen is the authoritative AppKit point-to-backing-pixel mapping.
    // The chroot virtual display's CGDisplayPixelsWide/High runtime-report its
    // logical extent, so that API pair alone collapses Retina to 1x during a
    // cold fullscreen subscription before any exact-window frame is observed.
    if (AppKitMainDisplayBackingScale >= 0.5 &&
        AppKitMainDisplayBackingScale <= 8.0)
        return AppKitMainDisplayBackingScale;
    CGDirectDisplayID display = CGMainDisplayID();
    CGRect bounds = CGDisplayBounds(display);
    size_t pixelWidth = CGDisplayPixelsWide(display);
    if (bounds.size.width <= 0 || pixelWidth == 0) return 1.0;
    CGFloat scale = pixelWidth / bounds.size.width;
    return scale > 0 && scale <= 8.0 ? scale : 1.0;
}

static CGFloat LayerPresentationScale(CGRect bounds, IOSurfaceRef surface,
                                      CGFloat fallbackScale,
                                      BOOL *usedSurfaceMeasurement) {
    if (usedSurfaceMeasurement) *usedSurfaceMeasurement = NO;
    if (!surface || CGRectIsEmpty(bounds) || !isfinite(fallbackScale) ||
        fallbackScale < 0.5 || fallbackScale > 8.0) return fallbackScale;

    size_t surfaceWidth = IOSurfaceGetWidth(surface);
    size_t surfaceHeight = IOSurfaceGetHeight(surface);
    if (surfaceWidth == 0 || surfaceHeight == 0) return fallbackScale;
    CGFloat scaleX = surfaceWidth / bounds.size.width;
    CGFloat scaleY = surfaceHeight / bounds.size.height;
    if (!isfinite(scaleX) || !isfinite(scaleY) || scaleX < 0.5 ||
        scaleX > 8.0 || scaleY < 0.5 || scaleY > 8.0 ||
        fabs(scaleX - scaleY) > 0.08) return fallbackScale;

    CGFloat measured = (scaleX + scaleY) * 0.5;
    // Accept only the two coordinate systems observed at this boundary:
    // logical AppKit points (surface/bounds ~= display scale) and backing
    // pixels (surface/bounds ~= 1).  A resize can briefly pair new bounds
    // with an old surface; that arbitrary ratio must not move the layer.
    CGFloat pixelDistance = fabs(measured - 1.0);
    CGFloat logicalDistance = fabs(measured - fallbackScale);
    if (pixelDistance > 0.08 && logicalDistance > 0.08)
        return fallbackScale;
    if (usedSurfaceMeasurement) *usedSurfaceMeasurement = YES;
    // The ratio is evidence for which coordinate space owns the rectangle,
    // not a scale transform in its own right.  Snap to that coordinate
    // space: small AppKit decoration/crop differences (Stray runtime-
    // confirmed 2388x1696 bounds around a 2388x1668 capture) must not turn
    // into fractional stretching of every pixel.
    return pixelDistance <= logicalDistance ? 1.0 : fallbackScale;
}

static BOOL CopyWindowBounds(uint32_t windowID, CGRect *result) {
    if (windowID == 0 || !result) return NO;
    for (NSDictionary *info in CopyOnScreenWindowInfo()) {
        if ([info[(id)kCGWindowNumber] unsignedIntValue] != windowID)
            continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                &bounds) || bounds.size.width <= 0.0 ||
            bounds.size.height <= 0.0) return NO;
        *result = bounds;
        return YES;
    }
    return NO;
}

static NSDictionary<NSNumber *, NSData *> *CopyWindowMetrics(int32_t pid) {
    if (pid <= 1) return @{};
    NSString *path = [NSString stringWithFormat:
        @"/private/tmp/macws_window_metrics.%d.bin", pid];
    NSData *data = [NSData dataWithContentsOfFile:path
                                         options:NSDataReadingMappedIfSafe
                                           error:nil];
    if (data.length < sizeof(MacWSWindowMetricsHeader)) return @{};
    const MacWSWindowMetricsHeader *header = data.bytes;
    if (!MacWSWindowMetricsAreValid(header, data.length)) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (uint32_t index = 0; index < header->entryCount; index++) {
        MacWSWindowMetricsEntry entry = {0};
        if (!MacWSWindowMetricsReadEntry(header, data.length, index, &entry))
            continue;
        if (entry.windowID == 0 ||
            !isfinite(entry.minimumLogicalWidth) ||
            !isfinite(entry.minimumLogicalHeight) ||
            entry.minimumLogicalWidth < 0 ||
            entry.minimumLogicalHeight < 0 ||
            entry.minimumLogicalWidth > MACWS_STREAM_MAX_DIMENSION ||
            entry.minimumLogicalHeight > MACWS_STREAM_MAX_DIMENSION) continue;
        // runtime-confirmed on Ventura: sizeof this packed wire record is
        // 56, but NSGetSizeAndAlignment(@encode(...)) is 64. ObjC encodings
        // discard packing; NSValue therefore copied eight bytes past both
        // stack buffers, corrupting an ARC owner in SendWindowList. Preserve
        // the explicit wire length at both storage and read boundaries.
        result[@(entry.windowID)] = [NSData dataWithBytes:&entry length:sizeof(entry)];
    }
    return result;
}

static MacWSStreamWindowDescriptor WindowDescriptor(
        NSDictionary *info, const MacWSWindowMetricsEntry *metrics) {
    CGRect bounds = CGRectZero;
    CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds);
    uint32_t windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
    int32_t ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
    CGFloat scale = MainDisplayBackingScale();
    MacWSStreamWindowDescriptor descriptor = {
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(MacWSStreamWindowDescriptor),
        .windowID = windowID,
        .ownerPID = ownerPID,
        .flags = 0,
        .logicalGroupID = metrics ? metrics->logicalGroupID : windowID,
        .logicalX = bounds.origin.x,
        .logicalY = bounds.origin.y,
        .logicalWidth = bounds.size.width,
        .logicalHeight = bounds.size.height,
        .pixelWidth = (uint32_t)llround(bounds.size.width * scale),
        .pixelHeight = (uint32_t)llround(bounds.size.height * scale),
        // Zero means the AppKit endpoint has not published evidence yet. The
        // Host must not replace an unknown minimum with a guessed constant.
        .minimumLogicalWidth = metrics ? metrics->minimumLogicalWidth : 0,
        .minimumLogicalHeight = metrics ? metrics->minimumLogicalHeight : 0,
        .backingScale = scale,
    };
    if (metrics) {
        descriptor.flags |= metrics->flags &
            (MacWSStreamWindowVisible | MacWSStreamWindowHasShadow |
             MacWSStreamWindowResizable |
             MacWSStreamWindowFocused | MacWSStreamWindowSpatialCanvas |
             MacWSStreamWindowFullscreenCanvas |
             MacWSStreamWindowFixedWidth |
             MacWSStreamWindowFixedHeight);
    }
    if ([info[(id)kCGWindowIsOnscreen] boolValue])
        descriptor.flags |= MacWSStreamWindowOnScreen;
    return descriptor;
}

static void SendWindowList(MacWSDisplayClient *client) {
    if (!client.connection) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_STREAM_EVENT_WINDOWS);
    xpc_object_t array = xpc_array_create(NULL, 0);
    xpc_object_t limitsArray = xpc_array_create(NULL, 0);
    NSUInteger emitted = 0;
    NSMutableDictionary<NSNumber *, NSDictionary *> *metricsByPID =
        [NSMutableDictionary dictionary];
    // Do not exclude desktop-owned elements before extracting system input
    // surfaces. The AppKit metrics/layer checks below still restrict Scenes.
    NSArray<NSDictionary *> *onScreenWindowInfo = CopyCompleteDesktopWindowInfo();
    NSArray<NSDictionary *> *catalogWindowInfo = CopyCatalogWindowInfo();
    // Runtime-confirmed: Dock's LPSpringboard is OnScreen at level 27 while
    // Launchpad is visible, and absent from OnScreenOnly after dismissal.
    // It has no AppKit metrics and must not become a selectable iPad Scene.
    // Publish its real identity/geometry separately, even when final-composite
    // rendering has suspended the redundant per-window capture surfaces.
    xpc_object_t systemInput = xpc_array_create(NULL, 0);
    for (NSDictionary *info in onScreenWindowInfo) {
        if (xpc_array_get_count(systemInput) >= 8) break;
        if (![info[(id)kCGWindowOwnerName] isEqual:@"Dock"] ||
            ![info[(id)kCGWindowName] isEqual:@"LPSpringboard"] ||
            ![info[(id)kCGWindowIsOnscreen] boolValue] ||
            [info[(id)kCGWindowLayer] integerValue] <= 0 ||
            [info[(id)kCGWindowAlpha] doubleValue] <= 0.01) continue;
        MacWSStreamWindowDescriptor descriptor = WindowDescriptor(info, NULL);
        if (!MacWSStreamWindowDescriptorIsValid(&descriptor, sizeof(descriptor)))
            continue;
        xpc_array_append_value(systemInput,
            xpc_data_create(&descriptor, sizeof(descriptor)));
    }
    xpc_dictionary_set_value(event, MACWS_STREAM_KEY_SYSTEM_INPUT_WINDOWS,
                             systemInput);
    // The Host uses this array for hit-testing pixels from FinalComposite, so
    // preserve WindowServer's live front-to-back OnScreenOnly order. Append
    // OptionAll-only entries afterward to retain lifecycle/fullscreen
    // identities without allowing that unordered identity catalog to shadow
    // what is actually visible. Runtime-confirmed on 2026-08-30: the old
    // OptionAll-first array retained Settings child window 302 over Activity
    // Monitor and routed scroll records to PID 95665 even after Activity was
    // frontmost.
    NSMutableArray<NSDictionary *> *orderedWindowInfo =
        [NSMutableArray arrayWithCapacity:
            onScreenWindowInfo.count + catalogWindowInfo.count];
    NSMutableSet<NSNumber *> *orderedWindowIDs = [NSMutableSet set];
    for (NSDictionary *info in onScreenWindowInfo) {
        uint32_t windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
        if (windowID == 0) continue;
        [orderedWindowInfo addObject:info];
        [orderedWindowIDs addObject:@(windowID)];
    }
    for (NSDictionary *info in catalogWindowInfo) {
        uint32_t windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
        if (windowID == 0 || [orderedWindowIDs containsObject:@(windowID)])
            continue;
        [orderedWindowInfo addObject:info];
        [orderedWindowIDs addObject:@(windowID)];
    }
    // The live OnScreenOnly list is WindowServer's front-to-back presentation
    // order. Runtime-confirmed after activating System Settings and Terminal
    // over the same desktop: this ordering followed the rendered menu bar and
    // window stack while NSWorkspace.frontmostApplication briefly retained
    // the previous process. Select the first real AppKit level-zero window by
    // joining it with that process's published window metrics. OptionAll is
    // still used below for lifecycle/fullscreen identities, but never as a
    // z-order authority.
    pid_t frontmostPID = 0;
    uint32_t frontmostWindowID = 0;
    for (NSDictionary *info in onScreenWindowInfo) {
        pid_t ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
        uint32_t windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
        if (ownerPID <= 1 || windowID == 0) continue;
        NSNumber *pidKey = @(ownerPID);
        NSDictionary<NSNumber *, NSData *> *processMetrics =
            metricsByPID[pidKey];
        if (!processMetrics) {
            processMetrics = CopyWindowMetrics(ownerPID);
            metricsByPID[pidKey] = processMetrics;
        }
        NSData *metricsValue = processMetrics[@(windowID)];
        if (!metricsValue) continue;
        MacWSWindowMetricsEntry metrics = {0};
        [metricsValue getBytes:&metrics length:sizeof(metrics)];
        if ((metrics.flags & MacWSStreamWindowVisible) == 0 ||
            (metrics.flags & MacWSStreamWindowTransient) != 0) continue;
        MacWSStreamWindowFlags fullscreenAuthority =
            MacWSStreamWindowFocused | MacWSStreamWindowFullscreenCanvas;
        BOOL focusedFullscreenCanvas =
            (metrics.flags & fullscreenAuthority) == fullscreenAuthority;
        NSInteger layer = [info[(id)kCGWindowLayer] integerValue];
        if (layer != 0 && !focusedFullscreenCanvas) continue;
        frontmostPID = ownerPID;
        frontmostWindowID = windowID;
        break;
    }
    client.catalogFrontmostOwnerPID = frontmostPID;
    client.catalogFrontmostWindowID = frontmostWindowID;
    // A catalog refresh can establish focus after the exact-window stream has
    // already delivered and retained its dimensions. Refresh the same
    // authority immediately instead of waiting for unrelated future damage.
    // If no active window-mode client matches, the existing two-second
    // freshness check remains the fail-closed revocation boundary.
    if (client.mode == MacWSStreamModeWindow &&
        client.windowID == frontmostWindowID && frontmostPID > 1 &&
        client.lastSurfaceWidth != 0 && client.lastSurfaceHeight != 0) {
        (void)PublishFocusedRenderAuthorityIdentity(
            frontmostPID, frontmostWindowID,
            client.lastSurfaceWidth, client.lastSurfaceHeight);
    }
    NSRunningApplication *workspaceFrontmost =
        NSWorkspace.sharedWorkspace.frontmostApplication;
    NSMutableDictionary<NSNumber *, NSNumber *> *focusedWindowOwners =
        [client.focusedWindowOwners mutableCopy] ?:
            [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *liveWindowOwners =
        [NSMutableDictionary dictionary];
    for (NSDictionary *info in orderedWindowInfo) {
        if (emitted >= MACWS_STREAM_MAX_WINDOWS) break;
        int32_t ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
        uint32_t candidateWindowID =
            [info[(id)kCGWindowNumber] unsignedIntValue];
        if (candidateWindowID != 0 && ownerPID > 1)
            liveWindowOwners[@(candidateWindowID)] = @(ownerPID);
        NSNumber *pidKey = @(ownerPID);
        NSDictionary<NSNumber *, NSData *> *processMetrics = metricsByPID[pidKey];
        if (!processMetrics) {
            processMetrics = CopyWindowMetrics(ownerPID);
            metricsByPID[pidKey] = processMetrics;
        }
        MacWSWindowMetricsEntry metrics = {0};
        NSData *metricsValue = processMetrics[@(candidateWindowID)];
        // A selectable Scene must correspond to a real, published AppKit
        // top-level window. Cursor/menu-bar/plugin surfaces have no matching
        // per-process metrics entry, while menus and overlays use nonzero
        // Quartz layers. A bundle-declared fullscreen canvas remains eligible
        // during AppKit's 0x140 transition even when ordered Visible is clear;
        // its live CGWindow identity and exact layer remain independently
        // validated below.
        if (!metricsValue) continue;
        [metricsValue getBytes:&metrics length:sizeof(metrics)];
        MacWSStreamWindowFlags fullscreenAuthority =
            MacWSStreamWindowFocused | MacWSStreamWindowFullscreenCanvas;
        BOOL focusedFullscreenCanvas =
            (metrics.flags & fullscreenAuthority) == fullscreenAuthority;
        NSInteger layer = [info[(id)kCGWindowLayer] integerValue];
        if (layer != 0 &&
            (!focusedFullscreenCanvas ||
             layer >= CGWindowLevelForKey(kCGCursorWindowLevelKey)))
            continue;
        BOOL visibleAppWindow =
            (metrics.flags & MacWSStreamWindowVisible) != 0;
        if ((!visibleAppWindow && !focusedFullscreenCanvas) ||
            (metrics.flags & MacWSStreamWindowTransient) != 0) continue;
        MacWSStreamWindowDescriptor descriptor = WindowDescriptor(
            info, &metrics);
        if (frontmostPID > 1 && descriptor.ownerPID == frontmostPID &&
            descriptor.windowID == frontmostWindowID)
            descriptor.flags |= MacWSStreamWindowFrontmostApplication;
        if (descriptor.windowID == 0 || descriptor.ownerPID <= 1 ||
            descriptor.logicalWidth <= 1 || descriptor.logicalHeight <= 1)
            continue;
        NSString *title = info[(id)kCGWindowName];
        if (![title isKindOfClass:NSString.class]) title = @"macOS Window";
        NSData *titleData = [title dataUsingEncoding:NSUTF8StringEncoding];
        if (titleData.length > UINT32_MAX) continue;
        descriptor.titleLength = (uint32_t)titleData.length;
        NSMutableData *bytes = [NSMutableData dataWithBytes:&descriptor
                                                     length:sizeof(descriptor)];
        [bytes appendData:titleData];
        xpc_object_t item = xpc_data_create(bytes.bytes, bytes.length);
        xpc_array_append_value(array, item);
        MacWSStreamWindowLimits limits = {
            .windowID = descriptor.windowID,
            .ownerPID = descriptor.ownerPID,
            .maximumLogicalWidth = metrics.maximumLogicalWidth,
            .maximumLogicalHeight = metrics.maximumLogicalHeight,
            .configureAck = metrics.configureAck,
        };
        // V2 metrics have a zero-filled extension; do not advertise ACK
        // support for an old AppKit producer merely because displayd is new.
        if ((limits.maximumLogicalWidth > 0 ||
             limits.maximumLogicalHeight > 0 ||
             limits.configureAck.timestamp > 0) &&
            MacWSStreamWindowLimitsAreValid(&limits, sizeof(limits))) {
            xpc_object_t limitsItem = xpc_data_create(&limits, sizeof(limits));
            xpc_array_append_value(limitsArray, limitsItem);
        }
        MacWSStreamWindowFlags requiredDirectFlags =
            MacWSStreamWindowFocused | MacWSStreamWindowVisible |
            MacWSStreamWindowOnScreen;
        MacWSStreamWindowFlags requiredFullscreenFlags =
            MacWSStreamWindowFocused | MacWSStreamWindowFullscreenCanvas;
        if ((descriptor.flags & requiredDirectFlags) == requiredDirectFlags ||
            (descriptor.flags & requiredFullscreenFlags) ==
                requiredFullscreenFlags) {
            // This is an authorization history for an exact live CGWindow,
            // not a mirror of the most recent focus snapshot. Host can keep
            // presenting the window it selected while AppKit publishes a
            // later non-focused catalog during the fullscreen transition.
            // Removing that identity here races the first drawable activity
            // heartbeat. Keep it only while the same window ID and owner are
            // still present in CGWindowList; the liveness pass below is the
            // authoritative revocation edge.
            focusedWindowOwners[@(descriptor.windowID)] =
                @(descriptor.ownerPID);
        }
        emitted++;
    }
    for (NSNumber *windowID in [focusedWindowOwners.allKeys copy]) {
        NSNumber *liveOwner = liveWindowOwners[windowID];
        if (!liveOwner || liveOwner.intValue !=
                focusedWindowOwners[windowID].intValue)
            [focusedWindowOwners removeObjectForKey:windowID];
    }
    client.focusedWindowOwners = focusedWindowOwners;
    if (MacWSDisplayDiagnosticsEnabled()) {
        DisplayLog(@"window-list frontmost-pid=%d frontmost-window=%u "
                   "source=onscreen-front-to-back workspace-pid=%d "
                   "workspace-name=%@ emitted=%lu", frontmostPID,
                   frontmostWindowID,
                   workspaceFrontmost.processIdentifier,
                   workspaceFrontmost.localizedName ?: @"",
                   (unsigned long)emitted);
    }
    xpc_dictionary_set_value(event, MACWS_STREAM_KEY_WINDOWS, array);
    xpc_dictionary_set_value(event, MACWS_STREAM_KEY_WINDOW_LIMITS, limitsArray);
    xpc_connection_send_message(client.connection, event);
}

static void BroadcastWindowList(void) {
    for (MacWSDisplayClient *client in [Clients copy])
        SendWindowList(client);
}

// A single AppKit action can update focus, key state and window metrics in
// separate callbacks. Runtime logs captured more than ten complete catalog
// broadcasts in the burst following one UI action. Preserve the latest
// authoritative CGWindow snapshot while collapsing each 16 ms burst into one
// display-queue edge.
// Explicit LIST_WINDOWS requests remain immediate in HandleRequest.
static void ScheduleCatalogBroadcast(void) {
    if (CatalogBroadcastPending) return;
    CatalogBroadcastPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   DisplayQueue, ^{
        CatalogBroadcastPending = NO;
        BroadcastWindowList();
        ScheduleTransientReconcile(0);
    });
}

// AppKit processes publish their window metrics in a shared sidecar. This
// datagram is only an invalidation edge: displayd remains the single process
// that reads the real CGWindow catalog and broadcasts a validated snapshot.
// A dispatch source drains every queued byte before one broadcast, so a tab
// switch plus its metrics update cannot turn into repeated catalog scans.
static void StartInvalidationListener(void) {
    InvalidationSocket = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (InvalidationSocket < 0) {
        DisplayLog(@"catalog-invalidation socket-create failed errno=%d", errno);
        return;
    }
    int flags = fcntl(InvalidationSocket, F_GETFL);
    if (flags >= 0) (void)fcntl(InvalidationSocket, F_SETFL,
                                flags | O_NONBLOCK);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, MACWS_STREAM_INVALIDATE_SOCKET_PATH,
            sizeof(address.sun_path));
    unlink(MACWS_STREAM_INVALIDATE_SOCKET_PATH);
    if (bind(InvalidationSocket, (const struct sockaddr *)&address,
             sizeof(address)) != 0) {
        DisplayLog(@"catalog-invalidation bind failed errno=%d", errno);
        close(InvalidationSocket);
        InvalidationSocket = -1;
        return;
    }
    chmod(MACWS_STREAM_INVALIDATE_SOCKET_PATH, 0666);
    InvalidationSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)InvalidationSocket, 0,
        DisplayQueue);
    dispatch_source_set_event_handler(InvalidationSource, ^{
        uint8_t bytes[128];
        BOOL geometryChanged = NO;
        BOOL semanticPointerClickCompleted = NO;
        BOOL workspaceAnimationAdvanced = NO;
        BOOL catalogChanged = NO;
        ssize_t count = 0;
        while ((count = recv(InvalidationSocket, bytes,
                             sizeof(bytes), 0)) > 0) {
            MacWSGeometryInvalidation geometry = {0};
            if ((size_t)count == sizeof(geometry)) {
                memcpy(&geometry, bytes, sizeof(geometry));
            }
            if (MacWSGeometryInvalidationIsValid(&geometry,
                                                  (size_t)count)) {
                @synchronized (GeometryTargets) {
                    GeometryTargets[@(geometry.windowID)] =
                        [NSValue valueWithBytes:&geometry
                            objCType:@encode(MacWSGeometryInvalidation)];
                }
                geometryChanged = YES;
            } else {
                for (ssize_t index = 0; index < count; index++) {
                    if (bytes[index] == 'a') {
                        workspaceAnimationAdvanced = YES;
                        continue;
                    }
                    // A geometry edge changes an existing layer's rectangle,
                    // not the window catalog. Sending it through the catalog
                    // path used to perform a complete CGWindow snapshot and
                    // request a full-screen final-composite replay for every
                    // title-bar drag sample.
                    if (bytes[index] == 'g') {
                        geometryChanged = YES;
                        continue;
                    }
                    catalogChanged = YES;
                    if (bytes[index] == 't')
                        semanticPointerClickCompleted = YES;
                }
            }
        }
        if (semanticPointerClickCompleted)
            UrgentTransientRetirePasses = 10;
        if (workspaceAnimationAdvanced) {
            CFTimeInterval now = CFAbsoluteTimeGetCurrent();
            BOOL wasSampling = now < WorkspaceAnimationSamplingDeadline;
            // The hard deadline is the bound of one animation burst, not a
            // sliding deadline.  Dock/WindowServer can publish continuous
            // animation edges while the desktop is otherwise idle.  Sliding
            // both deadlines kept DisplayQueue in geometry-only sampling
            // indefinitely, so a Dock restart was never reconciled into the
            // retained fullscreen layer catalog.  Begin a fresh bounded burst
            // only after the previous one has ended, and cap its soft tail at
            // that immutable boundary.
            if (!wasSampling)
                WorkspaceAnimationSettlementHardDeadline = now + 0.80;
            WorkspaceAnimationSamplingDeadline = fmin(
                now + 0.25, WorkspaceAnimationSettlementHardDeadline);
            // This path only needs compositor geometry. Avoid broadcasting a
            // complete application-window list for every gesture sample. A
            // targeted asynchronous query is single-flight: 120-Hz input can
            // request the next sample without queuing redundant SkyLight RPCs.
            if (!wasSampling) ScheduleTransientReconcile(0);
            RequestWorkspaceGeometrySample();
        }
        if (catalogChanged) ScheduleCatalogBroadcast();
        if (geometryChanged) {
            // NSWindow move/resize notifications continue for the real
            // duration of a drag. A sliding 250-ms tail keeps the lightweight
            // targeted descriptions alive, while the 150-ms restart debounce
            // below performs one final exact-stream shape check after resize.
            CFTimeInterval now = CFAbsoluteTimeGetCurrent();
            WorkspaceAppKitGeometrySamplingDeadline = fmax(
                WorkspaceAppKitGeometrySamplingDeadline, now + 0.25);
            RequestWorkspaceGeometrySample();
            ScheduleGeometryStreamRestart();
        }
    });
    dispatch_source_set_cancel_handler(InvalidationSource, ^{
        if (InvalidationSocket >= 0) close(InvalidationSocket);
        InvalidationSocket = -1;
        unlink(MACWS_STREAM_INVALIDATE_SOCKET_PATH);
    });
    dispatch_resume(InvalidationSource);
}

static NSDictionary *StreamProperties(void) {
    NSMutableDictionary *properties = [@{
        (__bridge id)kCGDisplayStreamQueueDepth: @3,
        (__bridge id)kCGDisplayStreamShowCursor: @NO,
        (__bridge id)kCGDisplayStreamPreserveAspectRatio: @YES,
        // The coexist compositor is paced at 120 Hz only during the bounded
        // one-second interaction window. Capping exact-window capture at 60
        // Hz forced a fresh VS Code frame to miss every other compositor
        // completion and runtime-measured 18.2 ms mean source intervals plus
        // 20.9 ms during momentum. A 120-Hz A/B restored 59 FPS average but
        // delivered bursts into an application/final-present path that is
        // currently near 60 Hz, increasing 33-66 ms tail gaps. A 90-Hz A/B
        // reduced the tails but momentum fell to 55.9 source FPS. Test the
        // midpoint at 100 Hz to retain the phase tolerance without needlessly
        // filling the three-surface lease queue. A static window still
        // produces no CGDisplayStream callback.
        (__bridge id)kCGDisplayStreamMinimumFrameTime: @(1.0 / 100.0),
    } mutableCopy];
    CFStringRef *surfacePropertiesKey = dlsym(
        RTLD_DEFAULT, "kSLDisplayStreamIOSurfaceProperties");
    if (surfacePropertiesKey && *surfacePropertiesKey) {
        properties[(__bridge NSString *)*surfacePropertiesKey] = @{
            (__bridge id)kIOSurfacePixelFormat: @(0x42475241u),
            (__bridge id)kIOSurfaceBytesPerElement: @4,
        };
    }
    return properties;
}

static NSUInteger OutstandingFramesForLayer(MacWSDisplayClient *client,
                                             uint32_t layerWindowID) {
    return [client.outstandingByLayer[@(layerWindowID)] unsignedIntegerValue];
}

static void SetOutstandingFramesForLayer(MacWSDisplayClient *client,
                                         uint32_t layerWindowID,
                                         NSUInteger count) {
    if (!client.outstandingByLayer)
        client.outstandingByLayer = [NSMutableDictionary dictionary];
    if (count == 0) [client.outstandingByLayer removeObjectForKey:@(layerWindowID)];
    else client.outstandingByLayer[@(layerWindowID)] = @(count);
}

static void PublishFrame(MacWSDisplayClient *client,
                         MacWSTransientLayer *layer,
                         uint64_t displayTime, IOSurfaceRef surface) {
    if (!surface || ![Clients containsObject:client]) return;
    // Keep one immutable IOSurface reference per workspace layer.  A
    // fullscreen Scene ownership transfer can then republish the complete
    // current desktop without stopping/recreating any SkyLight stream.
    if (layer) {
        [layer recordActiveFrameAtDisplayTime:displayTime];
        layer.latestSurface = surface;
        layer.latestDisplayTime = displayTime;
    }
    // During the bounded fullscreen handoff grace period, keep the existing
    // SkyLight streams and their newest immutable surfaces alive but do not
    // manufacture leases for a dead XPC connection. The replacement Host
    // republishes these surfaces when it atomically takes ownership.
    if (!client.connection || client.deliveryPaused) return;
    BOOL nativePopup = layer && !layer.retiring &&
        client.mode == MacWSStreamModeWindow && layer.popupCompositeEligible &&
        FinalCompositeSurface && FinalCompositeRecord.producerPID > 1 &&
        FinalCompositeRecord.completionTime >= layer.popupCompositeMinimumTime &&
        CGRectContainsRect(CGRectMake(0, 0, FinalCompositeRecord.width,
            FinalCompositeRecord.height), layer.popupCompositeSource);
    if (nativePopup) {
        if (layer.lastPopupCompositeSequence == FinalCompositeRecord.sequence) return;
        surface = FinalCompositeSurface;
        displayTime = FinalCompositeRecord.completionTime;
    }
    uint32_t layerWindowID = layer ? layer.windowID
        : (client.windowID ? client.windowID : UINT32_MAX);
    uint64_t producerStreamID = layer ? layer.streamID : client.streamID;
    // With a stream queue depth of three, retaining more than three surfaces
    // from one producer can pin that producer's compositor buffers. Bound
    // base and each transient independently so a static menu cannot stall the
    // continuously updating document stream.
    NSUInteger outstanding = OutstandingFramesForLayer(client, layerWindowID);
    if (outstanding >= 3) {
        uint64_t dropped = layer ? ++layer.droppedFrames
                                 : ++client.droppedFrames;
        if (dropped == 1 || (dropped % 120) == 0) {
            DisplayLog(@"backpressure stream=%llu window=%u layer=%u outstanding=%lu "
                       "dropped=%llu",
                (unsigned long long)producerStreamID, client.windowID,
                layerWindowID, (unsigned long)outstanding,
                (unsigned long long)dropped);
        }
        return;
    }

    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    if (width == 0 || height == 0 ||
        width > MACWS_STREAM_MAX_DIMENSION ||
        height > MACWS_STREAM_MAX_DIMENSION ||
        bytesPerRow > UINT32_MAX) return;
    if (!layer) {
        client.lastSurfaceWidth = width;
        client.lastSurfaceHeight = height;
        // Runtime-confirmed by the 2026-09-30 TestUFO profile on iPad13,6:
        // the page produced 118 fps internally, but the exact-window stream
        // and Host presented at 9.86 fps with a 101.49-ms source median.
        // GPU execution was only 0.42 ms. The window-mode base never entered
        // PublishFocusedRenderAuthority, so no authenticated render-activity
        // record could wake the 100-ms idle completion loop. Publish the same
        // exact PID/window/surface-size authority used by fullscreen capture;
        // Metal_hooks and WindowServer still independently validate geometry,
        // freshness and producer ancestry before raising compositor cadence.
        if (client.mode == MacWSStreamModeWindow &&
            client.windowID == client.catalogFrontmostWindowID &&
            client.catalogFrontmostOwnerPID > 1) {
            (void)PublishFocusedRenderAuthorityIdentity(
                client.catalogFrontmostOwnerPID, client.windowID,
                width, height);
        }
    }
    if (!layer && client.mode == MacWSStreamModeWindow &&
        client.windowBackingScale <= 0.0) {
        for (NSDictionary *info in CopyOnScreenWindowInfo()) {
            if ([info[(id)kCGWindowNumber] unsignedIntValue] !=
                client.windowID) continue;
            CGRect bounds = CGRectZero;
            if (!CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                    &bounds) || bounds.size.width <= 0.0 ||
                bounds.size.height <= 0.0) break;
            CGFloat scaleX = width / bounds.size.width;
            CGFloat scaleY = height / bounds.size.height;
            CGFloat measured = (scaleX + scaleY) * 0.5;
            if (isfinite(measured) && measured >= 0.5 && measured <= 8.0 &&
                fabs(scaleX - scaleY) <= 0.08) {
                client.windowBackingScale = measured;
                ObservedWindowBackingScale = measured;
                DisplayLog(@"runtime-confirmed backing-scale window=%u surface=%zux%zu bounds=%.1fx%.1f scale=%.3f",
                           client.windowID, width, height,
                           bounds.size.width, bounds.size.height, measured);
            }
            break;
        }
    }
    uint32_t contentX = nativePopup ? (uint32_t)layer.popupCompositeSource.origin.x : 0;
    uint32_t contentY = nativePopup ? (uint32_t)layer.popupCompositeSource.origin.y : 0;
    uint32_t contentWidth = nativePopup ? (uint32_t)layer.popupCompositeSource.size.width : (uint32_t)width;
    uint32_t contentHeight = nativePopup ? (uint32_t)layer.popupCompositeSource.size.height : (uint32_t)height;
    int32_t destinationX = layer
        ? (int32_t)llround(layer.destinationBounds.origin.x) : 0;
    int32_t destinationY = layer
        ? (int32_t)llround(layer.destinationBounds.origin.y) : 0;
    uint32_t destinationWidth = layer
        ? (uint32_t)llround(layer.destinationBounds.size.width)
        : contentWidth;
    uint32_t destinationHeight = layer
        ? (uint32_t)llround(layer.destinationBounds.size.height)
        : contentHeight;
    if (destinationWidth == 0 || destinationHeight == 0) return;

    BOOL finalComposite = !layer &&
        client.mode == MacWSStreamModeFullscreen &&
        surface == FinalCompositeSurface &&
        FinalCompositeRecord.producerPID > 1;

    MacWSDisplayLease *lease = [MacWSDisplayLease new];
    lease.token = NextLeaseToken++;
    if (lease.token == 0) lease.token = NextLeaseToken++;
    lease.surface = (IOSurfaceRef)CFRetain(surface);
    if (finalComposite || nativePopup) {
        IOSurfaceIncrementUseCount(surface);
        lease.holdsSurfaceUseCount = YES;
    }
    lease.owner = client;
    lease.layerWindowID = layerWindowID;
    Leases[@(lease.token)] = lease;
    SetOutstandingFramesForLayer(client, layerWindowID, outstanding + 1);

    CGFloat scale = client.windowBackingScale > 0.0
        ? client.windowBackingScale : MainDisplayBackingScale();
    MacWSStreamFrameDescriptor descriptor = {
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(MacWSStreamFrameDescriptor),
        .streamID = producerStreamID,
        .windowID = client.windowID,
        .flags = MacWSStreamFrameComplete |
                 (finalComposite
                     ? MacWSStreamFrameFinalComposite : 0) |
                 (nativePopup ? MacWSStreamFrameNativePopupComposite : 0) |
                 (layer ? MacWSStreamFrameOverlay : 0) |
                 (layer && [layer.ownerName isEqualToString:@"Dock"]
                     ? MacWSStreamFrameGlobalSystemSurface : 0) |
                 (layer && layer.skyLightLayer >=
                      CGWindowLevelForKey(kCGCursorWindowLevelKey)
                     ? MacWSStreamFrameInputPassthrough : 0),
        .leaseToken = lease.token,
        .sequence = layer ? ++layer.sequence : ++client.sequence,
        .displayTime = displayTime,
        .width = (uint32_t)width,
        .height = (uint32_t)height,
        .bytesPerRow = (uint32_t)bytesPerRow,
        .pixelFormat = IOSurfaceGetPixelFormat(surface),
        .backingScale = scale,
        .contentX = contentX,
        .contentY = contentY,
        .contentWidth = contentWidth,
        .contentHeight = contentHeight,
        .layerWindowID = layerWindowID,
        .layerOwnerPID = layer ? layer.ownerPID : 0,
        .layerLevel = layer ? layer.level : 0,
        .destinationX = destinationX,
        .destinationY = destinationY,
        .destinationWidth = destinationWidth,
        .destinationHeight = destinationHeight,
    };
    if (layer) layer.lastPopupCompositeSequence = nativePopup
        ? FinalCompositeRecord.sequence : 0;
    if (nativePopup && !layer.popupCompositeReported) {
        layer.popupCompositeReported = YES;
        DisplayLog(@"native-popup-composite base=%u layer=%u owner=%d "
            "source=%u,%u %ux%u destination=%d,%d %ux%u "
            "completed=%llu required=%llu route=completed-AGX-region no-copy=YES",
            client.windowID, layer.windowID, layer.ownerPID,
            contentX, contentY, contentWidth, contentHeight,
            destinationX, destinationY, destinationWidth, destinationHeight,
            (unsigned long long)displayTime,
            (unsigned long long)layer.popupCompositeMinimumTime);
    }
    if (descriptor.sequence == 1) {
        if (layer) layer.firstDisplayTime = displayTime;
        else client.firstDisplayTime = displayTime;
        DisplayLog(@"frame-first stream=%llu window=%u layer=%u overlay=%s "
                   "owner=%@ owner-pid=%d flags=%#x surface=%ux%u bpr=%u "
                   "pf=%08x destination=(%d,%d %ux%u)",
            (unsigned long long)producerStreamID, client.windowID,
            layerWindowID, layer ? "YES" : "NO",
            layer.ownerName ?: @"", descriptor.layerOwnerPID,
            descriptor.flags,
            descriptor.width, descriptor.height, descriptor.bytesPerRow,
            descriptor.pixelFormat, descriptor.destinationX,
            descriptor.destinationY, descriptor.destinationWidth,
            descriptor.destinationHeight);
    }
    uint64_t firstDisplayTime = layer ? layer.firstDisplayTime
                                      : client.firstDisplayTime;
    if (MacWSDisplayDiagnosticsEnabled() &&
        (descriptor.sequence % 120) == 0 &&
        displayTime >= firstDisplayTime) {
        static mach_timebase_info_data_t timebase;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
        double elapsed = timebase.denom
            ? (double)(displayTime - firstDisplayTime) *
                timebase.numer / timebase.denom / 1.0e9
            : 0.0;
        DisplayLog(@"throughput stream=%llu window=%u layer=%u frames=%llu "
                   "elapsed=%.3f fps=%.2f outstanding=%lu dropped=%llu",
            (unsigned long long)producerStreamID, client.windowID,
            layerWindowID,
            (unsigned long long)descriptor.sequence, elapsed,
            elapsed > 0.0 ? (descriptor.sequence - 1) / elapsed : 0.0,
            (unsigned long)outstanding,
            (unsigned long long)(layer ? layer.droppedFrames
                                      : client.droppedFrames));
    }
    if (descriptor.pixelFormat == 0) descriptor.pixelFormat = 0x42475241u;

    mach_port_t port = IOSurfaceCreateMachPort(surface);
    if (!MACH_PORT_VALID(port)) {
        [Leases removeObjectForKey:@(lease.token)];
        SetOutstandingFramesForLayer(client, layerWindowID, outstanding);
        return;
    }
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_STREAM_EVENT_FRAME);
    xpc_dictionary_set_data(event, MACWS_STREAM_KEY_DESCRIPTOR,
                            &descriptor, sizeof(descriptor));
    xpc_dictionary_set_mach_send(event, MACWS_STREAM_KEY_SURFACE_PORT, port);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_SURFACE_ID,
                              IOSurfaceGetID(surface));
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_LEASE_TOKEN,
                              lease.token);
    xpc_connection_send_message(client.connection, event);
    mach_port_deallocate(mach_task_self(), port);
}

static BOOL FinalCompositeIsLive(void) {
    return FinalCompositeSurface != NULL &&
        FinalCompositeRecord.completionTime != 0;
}

static void ExpireFinalCompositeIfObsolete(void) {
    if (!FinalCompositeSurface || WorkspaceGraphMutationTime == 0 ||
        WorkspaceGraphMutationTime <= FinalCompositeRecord.completionTime)
        return;
    IOSurfaceRef expiredSurface = FinalCompositeSurface;
    uint32_t expiredSurfaceID = IOSurfaceGetID(expiredSurface);
    pid_t producerPID = FinalCompositeRecord.producerPID;
    uint64_t producerSequence = FinalCompositeRecord.sequence;
    // Clear the authoritative-base identity before publishing the fallback so
    // its descriptor cannot be mislabeled as a final-composite frame.
    FinalCompositeSurface = NULL;

    // Re-arm the exact-window fallback graph before exposing its graphite
    // base. Newly started streams will replace that base with authoritative
    // layer IOSurfaces as their first complete frames arrive.
    ResumeFullscreenLayerCapturesForFallback();

    NSUInteger subscribers = 0;
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused ||
            client.mode != MacWSStreamModeFullscreen ||
            !client.workspaceCanvas) continue;
        subscribers++;
        PublishFrame(client, nil, mach_absolute_time(),
                     client.workspaceCanvas);
    }
    IOSurfaceDecrementUseCount(expiredSurface);
    CFRelease(expiredSurface);
    WriteFinalCompositeState(@"fallback", producerPID, producerSequence,
                             WorkspaceGraphMutationReason ?: @"unknown");
    DisplayLog(@"final-composite-obsolete producer=%d sequence=%llu "
               "surface=%u catch-up-ms=1000 mutation=%@ "
               "fallback=window-iosurface-composite subscribers=%lu",
               producerPID, (unsigned long long)producerSequence,
               expiredSurfaceID, WorkspaceGraphMutationReason ?: @"unknown",
               (unsigned long)subscribers);
}

static void ScheduleFinalCompositeCatchUpDeadline(void) {
    if (!FinalCompositeExpiryTimer) {
        FinalCompositeExpiryTimer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, DisplayQueue);
        dispatch_source_set_event_handler(FinalCompositeExpiryTimer, ^{
            ExpireFinalCompositeIfObsolete();
        });
        dispatch_resume(FinalCompositeExpiryTimer);
    }
    dispatch_source_set_timer(
        FinalCompositeExpiryTimer,
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)FinalCompositeCatchUpNanoseconds),
        DISPATCH_TIME_FOREVER, 0);
}

static uint64_t ReplayMinimumForObservedTopology(uint64_t observedTime) {
    if (observedTime == 0) return 1;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
            timebase.numer == 0 || timebase.denom == 0) {
            timebase.numer = 1;
            timebase.denom = 1;
        }
    });
    // Runtime-confirmed in WindowServer.err on 2026-08-28: for ten ordinary
    // Dock/window topology changes, the completed owned-scanout source
    // preceded displayd's later catalog-observation timestamp by
    // 0.442-11.593 ms.  Requiring source >= observation therefore rejected
    // the frame which caused the observation and left the desktop permanently
    // in layer fallback.  A separate 105.190-ms source was genuinely old.
    // Admit only one bounded 20-ms observation-latency window; older sources
    // still fail and force the typed full-session recovery path.
    static const uint64_t observationSlackNS = 20 * NSEC_PER_MSEC;
    __uint128_t numerator = (__uint128_t)observationSlackNS *
        timebase.denom + timebase.numer - 1;
    uint64_t slackTicks = (uint64_t)(numerator / timebase.numer);
    return observedTime > slackTicks ? observedTime - slackTicks : 1;
}

static void NoteWorkspaceGraphMutation(uint64_t displayTime,
                                       NSString *reason) {
    if (displayTime == 0) displayTime = mach_absolute_time();
    if (displayTime >= WorkspaceGraphMutationTime) {
        WorkspaceGraphMutationTime = displayTime;
        WorkspaceGraphMutationReason = [reason copy] ?: @"unknown";
    }
    // A topology transaction is discrete; request at most once for each
    // observed topology timestamp. Application content is carried by its
    // independent exact-window stream and is not a mutation of the retained
    // desktop-material base.
    // This request must not depend on FinalCompositeSurface being non-null:
    // after the one-second expiry the old implementation permanently lost
    // its only path back from window-layer fallback, so "repair desktop"
    // could restart Dock successfully without ever reacquiring SkyLight's
    // authoritative material composite.
    if ([reason isEqualToString:@"layer-topology"] &&
        WorkspaceGraphMutationTime >
            FinalCompositeReplayRequestedThroughMutationTime) {
        FinalCompositeReplayRequestedThroughMutationTime =
            WorkspaceGraphMutationTime;
        uint64_t replayMinimum = ReplayMinimumForObservedTopology(
            WorkspaceGraphMutationTime);
        MacWSRequestFinalCompositeReplay(replayMinimum);
        DisplayLog(@"final-composite-catch-up-request producer=%d "
                   "sequence=%llu surface=%@ mutation=%@ "
                   "observed=%llu replay-minimum=%llu slack-ms=20",
                   FinalCompositeRecord.producerPID,
                   (unsigned long long)FinalCompositeRecord.sequence,
                   FinalCompositeSurface ? @"ready" : @"missing",
                   WorkspaceGraphMutationReason ?: @"unknown",
                   (unsigned long long)WorkspaceGraphMutationTime,
                   (unsigned long long)replayMinimum);
    }
    if (FinalCompositeSurface &&
        WorkspaceGraphMutationTime > FinalCompositeRecord.completionTime) {
        ScheduleFinalCompositeCatchUpDeadline();
    }
}

static void DeliverFinalComposite(
        IOSurfaceRef surface, MacWSFinalCompositeRecord record) {
    if (!surface) return;
    if (FinalCompositeRecord.producerPID == record.producerPID &&
        FinalCompositeRecord.sequence >= record.sequence) return;
    IOSurfaceRef oldSurface = FinalCompositeSurface;
    // Own one cross-process use count for the current presentation surface.
    // Every Host lease owns an additional local count. The producer's pool
    // therefore sees IOSurfaceIsInUse until both the current-frame reference
    // and every outstanding GPU lease have retired.
    IOSurfaceIncrementUseCount(surface);
    FinalCompositeSurface = (IOSurfaceRef)CFRetain(surface);
    FinalCompositeRecord = record;
    WriteFinalCompositeState(@"ready", record.producerPID, record.sequence,
                             @"validated-final-composite");
    if (WorkspaceGraphMutationTime > record.completionTime) {
        ScheduleFinalCompositeCatchUpDeadline();
    } else if (FinalCompositeExpiryTimer) {
        dispatch_source_set_timer(FinalCompositeExpiryTimer,
            DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    }
    if (oldSurface) {
        IOSurfaceDecrementUseCount(oldSurface);
        CFRelease(oldSurface);
    }

    // The completed final composite is the complete native desktop authority
    // for a fullscreen Host. Retain exact-layer identities and their latest
    // surfaces for fallback/Catalyst geometry, but suspend duplicate native
    // capture streams one display interval apart. FullscreenCanvas remains an
    // independent direct-drawable authority and is handled by its validated
    // activity lease.
    SuspendFullscreenLayerCapturesForFinalComposite();

    NSUInteger subscribers = 0;
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused) continue;
        if (client.mode == MacWSStreamModeWindow) {
            for (MacWSTransientLayer *layer in client.transientLayers.allValues) {
                if (layer.popupCompositeEligible && !layer.retiring && layer.latestSurface)
                    PublishFrame(client, layer, layer.latestDisplayTime, layer.latestSurface);
            }
            continue;
        }
        if (client.mode != MacWSStreamModeFullscreen) continue;
        subscribers++;
        PublishFrame(client, nil, record.completionTime,
                     FinalCompositeSurface);
    }
    static BOOL loggedFirstAcceptedFrame = NO;
    if (!loggedFirstAcceptedFrame || MacWSDisplayDiagnosticsEnabled()) {
        loggedFirstAcceptedFrame = YES;
        DisplayLog(@"final-composite-received producer=%d sequence=%llu "
                   "surface=%u size=%ux%u bpr=%u subscribers=%lu",
                   record.producerPID,
                   (unsigned long long)record.sequence, record.surfaceID,
                   record.width, record.height, record.bytesPerRow,
                   (unsigned long)subscribers);
    }
}

static CGDisplayStreamRef CreateStream(MacWSDisplayClient *client) {
    NSDictionary *properties = StreamProperties();
    __weak MacWSDisplayClient *weakClient = client;
    uint64_t generation = client.streamID;
    CGDisplayStreamFrameAvailableHandler handler =
        ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
          IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
            (void)updateRef;
            MacWSDisplayClient *strongClient = weakClient;
            // CGDisplayStreamStop is asynchronous. A terminal callback from
            // the previous exact/composite stream must not be relabelled with
            // the new streamID and overwrite the Host with stale pixels.
            if (!strongClient || strongClient.streamID != generation) return;
            if (status == kCGDisplayStreamFrameStatusFrameComplete) {
                PublishFrame(strongClient, nil, displayTime, frameSurface);
            } else if (status == kCGDisplayStreamFrameStatusStopped) {
                SendStatus(strongClient, MACWS_STREAM_EVENT_STOPPED,
                           @"DisplayStream stopped", YES);
            }
        };
    if (client.mode == MacWSStreamModeFullscreen) return NULL;

    MacWSSLSWindowStreamCreate createWindow = dlsym(
        RTLD_DEFAULT, "SLSHWCaptureStreamCreateWithWindow");
    if (!createWindow || client.windowID == 0) return NULL;
    return createWindow(client.windowID, false,
                        (__bridge CFDictionaryRef)properties,
                        DisplayQueue, handler);
}

static IOSurfaceRef CreateWorkspaceCanvas(MacWSDisplayClient *client) {
    CGDirectDisplayID display = CGMainDisplayID();
    CGRect logicalBounds = CGDisplayBounds(display);
    CGFloat backingScale = MainDisplayBackingScale();
    size_t width = 0, height = 0;
    // runtime-confirmed via macwsdisplayd.log on iPad13,6: the old canvas was
    // 1194x834 at scale 2 while the compositor published a 2388x1668 desktop
    // and layer destinations. That mixed coordinate spaces, cropping the
    // desktop and shifting every fullscreen input point by 2x.
    if (!MacWSPhysicalDisplayExtent(logicalBounds.size.width,
                                    logicalBounds.size.height,
                                    backingScale,
                                    MACWS_STREAM_MAX_DIMENSION,
                                    &width, &height) ||
        width > SIZE_MAX / 4)
        return NULL;
    // iOS 16.3 Metal's _mtlValidateStrideTextureParameters asks the native
    // AGX device for iosurfaceReadOnlyTextureAlignmentBytes before importing
    // a ShaderRead IOSurface. Runtime LLDB evidence on iPad13,6 shows that
    // value is 16 bytes. The target's 1194-pixel workspace was previously
    // allocated with a 4776-byte row, which violates that real invariant.
    static const size_t kMacWSMetalIOSurfaceRowAlignment = 16;
    size_t tightBytesPerRow = width * 4;
    if (tightBytesPerRow > SIZE_MAX -
            (kMacWSMetalIOSurfaceRowAlignment - 1)) return NULL;
    size_t bytesPerRow = (tightBytesPerRow +
        (kMacWSMetalIOSurfaceRowAlignment - 1)) &
        ~(kMacWSMetalIOSurfaceRowAlignment - 1);
    if (height > SIZE_MAX / bytesPerRow) return NULL;
    NSDictionary *properties = @{
        (__bridge id)kIOSurfaceWidth: @(width),
        (__bridge id)kIOSurfaceHeight: @(height),
        (__bridge id)kIOSurfaceBytesPerElement: @4,
        (__bridge id)kIOSurfaceBytesPerRow: @(bytesPerRow),
        (__bridge id)kIOSurfaceAllocSize: @(bytesPerRow * height),
        (__bridge id)kIOSurfacePixelFormat: @(0x42475241u),
    };
    IOSurfaceRef surface = IOSurfaceCreate(
        (__bridge CFDictionaryRef)properties);
    if (!surface) return NULL;
    IOReturn lockResult = IOSurfaceLock(surface, 0, NULL);
    if (lockResult != kIOReturnSuccess) {
        CFRelease(surface);
        return NULL;
    }
    uint32_t *pixels = IOSurfaceGetBaseAddress(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface) / sizeof(uint32_t);
    if (!pixels || stride < width) {
        IOSurfaceUnlock(surface, 0, NULL);
        CFRelease(surface);
        return NULL;
    }
    // Opaque graphite is only the desktop backing. Real wallpaper, menu bar,
    // Dock and application windows arrive as native SkyLight capture layers.
    // It also provides deterministic pixels when a desktop element declines
    // capture instead of exposing uninitialised IOSurface memory.
    for (size_t y = 0; y < height; y++) {
        uint32_t *row = pixels + y * stride;
        for (size_t x = 0; x < width; x++) row[x] = 0xff25282du;
    }
    IOSurfaceUnlock(surface, 0, NULL);
    client.windowBackingScale = backingScale;
    return surface;
}

static void SendLayerRemoved(MacWSDisplayClient *client,
                             MacWSTransientLayer *layer) {
    if (!client.connection || client.deliveryPaused) return;
    if (!layer || layer.windowID == 0) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_STREAM_EVENT_LAYER_REMOVED);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_WINDOW_ID,
                              client.windowID);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_LAYER_WINDOW_ID,
                              layer.windowID);
    // This is the exact ordered cutoff for the producer generation. A return
    // republish increments layer.sequence in PublishFrame, allowing Host to
    // distinguish it from an already-queued pre-removal frame without
    // restarting the real CGDisplayStream.
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_STREAM_ID,
                              layer.streamID);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_SEQUENCE,
                              layer.sequence);
    xpc_connection_send_message(client.connection, event);
}

static void AppendLayerGeometry(NSMutableData *batch,
                                MacWSDisplayClient *client,
                                MacWSTransientLayer *layer,
                                uint64_t displayTime) {
    if (!batch || !client || !layer || !layer.latestSurface ||
        layer.retiring || batch.length / sizeof(MacWSStreamLayerGeometry) >=
            MACWS_STREAM_MAX_LAYER_GEOMETRY) return;
    uint32_t flags = MacWSStreamFrameOverlay |
        ([layer.ownerName isEqualToString:@"Dock"]
            ? MacWSStreamFrameGlobalSystemSurface : 0) |
        (layer.skyLightLayer >= CGWindowLevelForKey(kCGCursorWindowLevelKey)
            ? MacWSStreamFrameInputPassthrough : 0);
    MacWSStreamLayerGeometry geometry = {
        .magic = MACWS_STREAM_MAGIC,
        .version = MACWS_STREAM_VERSION,
        .size = sizeof(MacWSStreamLayerGeometry),
        .streamID = layer.streamID,
        .sequence = ++layer.sequence,
        .displayTime = displayTime,
        .windowID = client.windowID,
        .layerWindowID = layer.windowID,
        .layerOwnerPID = layer.ownerPID,
        .layerLevel = layer.level,
        .destinationX = (int32_t)llround(layer.destinationBounds.origin.x),
        .destinationY = (int32_t)llround(layer.destinationBounds.origin.y),
        .destinationWidth = (uint32_t)llround(
            layer.destinationBounds.size.width),
        .destinationHeight = (uint32_t)llround(
            layer.destinationBounds.size.height),
        .flags = flags,
    };
    if (!MacWSStreamLayerGeometryIsValid(&geometry, sizeof(geometry))) {
        // Do not consume an invalid sequence. The next real content frame or
        // valid geometry transaction remains contiguous and authoritative.
        layer.sequence--;
        return;
    }
    [layer recordActiveFrameAtDisplayTime:displayTime];
    layer.latestDisplayTime = displayTime;
    [batch appendBytes:&geometry length:sizeof(geometry)];
}

static void SendLayerGeometryBatch(MacWSDisplayClient *client,
                                   NSData *batch) {
    if (!client.connection || client.deliveryPaused || !batch.length ||
        batch.length % sizeof(MacWSStreamLayerGeometry) != 0 ||
        batch.length / sizeof(MacWSStreamLayerGeometry) >
            MACWS_STREAM_MAX_LAYER_GEOMETRY) return;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_STREAM_KEY_EVENT,
                              MACWS_STREAM_EVENT_LAYER_GEOMETRY);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_dictionary_set_uint64(event, MACWS_STREAM_KEY_WINDOW_ID,
                              client.windowID);
    xpc_dictionary_set_data(event, MACWS_STREAM_KEY_LAYER_GEOMETRY,
                            batch.bytes, batch.length);
    xpc_connection_send_message(client.connection, event);
}

static double WorkspaceMachMilliseconds(uint64_t start, uint64_t end) {
    if (!start || end < start) return 0.0;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
    if (!timebase.denom) return 0.0;
    return (double)(end - start) * timebase.numer / timebase.denom / 1.0e6;
}

static void FinishWorkspaceGeometryBurst(void) {
    if (!WorkspaceGeometryBurstActive) return;
    WorkspaceGeometryBurstActive = NO;
    if (!MacWSDisplayDiagnosticsEnabled()) {
        WorkspaceGeometryQueryDurationCount = 0;
        WorkspaceGeometryQueryDurationCursor = 0;
        return;
    }
    NSUInteger count = MIN(WorkspaceGeometryQueryDurationCount,
        sizeof(WorkspaceGeometryQueryDurationsMS) /
            sizeof(WorkspaceGeometryQueryDurationsMS[0]));
    if (count) {
        double durations[256];
        double total = 0.0;
        for (NSUInteger index = 0; index < count; index++) {
            durations[index] = WorkspaceGeometryQueryDurationsMS[index];
            total += durations[index];
        }
        qsort(durations, count, sizeof(durations[0]),
              MacWSCompareFrameInterval);
        NSUInteger p50Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.50) - 1);
        NSUInteger p95Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.95) - 1);
        NSUInteger p99Index = MIN(count - 1,
            (NSUInteger)ceil((double)count * 0.99) - 1);
        DisplayLog(@"workspace-geometry-burst queries=%llu records=%llu "
                   "query-mean-ms=%.3f p50-ms=%.3f p95-ms=%.3f "
                   "p99-ms=%.3f route=targeted-description-async",
                   (unsigned long long)WorkspaceGeometryQuerySamples,
                   (unsigned long long)WorkspaceGeometryRecordsSent,
                   total / count, durations[p50Index], durations[p95Index],
                   durations[p99Index]);
    }
}

static void ApplyWorkspaceGeometryDescriptions(
        NSArray<NSDictionary *> *descriptions, uint64_t displayTime) {
    NSMutableDictionary<NSNumber *, NSDictionary *> *byWindow =
        [NSMutableDictionary dictionaryWithCapacity:descriptions.count];
    for (NSDictionary *info in descriptions) {
        NSNumber *windowID = info[(id)kCGWindowNumber];
        if (windowID.unsignedIntValue) byWindow[windowID] = info;
    }
    CGRect desktopBounds = CGDisplayBounds(CGMainDisplayID());
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused) continue;
        BOOL fullscreen = client.mode == MacWSStreamModeFullscreen;
        BOOL windowed = client.mode == MacWSStreamModeWindow &&
            client.windowID != 0;
        if ((!fullscreen && !windowed) ||
            (fullscreen && CGRectIsEmpty(desktopBounds))) continue;
        CGRect baseBounds = CGRectZero;
        if (windowed) {
            NSDictionary *baseInfo = byWindow[@(client.windowID)];
            if (!baseInfo || !CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)baseInfo[(id)kCGWindowBounds],
                    &baseBounds) || CGRectIsEmpty(baseBounds)) continue;
        }
        CGFloat scale = client.windowBackingScale > 0.0
            ? client.windowBackingScale : MainDisplayBackingScale();
        if (!isfinite(scale) || scale < 0.5 || scale > 8.0) continue;
        NSMutableData *geometryBatch = [NSMutableData dataWithCapacity:
            MIN(client.transientLayers.count, (NSUInteger)
                MACWS_STREAM_MAX_LAYER_GEOMETRY) *
                sizeof(MacWSStreamLayerGeometry)];
        for (NSNumber *key in [client.transientLayers.allKeys copy]) {
            MacWSTransientLayer *layer = client.transientLayers[key];
            NSDictionary *info = byWindow[key];
            if (!layer || layer.retiring || !layer.latestSurface || !info)
                continue;
            CGRect bounds = CGRectZero;
            if (!CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                    &bounds) || CGRectIsEmpty(bounds)) continue;
            BOOL usedSurfaceMeasurement = NO;
            CGFloat presentationScale = LayerPresentationScale(
                bounds, layer.latestSurface, scale,
                &usedSurfaceMeasurement);
            if (usedSurfaceMeasurement &&
                fabs(presentationScale - scale) > 0.08 &&
                !layer.reportedPresentationScaleNormalization) {
                layer.reportedPresentationScaleNormalization = YES;
                DisplayLog(@"runtime-confirmed presentation-scale-normalized "
                           "layer=%u owner-pid=%d bounds=%.0fx%.0f "
                           "surface=%zux%zu display-scale=%.3f "
                           "presentation-scale=%.3f",
                           layer.windowID, layer.ownerPID,
                           bounds.size.width, bounds.size.height,
                           IOSurfaceGetWidth(layer.latestSurface),
                           IOSurfaceGetHeight(layer.latestSurface), scale,
                           presentationScale);
            }
            CGRect destination = fullscreen
                ? MacWSWorkspaceLayerDestination(
                    client, layer, bounds, desktopBounds, presentationScale,
                    usedSurfaceMeasurement)
                : CGRectMake(
                    (bounds.origin.x - baseBounds.origin.x) * scale,
                    (bounds.origin.y - baseBounds.origin.y) * scale,
                    usedSurfaceMeasurement
                        ? IOSurfaceGetWidth(layer.latestSurface)
                        : bounds.size.width * scale,
                    usedSurfaceMeasurement
                        ? IOSurfaceGetHeight(layer.latestSurface)
                        : bounds.size.height * scale);
            if (CGRectEqualToRect(layer.destinationBounds, destination))
                continue;
            // The texture crop belongs to the old global geometry. Do not
            // slide an old desktop rectangle with a newly moved NSWindow.
            // Reconciliation establishes a fresh crop/completion boundary.
            layer.popupCompositeEligible = NO;
            layer.destinationBounds = destination;
            if (windowed && layer.lastPopupCompositeSequence && layer.latestSurface)
                PublishFrame(client, layer, layer.latestDisplayTime, layer.latestSurface);
            AppendLayerGeometry(geometryBatch, client, layer, displayTime);
        }
        WorkspaceGeometryRecordsSent += geometryBatch.length /
            sizeof(MacWSStreamLayerGeometry);
        SendLayerGeometryBatch(client, geometryBatch);
    }
}

static void RequestWorkspaceGeometrySample(void) {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now >= WorkspaceGeometrySamplingDeadline()) {
        if (WorkspaceGeometryBurstActive &&
            !WorkspaceGeometryQueryInFlight) {
            WorkspaceGeometryQueryPending = NO;
            FinishWorkspaceGeometryBurst();
            ScheduleTransientReconcile(0);
        }
        return;
    }
    if (WorkspaceGeometryQueryInFlight) {
        WorkspaceGeometryQueryPending = YES;
        return;
    }
    NSMutableOrderedSet<NSNumber *> *identifiers = [NSMutableOrderedSet
        orderedSet];
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused) continue;
        if (client.mode == MacWSStreamModeWindow && client.windowID != 0)
            [identifiers addObject:@(client.windowID)];
        else if (client.mode != MacWSStreamModeFullscreen)
            continue;
        for (NSNumber *key in client.transientLayers) {
            MacWSTransientLayer *layer = client.transientLayers[key];
            if (layer.latestSurface && !layer.retiring)
                [identifiers addObject:key];
        }
    }
    if (!identifiers.count) return;
    if (!WorkspaceGeometryBurstActive) {
        WorkspaceGeometryBurstActive = YES;
        WorkspaceGeometryQuerySamples = 0;
        WorkspaceGeometryRecordsSent = 0;
        WorkspaceGeometryQueryDurationCount = 0;
        WorkspaceGeometryQueryDurationCursor = 0;
        memset(WorkspaceGeometryQueryDurationsMS, 0,
               sizeof(WorkspaceGeometryQueryDurationsMS));
    }
    WorkspaceGeometryQueryInFlight = YES;
    WorkspaceGeometryQueryPending = NO;
    uint64_t generation = ++WorkspaceGeometryQueryGeneration;
    NSArray<NSNumber *> *windowIDs = identifiers.array;
    uint64_t queryStarted = mach_absolute_time();
    dispatch_async(WorkspaceGeometryQueue, ^{
        @autoreleasepool {
            NSArray<NSDictionary *> *descriptions =
                CopyWindowDescriptions(windowIDs);
            uint64_t queryFinished = mach_absolute_time();
            dispatch_async(DisplayQueue, ^{
                WorkspaceGeometryQueryInFlight = NO;
                if (generation != WorkspaceGeometryQueryGeneration) return;
                double duration = WorkspaceMachMilliseconds(queryStarted,
                                                             queryFinished);
                NSUInteger capacity =
                    sizeof(WorkspaceGeometryQueryDurationsMS) /
                    sizeof(WorkspaceGeometryQueryDurationsMS[0]);
                WorkspaceGeometryQueryDurationsMS[
                    WorkspaceGeometryQueryDurationCursor] = duration;
                WorkspaceGeometryQueryDurationCursor =
                    (WorkspaceGeometryQueryDurationCursor + 1) % capacity;
                if (WorkspaceGeometryQueryDurationCount < capacity)
                    WorkspaceGeometryQueryDurationCount++;
                WorkspaceGeometryQuerySamples++;
                ApplyWorkspaceGeometryDescriptions(descriptions,
                                                    queryFinished);

                CFTimeInterval completedAt = CFAbsoluteTimeGetCurrent();
                if (completedAt < WorkspaceGeometrySamplingDeadline()) {
                    const double frameBudgetMS = 1000.0 / 60.0;
                    uint64_t delay = duration < frameBudgetMS
                        ? (uint64_t)llround((frameBudgetMS - duration) *
                                           NSEC_PER_MSEC)
                        : 0;
                    // A queued real Dock progress edge wins over the cadence
                    // timer, but both collapse through the in-flight gate.
                    if (WorkspaceGeometryQueryPending) delay = 0;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay),
                                   DisplayQueue, ^{
                        RequestWorkspaceGeometrySample();
                    });
                } else {
                    WorkspaceGeometryQueryPending = NO;
                    FinishWorkspaceGeometryBurst();
                    // Presentation sampling deliberately ignores topology.
                    // One authoritative full snapshot now discovers/removes
                    // transition windows after Dock's native animation ends.
                    ScheduleTransientReconcile(0);
                }
            });
        }
    });
}

static void DrainOneRetiredTransientStop(void) {
    if (RetiredTransientStopBlocks.count == 0) {
        RetiredTransientStopDrainPending = NO;
        return;
    }
    dispatch_block_t stopBlock = RetiredTransientStopBlocks.firstObject;
    [RetiredTransientStopBlocks removeObjectAtIndex:0];
    stopBlock();
    if (RetiredTransientStopBlocks.count == 0) {
        RetiredTransientStopDrainPending = NO;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   DisplayQueue, ^{
        DrainOneRetiredTransientStop();
    });
}

static void EnqueueRetiredTransientStop(dispatch_block_t stopBlock) {
    if (!stopBlock) return;
    [RetiredTransientStopBlocks addObject:[stopBlock copy]];
    DisplayLog(@"layer-retire-stop-queued depth=%lu interval-ms=16",
               (unsigned long)RetiredTransientStopBlocks.count);
    if (RetiredTransientStopDrainPending) return;
    RetiredTransientStopDrainPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   DisplayQueue, ^{
        DrainOneRetiredTransientStop();
    });
}

static void RetireTransientLayer(MacWSDisplayClient *client,
                                 NSNumber *key,
                                 MacWSTransientLayer *layer,
                                 NSString *reason) {
    if (!client || !key || !layer || layer.retiring) return;
    layer.retiring = YES;
    [layer finishActiveFrameBurstWithReason:@"catalog-retire"];
    uint64_t generation = ++layer.retirementGeneration;
    // Detach delivery immediately: Host has already removed this layer and a
    // final frame racing from the old stream must not resurrect stale pixels.
    layer.client = nil;
    if (![RetiredTransientLayers containsObject:layer])
        [RetiredTransientLayers addObject:layer];
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t timebaseOnce;
    dispatch_once(&timebaseOnce, ^{ (void)mach_timebase_info(&timebase); });
    double elapsed = 0.0;
    if (timebase.denom && layer.firstDisplayTime &&
        layer.latestDisplayTime >= layer.firstDisplayTime) {
        elapsed = (double)(layer.latestDisplayTime - layer.firstDisplayTime) *
            timebase.numer / timebase.denom / 1.0e9;
    }
    NSUInteger outstanding = OutstandingFramesForLayer(client,
                                                         layer.windowID);
    DisplayLog(@"layer-retire-begin layer=%u reason=%@ grace-ms=5000 "
               "frames=%llu elapsed=%.3f fps=%.2f outstanding=%lu "
               "dropped=%llu",
               layer.windowID, reason ?: @"catalog-removed",
               (unsigned long long)layer.sequence, elapsed,
               elapsed > 0.0 && layer.sequence > 1
                   ? (layer.sequence - 1) / elapsed : 0.0,
               (unsigned long)outstanding,
               (unsigned long long)layer.droppedFrames);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   DisplayQueue, ^{
        if (!layer.retiring ||
            layer.retirementGeneration != generation) return;
        // If the same SkyLight window ID returned during the grace period,
        // reconciliation cancels this retirement and reuses the live stream.
        if (client.transientLayers[key] != layer) {
            [RetiredTransientLayers removeObject:layer];
            return;
        }
        EnqueueRetiredTransientStop(^{
            // The catalog may have restored this exact window in the short
            // interval between the grace expiry and its staggered drain slot.
            if (!layer.retiring ||
                layer.retirementGeneration != generation ||
                client.transientLayers[key] != layer) {
                [RetiredTransientLayers removeObject:layer];
                return;
            }
            [layer stopStream];
            [client.transientLayers removeObjectForKey:key];
            [RetiredTransientLayers removeObject:layer];
            DisplayLog(@"layer-retire-complete layer=%u reason=%@",
                       layer.windowID, reason ?: @"catalog-removed");
        });
    });
}

static void StartTransientLayer(MacWSTransientLayer *layer) {
    MacWSDisplayClient *client = layer.client;
    if (!client || layer.windowID == 0 ||
        layer.directDrawableCaptureSuspended ||
        layer.directDrawableCaptureSuspensionPending) return;
    // Preserve the last complete IOSurface while SkyLight retires/recreates
    // the exact-window stream. Host can keep compositing it at the newly
    // committed destination instead of flashing a black hole during resize.
    [layer stopCapturePreservingSurface];
    layer.streamID = NextStreamID++;
    if (layer.streamID == 0) layer.streamID = NextStreamID++;
    layer.droppedFrames = 0;
    layer.firstDisplayTime = 0;
    layer.snapshotComplete = NO;
    uint64_t generation = layer.streamID;
    __weak MacWSTransientLayer *weakLayer = layer;
    CGDisplayStreamFrameAvailableHandler handler =
        ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
          IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
            (void)updateRef;
            MacWSTransientLayer *strongLayer = weakLayer;
            MacWSDisplayClient *strongClient = strongLayer.client;
            if (!strongLayer || !strongClient ||
                strongLayer.streamID != generation) return;
            if (status == kCGDisplayStreamFrameStatusFrameComplete) {
                if (strongClient.mode == MacWSStreamModeWindow) {
                    // A window Scene is expressed in the base capture's pixel
                    // coordinate space. The exact transient IOSurface is the
                    // authoritative size in that same space; using
                    // CGWindow-point bounds multiplied by the base scale can
                    // stretch utility panels whose presentation scale differs
                    // from their presenter during creation. Commit the real
                    // surface size before publishing its first frame so Host
                    // never displays one distorted generation.
                    size_t surfaceWidth = IOSurfaceGetWidth(frameSurface);
                    size_t surfaceHeight = IOSurfaceGetHeight(frameSurface);
                    CGRect destination = strongLayer.destinationBounds;
                    BOOL corrected = surfaceWidth && surfaceHeight &&
                        (fabs(destination.size.width - surfaceWidth) > 0.5 ||
                         fabs(destination.size.height - surfaceHeight) > 0.5);
                    if (corrected) {
                        DisplayLog(@"runtime-confirmed window-layer-size "
                                   "base=%u layer=%u catalog=%.0fx%.0f "
                                   "surface=%zux%zu route=surface-authority",
                                   strongClient.windowID,
                                   strongLayer.windowID,
                                   destination.size.width,
                                   destination.size.height,
                                   surfaceWidth, surfaceHeight);
                        destination.size = CGSizeMake(surfaceWidth,
                                                      surfaceHeight);
                        strongLayer.destinationBounds = destination;
                    }
                }
                // Runtime-confirmed during Stray: treating every exact-window
                // frame as a mutation of the desktop-material base expired
                // final-composite after one second, restarted the full Dock /
                // Finder / menu capture graph, cleared Host's fullscreen crop
                // and added avoidable sustained load. The layer IOSurface is
                // already the authoritative content update. Geometry/catalog
                // changes continue to call NoteWorkspaceGraphMutation with
                // layer-topology below.
                PublishFrame(strongClient, strongLayer, displayTime,
                             frameSurface);
                if (strongLayer.oneShotCapture &&
                    !strongLayer.snapshotComplete) {
                    strongLayer.snapshotComplete = YES;
                    // Wallpaper/backing streams have fulfilled their only
                    // job after one complete native IOSurface. Stop capture
                    // on the next display-queue turn while retaining that
                    // immutable surface for Host composition.
                    dispatch_async(DisplayQueue, ^{
                        MacWSTransientLayer *snapshotLayer = weakLayer;
                        if (!snapshotLayer ||
                            snapshotLayer.streamID != generation ||
                            !snapshotLayer.oneShotCapture ||
                            !snapshotLayer.snapshotComplete) return;
                        [snapshotLayer stopCapturePreservingSurface];
                        DisplayLog(@"workspace-layer-snapshot stream=%llu layer=%u owner=%@ name=%@",
                            (unsigned long long)generation,
                            snapshotLayer.windowID,
                            snapshotLayer.ownerName ?: @"",
                            snapshotLayer.windowName ?: @"");
                    });
                }
            }
        };
    MacWSSLSWindowStreamCreate createWindow = dlsym(
        RTLD_DEFAULT, "SLSHWCaptureStreamCreateWithWindow");
    if (!createWindow) return;
    layer.stream = createWindow(layer.windowID, false,
        (__bridge CFDictionaryRef)StreamProperties(), DisplayQueue, handler);
    if (!layer.stream) return;
    CGError error = CGDisplayStreamStart(layer.stream);
    if (error != kCGErrorSuccess) {
        [layer stopCapturePreservingSurface];
        DisplayLog(@"layer-start failed base=%u layer=%u error=%d",
                   client.windowID, layer.windowID, error);
        return;
    }
    DisplayLog(@"layer-start stream=%llu base=%u layer=%u level=%d "
               "owner-pid=%d owner=%@ name=%@ skylight-layer=%ld "
               "destination=(%.0f,%.0f %.0fx%.0f)",
        (unsigned long long)layer.streamID, client.windowID, layer.windowID,
        layer.level, layer.ownerPID, layer.ownerName ?: @"",
        layer.windowName ?: @"", (long)layer.skyLightLayer,
        layer.destinationBounds.origin.x,
        layer.destinationBounds.origin.y, layer.destinationBounds.size.width,
        layer.destinationBounds.size.height);
}

static MacWSTransientLayer *ValidatedDirectDrawableLayer(
        MacWSDisplayClient *client, int32_t ownerPID, uint32_t layerWindowID,
        uint32_t width, uint32_t height, NSString **rejectionReason) {
    if (rejectionReason) *rejectionReason = nil;
    if (!client || !client.subscriptionActive || client.deliveryPaused ||
        client.mode != MacWSStreamModeFullscreen || !client.workspaceCanvas) {
        if (rejectionReason) *rejectionReason = @"client-state";
        return nil;
    }
    if (ownerPID <= 1 || layerWindowID == 0 || width == 0 || height == 0 ||
        width > MACWS_STREAM_MAX_DIMENSION ||
        height > MACWS_STREAM_MAX_DIMENSION) {
        if (rejectionReason) *rejectionReason = @"malformed-identity";
        return nil;
    }
    MacWSTransientLayer *layer =
        client.transientLayers[@(layerWindowID)];
    if (!layer) {
        if (rejectionReason) *rejectionReason = @"layer-missing";
        return nil;
    }
    if (layer.client != client || layer.ownerPID != ownerPID) {
        if (rejectionReason) *rejectionReason = @"layer-identity";
        return nil;
    }
    if (layer.retiring) {
        if (rejectionReason) *rejectionReason = @"layer-retiring";
        return nil;
    }
    if (layer.oneShotCapture) {
        if (rejectionReason) *rejectionReason = @"snapshot-layer";
        return nil;
    }
    BOOL fullscreenCanvas = (layer.windowFlags &
        MacWSStreamWindowFullscreenCanvas) != 0;
    MacWSStreamWindowFlags ordinaryRequired = MacWSStreamWindowFocused |
        MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
    if (!fullscreenCanvas &&
        (layer.windowFlags & ordinaryRequired) != ordinaryRequired) {
        if (rejectionReason) *rejectionReason = @"not-focused-visible";
        return nil;
    }
    BOOL alreadyValidated = client.directDrawableActive &&
        client.directDrawableOwnerPID == ownerPID &&
        client.directDrawableLayerWindowID == layerWindowID;
    NSNumber *catalogOwner = client.focusedWindowOwners[@(layerWindowID)];
    if (!alreadyValidated && catalogOwner.intValue != ownerPID) {
        if (rejectionReason) {
            *rejectionReason = layer.skyLightLayer != 0
                ? @"layer-level-focus" : @"catalog-focus";
        }
        return nil;
    }
    // A real fullscreen transition can move the focused Stray NSWindow from
    // SkyLight level 0 to level 25 without changing its CGWindow ID or
    // drawable. The exact catalog owner above, not PID or geometry alone,
    // authorizes that transition.
    if (layer.skyLightLayer != 0 &&
        !layer.reportedDirectDrawableFocusedLevelAcceptance) {
        layer.reportedDirectDrawableFocusedLevelAcceptance = YES;
        DisplayLog(@"runtime-confirmed direct-drawable-focused-level "
                   "owner-pid=%d layer=%u skylight-level=%ld "
                   "catalog-focused=YES",
                   ownerPID, layerWindowID, (long)layer.skyLightLayer);
    }
    if (!layer.latestSurface) {
        if (rejectionReason) *rejectionReason = @"surface-missing";
        return nil;
    }
    size_t canvasWidth = IOSurfaceGetWidth(client.workspaceCanvas);
    size_t canvasHeight = IOSurfaceGetHeight(client.workspaceCanvas);
    CGRect destination = layer.destinationBounds;
    CGRect canvas = CGRectMake(0, 0, canvasWidth, canvasHeight);
    if (width < 320 || height < 240) {
        if (rejectionReason) *rejectionReason = @"drawable-size";
        return nil;
    }
    if (CGRectIsNull(destination) || CGRectIsEmpty(destination) ||
        CGRectGetWidth(destination) < 320.0 ||
        CGRectGetHeight(destination) < 240.0 ||
        !CGRectContainsRect(CGRectInset(canvas, -0.5, -0.5), destination)) {
        if (rejectionReason) *rejectionReason = @"destination";
        return nil;
    }
    if (!fullscreenCanvas) {
        size_t surfaceWidth = IOSurfaceGetWidth(layer.latestSurface);
        size_t surfaceHeight = IOSurfaceGetHeight(layer.latestSurface);
        uint64_t widthDifference = width > surfaceWidth
            ? width - surfaceWidth : surfaceWidth - width;
        uint64_t heightDifference = height > surfaceHeight
            ? height - surfaceHeight : surfaceHeight - height;
        if (surfaceWidth == 0 || surfaceHeight == 0 ||
            widthDifference * 5u > surfaceWidth ||
            heightDifference * 5u > surfaceHeight) {
            if (rejectionReason) *rejectionReason = @"focused-size";
            return nil;
        }
    }
    return layer;
}

static BOOL ValidateDirectDrawableWindowBase(
        MacWSDisplayClient *client, int32_t ownerPID,
        uint32_t layerWindowID, uint32_t width, uint32_t height,
        NSString **rejectionReason) {
    if (rejectionReason) *rejectionReason = nil;
    BOOL ownsBaseSuspension = client && client.directDrawableActive &&
        client.directDrawableOwnerPID == ownerPID &&
        client.directDrawableLayerWindowID == layerWindowID &&
        (client.directDrawableBaseCaptureSuspended ||
         client.directDrawableBaseCaptureSuspensionPending);
    if (!client || !client.subscriptionActive || client.deliveryPaused ||
        client.mode != MacWSStreamModeWindow || client.windowID == 0 ||
        (!client.stream && !ownsBaseSuspension)) {
        if (rejectionReason) *rejectionReason = @"window-client-state";
        return NO;
    }
    if (ownerPID <= 1 || layerWindowID == 0 || width < 320 || height < 240 ||
        width > MACWS_STREAM_MAX_DIMENSION ||
        height > MACWS_STREAM_MAX_DIMENSION) {
        if (rejectionReason) *rejectionReason = @"malformed-window-identity";
        return NO;
    }
    if (client.windowID != layerWindowID ||
        client.catalogFrontmostWindowID != layerWindowID ||
        client.catalogFrontmostOwnerPID != ownerPID) {
        if (rejectionReason) *rejectionReason = @"window-focus-identity";
        return NO;
    }
    size_t baseWidth = client.lastSurfaceWidth;
    size_t baseHeight = client.lastSurfaceHeight;
    uint64_t widthDifference = width > baseWidth
        ? width - baseWidth : baseWidth - width;
    uint64_t heightDifference = height > baseHeight
        ? height - baseHeight : baseHeight - height;
    if (baseWidth == 0 || baseHeight == 0 ||
        widthDifference * 5u > baseWidth ||
        heightDifference * 5u > baseHeight) {
        if (rejectionReason) *rejectionReason = @"window-focused-size";
        return NO;
    }
    return YES;
}

static void ClearDirectDrawableActivity(MacWSDisplayClient *client,
                                        NSString *reason) {
    if (!client) return;
    BOOL wasActive = client.directDrawableActive;
    int32_t ownerPID = client.directDrawableOwnerPID;
    uint32_t layerWindowID = client.directDrawableLayerWindowID;
    BOOL resumeWindowBase = client.directDrawableBaseCaptureSuspended ||
        client.directDrawableBaseCaptureSuspensionPending;
    BOOL retirePacingLease = client.directDrawablePacingLeasePublished;
    client.directDrawableActive = NO;
    client.directDrawableDeadline = 0;
    client.directDrawableOwnerPID = 0;
    client.directDrawableLayerWindowID = 0;
    client.directDrawableWidth = 0;
    client.directDrawableHeight = 0;
    client.directDrawableBaseCaptureSuspended = NO;
    client.directDrawableBaseCaptureSuspensionPending = NO;
    client.directDrawablePacingLeasePublished = NO;
    if (retirePacingLease) RetireDirectDrawablePacingLease();
    NSUInteger resumed = 0;
    for (MacWSTransientLayer *layer in
            [client.transientLayers.allValues copy]) {
        BOOL ownedSuspension = layer.directDrawableCaptureSuspended ||
            layer.directDrawableCaptureSuspensionPending;
        if (!ownedSuspension) continue;
        layer.directDrawableCaptureSuspended = NO;
        layer.directDrawableCaptureSuspensionPending = NO;
        if ((!FinalCompositeIsLive() ||
             LayerNeedsIndependentFinalCompositeCapture(layer)) &&
            !layer.stream && !layer.retiring &&
            !(layer.oneShotCapture && layer.snapshotComplete &&
              layer.latestSurface)) {
            StartTransientLayer(layer);
            if (layer.stream) resumed++;
        }
    }
    if (resumeWindowBase && client.subscriptionActive &&
        !client.deliveryPaused && client.mode == MacWSStreamModeWindow &&
        client.windowID != 0 && !client.stream) {
        StartClientStream(client);
        if (client.stream) resumed++;
    }
    if (wasActive || resumed) {
        DisplayLog(@"direct-drawable-capture-cleared owner-pid=%d layer=%u "
                   "resumed=%lu reason=%@",
                   ownerPID, layerWindowID, (unsigned long)resumed,
                   reason ?: @"inactive");
    }
}

static void ScheduleDirectDrawableExpiry(MacWSDisplayClient *client) {
    if (!client || client.directDrawableExpiryPending) return;
    client.directDrawableExpiryPending = YES;
    __weak MacWSDisplayClient *weakClient = client;
    __block void (^checkExpiry)(void) = nil;
    checkExpiry = ^{
        MacWSDisplayClient *strongClient = weakClient;
        if (!strongClient) {
            checkExpiry = nil;
            return;
        }
        if (!strongClient.directDrawableActive) {
            strongClient.directDrawableExpiryPending = NO;
            checkExpiry = nil;
            return;
        }
        CFTimeInterval remaining = strongClient.directDrawableDeadline -
            CFAbsoluteTimeGetCurrent();
        if (remaining > 0) {
            uint64_t delayNS = (uint64_t)llround(
                MIN(remaining, MacWSDirectDrawableLeaseSeconds) *
                    (double)NSEC_PER_SEC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNS),
                           DisplayQueue, checkExpiry);
            return;
        }
        strongClient.directDrawableExpiryPending = NO;
        ClearDirectDrawableActivity(strongClient, @"heartbeat-timeout");
        checkExpiry = nil;
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)llround(
                                     MacWSDirectDrawableLeaseSeconds *
                                     (double)NSEC_PER_SEC)),
                   DisplayQueue, checkExpiry);
}

static void HandleDirectDrawableActivity(MacWSDisplayClient *client,
                                         xpc_object_t request) {
    uint64_t version = xpc_dictionary_get_uint64(
        request, MACWS_STREAM_KEY_PROTOCOL_VERSION);
    BOOL active = xpc_dictionary_get_bool(request,
                                           MACWS_STREAM_KEY_ACTIVE);
    if (version != MACWS_STREAM_VERSION || !active) {
        ClearDirectDrawableActivity(client,
            version == MACWS_STREAM_VERSION ? @"host-clear" :
                                               @"protocol-mismatch");
        return;
    }
    int64_t ownerValue = xpc_dictionary_get_int64(
        request, MACWS_STREAM_KEY_OWNER_PID);
    uint64_t layerValue = xpc_dictionary_get_uint64(
        request, MACWS_STREAM_KEY_LAYER_WINDOW_ID);
    uint64_t widthValue = xpc_dictionary_get_uint64(
        request, MACWS_STREAM_KEY_WIDTH);
    uint64_t heightValue = xpc_dictionary_get_uint64(
        request, MACWS_STREAM_KEY_HEIGHT);
    if (ownerValue <= 1 || ownerValue > INT32_MAX || layerValue == 0 ||
        layerValue > UINT32_MAX || widthValue == 0 ||
        widthValue > MACWS_STREAM_MAX_DIMENSION || heightValue == 0 ||
        heightValue > MACWS_STREAM_MAX_DIMENSION) return;
    NSString *rejectionReason = nil;
    BOOL windowBase = client.mode == MacWSStreamModeWindow;
    MacWSTransientLayer *layer = nil;
    BOOL validated = NO;
    if (windowBase) {
        validated = ValidateDirectDrawableWindowBase(
            client, (int32_t)ownerValue, (uint32_t)layerValue,
            (uint32_t)widthValue, (uint32_t)heightValue, &rejectionReason);
    } else {
        layer = ValidatedDirectDrawableLayer(
            client, (int32_t)ownerValue, (uint32_t)layerValue,
            (uint32_t)widthValue, (uint32_t)heightValue, &rejectionReason);
        validated = layer != nil;
    }
    if (!validated) {
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - client.directDrawableLastRejectionLogTime >= 1.0) {
            client.directDrawableLastRejectionLogTime = now;
            MacWSTransientLayer *candidate =
                client.transientLayers[@((uint32_t)layerValue)];
            CGRect destination = candidate
                ? candidate.destinationBounds : CGRectZero;
            DisplayLog(@"direct-drawable-activity-rejected reason=%@ "
                       "owner-pid=%lld layer=%llu size=%llux%llu "
                       "candidate-owner=%d retiring=%@ level=%ld "
                       "surface=%zux%zu destination=(%.0f,%.0f %.0fx%.0f)",
                       rejectionReason ?: @"unknown", (long long)ownerValue,
                       (unsigned long long)layerValue,
                       (unsigned long long)widthValue,
                       (unsigned long long)heightValue,
                       candidate ? candidate.ownerPID : 0,
                       candidate.retiring ? @"YES" : @"NO",
                       candidate ? (long)candidate.skyLightLayer : 0L,
                       candidate.latestSurface
                           ? IOSurfaceGetWidth(candidate.latestSurface) : 0,
                       candidate.latestSurface
                           ? IOSurfaceGetHeight(candidate.latestSurface) : 0,
                       destination.origin.x, destination.origin.y,
                       destination.size.width, destination.size.height);
        }
        return;
    }

    BOOL identityChanged = !client.directDrawableActive ||
        client.directDrawableOwnerPID != ownerValue ||
        client.directDrawableLayerWindowID != layerValue;
    client.directDrawableActive = YES;
    client.directDrawableDeadline = CFAbsoluteTimeGetCurrent() +
        MacWSDirectDrawableLeaseSeconds;
    client.directDrawableOwnerPID = (int32_t)ownerValue;
    client.directDrawableLayerWindowID = (uint32_t)layerValue;
    client.directDrawableWidth = (uint32_t)widthValue;
    client.directDrawableHeight = (uint32_t)heightValue;
    // Once the Host has authenticated an exact focused drawable, WindowServer
    // no longer needs to synthesize 120-Hz desktop completions for that same
    // pixel authority. This applies to window-mode Chromium as well as native
    // fullscreen games: runtime-confirmed by
    // macws-aquarium-1k-single-frame-fastpath-repeat-v37.json on iPad13,6,
    // where a validated window direct lease kept the producer at 117.91 fps
    // while WindowServer averaged 3.11% CPU. Removing the window lease raised
    // WindowServer to 38.08% in
    // macws-testufo-window-direct-no-duplicate-charging-serious-v1.json,
    // while producer cadence fell to 109.99 fps. The Host panel scheduler is
    // independent and remains at 120 Hz; this lease only returns the now-
    // redundant virtual desktop completion loop to its 100-ms idle cadence.
    PublishDirectDrawablePacingLease(
        client.directDrawableOwnerPID,
        client.directDrawableLayerWindowID,
        client.directDrawableWidth,
        client.directDrawableHeight);
    client.directDrawablePacingLeasePublished = YES;
    ScheduleDirectDrawableExpiry(client);
    if (identityChanged) {
        DisplayLog(@"direct-drawable-activity-validated owner-pid=%lld "
                   "layer=%llu size=%llux%llu mode=%@ timeout-ms=%.0f",
                   (long long)ownerValue, (unsigned long long)layerValue,
                   (unsigned long long)widthValue,
                   (unsigned long long)heightValue,
                   windowBase ? @"window-base" : @"fullscreen-layer",
                   MacWSDirectDrawableLeaseSeconds * 1000.0);
    }

    if (windowBase) {
        if (client.directDrawableBaseCaptureSuspended ||
            client.directDrawableBaseCaptureSuspensionPending) return;
        client.directDrawableBaseCaptureSuspensionPending = YES;
        __weak MacWSDisplayClient *weakWindowClient = client;
        EnqueueRetiredTransientStop(^{
            MacWSDisplayClient *strongClient = weakWindowClient;
            if (!strongClient) return;
            strongClient.directDrawableBaseCaptureSuspensionPending = NO;
            if (!strongClient.directDrawableActive ||
                !strongClient.subscriptionActive ||
                strongClient.deliveryPaused ||
                strongClient.mode != MacWSStreamModeWindow ||
                strongClient.windowID !=
                    strongClient.directDrawableLayerWindowID ||
                strongClient.catalogFrontmostWindowID !=
                    strongClient.directDrawableLayerWindowID ||
                strongClient.catalogFrontmostOwnerPID !=
                    strongClient.directDrawableOwnerPID ||
                strongClient.directDrawableDeadline <=
                    CFAbsoluteTimeGetCurrent()) return;
            uint64_t oldStreamID = strongClient.streamID;
            strongClient.directDrawableBaseCaptureSuspended = YES;
            if (strongClient.stream) {
                strongClient.streamID = NextStreamID++;
                if (strongClient.streamID == 0)
                    strongClient.streamID = NextStreamID++;
                [strongClient stopStream];
            }
            DisplayLog(@"direct-drawable-base-capture-suspended "
                       "owner-pid=%d window=%u old-stream=%llu "
                       "generation=%llu size=%ux%u",
                       strongClient.directDrawableOwnerPID,
                       strongClient.directDrawableLayerWindowID,
                       (unsigned long long)oldStreamID,
                       (unsigned long long)strongClient.streamID,
                       strongClient.directDrawableWidth,
                       strongClient.directDrawableHeight);
        });
        return;
    }
    if (layer.directDrawableCaptureSuspended ||
        layer.directDrawableCaptureSuspensionPending) return;

    layer.directDrawableCaptureSuspensionPending = YES;
    __weak MacWSTransientLayer *weakLayer = layer;
    __weak MacWSDisplayClient *weakClient = client;
    EnqueueRetiredTransientStop(^{
        MacWSTransientLayer *strongLayer = weakLayer;
        MacWSDisplayClient *strongClient = weakClient;
        if (!strongLayer) return;
        strongLayer.directDrawableCaptureSuspensionPending = NO;
        if (!strongClient || !strongClient.directDrawableActive ||
            strongLayer.client != strongClient || strongLayer.retiring ||
            strongClient.directDrawableOwnerPID != strongLayer.ownerPID ||
            strongClient.directDrawableLayerWindowID !=
                strongLayer.windowID ||
            strongClient.directDrawableDeadline <=
                CFAbsoluteTimeGetCurrent()) return;
        uint64_t oldStreamID = strongLayer.streamID;
        strongLayer.directDrawableCaptureSuspended = YES;
        if (strongLayer.stream) {
            strongLayer.streamID = NextStreamID++;
            if (strongLayer.streamID == 0)
                strongLayer.streamID = NextStreamID++;
            [strongLayer finishActiveFrameBurstWithReason:
                @"direct-drawable-authoritative"];
            [strongLayer stopCapturePreservingSurface];
        }
        DisplayLog(@"direct-drawable-capture-suspended owner-pid=%d "
                   "layer=%u old-stream=%llu generation=%llu size=%ux%u",
                   strongLayer.ownerPID, strongLayer.windowID,
                   (unsigned long long)oldStreamID,
                   (unsigned long long)strongLayer.streamID,
                   strongClient.directDrawableWidth,
                   strongClient.directDrawableHeight);
    });
}

static void SuspendFullscreenLayerCapturesForFinalComposite(void) {
    if (!FinalCompositeIsLive()) return;
    NSUInteger scheduled = 0;
    MacWSTransientLayer *focusedRenderAuthority = nil;
    size_t focusedRenderArea = 0;
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused ||
            client.mode != MacWSStreamModeFullscreen) continue;
        for (MacWSTransientLayer *layer in
                [client.transientLayers.allValues copy]) {
            if (LayerCanAuthorizeFocusedRender(layer)) {
                size_t width = IOSurfaceGetWidth(layer.latestSurface);
                size_t height = IOSurfaceGetHeight(layer.latestSurface);
                size_t area = width && height <= SIZE_MAX / width
                    ? width * height : 0;
                if (area > focusedRenderArea) {
                    focusedRenderAuthority = layer;
                    focusedRenderArea = area;
                }
            }
            if (!layer.stream || layer.retiring ||
                LayerNeedsIndependentFinalCompositeCapture(layer) ||
                layer.finalCompositeCaptureSuspensionPending ||
                layer.directDrawableCaptureSuspended ||
                layer.directDrawableCaptureSuspensionPending) continue;
            layer.finalCompositeCaptureSuspensionPending = YES;
            __weak MacWSTransientLayer *weakLayer = layer;
            __weak MacWSDisplayClient *weakClient = client;
            EnqueueRetiredTransientStop(^{
                MacWSTransientLayer *strongLayer = weakLayer;
                MacWSDisplayClient *strongClient = weakClient;
                if (!strongLayer) return;
                strongLayer.finalCompositeCaptureSuspensionPending = NO;
                if (!FinalCompositeIsLive() || !strongClient ||
                    strongLayer.client != strongClient ||
                    !strongClient.subscriptionActive ||
                    strongClient.deliveryPaused ||
                    strongClient.mode != MacWSStreamModeFullscreen ||
                    strongLayer.retiring || !strongLayer.stream ||
                    LayerNeedsIndependentFinalCompositeCapture(strongLayer))
                    return;
                uint64_t oldStreamID = strongLayer.streamID;
                // Invalidate the asynchronous terminal callback before
                // stopping the capture object. A later fallback restart owns
                // a fresh generation and cannot be overwritten by this one.
                strongLayer.streamID = NextStreamID++;
                if (strongLayer.streamID == 0)
                    strongLayer.streamID = NextStreamID++;
                [strongLayer finishActiveFrameBurstWithReason:
                    @"final-composite-authoritative"];
                [strongLayer stopCapturePreservingSurface];
                DisplayLog(@"layer-capture-suspended layer=%u old-stream=%llu "
                           "generation=%llu reason=final-composite-authoritative",
                           strongLayer.windowID,
                           (unsigned long long)oldStreamID,
                           (unsigned long long)strongLayer.streamID);
            });
            scheduled++;
        }
    }
    // This is the catalog/SkyLight authority which lets a matching foreground
    // process ask WindowServer for an active completion cadence. It does not
    // itself raise the cadence: without a fresh, window-sized Metal present,
    // the compositor remains at the 100-ms idle pace.
    BOOL publishedAuthority =
        PublishFocusedRenderAuthority(focusedRenderAuthority);
    if (!publishedAuthority)
        publishedAuthority =
            PublishFocusedWindowClientAuthorityIfAvailable();
    if (!publishedAuthority) RetireFocusedRenderAuthority();
    if (scheduled) {
        DisplayLog(@"layer-capture-suspend-batch count=%lu interval-ms=16 "
                   "reason=final-composite-authoritative",
                   (unsigned long)scheduled);
    }
}

static void ResumeFullscreenLayerCapturesForFallback(void) {
    if (FinalCompositeIsLive()) return;
    NSUInteger resumed = 0;
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused ||
            client.mode != MacWSStreamModeFullscreen) continue;
        for (MacWSTransientLayer *layer in
                [client.transientLayers.allValues copy]) {
            layer.finalCompositeCaptureSuspensionPending = NO;
            if (layer.stream || layer.retiring ||
                layer.directDrawableCaptureSuspended ||
                layer.directDrawableCaptureSuspensionPending ||
                (layer.oneShotCapture && layer.snapshotComplete &&
                 layer.latestSurface)) continue;
            StartTransientLayer(layer);
            if (layer.stream) resumed++;
        }
    }
    if (resumed) {
        DisplayLog(@"layer-capture-resume-batch count=%lu "
                   "reason=final-composite-fallback",
                   (unsigned long)resumed);
    }
}

static void StartClientStream(MacWSDisplayClient *client) {
    [client stopStream];
    client.streamID = NextStreamID++;
    if (client.streamID == 0) client.streamID = NextStreamID++;
    client.droppedFrames = 0;
    client.firstDisplayTime = 0;
    if (client.mode == MacWSStreamModeFullscreen) {
        client.workspaceCanvas = CreateWorkspaceCanvas(client);
        if (!client.workspaceCanvas) {
            SendStatus(client, MACWS_STREAM_EVENT_ERROR,
                       @"无法创建 Retina 桌面 IOSurface 画布", NO);
            return;
        }
        BOOL hasLiveFinalComposite = FinalCompositeIsLive();
        IOSurfaceRef base = hasLiveFinalComposite
            ? FinalCompositeSurface : client.workspaceCanvas;
        uint64_t baseTime = hasLiveFinalComposite
            ? FinalCompositeRecord.completionTime : mach_absolute_time();
        PublishFrame(client, nil, baseTime, base);
        DisplayLog(@"workspace-start id=%llu display=%zux%zu scale=%.3f transport=%@",
                   (unsigned long long)client.streamID,
                   IOSurfaceGetWidth(base), IOSurfaceGetHeight(base),
                   client.windowBackingScale,
                   hasLiveFinalComposite
                       ? @"final-composite-iosurface"
                       : @"window-iosurface-composite");
        return;
    }
    client.stream = CreateStream(client);
    if (!client.stream) {
        SendStatus(client, MACWS_STREAM_EVENT_ERROR,
            client.mode == MacWSStreamModeWindow
                ? @"无法创建 SkyLight window DisplayStream"
                : @"无法创建 fullscreen CGDisplayStream", NO);
        return;
    }
    CGError error = CGDisplayStreamStart(client.stream);
    if (error != kCGErrorSuccess) {
        NSString *message = [NSString stringWithFormat:
            @"CGDisplayStreamStart failed: %d", error];
        [client stopStream];
        SendStatus(client, MACWS_STREAM_EVENT_ERROR, message, NO);
        return;
    }
    DisplayLog(@"stream-start id=%llu mode=%u window=%u exact=%s",
        (unsigned long long)client.streamID, client.mode, client.windowID,
        client.mode == MacWSStreamModeWindow ? "YES" : "NO");
}

// SLSHWCaptureStreamCreateWithWindow fixes its output shape when the stream is
// created. Runtime evidence on VSCode window 512 was unambiguous: AppKit
// accepted 934x592 -> 785x592, while stream 255 continued publishing a
// 1868x1184 IOSurface, producing portrait black bars and a stale input map.
// Recreate exact-window streams after the final geometry invalidation. The
// serial is a debounce boundary for live Stage Manager resizing; no frame-time
// polling or aspect stretching is involved.
static void ScheduleGeometryStreamRestart(void) {
    uint64_t serial = atomic_fetch_add_explicit(
        &GeometryRestartSerial, 1, memory_order_relaxed) + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   DisplayQueue, ^{
        if (serial != atomic_load_explicit(
                &GeometryRestartSerial, memory_order_relaxed)) return;
        for (MacWSDisplayClient *client in [Clients copy]) {
            if (client.mode != MacWSStreamModeWindow || client.windowID == 0)
                continue;
            uint32_t expectedWidth = 0, expectedHeight = 0;
            NSValue *targetValue = nil;
            @synchronized (GeometryTargets) {
                targetValue = GeometryTargets[@(client.windowID)];
                if (targetValue)
                    [GeometryTargets removeObjectForKey:@(client.windowID)];
            }
            if (targetValue) {
                MacWSGeometryInvalidation target = {0};
                [targetValue getValue:&target];
                expectedWidth = target.pixelWidth;
                expectedHeight = target.pixelHeight;
            } else {
                CGRect bounds = CGRectZero;
                CGFloat scale = client.windowBackingScale > 0.0
                    ? client.windowBackingScale : MainDisplayBackingScale();
                if (CopyWindowBounds(client.windowID, &bounds) && scale > 0.0) {
                    expectedWidth = (uint32_t)llround(
                        bounds.size.width * scale);
                    expectedHeight = (uint32_t)llround(
                        bounds.size.height * scale);
                }
            }
            // A stale Scene subscription can briefly outlive its CGWindow.
            // With no committed target and no catalog bounds there is no
            // geometry invariant to restore, so leave it alone rather than
            // blindly restarting an already-orphaned capture stream.
            if (expectedWidth == 0 || expectedHeight == 0) continue;
            if (client.lastSurfaceWidth == expectedWidth &&
                client.lastSurfaceHeight == expectedHeight) {
                continue;
            }
            DisplayLog(@"geometry-stream-restart window=%u old-stream=%llu current=%zux%zu expected=%ux%u phase=stop",
                       client.windowID,
                       (unsigned long long)client.streamID,
                       client.lastSurfaceWidth, client.lastSurfaceHeight,
                       expectedWidth, expectedHeight);
            uint64_t restartGeneration = ++client.geometryRestartGeneration;
            uint32_t restartWindowID = client.windowID;
            client.windowBackingScale = 0.0;
            [client stopTransientLayers];
            [client stopStream];
            // Runtime-confirmed on Maps/System Settings: recreating in the
            // same display-queue turn eventually made
            // SLSHWCaptureStreamCreateWithWindow return NULL for every Scene;
            // reloading displayd immediately restored creation.  Leave one
            // bounded release interval for SkyLight to retire the old graph.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           DisplayQueue, ^{
                if (![Clients containsObject:client] ||
                    !client.subscriptionActive ||
                    client.mode != MacWSStreamModeWindow ||
                    client.windowID != restartWindowID ||
                    client.geometryRestartGeneration != restartGeneration)
                    return;
                DisplayLog(@"geometry-stream-restart window=%u generation=%llu phase=create",
                           client.windowID,
                           (unsigned long long)restartGeneration);
                StartClientStream(client);
                ScheduleTransientReconcile(0);
            });
        }
        ScheduleTransientReconcile(0);
    });
}

static void StartSubscription(MacWSDisplayClient *client,
                              MacWSStreamMode mode, uint32_t windowID) {
    client.geometryRestartGeneration++;
    if (mode == MacWSStreamModeFullscreen) {
        if (client.subscriptionActive &&
            client.mode == MacWSStreamModeFullscreen &&
            (client.workspaceCanvas || client.transientLayers.count != 0)) {
            // UIKit can briefly resign/reactivate the same fullscreen Scene
            // during app launch and system fullscreen transactions. Resume
            // this client's retained graph instead of treating the identical
            // subscription as a request to allocate a second desktop graph.
            client.deliveryPaused = NO;
            client.disconnectGeneration++;
            DisplayLog(@"workspace-resume stream=%llu layers=%lu transport=retained-graph",
                       (unsigned long long)client.streamID,
                       (unsigned long)client.transientLayers.count);
            BOOL hasLiveFinalComposite = FinalCompositeIsLive();
            IOSurfaceRef retainedBase = hasLiveFinalComposite
                ? FinalCompositeSurface : client.workspaceCanvas;
            if (retainedBase)
                PublishFrame(client, nil,
                    hasLiveFinalComposite
                        ? FinalCompositeRecord.completionTime
                        : mach_absolute_time(), retainedBase);
            for (MacWSTransientLayer *layer in
                    client.transientLayers.allValues) {
                if (layer.latestSurface)
                    PublishFrame(client, layer,
                        layer.latestDisplayTime ?: mach_absolute_time(),
                        layer.latestSurface);
            }
            ScheduleTransientReconcile(0);
            return;
        }
        // Runtime-confirmed on 2026-08-03: a stale fullscreen client kept
        // stream 10 and its desktop layers alive while the foreground Scene
        // created workspace stream 55.  The duplicated Retina capture graphs
        // were immediately followed by WindowServer AGX command-buffer error
        // 00000103 and a producer restart.  Fullscreen is one shared physical
        // macOS desktop, so transfer its producer ownership atomically to the
        // newest foreground subscriber instead of cloning the graph.
        MacWSDisplayClient *owner = nil;
        for (MacWSDisplayClient *candidate in [Clients copy]) {
            if (candidate != client && candidate.subscriptionActive &&
                candidate.mode == MacWSStreamModeFullscreen) {
                owner = candidate;
                break;
            }
        }
        if (owner) {
            ClearDirectDrawableActivity(owner, @"workspace-handoff");
            BOOL ownerDisconnected = owner.connection == nil;
            owner.disconnectGeneration++;
            // Stop only this client's former exact-window graph.  The desktop
            // graph remains running and its layer callbacks dynamically read
            // layer.client, so moving the layer objects changes the XPC sink
            // without overlapping CGDisplayStreamStop/Create operations.
            [client stopTransientLayers];
            [client stopStream];
            client.outstandingByLayer = [NSMutableDictionary dictionary];
            client.frameAcknowledged = NO;
            client.subscriptionActive = YES;
            client.deliveryPaused = NO;
            client.mode = MacWSStreamModeFullscreen;
            client.windowID = 0;
            client.streamID = owner.streamID;
            client.sequence = owner.sequence;
            client.droppedFrames = owner.droppedFrames;
            client.firstDisplayTime = owner.firstDisplayTime;
            client.windowBackingScale = owner.windowBackingScale;
            client.lastSurfaceWidth = owner.lastSurfaceWidth;
            client.lastSurfaceHeight = owner.lastSurfaceHeight;
            client.workspaceCanvas = owner.workspaceCanvas;
            owner.workspaceCanvas = NULL;
            client.transientLayers = owner.transientLayers ?:
                [NSMutableDictionary dictionary];
            owner.transientLayers = [NSMutableDictionary dictionary];
            for (MacWSTransientLayer *layer in
                    client.transientLayers.allValues) {
                layer.client = client;
            }

            owner.subscriptionActive = NO;
            owner.deliveryPaused = NO;
            owner.mode = 0;
            owner.windowID = 0;
            owner.streamID = 0;
            owner.sequence = 0;
            owner.firstDisplayTime = 0;
            owner.droppedFrames = 0;
            owner.windowBackingScale = 0;
            owner.lastSurfaceWidth = 0;
            owner.lastSurfaceHeight = 0;

            DisplayLog(@"workspace-handoff stream=%llu layers=%lu new-client=%p transport=live-graph-transfer",
                       (unsigned long long)client.streamID,
                       (unsigned long)client.transientLayers.count, client);
            // Republish the retained current generation before waiting for a
            // future damage callback; static wallpaper/menu layers may not
            // otherwise emit another frame for the new Scene.
            BOOL hasLiveFinalComposite = FinalCompositeIsLive();
            IOSurfaceRef retainedBase = hasLiveFinalComposite
                ? FinalCompositeSurface : client.workspaceCanvas;
            if (retainedBase) {
                PublishFrame(client, nil,
                    hasLiveFinalComposite
                        ? FinalCompositeRecord.completionTime
                        : mach_absolute_time(), retainedBase);
            }
            NSArray<MacWSTransientLayer *> *layers =
                [client.transientLayers.allValues
                    sortedArrayUsingComparator:^NSComparisonResult(
                        MacWSTransientLayer *left,
                        MacWSTransientLayer *right) {
                    if (left.level < right.level) return NSOrderedAscending;
                    if (left.level > right.level) return NSOrderedDescending;
                    if (left.windowID < right.windowID)
                        return NSOrderedAscending;
                    if (left.windowID > right.windowID)
                        return NSOrderedDescending;
                    return NSOrderedSame;
                }];
            for (MacWSTransientLayer *layer in layers) {
                if (layer.latestSurface) {
                    PublishFrame(client, layer,
                        layer.latestDisplayTime ?: mach_absolute_time(),
                        layer.latestSurface);
                }
            }
            SendStatus(owner, MACWS_STREAM_EVENT_STOPPED,
                       @"全屏工作区已转移到当前前台窗口", YES);
            // A disconnected owner was retained solely as a short handoff
            // carrier. Its graph and retained surfaces now belong to the new
            // client, and its outstanding leases were cleared at disconnect,
            // so removing the empty shell performs no CGDisplayStream stop.
            if (ownerDisconnected) [Clients removeObject:owner];
            ScheduleTransientReconcile(0);
            return;
        }
    }
    // The generic path replaces the client's entire capture graph below. Do
    // not carry a direct-drawable lease or an owned suspension across that
    // generation: an old asynchronous expiry could otherwise restart/retire
    // resources belonging to the new subscription. We intentionally do not
    // resume the old exact stream here because StartClientStream creates the
    // replacement after the mode/window identity is committed.
    if (client.directDrawablePacingLeasePublished)
        RetireDirectDrawablePacingLease();
    client.directDrawableActive = NO;
    client.directDrawableDeadline = 0;
    client.directDrawableOwnerPID = 0;
    client.directDrawableLayerWindowID = 0;
    client.directDrawableWidth = 0;
    client.directDrawableHeight = 0;
    client.subscriptionActive = YES;
    client.deliveryPaused = NO;
    client.frameAcknowledged = NO;
    client.mode = mode;
    client.windowID = mode == MacWSStreamModeWindow ? windowID : 0;
    client.catalogFrontmostOwnerPID = 0;
    client.catalogFrontmostWindowID = 0;
    client.directDrawableBaseCaptureSuspended = NO;
    client.directDrawableBaseCaptureSuspensionPending = NO;
    client.directDrawablePacingLeasePublished = NO;
    client.windowBackingScale = 0.0;
    [client stopTransientLayers];
    StartClientStream(client);
    ScheduleTransientReconcile(0);
}

// Menus, popovers and sheets are real nonzero-layer SkyLight windows. Runtime
// evidence on the target iPad shows their exact window capture streams produce
// Retina IOSurfaces, while the full-display CGDisplayStream produces no first
// frame under WindowServer -virtualonly. Keep the base stream permanently
// exact and attach each same-owner transient as an independent native layer.
// Host composites the layers with Metal; no RFB, CPU copy, or stream-mode
// restart is involved.
static void ConfigureNativePopupComposite(MacWSTransientLayer *layer,
        MacWSDisplayClient *client, NSArray<NSDictionary *> *windows,
        CGRect baseBounds, CGRect popupBounds) {
    BOOL wasEligible = layer.popupCompositeEligible;
    layer.popupCompositeEligible = NO;
    // A popup is globally frontmost while tracking. Use completed compositor
    // pixels only for the part painted over this exact base and no window ABOVE THE
    // POPUP occupies its rectangle. The Dock has a full-display transparent
    // backing at level 20 (runtime window 21); testing until the level-zero
    // base mistakes that backing for an occluder of a level-101 menu.
    // Never screen-crop ordinary
    // or occluded app windows: their isolated streams remain authoritative.
    if (layer.skyLightLayer != CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey) ||
        !CGRectIntersectsRect(baseBounds, popupBounds)) return;
    CGRect desktop = CGDisplayBounds(CGMainDisplayID());
    CGRect paintBounds = CGRectIntersection(CGRectIntersection(
        CGRectInset(popupBounds, -20.0, -20.0), baseBounds), desktop);
    if (CGRectIsNull(paintBounds) || CGRectIsEmpty(paintBounds)) return;
    BOOL reachedPopup = NO;
    for (NSDictionary *info in windows) {
        uint32_t number = [info[(id)kCGWindowNumber] unsignedIntValue];
        if (number == layer.windowID) { reachedPopup = YES; break; }
        if ([info[(id)kCGWindowAlpha] doubleValue] <= 0.01 ||
            [info[(id)kCGWindowLayer] integerValue] >=
                CGWindowLevelForKey(kCGCursorWindowLevelKey)) continue;
        // A same-owner submenu is already part of this completed native
        // image. It will be painted at its own z-order too, using the same
        // opaque pixels; do not flatten the parent material when it opens.
        if ([info[(id)kCGWindowOwnerPID] intValue] == layer.ownerPID &&
            [info[(id)kCGWindowLayer] integerValue] ==
                CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey) &&
            client.transientLayers[@(number)]) continue;
        CGRect other = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &other) ||
            CGRectIntersectsRect(other, paintBounds)) return;
    }
    if (!reachedPopup || !CGRectContainsRect(desktop, popupBounds) ||
        !FinalCompositeSurface || CGRectIsEmpty(desktop)) return;
    CGFloat sx = FinalCompositeRecord.width / desktop.size.width;
    CGFloat sy = FinalCompositeRecord.height / desktop.size.height;
    if (!isfinite(sx) || !isfinite(sy) || sx <= 0 || fabs(sx - sy) > 0.01) return;
    CGRect source = CGRectMake(
        round((popupBounds.origin.x - desktop.origin.x) * sx),
        round((popupBounds.origin.y - desktop.origin.y) * sy),
        round(popupBounds.size.width * sx), round(popupBounds.size.height * sy));
    if (CGRectIsEmpty(source) ||
        !CGRectContainsRect(CGRectMake(0, 0, FinalCompositeRecord.width,
            FinalCompositeRecord.height), source)) return;
    if (!wasEligible || !CGRectEqualToRect(source, layer.popupCompositeSource)) {
        layer.popupCompositeMinimumTime = mach_absolute_time();
        layer.popupCompositeSource = source;
        layer.lastPopupCompositeSequence = 0;
        layer.popupCompositeReported = NO;
        // Require a completed frame newer than this geometry observation.
        // The normal producer/replay path owns freshness and use-count leases;
        // no TCC result, WindowServer check or GPU completion is fabricated.
        MacWSRequestFinalCompositeReplay(layer.popupCompositeMinimumTime);
    }
    layer.popupCompositeEligible = YES;
}

static void ReconcileTransientStreams(void) {
    TransientReconcilePending = NO;
    BOOL urgentRetireConfirmation = UrgentTransientRetirePasses > 0;
    if (UrgentTransientRetirePasses > 0) UrgentTransientRetirePasses--;
    // Fullscreen owns an exclusive desktop capture graph and does not need
    // the application-only catalog.  Keeping this eager performed two full
    // CGWindow snapshots on every 60-Hz native gesture sample; load the second
    // list only if a window-mode client actually exists.
    NSArray<NSDictionary *> *windowInfo = nil;
    NSArray<NSDictionary *> *desktopInfo = nil;
    BOOL needsFollowup = NO;
    BOOL windowMissingLayerNeedsConfirmation = NO;
    BOOL workspaceNeedsFollowup = NO;
    BOOL workspaceMissingLayerNeedsConfirmation = NO;
    BOOL urgentPopupPresent = NO;
    BOOL workspacePresentationChanged = NO;
    BOOL workspaceTopologyChanged = NO;
    for (MacWSDisplayClient *client in [Clients copy]) {
        if (!client.subscriptionActive || client.deliveryPaused) continue;
        if (client.mode == MacWSStreamModeFullscreen) {
            if (!desktopInfo) desktopInfo = CopyCompleteDesktopWindowInfo();
            CGRect desktopBounds = CGDisplayBounds(CGMainDisplayID());
            CGFloat scale = client.windowBackingScale > 0.0
                ? client.windowBackingScale : MainDisplayBackingScale();
            if (CGRectIsEmpty(desktopBounds) || !isfinite(scale) ||
                scale < 0.5 || scale > 8.0) continue;
            if (!client.transientLayers)
                client.transientLayers = [NSMutableDictionary dictionary];
            NSMutableData *geometryBatch = [NSMutableData dataWithCapacity:
                MIN(client.transientLayers.count, (NSUInteger)
                    MACWS_STREAM_MAX_LAYER_GEOMETRY) *
                    sizeof(MacWSStreamLayerGeometry)];
            uint64_t geometryDisplayTime = mach_absolute_time();
            NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
            NSMutableDictionary<NSNumber *, NSDictionary<NSNumber *, NSData *> *>
                *metricsByPID = [NSMutableDictionary dictionary];
            NSUInteger attached = 0;
            NSUInteger count = desktopInfo.count;
            // The frontmost full-display negative-level window is Finder's
            // interactive desktop on the target runtime and must remain live
            // for icon selection. Lower negative layers are compositor
            // backing/wallpaper: capture one authoritative frame, then retain
            // it without keeping several redundant Retina streams active.
            uint32_t frontmostInteractiveDesktopWindowID = 0;
            for (NSDictionary *candidate in desktopInfo) {
                NSInteger candidateLevel =
                    [candidate[(id)kCGWindowLayer] integerValue];
                CGRect candidateBounds = CGRectZero;
                if (candidateLevel >= 0 ||
                    !CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)
                            candidate[(id)kCGWindowBounds],
                        &candidateBounds) ||
                    !CGRectContainsRect(candidateBounds, desktopBounds))
                    continue;
                frontmostInteractiveDesktopWindowID =
                    [candidate[(id)kCGWindowNumber] unsignedIntValue];
                if (frontmostInteractiveDesktopWindowID != 0) break;
            }
            for (NSUInteger index = 0; index < count; index++) {
                NSDictionary *info = desktopInfo[index];
                uint32_t candidateWindowID =
                    [info[(id)kCGWindowNumber] unsignedIntValue];
                NSInteger candidateSkyLightLayer =
                    [info[(id)kCGWindowLayer] integerValue];
                // runtime-confirmed on iPad13,6 on 2026-08-12: WindowServer
                // publishes its black 34x46 `Cursor` as window 3 at
                // SkyLight layer 2147483630. Host already renders its own
                // direct-touch/trackpad/Pencil affordance, so composing that
                // hardware cursor creates a duplicate visual pointer. Cursor-
                // level surfaces are presentation-only and never belong in
                // the macOS desktop layer graph consumed by Host.
                if (candidateSkyLightLayer >=
                    CGWindowLevelForKey(kCGCursorWindowLevelKey)) continue;
                if (attached >= 48 || candidateWindowID == 0 ||
                    [info[(id)kCGWindowAlpha] doubleValue] <= 0.01) continue;
                CGRect candidateBounds = CGRectZero;
                if (!CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                        &candidateBounds) || CGRectIsEmpty(candidateBounds) ||
                    !CGRectIntersectsRect(desktopBounds, candidateBounds))
                    continue;
                NSNumber *key = @(candidateWindowID);
                // A compositor layer is identified by its CGWindow ID.  Even
                // if SkyLight momentarily exposes the same ID more than once
                // while rebuilding the desktop list, it must still own only
                // one capture stream in this reconciliation transaction.
                if ([seen containsObject:key]) continue;
                [seen addObject:key];
                attached++;
                MacWSTransientLayer *layer = client.transientLayers[key];
                BOOL isNew = layer == nil;
                if (isNew) {
                    layer = [MacWSTransientLayer new];
                    layer.client = client;
                    layer.windowID = candidateWindowID;
                    client.transientLayers[key] = layer;
                }
                BOOL returnedFromCatalog = layer.retiring;
                if (returnedFromCatalog) {
                    layer.retiring = NO;
                    layer.retirementGeneration++;
                    [RetiredTransientLayers removeObject:layer];
                    DisplayLog(@"layer-retire-cancel layer=%u reason=window-returned",
                               layer.windowID);
                }
                layer.client = client;
                layer.ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
                id ownerName = info[(id)kCGWindowOwnerName];
                layer.ownerName = [ownerName isKindOfClass:NSString.class]
                    ? ownerName : @"";
                id windowName = info[(id)kCGWindowName];
                layer.windowName = [windowName isKindOfClass:NSString.class]
                    ? windowName : @"";
                layer.skyLightLayer = candidateSkyLightLayer;
                NSNumber *ownerPIDKey = @(layer.ownerPID);
                NSDictionary<NSNumber *, NSData *> *processMetrics =
                    metricsByPID[ownerPIDKey];
                if (!processMetrics) {
                    processMetrics = CopyWindowMetrics(layer.ownerPID);
                    metricsByPID[ownerPIDKey] = processMetrics;
                }
                MacWSWindowMetricsEntry windowMetrics = {0};
                NSData *windowMetricsValue =
                    processMetrics[@(candidateWindowID)];
                if (windowMetricsValue)
                    [windowMetricsValue getBytes:&windowMetrics length:sizeof(windowMetrics)];
                layer.windowFlags = windowMetrics.flags &
                    (MacWSStreamWindowVisible |
                     MacWSStreamWindowFocused |
                     MacWSStreamWindowFullscreenCanvas);
                if ([info[(id)kCGWindowIsOnscreen] boolValue])
                    layer.windowFlags |= MacWSStreamWindowOnScreen;
                if (urgentRetireConfirmation &&
                    layer.skyLightLayer >=
                        CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey) &&
                    layer.skyLightLayer <
                        CGWindowLevelForKey(kCGCursorWindowLevelKey))
                    urgentPopupPresent = YES;
                BOOL desiredOneShot = layer.skyLightLayer < 0 &&
                    CGRectContainsRect(candidateBounds, desktopBounds) &&
                    candidateWindowID != frontmostInteractiveDesktopWindowID;
                // Bind capture lifetime to the window identity that created
                // it, not to a later catalog rank.  During cold desktop
                // bootstrap the WindowServer backing, Dock wallpaper and
                // Finder desktop appear in separate snapshots; the previous
                // code reclassified the old full-screen layer each time a
                // more-front negative layer arrived, synchronously stopping
                // and recreating the same CGWindow stream.  Runtime logs on
                // 2026-08-06 prove window 2 was restarted as streams 3 -> 5
                // and window 4 as streams 4 -> 13 during one cold recovery.
                // Separately, launchd records the preceding WindowServer's
                // last exit as OS_REASON_COREANIMATION; the duplicate starts
                // are not claimed as that abort's cause, but they directly
                // violate the one-window/one-stream invariant. A window's
                // immutable first-seen policy restores that invariant.
                // Retirement and a genuinely new ID still create a fresh
                // policy.
                if (isNew) layer.oneShotCapture = desiredOneShot;
                // CGWindowList is front-to-back, but its cross-level order is
                // not authoritative on this chroot.  Runtime evidence from
                // Stray listed its opaque-black SkyLight -1 backing ahead of
                // the visible level-0 game window; using catalog rank alone
                // consequently painted the backing over the game in Host.
                // Preserve catalog rank within each semantic level class,
                // while enforcing SkyLight's structural invariant that all
                // negative layers are behind ordinary windows and all
                // positive system/menu layers are in front.  The fixed bands
                // leave ample room for the bounded desktop catalog rank and
                // avoid arithmetic on the private INT32_MIN-adjacent desktop
                // levels.
                int32_t catalogRank = (int32_t)MIN(
                    count - index, (NSUInteger)(INT32_MAX / 8));
                static const int32_t kMacWSNegativeLayerBand =
                    -(INT32_MAX / 2);
                static const int32_t kMacWSPositiveLayerBand =
                    INT32_MAX / 2;
                int32_t newLevel = candidateSkyLightLayer < 0
                    ? kMacWSNegativeLayerBand + catalogRank
                    : (candidateSkyLightLayer > 0
                        ? kMacWSPositiveLayerBand + catalogRank
                        : catalogRank);
                BOOL usedSurfaceMeasurement = NO;
                CGFloat presentationScale = LayerPresentationScale(
                    candidateBounds, layer.latestSurface, scale,
                    &usedSurfaceMeasurement);
                if (usedSurfaceMeasurement &&
                    fabs(presentationScale - scale) > 0.08 &&
                    !layer.reportedPresentationScaleNormalization) {
                    layer.reportedPresentationScaleNormalization = YES;
                    DisplayLog(@"runtime-confirmed presentation-scale-normalized "
                               "layer=%u owner-pid=%d bounds=%.0fx%.0f "
                               "surface=%zux%zu display-scale=%.3f "
                               "presentation-scale=%.3f",
                               layer.windowID, layer.ownerPID,
                               candidateBounds.size.width,
                               candidateBounds.size.height,
                               IOSurfaceGetWidth(layer.latestSurface),
                               IOSurfaceGetHeight(layer.latestSurface), scale,
                               presentationScale);
                }
                CGRect newDestination = MacWSWorkspaceLayerDestination(
                    client, layer, candidateBounds, desktopBounds,
                    presentationScale, usedSurfaceMeasurement);
                BOOL presentationChanged = !isNew &&
                    (layer.level != newLevel ||
                     !CGRectEqualToRect(layer.destinationBounds,
                                        newDestination));
                layer.level = newLevel;
                layer.destinationBounds = newDestination;
                layer.missCount = 0;
                workspacePresentationChanged |=
                    isNew || presentationChanged || returnedFromCatalog;
                workspaceTopologyChanged |= isNew || returnedFromCatalog;
                if ((!FinalCompositeIsLive() ||
                     LayerNeedsIndependentFinalCompositeCapture(layer)) &&
                    (isNew ||
                     (!layer.stream &&
                      !(layer.oneShotCapture &&
                        layer.snapshotComplete)))) {
                    StartTransientLayer(layer);
                }
                // Window movement does not necessarily damage its backing
                // store. Send an ordered geometry record while retaining the
                // already-imported IOSurface; waiting for a future capture
                // callback made title-bar dragging update at the 250ms
                // catalog-poll cadence, while republishing the surface made
                // every moving layer acquire another Mach port and lease.
                // SendLayerRemoved detached this layer from Host as soon as
                // the native overview/Space catalog hid it. If Dock restores
                // the window to exactly its old z-order and bounds, an exact
                // CGDisplayStream has no content damage to report and
                // presentationChanged is false. Re-publish the retained real
                // IOSurface on catalog return or the window remains invisible
                // even though it never closed.
                if (returnedFromCatalog && layer.latestSurface) {
                    PublishFrame(client, layer, mach_absolute_time(),
                                 layer.latestSurface);
                } else if (presentationChanged && layer.latestSurface) {
                    AppendLayerGeometry(geometryBatch, client, layer,
                                        geometryDisplayTime);
                }
            }
            SendLayerGeometryBatch(client, geometryBatch);
            for (NSNumber *key in [client.transientLayers.allKeys copy]) {
                MacWSTransientLayer *layer = client.transientLayers[key];
                if ([seen containsObject:key]) continue;
                if (layer.retiring) continue;
                layer.missCount++;
                if (layer.missCount < 2) {
                    // A native popup can disappear between two AppKit
                    // catalog notifications. Confirm the first miss on the
                    // next display interval instead of waiting for the 1 s
                    // idle recovery poll; otherwise the already-closed menu
                    // remains visibly composited as a translucent ghost.
                    // Two independent CGWindow snapshots remain required, so
                    // a one-sample catalog transition cannot detach a live
                    // window.
                    workspaceMissingLayerNeedsConfirmation = YES;
                    continue;
                }
                DisplayLog(@"workspace-layer-remove layer=%u stream=%llu through=%llu",
                           layer.windowID,
                           (unsigned long long)layer.streamID,
                           (unsigned long long)layer.sequence);
                SendLayerRemoved(client, layer);
                RetireTransientLayer(client, key, layer,
                                     @"workspace-catalog-removed");
                workspacePresentationChanged = YES;
                workspaceTopologyChanged = YES;
            }
            workspaceNeedsFollowup |= client.transientLayers.count != 0;
            UpdateWorkspaceGraphState(client, @"fullscreen-reconcile");
            continue;
        }
        if (client.mode != MacWSStreamModeWindow || client.windowID == 0)
            continue;
        if (!windowInfo) windowInfo = CopyOnScreenWindowInfo();
        NSDictionary *baseInfo = nil;
        for (NSDictionary *info in windowInfo) {
            if ([info[(id)kCGWindowNumber] unsignedIntValue] ==
                client.windowID) {
                baseInfo = info;
                break;
            }
        }
        CGRect baseBounds = CGRectZero;
        if (!baseInfo || !CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)baseInfo[(id)kCGWindowBounds],
                &baseBounds) || CGRectIsEmpty(baseBounds)) continue;
        int32_t ownerPID = [baseInfo[(id)kCGWindowOwnerPID] intValue];
        NSDictionary<NSNumber *, NSData *> *processMetrics =
            CopyWindowMetrics(ownerPID);
        MacWSWindowMetricsEntry baseMetrics = {0};
        NSData *baseMetricsValue = processMetrics[@(client.windowID)];
        if (baseMetricsValue) [baseMetricsValue getBytes:&baseMetrics length:sizeof(baseMetrics)];
        CGFloat scale = client.windowBackingScale > 0.0
            ? client.windowBackingScale : MainDisplayBackingScale();
        if (!isfinite(scale) || scale < 0.5 || scale > 8.0) continue;

        if (!client.transientLayers)
            client.transientLayers = [NSMutableDictionary dictionary];
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        NSUInteger attached = 0;
        for (NSDictionary *info in windowInfo) {
            uint32_t candidateWindowID =
                [info[(id)kCGWindowNumber] unsignedIntValue];
            NSInteger level = [info[(id)kCGWindowLayer] integerValue];
            MacWSWindowMetricsEntry candidateMetrics = {0};
            NSData *candidateMetricsValue =
                processMetrics[@(candidateWindowID)];
            if (candidateMetricsValue)
                [candidateMetricsValue getBytes:&candidateMetrics length:sizeof(candidateMetrics)];
            BOOL logicalTransient = level == 0 &&
                (candidateMetrics.flags & MacWSStreamWindowTransient) != 0 &&
                baseMetrics.logicalGroupID != 0 &&
                candidateMetrics.logicalGroupID == baseMetrics.logicalGroupID;
            if (attached >= 8 || candidateWindowID == 0 ||
                candidateWindowID == client.windowID ||
                // The Host paints the subscribed base first and then its
                // related overlays.  A negative SkyLight level is behind the
                // base by definition and cannot be represented by that
                // overlay graph.  Capturing it here reverses z-order: Stray
                // runtime-confirmed this with window 2347 (level 0, complete
                // calibration pixels) and its full-size window 2350 (level
                // -1, opaque black), where 2350 covered 2347 in Host even
                // though screencapture correctly placed it behind.  Level-0
                // AppKit sheets remain eligible only through their published
                // logical-group relationship; positive menu/popup layers
                // remain ordinary overlays.
                (level <= 0 && !logicalTransient) ||
                [info[(id)kCGWindowOwnerPID] intValue] != ownerPID ||
                [info[(id)kCGWindowAlpha] doubleValue] <= 0.01) continue;
            CGRect candidateBounds = CGRectZero;
            if (!CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                    &candidateBounds) || CGRectIsEmpty(candidateBounds) ||
                !CGRectIntersectsRect(baseBounds, candidateBounds)) continue;

            NSNumber *key = @(candidateWindowID);
            [seen addObject:key];
            attached++;
            MacWSTransientLayer *layer = client.transientLayers[key];
            BOOL usedSurfaceMeasurement = NO;
            CGFloat presentationScale = LayerPresentationScale(
                candidateBounds, layer.latestSurface, scale,
                &usedSurfaceMeasurement);
            CGRect destination = CGRectMake(
                (candidateBounds.origin.x - baseBounds.origin.x) * scale,
                (candidateBounds.origin.y - baseBounds.origin.y) * scale,
                usedSurfaceMeasurement
                    ? IOSurfaceGetWidth(layer.latestSurface)
                    : candidateBounds.size.width * presentationScale,
                usedSurfaceMeasurement
                    ? IOSurfaceGetHeight(layer.latestSurface)
                    : candidateBounds.size.height * presentationScale);
            BOOL isNew = layer == nil;
            if (isNew) {
                layer = [MacWSTransientLayer new];
                layer.client = client;
                layer.windowID = candidateWindowID;
                client.transientLayers[key] = layer;
            }
            if (layer.retiring) {
                layer.retiring = NO;
                layer.retirementGeneration++;
                [RetiredTransientLayers removeObject:layer];
                DisplayLog(@"layer-retire-cancel layer=%u reason=window-returned",
                           layer.windowID);
            }
            layer.client = client;
            layer.ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
            id ownerName = info[(id)kCGWindowOwnerName];
            layer.ownerName = [ownerName isKindOfClass:NSString.class]
                ? ownerName : @"";
            id windowName = info[(id)kCGWindowName];
            layer.windowName = [windowName isKindOfClass:NSString.class]
                ? windowName : @"";
            layer.skyLightLayer = level;
            if (urgentRetireConfirmation &&
                layer.skyLightLayer >=
                    CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey) &&
                layer.skyLightLayer <
                    CGWindowLevelForKey(kCGCursorWindowLevelKey))
                urgentPopupPresent = YES;
            // An AppKit sheet can be a level-0 SkyLight window even though it
            // belongs above its presenting document. The metrics sidecar is
            // the owning process's authoritative relationship; assign only
            // those children a synthetic positive compositor level.
            NSInteger compositorLevel = logicalTransient ? 1 : level;
            layer.level = (int32_t)MAX(INT32_MIN,
                MIN((NSInteger)INT32_MAX, compositorLevel));
            layer.destinationBounds = destination;
            layer.missCount = 0;
            ConfigureNativePopupComposite(layer, client, windowInfo,
                                          baseBounds, candidateBounds);
            if (isNew || !layer.stream) StartTransientLayer(layer);
        }

        for (NSNumber *key in [client.transientLayers.allKeys copy]) {
            MacWSTransientLayer *layer = client.transientLayers[key];
            if ([seen containsObject:key]) continue;
            if (layer.retiring) continue;
            // A transient can briefly disappear from the on-screen catalog
            // while AppKit swaps its selection/shadow surface. Ordinary
            // recovery polling still requires three misses. A completed
            // semantic click is stronger evidence, but still requires two
            // independent snapshots; confirm its first miss on the next
            // display interval instead of leaving a closed translucent menu
            // visible until the 250 ms recovery poll runs twice.
            layer.missCount++;
            unsigned requiredMisses = urgentRetireConfirmation ? 2 : 3;
            if (layer.missCount < requiredMisses) {
                if (urgentRetireConfirmation)
                    windowMissingLayerNeedsConfirmation = YES;
                continue;
            }
            DisplayLog(@"layer-remove base=%u layer=%u stream=%llu through=%llu",
                       client.windowID, layer.windowID,
                       (unsigned long long)layer.streamID,
                       (unsigned long long)layer.sequence);
            SendLayerRemoved(client, layer);
            RetireTransientLayer(client, key, layer,
                                 @"window-catalog-removed");
        }
        if (client.transientLayers.count) needsFollowup = YES;
    }
    // Focus can move between two application owners without producing a new
    // final-composite IOSurface first. Re-apply the focused-layer policy from
    // the freshly read AppInput metrics so the previous application does not
    // keep a hidden high-rate capture stream alive and heat the device.
    if (FinalCompositeIsLive())
        SuspendFullscreenLayerCapturesForFinalComposite();

    CFTimeInterval reconcileFinished = CFAbsoluteTimeGetCurrent();
    // Geometry has its own ordered layer transaction and the normal
    // WindowServer compositor produces a fresh final frame for it. Only a
    // real layer add/remove can invalidate the topology represented by the
    // retained final composite and therefore authorize a replay request.
    if (workspaceTopologyChanged)
        NoteWorkspaceGraphMutation(mach_absolute_time(), @"layer-topology");
    if (workspacePresentationChanged &&
        reconcileFinished < WorkspaceAnimationSettlementHardDeadline) {
        CFTimeInterval settlementDeadline = fmin(
            WorkspaceAnimationSettlementHardDeadline,
            reconcileFinished + 0.10);
        WorkspaceAnimationSamplingDeadline = fmax(
            WorkspaceAnimationSamplingDeadline, settlementDeadline);
    }
    BOOL workspaceAnimationSampling =
        reconcileFinished < WorkspaceGeometrySamplingDeadline();
    if (workspaceAnimationSampling) RequestWorkspaceGeometrySample();
    if ((needsFollowup || workspaceNeedsFollowup) &&
        !workspaceAnimationSampling) {
        // Native AppKit geometry/catalog datagrams now preempt this timer at
        // 16ms. The periodic pass is only a recovery net for non-AppKit system
        // producers, so an idle fullscreen desktop no longer scans four times
        // per second.
        uint64_t delayNanoseconds = 0;
        delayNanoseconds =
            ((workspaceMissingLayerNeedsConfirmation ||
              windowMissingLayerNeedsConfirmation)
                ? 16
                : (urgentPopupPresent &&
                   UrgentTransientRetirePasses > 0)
                    ? 50
                    : (workspaceNeedsFollowup ? 1000 : 250)) *
            NSEC_PER_MSEC;
        ScheduleTransientReconcile(delayNanoseconds);
    }
}

static void ScheduleTransientReconcile(uint64_t delayNanoseconds) {
    // A delayed follow-up is only a recovery poll. A geometry/catalog edge is
    // authoritative and must be able to preempt it. Generation cancellation
    // keeps at most one effective reconcile without relying on an
    // uncancellable dispatch_after block.
    if (TransientReconcilePending && delayNanoseconds != 0) return;
    TransientReconcilePending = YES;
    uint64_t generation = ++TransientReconcileGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNanoseconds),
                   DisplayQueue, ^{
        if (generation != TransientReconcileGeneration) return;
        ReconcileTransientStreams();
    });
}

static void ReleaseLease(uint64_t token, MacWSDisplayClient *client) {
    MacWSDisplayLease *lease = Leases[@(token)];
    if (!lease || lease.owner != client) return;
    client.frameAcknowledged = YES;
    NSUInteger outstanding = OutstandingFramesForLayer(
        client, lease.layerWindowID);
    if (outstanding)
        SetOutstandingFramesForLayer(client, lease.layerWindowID,
                                     outstanding - 1);
    [Leases removeObjectForKey:@(token)];
}

static void RemoveClientLeases(MacWSDisplayClient *client) {
    NSArray<NSNumber *> *tokens = [Leases.allKeys copy];
    for (NSNumber *token in tokens) {
        MacWSDisplayLease *lease = Leases[token];
        if (lease.owner == client) [Leases removeObjectForKey:token];
    }
    [client.outstandingByLayer removeAllObjects];
}

static void RemoveClient(MacWSDisplayClient *client) {
    client.disconnectGeneration++;
    [client stopTransientLayers];
    [client stopStream];
    RemoveClientLeases(client);
    [Clients removeObject:client];
}

static void RetireFullscreenClientStaggered(MacWSDisplayClient *client) {
    if (![Clients containsObject:client]) return;
    client.disconnectGeneration++;
    NSArray<MacWSTransientLayer *> *layers =
        [client.transientLayers.allValues copy];
    // Detach first so removing/deallocating the client cannot synchronously
    // stop every Retina stream in one stack frame. Runtime evidence from
    // WindowServer.err showed that the old disconnect/reconnect burst was
    // followed by AGX command-buffer Internal Error 00000103 and a fresh
    // WindowServer PID.
    client.transientLayers = [NSMutableDictionary dictionary];
    [client stopStream];
    RemoveClientLeases(client);
    client.subscriptionActive = NO;
    client.deliveryPaused = NO;
    client.mode = 0;
    client.windowID = 0;
    client.streamID = 0;
    if (!client.connection) [Clients removeObject:client];
    DisplayLog(@"workspace-retire-staggered layers=%lu interval-ms=16",
               (unsigned long)layers.count);
    [layers enumerateObjectsUsingBlock:^(MacWSTransientLayer *layer,
                                         NSUInteger index, BOOL *stop) {
        (void)stop;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(index + 1) * 16 *
                                         NSEC_PER_MSEC),
                       DisplayQueue, ^{
            [layer stopStream];
            if (index + 1 == layers.count)
                DisplayLog(@"workspace-retire-complete layers=%lu",
                           (unsigned long)layers.count);
        });
    }];
}

static void PreserveFullscreenClientForHandoff(
        MacWSDisplayClient *client, BOOL disconnected) {
    if (disconnected) client.connection = nil;
    client.deliveryPaused = YES;
    RemoveClientLeases(client);
    uint64_t generation = ++client.disconnectGeneration;
    DisplayLog(@"workspace-%@-grace stream=%llu layers=%lu grace-ms=5000",
               disconnected ? @"disconnect" : @"pause",
               (unsigned long long)client.streamID,
               (unsigned long)client.transientLayers.count);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   DisplayQueue, ^{
        if (![Clients containsObject:client] ||
            client.disconnectGeneration != generation ||
            !client.subscriptionActive ||
            !client.deliveryPaused ||
            client.mode != MacWSStreamModeFullscreen ||
            (disconnected && client.connection)) return;
        DisplayLog(@"workspace-%@-grace-expired stream=%llu",
                   disconnected ? @"disconnect" : @"pause",
                   (unsigned long long)client.streamID);
        RetireFullscreenClientStaggered(client);
    });
}

static void RepublishUnacknowledgedWorkspaceGraph(
        MacWSDisplayClient *client) {
    if (!client || client.frameAcknowledged || !client.connection ||
        !client.subscriptionActive || client.deliveryPaused ||
        client.mode != MacWSStreamModeFullscreen) return;
    BOOL hasLiveFinalComposite = FinalCompositeIsLive();
    IOSurfaceRef base = hasLiveFinalComposite
        ? FinalCompositeSurface : client.workspaceCanvas;
    NSUInteger published = 0;
    if (base) {
        PublishFrame(client, nil,
            hasLiveFinalComposite
                ? FinalCompositeRecord.completionTime
                : mach_absolute_time(), base);
        published++;
    }
    NSArray<MacWSTransientLayer *> *layers =
        [client.transientLayers.allValues
            sortedArrayUsingComparator:^NSComparisonResult(
                MacWSTransientLayer *left, MacWSTransientLayer *right) {
            if (left.level < right.level) return NSOrderedAscending;
            if (left.level > right.level) return NSOrderedDescending;
            if (left.windowID < right.windowID) return NSOrderedAscending;
            if (left.windowID > right.windowID) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    for (MacWSTransientLayer *layer in layers) {
        if (!layer.latestSurface) continue;
        PublishFrame(client, layer,
            layer.latestDisplayTime ?: mach_absolute_time(),
            layer.latestSurface);
        published++;
    }
    DisplayLog(@"workspace-unacknowledged-republish stream=%llu frames=%lu "
               "catalog-barrier=YES",
               (unsigned long long)client.streamID,
               (unsigned long)published);
}

static void HandleRequest(MacWSDisplayClient *client, xpc_object_t request) {
    if (request == XPC_ERROR_CONNECTION_INVALID ||
        request == XPC_ERROR_CONNECTION_INTERRUPTED) {
        if (client.subscriptionActive &&
            client.mode == MacWSStreamModeFullscreen &&
            (client.workspaceCanvas || client.transientLayers.count != 0)) {
            PreserveFullscreenClientForHandoff(client, YES);
        } else {
            RemoveClient(client);
        }
        return;
    }
    if (!request || xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
    const char *operation = xpc_dictionary_get_string(request,
                                                       MACWS_STREAM_KEY_OP);
    if (!operation) return;
    if (strcmp(operation, MACWS_STREAM_OP_HELLO) == 0) {
        uint64_t version = xpc_dictionary_get_uint64(
            request, MACWS_STREAM_KEY_PROTOCOL_VERSION);
        if (version != MACWS_STREAM_VERSION) {
            SendStatus(client, MACWS_STREAM_EVENT_ERROR,
                       @"protocol version mismatch", NO);
            return;
        }
        SendStatus(client, MACWS_STREAM_EVENT_READY, @"ready", YES);
    } else if (strcmp(operation, MACWS_STREAM_OP_LIST_WINDOWS) == 0) {
        SendWindowList(client);
        // LIST_WINDOWS is the client's post-connection synchronization
        // barrier. Runtime-confirmed on 2026-08-29: the new Host received the
        // ready and catalog events but none of the IOSurface events emitted
        // synchronously while SUBSCRIBE was building eleven capture streams.
        // If no lease has made the complete Host -> RELEASE_FRAME round trip,
        // republish the retained immutable graph once the catalog event is
        // already ahead of it in the XPC stream. Stop automatically after the
        // first real acknowledgement; this is not a periodic frame replay.
        if (client.subscriptionActive &&
            client.mode == MacWSStreamModeFullscreen &&
            !client.frameAcknowledged) {
            __weak MacWSDisplayClient *weakClient = client;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         50 * NSEC_PER_MSEC),
                           DisplayQueue, ^{
                RepublishUnacknowledgedWorkspaceGraph(weakClient);
            });
        }
    } else if (strcmp(operation, MACWS_STREAM_OP_SUBSCRIBE) == 0) {
        MacWSStreamMode mode = (MacWSStreamMode)xpc_dictionary_get_uint64(
            request, MACWS_STREAM_KEY_MODE);
        uint64_t windowID = xpc_dictionary_get_uint64(
            request, MACWS_STREAM_KEY_WINDOW_ID);
        if ((mode != MacWSStreamModeFullscreen &&
             mode != MacWSStreamModeWindow) ||
            (mode == MacWSStreamModeWindow &&
             (windowID == 0 || windowID > UINT32_MAX))) {
            SendStatus(client, MACWS_STREAM_EVENT_ERROR,
                       @"invalid subscription", NO);
            return;
        }
        DisplayLog(@"request-subscribe client=%p requested-mode=%u window=%llu current-mode=%u active=%@ paused=%@ stream=%llu",
                   client, mode, (unsigned long long)windowID, client.mode,
                   client.subscriptionActive ? @"YES" : @"NO",
                   client.deliveryPaused ? @"YES" : @"NO",
                   (unsigned long long)client.streamID);
        StartSubscription(client, mode, (uint32_t)windowID);
    } else if (strcmp(operation, MACWS_STREAM_OP_UNSUBSCRIBE) == 0) {
        client.geometryRestartGeneration++;
        DisplayLog(@"request-unsubscribe client=%p current-mode=%u active=%@ stream=%llu",
                   client, client.mode,
                   client.subscriptionActive ? @"YES" : @"NO",
                   (unsigned long long)client.streamID);
        if (client.subscriptionActive &&
            client.mode == MacWSStreamModeFullscreen &&
            (client.workspaceCanvas || client.transientLayers.count != 0)) {
            PreserveFullscreenClientForHandoff(client, NO);
        } else {
            client.subscriptionActive = NO;
            client.deliveryPaused = NO;
            client.mode = 0;
            client.windowID = 0;
            [client stopTransientLayers];
            [client stopStream];
        }
    } else if (strcmp(operation, MACWS_STREAM_OP_RELEASE_FRAME) == 0) {
        ReleaseLease(xpc_dictionary_get_uint64(
            request, MACWS_STREAM_KEY_LEASE_TOKEN), client);
    } else if (strcmp(operation,
                      MACWS_STREAM_OP_DIRECT_DRAWABLE_ACTIVITY) == 0) {
        HandleDirectDrawableActivity(client, request);
    } else if (strcmp(operation, MACWS_MENU_XPC_OP_SNAPSHOT) == 0 ||
               strcmp(operation, MACWS_MENU_XPC_OP_ACTION) == 0) {
        size_t byteCount = 0;
        const void *bytes = xpc_dictionary_get_data(
            request, MACWS_MENU_XPC_KEY_REQUEST, &byteCount);
        MacWSMenuRequest menuRequest = {0};
        if (!bytes || byteCount != sizeof(menuRequest)) return;
        memcpy(&menuRequest, bytes, sizeof(menuRequest));
        if (!MacWSMenuRequestIsValid(&menuRequest, sizeof(menuRequest)) ||
            (menuRequest.operation == MacWSMenuOperationSnapshot) !=
                (strcmp(operation, MACWS_MENU_XPC_OP_SNAPSHOT) == 0)) return;
        RelayMenuRequest(client, menuRequest);
    }
}

static void AcceptConnection(xpc_connection_t connection) {
    MacWSDisplayClient *client = [MacWSDisplayClient new];
    client.connection = connection;
    client.transientLayers = [NSMutableDictionary dictionary];
    client.outstandingByLayer = [NSMutableDictionary dictionary];
    [Clients addObject:client];
    xpc_connection_set_target_queue(connection, DisplayQueue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        HandleRequest(client, event);
    });
    xpc_connection_resume(connection);
}

int main(void) {
    @autoreleasepool {
        // Establish the AppKit display mapping once on the main thread. The
        // serial display queue then consumes only this immutable scalar on
        // catalog/frame hot paths.
        NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
        CGFloat appKitScale = screen.backingScaleFactor;
        if (isfinite(appKitScale) && appKitScale >= 0.5 &&
            appKitScale <= 8.0) {
            AppKitMainDisplayBackingScale = appKitScale;
            DisplayLog(@"runtime-confirmed AppKit display backing-scale=%.3f frame=%@",
                       appKitScale, NSStringFromRect(screen.frame));
        }
        DisplayQueue = dispatch_queue_create("com.macwsguide.display.queue",
                                             DISPATCH_QUEUE_SERIAL);
        MenuQueue = dispatch_queue_create("com.macwsguide.display.menu",
                                          DISPATCH_QUEUE_CONCURRENT);
        WorkspaceGeometryQueue = dispatch_queue_create(
            "com.macwsguide.display.workspace-geometry",
            DISPATCH_QUEUE_SERIAL);
        Clients = [NSMutableSet set];
        Leases = [NSMutableDictionary dictionary];
        RetiredTransientLayers = [NSMutableArray array];
        RetiredTransientStopBlocks = [NSMutableArray array];
        GeometryTargets = [NSMutableDictionary dictionary];
        WriteFinalCompositeState(@"missing", 0, 0, @"displayd-start");
        WorkspaceGraphStateSignature = 0;
        [@"state=missing\nwindowserver=0\npublisher=0\nreason=displayd-start\n"
            writeToFile:WorkspaceGraphStatePath atomically:YES
               encoding:NSUTF8StringEncoding error:nil];
        StartInvalidationListener();
        xpc_connection_t listener = xpc_connection_create_mach_service(
            MACWS_STREAM_SERVICE, DisplayQueue,
            XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (!listener) {
            DisplayLog(@"listener-create failed service=%s",
                       MACWS_STREAM_SERVICE);
            return 1;
        }
        xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_CONNECTION)
                AcceptConnection((xpc_connection_t)event);
        });
        xpc_connection_resume(listener);
        MacWSStartFinalCompositeReceiver(
            DisplayQueue,
            ^(IOSurfaceRef surface, MacWSFinalCompositeRecord record) {
                DeliverFinalComposite(surface, record);
            },
            ^(NSString *message) {
                DisplayLog(@"%@", message);
            });
        DisplayLog(@"READY service=%s protocol=%u", MACWS_STREAM_SERVICE,
                   MACWS_STREAM_VERSION);
        dispatch_main();
    }
}
