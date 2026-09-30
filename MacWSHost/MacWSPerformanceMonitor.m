#import "MacWSPerformanceMonitor.h"

#import <os/lock.h>

#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>

#include "macws_touch_policy.h"

static const NSUInteger MacWSPerfRingCapacity = 512;
static const NSUInteger MacWSPerfInputKindCapacity = 32;
static const double MacWSPerfActiveGapMilliseconds = 150.0;
static const double MacWSPerfInputActiveWindowMilliseconds = 250.0;
static const int MacWSQuartzCorePerformanceHUDFlag = 0x10000000;

typedef struct {
    double values[512];
    NSUInteger count;
    NSUInteger cursor;
} MacWSPerfRing;

static const NSUInteger MacWSPerfSourceCapacity = 64;
typedef struct {
    uint64_t streamID;
    uint64_t lastCaptureTime;
    uint64_t lastReceiptTime;
    uint64_t contentFrames;
    uint64_t geometryUpdates;
    uint32_t layerWindowID;
    int32_t ownerPID;
    bool dirtySinceSubmission;
    MacWSPerfRing intervals;
} MacWSPerfSource;

static const NSUInteger MacWSPerfDirectSourceCapacity = 16;
enum { MacWSPerfDirectReceiptCapacity = 8 };
typedef struct {
    int32_t ownerPID;
    bool target;
    uint64_t firstSequence;
    uint64_t lastSequence;
    uint64_t uniqueFramesReceived;
    uint64_t missingSequences;
    uint64_t firstCompletionTime;
    uint64_t lastCompletionTime;
    uint64_t lastReceiptTime;
    uint64_t lastSubmittedSequence;
    uint64_t lastPresentedSequence;
    uint64_t uniqueFramesPresented;
    double firstPresentedSeconds;
    double lastPresentedSeconds;
    uint64_t pendingReceiptSequences[MacWSPerfDirectReceiptCapacity];
    uint64_t pendingReceiptTimes[MacWSPerfDirectReceiptCapacity];
    MacWSPerfRing producerIntervals;
    MacWSPerfRing completionToReceipt;
    MacWSPerfRing receiptToSubmission;
    MacWSPerfRing completionToSubmission;
    MacWSPerfRing submissionToVisible;
    MacWSPerfRing completionToVisible;
    MacWSPerfRing visibleIntervals;
} MacWSPerfDirectSource;

static void MacWSPerfRingReset(MacWSPerfRing *ring) {
    memset(ring, 0, sizeof(*ring));
}

static void MacWSPerfRingAppend(MacWSPerfRing *ring, double value) {
    if (!isfinite(value) || value < 0.0) return;
    ring->values[ring->cursor] = value;
    ring->cursor = (ring->cursor + 1) % MacWSPerfRingCapacity;
    ring->count = MIN(ring->count + 1, MacWSPerfRingCapacity);
}

static NSArray<NSNumber *> *MacWSPerfSortedValues(const MacWSPerfRing *ring) {
    NSMutableArray<NSNumber *> *values =
        [NSMutableArray arrayWithCapacity:ring->count];
    NSUInteger first = ring->count == MacWSPerfRingCapacity
        ? ring->cursor : 0;
    for (NSUInteger index = 0; index < ring->count; index++) {
        NSUInteger slot = (first + index) % MacWSPerfRingCapacity;
        [values addObject:@(ring->values[slot])];
    }
    [values sortUsingComparator:^NSComparisonResult(NSNumber *left,
                                                      NSNumber *right) {
        return [left compare:right];
    }];
    return values;
}

static NSNumber *MacWSPerfPercentile(NSArray<NSNumber *> *values,
                                     double fraction) {
    if (!values.count) return (NSNumber *)NSNull.null;
    NSUInteger index = (NSUInteger)ceil(values.count * fraction);
    index = MIN(MAX(index, 1u), values.count) - 1;
    return values[index];
}

static NSDictionary<NSString *, id> *MacWSPerfRingSummary(
        const MacWSPerfRing *ring) {
    NSArray<NSNumber *> *values = MacWSPerfSortedValues(ring);
    if (!values.count) {
        return @{
            @"samples": @0,
            @"mean_ms": NSNull.null,
            @"p50_ms": NSNull.null,
            @"p95_ms": NSNull.null,
            @"p99_ms": NSNull.null,
            @"maximum_ms": NSNull.null,
        };
    }
    double total = 0.0;
    for (NSNumber *value in values) total += value.doubleValue;
    return @{
        @"samples": @(values.count),
        @"mean_ms": @(total / values.count),
        @"p50_ms": MacWSPerfPercentile(values, 0.50),
        @"p95_ms": MacWSPerfPercentile(values, 0.95),
        @"p99_ms": MacWSPerfPercentile(values, 0.99),
        @"maximum_ms": values.lastObject,
    };
}

static double MacWSPerfMachMilliseconds(uint64_t start, uint64_t end) {
    if (!start || end < start) return -1.0;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
    if (!timebase.denom) return -1.0;
    long double nanoseconds = (long double)(end - start) *
        timebase.numer / timebase.denom;
    return (double)(nanoseconds / 1000000.0L);
}

static NSString *MacWSPerfThermalStateName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return @"nominal";
        case NSProcessInfoThermalStateFair: return @"fair";
        case NSProcessInfoThermalStateSerious: return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
    }
    return @"unknown";
}

@interface MacWSPerformanceMonitor ()
@property(nonatomic, readwrite) UIView *HUDView;
@end

@implementation MacWSPerformanceMonitor {
    NSString *_sceneLabel;
    os_unfair_lock _lock;
    uint64_t _resetMachTime;
    uint64_t _measurementGeneration;
    NSDate *_resetDate;
    NSString *_resetReason;
    atomic_bool _instrumentationActive;
    BOOL _explicitRecording;
    double _targetFramesPerSecond;
    double _targetFrameMilliseconds;

    uint64_t _framesReceived;
    uint64_t _contentFramesReceived;
    uint64_t _geometryUpdatesReceived;
    uint64_t _geometryBatchesReceived;
    uint64_t _framesSubmitted;
    uint64_t _framesPresented;
    uint64_t _directDrawableFramesReceived;
    uint64_t _directDrawableFramesPresented;
    uint64_t _directDrawableSchedulerTicks;
    uint64_t _directDrawableSchedulerEmptyTicks;
    uint64_t _commandErrors;
    uint64_t _inputsAttempted;
    uint64_t _inputsSent;
    uint64_t _inputTransportErrors;
    uint64_t _directInputPendingCandidates;
    uint64_t _directInputRejectedBeforeCompletion;
    uint64_t _directTargetUniqueSubmissions;
    uint64_t _compositedInputClaims;
    uint64_t _directInputVisibilitySamples;
    uint64_t _compositedInputVisibilitySamples;
    uint64_t _estimatedDroppedVsyncs;
    uint64_t _hitchCount;
    uint64_t _stallCount;
    uint64_t _inactiveGapCount;
    uint64_t _staleCaptureSamples;

    uint64_t _lastSubmittedStream;
    uint64_t _lastSubmittedSequence;
    double _lastPresentedSeconds;
    double _lastInteractivePresentedSeconds;
    uint64_t _lastInputMachTime;
    uint64_t _pendingInputMachTime;
    uint16_t _pendingInputKind;
    int32_t _pendingInputTargetPID;
    BOOL _finalCompositeActive;
    uint64_t _baseTransportStreamID;
    uint64_t _baseTransportSequence;
    uint32_t _baseTransportSurfaceID;

    MacWSPerfRing _sourceIntervals;
    MacWSPerfRing _presentIntervals;
    MacWSPerfRing _observedPresentIntervals;
    MacWSPerfRing _captureToReceipt;
    MacWSPerfRing _receiptToSubmit;
    MacWSPerfRing _submitToComplete;
    MacWSPerfRing _gpuExecution;
    MacWSPerfRing _captureToPresent;
    MacWSPerfRing _inputToPresent;
    MacWSPerfRing _inputToPresentByKind[32];
    MacWSPerfSource _sources[64];
    MacWSPerfDirectSource _directSources[16];

    UIVisualEffectView *_HUDMaterial;
    UILabel *_HUDLabel;
    NSLayoutConstraint *_HUDWidthConstraint;
    NSLayoutConstraint *_HUDHeightConstraint;
    dispatch_source_t _HUDTimer;
}

- (instancetype)initWithSceneLabel:(NSString *)sceneLabel {
    self = [super init];
    if (!self) return nil;
    _sceneLabel = [sceneLabel copy] ?: @"unknown";
    _lock = OS_UNFAIR_LOCK_INIT;
    NSInteger maximumFramesPerSecond = UIScreen.mainScreen.maximumFramesPerSecond;
    _targetFramesPerSecond = maximumFramesPerSecond > 0
        ? (double)maximumFramesPerSecond : 60.0;
    _targetFrameMilliseconds = 1000.0 / _targetFramesPerSecond;
    atomic_init(&_instrumentationActive, false);
    [self resetWithReason:@"monitor-created"];

    _HUDMaterial = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    _HUDMaterial.translatesAutoresizingMaskIntoConstraints = NO;
    _HUDMaterial.userInteractionEnabled = NO;
    _HUDMaterial.layer.cornerRadius = 13.0;
    _HUDMaterial.layer.cornerCurve = kCACornerCurveContinuous;
    _HUDMaterial.layer.borderWidth = 0.5;
    _HUDMaterial.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.22].CGColor;
    _HUDMaterial.clipsToBounds = YES;
    _HUDMaterial.accessibilityIdentifier = @"macws-performance-hud";

    _HUDLabel = [UILabel new];
    _HUDLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _HUDLabel.numberOfLines = 0;
    _HUDLabel.textColor = UIColor.whiteColor;
    _HUDLabel.font = [UIFont monospacedSystemFontOfSize:11.0
                                                weight:UIFontWeightSemibold];
    [_HUDMaterial.contentView addSubview:_HUDLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_HUDLabel.leadingAnchor constraintEqualToAnchor:
            _HUDMaterial.contentView.leadingAnchor constant:10],
        [_HUDLabel.trailingAnchor constraintEqualToAnchor:
            _HUDMaterial.contentView.trailingAnchor constant:-10],
        [_HUDLabel.topAnchor constraintEqualToAnchor:
            _HUDMaterial.contentView.topAnchor constant:8],
        [_HUDLabel.bottomAnchor constraintEqualToAnchor:
            _HUDMaterial.contentView.bottomAnchor constant:-8],
    ]];
    self.HUDView = _HUDMaterial;
    self.HUDMode = MacWSPerformanceHUDModeOff;
    return self;
}

- (void)dealloc {
    if (_HUDTimer) dispatch_source_cancel(_HUDTimer);
}

- (void)attachHUDToView:(UIView *)view {
    if (!view || _HUDMaterial.superview == view) return;
    [_HUDMaterial removeFromSuperview];
    [view addSubview:_HUDMaterial];
    _HUDWidthConstraint = [_HUDMaterial.widthAnchor constraintEqualToConstant:228];
    _HUDHeightConstraint = [_HUDMaterial.heightAnchor constraintEqualToConstant:64];
    [NSLayoutConstraint activateConstraints:@[
        [_HUDMaterial.trailingAnchor constraintEqualToAnchor:
            view.safeAreaLayoutGuide.trailingAnchor constant:-10],
        [_HUDMaterial.bottomAnchor constraintEqualToAnchor:
            view.safeAreaLayoutGuide.bottomAnchor constant:-10],
        _HUDWidthConstraint,
        _HUDHeightConstraint,
    ]];
    [self applyHUDMode];
}

- (void)setHUDMode:(MacWSPerformanceHUDMode)HUDMode {
    if (HUDMode < MacWSPerformanceHUDModeOff ||
        HUDMode > MacWSPerformanceHUDModeFull)
        HUDMode = MacWSPerformanceHUDModeOff;
    _HUDMode = HUDMode;
    os_unfair_lock_lock(&_lock);
    atomic_store(&_instrumentationActive,
        _explicitRecording || HUDMode != MacWSPerformanceHUDModeOff);
    os_unfair_lock_unlock(&_lock);
    [self applyHUDMode];
}

- (void)applyHUDMode {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyHUDMode]; });
        return;
    }
    BOOL enabled = self.HUDMode != MacWSPerformanceHUDModeOff;
    _HUDMaterial.hidden = !enabled;
    _HUDWidthConstraint.constant = self.HUDMode == MacWSPerformanceHUDModeFull
        ? 292.0 : 228.0;
    _HUDHeightConstraint.constant = self.HUDMode == MacWSPerformanceHUDModeFull
        ? 146.0 : 64.0;
    if (enabled) {
        [self updateHUD];
        [self startHUDTimer];
    } else if (_HUDTimer) {
        dispatch_source_cancel(_HUDTimer);
        _HUDTimer = nil;
    }
}

- (void)startHUDTimer {
    if (_HUDTimer) return;
    _HUDTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
    dispatch_source_set_timer(_HUDTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_HUDTimer, ^{ [weakSelf updateHUD]; });
    dispatch_resume(_HUDTimer);
}

- (void)resetWithReason:(NSString *)reason {
    os_unfair_lock_lock(&_lock);
    _explicitRecording = ![reason isEqualToString:@"monitor-created"];
    atomic_store(&_instrumentationActive,
        _explicitRecording || _HUDMode != MacWSPerformanceHUDModeOff);
    _resetMachTime = mach_absolute_time();
    _measurementGeneration++;
    _resetDate = NSDate.date;
    _resetReason = [reason copy] ?: @"manual";
    _framesReceived = 0;
    _contentFramesReceived = 0;
    _geometryUpdatesReceived = 0;
    _geometryBatchesReceived = 0;
    _framesSubmitted = 0;
    _framesPresented = 0;
    _directDrawableFramesReceived = 0;
    _directDrawableFramesPresented = 0;
    _directDrawableSchedulerTicks = 0;
    _directDrawableSchedulerEmptyTicks = 0;
    _commandErrors = 0;
    _inputsAttempted = 0;
    _inputsSent = 0;
    _inputTransportErrors = 0;
    _directInputPendingCandidates = 0;
    _directInputRejectedBeforeCompletion = 0;
    _directTargetUniqueSubmissions = 0;
    _compositedInputClaims = 0;
    _directInputVisibilitySamples = 0;
    _compositedInputVisibilitySamples = 0;
    _estimatedDroppedVsyncs = 0;
    _hitchCount = 0;
    _stallCount = 0;
    _inactiveGapCount = 0;
    _staleCaptureSamples = 0;
    _lastSubmittedStream = 0;
    _lastSubmittedSequence = 0;
    _lastPresentedSeconds = 0.0;
    _lastInteractivePresentedSeconds = 0.0;
    _lastInputMachTime = 0;
    _pendingInputMachTime = 0;
    _pendingInputKind = 0;
    _pendingInputTargetPID = 0;
    MacWSPerfRingReset(&_sourceIntervals);
    MacWSPerfRingReset(&_presentIntervals);
    MacWSPerfRingReset(&_observedPresentIntervals);
    MacWSPerfRingReset(&_captureToReceipt);
    MacWSPerfRingReset(&_receiptToSubmit);
    MacWSPerfRingReset(&_submitToComplete);
    MacWSPerfRingReset(&_gpuExecution);
    MacWSPerfRingReset(&_captureToPresent);
    MacWSPerfRingReset(&_inputToPresent);
    memset(_inputToPresentByKind, 0, sizeof(_inputToPresentByKind));
    memset(_sources, 0, sizeof(_sources));
    memset(_directSources, 0, sizeof(_directSources));
    os_unfair_lock_unlock(&_lock);
    if (self.HUDMode != MacWSPerformanceHUDModeOff)
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateHUD]; });
}

- (void)recordInputKind:(uint16_t)kind
             sampleTime:(CFTimeInterval)sampleTime
              targetPID:(int32_t)targetPID
       transportSuccess:(BOOL)success {
    (void)sampleTime;
    if (!atomic_load(&_instrumentationActive)) return;
    uint64_t now = mach_absolute_time();
    os_unfair_lock_lock(&_lock);
    _inputsAttempted++;
    if (success) {
        _inputsSent++;
        _lastInputMachTime = now;
        // Keep the oldest not-yet-assigned event. It represents the first
        // user action waiting for a newly produced visible frame; high-rate
        // move records are naturally coalesced behind that boundary.
        if (!_pendingInputMachTime ||
            MacWSInputSupersedesPendingVisibilitySample(
                _pendingInputKind, kind)) {
            _pendingInputMachTime = now;
            _pendingInputKind = kind;
            _pendingInputTargetPID = targetPID;
        }
    } else {
        _inputTransportErrors++;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)recordBaseTransportFinalComposite:(BOOL)finalComposite
                                  streamID:(uint64_t)streamID
                                  sequence:(uint64_t)sequence
                                 surfaceID:(uint32_t)surfaceID {
    if (!atomic_load(&_instrumentationActive)) return;
    os_unfair_lock_lock(&_lock);
    _finalCompositeActive = finalComposite;
    _baseTransportStreamID = streamID;
    _baseTransportSequence = sequence;
    _baseTransportSurfaceID = surfaceID;
    os_unfair_lock_unlock(&_lock);
}

- (void)recordSourceForStream:(uint64_t)streamID
                     sequence:(uint64_t)sequence
                layerWindowID:(uint32_t)layerWindowID
                     ownerPID:(int32_t)ownerPID
                  captureTime:(uint64_t)captureTime
                  receiptTime:(uint64_t)receiptTime
                     geometry:(BOOL)geometry {
    (void)sequence;
    if (!atomic_load(&_instrumentationActive)) return;
    os_unfair_lock_lock(&_lock);
    _framesReceived++;
    if (geometry) _geometryUpdatesReceived++;
    else _contentFramesReceived++;
    MacWSPerfSource *source = NULL;
    MacWSPerfSource *empty = NULL;
    for (NSUInteger index = 0; index < MacWSPerfSourceCapacity; index++) {
        MacWSPerfSource *candidate = &_sources[index];
        if (candidate->streamID == streamID) {
            source = candidate;
            break;
        }
        if (!candidate->streamID && !empty) empty = candidate;
    }
    if (!source && streamID) {
        source = empty ?: &_sources[streamID % MacWSPerfSourceCapacity];
        memset(source, 0, sizeof(*source));
        source->streamID = streamID;
    }
    if (source) {
        if (layerWindowID) source->layerWindowID = layerWindowID;
        if (ownerPID > 0) source->ownerPID = ownerPID;
        if (geometry) source->geometryUpdates++;
        else source->contentFrames++;
        if (source->lastCaptureTime &&
            captureTime > source->lastCaptureTime) {
            double interval = MacWSPerfMachMilliseconds(
                source->lastCaptureTime, captureTime);
            if (interval <= MacWSPerfActiveGapMilliseconds) {
                MacWSPerfRingAppend(&_sourceIntervals, interval);
                MacWSPerfRingAppend(&source->intervals, interval);
            }
        }
        if (captureTime > source->lastCaptureTime)
            source->lastCaptureTime = captureTime;
        if (receiptTime > source->lastReceiptTime)
            source->lastReceiptTime = receiptTime;
        source->dirtySinceSubmission = true;
    }
    double captureReceipt = MacWSPerfMachMilliseconds(captureTime,
                                                      receiptTime);
    // displayd may explicitly republish a retained static IOSurface after a
    // layer temporarily leaves Mission Control. Its capture timestamp is
    // intentionally old and is not a transport-latency sample.
    if (captureReceipt >= 0.0 && captureReceipt <= 1000.0)
        MacWSPerfRingAppend(&_captureToReceipt, captureReceipt);
    else
        _staleCaptureSamples++;
    os_unfair_lock_unlock(&_lock);
}

- (void)recordFrameReceivedForStream:(uint64_t)streamID
                            sequence:(uint64_t)sequence
                       layerWindowID:(uint32_t)layerWindowID
                            ownerPID:(int32_t)ownerPID
                         captureTime:(uint64_t)captureTime
                         receiptTime:(uint64_t)receiptTime {
    [self recordSourceForStream:streamID sequence:sequence
        layerWindowID:layerWindowID ownerPID:ownerPID
        captureTime:captureTime receiptTime:receiptTime geometry:NO];
}

- (void)recordGeometryReceivedForStream:(uint64_t)streamID
                                sequence:(uint64_t)sequence
                           layerWindowID:(uint32_t)layerWindowID
                                ownerPID:(int32_t)ownerPID
                             captureTime:(uint64_t)captureTime
                             receiptTime:(uint64_t)receiptTime {
    [self recordSourceForStream:streamID sequence:sequence
        layerWindowID:layerWindowID ownerPID:ownerPID
        captureTime:captureTime receiptTime:receiptTime geometry:YES];
}

- (void)recordGeometryBatchReceived {
    if (!atomic_load(&_instrumentationActive)) return;
    os_unfair_lock_lock(&_lock);
    _geometryBatchesReceived++;
    os_unfair_lock_unlock(&_lock);
}

- (MacWSPerfDirectSource *)directSourceForOwnerPID:(int32_t)ownerPID
                                             create:(BOOL)create {
    MacWSPerfDirectSource *empty = NULL;
    for (NSUInteger index = 0; index < MacWSPerfDirectSourceCapacity; index++) {
        MacWSPerfDirectSource *candidate = &_directSources[index];
        if (candidate->ownerPID == ownerPID) return candidate;
        if (candidate->ownerPID == 0 && !empty) empty = candidate;
    }
    if (!create || ownerPID <= 1) return NULL;
    MacWSPerfDirectSource *source = empty ?:
        &_directSources[(uint32_t)ownerPID % MacWSPerfDirectSourceCapacity];
    memset(source, 0, sizeof(*source));
    source->ownerPID = ownerPID;
    return source;
}

- (void)recordDirectDrawableReceivedForOwnerPID:(int32_t)ownerPID
                                        sequence:(uint64_t)sequence
                                  completionTime:(uint64_t)completionTime
                                     receiptTime:(uint64_t)receiptTime
                                        isTarget:(BOOL)isTarget {
    if (ownerPID <= 1 || sequence == 0 || completionTime == 0 ||
        receiptTime == 0 || !atomic_load(&_instrumentationActive)) return;
    os_unfair_lock_lock(&_lock);
    MacWSPerfDirectSource *source =
        [self directSourceForOwnerPID:ownerPID create:YES];
    if (!source || (source->lastSequence != 0 &&
                    sequence <= source->lastSequence)) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    source->target = source->target || isTarget;
    if (source->lastSequence != 0) {
        if (sequence > source->lastSequence + 1)
            source->missingSequences += sequence - source->lastSequence - 1;
        if (completionTime > source->lastCompletionTime) {
            MacWSPerfRingAppend(&source->producerIntervals,
                MacWSPerfMachMilliseconds(source->lastCompletionTime,
                                          completionTime));
        }
    } else {
        source->firstSequence = sequence;
        source->firstCompletionTime = completionTime;
    }
    double transport = MacWSPerfMachMilliseconds(completionTime, receiptTime);
    if (transport >= 0.0 && transport <= 1000.0)
        MacWSPerfRingAppend(&source->completionToReceipt, transport);
    source->lastSequence = sequence;
    source->lastCompletionTime = completionTime;
    source->lastReceiptTime = receiptTime;
    NSUInteger receiptSlot = sequence % MacWSPerfDirectReceiptCapacity;
    source->pendingReceiptSequences[receiptSlot] = sequence;
    source->pendingReceiptTimes[receiptSlot] = receiptTime;
    source->uniqueFramesReceived++;
    _directDrawableFramesReceived++;
    os_unfair_lock_unlock(&_lock);
}

- (void)recordDirectDrawableSubmissionForOwnerPID:(int32_t)ownerPID
                                          sequence:(uint64_t)sequence
                                    completionTime:(uint64_t)completionTime
                                          isTarget:(BOOL)isTarget
                                           drawable:(id<MTLDrawable>)drawable {
    if (ownerPID <= 1 || sequence == 0 || completionTime == 0 || !drawable ||
        !atomic_load(&_instrumentationActive)) return;
    __block uint64_t measurementGeneration = 0;
    __block uint64_t inputMachTime = 0;
    __block uint16_t inputKind = 0;
    uint64_t submitTime = mach_absolute_time();
    os_unfair_lock_lock(&_lock);
    MacWSPerfDirectSource *source =
        [self directSourceForOwnerPID:ownerPID create:YES];
    if (!source || (source->lastSubmittedSequence != 0 &&
                    sequence <= source->lastSubmittedSequence)) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    source->target = source->target || isTarget;
    source->lastSubmittedSequence = sequence;
    NSUInteger receiptSlot = sequence % MacWSPerfDirectReceiptCapacity;
    if (source->pendingReceiptSequences[receiptSlot] == sequence) {
        MacWSPerfRingAppend(&source->receiptToSubmission,
            MacWSPerfMachMilliseconds(
                source->pendingReceiptTimes[receiptSlot], submitTime));
        source->pendingReceiptSequences[receiptSlot] = 0;
        source->pendingReceiptTimes[receiptSlot] = 0;
    }
    MacWSPerfRingAppend(&source->completionToSubmission,
        MacWSPerfMachMilliseconds(completionTime, submitTime));
    measurementGeneration = _measurementGeneration;
    if (isTarget) _directTargetUniqueSubmissions++;
    // Runtime-confirmed on iPad14,5: the fullscreen 7DTD drawable was the
    // visible pixel authority at ~115 Hz while the retained WindowServer
    // FinalComposite advanced at ~10 Hz.  Pairing its input with the base
    // stream therefore reported 66.8 ms against pixels hidden beneath the
    // authoritative direct layer.  A producer completion after the input is
    // the first direct frame that can contain that input's result; consume
    // the pending sample here so the hidden base fallback cannot claim it.
    if (isTarget && _pendingInputMachTime &&
        (_pendingInputTargetPID <= 1 ||
         _pendingInputTargetPID == ownerPID)) {
        _directInputPendingCandidates++;
        if (completionTime >= _pendingInputMachTime) {
            inputMachTime = _pendingInputMachTime;
            inputKind = _pendingInputKind;
            _pendingInputMachTime = 0;
            _pendingInputKind = 0;
            _pendingInputTargetPID = 0;
        } else {
            _directInputRejectedBeforeCompletion++;
        }
    }
    os_unfair_lock_unlock(&_lock);

    __weak typeof(self) weakSelf = self;
    [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        uint64_t callbackTime = mach_absolute_time();
        double presentedSeconds = presentedDrawable.presentedTime;
        if (presentedSeconds <= 0.0) presentedSeconds = CACurrentMediaTime();
        os_unfair_lock_lock(&strongSelf->_lock);
        if (measurementGeneration != strongSelf->_measurementGeneration) {
            os_unfair_lock_unlock(&strongSelf->_lock);
            return;
        }
        MacWSPerfDirectSource *current =
            [strongSelf directSourceForOwnerPID:ownerPID create:NO];
        if (!current || (current->lastPresentedSequence != 0 &&
                         sequence <= current->lastPresentedSequence)) {
            os_unfair_lock_unlock(&strongSelf->_lock);
            return;
        }
        if (current->lastPresentedSeconds > 0.0 &&
            presentedSeconds > current->lastPresentedSeconds) {
            MacWSPerfRingAppend(&current->visibleIntervals,
                (presentedSeconds - current->lastPresentedSeconds) * 1000.0);
        } else if (current->firstPresentedSeconds == 0.0) {
            current->firstPresentedSeconds = presentedSeconds;
        }
        current->lastPresentedSeconds = presentedSeconds;
        current->lastPresentedSequence = sequence;
        current->uniqueFramesPresented++;
        MacWSPerfRingAppend(&current->submissionToVisible,
            MacWSPerfMachMilliseconds(submitTime, callbackTime));
        MacWSPerfRingAppend(&current->completionToVisible,
            MacWSPerfMachMilliseconds(completionTime, callbackTime));
        strongSelf->_directDrawableFramesPresented++;
        if (inputMachTime) {
            double latency = MacWSPerfMachMilliseconds(
                inputMachTime, mach_absolute_time());
            MacWSPerfRingAppend(&strongSelf->_inputToPresent, latency);
            strongSelf->_directInputVisibilitySamples++;
            if (inputKind < MacWSPerfInputKindCapacity)
                MacWSPerfRingAppend(
                    &strongSelf->_inputToPresentByKind[inputKind], latency);
        }
        os_unfair_lock_unlock(&strongSelf->_lock);
    }];
}

- (void)recordDirectDrawableSchedulerTickWithFrame:(BOOL)hasFrame {
    if (!atomic_load(&_instrumentationActive)) return;
    os_unfair_lock_lock(&_lock);
    _directDrawableSchedulerTicks++;
    if (!hasFrame) _directDrawableSchedulerEmptyTicks++;
    os_unfair_lock_unlock(&_lock);
}

- (void)recordSubmissionForStream:(uint64_t)streamID
                         sequence:(uint64_t)sequence
                      captureTime:(uint64_t)captureTime
                       receiptTime:(uint64_t)receiptTime
                        submitTime:(uint64_t)submitTime
        directTargetAuthoritative:(BOOL)directTargetAuthoritative
                     commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          drawable:(id<MTLDrawable>)drawable {
    if (!commandBuffer || !drawable ||
        !atomic_load(&_instrumentationActive)) return;
    __block uint64_t inputMachTime = 0;
    __block uint16_t inputKind = 0;
    __block uint64_t measurementGeneration = 0;
    __block BOOL newlyReceivedFrame = NO;
    os_unfair_lock_lock(&_lock);
    measurementGeneration = _measurementGeneration;
    newlyReceivedFrame = receiptTime >= _resetMachTime;
    _framesSubmitted++;
    _lastSubmittedStream = streamID;
    _lastSubmittedSequence = sequence;
    if (newlyReceivedFrame) {
        MacWSPerfRingAppend(&_receiptToSubmit,
            MacWSPerfMachMilliseconds(receiptTime, submitTime));
    }
    // Never pair input with a redraw of a frame captured before that input.
    BOOL inputTargetUpdated = NO;
    BOOL dirtyFrameAfterReset = NO;
    for (NSUInteger index = 0; index < MacWSPerfSourceCapacity; index++) {
        MacWSPerfSource *source = &_sources[index];
        if (source->dirtySinceSubmission &&
            source->lastReceiptTime >= _resetMachTime)
            dirtyFrameAfterReset = YES;
        if (!directTargetAuthoritative &&
            source->dirtySinceSubmission && _pendingInputMachTime &&
            source->lastReceiptTime >= _pendingInputMachTime &&
            (_pendingInputTargetPID <= 1 ||
             source->ownerPID == _pendingInputTargetPID ||
             (_finalCompositeActive &&
              source->streamID == _baseTransportStreamID)))
            inputTargetUpdated = YES;
        source->dirtySinceSubmission = false;
    }
    // A drawable may composite several streams. The caller passes the newest
    // representative stream for capture/receipt timing, but that stream can
    // be a retained static overlay while another source supplied the fresh
    // pixels. Count the presentation whenever any included source was dirty;
    // otherwise valid target-correlated input samples disappear.
    newlyReceivedFrame = newlyReceivedFrame || dirtyFrameAfterReset;
    if (_pendingInputMachTime && inputTargetUpdated) {
        inputMachTime = _pendingInputMachTime;
        inputKind = _pendingInputKind;
        _compositedInputClaims++;
        _pendingInputMachTime = 0;
        _pendingInputKind = 0;
        _pendingInputTargetPID = 0;
    }
    os_unfair_lock_unlock(&_lock);

    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        uint64_t completeTime = mach_absolute_time();
        os_unfair_lock_lock(&strongSelf->_lock);
        if (measurementGeneration != strongSelf->_measurementGeneration ||
            !newlyReceivedFrame) {
            os_unfair_lock_unlock(&strongSelf->_lock);
            return;
        }
        MacWSPerfRingAppend(&strongSelf->_submitToComplete,
            MacWSPerfMachMilliseconds(submitTime, completeTime));
        if (completed.status == MTLCommandBufferStatusError)
            strongSelf->_commandErrors++;
        if (completed.GPUEndTime >= completed.GPUStartTime &&
            completed.GPUStartTime > 0.0) {
            MacWSPerfRingAppend(&strongSelf->_gpuExecution,
                (completed.GPUEndTime - completed.GPUStartTime) * 1000.0);
        }
        os_unfair_lock_unlock(&strongSelf->_lock);
    }];

    [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        uint64_t callbackTime = mach_absolute_time();
        double presentedSeconds = presentedDrawable.presentedTime;
        if (presentedSeconds <= 0.0) presentedSeconds = CACurrentMediaTime();
        os_unfair_lock_lock(&strongSelf->_lock);
        if (measurementGeneration != strongSelf->_measurementGeneration ||
            !newlyReceivedFrame) {
            os_unfair_lock_unlock(&strongSelf->_lock);
            return;
        }
        strongSelf->_framesPresented++;
        if (strongSelf->_lastPresentedSeconds > 0.0 &&
            presentedSeconds > strongSelf->_lastPresentedSeconds) {
            double interval = (presentedSeconds -
                               strongSelf->_lastPresentedSeconds) * 1000.0;
            if (interval <= MacWSPerfActiveGapMilliseconds)
                MacWSPerfRingAppend(&strongSelf->_observedPresentIntervals,
                                    interval);
        }
        strongSelf->_lastPresentedSeconds = presentedSeconds;
        double sinceInput = MacWSPerfMachMilliseconds(
            strongSelf->_lastInputMachTime, callbackTime);
        BOOL inputActive = sinceInput >= 0.0 &&
            sinceInput <= MacWSPerfInputActiveWindowMilliseconds;
        if (inputActive &&
            strongSelf->_lastInteractivePresentedSeconds > 0.0 &&
            presentedSeconds > strongSelf->_lastInteractivePresentedSeconds) {
            double interval = (presentedSeconds -
                strongSelf->_lastInteractivePresentedSeconds) * 1000.0;
            if (interval <= MacWSPerfActiveGapMilliseconds) {
                MacWSPerfRingAppend(&strongSelf->_presentIntervals,
                                    interval);
                if (interval > strongSelf->_targetFrameMilliseconds * 1.5)
                    strongSelf->_hitchCount++;
                if (interval > 50.0) strongSelf->_stallCount++;
                NSUInteger vsyncs = (NSUInteger)llround(
                    interval / strongSelf->_targetFrameMilliseconds);
                if (vsyncs > 1)
                    strongSelf->_estimatedDroppedVsyncs += vsyncs - 1;
            } else {
                strongSelf->_inactiveGapCount++;
            }
        }
        if (inputActive)
            strongSelf->_lastInteractivePresentedSeconds = presentedSeconds;
        double capturePresent = MacWSPerfMachMilliseconds(captureTime,
                                                          callbackTime);
        if (capturePresent >= 0.0 && capturePresent <= 1000.0)
            MacWSPerfRingAppend(&strongSelf->_captureToPresent,
                                capturePresent);
        else
            strongSelf->_staleCaptureSamples++;
        if (inputMachTime) {
            double latency = MacWSPerfMachMilliseconds(
                inputMachTime, callbackTime);
            MacWSPerfRingAppend(&strongSelf->_inputToPresent, latency);
            strongSelf->_compositedInputVisibilitySamples++;
            if (inputKind < MacWSPerfInputKindCapacity)
                MacWSPerfRingAppend(
                    &strongSelf->_inputToPresentByKind[inputKind], latency);
        }
        os_unfair_lock_unlock(&strongSelf->_lock);
    }];
}

- (NSDictionary<NSString *, id> *)snapshotWithReason:(NSString *)reason {
    MacWSPerfSource *sourcesCopy = calloc(MacWSPerfSourceCapacity,
                                          sizeof(MacWSPerfSource));
    MacWSPerfDirectSource *directSourcesCopy = calloc(
        MacWSPerfDirectSourceCapacity, sizeof(MacWSPerfDirectSource));
    os_unfair_lock_lock(&_lock);
    NSDictionary *present = MacWSPerfRingSummary(&_presentIntervals);
    NSDictionary *observedPresent =
        MacWSPerfRingSummary(&_observedPresentIntervals);
    NSDictionary *source = MacWSPerfRingSummary(&_sourceIntervals);
    NSDictionary *captureReceipt = MacWSPerfRingSummary(&_captureToReceipt);
    NSDictionary *receiptSubmit = MacWSPerfRingSummary(&_receiptToSubmit);
    NSDictionary *submitComplete = MacWSPerfRingSummary(&_submitToComplete);
    NSDictionary *gpu = MacWSPerfRingSummary(&_gpuExecution);
    NSDictionary *capturePresent = MacWSPerfRingSummary(&_captureToPresent);
    NSDictionary *inputPresent = MacWSPerfRingSummary(&_inputToPresent);
    NSMutableDictionary<NSString *, NSDictionary *> *inputPresentByKind =
        [NSMutableDictionary dictionary];
    for (NSUInteger kind = 0; kind < MacWSPerfInputKindCapacity; kind++) {
        if (_inputToPresentByKind[kind].count == 0) continue;
        inputPresentByKind[[NSString stringWithFormat:@"%lu",
            (unsigned long)kind]] = MacWSPerfRingSummary(
                &_inputToPresentByKind[kind]);
    }
    uint64_t framesReceived = _framesReceived;
    uint64_t contentFramesReceived = _contentFramesReceived;
    uint64_t geometryUpdatesReceived = _geometryUpdatesReceived;
    uint64_t geometryBatchesReceived = _geometryBatchesReceived;
    uint64_t framesSubmitted = _framesSubmitted;
    uint64_t framesPresented = _framesPresented;
    uint64_t directDrawableFramesReceived = _directDrawableFramesReceived;
    uint64_t directDrawableFramesPresented = _directDrawableFramesPresented;
    uint64_t directDrawableSchedulerTicks =
        _directDrawableSchedulerTicks;
    uint64_t directDrawableSchedulerEmptyTicks =
        _directDrawableSchedulerEmptyTicks;
    uint64_t commandErrors = _commandErrors;
    uint64_t inputsAttempted = _inputsAttempted;
    uint64_t inputsSent = _inputsSent;
    uint64_t inputErrors = _inputTransportErrors;
    uint64_t directInputCandidates = _directInputPendingCandidates;
    uint64_t directInputRejected = _directInputRejectedBeforeCompletion;
    uint64_t directTargetSubmissions = _directTargetUniqueSubmissions;
    uint64_t compositedInputClaims = _compositedInputClaims;
    uint64_t directInputSamples = _directInputVisibilitySamples;
    uint64_t compositedInputSamples = _compositedInputVisibilitySamples;
    uint64_t dropped = _estimatedDroppedVsyncs;
    uint64_t hitches = _hitchCount;
    uint64_t stalls = _stallCount;
    uint64_t inactiveGaps = _inactiveGapCount;
    uint64_t staleCaptureSamples = _staleCaptureSamples;
    uint64_t lastStream = _lastSubmittedStream;
    uint64_t lastSequence = _lastSubmittedSequence;
    BOOL inputVisibilityPending = _pendingInputMachTime != 0;
    uint16_t pendingInputKind = _pendingInputKind;
    int32_t pendingInputTargetPID = _pendingInputTargetPID;
    BOOL finalCompositeActive = _finalCompositeActive;
    uint64_t baseTransportStreamID = _baseTransportStreamID;
    uint64_t baseTransportSequence = _baseTransportSequence;
    uint32_t baseTransportSurfaceID = _baseTransportSurfaceID;
    uint64_t resetTime = _resetMachTime;
    NSDate *resetDate = _resetDate;
    NSString *resetReason = _resetReason;
    BOOL instrumentationActive = atomic_load(&_instrumentationActive);
    if (sourcesCopy)
        memcpy(sourcesCopy, _sources, sizeof(_sources));
    if (directSourcesCopy)
        memcpy(directSourcesCopy, _directSources, sizeof(_directSources));
    os_unfair_lock_unlock(&_lock);

    NSMutableArray<NSDictionary *> *sourceStreams = [NSMutableArray array];
    if (sourcesCopy) {
        for (NSUInteger index = 0; index < MacWSPerfSourceCapacity; index++) {
            MacWSPerfSource *item = &sourcesCopy[index];
            if (!item->streamID) continue;
            NSDictionary *interval = MacWSPerfRingSummary(&item->intervals);
            NSNumber *mean = interval[@"mean_ms"];
            NSNumber *p99 = interval[@"p99_ms"];
            double fps = [mean isKindOfClass:NSNumber.class] &&
                         mean.doubleValue > 0.0
                ? 1000.0 / mean.doubleValue : 0.0;
            double low = [p99 isKindOfClass:NSNumber.class] &&
                         p99.doubleValue > 0.0
                ? 1000.0 / p99.doubleValue : 0.0;
            [sourceStreams addObject:@{
                @"stream_id": @(item->streamID),
                @"layer_window_id": @(item->layerWindowID),
                @"owner_pid": @(item->ownerPID),
                @"content_frames": @(item->contentFrames),
                @"geometry_updates": @(item->geometryUpdates),
                @"active_average_fps": @(fps),
                @"one_percent_low_fps": @(low),
                @"frame_interval": interval,
            }];
        }
        free(sourcesCopy);
    }
    [sourceStreams sortUsingComparator:^NSComparisonResult(
            NSDictionary *left, NSDictionary *right) {
        NSComparisonResult owner = [left[@"owner_pid"]
            compare:right[@"owner_pid"]];
        if (owner != NSOrderedSame) return owner;
        return [left[@"layer_window_id"] compare:right[@"layer_window_id"]];
    }];

    NSMutableArray<NSDictionary *> *directDrawableSources =
        [NSMutableArray array];
    NSDictionary *targetDirectDrawable = nil;
    if (directSourcesCopy) {
        for (NSUInteger index = 0; index < MacWSPerfDirectSourceCapacity;
             index++) {
            MacWSPerfDirectSource *item = &directSourcesCopy[index];
            if (item->ownerPID <= 1) continue;
            NSDictionary *producerInterval =
                MacWSPerfRingSummary(&item->producerIntervals);
            NSDictionary *transport =
                MacWSPerfRingSummary(&item->completionToReceipt);
            NSDictionary *receiptSubmission =
                MacWSPerfRingSummary(&item->receiptToSubmission);
            NSDictionary *completionSubmission =
                MacWSPerfRingSummary(&item->completionToSubmission);
            NSDictionary *submissionVisible =
                MacWSPerfRingSummary(&item->submissionToVisible);
            NSDictionary *completionVisible =
                MacWSPerfRingSummary(&item->completionToVisible);
            NSDictionary *visibleInterval =
                MacWSPerfRingSummary(&item->visibleIntervals);
            double producerElapsed = MacWSPerfMachMilliseconds(
                item->firstCompletionTime, item->lastCompletionTime) / 1000.0;
            double deliveredFPS = producerElapsed > 0.0 &&
                    item->uniqueFramesReceived > 1
                ? (double)(item->uniqueFramesReceived - 1) / producerElapsed
                : 0.0;
            double sequenceFPS = producerElapsed > 0.0 &&
                    item->lastSequence > item->firstSequence
                ? (double)(item->lastSequence - item->firstSequence) /
                    producerElapsed : 0.0;
            double visibleElapsed = item->lastPresentedSeconds -
                item->firstPresentedSeconds;
            double visibleFPS = visibleElapsed > 0.0 &&
                    item->uniqueFramesPresented > 1
                ? (double)(item->uniqueFramesPresented - 1) / visibleElapsed
                : 0.0;
            NSNumber *visibleP99 = visibleInterval[@"p99_ms"];
            double visibleOnePercentLow =
                [visibleP99 isKindOfClass:NSNumber.class] &&
                visibleP99.doubleValue > 0.0
                    ? 1000.0 / visibleP99.doubleValue : 0.0;
            NSDictionary *entry = @{
                @"owner_pid": @(item->ownerPID),
                @"target": @(item->target),
                @"first_sequence": @(item->firstSequence),
                @"last_sequence": @(item->lastSequence),
                @"unique_frames_received": @(item->uniqueFramesReceived),
                @"missing_sequences": @(item->missingSequences),
                @"producer_elapsed_s": @(MAX(0.0, producerElapsed)),
                @"producer_delivered_average_fps": @(deliveredFPS),
                @"producer_sequence_average_fps": @(sequenceFPS),
                @"producer_frame_interval": producerInterval,
                @"completion_to_host_receipt": transport,
                @"host_receipt_to_submission": receiptSubmission,
                @"producer_completion_to_submission": completionSubmission,
                @"submission_to_visible_callback": submissionVisible,
                @"producer_completion_to_visible_callback":
                    completionVisible,
                @"host_unique_frames_presented":
                    @(item->uniqueFramesPresented),
                @"host_visible_elapsed_s": @(MAX(0.0, visibleElapsed)),
                @"host_visible_average_fps": @(visibleFPS),
                @"host_visible_one_percent_low_fps":
                    @(visibleOnePercentLow),
                @"host_visible_frame_interval": visibleInterval,
            };
            [directDrawableSources addObject:entry];
            if (item->target) targetDirectDrawable = entry;
        }
        free(directSourcesCopy);
    }
    [directDrawableSources sortUsingComparator:^NSComparisonResult(
            NSDictionary *left, NSDictionary *right) {
        return [left[@"owner_pid"] compare:right[@"owner_pid"]];
    }];

    NSNumber *meanFrame = present[@"mean_ms"];
    NSNumber *p99Frame = present[@"p99_ms"];
    double averageFPS = [meanFrame isKindOfClass:NSNumber.class] &&
                        meanFrame.doubleValue > 0.0
        ? 1000.0 / meanFrame.doubleValue : 0.0;
    double onePercentLowFPS = [p99Frame isKindOfClass:NSNumber.class] &&
                              p99Frame.doubleValue > 0.0
        ? 1000.0 / p99Frame.doubleValue : 0.0;
    NSUInteger intervalSamples = [present[@"samples"] unsignedIntegerValue];
    double hitchRate = intervalSamples
        ? (double)hitches / intervalSamples * 100.0 : 0.0;
    NSTimeInterval elapsed = MAX(0.0,
        MacWSPerfMachMilliseconds(resetTime, mach_absolute_time()) / 1000.0);

    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    });

    return @{
        @"schema": @"macws-ui-performance-v1",
        @"reason": reason.length ? reason : @"snapshot",
        @"scene": _sceneLabel,
        @"captured_at": [formatter stringFromDate:NSDate.date],
        @"measurement_started_at": [formatter stringFromDate:resetDate],
        @"measurement_reason": resetReason,
        @"elapsed_s": @(elapsed),
        @"target": @{
            @"active_fps": @(_targetFramesPerSecond),
            @"one_percent_low_fps": @(_targetFramesPerSecond * 0.75),
            @"frame_budget_ms": @(_targetFrameMilliseconds),
            @"display_maximum_fps": @(_targetFramesPerSecond),
            @"input_to_visible_p95_ms": @50.0,
            @"active_gap_cutoff_ms": @(MacWSPerfActiveGapMilliseconds),
            @"input_active_window_ms":
                @(MacWSPerfInputActiveWindowMilliseconds),
        },
        @"presentation_transport": @{
            @"final_composite_active": @(finalCompositeActive),
            @"base_stream": @(baseTransportStreamID),
            @"base_sequence": @(baseTransportSequence),
            @"base_surface": @(baseTransportSurfaceID),
        },
        @"direct_drawable": @{
            @"target": targetDirectDrawable ?: NSNull.null,
            @"sources": directDrawableSources,
            @"scoring_metric": @"target.host_visible_average_fps",
        },
        @"visible_presentation": @{
            @"active_average_fps": @(averageFPS),
            @"one_percent_low_fps": @(onePercentLowFPS),
            @"frame_interval": present,
            @"observed_frame_interval": observedPresent,
            @"estimated_dropped_vsyncs": @(dropped),
            @"hitches_over_1_5_frames": @(hitches),
            @"hitch_rate_percent": @(hitchRate),
            @"stalls_over_50ms": @(stalls),
            @"inactive_gaps_excluded": @(inactiveGaps),
            @"stale_capture_samples_excluded": @(staleCaptureSamples),
        },
        @"pipeline": @{
            @"source_frame_interval": source,
            @"source_streams": sourceStreams,
            @"capture_to_host_receipt": captureReceipt,
            @"host_receipt_to_submit": receiptSubmit,
            @"submit_to_command_complete": submitComplete,
            @"gpu_execution": gpu,
            @"capture_to_visible_callback": capturePresent,
            @"input_dispatch_to_visible_callback": inputPresent,
            @"input_dispatch_to_visible_by_kind": inputPresentByKind,
        },
        @"counters": @{
            @"frames_received": @(framesReceived),
            @"content_frames_received": @(contentFramesReceived),
            @"geometry_updates_received": @(geometryUpdatesReceived),
            @"geometry_batches_received": @(geometryBatchesReceived),
            @"frames_submitted": @(framesSubmitted),
            @"frames_presented": @(framesPresented),
            @"direct_drawable_frames_received":
                @(directDrawableFramesReceived),
            @"direct_drawable_unique_frames_presented":
                @(directDrawableFramesPresented),
            @"direct_drawable_scheduler_ticks":
                @(directDrawableSchedulerTicks),
            @"direct_drawable_scheduler_empty_ticks":
                @(directDrawableSchedulerEmptyTicks),
            @"command_errors": @(commandErrors),
            @"inputs_attempted": @(inputsAttempted),
            @"inputs_sent": @(inputsSent),
            @"input_transport_errors": @(inputErrors),
            @"direct_input_pending_candidates": @(directInputCandidates),
            @"direct_input_rejected_before_completion":
                @(directInputRejected),
            @"direct_target_unique_submissions":
                @(directTargetSubmissions),
            @"composited_input_claims": @(compositedInputClaims),
            @"direct_input_visibility_samples": @(directInputSamples),
            @"composited_input_visibility_samples":
                @(compositedInputSamples),
            @"input_visibility_pending": @(inputVisibilityPending),
            @"pending_input_kind": @(pendingInputKind),
            @"pending_input_target_pid": @(pendingInputTargetPID),
            @"last_stream": @(lastStream),
            @"last_sequence": @(lastSequence),
        },
        @"environment": @{
            @"thermal_state": MacWSPerfThermalStateName(
                NSProcessInfo.processInfo.thermalState),
            @"system_ca_hud_level": @([MacWSPerformanceMonitor
                systemPerformanceHUDLevel]),
            @"instrumentation_active": @(instrumentationActive),
        },
        @"measurement_notes": @[
            @"Interactive FPS uses CAMetalDrawable presentation callbacks within 250 ms of Host input; gaps over 150 ms are excluded.",
            @"Observed frame interval remains available for autonomous animation/WebGL workloads that do not emit input.",
            @"Source cadence is tracked independently by producer stream/owner; the aggregate includes every active desktop layer and must not be used to score one target app.",
            @"Content IOSurface frames and lease-free layer geometry transactions have separate counters.",
            @"Input latency pairs the oldest unrepresented Host input with a subsequently completed target-owned direct drawable when present; otherwise it uses a subsequently captured target-owned frame or the authoritative WindowServer final-composite base.",
            @"Synthetic transport probes do not measure physical finger-to-UIKit recognizer latency.",
            @"Game FPS is target direct_drawable.host_visible_average_fps: only unique producer sequences that reach a real Host drawable presentation are counted; repeated presentation of one retained IOSurface is excluded.",
        ],
    };
}

- (void)updateHUD {
    if (self.HUDMode == MacWSPerformanceHUDModeOff) return;
    NSDictionary *snapshot = [self snapshotWithReason:@"hud"];
    NSDictionary *visible = snapshot[@"visible_presentation"];
    NSDictionary *pipeline = snapshot[@"pipeline"];
    NSDictionary *counters = snapshot[@"counters"];
    NSDictionary *direct = snapshot[@"direct_drawable"][@"target"];
    BOOL hasDirect = [direct isKindOfClass:NSDictionary.class] &&
        [direct[@"host_unique_frames_presented"] unsignedLongLongValue] > 1;
    double fps = hasDirect
        ? [direct[@"host_visible_average_fps"] doubleValue]
        : [visible[@"active_average_fps"] doubleValue];
    double low = hasDirect
        ? [direct[@"host_visible_one_percent_low_fps"] doubleValue]
        : [visible[@"one_percent_low_fps"] doubleValue];
    NSDictionary *frame = hasDirect
        ? direct[@"host_visible_frame_interval"]
        : visible[@"frame_interval"];
    NSString *headline = [NSString stringWithFormat:
        @"MacWS PERF   %5.1f FPS\n1%% low %5.1f  p99 %@ ms",
        fps, low, [self displayNumber:frame[@"p99_ms"]]];
    if (self.HUDMode == MacWSPerformanceHUDModeCompact) {
        _HUDLabel.text = headline;
        return;
    }
    NSDictionary *capturePresent = pipeline[@"capture_to_visible_callback"];
    NSDictionary *inputPresent = pipeline[@"input_dispatch_to_visible_callback"];
    NSDictionary *gpu = pipeline[@"gpu_execution"];
    _HUDLabel.text = [NSString stringWithFormat:
        @"%@\ncap→visible p50/p95 %@ / %@ ms\ninput→visible p50/p95 %@ / %@ ms\nGPU p50/p95 %@ / %@ ms\nhitch %.1f%%  drop %@  error %@\nthermal %@   samples %@",
        headline,
        [self displayNumber:capturePresent[@"p50_ms"]],
        [self displayNumber:capturePresent[@"p95_ms"]],
        [self displayNumber:inputPresent[@"p50_ms"]],
        [self displayNumber:inputPresent[@"p95_ms"]],
        [self displayNumber:gpu[@"p50_ms"]],
        [self displayNumber:gpu[@"p95_ms"]],
        [visible[@"hitch_rate_percent"] doubleValue],
        visible[@"estimated_dropped_vsyncs"], counters[@"command_errors"],
        snapshot[@"environment"][@"thermal_state"], frame[@"samples"]];
}

- (NSString *)displayNumber:(id)value {
    if (![value isKindOfClass:NSNumber.class]) return @"—";
    return [NSString stringWithFormat:@"%.1f", [value doubleValue]];
}

- (NSString *)exportSnapshotWithReason:(NSString *)reason
                                  error:(NSError **)error {
    NSDictionary *snapshot = [self snapshotWithReason:reason];
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
        error:error];
    if (!data) return nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = @"/var/mobile/Library/Logs/MacWSPerformance";
    if (![manager createDirectoryAtPath:directory
             withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    NSString *latest = [directory stringByAppendingPathComponent:@"latest.json"];
    if (![data writeToFile:latest options:NSDataWritingAtomic error:error])
        return nil;

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *archive = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"profile-%@.json",
         [formatter stringFromDate:NSDate.date]]];
    if (![data writeToFile:archive options:NSDataWritingAtomic error:error])
        return nil;

    NSArray<NSString *> *files = [[manager contentsOfDirectoryAtPath:directory
        error:nil] filteredArrayUsingPredicate:[NSPredicate
            predicateWithBlock:^BOOL(NSString *name,
                                     NSDictionary *bindings) {
                (void)bindings;
                return [name hasPrefix:@"profile-"] &&
                       [name hasSuffix:@".json"];
            }]];
    files = [files sortedArrayUsingSelector:@selector(compare:)];
    if (files.count > 20) {
        for (NSString *name in [files subarrayWithRange:
             NSMakeRange(0, files.count - 20)]) {
            [manager removeItemAtPath:[directory
                stringByAppendingPathComponent:name] error:nil];
        }
    }
    os_unfair_lock_lock(&_lock);
    _explicitRecording = NO;
    atomic_store(&_instrumentationActive,
        _HUDMode != MacWSPerformanceHUDModeOff);
    os_unfair_lock_unlock(&_lock);
    return archive;
}

+ (NSInteger)systemPerformanceHUDLevel {
    typedef int (*GetFlagsFn)(mach_port_t);
    typedef int (*GetValueFn)(mach_port_t, int);
    GetFlagsFn getFlags = (GetFlagsFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerGetDebugFlags");
    GetValueFn getValue = (GetValueFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerGetDebugValue");
    if (!getFlags || !getValue) return -1;
    if (!(getFlags(MACH_PORT_NULL) & MacWSQuartzCorePerformanceHUDFlag))
        return 0;
    return getValue(MACH_PORT_NULL, 1) + 1;
}

+ (BOOL)setSystemPerformanceHUDLevel:(NSInteger)level
                                error:(NSError **)error {
    typedef int (*GetFlagsFn)(mach_port_t);
    typedef void (*SetFlagsFn)(mach_port_t, int, int);
    typedef void (*SetValueFn)(mach_port_t, int, int);
    GetFlagsFn getFlags = (GetFlagsFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerGetDebugFlags");
    SetFlagsFn setFlags = (SetFlagsFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerSetDebugFlags");
    SetValueFn setValue = (SetValueFn)dlsym(RTLD_DEFAULT,
                                             "CARenderServerSetDebugValue");
    if (!getFlags || !setFlags || !setValue) {
        if (error) *error = [NSError errorWithDomain:@"MacWSPerformance"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"QuartzCore render-server debug API is unavailable"}];
        return NO;
    }
    int flags = getFlags(MACH_PORT_NULL);
    if (level > 0) {
        flags |= MacWSQuartzCorePerformanceHUDFlag;
        setValue(MACH_PORT_NULL, 1, (int)level - 1);
    } else {
        flags &= ~MacWSQuartzCorePerformanceHUDFlag;
    }
    setFlags(MACH_PORT_NULL, MacWSQuartzCorePerformanceHUDFlag, flags);
    NSInteger actual = [self systemPerformanceHUDLevel];
    if (actual != level) {
        if (error) *error = [NSError errorWithDomain:@"MacWSPerformance"
            code:2 userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    @"QuartzCore HUD requested level %ld but read back %ld",
                    (long)level, (long)actual]}];
        return NO;
    }
    return YES;
}

@end
