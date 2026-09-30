#import "MacWSStreamClient.h"

#import "MacWSHostDiagnostics.h"

#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <xpc/xpc.h>

@implementation MacWSStreamWindow
- (instancetype)initWithDescriptor:(MacWSStreamWindowDescriptor)descriptor
                              title:(NSString *)title {
    return [self initWithDescriptor:descriptor title:title limits:NULL];
}
- (instancetype)initWithDescriptor:(MacWSStreamWindowDescriptor)descriptor
                              title:(NSString *)title
                             limits:(const MacWSStreamWindowLimits *)limits {
    self = [super init];
    if (self) {
        _descriptor = descriptor;
        _title = [title copy];
        if (MacWSStreamWindowLimitsAreValid(limits, sizeof(*limits)) &&
            limits->ownerPID == descriptor.ownerPID &&
            limits->windowID == descriptor.windowID) {
            _maximumLogicalSize = CGSizeMake(limits->maximumLogicalWidth,
                                             limits->maximumLogicalHeight);
            _supportsConfigurationAcknowledgements = YES;
            _latestConfigureTimestamp = limits->configureAck.timestamp;
            _latestConfigureSequence = limits->configureAck.sequence;
            _latestConfigureRequestedSize = CGSizeMake(
                limits->configureAck.requestedWidth,
                limits->configureAck.requestedHeight);
            _latestConfigureAppliedSize = CGSizeMake(
                limits->configureAck.appliedWidth,
                limits->configureAck.appliedHeight);
        }
    }
    return self;
}
@end

@implementation MacWSSurfaceFrame {
    IOSurfaceRef _surface;
}

- (instancetype)initWithDescriptor:(MacWSStreamFrameDescriptor)descriptor
                            surface:(IOSurfaceRef)surface
                        receiptTime:(uint64_t)receiptTime {
    self = [super init];
    if (self) {
        _descriptor = descriptor;
        _surface = surface ? (IOSurfaceRef)CFRetain(surface) : NULL;
        _receiptTime = receiptTime;
    }
    return self;
}

- (void)dealloc {
    if (_surface) CFRelease(_surface);
}

- (IOSurfaceRef)surface { return _surface; }
@end

@interface MacWSStreamClient ()
@property(nonatomic) xpc_connection_t connection;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic, readwrite, getter=isConnected) BOOL connected;
@property(nonatomic, readwrite) MacWSStreamMode mode;
@property(nonatomic, readwrite) uint32_t windowID;
@property(nonatomic) MacWSStreamMode subscribedMode;
@property(nonatomic) uint32_t subscribedWindowID;
@property(nonatomic) BOOL subscriptionActive;
@property(nonatomic) NSData *lastWindowCatalog;
@property(nonatomic, readwrite, copy) NSArray<MacWSStreamWindow *> *systemInputWindows;
// DisplayStream is a realtime transport.  If UIKit's main thread is still
// presenting frame N when N+1/N+2 arrive, replaying every stale frame adds
// latency without adding visible information.  Keep only the newest base and
// newest frame for each overlay until the next main-queue delivery.
@property(nonatomic) MacWSSurfaceFrame *pendingBaseFrame;
@property(nonatomic) NSMutableDictionary<NSNumber *, MacWSSurfaceFrame *> *pendingOverlayFrames;
// A layer removal and its final capture callback can cross UIKit's main-queue
// delivery boundary. Remember the retired producer stream so a late frame from
// that generation cannot resurrect visible pixels during displayd's five-second
// crash-safe stream-stop grace period. A genuinely recreated SkyLight window
// has a new streamID and clears its own tombstone on first frame.
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *latestOverlayStreamIDs;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *retiredOverlayStreamIDs;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *retiredOverlaySequences;
// Frame events for one WindowServer composite arrive as a short burst from
// several independent window streams.  Delivering each burst immediately on
// UIKit's main queue made Mission Control import textures and schedule Metal
// presents several times inside one panel refresh.  Arm a paused display link
// and drain only the newest frame for each layer at the next native refresh.
@property(nonatomic) CADisplayLink *frameDeliveryDisplayLink;
@property(nonatomic) BOOL frameDeliveryScheduled;
@property(nonatomic) BOOL reconnectEnabled;
@property(nonatomic) NSUInteger reconnectAttempt;
@property(nonatomic) uint64_t reconnectGeneration;
@end

@implementation MacWSStreamClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.macwsguide.host.display-client",
                                       DISPATCH_QUEUE_SERIAL);
        _pendingOverlayFrames = [NSMutableDictionary dictionary];
        _latestOverlayStreamIDs = [NSMutableDictionary dictionary];
        _retiredOverlayStreamIDs = [NSMutableDictionary dictionary];
        _retiredOverlaySequences = [NSMutableDictionary dictionary];
        _reconnectEnabled = YES;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)publishStatus:(NSString *)status connected:(BOOL)connected {
    self.connected = connected;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!connected) self.systemInputWindows = @[];
        [self.delegate streamClient:self statusChanged:status connected:connected];
    });
}

- (BOOL)ensureConnection {
    if (self.connection) return YES;
    xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
        dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!createMach) {
        [self publishStatus:@"DisplayStream XPC API 不可用" connected:NO];
        return NO;
    }
    xpc_connection_t connection = createMach(MACWS_STREAM_SERVICE, self.queue, 0);
    if (!connection) {
        [self publishStatus:@"DisplayStream 服务未注册" connected:NO];
        return NO;
    }
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        [weakSelf handleEvent:event];
    });
    xpc_connection_resume(connection);
    self.connection = connection;

    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, MACWS_STREAM_KEY_OP,
                              MACWS_STREAM_OP_HELLO);
    xpc_dictionary_set_uint64(hello, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_connection_send_message(connection, hello);
    return YES;
}

- (void)sendSubscription {
    if (![self ensureConnection]) return;
    uint32_t desiredWindowID = self.mode == MacWSStreamModeWindow
        ? self.windowID : 0;
    if (self.subscriptionActive && self.subscribedMode == self.mode &&
        self.subscribedWindowID == desiredWindowID) return;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_STREAM_KEY_OP,
                              MACWS_STREAM_OP_SUBSCRIBE);
    xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                              MACWS_STREAM_VERSION);
    xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_MODE, self.mode);
    xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_WINDOW_ID,
                              self.windowID);
    xpc_connection_send_message(self.connection, request);
    self.subscribedMode = self.mode;
    self.subscribedWindowID = desiredWindowID;
    self.subscriptionActive = YES;
}

- (void)subscribeToMode:(MacWSStreamMode)mode windowID:(uint32_t)windowID {
    if (mode != MacWSStreamModeFullscreen && mode != MacWSStreamModeWindow)
        return;
    if (mode == MacWSStreamModeWindow && windowID == 0) return;
    dispatch_async(self.queue, ^{
        self.reconnectEnabled = YES;
        uint32_t normalizedWindowID = mode == MacWSStreamModeWindow
            ? windowID : 0;
        if (self.mode != mode || self.windowID != normalizedWindowID)
            [self clearPendingFramesOnClientQueueReleasing:YES];
        self.mode = mode;
        self.windowID = normalizedWindowID;
        if (![self ensureConnection]) return;
        if (self.isConnected) [self sendSubscription];
    });
}

- (void)requestWindowList {
    dispatch_async(self.queue, ^{
        self.reconnectEnabled = YES;
        if (![self ensureConnection]) return;
        // Callers use an explicit list request as a synchronization barrier
        // after launch/reopen. The bytes may equal the last unsolicited
        // catalog, but the newly-installed pending PID transaction still
        // needs that snapshot. Keep deduplication for broadcasts and force
        // only this user/control-plane query to reach the delegate.
        self.lastWindowCatalog = nil;
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, MACWS_STREAM_KEY_OP,
                                  MACWS_STREAM_OP_LIST_WINDOWS);
        xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_PROTOCOL_VERSION,
                                  MACWS_STREAM_VERSION);
        xpc_connection_send_message(self.connection, request);
    });
}

- (void)unsubscribe {
    dispatch_async(self.queue, ^{
        self.reconnectEnabled = NO;
        self.reconnectGeneration++;
        self.subscriptionActive = NO;
        [self clearPendingFramesOnClientQueueReleasing:YES];
        if (!self.connection) return;
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, MACWS_STREAM_KEY_OP,
                                  MACWS_STREAM_OP_UNSUBSCRIBE);
        xpc_connection_send_message(self.connection, request);
    });
}

- (void)releaseFrame:(MacWSSurfaceFrame *)frame {
    [self releaseToken:frame.descriptor.leaseToken];
}

- (void)noteDirectDrawableForOwnerPID:(int32_t)ownerPID
                        layerWindowID:(uint32_t)layerWindowID
                                width:(uint32_t)width
                               height:(uint32_t)height {
    if (ownerPID <= 1 || layerWindowID == 0 || width == 0 || height == 0 ||
        width > MACWS_STREAM_MAX_DIMENSION ||
        height > MACWS_STREAM_MAX_DIMENSION) return;
    dispatch_async(self.queue, ^{
        if (!self.connection || !self.isConnected ||
            !self.subscriptionActive ||
            (self.mode != MacWSStreamModeFullscreen &&
             self.mode != MacWSStreamModeWindow)) return;
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(
            request, MACWS_STREAM_KEY_OP,
            MACWS_STREAM_OP_DIRECT_DRAWABLE_ACTIVITY);
        xpc_dictionary_set_uint64(request,
            MACWS_STREAM_KEY_PROTOCOL_VERSION, MACWS_STREAM_VERSION);
        xpc_dictionary_set_bool(request, MACWS_STREAM_KEY_ACTIVE, true);
        xpc_dictionary_set_int64(request, MACWS_STREAM_KEY_OWNER_PID,
                                 ownerPID);
        xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_LAYER_WINDOW_ID,
                                  layerWindowID);
        xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_WIDTH, width);
        xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_HEIGHT, height);
        xpc_connection_send_message(self.connection, request);
    });
}

- (void)clearDirectDrawableActivity {
    dispatch_async(self.queue, ^{
        if (!self.connection) return;
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(
            request, MACWS_STREAM_KEY_OP,
            MACWS_STREAM_OP_DIRECT_DRAWABLE_ACTIVITY);
        xpc_dictionary_set_uint64(request,
            MACWS_STREAM_KEY_PROTOCOL_VERSION, MACWS_STREAM_VERSION);
        xpc_dictionary_set_bool(request, MACWS_STREAM_KEY_ACTIVE, false);
        xpc_connection_send_message(self.connection, request);
    });
}

- (void)releaseToken:(uint64_t)leaseToken {
    if (!leaseToken) return;
    dispatch_async(self.queue, ^{
        if (!self.connection) return;
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, MACWS_STREAM_KEY_OP,
                                  MACWS_STREAM_OP_RELEASE_FRAME);
        xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_LEASE_TOKEN,
                                  leaseToken);
        xpc_connection_send_message(self.connection, request);
    });
}

- (void)releaseTokenImmediatelyOnClientQueue:(uint64_t)leaseToken {
    if (!leaseToken || !self.connection) return;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_STREAM_KEY_OP,
                              MACWS_STREAM_OP_RELEASE_FRAME);
    xpc_dictionary_set_uint64(request, MACWS_STREAM_KEY_LEASE_TOKEN,
                              leaseToken);
    xpc_connection_send_message(self.connection, request);
}

- (void)setFrameDeliveryDisplayLinkPausedOnMainQueue:(BOOL)paused {
    NSAssert(NSThread.isMainThread, @"frame delivery display link is main-thread owned");
    if (!self.frameDeliveryDisplayLink && !paused) {
        CADisplayLink *link = [CADisplayLink
            displayLinkWithTarget:self
                         selector:@selector(deliverPendingFramesForDisplayLink:)];
        if (@available(iOS 15.0, *)) {
            // Frame delivery and MTKView presentation are two consecutive
            // main-runloop stages. Runtime evidence on 2026-08-10 showed that
            // pacing both at 60 Hz reduced an interactive full-Retina Dock
            // layer to 30.82 fps (68 frames / 2.174 s, with 30 producer frames
            // dropped to the three-lease backpressure limit). Use the iPad
            // panel's 120-Hz boundary for this lightweight newest-frame drain.
            // The producer remains capped at 60 Hz, the pending dictionary
            // still coalesces by layer, and the display link pauses after one
            // drain, so this reduces the two-stage latency without inventing
            // frames or running continuously while the desktop is static.
            link.preferredFrameRateRange = CAFrameRateRangeMake(60.0, 120.0,
                                                                 120.0);
        } else {
            link.preferredFramesPerSecond = 60;
        }
        link.paused = YES;
        [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        self.frameDeliveryDisplayLink = link;
    }
    self.frameDeliveryDisplayLink.paused = paused;
}

- (void)deliverPendingFramesForDisplayLink:(CADisplayLink *)displayLink {
    NSAssert(NSThread.isMainThread, @"frame delivery must run on UIKit main");
    NSArray<MacWSSurfaceFrame *> *frames = nil;
    @synchronized (self) {
        NSMutableArray<MacWSSurfaceFrame *> *latest =
            [NSMutableArray arrayWithCapacity:
                self.pendingOverlayFrames.count + 1];
        if (self.pendingBaseFrame) [latest addObject:self.pendingBaseFrame];
        NSArray<MacWSSurfaceFrame *> *overlays =
            [self.pendingOverlayFrames.allValues
                sortedArrayUsingComparator:^NSComparisonResult(
                    MacWSSurfaceFrame *left,
                    MacWSSurfaceFrame *right) {
                if (left.descriptor.layerLevel <
                    right.descriptor.layerLevel) return NSOrderedAscending;
                if (left.descriptor.layerLevel >
                    right.descriptor.layerLevel) return NSOrderedDescending;
                if (left.descriptor.layerWindowID <
                    right.descriptor.layerWindowID) return NSOrderedAscending;
                if (left.descriptor.layerWindowID >
                    right.descriptor.layerWindowID) return NSOrderedDescending;
                return NSOrderedSame;
            }];
        [latest addObjectsFromArray:overlays];
        frames = [latest copy];
        self.pendingBaseFrame = nil;
        [self.pendingOverlayFrames removeAllObjects];
        self.frameDeliveryScheduled = NO;
    }
    // Pause before invoking the delegate.  A frame arriving during texture
    // import observes frameDeliveryScheduled=NO and queues a later unpause;
    // it cannot be accidentally cancelled by the end of this callback.
    displayLink.paused = YES;
    static BOOL reportedFirstDisplayLinkDrain = NO;
    if (!reportedFirstDisplayLinkDrain && frames.count != 0) {
        reportedFirstDisplayLinkDrain = YES;
        MacWSLog(@"display-stream frame-transport display-link-drain "
                 "frames=%lu", (unsigned long)frames.count);
    }
    for (MacWSSurfaceFrame *latest in frames)
        [self.delegate streamClient:self receivedFrame:latest];
}

- (void)clearPendingFramesOnClientQueueReleasing:(BOOL)releaseFrames {
    NSArray<MacWSSurfaceFrame *> *pending = nil;
    @synchronized (self) {
        NSMutableArray<MacWSSurfaceFrame *> *frames =
            [NSMutableArray arrayWithCapacity:
                self.pendingOverlayFrames.count + 1];
        if (self.pendingBaseFrame) [frames addObject:self.pendingBaseFrame];
        [frames addObjectsFromArray:self.pendingOverlayFrames.allValues];
        pending = [frames copy];
        self.pendingBaseFrame = nil;
        [self.pendingOverlayFrames removeAllObjects];
        [self.latestOverlayStreamIDs removeAllObjects];
        [self.retiredOverlayStreamIDs removeAllObjects];
        [self.retiredOverlaySequences removeAllObjects];
        self.frameDeliveryScheduled = NO;
    }
    if (releaseFrames) {
        for (MacWSSurfaceFrame *frame in pending) {
            [self releaseTokenImmediatelyOnClientQueue:
                frame.descriptor.leaseToken];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setFrameDeliveryDisplayLinkPausedOnMainQueue:YES];
    });
}

- (void)enqueueFrameForMainDelivery:(MacWSSurfaceFrame *)frame {
    BOOL overlay = (frame.descriptor.flags & MacWSStreamFrameOverlay) != 0;
    MacWSSurfaceFrame *replaced = nil;
    BOOL scheduleDelivery = NO;
    @synchronized (self) {
        if (overlay) {
            NSNumber *key = @(frame.descriptor.layerWindowID);
            replaced = self.pendingOverlayFrames[key];
            self.pendingOverlayFrames[key] = frame;
        } else {
            replaced = self.pendingBaseFrame;
            self.pendingBaseFrame = frame;
        }
        if (!self.frameDeliveryScheduled) {
            self.frameDeliveryScheduled = YES;
            scheduleDelivery = YES;
        }
    }
    if (replaced) {
        [self releaseTokenImmediatelyOnClientQueue:
            replaced.descriptor.leaseToken];
    }
    if (!scheduleDelivery) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setFrameDeliveryDisplayLinkPausedOnMainQueue:NO];
    });
}

- (void)invalidate {
    CADisplayLink *deliveryLink = self.frameDeliveryDisplayLink;
    self.frameDeliveryDisplayLink = nil;
    if (deliveryLink) {
        if (NSThread.isMainThread) [deliveryLink invalidate];
        else dispatch_async(dispatch_get_main_queue(), ^{
            [deliveryLink invalidate];
        });
    }
    xpc_connection_t connection = self.connection;
    self.connection = nil;
    self.connected = NO;
    self.subscriptionActive = NO;
    self.lastWindowCatalog = nil;
    self.reconnectEnabled = NO;
    self.reconnectGeneration++;
    dispatch_sync(self.queue, ^{
        [self clearPendingFramesOnClientQueueReleasing:YES];
    });
    if (connection) xpc_connection_cancel(connection);
}

- (void)scheduleReconnectOnClientQueue {
    if (!self.reconnectEnabled || !self.mode || self.connection) return;
    uint64_t generation = ++self.reconnectGeneration;
    NSUInteger attempt = MIN(self.reconnectAttempt++, (NSUInteger)4);
    uint64_t delayMilliseconds = 100ull << attempt; // 100ms ... 1.6s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 delayMilliseconds * NSEC_PER_MSEC),
                   self.queue, ^{
        if (generation != self.reconnectGeneration ||
            !self.reconnectEnabled || !self.mode || self.connection) return;
        [self ensureConnection];
    });
}

- (void)handleEvent:(xpc_object_t)event {
    if (event == XPC_ERROR_CONNECTION_INVALID ||
        event == XPC_ERROR_CONNECTION_INTERRUPTED) {
        xpc_connection_t connection = self.connection;
        self.connection = nil;
        self.subscriptionActive = NO;
        self.lastWindowCatalog = nil;
        [self clearPendingFramesOnClientQueueReleasing:NO];
        if (connection) xpc_connection_cancel(connection);
        [self publishStatus:event == XPC_ERROR_CONNECTION_INTERRUPTED
            ? @"DisplayStream 连接中断，等待重新连接"
            : @"DisplayStream 服务离线"
                  connected:NO];
        [self scheduleReconnectOnClientQueue];
        return;
    }
    if (!event || xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    const char *eventName = xpc_dictionary_get_string(
        event, MACWS_STREAM_KEY_EVENT);
    if (!eventName) return;
    if (strcmp(eventName, MACWS_STREAM_EVENT_READY) == 0) {
        uint64_t version = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_PROTOCOL_VERSION);
        if (version != MACWS_STREAM_VERSION) {
            [self publishStatus:@"DisplayStream 协议版本不匹配" connected:NO];
            return;
        }
        self.reconnectAttempt = 0;
        self.reconnectGeneration++;
        [self publishStatus:@"DisplayStream IOSurface 直传已连接" connected:YES];
        if (self.mode) [self sendSubscription];
        [self requestWindowList];
    } else if (strcmp(eventName, MACWS_STREAM_EVENT_FRAME) == 0) {
        [self handleFrameEvent:event];
    } else if (strcmp(eventName,
                      MACWS_STREAM_EVENT_LAYER_GEOMETRY) == 0) {
        uint64_t receiptTime = mach_absolute_time();
        size_t byteCount = 0;
        const MacWSStreamLayerGeometry *updates =
            xpc_dictionary_get_data(event,
                MACWS_STREAM_KEY_LAYER_GEOMETRY, &byteCount);
        NSUInteger count = byteCount / sizeof(MacWSStreamLayerGeometry);
        BOOL valid = updates && byteCount != 0 &&
            byteCount % sizeof(MacWSStreamLayerGeometry) == 0 &&
            count <= MACWS_STREAM_MAX_LAYER_GEOMETRY;
        for (NSUInteger index = 0; valid && index < count; index++) {
            const MacWSStreamLayerGeometry *geometry = &updates[index];
            valid = MacWSStreamLayerGeometryIsValid(
                geometry, sizeof(*geometry)) &&
                ((self.mode == MacWSStreamModeFullscreen &&
                  geometry->windowID == 0) ||
                 (self.mode == MacWSStreamModeWindow &&
                  geometry->windowID == self.windowID));
        }
        if (!valid) return;
        NSData *payload = [NSData dataWithBytes:updates length:byteCount];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate streamClient:self
                receivedLayerGeometryUpdates:payload
                               receiptTime:receiptTime];
        });
    } else if (strcmp(eventName, MACWS_STREAM_EVENT_LAYER_REMOVED) == 0) {
        uint64_t baseWindowID = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_WINDOW_ID);
        uint64_t layerWindowID = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_LAYER_WINDOW_ID);
        uint64_t removedStreamID = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_STREAM_ID);
        uint64_t removedThroughSequence = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_SEQUENCE);
        if ((self.mode != MacWSStreamModeWindow &&
             self.mode != MacWSStreamModeFullscreen) ||
            baseWindowID != self.windowID || layerWindowID == 0 ||
            layerWindowID > UINT32_MAX || layerWindowID == baseWindowID)
            return;
        NSNumber *layerKey = @((uint32_t)layerWindowID);
        MacWSSurfaceFrame *pending = nil;
        @synchronized (self) {
            NSNumber *streamID = removedStreamID != 0
                ? @(removedStreamID)
                : self.latestOverlayStreamIDs[layerKey];
            if (streamID) {
                self.retiredOverlayStreamIDs[layerKey] = streamID;
                self.retiredOverlaySequences[layerKey] =
                    @(removedThroughSequence);
            }
            pending = self.pendingOverlayFrames[layerKey];
            [self.pendingOverlayFrames removeObjectForKey:layerKey];
        }
        if (pending) [self releaseTokenImmediatelyOnClientQueue:
            pending.descriptor.leaseToken];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate streamClient:self
                   removedLayerWindowID:(uint32_t)layerWindowID];
        });
    } else if (strcmp(eventName, MACWS_STREAM_EVENT_WINDOWS) == 0) {
        [self handleWindowsEvent:event];
    } else if (strcmp(eventName, MACWS_STREAM_EVENT_STOPPED) == 0 ||
               strcmp(eventName, MACWS_STREAM_EVENT_ERROR) == 0) {
        self.subscriptionActive = NO;
        const char *message = xpc_dictionary_get_string(
            event, MACWS_STREAM_KEY_MESSAGE);
        NSString *status = message ? [NSString stringWithUTF8String:message]
                                   : @"DisplayStream 已停止";
        [self publishStatus:status connected:self.isConnected];
    }
}

- (void)handleFrameEvent:(xpc_object_t)event {
    uint64_t receiptTime = mach_absolute_time();
    uint64_t eventLease = xpc_dictionary_get_uint64(
        event, MACWS_STREAM_KEY_LEASE_TOKEN);
    size_t descriptorSize = 0;
    const void *descriptorBytes = xpc_dictionary_get_data(
        event, MACWS_STREAM_KEY_DESCRIPTOR, &descriptorSize);
    MacWSStreamFrameDescriptor descriptor = {0};
    if (!descriptorBytes || descriptorSize != sizeof(descriptor)) {
        [self releaseToken:eventLease];
        return;
    }
    memcpy(&descriptor, descriptorBytes, sizeof(descriptor));
    static BOOL reportedFirstFrameEnvelope = NO;
    if (!reportedFirstFrameEnvelope) {
        reportedFirstFrameEnvelope = YES;
        MacWSLog(@"display-stream frame-transport envelope stream=%llu "
                 "sequence=%llu layer=%u lease=%llu descriptor-size=%lu",
                 (unsigned long long)descriptor.streamID,
                 (unsigned long long)descriptor.sequence,
                 descriptor.layerWindowID,
                 (unsigned long long)eventLease,
                 (unsigned long)descriptorSize);
    }
    if (!MacWSStreamFrameDescriptorIsValid(&descriptor, descriptorSize) ||
        eventLease == 0 || descriptor.leaseToken != eventLease) {
        [self releaseToken:eventLease];
        return;
    }
    if (self.mode == MacWSStreamModeWindow &&
        descriptor.windowID != self.windowID) {
        [self releaseToken:descriptor.leaseToken];
        return;
    }
    if (self.mode == MacWSStreamModeFullscreen && descriptor.windowID != 0) {
        [self releaseToken:descriptor.leaseToken];
        return;
    }
    BOOL overlay = (descriptor.flags & MacWSStreamFrameOverlay) != 0;
    if ((overlay && (self.mode != MacWSStreamModeWindow &&
                     self.mode != MacWSStreamModeFullscreen)) ||
        (overlay && descriptor.layerWindowID == descriptor.windowID) ||
        (!overlay && self.mode == MacWSStreamModeWindow &&
         descriptor.layerWindowID != descriptor.windowID)) {
        [self releaseToken:descriptor.leaseToken];
        return;
    }
    if (overlay) {
        NSNumber *layerKey = @(descriptor.layerWindowID);
        NSNumber *streamID = @(descriptor.streamID);
        BOOL retiredGeneration = NO;
        @synchronized (self) {
            NSNumber *retired = self.retiredOverlayStreamIDs[layerKey];
            NSNumber *retiredThrough =
                self.retiredOverlaySequences[layerKey];
            retiredGeneration = retired &&
                !MacWSStreamFrameSupersedesLayerRemoval(
                    descriptor.streamID, descriptor.sequence,
                    retired.unsignedLongLongValue,
                    retiredThrough.unsignedLongLongValue);
            if (!retiredGeneration) {
                // Either a new producer generation or a sequence above
                // displayd's explicit removal cutoff is authoritative proof
                // that the SkyLight window has returned. The latter preserves
                // the live stream and its retained IOSurface during Space and
                // App Expose transitions.
                [self.retiredOverlayStreamIDs removeObjectForKey:layerKey];
                [self.retiredOverlaySequences removeObjectForKey:layerKey];
                self.latestOverlayStreamIDs[layerKey] = streamID;
            }
        }
        if (retiredGeneration) {
            [self releaseToken:descriptor.leaseToken];
            return;
        }
    }

    IOSurfaceRef surface = NULL;
    mach_port_t port = xpc_dictionary_copy_mach_send(
        event, MACWS_STREAM_KEY_SURFACE_PORT);
    if (MACH_PORT_VALID(port)) {
        surface = IOSurfaceLookupFromMachPort(port);
        mach_port_deallocate(mach_task_self(), port);
    }
    if (!surface) {
        uint64_t surfaceID = xpc_dictionary_get_uint64(
            event, MACWS_STREAM_KEY_SURFACE_ID);
        if (surfaceID > 0 && surfaceID <= UINT32_MAX)
            surface = IOSurfaceLookup((uint32_t)surfaceID);
    }
    if (!surface) {
        [self releaseToken:descriptor.leaseToken];
        [self publishStatus:@"收到帧但无法导入 IOSurface" connected:YES];
        return;
    }

    BOOL geometryMatches = IOSurfaceGetWidth(surface) == descriptor.width &&
        IOSurfaceGetHeight(surface) == descriptor.height &&
        IOSurfaceGetBytesPerRow(surface) == descriptor.bytesPerRow;
    uint32_t actualFormat = IOSurfaceGetPixelFormat(surface);
    if (descriptor.pixelFormat && actualFormat &&
        actualFormat != descriptor.pixelFormat) {
        geometryMatches = NO;
    }
    if (!geometryMatches) {
        CFRelease(surface);
        [self releaseToken:descriptor.leaseToken];
        [self publishStatus:@"拒绝尺寸或像素格式不匹配的 IOSurface"
                  connected:YES];
        return;
    }

    MacWSSurfaceFrame *frame = [[MacWSSurfaceFrame alloc]
        initWithDescriptor:descriptor surface:surface receiptTime:receiptTime];
    static BOOL reportedFirstSurfaceImport = NO;
    if (!reportedFirstSurfaceImport) {
        reportedFirstSurfaceImport = YES;
        MacWSLog(@"display-stream frame-transport surface-import stream=%llu "
                 "layer=%u surface=%u size=%ux%u",
                 (unsigned long long)descriptor.streamID,
                 descriptor.layerWindowID, IOSurfaceGetID(surface),
                 descriptor.width, descriptor.height);
    }
    CFRelease(surface);
    [self enqueueFrameForMainDelivery:frame];
}

- (void)handleWindowsEvent:(xpc_object_t)event {
    xpc_object_t array = xpc_dictionary_get_value(event,
                                                   MACWS_STREAM_KEY_WINDOWS);
    if (!array || xpc_get_type(array) != XPC_TYPE_ARRAY) return;
    NSMutableArray<MacWSStreamWindow *> *windows = [NSMutableArray array];
    NSMutableData *fingerprint = [NSMutableData data];
    NSMutableArray<MacWSStreamWindow *> *systemWindows = [NSMutableArray array];
    xpc_object_t systemArray = xpc_dictionary_get_value(event,
        MACWS_STREAM_KEY_SYSTEM_INPUT_WINDOWS);
    if (systemArray && xpc_get_type(systemArray) == XPC_TYPE_ARRAY) {
        xpc_array_apply(systemArray, ^bool(size_t index, xpc_object_t value) {
            if (index >= 8) return false;
            if (xpc_get_type(value) != XPC_TYPE_DATA) return true;
            size_t count = xpc_data_get_length(value);
            const void *bytes = xpc_data_get_bytes_ptr(value);
            if (count != sizeof(MacWSStreamWindowDescriptor) ||
                !MacWSStreamWindowDescriptorIsValid(bytes, count)) return true;
            MacWSStreamWindowDescriptor descriptor;
            memcpy(&descriptor, bytes, sizeof(descriptor));
            if ((descriptor.flags & MacWSStreamWindowOnScreen) == 0) return true;
            [systemWindows addObject:[[MacWSStreamWindow alloc]
                initWithDescriptor:descriptor title:@""]];
            return true;
        });
    }
    uint32_t systemCount = (uint32_t)systemWindows.count;
    [fingerprint appendBytes:&systemCount length:sizeof(systemCount)];
    for (MacWSStreamWindow *window in systemWindows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        [fingerprint appendBytes:&descriptor length:sizeof(descriptor)];
    }
    NSMutableDictionary<NSString *, NSData *> *limitsByIdentity =
        [NSMutableDictionary dictionary];
    xpc_object_t limitsArray = xpc_dictionary_get_value(
        event, MACWS_STREAM_KEY_WINDOW_LIMITS);
    if (limitsArray && xpc_get_type(limitsArray) == XPC_TYPE_ARRAY) {
        xpc_array_apply(limitsArray, ^bool(size_t index, xpc_object_t value) {
            if (index >= MACWS_STREAM_MAX_WINDOWS) return false;
            if (xpc_get_type(value) != XPC_TYPE_DATA) return true;
            const MacWSStreamWindowLimits *limits = xpc_data_get_bytes_ptr(value);
            size_t count = xpc_data_get_length(value);
            if (!MacWSStreamWindowLimitsAreValid(limits, count)) return true;
            NSString *identity = [NSString stringWithFormat:@"%d:%u",
                limits->ownerPID, limits->windowID];
            limitsByIdentity[identity] = [NSData dataWithBytes:limits length:count];
            return true;
        });
    }
    xpc_array_apply(array, ^bool(size_t index, xpc_object_t value) {
        (void)index;
        if (windows.count >= MACWS_STREAM_MAX_WINDOWS ||
            xpc_get_type(value) != XPC_TYPE_DATA) return true;
        size_t byteCount = xpc_data_get_length(value);
        const void *bytes = xpc_data_get_bytes_ptr(value);
        if (!MacWSStreamWindowDescriptorIsValid(bytes, byteCount)) return true;
        uint32_t stableByteCount = byteCount <= UINT32_MAX
            ? (uint32_t)byteCount : 0;
        [fingerprint appendBytes:&stableByteCount length:sizeof(stableByteCount)];
        [fingerprint appendBytes:bytes length:byteCount];
        MacWSStreamWindowDescriptor descriptor;
        memcpy(&descriptor, bytes, sizeof(descriptor));
        NSString *identity = [NSString stringWithFormat:@"%d:%u",
            descriptor.ownerPID, descriptor.windowID];
        NSData *limitsData = limitsByIdentity[identity];
        uint32_t limitsLength = (uint32_t)limitsData.length;
        [fingerprint appendBytes:&limitsLength length:sizeof(limitsLength)];
        if (limitsData) [fingerprint appendData:limitsData];
        NSData *titleData = [NSData dataWithBytes:(const uint8_t *)bytes +
                             sizeof(descriptor) length:descriptor.titleLength];
        NSString *title = [[NSString alloc] initWithData:titleData
                                                encoding:NSUTF8StringEncoding];
        if (!title) title = @"macOS Window";
        [windows addObject:[[MacWSStreamWindow alloc]
            initWithDescriptor:descriptor title:title limits:limitsData.bytes]];
        return true;
    });
    if ([self.lastWindowCatalog isEqualToData:fingerprint]) return;
    self.lastWindowCatalog = [fingerprint copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.systemInputWindows = systemWindows;
        [self.delegate streamClient:self receivedWindows:windows];
    });
}

@end
