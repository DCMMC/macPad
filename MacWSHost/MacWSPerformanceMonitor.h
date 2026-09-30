#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MacWSPerformanceHUDMode) {
    MacWSPerformanceHUDModeOff = 0,
    MacWSPerformanceHUDModeCompact = 1,
    MacWSPerformanceHUDModeFull = 2,
};

// A low-overhead, per-Scene profiler for the complete MacWS presentation
// boundary. The hot path writes only fixed-size rings; sorting, JSON encoding
// and label layout happen at the bounded 2 Hz HUD/export boundary.
@interface MacWSPerformanceMonitor : NSObject

@property(nonatomic) MacWSPerformanceHUDMode HUDMode;
@property(nonatomic, readonly) UIView *HUDView;

- (instancetype)initWithSceneLabel:(NSString *)sceneLabel
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)attachHUDToView:(UIView *)view;
- (void)resetWithReason:(NSString *)reason;

- (void)recordInputKind:(uint16_t)kind
             sampleTime:(CFTimeInterval)sampleTime
              targetPID:(int32_t)targetPID
       transportSuccess:(BOOL)success;

// Records the presentation authority independently of measurement state.
// A final-composite base is WindowServer-owned by construction, so input
// latency must correlate against this base rather than a target-PID layer.
- (void)recordBaseTransportFinalComposite:(BOOL)finalComposite
                                  streamID:(uint64_t)streamID
                                   sequence:(uint64_t)sequence
                                  surfaceID:(uint32_t)surfaceID;

- (void)recordFrameReceivedForStream:(uint64_t)streamID
                            sequence:(uint64_t)sequence
                       layerWindowID:(uint32_t)layerWindowID
                            ownerPID:(int32_t)ownerPID
                         captureTime:(uint64_t)captureTime
                         receiptTime:(uint64_t)receiptTime;

- (void)recordGeometryReceivedForStream:(uint64_t)streamID
                                sequence:(uint64_t)sequence
                           layerWindowID:(uint32_t)layerWindowID
                                ownerPID:(int32_t)ownerPID
                             captureTime:(uint64_t)captureTime
                             receiptTime:(uint64_t)receiptTime;
- (void)recordGeometryBatchReceived;

// Records one producer-completed Catalyst CAMetalLayer drawable.  The
// completion timestamp and monotonically increasing sequence originate in
// the game process, so this cadence cannot be inflated by MacWSHost drawing
// the same retained IOSurface more than once.
- (void)recordDirectDrawableReceivedForOwnerPID:(int32_t)ownerPID
                                        sequence:(uint64_t)sequence
                                  completionTime:(uint64_t)completionTime
                                     receiptTime:(uint64_t)receiptTime
                                        isTarget:(BOOL)isTarget;

// Call before -presentDrawable: for every direct drawable sampled by this
// Host submission.  Repeated submissions of the same producer sequence are
// coalesced; the resulting visible cadence counts only unique game frames
// that reached an actual CAMetalDrawable presentation callback.
- (void)recordDirectDrawableSubmissionForOwnerPID:(int32_t)ownerPID
                                          sequence:(uint64_t)sequence
                                      completionTime:(uint64_t)completionTime
                                          isTarget:(BOOL)isTarget
                                           drawable:(id<MTLDrawable>)drawable;

// Counts every authenticated-animation scheduler callback and whether it had
// a completed producer frame. This exposes producer/display phase misses
// without adding per-frame logging or a second scheduling loop.
- (void)recordDirectDrawableSchedulerTickWithFrame:(BOOL)hasFrame;

// Call before -presentDrawable:. This registers Metal completion and actual
// drawable-presentation handlers, so the result is visible-frame timing and
// not merely command submission throughput.
- (void)recordSubmissionForStream:(uint64_t)streamID
                         sequence:(uint64_t)sequence
                      captureTime:(uint64_t)captureTime
                      receiptTime:(uint64_t)receiptTime
                       submitTime:(uint64_t)submitTime
        directTargetAuthoritative:(BOOL)directTargetAuthoritative
                    commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                         drawable:(id<MTLDrawable>)drawable;

- (NSDictionary<NSString *, id> *)snapshotWithReason:(NSString *)reason;
- (nullable NSString *)exportSnapshotWithReason:(NSString *)reason
                                           error:(NSError **)error;

// CAPerfHUD-compatible access to Apple QuartzCore's system-wide render-server
// HUD. Level 5 is Apple's "Full" view; zero disables it. The custom MacWS HUD
// remains independent and measures the cross-process pipeline above.
+ (NSInteger)systemPerformanceHUDLevel;
+ (BOOL)setSystemPerformanceHUDLevel:(NSInteger)level
                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
