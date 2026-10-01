#import "MacWSMetalView.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <simd/simd.h>

#include <errno.h>
#include <mach/mach_time.h>
#include <math.h>
#include <signal.h>
#include <notify.h>
#include <objc/message.h>
#include <objc/runtime.h>

#import "MacWSCatalystDrawableCompositor.h"
#import "MacWSCatalystDrawableProbe.h"
#import "MacWSCatalystDrawableReceiver.h"
#import "MacWSHostDiagnostics.h"
#import "MacWSHostRuntime.h"
#import "MacWSKeyMapping.h"
#import "MacWSMappedFrame.h"
#import "MacWSPerformanceGestureScenario.h"
#include "macws_catalyst_drawable_protocol.h"
#include "macws_dock_expose_notify.h"
#include "macws_touch_policy.h"
#include "macws_viewport_math.h"
#include "macws_window_configuration.h"
#include "macws_resize_gesture.h"
#include "macws_keyboard_state.h"
#include "macws_keyboard_source.h"
#include "macws_process_ancestry.h"

// UIKit routes one keyboard across the app's Scenes. Keep ownership global,
// not one independent owner per captured macOS window.
static __weak MacWSMetalView *MacWSHardwareKeyboardOwner;

typedef uint32_t MacWSCAHighFrameRateReason;
#define MACWS_CA_HIGH_FRAME_RATE_REASON_MAKE(component, code) \
    ((((uint32_t)(component) & UINT32_C(0xffff)) << 16) | \
     ((uint32_t)(code) & UINT32_C(0xffff)))
static const MacWSCAHighFrameRateReason
    MacWSActiveDirectCompositeFrameRateReason =
        MACWS_CA_HIGH_FRAME_RATE_REASON_MAKE(0x4d57, 1); // "MW", active direct

static CADisplayLink *MacWSMTKDisplayLink(MTKView *view) {
    // Runtime-confirmed by misc/mtk_view_runtime_probe.m on iPad13,6 / iOS
    // 16.3.1: MTKView owns a CADisplayLink in `_displayLink` at ivar offset
    // 472 and creates it through `_createDisplayLinkForScreen:`. The public
    // preferredFramesPerSecond remained 120 while the actual scheduler made
    // only ~60 submissions/s, so configure the real scheduling boundary.
    static Ivar displayLinkIvar;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        displayLinkIvar = class_getInstanceVariable(MTKView.class,
                                                     "_displayLink");
    });
    return displayLinkIvar ? object_getIvar(view, displayLinkIvar) : nil;
}

static void MacWSConfigureMTKDisplayLinkForActiveAnimation(MTKView *view) {
    CADisplayLink *link = MacWSMTKDisplayLink(view);
    if (!link) return;
    NSInteger maximumFPS = view.window.windowScene.screen.maximumFramesPerSecond;
    if (maximumFPS <= 0)
        maximumFPS = UIScreen.mainScreen.maximumFramesPerSecond;
    NSInteger targetFPS = MAX(60, MIN(maximumFPS > 0 ? maximumFPS : 60,
                                     120));
    view.preferredFramesPerSecond = targetFPS;
    // iOS 16 MetalKit keeps a second scheduling rate in
    // `_nominalFramesPerSecond`. RE-confirmed from the live iPad13,6 method
    // bytes: -setNominalFramesPerSecond: is a single store into that ivar.
    // Keep it coherent with the public preference if UIKit left it stale.
    SEL getNominal = NSSelectorFromString(@"nominalFramesPerSecond");
    SEL setNominal = NSSelectorFromString(@"setNominalFramesPerSecond:");
    NSInteger nominalFPS = [view respondsToSelector:getNominal]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(view, getNominal) : 0;
    if (nominalFPS != targetFPS && [view respondsToSelector:setNominal]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            view, setNominal, targetFPS);
        nominalFPS = ((NSInteger (*)(id, SEL))objc_msgSend)(view, getNominal);
    }
    if (@available(iOS 15.0, *)) {
        // ProMotion's scheduler treats this as a high-frame-rate operating
        // envelope, not a fixed timer. Apple WebKit uses the same 80...120
        // shape for interactive high-refresh content: it permits phase/load
        // adaptation without falling back to the legacy 60-Hz cadence class.
        // Keep the maximum and preference panel-derived on non-120-Hz panels.
        float minimumFPS = targetFPS >= 120 ? 80.0f : (float)targetFPS;
        link.preferredFrameRateRange =
            CAFrameRateRangeMake(minimumFPS, targetFPS, targetFPS);
    } else {
        link.preferredFramesPerSecond = targetFPS;
    }
    SEL setReason = NSSelectorFromString(@"setHighFrameRateReason:");
    if ([link respondsToSelector:setReason]) {
        ((void (*)(id, SEL, MacWSCAHighFrameRateReason))objc_msgSend)(
            link, setReason, MacWSActiveDirectCompositeFrameRateReason);
    }
    static BOOL reported = NO;
    if (!reported) {
        reported = YES;
        if (@available(iOS 15.0, *)) {
            CAFrameRateRange range = link.preferredFrameRateRange;
            SEL getReason = NSSelectorFromString(@"highFrameRateReason");
            SEL getActual = NSSelectorFromString(@"actualFramesPerSecond");
            uint32_t reason = [link respondsToSelector:getReason]
                ? ((uint32_t (*)(id, SEL))objc_msgSend)(link, getReason) : 0;
            NSInteger actual = [link respondsToSelector:getActual]
                ? ((NSInteger (*)(id, SEL))objc_msgSend)(link, getActual) : 0;
            MacWSLog(@"runtime-confirmed mtk-displaylink configured "
                     "target=%ld nominal=%ld actual=%ld reason=0x%x "
                     "range=%.1f/%.1f/%.1f duration-ms=%.3f",
                     (long)targetFPS, (long)nominalFPS, (long)actual, reason,
                     range.minimum, range.maximum,
                     range.preferred, link.duration * 1000.0);
        }
    }
}

static void MacWSClearMTKDisplayLinkHighFrameRateReason(MTKView *view) {
    CADisplayLink *link = MacWSMTKDisplayLink(view);
    SEL setReason = NSSelectorFromString(@"setHighFrameRateReason:");
    if (link && [link respondsToSelector:setReason]) {
        ((void (*)(id, SEL, MacWSCAHighFrameRateReason))objc_msgSend)(
            link, setReason, 0);
    }
}

typedef NS_ENUM(uint8_t, MacWSDirectTouchState) {
    MacWSDirectTouchStateIdle = 0,
    MacWSDirectTouchStateCandidate,
    MacWSDirectTouchStateScrolling,
    MacWSDirectTouchStateLongPressArmed,
    MacWSDirectTouchStateDragging,
};

// UIKit lets a pinch/rotation recognizer begin as soon as the first two
// contacts move.  A slightly staggered third contact consequently arrives
// after that two-finger recognizer has already won, so the three-finger Dock
// pan never receives a viable sequence.  This gate keeps only the direct
// two-finger recognizers Possible for one short hardware-chord interval.  A
// real third contact begins the gate and rejects those competitors; otherwise
// it fails after the bounded interval and releases ordinary two-finger input.
@interface MacWSThreeFingerChordGateGestureRecognizer : UIGestureRecognizer
@end

@implementation MacWSThreeFingerChordGateGestureRecognizer {
    NSMutableSet<UITouch *> *_directTouches;
    NSMutableDictionary<NSValue *, NSValue *> *_initialTouchLocations;
    uint64_t _deadlineGeneration;
    BOOL _deadlineScheduled;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _directTouches = [NSMutableSet set];
        _initialTouchLocations = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)reset {
    [super reset];
    [_directTouches removeAllObjects];
    [_initialTouchLocations removeAllObjects];
    _deadlineScheduled = NO;
    _deadlineGeneration++;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (self.state != UIGestureRecognizerStatePossible) return;
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeDirect) [_directTouches addObject:touch];
    }
    if (_directTouches.count >= 3) {
        self.state = UIGestureRecognizerStateBegan;
        return;
    }
    if (_directTouches.count != 2 || _deadlineScheduled) return;
    [_initialTouchLocations removeAllObjects];
    for (UITouch *touch in _directTouches) {
        _initialTouchLocations[[NSValue valueWithNonretainedObject:touch]] =
            [NSValue valueWithCGPoint:[touch locationInView:self.view]];
    }
    _deadlineScheduled = YES;
    uint64_t generation = ++_deadlineGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(
        DISPATCH_TIME_NOW,
        (int64_t)(MACWS_THREE_FINGER_CHORD_GRACE_SECONDS * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_deadlineGeneration != generation ||
                strongSelf.state != UIGestureRecognizerStatePossible) return;
            strongSelf.state = UIGestureRecognizerStateFailed;
        });
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    if (self.state == UIGestureRecognizerStatePossible &&
        _directTouches.count == 2 && _initialTouchLocations.count == 2) {
        NSArray<UITouch *> *contacts = _directTouches.allObjects;
        CGPoint initial[2] = {CGPointZero, CGPointZero};
        CGPoint current[2] = {CGPointZero, CGPointZero};
        double maximumTravel = 0.0;
        BOOL complete = YES;
        for (NSUInteger index = 0; index < 2; index++) {
            UITouch *touch = contacts[index];
            NSValue *value = _initialTouchLocations[
                [NSValue valueWithNonretainedObject:touch]];
            if (!value) {
                complete = NO;
                break;
            }
            initial[index] = value.CGPointValue;
            current[index] = [touch locationInView:self.view];
            maximumTravel = fmax(maximumTravel,
                hypot(current[index].x - initial[index].x,
                      current[index].y - initial[index].y));
        }
        if (complete) {
            double initialSpan = hypot(initial[1].x - initial[0].x,
                                       initial[1].y - initial[0].y);
            double currentSpan = hypot(current[1].x - current[0].x,
                                       current[1].y - current[0].y);
            if (MacWSTwoFingerMotionHasCommitted(
                    maximumTravel, currentSpan - initialSpan)) {
                // Release dependencies on this same UIKit movement event.
                // UIPinch/UIPan retain their accumulated displacement and can
                // begin without waiting for the fixed chord deadline.
                self.state = UIGestureRecognizerStateFailed;
                return;
            }
        }
    }
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged)
        self.state = UIGestureRecognizerStateChanged;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) [_directTouches removeObject:touch];
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged) {
        if (_directTouches.count < 3)
            self.state = UIGestureRecognizerStateEnded;
    } else if (self.state == UIGestureRecognizerStatePossible &&
               _directTouches.count < 2) {
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [_directTouches removeAllObjects];
    self.state = (self.state == UIGestureRecognizerStateBegan ||
                  self.state == UIGestureRecognizerStateChanged)
        ? UIGestureRecognizerStateCancelled
        : UIGestureRecognizerStateFailed;
}

@end

@implementation MacWSMetalView {
    MacWSMappedFrame *_frame;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLRenderPipelineState> _opaquePipeline;
    id<MTLRenderPipelineState> _directCompositePipeline;
    id<MTLRenderPipelineState> _shadowPipeline;
    id<MTLTexture> _sourceTexture;
    MacWSPerformanceMonitor *_performanceMonitor;
    uint32_t _textureWidth;
    uint32_t _textureHeight;
    CGRect _contentRect;
    CGRect _visibleSourceRect;
    BOOL _reportedNonzeroFrame;
    BOOL _submittedPresentWitness;
    BOOL _submittedCatalystDrawableWitness;
    NSString *_lastStatus;
    NSString *_directSurfaceStatus;
    uint32_t _directSurfaceStatusWidth;
    uint32_t _directSurfaceStatusHeight;
    UIView *_directTouchIndicator;
    UIImageView *_directTouchStateGlyph;
    NSMutableArray<UIView *> *_multitouchIndicators;
    UIView *_trackpadCursorView;
    UIImageView *_trackpadStateGlyph;
    UIView *_pencilCursorView;
    UILabel *_inputUnavailableLabel;
    UIView *_tooSmallOverlay;
    UILabel *_tooSmallLabel;
    UIVisualEffectView *_zoomHUD;
    UILabel *_zoomHUDLabel;
    UIImageView *_fallbackImageView;
    CADisplayLink *_framePollDisplayLink;
    // Focused Catalyst drawables arrive independently of DisplayStream. Keep
    // the selected immutable frame across an interrupted draw, and let
    // MTKView's panel-clock scheduler consume the compositor's bounded FIFO.
    MacWSCatalystDrawableFrame *_scheduledCatalystDrawableFrame;
    BOOL _directDrawableContinuousPacing;
    CFTimeInterval _lastDirectDrawableReceiptTime;
    CFTimeInterval _directDrawableTickWitnessStart;
    NSUInteger _directDrawableTickWitnessCount;
    NSUInteger _directDrawableTickWitnessPendingCount;
    BOOL _reportedDirectDrawableTickWitness;
    uint64_t _fallbackSignature;
    BOOL _reportedFallbackFrame;
    uint64_t _pendingCaptureGeneration;
    uint64_t _presentedCaptureGeneration;
    BOOL _macWSInputEnabled;
    BOOL _windowTooSmall;
    MacWSStreamClient *_streamClient;
    MacWSSurfaceFrame *_surfaceFrame;
    id<MTLTexture> _surfaceTexture;
    NSMutableDictionary<NSNumber *, MacWSSurfaceFrame *> *_overlayFrames;
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *_overlayTextures;
    MacWSCatalystDrawableCompositor *_catalystDrawableCompositor;
    NSArray<MacWSStreamWindow *> *_latestWindows;
    NSSet<NSNumber *> *_spatialCanvasPIDs;
    NSSet<NSNumber *> *_fullscreenCanvasPIDs;
    int32_t _reportedFullscreenCanvasPID;
    uint32_t _reportedFullscreenCanvasWindowID;
    CGRect _reportedFullscreenCanvasPixels;
    // Chromium has no application-declared FullscreenCanvas capability. It
    // may still become an exact native-fullscreen canvas after its descendant
    // IOSurface has independently joined the focused catalog window at the
    // complete final-composite extent. Keep that runtime proof distinct so a
    // later window-sized drawable can revoke only the inferred capability.
    BOOL _inferredDescendantFullscreenCanvas;
    NSSet<NSNumber *> *_shadowWindowIDs;
    BOOL _directTouchUsesPrimaryDrag;
    uint64_t _surfaceTextureImports;
    uint64_t _surfaceTextureReuses;
    uint64_t _lastPerformanceLogStreamID;
    uint64_t _lastPerformanceLogSequence;
    BOOL _catalogRevalidationRequestedForPresentation;
    BOOL _targetRetirementCatalogRequeryScheduled;
    CFTimeInterval _lastDirectDrawableHeartbeatTime;
    int32_t _directDrawableHeartbeatPID;
    uint32_t _directDrawableHeartbeatLayerID;
    uint32_t _directDrawableHeartbeatWidth;
    uint32_t _directDrawableHeartbeatHeight;
    // A final-composite/direct fusion is valid only after the retained base
    // was completed at or after the latest direct-layer geometry transaction.
    // This prevents old-position desktop pixels and new-position direct
    // pixels from appearing in the same Host drawable during move/resize.
    uint64_t _directDrawableGeometryBarrierTime;
    CFTimeInterval _lastDirectDrawableCatalogRefreshTime;
    BOOL _reportedDirectDrawableJoinMiss;
    BOOL _reportedDirectDrawableExactLayerSuppression;
    BOOL _reportedDirectDrawableBaseElision;
    NSString *_pendingRenderedDrawableSnapshotPath;
    NSArray<NSNumber *> *_sortedOverlayKeys;
    NSMutableArray<MacWSSurfaceFrame *> *_retiredSurfaceFrames;
    uint64_t _submittedSurfaceLeaseToken;
    NSMutableDictionary<NSNumber *, NSNumber *> *_submittedOverlayLeaseTokens;
    BOOL _streamConnected;
    UITouch *_trackpadTouch;
    CGPoint _trackpadCursor;
    CGPoint _trackpadPreviousPoint;
    CGFloat _trackpadTravel;
    NSTimeInterval _trackpadBeganAt;
    BOOL _trackpadButtonDown;
    BOOL _trackpadHadMultipleTouches;
    BOOL _trackpadCursorWasTouched;
    BOOL _externalPointerHoverActive;
    BOOL _pencilHoverActive;
    UITouch *_pencilTouch;
    CGPoint _pencilTouchStartPoint;
    CGFloat _pencilTouchTravel;
    NSTimeInterval _pencilTouchBeganAt;
    UITouch *_directTouch;
    UITouch *_secondaryPointerTouch;
    UITouch *_primaryPointerTouch;
    UITouch *_pendingPointerDoubleTouch;
    CGPoint _primaryPointerStartPoint;
    CGFloat _primaryPointerTravel;
    NSTimeInterval _primaryPointerStartTimestamp;
    NSTimeInterval _lastPointerTapTimestamp;
    CGPoint _lastPointerTapPoint;
    int32_t _lastPointerTapPID;
    uint32_t _lastPointerTapWindowID;
    BOOL _primaryPointerDownEmitted;
    BOOL _directGestureBlocked;
    BOOL _crossAppDragModeEnabled;
    MacWSDirectTouchState _directTouchState;
    CGPoint _directTouchStartPoint;
    CGPoint _directTouchPreviousPoint;
    CGPoint _directScrollVelocity;
    CGPoint _directScrollFramePoint;
    MacWSDirectScrollAxis _directScrollAxis;
    NSTimeInterval _directTouchStartTimestamp;
    NSTimeInterval _directTouchPreviousTimestamp;
    NSTimeInterval _lastDirectTapTimestamp;
    CGPoint _lastDirectTapPoint;
    uint64_t _directTouchSerial;
    UIImpactFeedbackGenerator *_directTouchFeedback;
    CGFloat _viewportZoom;
    CGPoint _viewportCenter;
    CGFloat _fixedZoomScale;
    BOOL _contentGesturesPassthrough;
    UIPanGestureRecognizer *_twoFingerPanRecognizer;
    UIPanGestureRecognizer *_indirectScrollRecognizer;
    CGPoint _indirectScrollSampledVelocity;
    CFTimeInterval _indirectScrollPreviousTimestamp;
    CFTimeInterval _indirectScrollLastMotionTimestamp;
    NSUInteger _indirectScrollMotionSegmentCount;
    CGPoint _indirectScrollFramePoint;
    BOOL _indirectScrollFramePointValid;
    UIPinchGestureRecognizer *_pinchRecognizer;
    UIRotationGestureRecognizer *_rotationRecognizer;
    UITapGestureRecognizer *_secondaryTapRecognizer;
    MacWSThreeFingerChordGateGestureRecognizer *_threeFingerChordGate;
    UIPanGestureRecognizer *_threeFingerPanRecognizer;
    BOOL _threeFingerSystemGestureActive;
    MacWSSystemGestureAxis _threeFingerSystemGestureAxis;
    CGFloat _threeFingerSystemGestureReferenceDistance;
    uint32_t _threeFingerSystemGestureContactID;
    int32_t _threeFingerSystemGestureTargetPID;
    uint32_t _threeFingerSystemGestureFrameWidth;
    uint32_t _threeFingerSystemGestureFrameHeight;
    CGFloat _threeFingerSystemGestureLastProgress;
    CGFloat _threeFingerSystemGestureLastVelocity;
    CADisplayLink *_scrollMomentumDisplayLink;
    CGPoint _scrollMomentumVelocity;
    CGPoint _scrollMomentumFramePoint;
    CGPoint _scrollEmissionResidual;
    MacWSInputSource _scrollMomentumSource;
    CGFloat _scrollMomentumDirectionMultiplier;
    CFTimeInterval _scrollMomentumLastTimestamp;
    BOOL _scrollMomentumBegan;
    BOOL _windowConfigurationDispatchPending;
    CGSize _pendingRequestedWindowSize;
    CGFloat _pendingRequestedDensityScale;
    uint32_t _inputSampleSequence;
    BOOL _interopDragProbeActive;
    CGPoint _interopDragProbeFramePoint;
    uint32_t _interopDragProbeContactID;
    uint32_t _lastKeyboardFrameWidth;
    uint32_t _lastKeyboardFrameHeight;
    uint8_t _hardwareModifierSides;
    MacWSKeyboardSourceState _hardwareModifierSource;
    BOOL _ownsHardwareKeyboard;
    NSMutableDictionary<NSNumber *, NSData *> *_heldHardwareKeys;
    CGSize _lastRequestedWindowSize;
    CGFloat _lastRequestedDensityScale;
    CGSize _lastObservedTargetWindowLogicalSize;
    double _windowConfigurationRequestTimestamp;
    uint32_t _windowConfigurationRequestSequence;
    uint64_t _windowConfigurationSettlementSerial;
    uint64_t _constrainedWindowSettlementSerial;
    BOOL _constrainedWindowSettlementPending;
    dispatch_block_t _deferredConstrainedWindowSettlement;
    int _nativeResizeGestureToken;
    BOOL _nativeResizeGestureRegistered;
    NSString *_nativeResizeGestureScene;
    BOOL _windowConfigurationAwaitingAcknowledgement;
    BOOL _sceneResizeFollowingTargetWindow;
    uint32_t _sceneResizeFollowWindowID;
    int32_t _sceneResizeFollowOwnerPID;
    CGSize _sceneResizeTargetWindowLogicalSize;
    CFTimeInterval _sceneResizeFollowDeadline;
    BOOL _fullscreenGestureRouteActive;
    uint32_t _fullscreenGestureRouteContactID;
    int32_t _fullscreenGestureRoutePID;
    uint32_t _fullscreenGestureRouteWindowID;
    MacWSStreamFrameDescriptor _fullscreenGestureRouteDescriptor;
    CFTimeInterval _fullscreenLastTapRouteTimestamp;
    int32_t _fullscreenLastTapRoutePID;
    uint32_t _fullscreenLastTapRouteWindowID;
    MacWSStreamFrameDescriptor _fullscreenLastTapRouteDescriptor;
    BOOL _fullscreenGlobalPointerRouteActive;
    int32_t _fullscreenGlobalPointerPresentationPID;
    uint32_t _fullscreenGlobalPointerPresentationContactID;
    BOOL _acceptsCatalystDrawables;
    BOOL _streamSuspended;
    int _dockExposeStateToken;
    BOOL _scrollSuppressedByDockExpose;
}

- (instancetype)initWithFrame:(CGRect)frameRect {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frameRect device:device];
    if (!self) return nil;

    self.delegate = self;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    // Runtime-confirmed via /var/jb/var/mobile/macws-power-before.log on
    // iPad13,6: MacWSHost's dominant category is IOSurface (65 MiB), while
    // one 2388x1668 BGRA drawable is 15.2 MiB. CAMetalLayer defaults to a
    // three-drawable swap queue and the
    // Host's event-driven compositor does not encode a later frame until the
    // current surface/geometry update. Use the API-supported two-drawable
    // queue to bound each visible Scene without reducing its resolution.
    ((CAMetalLayer *)self.layer).maximumDrawableCount = 2;
    // The producer publishes acknowledged snapshots, not a live 20-fps pixel
    // stream.  Continuous MTKView drawing uploaded the unchanged 15.2-MiB
    // frame 20 times per second and runtime-measured as 13-15% App CPU.  Poll
    // only the tiny generation ACK and draw exactly once per new snapshot.
    self.enableSetNeedsDisplay = YES;
    self.paused = YES;
    // MTKView defaults to a 60-Hz presentation cadence even when drawing is
    // event-driven. The 1000-fish Aquarium runtime profile consequently
    // landed at an exact 16.67-ms median although the 120-Hz stream-delivery
    // link and producer were both faster. Keep the view paused between frame
    // events, but let each real new surface present at the panel's supported
    // cadence instead of silently coalescing two 120-Hz updates into one.
    NSInteger maximumFramesPerSecond = UIScreen.mainScreen.maximumFramesPerSecond;
    self.preferredFramesPerSecond = MAX(
        60, MIN(maximumFramesPerSecond > 0 ? maximumFramesPerSecond : 60,
                120));
    MacWSLog(@"presentation-cadence event-driven preferred-fps=%ld "
             "panel-maximum-fps=%ld",
             (long)self.preferredFramesPerSecond,
             (long)maximumFramesPerSecond);
    // Own drawable sizing explicitly. The adaptive policy preserves the
    // producer's pixels for the desktop, while a validated fullscreen canvas
    // uses one output pixel per UIKit point so a game does not pay for a
    // second high-resolution presentation pass.
    self.autoResizeDrawable = NO;
    self.clearColor = MTLClearColorMake(0.025, 0.028, 0.035, 1.0);
    self.multipleTouchEnabled = YES;
    self.inputMode = MacWSHostInputModeDirect;
    self.fixedZoomScale = 1.5;
    self.displayDensity = MacWSHostDisplayDensityRetinaStandard;
    // Status polling enables interaction only after WindowServer, the input
    // socket and an exact-PID acknowledged frame are all present.  A stale
    // screenshot must never look like a live, touchable workspace.
    self.userInteractionEnabled = NO;

    _frame = [MacWSMappedFrame new];
    _streamClient = [MacWSStreamClient new];
    _streamClient.delegate = self;
    _overlayFrames = [NSMutableDictionary dictionary];
    _overlayTextures = [NSMutableDictionary dictionary];
    _catalystDrawableCompositor =
        [[MacWSCatalystDrawableCompositor alloc] initWithDevice:device];
    _retiredSurfaceFrames = [NSMutableArray array];
    _submittedOverlayLeaseTokens = [NSMutableDictionary dictionary];
    _commandQueue = [device newCommandQueue];
    _commandQueue.label = @"MacWSHost display queue";
    _performanceMonitor = [[MacWSPerformanceMonitor alloc]
        initWithSceneLabel:[NSString stringWithFormat:@"scene-%p", self]];
    _contentRect = CGRectZero;
    _visibleSourceRect = CGRectMake(0, 0, 1, 1);
    _trackpadCursor = CGPointMake(-1, -1);
    _viewportZoom = 1.0;
    _viewportCenter = CGPointMake(0.5, 0.5);
    _directTouchState = MacWSDirectTouchStateIdle;
    _dockExposeStateToken = -1;
    _directTouchFeedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    MacWSStartCatalystDrawableReceiver();
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(catalystDrawableDidPresent:)
        name:MacWSCatalystDrawableDidPresentNotification object:nil];

    // Direct touch uses a soft contact halo.  It is deliberately different
    // from the trackpad cursor: one represents the finger's absolute contact,
    // the other represents persistent relative-pointer state.
    _directTouchIndicator = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 30, 30)];
    _directTouchIndicator.backgroundColor =
        [UIColor.systemCyanColor colorWithAlphaComponent:0.15];
    _directTouchIndicator.layer.borderWidth = 1.5;
    _directTouchIndicator.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.82].CGColor;
    _directTouchIndicator.layer.cornerRadius = 15;
    _directTouchIndicator.layer.shadowColor = UIColor.blackColor.CGColor;
    _directTouchIndicator.layer.shadowOpacity = 0.22;
    _directTouchIndicator.layer.shadowRadius = 5;
    _directTouchIndicator.layer.shadowOffset = CGSizeMake(0, 2);
    _directTouchIndicator.userInteractionEnabled = NO;
    _directTouchIndicator.hidden = YES;
    UIView *contactDot = [[UIView alloc] initWithFrame:CGRectMake(11, 11, 8, 8)];
    contactDot.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.92];
    contactDot.layer.cornerRadius = 4;
    contactDot.userInteractionEnabled = NO;
    [_directTouchIndicator addSubview:contactDot];
    contactDot.tag = 501;
    _directTouchStateGlyph = [[UIImageView alloc] initWithFrame:
        CGRectMake(7, 7, 16, 16)];
    _directTouchStateGlyph.contentMode = UIViewContentModeScaleAspectFit;
    _directTouchStateGlyph.tintColor = UIColor.whiteColor;
    _directTouchStateGlyph.hidden = YES;
    _directTouchStateGlyph.userInteractionEnabled = NO;
    [_directTouchIndicator addSubview:_directTouchStateGlyph];
    [self addSubview:_directTouchIndicator];
    _multitouchIndicators = [NSMutableArray array];

    // A finger-driven relative trackpad uses the same circular MacWS pointer
    // language advertised by the control center. The previous black macOS
    // arrow duplicated the real cursor presentation and was visibly mistaken
    // for a cursor leaking out of the WindowServer final composite. Hardware
    // Magic Keyboard pointers keep UIKit's native adaptive pointer and do not
    // draw this overlay.
    _trackpadCursorView = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 24, 24)];
    _trackpadCursorView.backgroundColor =
        [UIColor.systemGrayColor colorWithAlphaComponent:0.74];
    _trackpadCursorView.layer.cornerRadius = 12.0;
    _trackpadCursorView.layer.borderWidth = 1.0;
    _trackpadCursorView.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.88].CGColor;
    _trackpadCursorView.layer.shadowColor = UIColor.blackColor.CGColor;
    _trackpadCursorView.layer.shadowOpacity = 0.30;
    _trackpadCursorView.layer.shadowRadius = 3.0;
    _trackpadCursorView.layer.shadowOffset = CGSizeMake(0, 1.5);
    _trackpadCursorView.userInteractionEnabled = NO;
    _trackpadCursorView.hidden = YES;
    _trackpadStateGlyph = [[UIImageView alloc] initWithFrame:
        CGRectMake(5, 5, 14, 14)];
    _trackpadStateGlyph.contentMode = UIViewContentModeScaleAspectFit;
    _trackpadStateGlyph.tintColor = UIColor.whiteColor;
    _trackpadStateGlyph.image = [UIImage systemImageNamed:
        @"hand.point.up.left.fill"];
    _trackpadStateGlyph.hidden = YES;
    _trackpadStateGlyph.userInteractionEnabled = NO;
    [_trackpadCursorView addSubview:_trackpadStateGlyph];
    [self addSubview:_trackpadCursorView];

    // Pencil hover follows iPad's precise-pointer visual language. Native
    // in-air updates arrive only on hover-capable hardware; contact movement
    // remains a non-clicking preview on older iPads until a short tap ends.
    _pencilCursorView = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, 20, 20)];
    _pencilCursorView.backgroundColor =
        [UIColor.systemGrayColor colorWithAlphaComponent:0.72];
    _pencilCursorView.layer.borderWidth = 1.0;
    _pencilCursorView.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.90].CGColor;
    _pencilCursorView.layer.cornerRadius = 10;
    _pencilCursorView.layer.shadowColor = UIColor.blackColor.CGColor;
    _pencilCursorView.layer.shadowOpacity = 0.28;
    _pencilCursorView.layer.shadowRadius = 4;
    _pencilCursorView.layer.shadowOffset = CGSizeMake(0, 1.5);
    _pencilCursorView.userInteractionEnabled = NO;
    _pencilCursorView.hidden = YES;
    [self addSubview:_pencilCursorView];

    _inputUnavailableLabel = [UILabel new];
    _inputUnavailableLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _inputUnavailableLabel.text = @"触控暂不可用 · macOS 工作区未就绪";
    _inputUnavailableLabel.textColor = UIColor.whiteColor;
    _inputUnavailableLabel.backgroundColor =
        [UIColor.systemOrangeColor colorWithAlphaComponent:0.88];
    _inputUnavailableLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _inputUnavailableLabel.textAlignment = NSTextAlignmentCenter;
    _inputUnavailableLabel.numberOfLines = 0;
    _inputUnavailableLabel.layer.cornerRadius = 12;
    _inputUnavailableLabel.clipsToBounds = YES;
    _inputUnavailableLabel.userInteractionEnabled = NO;
    [self addSubview:_inputUnavailableLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_inputUnavailableLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_inputUnavailableLabel.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor
                                                            constant:-18],
        [_inputUnavailableLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor
                                                                    multiplier:0.82],
        [_inputUnavailableLabel.heightAnchor constraintGreaterThanOrEqualToConstant:38],
    ]];

    _tooSmallOverlay = [UIView new];
    _tooSmallOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    _tooSmallOverlay.backgroundColor =
        [UIColor.systemBackgroundColor colorWithAlphaComponent:0.98];
    _tooSmallOverlay.hidden = YES;
    _tooSmallOverlay.userInteractionEnabled = NO;
    [self addSubview:_tooSmallOverlay];
    _tooSmallLabel = [UILabel new];
    _tooSmallLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _tooSmallLabel.numberOfLines = 0;
    _tooSmallLabel.textAlignment = NSTextAlignmentCenter;
    _tooSmallLabel.textColor = UIColor.labelColor;
    _tooSmallLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [_tooSmallOverlay addSubview:_tooSmallLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_tooSmallOverlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_tooSmallOverlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_tooSmallOverlay.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_tooSmallOverlay.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_tooSmallLabel.centerXAnchor constraintEqualToAnchor:_tooSmallOverlay.centerXAnchor],
        [_tooSmallLabel.centerYAnchor constraintEqualToAnchor:_tooSmallOverlay.centerYAnchor],
        [_tooSmallLabel.widthAnchor constraintLessThanOrEqualToAnchor:_tooSmallOverlay.widthAnchor
                                                             multiplier:0.82],
    ]];

    _zoomHUD = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    _zoomHUD.translatesAutoresizingMaskIntoConstraints = NO;
    _zoomHUD.layer.cornerRadius = 13;
    _zoomHUD.clipsToBounds = YES;
    _zoomHUD.hidden = YES;
    [self addSubview:_zoomHUD];
    _zoomHUDLabel = [UILabel new];
    _zoomHUDLabel.font = [UIFont monospacedDigitSystemFontOfSize:12
                                                         weight:UIFontWeightSemibold];
    _zoomHUDLabel.textColor = UIColor.labelColor;
    _zoomHUDLabel.textAlignment = NSTextAlignmentCenter;
    [_zoomHUDLabel.widthAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;
    UIStackView *zoomHUDContent = [[UIStackView alloc]
        initWithArrangedSubviews:@[_zoomHUDLabel]];
    zoomHUDContent.translatesAutoresizingMaskIntoConstraints = NO;
    zoomHUDContent.axis = UILayoutConstraintAxisHorizontal;
    zoomHUDContent.alignment = UIStackViewAlignmentCenter;
    zoomHUDContent.spacing = 7;
    zoomHUDContent.layoutMargins = UIEdgeInsetsMake(7, 9, 7, 9);
    zoomHUDContent.layoutMarginsRelativeArrangement = YES;
    [_zoomHUD.contentView addSubview:zoomHUDContent];
    [NSLayoutConstraint activateConstraints:@[
        [_zoomHUD.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor
                                                 constant:-12],
        [_zoomHUD.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor
                                            constant:12],
        [zoomHUDContent.leadingAnchor constraintEqualToAnchor:_zoomHUD.contentView.leadingAnchor],
        [zoomHUDContent.trailingAnchor constraintEqualToAnchor:_zoomHUD.contentView.trailingAnchor],
        [zoomHUDContent.topAnchor constraintEqualToAnchor:_zoomHUD.contentView.topAnchor],
        [zoomHUDContent.bottomAnchor constraintEqualToAnchor:_zoomHUD.contentView.bottomAnchor],
    ]];

    if (device) {
        [self buildPipeline];
    } else {
        self.paused = YES;
        _fallbackImageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _fallbackImageView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _fallbackImageView.backgroundColor = UIColor.blackColor;
        _fallbackImageView.contentMode = UIViewContentModeScaleAspectFit;
        _fallbackImageView.clipsToBounds = YES;
        _fallbackImageView.userInteractionEnabled = NO;
        [self insertSubview:_fallbackImageView atIndex:0];
        MacWSLog(@"native Metal device unavailable; UIKit fallback armed");
    }

    _framePollDisplayLink = [CADisplayLink displayLinkWithTarget:self
        selector:@selector(pollSharedFrame:)];
    _framePollDisplayLink.preferredFramesPerSecond = 5;
    _framePollDisplayLink.paused = !MacWSLegacyFramebufferFallbackEnabled();
    [_framePollDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                               forMode:NSRunLoopCommonModes];

    if (@available(iOS 13.4, *)) {
        UIHoverGestureRecognizer *hover =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(hovered:)];
        hover.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:hover];
        UIHoverGestureRecognizer *pencilHover =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(pencilHovered:)];
        pencilHover.allowedTouchTypes = @[@(UITouchTypePencil)];
        [self addGestureRecognizer:pencilHover];
    }
    _twoFingerPanRecognizer = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(twoFingerPanned:)];
    _twoFingerPanRecognizer.minimumNumberOfTouches = 2;
    _twoFingerPanRecognizer.maximumNumberOfTouches = 2;
    _twoFingerPanRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
    if (@available(iOS 13.4, *))
        _twoFingerPanRecognizer.allowedScrollTypesMask = 0;
    _twoFingerPanRecognizer.cancelsTouchesInView = YES;
    _twoFingerPanRecognizer.delegate = self;
    [self addGestureRecognizer:_twoFingerPanRecognizer];
    if (@available(iOS 13.4, *)) {
        // A Magic Keyboard trackpad or mouse wheel is a UIKit scroll event,
        // not two UITouch contacts.  The old two-finger recognizer required
        // exactly two touches and therefore could never receive this input.
        // Apple's supported split is an independent pan recognizer with the
        // desired scroll mask and an empty allowedTouchTypes set; direct
        // fingers remain exclusively owned by the recognizer above.
        _indirectScrollRecognizer = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(indirectScrolled:)];
        _indirectScrollRecognizer.allowedTouchTypes = @[];
        _indirectScrollRecognizer.allowedScrollTypesMask = UIScrollTypeMaskAll;
        _indirectScrollRecognizer.cancelsTouchesInView = NO;
        _indirectScrollRecognizer.delegate = self;
        [self addGestureRecognizer:_indirectScrollRecognizer];
    }
    _pinchRecognizer = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(pinched:)];
    _pinchRecognizer.cancelsTouchesInView = YES;
    _pinchRecognizer.delegate = self;
    [self addGestureRecognizer:_pinchRecognizer];
    _rotationRecognizer = [[UIRotationGestureRecognizer alloc]
        initWithTarget:self action:@selector(rotated:)];
    // Do not restrict allowedTouchTypes here. UIKit's rotation recognizer is
    // the supported common boundary for both direct fingers and the Magic
    // Keyboard/trackpad's indirect two-finger rotation stream.
    _rotationRecognizer.cancelsTouchesInView = YES;
    _rotationRecognizer.delegate = self;
    [self addGestureRecognizer:_rotationRecognizer];
    _threeFingerChordGate =
        [[MacWSThreeFingerChordGateGestureRecognizer alloc]
            initWithTarget:self action:@selector(threeFingerChordChanged:)];
    _threeFingerChordGate.allowedTouchTypes = @[@(UITouchTypeDirect)];
    _threeFingerChordGate.cancelsTouchesInView = YES;
    _threeFingerChordGate.delegate = self;
    [self addGestureRecognizer:_threeFingerChordGate];
    _threeFingerPanRecognizer = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(threeFingerPanned:)];
    _threeFingerPanRecognizer.minimumNumberOfTouches = 3;
    _threeFingerPanRecognizer.maximumNumberOfTouches = 3;
    _threeFingerPanRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
    _threeFingerPanRecognizer.cancelsTouchesInView = YES;
    _threeFingerPanRecognizer.delegate = self;
    [self addGestureRecognizer:_threeFingerPanRecognizer];
    [_twoFingerPanRecognizer
        requireGestureRecognizerToFail:_threeFingerChordGate];
    [_pinchRecognizer requireGestureRecognizerToFail:_threeFingerChordGate];
    [_rotationRecognizer requireGestureRecognizerToFail:_threeFingerChordGate];
    UITapGestureRecognizer *resetZoom = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(viewportZoomToggled:)];
    resetZoom.numberOfTouchesRequired = 2;
    resetZoom.numberOfTapsRequired = 2;
    resetZoom.cancelsTouchesInView = YES;
    [self addGestureRecognizer:resetZoom];
    _secondaryTapRecognizer = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(trackpadSecondaryTapped:)];
    _secondaryTapRecognizer.numberOfTouchesRequired = 2;
    _secondaryTapRecognizer.cancelsTouchesInView = NO;
    [_secondaryTapRecognizer requireGestureRecognizerToFail:resetZoom];
    [self addGestureRecognizer:_secondaryTapRecognizer];
    return self;
}

- (void)dealloc {
    if (_nativeResizeGestureRegistered) notify_cancel(_nativeResizeGestureToken);
    if (_dockExposeStateToken >= 0) notify_cancel(_dockExposeStateToken);
    [NSNotificationCenter.defaultCenter removeObserver:self
        name:MacWSCatalystDrawableDidPresentNotification object:nil];
    [_framePollDisplayLink invalidate];
    [_scrollMomentumDisplayLink invalidate];
    if (_surfaceFrame) [_streamClient releaseFrame:_surfaceFrame];
    for (MacWSSurfaceFrame *frame in _overlayFrames.allValues)
        [_streamClient releaseFrame:frame];
    for (MacWSSurfaceFrame *frame in _retiredSurfaceFrames)
        [_streamClient releaseFrame:frame];
    [_streamClient invalidate];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    UIWindowScene *scene = self.window.windowScene;
    SEL identifier = NSSelectorFromString(@"_sceneIdentifier");
    NSString *sceneID = [scene respondsToSelector:identifier]
        ? ((id (*)(id, SEL))objc_msgSend)(scene, identifier) : nil;
    if ([_nativeResizeGestureScene isEqualToString:sceneID]) return;
    if (_nativeResizeGestureRegistered) notify_cancel(_nativeResizeGestureToken);
    _nativeResizeGestureRegistered = NO;
    _nativeResizeGestureScene = [sceneID copy];
    if (!sceneID.length) return;
    NSString *name = [@MACWS_RESIZE_GESTURE_NOTIFICATION_PREFIX stringByAppendingString:sceneID];
    __weak typeof(self) weakSelf = self;
    uint32_t status = notify_register_dispatch(name.UTF8String,
        &_nativeResizeGestureToken, dispatch_get_main_queue(), ^(int token) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->_nativeResizeGestureRegistered ||
                token != strongSelf->_nativeResizeGestureToken) return;
            BOOL active = strongSelf.nativeWindowResizeGestureActive;
            MacWSDiagnosticLog(@"native-resize-gesture scene=%@ window=%u active=%@",
                strongSelf->_nativeResizeGestureScene, strongSelf.targetWindowID,
                active ? @"YES" : @"NO");
            if (active) {
                [strongSelf cancelSceneResizeFollowingTargetWindow];
            } else {
                // Let the end response's last UIKit bounds commit first.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 32 * NSEC_PER_MSEC),
                    dispatch_get_main_queue(), ^{
                        [weakSelf completeConstrainedWindowSettlementIfIdle];
                    });
            }
        });
    _nativeResizeGestureRegistered = status == NOTIFY_STATUS_OK;
    if (!_nativeResizeGestureRegistered)
        MacWSLog(@"native-resize-gesture registration-failed scene=%@ status=%u", sceneID, status);
}

- (BOOL)nativeWindowResizeGestureActive {
    uint64_t state = 0;
    if (!_nativeResizeGestureRegistered ||
        notify_get_state(_nativeResizeGestureToken, &state) != NOTIFY_STATUS_OK ||
        !MacWSResizeGestureIsActive(state)) return NO;
    pid_t writer = (pid_t)MacWSResizeGestureWriter(state);
    return kill(writer, 0) == 0 || errno == EPERM;
}

- (void)completeConstrainedWindowSettlementIfIdle {
    if (self.nativeWindowResizeGestureActive) return;
    dispatch_block_t settlement = _deferredConstrainedWindowSettlement;
    _deferredConstrainedWindowSettlement = nil;
    if (settlement) settlement();
}

- (void)catalystDrawableDidPresent:(NSNotification *)notification {
    // The receiver is process-global, while a MacWSHost process can retain
    // several UIWindowScenes.  Only a foreground Scene with an active stream
    // may claim the producer's single transferred IOSurface use count. The
    // receiver has already authenticated record.producerPID against the Mach
    // audit trailer; this Scene only accepts the logical focused owner.
    if (!_acceptsCatalystDrawables) return;
    __weak typeof(self) weakSelf = self;
    MacWSCatalystDrawableFrame *accepted =
        [_catalystDrawableCompositor consumeDeliveryObject:notification.object
            shouldAcceptOwner:^BOOL(int32_t ownerPID) {
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return NO;
                if (strongSelf.targetPID == ownerPID) return YES;
                if (strongSelf.targetWindowID != 0) return NO;
                for (MacWSSurfaceFrame *frame in
                        strongSelf->_overlayFrames.allValues) {
                    if (frame.descriptor.layerOwnerPID == ownerPID) return YES;
                }
                return NO;
            }];
    if (!accepted) return;

    MacWSCatalystDrawableRecord direct = accepted.record;
    BOOL descendantProducer = direct.producerPID != direct.ownerPID;
    int32_t logicalOwnerPID = direct.ownerPID;
    uint64_t directReceiptTime = mach_absolute_time();
    [_performanceMonitor
        recordDirectDrawableReceivedForOwnerPID:logicalOwnerPID
        sequence:direct.sequence
        completionTime:direct.completionTime
        receiptTime:directReceiptTime
        isTarget:self.targetPID == logicalOwnerPID];

    // Suppress redundant capture only after joining the direct surface to a
    // live focused catalog identity. PID alone is not sufficient: one process
    // can own menus, launch windows and the game window simultaneously. A
    // native fullscreen drawable may use its configured render resolution;
    // a Chromium GPU child must also match the focused window dimensions.
    // displayd independently validates the same owner/window/focus geometry.
    uint32_t canvasWidth = _surfaceFrame.descriptor.contentWidth;
    uint32_t canvasHeight = _surfaceFrame.descriptor.contentHeight;
    uint32_t matchedWindowID = 0;
    NSString *identitySource = nil;
    if (!descendantProducer &&
        _reportedFullscreenCanvasPID == logicalOwnerPID &&
        _reportedFullscreenCanvasWindowID != 0) {
        matchedWindowID = _reportedFullscreenCanvasWindowID;
        identitySource = @"retained-live-fullscreen-canvas";
    }
    uint64_t matchedScore = 0;
    for (MacWSStreamWindow *window in
            (matchedWindowID == 0 ? _latestWindows : @[])) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        if (descriptor.ownerPID != logicalOwnerPID ||
            descriptor.windowID == 0 ||
            (descriptor.flags & MacWSStreamWindowFocused) == 0 ||
            (_targetWindowID != 0 &&
             descriptor.windowID != _targetWindowID)) continue;
        BOOL fullscreenCanvas = (descriptor.flags &
            MacWSStreamWindowFullscreenCanvas) != 0;
        MacWSStreamWindowFlags ordinaryRequired =
            MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
        MacWSStreamWindowFlags spaceTransitionRequired =
            MacWSStreamWindowFocused | MacWSStreamWindowVisible |
            MacWSStreamWindowFrontmostApplication;
        BOOL focusedSpaceTransition = descendantProducer &&
            !fullscreenCanvas && self.targetPID == logicalOwnerPID &&
            self.targetWindowID == 0 && [self hasFinalCompositeFrame] &&
            (descriptor.flags & spaceTransitionRequired) ==
                spaceTransitionRequired;
        if (!fullscreenCanvas &&
            (!descendantProducer ||
             ((descriptor.flags & ordinaryRequired) != ordinaryRequired &&
              !focusedSpaceTransition)))
            continue;
        if (descendantProducer && !fullscreenCanvas) {
            uint64_t widthDifference = direct.width > descriptor.pixelWidth
                ? direct.width - descriptor.pixelWidth
                : descriptor.pixelWidth - direct.width;
            uint64_t heightDifference = direct.height > descriptor.pixelHeight
                ? direct.height - descriptor.pixelHeight
                : descriptor.pixelHeight - direct.height;
            // A descendant Chromium drawable is the exact client IOSurface,
            // not a scalable preview.  The old 20% tolerance joined a new
            // resize generation to stale window geometry and let retained
            // pixels overwrite a correct final composite.  Only tolerate
            // the bounded backing-scale rounding shared with displayd.
            if (descriptor.pixelWidth == 0 || descriptor.pixelHeight == 0 ||
                widthDifference >
                    MACWS_DIRECT_DRAWABLE_GEOMETRY_TOLERANCE_PIXELS ||
                heightDifference >
                    MACWS_DIRECT_DRAWABLE_GEOMETRY_TOLERANCE_PIXELS) continue;
        }
        uint64_t score = (uint64_t)descriptor.pixelWidth *
            (uint64_t)descriptor.pixelHeight;
        if (score > matchedScore) {
            matchedScore = score;
            matchedWindowID = descriptor.windowID;
            identitySource = fullscreenCanvas
                ? @"focused-fullscreen-catalog"
                : @"focused-descendant-layer-catalog";
        }
    }
    if (matchedWindowID == 0 &&
        self.targetPID == logicalOwnerPID &&
        self.targetWindowID != 0 &&
        [_fullscreenCanvasPIDs containsObject:@(direct.ownerPID)] &&
        MacWSAppInputEndpointReady(direct.ownerPID) &&
        [self hasFinalCompositeFrame] &&
        canvasWidth != 0 && canvasHeight != 0) {
        // The controller has already selected this exact window from a
        // Focused|FullscreenCanvas catalog record and retains it only while
        // the same AppInput endpoint is alive.  R19 runtime evidence shows
        // SkyLight can retire every corresponding surface before the delayed
        // direct-drawable activation, so MacWSMetalView never gets a
        // simultaneous layer from which to establish its own cache.  Join
        // the same validated target identity here; FullscreenCanvas makes the
        // final-composite extent, rather than the retired backing size, the
        // semantic destination.
        matchedWindowID = self.targetWindowID;
        identitySource = @"retained-targeted-fullscreen-endpoint";
        _reportedFullscreenCanvasPID = direct.ownerPID;
        _reportedFullscreenCanvasWindowID = matchedWindowID;
        _reportedFullscreenCanvasPixels =
            CGRectMake(0, 0, canvasWidth, canvasHeight);
    }
    uint64_t canvasWidthDifference = direct.width > canvasWidth
        ? direct.width - canvasWidth : canvasWidth - direct.width;
    uint64_t canvasHeightDifference = direct.height > canvasHeight
        ? direct.height - canvasHeight : canvasHeight - direct.height;
    BOOL inferredDescendantFullscreenCanvas = descendantProducer &&
        matchedWindowID != 0 && logicalOwnerPID == self.targetPID &&
        self.targetWindowID == 0 && [self hasFinalCompositeFrame] &&
        MacWSAppInputEndpointReady(logicalOwnerPID) &&
        [identitySource isEqualToString:
            @"focused-descendant-layer-catalog"] &&
        canvasWidth != 0 && canvasHeight != 0 &&
        canvasWidthDifference <=
            MACWS_DIRECT_DRAWABLE_GEOMETRY_TOLERANCE_PIXELS &&
        canvasHeightDifference <=
            MACWS_DIRECT_DRAWABLE_GEOMETRY_TOLERANCE_PIXELS;
    if (inferredDescendantFullscreenCanvas) {
        if (!_inferredDescendantFullscreenCanvas ||
            _reportedFullscreenCanvasPID != logicalOwnerPID ||
            _reportedFullscreenCanvasWindowID != matchedWindowID) {
            MacWSLog(@"runtime-confirmed descendant-fullscreen-canvas "
                     "pid=%d window=%u drawable=%ux%u canvas=%ux%u "
                     "source=strict-focused-catalog-join",
                     logicalOwnerPID, matchedWindowID,
                     direct.width, direct.height, canvasWidth, canvasHeight);
        }
        _inferredDescendantFullscreenCanvas = YES;
        NSMutableSet<NSNumber *> *capabilities =
            [_fullscreenCanvasPIDs mutableCopy] ?: [NSMutableSet set];
        [capabilities addObject:@(logicalOwnerPID)];
        _fullscreenCanvasPIDs = [capabilities copy];
        _reportedFullscreenCanvasPID = logicalOwnerPID;
        _reportedFullscreenCanvasWindowID = matchedWindowID;
        _reportedFullscreenCanvasPixels =
            CGRectMake(0, 0, canvasWidth, canvasHeight);
    } else if (_inferredDescendantFullscreenCanvas &&
               logicalOwnerPID == self.targetPID) {
        BOOL explicitFullscreenCapability = NO;
        for (MacWSStreamWindow *window in _latestWindows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            if (descriptor.ownerPID == logicalOwnerPID &&
                (descriptor.flags & MacWSStreamWindowFullscreenCanvas) != 0) {
                explicitFullscreenCapability = YES;
                break;
            }
        }
        _inferredDescendantFullscreenCanvas = NO;
        if (!explicitFullscreenCapability) {
            NSMutableSet<NSNumber *> *capabilities =
                [_fullscreenCanvasPIDs mutableCopy] ?: [NSMutableSet set];
            [capabilities removeObject:@(logicalOwnerPID)];
            _fullscreenCanvasPIDs = [capabilities copy];
            if (_reportedFullscreenCanvasPID == logicalOwnerPID) {
                _reportedFullscreenCanvasPID = 0;
                _reportedFullscreenCanvasWindowID = 0;
                _reportedFullscreenCanvasPixels = CGRectZero;
            }
        }
        MacWSLog(@"descendant-fullscreen-canvas cleared pid=%d "
                 "drawable=%ux%u canvas=%ux%u explicit=%@",
                 logicalOwnerPID, direct.width, direct.height,
                 canvasWidth, canvasHeight,
                 explicitFullscreenCapability ? @"YES" : @"NO");
    }
    if (matchedWindowID != 0 && canvasWidth != 0 && canvasHeight != 0) {
        CFTimeInterval now = CACurrentMediaTime();
        BOOL identityChanged =
            _directDrawableHeartbeatPID != logicalOwnerPID ||
            _directDrawableHeartbeatLayerID != matchedWindowID;
        BOOL geometryChanged =
            _directDrawableHeartbeatWidth != direct.width ||
            _directDrawableHeartbeatHeight != direct.height;
        if (identityChanged || geometryChanged ||
            now - _lastDirectDrawableHeartbeatTime >= 0.25) {
            _lastDirectDrawableHeartbeatTime = now;
            _directDrawableHeartbeatPID = logicalOwnerPID;
            _directDrawableHeartbeatLayerID = matchedWindowID;
            _directDrawableHeartbeatWidth = direct.width;
            _directDrawableHeartbeatHeight = direct.height;
            if (identityChanged || geometryChanged) {
                _directDrawableGeometryBarrierTime = MAX(
                    _directDrawableGeometryBarrierTime, directReceiptTime);
            }
            // A CAMetalLayer resize can leave completed old-size records in
            // the bounded presentation FIFO. They remain valid IOSurfaces,
            // but no longer belong to this geometry generation. Drop a
            // selected predecessor now; the scheduler below also filters the
            // remaining FIFO by the newly joined heartbeat dimensions.
            if (geometryChanged) _scheduledCatalystDrawableFrame = nil;
            if (identityChanged || geometryChanged) {
                MacWSLog(@"direct-drawable-heartbeat pid=%d layer=%u "
                         "drawable=%ux%u canvas=%ux%u "
                         "identity=%@",
                         logicalOwnerPID, matchedWindowID,
                         direct.width, direct.height,
                         canvasWidth, canvasHeight, identitySource);
            }
            [_streamClient noteDirectDrawableForOwnerPID:logicalOwnerPID
                                           layerWindowID:matchedWindowID
                                                   width:direct.width
                                                  height:direct.height];
        }
        _reportedDirectDrawableJoinMiss = NO;
        _lastDirectDrawableCatalogRefreshTime = 0.0;
    } else {
        if (!_reportedDirectDrawableJoinMiss) {
            _reportedDirectDrawableJoinMiss = YES;
            NSMutableArray<NSString *> *candidates = [NSMutableArray array];
            for (MacWSStreamWindow *window in _latestWindows) {
                MacWSStreamWindowDescriptor descriptor = window.descriptor;
                if (descriptor.ownerPID != logicalOwnerPID) continue;
                [candidates addObject:[NSString stringWithFormat:
                    @"%u:flags=0x%x/%ux%u", descriptor.windowID,
                    descriptor.flags, descriptor.pixelWidth,
                    descriptor.pixelHeight]];
            }
            MacWSLog(@"direct-drawable-join-miss pid=%d drawable=%ux%u "
                     "canvas=%ux%u catalog-candidates=%@",
                     logicalOwnerPID, direct.width, direct.height,
                     canvasWidth, canvasHeight, candidates);
        }
        // A drawable resize can precede both the unsolicited AppKit catalog
        // broadcast and fullscreen layer reconciliation. The exact geometry
        // join must remain fail-closed, but the completed new-size drawable
        // is itself a bounded reason to refresh those authorities. Without
        // this barrier the Host retained a 1700x1040 catalog indefinitely
        // while Chromium was already publishing 1600x1000, so no activity
        // heartbeat could reach displayd and the direct path could never
        // recover. Coalesce producer-rate notifications to at most 4 Hz.
        CFTimeInterval refreshTime = CACurrentMediaTime();
        if (logicalOwnerPID == self.targetPID &&
            refreshTime - _lastDirectDrawableCatalogRefreshTime >= 0.25) {
            _lastDirectDrawableCatalogRefreshTime = refreshTime;
            [_streamClient requestWindowList];
        }
        if (_directDrawableHeartbeatPID == logicalOwnerPID) {
            MacWSLog(@"direct-drawable-authority-cleared pid=%d layer=%u "
                     "reason=join-miss",
                     logicalOwnerPID, _directDrawableHeartbeatLayerID);
            [_streamClient clearDirectDrawableActivity];
            _lastDirectDrawableHeartbeatTime = 0.0;
            _directDrawableHeartbeatPID = 0;
            _directDrawableHeartbeatLayerID = 0;
            _directDrawableHeartbeatWidth = 0;
            _directDrawableHeartbeatHeight = 0;
            _scheduledCatalystDrawableFrame = nil;
            if (_directDrawableContinuousPacing) {
                _directDrawableContinuousPacing = NO;
                self.paused = YES;
                MacWSClearMTKDisplayLinkHighFrameRateReason(self);
                self.enableSetNeedsDisplay = YES;
                ((CAMetalLayer *)self.layer).maximumDrawableCount = 2;
            }
        }
    }
    // Runtime-confirmed by aquarium-1k-focused-direct-v3.json on
    // 2026-09-30: the authenticated producer delivered 1,402 unique frames
    // at 118.05 fps while setNeedsDisplay submitted only 712 and the visible
    // callback stayed at an exact 16.67 ms / 59.95 fps. A synchronous `draw`
    // here was also runtime-disproved: MacWSHost-2026-09-30-044749.ips shows
    // the main thread in catalystDrawableDidPresent -> drawInMTKView when the
    // scene-update watchdog exhausted its 10-second allowance. Latch the
    // newest real update and let the panel-clock callback acquire at most one
    // drawable per vblank instead.
    BOOL focusedDirectUpdate = matchedWindowID != 0 &&
        logicalOwnerPID == self.targetPID;
    if (focusedDirectUpdate && self.window && !self.hidden &&
        self.alpha > 0.0) {
        _lastDirectDrawableReceiptTime = CACurrentMediaTime();
        if (!_directDrawableContinuousPacing) {
            _directDrawableContinuousPacing = YES;
            // setNeedsDisplay is intentionally a low-power 60-Hz-coalesced
            // mode for desktop changes. During authenticated animation, use
            // MTKView's own preferredFramesPerSecond scheduler instead.
            self.enableSetNeedsDisplay = NO;
            // At 120 Hz, one drawable may be scanned out while a second is
            // queued and Metal encodes the next. The static desktop uses two
            // to save one full-resolution allocation, but authenticated
            // continuous animation needs the supported three-buffer pool to
            // avoid blocking currentDrawable on every other panel tick.
            ((CAMetalLayer *)self.layer).maximumDrawableCount = 3;
            MacWSConfigureMTKDisplayLinkForActiveAnimation(self);
            self.paused = NO;
        }
    } else {
        [self setNeedsDisplay];
    }
}

- (NSString *)exportCatalystDrawableProbeForPID:(int32_t)ownerPID
                                           error:(NSError **)error {
    MacWSCatalystDrawableFrame *frame =
        [_catalystDrawableCompositor frameForOwnerPID:ownerPID];
    if (!frame) {
        if (error) *error = [NSError errorWithDomain:@"MacWSCatalystProbe"
            code:2 userInfo:@{NSLocalizedDescriptionKey:
                @"当前目标还没有 Catalyst drawable"}];
        return nil;
    }
    NSString *directory = @"/var/mobile/Library/Logs/MacWSPerformance";
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil error:error])
        return nil;
    NSString *rawPath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"catalyst-drawable-%d.bgra", ownerPID]];
    NSDictionary *probe = MacWSProbeCatalystDrawable(frame, rawPath, error);
    if (!probe) return nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:probe
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!json) return nil;
    NSString *jsonPath = [directory stringByAppendingPathComponent:
        @"latest-catalyst-drawable.json"];
    if (![json writeToFile:jsonPath options:NSDataWritingAtomic error:error])
        return nil;
    MacWSLog(@"catalyst-drawable-probe path=%@ result=%@", jsonPath, probe);
    return jsonPath;
}

- (void)configureStreamMode:(MacWSStreamMode)mode windowID:(uint32_t)windowID {
    _streamSuspended = NO;
    // Subscription setup can run in viewDidAppear/sceneWillEnterForeground
    // after willConnect has already issued the native Scene transaction. It
    // does not change that transaction's owner when its exact target is the
    // same. Never let a transport reconnect cancel pre-visible sizing.
    BOOL preserveSceneFollow = _sceneResizeFollowingTargetWindow &&
        mode == MacWSStreamModeWindow && windowID != 0 &&
        windowID == _sceneResizeFollowWindowID &&
        self.targetPID == _sceneResizeFollowOwnerPID &&
        CACurrentMediaTime() <= _sceneResizeFollowDeadline;
    // A UIKit scene/mode transition can cancel its recognizers after the
    // DisplayStream subscription has already changed.  Close the native Dock
    // phase stream while its latched endpoint is still valid; clearing these
    // fields without a Cancel strands Dock's fluid controller in a gesture
    // that no later touch owns.
    [self cancelActiveThreeFingerSystemGestureAtTimestamp:
        CACurrentMediaTime()];
    _windowConfigurationSettlementSerial++;
    _constrainedWindowSettlementSerial++;
    _constrainedWindowSettlementPending = NO;
    _deferredConstrainedWindowSettlement = nil;
    _windowConfigurationAwaitingAcknowledgement = NO;
    _windowConfigurationRequestTimestamp = 0.0;
    _windowConfigurationRequestSequence = 0;
    _windowConfigurationAcknowledgementsAvailable = NO;
    _lastRequestedWindowSize = CGSizeZero;
    if (!preserveSceneFollow) {
        _lastObservedTargetWindowLogicalSize = CGSizeZero;
        [self cancelSceneResizeFollowingTargetWindow];
    } else {
        MacWSLog(@"window-configuration scene-follow retained-on-subscribe window=%u pid=%d target-logical=%.1fx%.1f",
            windowID, self.targetPID, _sceneResizeTargetWindowLogicalSize.width,
            _sceneResizeTargetWindowLogicalSize.height);
    }
    _fullscreenGestureRouteActive = NO;
    _fullscreenGestureRouteContactID = 0;
    _fullscreenGestureRoutePID = 0;
    _fullscreenGestureRouteWindowID = 0;
    _fullscreenGestureRouteDescriptor = (MacWSStreamFrameDescriptor){0};
    _fullscreenGlobalPointerRouteActive = NO;
    _fullscreenGlobalPointerPresentationPID = 0;
    _fullscreenGlobalPointerPresentationContactID = 0;
    _threeFingerSystemGestureActive = NO;
    _threeFingerSystemGestureAxis = 0;
    _threeFingerSystemGestureReferenceDistance = 0.0;
    _threeFingerSystemGestureContactID = 0;
    _threeFingerSystemGestureTargetPID = 0;
    _threeFingerSystemGestureFrameWidth = 0;
    _threeFingerSystemGestureFrameHeight = 0;
    _threeFingerSystemGestureLastProgress = 0.0;
    _threeFingerSystemGestureLastVelocity = 0.0;
    _fullscreenLastTapRouteTimestamp = 0.0;
    _fullscreenLastTapRoutePID = 0;
    _fullscreenLastTapRouteWindowID = 0;
    _fullscreenLastTapRouteDescriptor = (MacWSStreamFrameDescriptor){0};
    _catalogRevalidationRequestedForPresentation = NO;
    [_streamClient clearDirectDrawableActivity];
    _lastDirectDrawableHeartbeatTime = 0;
    _directDrawableHeartbeatPID = 0;
    _directDrawableHeartbeatLayerID = 0;
    _directDrawableHeartbeatWidth = 0;
    _directDrawableHeartbeatHeight = 0;
    _directDrawableGeometryBarrierTime = 0;
    _lastDirectDrawableCatalogRefreshTime = 0;
    _reportedDirectDrawableJoinMiss = NO;
    _reportedDirectDrawableExactLayerSuppression = NO;
    _reportedDirectDrawableBaseElision = NO;
    _scheduledCatalystDrawableFrame = nil;
    _directDrawableContinuousPacing = NO;
    self.paused = YES;
    MacWSClearMTKDisplayLinkHighFrameRateReason(self);
    self.enableSetNeedsDisplay = YES;
    ((CAMetalLayer *)self.layer).maximumDrawableCount = 2;
    [_catalystDrawableCompositor removeAllFrames];
    _acceptsCatalystDrawables = YES;
    _scrollSuppressedByDockExpose = NO;
    self.targetWindowID = mode == MacWSStreamModeWindow ? windowID : 0;
    // A window Scene must only display the IOSurface exported for that window.
    // The mmap framebuffer is a full-desktop compatibility path and would show
    // a misleading crop while the direct stream is negotiating its first frame.
    _framePollDisplayLink.paused = self.targetWindowID != 0 ||
        !MacWSLegacyFramebufferFallbackEnabled();
    [_streamClient subscribeToMode:mode windowID:windowID];
    [self refreshPresentationPolicy];
}

- (uint64_t)inputSceneIDWithModifiers:(uint32_t)modifiers {
    if (self.targetWindowID != 0)
        return MacWSInputSceneForWindow(self.targetWindowID, modifiers);
    // sceneID's low 32 bits are the keyboard modifier ABI.  A fullscreen
    // UIWindowScene identity is an opaque hash and must never occupy that
    // field: runtime record 0xe94da71f accidentally asserted AlphaShift,
    // Control and Option, making both hardware and software input uppercase.
    // The protocol already defines a marked zero-window encoding for a
    // fullscreen system surface; use it even when modifiers are zero.
    return MacWSInputSceneForWindow(0, modifiers);
}

- (void)requestStreamWindowList {
    [_streamClient requestWindowList];
}

- (void)suspendStream {
    // Close admission before unsubscribing. A completed game command buffer
    // can publish concurrently with Scene backgrounding; allowing that frame
    // through would immediately recreate the lease we are about to retire.
    _acceptsCatalystDrawables = NO;
    _streamSuspended = YES;
    _scrollSuppressedByDockExpose = NO;
    [self cancelSceneResizeFollowingTargetWindow];
    [self releaseHardwareKeyboardState];
    _constrainedWindowSettlementSerial++;
    _constrainedWindowSettlementPending = NO;
    _deferredConstrainedWindowSettlement = nil;
    [self cancelActiveThreeFingerSystemGestureAtTimestamp:
        CACurrentMediaTime()];
    _framePollDisplayLink.paused = YES;
    [_streamClient clearDirectDrawableActivity];
    _lastDirectDrawableHeartbeatTime = 0;
    _directDrawableHeartbeatPID = 0;
    _directDrawableHeartbeatLayerID = 0;
    _directDrawableHeartbeatWidth = 0;
    _directDrawableHeartbeatHeight = 0;
    _directDrawableGeometryBarrierTime = 0;
    _lastDirectDrawableCatalogRefreshTime = 0;
    _reportedDirectDrawableJoinMiss = NO;
    _reportedDirectDrawableExactLayerSuppression = NO;
    _reportedDirectDrawableBaseElision = NO;
    _scheduledCatalystDrawableFrame = nil;
    _directDrawableContinuousPacing = NO;
    self.paused = YES;
    MacWSClearMTKDisplayLinkHighFrameRateReason(self);
    self.enableSetNeedsDisplay = YES;
    ((CAMetalLayer *)self.layer).maximumDrawableCount = 2;
    [_streamClient unsubscribe];
    NSMutableArray<MacWSSurfaceFrame *> *leases =
        [_retiredSurfaceFrames mutableCopy];
    [_retiredSurfaceFrames removeAllObjects];
    if (_surfaceFrame) [leases addObject:_surfaceFrame];
    [leases addObjectsFromArray:_overlayFrames.allValues];
    _surfaceFrame = nil;
    _surfaceTexture = nil;
    [_overlayFrames removeAllObjects];
    [_overlayTextures removeAllObjects];
    [_submittedOverlayLeaseTokens removeAllObjects];
    // Direct-drawable frames are not owned by MacWSStreamClient, but each one
    // holds the producer-transferred IOSurface use count until deallocation.
    // A suspended Scene has no consuming GPU submissions, so release its
    // current frame here instead of retaining it until Scene destruction.
    [_catalystDrawableCompositor removeAllFrames];
    _submittedSurfaceLeaseToken = 0;
    _sortedOverlayKeys = nil;
    _catalogRevalidationRequestedForPresentation = NO;
    _sourceTexture = nil;
    _textureWidth = 0;
    _textureHeight = 0;
    _contentRect = CGRectZero;
    // CAMetalLayer otherwise keeps its full-resolution drawable pool while
    // the Scene is resident in the background. The app-switcher snapshot is
    // already owned by UIKit at this lifecycle edge; collapse the invisible
    // pool to one pixel and let configureStreamMode restore the live policy
    // before the first foreground frame arrives.
    self.drawableSize = CGSizeMake(1.0, 1.0);
    // A UIWindow/Stage Manager maximization animation can rescale the last
    // CAMetalDrawable before the replacement DisplayStream generation lands.
    // Rendering a deterministic clear frame prevents that stale exact-window
    // image from appearing as a cropped/magnified full desktop.
    _submittedPresentWitness = NO;
    [self setDirectTouchHeld:NO dragging:NO animated:NO];
    [self hideMultitouchIndicators];
    _directTouchIndicator.hidden = YES;
    _trackpadCursorView.hidden = YES;
    if (leases.count && _commandQueue) {
        id<MTLCommandBuffer> fence = [_commandQueue commandBuffer];
        __weak MacWSStreamClient *weakClient = _streamClient;
        [fence addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
            for (MacWSSurfaceFrame *frame in leases)
                [weakClient releaseFrame:frame];
        }];
        [fence commit];
    } else {
        for (MacWSSurfaceFrame *frame in leases)
            [_streamClient releaseFrame:frame];
    }
    [self setNeedsDisplay];
}

- (uint32_t)currentFrameWidth {
    return _surfaceFrame ? _surfaceFrame.descriptor.contentWidth : _frame.width;
}

- (uint32_t)currentFrameHeight {
    return _surfaceFrame ? _surfaceFrame.descriptor.contentHeight : _frame.height;
}

- (CGFloat)effectiveDensityScale {
    // Density describes the macOS source's logical geometry in the UIKit
    // Scene; it must not change when the presentation drawable is deliberately
    // lower resolution.
    if (self.targetWindowID != 0) {
        // AppKit logical window sizes and UIWindowScene sizes are already in
        // points. Runtime logs showed UIKit changing the new Scene's render
        // scale from 1.0 to an intermediate value after attachment; applying
        // backing/display scale here changed one 1086x687 AppKit window from
        // a 2389x1563 request to 1314x883. Keep pixel scale exclusively in the
        // drawable path and make native geometry depend only on the selected
        // macPad density mode.
        return MacWSLogicalWindowDensity(
            MacWSDensityModeFactor(self.displayDensity));
    }
    CGFloat backingScale = _surfaceFrame.descriptor.backingScale;
    if (!isfinite(backingScale) || backingScale < 0.5) backingScale = 2.0;
    CGFloat sourceWidth = [self currentFrameWidth];
    CGFloat sourceHeight = [self currentFrameHeight];
    CGFloat scaleX = self.bounds.size.width > 0 && sourceWidth > 0
        ? sourceWidth / self.bounds.size.width : 0.0;
    CGFloat scaleY = self.bounds.size.height > 0 && sourceHeight > 0
        ? sourceHeight / self.bounds.size.height : 0.0;
    CGFloat sourcePixelsPerPoint = (scaleX + scaleY) * 0.5;
    if (!isfinite(sourcePixelsPerPoint) || sourcePixelsPerPoint < 0.5)
        sourcePixelsPerPoint = self.contentScaleFactor;
    if (!isfinite(sourcePixelsPerPoint) || sourcePixelsPerPoint < 0.5)
        sourcePixelsPerPoint = 2.0;
    CGFloat pixelMatched = backingScale / sourcePixelsPerPoint;
    pixelMatched = fmin(fmax(pixelMatched, 0.5), 2.0);
    return pixelMatched * MacWSDensityModeFactor(self.displayDensity);
}

- (BOOL)hasDirectSurfaceFrame { return _surfaceFrame != nil; }
- (BOOL)hasFinalCompositeFrame {
    return _surfaceFrame &&
        (_surfaceFrame.descriptor.flags & MacWSStreamFrameFinalComposite) != 0;
}
- (BOOL)streamServiceConnected { return _streamClient.isConnected; }
- (BOOL)fullscreenInputTransactionActive {
    return _fullscreenGlobalPointerRouteActive ||
        _fullscreenGestureRouteActive;
}

- (void)requestRenderedDrawableSnapshotToPath:(NSString *)path {
    if (path.length == 0) return;
    _pendingRenderedDrawableSnapshotPath = [path copy];
    [self setNeedsDisplay];
}

- (void)setTargetPID:(int32_t)targetPID {
    if (_targetPID == targetPID) return;
    [self cancelSceneResizeFollowingTargetWindow];
    int32_t previousTargetPID = _targetPID;
    _lastKeyboardFrameWidth = 0;
    _lastKeyboardFrameHeight = 0;
    MacWSLog(@"presentation-target-change previous=%d next=%d "
             "direct-heartbeat=%d/%u fullscreen-canvas=%d/%u mode=%lu",
             previousTargetPID, targetPID, _directDrawableHeartbeatPID,
             _directDrawableHeartbeatLayerID, _reportedFullscreenCanvasPID,
             _reportedFullscreenCanvasWindowID,
             (unsigned long)_streamClient.mode);
    [_streamClient clearDirectDrawableActivity];
    _lastDirectDrawableHeartbeatTime = 0;
    _directDrawableHeartbeatPID = 0;
    _directDrawableHeartbeatLayerID = 0;
    _directDrawableHeartbeatWidth = 0;
    _directDrawableHeartbeatHeight = 0;
    _lastDirectDrawableCatalogRefreshTime = 0;
    _reportedDirectDrawableJoinMiss = NO;
    _reportedDirectDrawableExactLayerSuppression = NO;
    _reportedDirectDrawableBaseElision = NO;
    // Runtime-confirmed on iPad13,6 by /tmp/macwshost-v33.vmmap: after
    // several VS Code restarts this one long-lived Scene still mapped eight
    // 1822x1468 producer IOSurfaces (about 81.6 MiB). The compositor keys its
    // retained newest/pending frames by logical owner PID, so an exec/relaunch
    // gives the same application a new key and the old frame can otherwise
    // survive until Scene destruction. A target transition invalidates every
    // old direct-drawable identity. Release the queued/current owners here;
    // command-buffer completion blocks independently retain any frame still
    // referenced by the GPU, so this cannot retire an in-flight IOSurface.
    _scheduledCatalystDrawableFrame = nil;
    [_catalystDrawableCompositor removeAllFrames];
    _lastDirectDrawableReceiptTime = 0.0;
    _inferredDescendantFullscreenCanvas = NO;
    if (_directDrawableContinuousPacing) {
        _directDrawableContinuousPacing = NO;
        self.paused = YES;
        MacWSClearMTKDisplayLinkHighFrameRateReason(self);
        self.enableSetNeedsDisplay = YES;
        ((CAMetalLayer *)self.layer).maximumDrawableCount = 2;
    }
    if (_reportedFullscreenCanvasPID != targetPID) {
        _reportedFullscreenCanvasPID = 0;
        _reportedFullscreenCanvasWindowID = 0;
        _reportedFullscreenCanvasPixels = CGRectZero;
    }
    if (previousTargetPID > 1) {
        NSMutableSet<NSNumber *> *capabilities =
            [_fullscreenCanvasPIDs mutableCopy] ?: [NSMutableSet set];
        [capabilities removeObject:@(previousTargetPID)];
        _fullscreenCanvasPIDs = [capabilities copy];
    }
    _targetPID = targetPID;
    _directTouchUsesPrimaryDrag = targetPID > 1 &&
        [_spatialCanvasPIDs containsObject:@(targetPID)];
    [self refreshPresentationPolicy];
}

- (void)noteValidatedFullscreenCanvasForPID:(int32_t)ownerPID
                                   windowID:(uint32_t)windowID {
    if (ownerPID <= 1 || windowID == 0 || ownerPID != self.targetPID) return;
    NSMutableSet<NSNumber *> *capabilities =
        [_fullscreenCanvasPIDs mutableCopy] ?: [NSMutableSet set];
    [capabilities addObject:@(ownerPID)];
    _fullscreenCanvasPIDs = [capabilities copy];
    _reportedFullscreenCanvasPID = ownerPID;
    _reportedFullscreenCanvasWindowID = windowID;
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    _reportedFullscreenCanvasPixels = width != 0 && height != 0
        ? CGRectMake(0, 0, width, height) : CGRectZero;
    MacWSLog(@"fullscreen-canvas-capability pid=%d window=%u "
             "source=controller-validated-catalog canvas=%ux%u",
             ownerPID, windowID, width, height);
    [self updateDrawableResolution];
    [self setNeedsDisplay];
}

- (BOOL)hasCompletedFullscreenDrawableForPID:(int32_t)ownerPID {
    if (ownerPID <= 1 || ownerPID != self.targetPID ||
        ![_fullscreenCanvasPIDs containsObject:@(ownerPID)] ||
        !MacWSAppInputEndpointReady(ownerPID)) return NO;
    MacWSCatalystDrawableFrame *frame =
        [_catalystDrawableCompositor frameForOwnerPID:ownerPID];
    if (!frame.texture) return NO;
    for (MacWSStreamWindow *window in _latestWindows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        MacWSStreamWindowFlags required = MacWSStreamWindowFocused |
            MacWSStreamWindowFullscreenCanvas;
        if (descriptor.ownerPID == ownerPID && descriptor.windowID != 0 &&
            (descriptor.flags & required) == required) return YES;
    }
    return NO;
}

- (void)setDisplayDensity:(MacWSHostDisplayDensity)displayDensity {
    MacWSHostDisplayDensity previous = _displayDensity;
    _displayDensity = MacWSNormalizedDisplayDensity(displayDensity);
    _lastRequestedWindowSize = CGSizeZero;
    _submittedPresentWitness = NO;
    MacWSLog(@"display-density changed previous=%u next=%u factor=%.2f",
             (unsigned)previous, (unsigned)_displayDensity,
             MacWSDisplayDensityFactor(_displayDensity));
    [self resetViewportZoom];
    [self geometryDidChange];
}

- (void)setPresentationResolution:
        (MacWSHostPresentationResolution)presentationResolution {
    if (presentationResolution !=
            MacWSHostPresentationResolutionAutomatic &&
        presentationResolution !=
            MacWSHostPresentationResolutionSourceNative &&
        presentationResolution !=
            MacWSHostPresentationResolutionPerformance) return;
    if (_presentationResolution == presentationResolution) return;
    _presentationResolution = presentationResolution;
    [self updateDrawableResolution];
    [self updatePresentationGeometry];
    [self setNeedsDisplay];
}

- (void)setFixedZoomScale:(CGFloat)fixedZoomScale {
    CGFloat normalized = fixedZoomScale >= 1.75 ? 2.0 : 1.5;
    BOOL wasZoomed = _viewportZoom > 1.001;
    _fixedZoomScale = normalized;
    if (wasZoomed) {
        _viewportZoom = normalized;
        [self setNeedsDisplay];
    }
    [self updateZoomHUD];
}

- (BOOL)isViewportZoomed {
    return _viewportZoom > 1.001;
}

- (void)updateZoomHUD {
    BOOL visible = [self isViewportZoomed] && !_windowTooSmall;
    _zoomHUD.hidden = !visible;
    _zoomHUDLabel.text = [NSString stringWithFormat:@"%.1f×", _viewportZoom];
}

- (void)setMinimumLogicalSize:(CGSize)minimumLogicalSize {
    _minimumLogicalSize = (CGSize){
        isfinite(minimumLogicalSize.width) && minimumLogicalSize.width > 0
            ? minimumLogicalSize.width : 0,
        isfinite(minimumLogicalSize.height) && minimumLogicalSize.height > 0
            ? minimumLogicalSize.height : 0,
    };
    [self refreshPresentationPolicy];
}

- (void)setTargetWindowResizable:(BOOL)targetWindowResizable {
    _targetWindowResizable = targetWindowResizable;
    [self refreshPresentationPolicy];
}

- (void)observeTargetWindowLogicalSize:(CGSize)logicalSize {
    if (!isfinite(logicalSize.width) || !isfinite(logicalSize.height) ||
        logicalSize.width <= 0.0 || logicalSize.height <= 0.0) return;
    _lastObservedTargetWindowLogicalSize = logicalSize;
    // Catalog generations and ConfigureWindow deliveries are independent.
    // Runtime-confirmed at MacWSHost.log 1789154729.441: the catalog's
    // 648x613 was labelled as the result of a still-moving 736x634 request,
    // started a reverse Scene resize and cancelled its newer queued request.
    // Legacy producers can prove only same-size convergence; disagreement
    // carries no causal evidence of a constraint.
    if (self.windowConfigurationAcknowledgementsAvailable ||
        !_windowConfigurationAwaitingAcknowledgement ||
        !MacWSWindowConfigurationSizesMatch(
            logicalSize.width, logicalSize.height,
            _lastRequestedWindowSize.width, _lastRequestedWindowSize.height,
            0.75) || self.windowConfigurationHasQueuedRequest) return;
    _windowConfigurationAwaitingAcknowledgement = NO;
    _windowConfigurationSettlementSerial++;
    _windowConfigurationRequestSequence = 0;
}

- (void)observeWindowConfigurationWithTimestamp:(double)timestamp
                                sampleSequence:(uint32_t)sampleSequence
                                 requestedSize:(CGSize)requestedSize
                                   appliedSize:(CGSize)appliedSize {
    if (!_windowConfigurationAwaitingAcknowledgement) return;
    MacWSWindowConfigurationAckResult result =
        MacWSClassifyWindowConfigurationAcknowledgement(
            _windowConfigurationRequestTimestamp,
            _windowConfigurationRequestSequence,
            _lastRequestedWindowSize.width, _lastRequestedWindowSize.height,
            _lastRequestedDensityScale,
            _pendingRequestedWindowSize.width, _pendingRequestedWindowSize.height,
            _pendingRequestedDensityScale,
            timestamp, sampleSequence, requestedSize.width, requestedSize.height,
            appliedSize.width, appliedSize.height);
    if (result == MacWSWindowConfigurationAckUnrelated) return;
    _windowConfigurationAwaitingAcknowledgement = NO;
    _windowConfigurationSettlementSerial++;
    _windowConfigurationRequestSequence = 0;
    MacWSDiagnosticLog(@"window-configuration ack window=%u pid=%d sequence=%u request-time=%.6f requested=%.1fx%.1f applied=%.1fx%.1f queued=%.1fx%.1f result=%@",
             self.targetWindowID, self.targetPID, sampleSequence, timestamp,
             requestedSize.width, requestedSize.height,
             appliedSize.width, appliedSize.height,
             _pendingRequestedWindowSize.width, _pendingRequestedWindowSize.height,
             result == MacWSWindowConfigurationAckSuperseded ? @"superseded" :
                 (result == MacWSWindowConfigurationAckApplied ? @"applied" :
                    @"constrained"));
    if (result == MacWSWindowConfigurationAckSuperseded) {
        [self scheduleWindowConfiguration];
    } else if (result == MacWSWindowConfigurationAckConstrained) {
        // Runtime-confirmed at MacWSHost.log 1789179563.847-.866: a
        // Terminal cell-rounded ACK arrived between native corner-drag
        // updates. Reversing the Scene immediately armed reciprocal-configure
        // suppression and discarded the rest of the still-moving gesture.
        // Coalesce only reverse settlement; forward delivery stays live.
        uint64_t serial = ++_constrainedWindowSettlementSerial;
        uint64_t transaction = _windowConfigurationSettlementSerial;
        uint32_t windowID = self.targetWindowID;
        int32_t ownerPID = self.targetPID;
        CGSize bounds = self.bounds.size;
        CGFloat density = self.effectiveDensityScale;
        _constrainedWindowSettlementPending = YES;
        __weak typeof(self) weakSelf = self;
        _deferredConstrainedWindowSettlement = ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            if (serial != self->_constrainedWindowSettlementSerial) return;
            self->_constrainedWindowSettlementPending = NO;
            if (!MacWSWindowConfigurationSettlementIsCurrent(
                    transaction, self->_windowConfigurationSettlementSerial,
                    windowID, self.targetWindowID, ownerPID, self.targetPID,
                    bounds.width, bounds.height,
                    self.bounds.size.width, self.bounds.size.height,
                    density, self.effectiveDensityScale,
                    self->_windowConfigurationAwaitingAcknowledgement ||
                        self.windowConfigurationHasQueuedRequest ||
                        self->_sceneResizeFollowingTargetWindow)) return;
            [self.statusDelegate metalView:self
                windowConfigurationWasConstrainedToLogicalSize:appliedSize
                                                  requestedSize:requestedSize];
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (serial != self->_constrainedWindowSettlementSerial) return;
            [self completeConstrainedWindowSettlementIfIdle];
        });
    }
}

- (BOOL)windowConfigurationAwaitingAcknowledgement {
    return _windowConfigurationAwaitingAcknowledgement;
}

- (BOOL)windowConfigurationAwaitingSettlement {
    return _constrainedWindowSettlementPending;
}

- (BOOL)windowConfigurationHasQueuedRequest {
    return _windowConfigurationDispatchPending &&
        (!MacWSWindowConfigurationSizesMatch(
            _pendingRequestedWindowSize.width, _pendingRequestedWindowSize.height,
            _lastRequestedWindowSize.width, _lastRequestedWindowSize.height,
            0.25) || fabs(_pendingRequestedDensityScale -
                          _lastRequestedDensityScale) >= 0.001);
}

- (BOOL)sceneResizeFollowingTargetWindow {
    return _sceneResizeFollowingTargetWindow;
}

- (void)beginSceneResizeFollowingTargetWindowLogicalSize:(CGSize)logicalSize {
    if (!isfinite(logicalSize.width) || !isfinite(logicalSize.height) ||
        logicalSize.width <= 0.0 || logicalSize.height <= 0.0) return;
    _sceneResizeFollowingTargetWindow = YES;
    _sceneResizeFollowWindowID = self.targetWindowID;
    _sceneResizeFollowOwnerPID = self.targetPID;
    _sceneResizeTargetWindowLogicalSize = logicalSize;
    // SpringBoard's app-layout transaction is asynchronous and its existing
    // postcondition witness is sampled at 1.5 seconds.  Suppress only the
    // reciprocal Scene->AppKit configure path while that one transaction is
    // settling; a later user resize remains authoritative.
    _sceneResizeFollowDeadline = CACurrentMediaTime() + 1.8;
    _windowConfigurationSettlementSerial++;
    _windowConfigurationAwaitingAcknowledgement = NO;
    _windowConfigurationRequestSequence = 0;
    MacWSDiagnosticLog(@"window-configuration scene-follow armed window=%u pid=%d target-logical=%.1fx%.1f",
             self.targetWindowID, self.targetPID,
             logicalSize.width, logicalSize.height);
}

- (void)cancelSceneResizeFollowingTargetWindow {
    _sceneResizeFollowingTargetWindow = NO;
    _sceneResizeFollowWindowID = 0;
    _sceneResizeFollowOwnerPID = 0;
    _sceneResizeTargetWindowLogicalSize = CGSizeZero;
    _sceneResizeFollowDeadline = 0.0;
}

- (void)updateWindowTooSmallState {
    CGFloat density = self.effectiveDensityScale;
    CGSize available = self.bounds.size;
    CGFloat requiredWidth = self.minimumLogicalSize.width * density;
    CGFloat requiredHeight = self.minimumLogicalSize.height * density;
    BOOL hasRequirement = self.targetWindowID != 0 &&
        (requiredWidth > 0 || requiredHeight > 0);
    _windowTooSmall = hasRequirement &&
        ((requiredWidth > 0 && available.width + 0.5 < requiredWidth) ||
         (requiredHeight > 0 && available.height + 0.5 < requiredHeight));
    _tooSmallOverlay.hidden = !_windowTooSmall;
    _inputUnavailableLabel.hidden = _windowTooSmall || _macWSInputEnabled;
    self.userInteractionEnabled = _macWSInputEnabled && !_windowTooSmall;
    if (_windowTooSmall) {
        NSString *densityName = self.displayDensity ==
            MacWSHostDisplayDensityRetinaLarger
                ? @"Retina 放大" : @"Retina 标准";
        _tooSmallLabel.text = [NSString stringWithFormat:
            @"窗口太小\n\n此 macOS 应用至少需要 %.0f × %.0f 点\n"
             "当前 %@ 模式需要约 %.0f × %.0f iPad 点\n\n"
             "请放大 iPadOS 窗口，或切换到 Retina 标准。",
            self.minimumLogicalSize.width,
            self.minimumLogicalSize.height,
            densityName, requiredWidth, requiredHeight];
    }
    [self updateZoomHUD];
    [self updatePointerVisibility];
}

- (void)scheduleWindowConfiguration {
    // A too-small Scene still has to reach AppKit. Its real min/max/content
    // constraints are the authority that produces the applied-size reply;
    // the controller then moves the iPadOS Scene back to that native size.
    // Returning merely because the warning overlay is visible strands the
    // two window managers at different geometries indefinitely.
    if (self.targetWindowID == 0 || self.targetPID <= 1 ||
        self.bounds.size.width < 64 ||
        self.bounds.size.height < 64) return;
    CGFloat density = self.effectiveDensityScale;
    CGSize visibleLogicalSize = {
        self.bounds.size.width / density,
        self.bounds.size.height / density,
    };
    CGSize requested = visibleLogicalSize;
    // Per-axis AppKit policy is stronger than a transient Scene geometry.
    // Keep a content-driven/fixed axis on the last native window dimension;
    // the unfixed axis still follows the user's dense Stage Manager gesture.
    // This also prevents a missed SpringBoard gesture association from ever
    // deforming the AppKit window while the native Scene springs back.
    if (self.targetWindowFixedWidth &&
        _lastObservedTargetWindowLogicalSize.width > 0.0)
        requested.width = _lastObservedTargetWindowLogicalSize.width;
    if (self.targetWindowFixedHeight &&
        _lastObservedTargetWindowLogicalSize.height > 0.0)
        requested.height = _lastObservedTargetWindowLogicalSize.height;
    if (_sceneResizeFollowingTargetWindow) {
        CFTimeInterval now = CACurrentMediaTime();
        // Runtime-confirmed Get Info collapse, 1789182049.530/.613:
        // "scene-follow reached" preceded UIKit's real height update at
        // .711. `requested` above had already replaced the fixed height with
        // the AppKit target, so it could not witness Scene completion. Compare
        // unmodified UIKit content bounds, with only Scene edge rounding.
        // Dense proposals are exact now, not the historical 10-point grid.
        BOOL reached = MacWSWindowSceneContentMatchesTarget(
            self.bounds.size.width, self.bounds.size.height, density,
            _sceneResizeTargetWindowLogicalSize.width,
            _sceneResizeTargetWindowLogicalSize.height);
        if (reached) {
            // Record the geometry that AppKit itself selected so the next
            // layout pass does not echo it back as a new configure request.
            _lastRequestedWindowSize = requested;
            _lastRequestedDensityScale = density;
            MacWSDiagnosticLog(@"window-configuration scene-follow reached window=%u pid=%d logical=%.1fx%.1f after-deadline=%@",
                     self.targetWindowID, self.targetPID,
                     visibleLogicalSize.width, visibleLogicalSize.height,
                     now > _sceneResizeFollowDeadline ? @"YES" : @"NO");
            [self cancelSceneResizeFollowingTargetWindow];
            return;
        }
        if (now <= _sceneResizeFollowDeadline) {
            return;
        }
        MacWSLog(@"window-configuration scene-follow expired window=%u pid=%d target-logical=%.1fx%.1f current-logical=%.1fx%.1f",
                 self.targetWindowID, self.targetPID,
                 _sceneResizeTargetWindowLogicalSize.width,
                 _sceneResizeTargetWindowLogicalSize.height,
                 visibleLogicalSize.width, visibleLogicalSize.height);
        [self cancelSceneResizeFollowingTargetWindow];
    }
    _pendingRequestedWindowSize = requested;
    _pendingRequestedDensityScale = density;
    if (MacWSWindowConfigurationSizesMatch(
            requested.width, requested.height,
            _lastRequestedWindowSize.width, _lastRequestedWindowSize.height,
            0.25) && fabs(density - _lastRequestedDensityScale) < 0.001)
        return;
    if (_windowConfigurationDispatchPending) return;
    _windowConfigurationDispatchPending = YES;
    // Stage Manager can report geometry on every display refresh.  Coalesce
    // those callbacks into the newest AppKit size at a bounded 30-Hz rate,
    // rather than waiting for a 180-ms quiet period after the drag.  This
    // preserves AppKit's real minimum-size validation while making the macOS
    // content follow the iPad window continuously.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        self->_windowConfigurationDispatchPending = NO;
        if (self.targetPID <= 1 || self.targetWindowID == 0) return;
        // AppKit may publish its authoritative geometry after this 33-ms
        // Scene->AppKit configure was queued but before it executes. Recheck
        // the ownership boundary here: sending the stale, stock Scene size
        // would resize the native window and supersede the reverse sync that
        // has just been armed. Runtime-confirmed for Finder Get Info at
        // MacWSHost.log 1789067847.504-1789067847.622.
        if (self->_sceneResizeFollowingTargetWindow) {
            MacWSDiagnosticLog(@"window-configuration queued-request-superseded window=%u pid=%d target-logical=%.1fx%.1f",
                     self.targetWindowID, self.targetPID,
                     self->_sceneResizeTargetWindowLogicalSize.width,
                     self->_sceneResizeTargetWindowLogicalSize.height);
            return;
        }
        CGSize requested = self->_pendingRequestedWindowSize;
        CGFloat density = self->_pendingRequestedDensityScale;
        if (fabs(requested.width - self->_lastRequestedWindowSize.width) < 0.25 &&
            fabs(requested.height - self->_lastRequestedWindowSize.height) < 0.25 &&
            fabs(density - self->_lastRequestedDensityScale) < 0.001) return;
        self->_lastRequestedWindowSize = requested;
        self->_lastRequestedDensityScale = density;
        self->_windowConfigurationAwaitingAcknowledgement = YES;
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = MacWSInputKindConfigureWindow,
            .sceneID = MacWSInputSceneForWindow(self.targetWindowID, 0),
            .timestamp = CACurrentMediaTime(),
            .x = (float)requested.width,
            .y = (float)requested.height,
            .pressure = (float)density,
            .frameWidth = (uint32_t)ceil(requested.width) + 1,
            .frameHeight = (uint32_t)ceil(requested.height) + 1,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceUnknown,
            .flags = MacWSInputFlagConfigureAnchorTopRight,
            .sampleSequence = ++self->_inputSampleSequence,
        };
        self->_windowConfigurationRequestTimestamp = record.timestamp;
        self->_windowConfigurationRequestSequence = record.sampleSequence;
        uint64_t settlementSerial = ++self->_windowConfigurationSettlementSerial;
        [self.statusDelegate metalView:self emittedInput:record];
        // Electron restores its persisted NSWindow frame after the first
        // DisplayStream/Scene transaction. A single datagram can therefore be
        // accepted and then legitimately superseded. Re-assert the same native
        // frame invariant at three bounded settlement points. A new Scene size,
        // density, target, or suspension changes the serial and cancels these
        // retries; this is not a periodic poll and does not touch WindowServer.
        // Ask once for a current metrics/ACK snapshot if the event was lost.
        // Elapsed time never upgrades an unrelated old catalog into an ACK.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     220 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (self->_windowConfigurationSettlementSerial !=
                    settlementSerial ||
                !self->_windowConfigurationAwaitingAcknowledgement)
                return;
            [self->_streamClient requestWindowList];
        });
        const int64_t retryNanoseconds[] = {
            350 * NSEC_PER_MSEC,
            1200 * NSEC_PER_MSEC,
            3000 * NSEC_PER_MSEC,
        };
        for (NSUInteger index = 0;
             index < sizeof(retryNanoseconds) / sizeof(retryNanoseconds[0]);
             index++) {
            int64_t delay = retryNanoseconds[index];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay),
                           dispatch_get_main_queue(), ^{
                if (self->_windowConfigurationSettlementSerial !=
                        settlementSerial ||
                    !self->_windowConfigurationAwaitingAcknowledgement ||
                    self.targetPID <= 1 ||
                    self.targetWindowID == 0 ||
                    self.targetPID != record.targetPID ||
                    self.targetWindowID != MacWSInputWindowIDForScene(record.sceneID) ||
                    fabs(self->_pendingRequestedWindowSize.width -
                         requested.width) >= 0.25 ||
                    fabs(self->_pendingRequestedWindowSize.height -
                         requested.height) >= 0.25 ||
                    fabs(self->_pendingRequestedDensityScale - density) >=
                         0.001) return;
                // A retry is the same configuration transaction. Preserve
                // its correlation key so a late original ACK still matches.
                [self.statusDelegate metalView:self emittedInput:record];
            });
        }
    });
}

- (void)refreshPresentationPolicy {
    [self updateWindowTooSmallState];
    [self updateDrawableResolution];
    [self scheduleWindowConfiguration];
    [self setNeedsDisplay];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateDrawableResolution];
    [self updatePresentationGeometry];
    [self refreshPresentationPolicy];
}

- (void)updateDrawableResolution {
    if (_streamSuspended) {
        if (self.drawableSize.width != 1.0 ||
            self.drawableSize.height != 1.0)
            self.drawableSize = CGSizeMake(1.0, 1.0);
        return;
    }
    CGFloat logicalWidth = self.bounds.size.width;
    CGFloat logicalHeight = self.bounds.size.height;
    if (!isfinite(logicalWidth) || !isfinite(logicalHeight) ||
        logicalWidth < 1.0 || logicalHeight < 1.0) return;

    BOOL validatedFullscreenCanvas =
        _streamClient.mode == MacWSStreamModeFullscreen &&
        self.targetPID > 1 &&
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)];
    BOOL performanceResolution =
        self.presentationResolution ==
            MacWSHostPresentationResolutionPerformance ||
        (self.presentationResolution ==
             MacWSHostPresentationResolutionAutomatic &&
         validatedFullscreenCanvas);
    uint32_t sourceWidth = [self currentFrameWidth];
    uint32_t sourceHeight = [self currentFrameHeight];
    BOOL sourceNativeAvailable = !performanceResolution &&
        _surfaceFrame != nil && sourceWidth > 0 && sourceHeight > 0;

    CGSize target = CGSizeMake(ceil(logicalWidth), ceil(logicalHeight));
    NSString *policy = performanceResolution
        ? @"performance-logical-one-to-one"
        : @"logical-one-to-one-awaiting-source";
    UIScreen *screen = self.window.windowScene.screen ?: UIScreen.mainScreen;
    CGFloat displayScale = screen.scale;
    if (!isfinite(displayScale) || displayScale < 0.5 || displayScale > 8.0)
        displayScale = 1.0;
    CGFloat sourceBackingScale = _surfaceFrame.descriptor.backingScale;
    if (!isfinite(sourceBackingScale) || sourceBackingScale < 0.5 ||
        sourceBackingScale > 8.0) sourceBackingScale = 2.0;
    CGFloat density = self.effectiveDensityScale;
    if (sourceNativeAvailable) {
        // Runtime-confirmed in MacWSHost.log at 1789153123.890: unchanged
        // bounds=987x582/source=1806x1084 repeatedly produced 1693x1016,
        // 1663x998, 1634x981, 1605x964. MTKView's contentScaleFactor followed
        // the previous drawable width / view width, feeding each reduction
        // into the next source fit. A first frame also stayed at half its
        // Retina resolution (1876x1116 -> 938x558 at 1789153112.985).
        // Use the screen's independent scale and preserve the Scene aspect
        // ratio so a native source has the same pixel budget on every pass.
        MacWSPresentationDrawableSize pixels = {0};
        if (MacWSComputePresentationDrawableSize(
                logicalWidth, logicalHeight, sourceWidth, sourceHeight,
                sourceBackingScale, density, displayScale,
                _streamClient.mode == MacWSStreamModeWindow, &pixels)) {
            target = CGSizeMake(pixels.width, pixels.height);
            policy = self.presentationResolution ==
                    MacWSHostPresentationResolutionSourceNative
                ? @"source-native-forced" : @"source-native-auto";
        }
    }
    CGSize previous = self.drawableSize;
    if (fabs(previous.width - target.width) < 0.5 &&
        fabs(previous.height - target.height) < 0.5) return;
    self.drawableSize = target;
    MacWSDiagnosticLog(@"host-drawable-policy window=%u bounds=%.2fx%.2f previous=%.0fx%.0f "
             "source=%ux%u drawable=%.0fx%.0f display-scale=%.3f "
             "backing=%.3f density=%.3f policy=%@ "
             "fullscreen-canvas=%@",
             self.targetWindowID, self.bounds.size.width, self.bounds.size.height,
             previous.width, previous.height, sourceWidth, sourceHeight,
             target.width, target.height, displayScale, sourceBackingScale,
             density, policy,
             validatedFullscreenCanvas ? @"YES" : @"NO");
}

- (void)geometryDidChange {
    // Geometry changes invalidate the view-to-surface transform immediately;
    // do not leave an old down/scroll sequence alive across rotation or a
    // Stage Manager resize.
    if (_directTouch && MacWSHostTouchDiagnosticsEnabled()) {
        MacWSLog(@"direct-touch lifecycle=geometry-reset window=%u contact=%u state=%u bounds=%.1fx%.1f",
            self.targetWindowID, (uint32_t)_directTouch.hash,
            (unsigned)_directTouchState, self.bounds.size.width,
            self.bounds.size.height);
    }
    if (_directTouch && _directTouchState == MacWSDirectTouchStateDragging) {
        [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                 point:[_directTouch locationInView:self]];
    } else if (_directTouch &&
               _directTouchState == MacWSDirectTouchStateScrolling) {
        [self emitScrollAtFramePoint:_directScrollFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollCancelled
                           timestamp:CACurrentMediaTime()];
    }
    if (_trackpadTouch && _trackpadButtonDown) {
        [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
             pressure:0 contactID:(uint32_t)_trackpadTouch.hash
             timestamp:CACurrentMediaTime()];
    }
    _directTouchSerial++;
    _directTouch = nil;
    _directTouchState = MacWSDirectTouchStateIdle;
    _directGestureBlocked = NO;
    _trackpadTouch = nil;
    _trackpadButtonDown = NO;
    _trackpadHadMultipleTouches = NO;
    [self stopScrollMomentumWithTerminalPhase:YES];
    [self setDirectTouchHeld:NO dragging:NO animated:NO];
    [self hideMultitouchIndicators];
    [self setTrackpadPointerPressed:NO animated:NO];
    [self updatePresentationGeometry];
    [self refreshPresentationPolicy];
}

- (void)setMacWSInputEnabled:(BOOL)enabled {
    [self setMacWSInputEnabled:enabled reason:nil];
}

- (BOOL)isMacWSInputEnabled {
    return _macWSInputEnabled && !_windowTooSmall;
}

- (void)setMacWSInputEnabled:(BOOL)enabled reason:(NSString *)reason {
    if (!enabled && _macWSInputEnabled) {
        if (_directTouch && MacWSHostTouchDiagnosticsEnabled()) {
            MacWSLog(@"direct-touch lifecycle=input-disabled window=%u contact=%u state=%u reason=%@",
                self.targetWindowID, (uint32_t)_directTouch.hash,
                (unsigned)_directTouchState, reason ?: @"unknown");
        }
        if (_directTouch && _directTouchState == MacWSDirectTouchStateDragging) {
            [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                     point:[_directTouch locationInView:self]];
        } else if (_directTouch &&
                   _directTouchState == MacWSDirectTouchStateScrolling) {
            [self emitScrollAtFramePoint:_directScrollFramePoint
                             translation:CGPointZero
                                   flags:MacWSInputFlagScrollCancelled
                               timestamp:CACurrentMediaTime()];
        }
        if (_trackpadTouch && _trackpadButtonDown) {
            [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
                 pressure:0 contactID:(uint32_t)_trackpadTouch.hash
                 timestamp:CACurrentMediaTime()];
        }
        _directTouchSerial++;
        _directTouch = nil;
        _directTouchState = MacWSDirectTouchStateIdle;
        _trackpadTouch = nil;
        _trackpadButtonDown = NO;
        _trackpadHadMultipleTouches = NO;
        [self stopScrollMomentumWithTerminalPhase:YES];
        [self setDirectTouchHeld:NO dragging:NO animated:NO];
        [self hideMultitouchIndicators];
        [self setTrackpadPointerPressed:NO animated:NO];
    }
    _macWSInputEnabled = enabled;
    if (!enabled) {
        _directTouchIndicator.hidden = YES;
        _trackpadCursorView.hidden = YES;
        _inputUnavailableLabel.text = [NSString stringWithFormat:
            @"触控暂不可用 · %@", reason.length ? reason : @"工作区未就绪"];
    }
    [self updateWindowTooSmallState];
    [self updatePointerVisibility];
}

- (void)setInputMode:(MacWSHostInputMode)inputMode {
    if (inputMode != MacWSHostInputModeDirect &&
        inputMode != MacWSHostInputModeTrackpad) return;
    if (_inputMode == MacWSHostInputModeDirect && _directTouch &&
        _directTouchState == MacWSDirectTouchStateDragging) {
        [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                 point:[_directTouch locationInView:self]];
    } else if (_inputMode == MacWSHostInputModeDirect && _directTouch &&
               _directTouchState == MacWSDirectTouchStateScrolling) {
        [self emitScrollAtFramePoint:_directScrollFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollCancelled
                           timestamp:CACurrentMediaTime()];
    }
    if (_inputMode == MacWSHostInputModeTrackpad && _trackpadTouch &&
        _trackpadButtonDown) {
        [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
             pressure:0 contactID:(uint32_t)_trackpadTouch.hash
             timestamp:CACurrentMediaTime()];
    }
    _inputMode = inputMode;
    _trackpadTouch = nil;
    _trackpadButtonDown = NO;
    _trackpadTravel = 0;
    _trackpadHadMultipleTouches = NO;
    _trackpadCursorWasTouched = NO;
    _externalPointerHoverActive = NO;
    _directTouch = nil;
    _directGestureBlocked = NO;
    _directTouchState = MacWSDirectTouchStateIdle;
    _directTouchSerial++;
    [self stopScrollMomentumWithTerminalPhase:YES];
    _directTouchIndicator.hidden = YES;
    [self setTrackpadPointerPressed:NO animated:NO];
    [self updatePointerVisibility];
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (NSArray<UIKeyCommand *> *)keyCommands {
    // Hardware keyboard input may be resolved by UIKit's key-command system
    // before a custom responder receives UIPresses. Publish the desktop keys
    // that must remain available to an AppKit terminal/editor, then forward
    // the original key and modifiers through the same Host input protocol as
    // UIPresses. This is intentionally finite: Command-Tab and Command-Space
    // remain owned by iPadOS.
    static NSArray<UIKeyCommand *> *commands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<UIKeyCommand *> *result = [NSMutableArray array];
        void (^append)(NSString *, UIKeyModifierFlags) =
            ^(NSString *input, UIKeyModifierFlags modifiers) {
                UIKeyCommand *key = [UIKeyCommand
                    keyCommandWithInput:input
                          modifierFlags:modifiers
                                  action:@selector(forwardMacKeyCommand:)];
                if ([key respondsToSelector:
                        @selector(setWantsPriorityOverSystemBehavior:)])
                    key.wantsPriorityOverSystemBehavior = YES;
                [result addObject:key];
            };
        // Register the complete printable Command-letter/digit/punctuation
        // family rather than guessing which menu equivalents each AppKit app
        // uses. Finder alone needs Command-I/J/D/Y in addition to C/V, while
        // editors use B/K/L/R/U and their shifted forms. Command-Tab and
        // Command-Space are deliberately absent so iPadOS keeps its own app
        // switcher and system search.
        NSArray<NSString *> *plain = @[
            @"a", @"b", @"c", @"d", @"e", @"f", @"g", @"h",
            @"i", @"j", @"k", @"l", @"m", @"n", @"o", @"p",
            @"q", @"r", @"s", @"t", @"u", @"v", @"w", @"x",
            @"y", @"z", @"0", @"1", @"2", @"3", @"4", @"5",
            @"6", @"7", @"8", @"9", @",", @".", @"/", @";",
            @"'", @"[", @"]", @"\\", @"-", @"=", @"`"
        ];
        for (NSString *input in plain) {
            append(input, UIKeyModifierCommand);
            append(input, UIKeyModifierCommand | UIKeyModifierShift);

            // Terminal control sequences must preserve both the physical
            // key identity and Control modifier. Sending the resulting ASCII
            // control byte as text would lose combinations such as Ctrl-[,
            // Ctrl-\\ and Ctrl-].
            append(input, UIKeyModifierControl);
            append(input, UIKeyModifierControl | UIKeyModifierShift);
        }

        // Ctrl-Space is a real terminal input (NUL) and does not overlap the
        // iPadOS Command-Space search gesture.
        append(@" ", UIKeyModifierControl);
        append(@" ", UIKeyModifierControl | UIKeyModifierShift);

        NSArray<NSString *> *navigationInputs = @[
            UIKeyInputUpArrow, UIKeyInputDownArrow,
            UIKeyInputLeftArrow, UIKeyInputRightArrow,
            UIKeyInputPageUp, UIKeyInputPageDown,
            UIKeyInputHome, UIKeyInputEnd
        ];
        NSArray<NSNumber *> *navigationModifiers = @[
            @0,
            @(UIKeyModifierShift),
            @(UIKeyModifierControl),
            @(UIKeyModifierAlternate),
            @(UIKeyModifierCommand),
            @(UIKeyModifierControl | UIKeyModifierShift),
            @(UIKeyModifierAlternate | UIKeyModifierShift),
            @(UIKeyModifierCommand | UIKeyModifierShift)
        ];
        for (NSString *input in navigationInputs) {
            for (NSNumber *modifiers in navigationModifiers)
                append(input, modifiers.unsignedIntegerValue);
        }

        // UIKit publishes Escape and backward Delete as named key inputs.
        // Explicit entries keep them out of view-dismissal/editing handling
        // and preserve their real AppKit key codes for Vim and shells.
        append(UIKeyInputEscape, 0);
        for (NSNumber *modifiers in navigationModifiers)
            append(UIKeyInputDelete, modifiers.unsignedIntegerValue);

        // Return and Tab can also be consumed as responder navigation/default
        // actions. Preserve the common terminal modifier variants.
        NSArray<NSNumber *> *terminalModifiers = @[
            @0, @(UIKeyModifierShift), @(UIKeyModifierControl),
            @(UIKeyModifierAlternate),
            @(UIKeyModifierControl | UIKeyModifierShift),
            @(UIKeyModifierAlternate | UIKeyModifierShift)
        ];
        for (NSNumber *modifiers in terminalModifiers) {
            append(@"\r", modifiers.unsignedIntegerValue);
            append(@"\t", modifiers.unsignedIntegerValue);
        }
        commands = [result copy];
    });
    return commands;
}

- (void)forwardMacKeyCommand:(UIKeyCommand *)command {
    if (!self.isMacWSInputEnabled || command.input.length == 0) return;
    NSString *input = command.input;
    uint32_t keySym = 0;
    if ([input isEqualToString:UIKeyInputEscape]) keySym = 0xff1b;
    else if ([input isEqualToString:UIKeyInputDelete]) keySym = 0xff08;
    else if ([input isEqualToString:UIKeyInputUpArrow]) keySym = 0xff52;
    else if ([input isEqualToString:UIKeyInputDownArrow]) keySym = 0xff54;
    else if ([input isEqualToString:UIKeyInputLeftArrow]) keySym = 0xff51;
    else if ([input isEqualToString:UIKeyInputRightArrow]) keySym = 0xff53;
    else if ([input isEqualToString:UIKeyInputPageUp]) keySym = 0xff55;
    else if ([input isEqualToString:UIKeyInputPageDown]) keySym = 0xff56;
    else if ([input isEqualToString:UIKeyInputHome]) keySym = 0xff50;
    else if ([input isEqualToString:UIKeyInputEnd]) keySym = 0xff57;
    else {
        unichar scalar = [input characterAtIndex:0];
        if (scalar == '\r' || scalar == '\n') keySym = 0xff0d;
        else if (scalar == '\t') keySym = 0xff09;
        else if (scalar == '\b') keySym = 0xff08;
        else {
            NSInteger usage = MacWSHIDUsageForASCII(scalar);
            keySym = usage >= 0
                ? MacWSKeySymForHIDUsage(
                      usage, nil, command.modifierFlags)
                : scalar;
        }
    }
    [self emitSoftwareKeySym:keySym
                   modifiers:(uint32_t)command.modifierFlags];
}

// UIKit resolves several Command shortcuts through the responder action
// system instead of delivering them as ordinary UIPressesEvent records. This
// is especially visible for the standard editing selectors: the hardware C/V
// keys work as text in AppKit, but Command-C/Command-V can terminate at the
// focused MTKView as copy:/paste:. Keep that public UIKit route and translate
// the action back into the same complete AppKit key lifecycle used by every
// other hardware key. No pasteboard payload or target action is synthesized;
// the selected macOS application's normal menu/key-equivalent handling stays
// authoritative.
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(copy:) || action == @selector(paste:) ||
        action == @selector(cut:) || action == @selector(selectAll:) ||
        action == @selector(undo:) || action == @selector(redo:))
        return self.isMacWSInputEnabled;
    return [super canPerformAction:action withSender:sender];
}

- (void)copy:(id)sender {
    (void)sender;
    [self emitSoftwareKeySym:'c' modifiers:UIKeyModifierCommand];
}

- (void)paste:(id)sender {
    (void)sender;
    [self emitSoftwareKeySym:'v' modifiers:UIKeyModifierCommand];
}

- (void)cut:(id)sender {
    (void)sender;
    [self emitSoftwareKeySym:'x' modifiers:UIKeyModifierCommand];
}

- (void)selectAll:(id)sender {
    (void)sender;
    [self emitSoftwareKeySym:'a' modifiers:UIKeyModifierCommand];
}

- (void)undo:(id)sender {
    (void)sender;
    [self emitSoftwareKeySym:'z' modifiers:UIKeyModifierCommand];
}

- (void)redo:(id)sender {
    (void)sender;
    [self emitSoftwareKeySym:'z'
                   modifiers:UIKeyModifierCommand | UIKeyModifierShift];
}

- (BOOL)restoreHardwareKeyboardFocusWithReason:(NSString *)reason {
    if (self.softwareKeyboardActive || !self.window ||
        !self.isMacWSInputEnabled) return NO;
    BOOL alreadyFocused = self.isFirstResponder;
    BOOL focused = alreadyFocused || [self becomeFirstResponder];
    if (MacWSHostDiagnosticsEnabled()) {
        MacWSLog(@"hardware-key-focus reason=%@ focused=%@ already=%@ "
                  "scene-active=%ld target=%d frame=%ux%u",
                 reason ?: @"unspecified", focused ? @"YES" : @"NO",
                 alreadyFocused ? @"YES" : @"NO",
                 (long)self.window.windowScene.activationState,
                 self.targetPID, [self currentFrameWidth],
                 [self currentFrameHeight]);
    }
    return focused;
}

- (BOOL)emitKeyPresses:(NSSet<UIPress *> *)presses kind:(MacWSInputKind)kind {
    if (MacWSHostDiagnosticsEnabled()) {
        MacWSLog(@"hardware-key-callback kind=%u presses=%lu responder=%@ "
                  "input-enabled=%@ target=%d frame=%ux%u",
                 kind, (unsigned long)presses.count,
                 self.isFirstResponder ? @"YES" : @"NO",
                 self.isMacWSInputEnabled ? @"YES" : @"NO",
                 self.targetPID, [self currentFrameWidth],
                 [self currentFrameHeight]);
    }
    if (MacWSHardwareKeyboardOwner != self) return NO;
    if (!self.isMacWSInputEnabled && kind != MacWSInputKindKeyUp) return NO;
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (width != 0 && height != 0) {
        _lastKeyboardFrameWidth = width;
        _lastKeyboardFrameHeight = height;
    } else {
        // DisplayStream retires the old surface before publishing the resized
        // successor. Runtime log 1788371421.797 captured a real hardware key
        // callback in that interval with input enabled and target PID stable,
        // but frame=0x0 made the key disappear. Keyboard dispatch does not use
        // the pointer coordinates; retain only the same target's last valid
        // dimensions so a geometry handoff cannot swallow physical keys.
        width = _lastKeyboardFrameWidth;
        height = _lastKeyboardFrameHeight;
    }
    // A keyboard release has no coordinate dependency. Reuse the original
    // down below; the 1x1 envelope also covers a release first seen after an
    // interrupted drawable/scene transition.
    if (width == 0 || height == 0) {
        if (kind != MacWSInputKindKeyUp) return NO;
        width = height = 1;
    }
    BOOL emitted = NO;
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) continue;
        uint16_t keyCode = MacWSMacKeyCodeForHIDUsage(key.keyCode);
        if (keyCode == UINT16_MAX) continue;
        // sceneID forwards UIKit's modifier flags to AppKit as the authority
        // for Shift/Caps/Option state. If UIKit supplies a pre-transformed
        // `characters` value while declaring none of those text modifiers,
        // forwarding that transformed scalar makes the remote application
        // type uppercase even though its NSEvent has no Shift/Caps flag. Use
        // the layout-aware unmodified value in precisely that inconsistent
        // state; real Shift, Caps Lock and Option input continues to use
        // UIKit's transformed characters unchanged.
        UIKeyModifierFlags textModifiers = UIKeyModifierShift |
            UIKeyModifierAlphaShift | UIKeyModifierAlternate;
        NSString *mappedCharacters = key.characters;
        if ((key.modifierFlags & textModifiers) == 0 &&
            key.charactersIgnoringModifiers.length != 0) {
            mappedCharacters = key.charactersIgnoringModifiers;
        }
        uint32_t keySym = MacWSKeySymForHIDUsage(
            key.keyCode, mappedCharacters, key.modifierFlags);
        if (keySym == 0) continue;
        if (MacWSHostDiagnosticsEnabled()) {
            MacWSLog(@"hardware-key-map kind=%u usage=%ld keycode=%u "
                     "characters=%@ ignoring=%@ mapped=%@ modifiers=%#lx "
                     "keysym=%#x",
                     kind, (long)key.keyCode, keyCode,
                     key.characters ?: @"", key.charactersIgnoringModifiers ?: @"",
                     mappedCharacters ?: @"",
                     (unsigned long)key.modifierFlags, keySym);
        }
        CGPoint keyPoint = _trackpadCursor;
        if (keyPoint.x < 0 || keyPoint.y < 0 ||
            keyPoint.x >= width || keyPoint.y >= height)
            keyPoint = CGPointMake(width * 0.5, height * 0.5);
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = kind,
            // AppInputBridge's established v3 keyboard ABI stores AppKit-
            // compatible modifier bits in sceneID's low 32 bits.
            .sceneID = [self inputSceneIDWithModifiers:
                ((uint32_t)key.modifierFlags & ~MacWSKeyboardModifierMask) |
                    MacWSKeyboardFlagsForSides(_hardwareModifierSides)],
            .timestamp = press.timestamp,
            .x = (float)keyPoint.x,
            .y = (float)keyPoint.y,
            .pressure = (float)keyCode,
            .contactID = keySym,
            .frameWidth = width,
            .frameHeight = height,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceHardwareKeyboard,
            .sampleSequence = ++_inputSampleSequence,
            .reserved = 0x100u | _hardwareModifierSides,
        };
        NSData *originalDown = _heldHardwareKeys[@(keyCode)];
        if (kind == MacWSInputKindKeyUp && originalDown.length == sizeof(record)) {
            MacWSInputRecord original;
            [originalDown getBytes:&original length:sizeof(original)];
            record.targetPID = original.targetPID;
            record.frameWidth = original.frameWidth;
            record.frameHeight = original.frameHeight;
            record.x = original.x;
            record.y = original.y;
            record.sceneID = MacWSInputSceneForWindow(
                MacWSInputWindowIDForScene(original.sceneID),
                MacWSInputModifiersForScene(record.sceneID));
        }
        if (!_heldHardwareKeys) _heldHardwareKeys = [NSMutableDictionary dictionary];
        if (kind == MacWSInputKindKeyDown)
            _heldHardwareKeys[@(keyCode)] = [NSData dataWithBytes:&record length:sizeof(record)];
        else
            [_heldHardwareKeys removeObjectForKey:@(keyCode)];
        [self.statusDelegate metalView:self emittedInput:record];
        emitted = YES;
    }
    return emitted;
}

// A modifier release can belong to a different responder or Scene than its
// down. Use the public UIEvent snapshot at the UIWindow boundary, including
// mouse/finger edges, instead of trusting an indefinitely retained down mask.
- (void)observeHardwareModifiersForEvent:(UIEvent *)event {
    if (!event || (!self.isMacWSInputEnabled &&
                  MacWSHardwareKeyboardOwner != self)) return;
    static const NSInteger usages[] = {225,229,224,228,226,230,227,231};
    uint8_t downs = 0, ups = 0, sides = 0;
    BOOL edge = !_ownsHardwareKeyboard;
    if ([event isKindOfClass:UIPressesEvent.class]) {
        for (UIPress *press in ((UIPressesEvent *)event).allPresses) {
            BOOL down = press.phase == UIPressPhaseBegan;
            BOOL up = press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled;
            if (!down && !up) continue;
            edge = YES;
            for (unsigned i = 0; press.key && i < 8; ++i) {
                if (press.key.keyCode != usages[i]) continue;
                if (down) downs |= (uint8_t)(1u << i);
                else ups |= (uint8_t)(1u << i);
            }
        }
    } else if (event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan || touch.phase == UITouchPhaseEnded ||
                touch.phase == UITouchPhaseCancelled) edge = YES;
        }
    } else {
        return;
    }
    uint32_t modifiers = (uint32_t)event.modifierFlags;
    if (MacWSHardwareKeyboardOwner != self) {
        [MacWSHardwareKeyboardOwner releaseHardwareKeyboardState];
        MacWSHardwareKeyboardOwner = self;
        edge = YES;
    }
    if (!MacWSKeyboardSourceApplyOwned(&_hardwareModifierSource,
            self.isMacWSInputEnabled, MacWSHardwareKeyboardOwner == self,
            modifiers, downs, ups, &sides)) return;
    if (!edge && sides == _hardwareModifierSides) return;
    _hardwareModifierSides = sides;
    _ownsHardwareKeyboard = YES;
    modifiers = (modifiers & ~MacWSKeyboardModifierMask) |
        MacWSKeyboardFlagsForSides(sides);
    MacWSInputRecord snapshot = {
        .magic = MACWS_INPUT_MAGIC, .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindModifierSnapshot,
        .sceneID = MacWSInputSceneForWindow(0, modifiers),
        .timestamp = event.timestamp,
        .source = MacWSInputSourceHardwareKeyboard,
        .reserved = sides, .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:snapshot];
}

- (void)releaseHardwareKeyboardState {
    // Retired Scenes can receive delayed background/cancel callbacks after a
    // new Scene has acquired the keyboard. Never release the new owner's keys.
    if (MacWSHardwareKeyboardOwner != self) {
        [_heldHardwareKeys removeAllObjects];
        _ownsHardwareKeyboard = NO;
        _hardwareModifierSides = 0;
        _hardwareModifierSource = (MacWSKeyboardSourceState){0};
        return;
    }
    if (!_ownsHardwareKeyboard && _heldHardwareKeys.count == 0) return;
    // Preserve the exact key's original destination even if the presentation
    // target changed, and permit release after the drawable was retired.
    for (NSData *value in _heldHardwareKeys.allValues) {
        MacWSInputRecord release;
        [value getBytes:&release length:sizeof(release)];
        release.kind = MacWSInputKindKeyUp;
        release.timestamp = CACurrentMediaTime();
        release.sceneID = MacWSInputSceneForWindow(
            MacWSInputWindowIDForScene(release.sceneID), 0);
        release.reserved = 0x100u;
        release.sampleSequence = ++_inputSampleSequence;
        [self.statusDelegate metalView:self emittedInput:release];
    }
    [_heldHardwareKeys removeAllObjects];
    _hardwareModifierSides = 0;
    _hardwareModifierSource = (MacWSKeyboardSourceState){0};
    _ownsHardwareKeyboard = NO;
    MacWSInputRecord snapshot = {
        .magic = MACWS_INPUT_MAGIC, .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindModifierSnapshot,
        .timestamp = CACurrentMediaTime(), .contactID = 1,
        .source = MacWSInputSourceHardwareKeyboard,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:snapshot];
    MacWSHardwareKeyboardOwner = nil;
}

- (BOOL)forwardHardwarePresses:(NSSet<UIPress *> *)presses
                       keyDown:(BOOL)keyDown {
    return [self emitKeyPresses:presses
                           kind:keyDown ? MacWSInputKindKeyDown
                                        : MacWSInputKindKeyUp];
}

- (void)emitSoftwareKeySym:(uint32_t)keySym modifiers:(uint32_t)modifiers {
    if (!self.isMacWSInputEnabled || keySym == 0) return;
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (width != 0 && height != 0) {
        _lastKeyboardFrameWidth = width;
        _lastKeyboardFrameHeight = height;
    } else {
        width = _lastKeyboardFrameWidth;
        height = _lastKeyboardFrameHeight;
    }
    if (width == 0 || height == 0) return;
    uint32_t scalar = (keySym & 0xff000000u) == 0x01000000u
        ? keySym & 0x00ffffffu : keySym;
    NSInteger usage = MacWSHIDUsageForASCII(scalar);
    uint16_t keyCode = usage >= 0
        ? MacWSMacKeyCodeForHIDUsage(usage) : 0;
    switch (keySym) {
        case 0xff08: keyCode = 51; break;
        case 0xff09: keyCode = 48; break;
        case 0xff0d: keyCode = 36; break;
        case 0xff1b: keyCode = 53; break;
        case 0xff51: keyCode = 123; break;
        case 0xff52: keyCode = 126; break;
        case 0xff53: keyCode = 124; break;
        case 0xff54: keyCode = 125; break;
        case 0xff50: keyCode = 115; break;
        case 0xff55: keyCode = 116; break;
        case 0xff56: keyCode = 121; break;
        case 0xff57: keyCode = 119; break;
        default: break;
    }
    CGPoint point = _trackpadCursor;
    if (point.x < 0 || point.y < 0 || point.x >= width || point.y >= height)
        point = CGPointMake(width * 0.5, height * 0.5);
    for (MacWSInputKind kind = MacWSInputKindKeyDown;
         kind <= MacWSInputKindKeyUp; kind++) {
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = kind,
            .sceneID = [self inputSceneIDWithModifiers:modifiers],
            .timestamp = CACurrentMediaTime(),
            .x = (float)point.x,
            .y = (float)point.y,
            .pressure = (float)keyCode,
            .contactID = keySym,
            .frameWidth = width,
            .frameHeight = height,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceSoftwareKeyboard,
            .sampleSequence = ++_inputSampleSequence,
        };
        [self.statusDelegate metalView:self emittedInput:record];
    }
}

- (void)emitSoftwareText:(NSString *)text modifiers:(uint32_t)modifiers {
    if (!text.length) return;
    NSData *utf32 = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint32_t *scalars = utf32.bytes;
    for (NSUInteger index = 0; index < utf32.length / sizeof(uint32_t); index++) {
        uint32_t scalar = scalars[index];
        uint32_t keySym = scalar > 0xffu ? 0x01000000u | scalar : scalar;
        if (scalar == '\n' || scalar == '\r') keySym = 0xff0d;
        else if (scalar == '\t') keySym = 0xff09;
        else if (scalar == '\b') keySym = 0xff08;
        [self emitSoftwareKeySym:keySym modifiers:modifiers];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self emitKeyPresses:presses kind:MacWSInputKindKeyDown];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self emitKeyPresses:presses kind:MacWSInputKindKeyUp];
    [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses
                withEvent:(UIPressesEvent *)event {
    [self emitKeyPresses:presses kind:MacWSInputKindKeyUp];
    [super pressesCancelled:presses withEvent:event];
}

- (void)buildPipeline {
    if (!self.device) {
        [self publishStatus:@"此设备没有可用的原生 Metal Device"];
        return;
    }
    static NSString *const shaderSource =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct VOut { float4 position [[position]]; float2 uv; };\n"
         "vertex VOut macws_vertex(uint vid [[vertex_id]],\n"
         "    constant float4 *vertices [[buffer(0)]]) {\n"
         "  VOut o; o.position = float4(vertices[vid].xy, 0.0, 1.0);\n"
         "  o.uv = vertices[vid].zw; return o;\n"
         "}\n"
         "half4 macws_quality_sample(texture2d<half> image, float2 uv) {\n"
         "  constexpr sampler s(coord::normalized, address::clamp_to_edge,\n"
         "                      filter::linear);\n"
         "  half4 center = image.sample(s, uv);\n"
         "  float2 size = float2(image.get_width(), image.get_height());\n"
         "  float2 dx = dfdx(uv) * size;\n"
         "  float2 dy = dfdy(uv) * size;\n"
         "  float sourcePerPixelX = length(float2(dx.x, dy.x));\n"
         "  float sourcePerPixelY = length(float2(dx.y, dy.y));\n"
         "  if (sourcePerPixelX >= 0.995f && sourcePerPixelY >= 0.995f)\n"
         "    return center;\n"
         "  float2 texel = 1.0f / size;\n"
         "  half3 left = image.sample(s, uv - float2(texel.x, 0.0f)).rgb;\n"
         "  half3 right = image.sample(s, uv + float2(texel.x, 0.0f)).rgb;\n"
         "  half3 up = image.sample(s, uv - float2(0.0f, texel.y)).rgb;\n"
         "  half3 down = image.sample(s, uv + float2(0.0f, texel.y)).rgb;\n"
         "  half3 low = min(center.rgb, min(min(left, right), min(up, down)));\n"
         "  half3 high = max(center.rgb, max(max(left, right), max(up, down)));\n"
         "  half3 sharpened = center.rgb * 1.4h\n"
         "      - (left + right + up + down) * 0.1h;\n"
         "  return half4(clamp(sharpened, low, high), center.a);\n"
         "}\n"
         "fragment half4 macws_fragment(VOut in [[stage_in]],\n"
         "    texture2d<half> image [[texture(0)]]) {\n"
         "  return macws_quality_sample(image, in.uv);\n"
         "}\n"
         "fragment half4 macws_fragment_opaque(VOut in [[stage_in]],\n"
         "    texture2d<half> image [[texture(0)]]) {\n"
         "  half4 pixel = macws_quality_sample(image, in.uv);\n"
         "  return half4(pixel.rgb, 1.0h);\n"
         "}\n"
         "fragment half4 macws_direct_composite(VOut in [[stage_in]],\n"
         "    texture2d<half> desktop [[texture(0)]],\n"
         "    texture2d<half> direct [[texture(1)]],\n"
         "    constant float4 *geometry [[buffer(0)]]) {\n"
         "  float4 destination = geometry[0];\n"
         "  if (in.uv.x >= destination.x && in.uv.x <= destination.z &&\n"
         "      in.uv.y >= destination.y && in.uv.y <= destination.w) {\n"
         "    float2 fraction = (in.uv - destination.xy) /\n"
         "        (destination.zw - destination.xy);\n"
         "    float4 source = geometry[1];\n"
         "    float2 directUV = mix(source.xy, source.zw, fraction);\n"
         "    half4 foreground = macws_quality_sample(direct, directUV);\n"
         "    if (foreground.a >= 0.999h) return foreground;\n"
         "    half4 background = macws_quality_sample(desktop, in.uv);\n"
         "    return foreground + background * (1.0h - foreground.a);\n"
         "  }\n"
         "  return macws_quality_sample(desktop, in.uv);\n"
         "}\n"
         "fragment half4 macws_shadow(VOut in [[stage_in]],\n"
         "    constant float4 *geometry [[buffer(0)]]) {\n"
         "  float2 quad = geometry[0].xy;\n"
         "  float2 innerOrigin = geometry[0].zw;\n"
         "  float2 innerSize = geometry[1].xy;\n"
         "  float radius = geometry[1].z;\n"
         "  float sigma = geometry[1].w;\n"
         "  float2 p = in.uv * quad - (innerOrigin + innerSize * 0.5);\n"
         "  float2 q = abs(p) - (innerSize * 0.5 - radius);\n"
         "  float distance = length(max(q, 0.0))\n"
         "      + min(max(q.x, q.y), 0.0) - radius;\n"
         "  float outside = max(distance, 0.0);\n"
         "  half alpha = half(0.30 * exp(-(outside * outside)\n"
         "      / (2.0 * sigma * sigma)));\n"
         "  return half4(0.0h, 0.0h, 0.0h, alpha);\n"
         "}\n";
    NSError *error = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:shaderSource
                                                      options:nil error:&error];
    if (!library) {
        [self publishStatus:[NSString stringWithFormat:@"Metal shader 编译失败: %@",
                             error.localizedDescription ?: @"未知错误"]];
        return;
    }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = @"MacWSHost BGRA display pipeline";
    descriptor.vertexFunction = [library newFunctionWithName:@"macws_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"macws_fragment"];
    descriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    _pipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor
                                                             error:&error];
    if (!_pipeline) {
        [self publishStatus:[NSString stringWithFormat:@"Metal pipeline 创建失败: %@",
                             error.localizedDescription ?: @"未知错误"]];
    }
    // A validated FullscreenCanvas is an opaque display authority.  Its
    // CAMetalLayer backing can nevertheless retain non-255 alpha values that
    // are meaningful inside the producer but are not a request to blend an
    // obsolete WindowServer snapshot behind the fullscreen game.  Keep the
    // ordinary premultiplied-alpha pipeline for desktop/native windows and
    // use this sibling only after the exact fullscreen drawable join.
    descriptor.label = @"MacWSHost opaque fullscreen drawable pipeline";
    // Runtime-confirmed from Stray pid 9198 drawable surface 687 on
    // 2026-08-29: all 1,296,000 alpha bytes are zero while every RGB pixel is
    // nonzero and contains the complete game scene. Disabling blending alone
    // copies that zero alpha into the CAMetalDrawable, so the downstream
    // UIKit compositor treats the otherwise-correct game pixels as
    // transparent. FullscreenCanvas is already the exact opaque authority;
    // make its output alpha match that semantic ownership.
    descriptor.fragmentFunction =
        [library newFunctionWithName:@"macws_fragment_opaque"];
    descriptor.colorAttachments[0].blendingEnabled = NO;
    _opaquePipeline = [self.device
        newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_opaquePipeline) {
        [self publishStatus:[NSString stringWithFormat:
            @"全屏 drawable pipeline 创建失败: %@",
            error.localizedDescription ?: @"未知错误"]];
    }
    // A focused descendant drawable is absent from WindowServer's final
    // composite. Sampling the complete desktop and then drawing that opaque
    // client rectangle as a second pass shades most of the display twice.
    // Compose both sources in one fragment pass: each pixel normally samples
    // exactly one texture, while a genuinely translucent direct pixel still
    // performs the mathematically required premultiplied-alpha blend.
    descriptor.label = @"MacWSHost focused direct composite pipeline";
    descriptor.fragmentFunction =
        [library newFunctionWithName:@"macws_direct_composite"];
    descriptor.colorAttachments[0].blendingEnabled = NO;
    _directCompositePipeline = [self.device
        newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_directCompositePipeline) {
        [self publishStatus:[NSString stringWithFormat:
            @"直传合成 pipeline 创建失败: %@",
            error.localizedDescription ?: @"未知错误"]];
    }
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.label = @"MacWSHost native-window shadow pipeline";
    descriptor.fragmentFunction = [library newFunctionWithName:@"macws_shadow"];
    _shadowPipeline = [self.device
        newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_shadowPipeline) {
        [self publishStatus:[NSString stringWithFormat:
            @"窗口阴影 pipeline 创建失败: %@",
            error.localizedDescription ?: @"未知错误"]];
    }
}

- (void)publishStatus:(NSString *)status {
    if (!status || [_lastStatus isEqualToString:status]) return;
    _lastStatus = [status copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.statusDelegate metalView:self statusChanged:status];
    });
}

- (BOOL)ensureSourceTexture {
    if (_sourceTexture && _textureWidth == _frame.width &&
        _textureHeight == _frame.height) return YES;
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:_frame.width
                                                          height:_frame.height
                                                       mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    _sourceTexture = [self.device newTextureWithDescriptor:descriptor];
    _sourceTexture.label = @"MacWSHost mmap upload";
    _textureWidth = _frame.width;
    _textureHeight = _frame.height;
    _reportedNonzeroFrame = NO;
    return _sourceTexture != nil;
}

- (void)updateContentRectAndVertices:(simd_float4 [4])vertices {
    CGFloat viewWidth = self.bounds.size.width;
    CGFloat viewHeight = self.bounds.size.height;
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];

    // A low-resolution game window remains a real layer inside the native
    // full-resolution desktop.  For bundle-declared fullscreen canvases,
    // crop the completed WindowServer composite to that exact layer's
    // destination and fit it to the iPad Scene.  Because _visibleSourceRect
    // is also the input transform below, keyboard/pointer activation and
    // pixels retain one coordinate authority.  The source is still the final
    // composite, so Steam's separately composited FPS panel is preserved.
    CGRect fullscreenCanvasPixels = CGRectZero;
    BOOL focusFullscreenCanvas = NO;
    uint32_t fullscreenCanvasWindowID = 0;
    if (_viewportZoom <= 1.001 &&
        _streamClient.mode == MacWSStreamModeFullscreen &&
        self.targetPID > 1 &&
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)] &&
        [self hasFinalCompositeFrame] && frameWidth > 0 && frameHeight > 0) {
        uint32_t preferredWindowID = 0;
        uint64_t preferredScore = 0;
        for (MacWSStreamWindow *window in _latestWindows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            // During Stray's AppKit fullscreen transition the live catalog
            // publishes 0x140 (Focused|FullscreenCanvas) without the ordinary
            // ordered-window Visible/OnScreen bits. The matching live layer
            // below remains the pixel/geometry witness; rejecting that exact
            // bundle capability here collapsed presentation back to the
            // uncropped desktop even while its 1024x768 stream advanced.
            if (descriptor.ownerPID != self.targetPID ||
                descriptor.windowID == 0 ||
                (descriptor.flags & MacWSStreamWindowFullscreenCanvas) == 0)
                continue;
            uint64_t area = (uint64_t)descriptor.pixelWidth *
                (uint64_t)descriptor.pixelHeight;
            uint64_t score = area +
                ((descriptor.flags & MacWSStreamWindowFocused) != 0
                    ? UINT64_C(1) << 62 : 0);
            if (score > preferredScore) {
                preferredScore = score;
                preferredWindowID = descriptor.windowID;
            }
        }
        MacWSSurfaceFrame *layer = preferredWindowID != 0
            ? _overlayFrames[@(preferredWindowID)] : nil;
        if (!layer) {
            // SkyLight can retire the AppKit window ID that published the
            // capability while immediately replacing it with a new backing
            // layer for the same process. Follow only this already-validated
            // target PID and choose its largest current surface; do not infer
            // game identity from names, titles or dimensions.
            uint64_t largestArea = 0;
            for (MacWSSurfaceFrame *candidateLayer in
                    _overlayFrames.allValues) {
                MacWSStreamFrameDescriptor candidateDescriptor =
                    candidateLayer.descriptor;
                if (candidateDescriptor.layerOwnerPID != self.targetPID ||
                    candidateDescriptor.layerWindowID == 0) continue;
                uint64_t area =
                    (uint64_t)candidateDescriptor.destinationWidth *
                    (uint64_t)candidateDescriptor.destinationHeight;
                if (area > largestArea) {
                    largestArea = area;
                    layer = candidateLayer;
                }
            }
        }
        if (layer) {
            MacWSStreamFrameDescriptor descriptor = layer.descriptor;
            CGRect canvas = CGRectMake(0, 0, frameWidth, frameHeight);
            CGRect candidate = CGRectMake(
                descriptor.destinationX, descriptor.destinationY,
                descriptor.destinationWidth, descriptor.destinationHeight);
            candidate = CGRectIntersection(candidate, canvas);
            if (descriptor.layerOwnerPID == self.targetPID &&
                descriptor.layerWindowID != 0 &&
                !CGRectIsNull(candidate) && !CGRectIsEmpty(candidate) &&
                candidate.size.width >= 320.0 &&
                candidate.size.height >= 240.0) {
                fullscreenCanvasPixels = candidate;
                focusFullscreenCanvas = YES;
                fullscreenCanvasWindowID = descriptor.layerWindowID;
            }
        }
    }
    // SkyLight can retire the exact fullscreen layer after it has handed the
    // Catalyst CAMetalLayer off to the Host.  Runtime-confirmed by
    // MacWSHost.log for Stray pid 16096 on 2026-08-25: window 188 was first
    // validated as Focused|FullscreenCanvas, then the catalog and overlay
    // entries both disappeared while the same AppInput endpoint and completed
    // 1400x900 drawable continued.  Retain the already-validated geometry
    // across only that window-generation gap.  Target changes, capability
    // revocation, or endpoint death invalidate it independently.
    BOOL preserveFullscreenCanvasIdentity =
        _reportedFullscreenCanvasPID == self.targetPID &&
        _reportedFullscreenCanvasWindowID != 0 &&
        !CGRectIsEmpty(_reportedFullscreenCanvasPixels) &&
        self.targetPID > 1 &&
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)];
    BOOL retainedFullscreenCanvas = !focusFullscreenCanvas &&
        preserveFullscreenCanvasIdentity &&
        MacWSAppInputEndpointReady(self.targetPID) &&
        [self hasFinalCompositeFrame] && frameWidth > 0 && frameHeight > 0;
    if (retainedFullscreenCanvas) {
        CGRect canvas = CGRectMake(0, 0, frameWidth, frameHeight);
        CGRect retained = CGRectIntersection(
            _reportedFullscreenCanvasPixels, canvas);
        if (!CGRectIsNull(retained) && !CGRectIsEmpty(retained)) {
            fullscreenCanvasPixels = retained;
            fullscreenCanvasWindowID = _reportedFullscreenCanvasWindowID;
            focusFullscreenCanvas = YES;
        }
    }
    if (focusFullscreenCanvas && viewWidth > 0 && viewHeight > 0) {
        if (_reportedFullscreenCanvasPID != self.targetPID ||
            _reportedFullscreenCanvasWindowID != fullscreenCanvasWindowID) {
            _reportedFullscreenCanvasPID = self.targetPID;
            _reportedFullscreenCanvasWindowID = fullscreenCanvasWindowID;
            MacWSLog(@"runtime-confirmed fullscreen-canvas-focus pid=%d "
                     "window=%u source=(%.0f,%.0f %.0fx%.0f) "
                     "desktop=%ux%u",
                     self.targetPID, fullscreenCanvasWindowID,
                     fullscreenCanvasPixels.origin.x,
                     fullscreenCanvasPixels.origin.y,
                     fullscreenCanvasPixels.size.width,
                     fullscreenCanvasPixels.size.height,
                     frameWidth, frameHeight);
        }
        _reportedFullscreenCanvasPixels = fullscreenCanvasPixels;
        // Vertices are normalized against the UIKit view, not against the
        // drawable allocation.  A source-native drawable may deliberately
        // have a different aspect ratio from the Scene (for example when the
        // software-key row removes only vertical space).  Converting through
        // independent drawable X/Y scales makes the fitted rectangle fill the
        // view and stretches the image.  Fit once in view coordinates so the
        // same rectangle remains authoritative for pixels and input.
        CGFloat scale = MIN(
            viewWidth / fullscreenCanvasPixels.size.width,
            viewHeight / fullscreenCanvasPixels.size.height);
        CGFloat fittedWidth = fullscreenCanvasPixels.size.width * scale;
        CGFloat fittedHeight = fullscreenCanvasPixels.size.height * scale;
        _contentRect = CGRectMake(
            (viewWidth - fittedWidth) * 0.5,
            (viewHeight - fittedHeight) * 0.5,
            fittedWidth, fittedHeight);
        _visibleSourceRect = CGRectMake(
            fullscreenCanvasPixels.origin.x / frameWidth,
            fullscreenCanvasPixels.origin.y / frameHeight,
            fullscreenCanvasPixels.size.width / frameWidth,
            fullscreenCanvasPixels.size.height / frameHeight);
        _viewportCenter = CGPointMake(CGRectGetMidX(_visibleSourceRect),
                                      CGRectGetMidY(_visibleSourceRect));
        CGFloat left = CGRectGetMinX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat right = CGRectGetMaxX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat top = 1.0 - CGRectGetMinY(_contentRect) / viewHeight * 2.0;
        CGFloat bottom = 1.0 - CGRectGetMaxY(_contentRect) / viewHeight * 2.0;
        CGFloat minX = CGRectGetMinX(_visibleSourceRect);
        CGFloat maxX = CGRectGetMaxX(_visibleSourceRect);
        CGFloat minY = CGRectGetMinY(_visibleSourceRect);
        CGFloat maxY = CGRectGetMaxY(_visibleSourceRect);
        vertices[0] = (simd_float4){left, bottom, minX, maxY};
        vertices[1] = (simd_float4){right, bottom, maxX, maxY};
        vertices[2] = (simd_float4){left, top, minX, minY};
        vertices[3] = (simd_float4){right, top, maxX, minY};
        return;
    }
    if (_reportedFullscreenCanvasWindowID != 0 &&
        !preserveFullscreenCanvasIdentity) {
        MacWSLog(@"fullscreen-canvas-focus cleared pid=%d window=%u",
                 _reportedFullscreenCanvasPID,
                 _reportedFullscreenCanvasWindowID);
        _reportedFullscreenCanvasPID = 0;
        _reportedFullscreenCanvasWindowID = 0;
        _reportedFullscreenCanvasPixels = CGRectZero;
    }
    // Window mode is not a video fit operation.  Keep its selected native
    // density invariant while UIKit and AppKit publish adjacent geometry
    // generations.  A temporarily larger Scene letterboxes the unchanged
    // surface; a temporarily smaller Scene clips it.  Neither case shrinks or
    // enlarges the application's pixels.  The controller concurrently asks
    // iPadOS to settle on the matching native Scene size.  Fullscreen remains
    // a fitted desktop, and deliberate 1.5x/2x zoom uses the crop/pan path.
    if (_viewportZoom <= 1.001 && frameWidth > 0 && frameHeight > 0 &&
        viewWidth > 0 && viewHeight > 0) {
        MacWSNativePresentationRect nativeRect = {0};
        BOOL nativeWindow = _streamClient.mode == MacWSStreamModeWindow;
        CGFloat backingScale = _surfaceFrame.descriptor.backingScale;
        if (!isfinite(backingScale) || backingScale < 0.5 ||
            backingScale > 8.0) backingScale = 2.0;
        BOOL hasNativeRect = nativeWindow &&
            MacWSComputeNativeWindowPresentationRect(
                frameWidth, frameHeight, backingScale,
                self.effectiveDensityScale, viewWidth, viewHeight,
                &nativeRect);
        if (hasNativeRect) {
            _contentRect = CGRectMake(nativeRect.x, nativeRect.y,
                                      nativeRect.width, nativeRect.height);
        } else {
            CGFloat scale = MIN(viewWidth / frameWidth,
                                viewHeight / frameHeight);
            CGFloat fittedWidth = frameWidth * scale;
            CGFloat fittedHeight = frameHeight * scale;
            _contentRect = CGRectMake((viewWidth - fittedWidth) * 0.5,
                                      (viewHeight - fittedHeight) * 0.5,
                                      fittedWidth, fittedHeight);
        }
        _visibleSourceRect = CGRectMake(0, 0, 1, 1);
        _viewportCenter = CGPointMake(0.5, 0.5);
        _viewportZoom = 1.0;
        CGFloat left = CGRectGetMinX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat right = CGRectGetMaxX(_contentRect) / viewWidth * 2.0 - 1.0;
        CGFloat top = 1.0 - CGRectGetMinY(_contentRect) / viewHeight * 2.0;
        CGFloat bottom = 1.0 - CGRectGetMaxY(_contentRect) / viewHeight * 2.0;
        vertices[0] = (simd_float4){left, bottom, 0, 1};
        vertices[1] = (simd_float4){right, bottom, 1, 1};
        vertices[2] = (simd_float4){left, top, 0, 0};
        vertices[3] = (simd_float4){right, top, 1, 0};
        return;
    }
    MacWSViewport viewport = {0};
    BOOL valid = MacWSComputeViewport(
        frameWidth, frameHeight, viewWidth, viewHeight, _viewportZoom,
        _viewportCenter.x, _viewportCenter.y, &viewport);
    if (!valid) {
        viewport = (MacWSViewport){
            .visibleSource = {0, 0, 1, 1},
            .centerX = 0.5,
            .centerY = 0.5,
            .zoom = 1.0,
        };
    }
    _viewportZoom = viewport.zoom;
    _viewportCenter = CGPointMake(viewport.centerX, viewport.centerY);
    _visibleSourceRect = CGRectMake(
        viewport.visibleSource.x, viewport.visibleSource.y,
        viewport.visibleSource.width, viewport.visibleSource.height);
    _contentRect = self.bounds;
    CGFloat minX = CGRectGetMinX(_visibleSourceRect);
    CGFloat maxX = CGRectGetMaxX(_visibleSourceRect);
    CGFloat minY = CGRectGetMinY(_visibleSourceRect);
    CGFloat maxY = CGRectGetMaxY(_visibleSourceRect);
    // A user-requested enlarged view fills the Scene and pans over a bounded
    // source crop.
    vertices[0] = (simd_float4){-1, -1, minX, maxY};
    vertices[1] = (simd_float4){ 1, -1, maxX, maxY};
    vertices[2] = (simd_float4){-1,  1, minX, minY};
    vertices[3] = (simd_float4){ 1,  1, maxX, minY};
}

- (void)updatePresentationGeometry {
    simd_float4 unusedVertices[4];
    [self updateContentRectAndVertices:unusedVertices];
    [self updatePointerVisibility];
}

- (BOOL)frameHasSampledContent {
    if (!_frame.pixels) return NO;
    size_t samples = 128;
    for (size_t i = 0; i < samples; i++) {
        size_t x = (i * 7919u) % _frame.width;
        size_t y = (i * 104729u) % _frame.height;
        const uint8_t *pixel = _frame.pixels + y * _frame.stride + x * 4;
        if (pixel[0] || pixel[1] || pixel[2]) return YES;
    }
    return NO;
}

- (uint64_t)fallbackFrameSignature {
    uint64_t hash = 1469598103934665603ull;
    size_t payloadSize = (size_t)_frame.stride * _frame.height;
    size_t step = payloadSize / 4096;
    if (step < 4) step = 4;
    for (size_t offset = 0; offset < payloadSize; offset += step) {
        hash ^= _frame.pixels[offset];
        hash *= 1099511628211ull;
    }
    hash ^= ((uint64_t)_frame.width << 32) | _frame.height;
    return hash;
}

- (void)pollSharedFrame:(CADisplayLink *)displayLink {
    (void)displayLink;
    uint64_t generation = 0;
    if (!MacWSReadCaptureAck(&generation)) {
        if (_presentedCaptureGeneration != 0 ||
            _pendingCaptureGeneration != 0) {
            _presentedCaptureGeneration = 0;
            _pendingCaptureGeneration = 0;
            _fallbackImageView.image = nil;
            (void)[_frame refresh];
            if (self.device) [self setNeedsDisplay];
            [self publishStatus:_frame.lastError ?: @"等待已确认的共享帧"];
        }
        return;
    }
    if (generation == _presentedCaptureGeneration) return;
    if (generation != _pendingCaptureGeneration)
        _pendingCaptureGeneration = generation;
    if (self.device) {
        [self setNeedsDisplay];
    } else {
        [self drawFallbackFrame];
    }
}

- (void)drawFallbackFrame {
    if (![_frame refresh]) {
        [self publishStatus:_frame.lastError ?: @"等待共享帧"];
        return;
    }
    simd_float4 unusedVertices[4];
    [self updateContentRectAndVertices:unusedVertices];
    uint64_t signature = [self fallbackFrameSignature];
    if (_fallbackImageView.image && signature == _fallbackSignature) {
        _presentedCaptureGeneration = _pendingCaptureGeneration;
        _pendingCaptureGeneration = 0;
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  快照 #%llu  ·  像素未变化",
            _frame.width, _frame.height,
            (unsigned long long)_presentedCaptureGeneration]];
        return;
    }

    size_t payloadSize = (size_t)_frame.stride * _frame.height;
    NSData *snapshot = [NSData dataWithBytes:_frame.pixels length:payloadSize];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(
        (__bridge CFDataRef)snapshot);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little |
        kCGImageAlphaPremultipliedFirst;
    CGImageRef image = CGImageCreate(_frame.width, _frame.height, 8, 32,
        _frame.stride, colorSpace, bitmapInfo, provider, NULL, false,
        kCGRenderingIntentDefault);
    if (image) {
        _fallbackImageView.image = [UIImage imageWithCGImage:image];
        CGImageRelease(image);
        _fallbackSignature = signature;
        _presentedCaptureGeneration = _pendingCaptureGeneration;
        _pendingCaptureGeneration = 0;
        BOOL nonzero = [self frameHasSampledContent];
        if (nonzero && !_reportedFallbackFrame) {
            _reportedFallbackFrame = YES;
            MacWSLog(@"runtime-confirmed UIKit fallback frame nonzero %ux%u stride=%u",
                     _frame.width, _frame.height, _frame.stride);
        }
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  快照 #%llu  ·  UIKit fallback",
            _frame.width, _frame.height,
            (unsigned long long)_presentedCaptureGeneration]];
    } else {
        [self publishStatus:@"UIKit fallback 无法创建 BGRA 图像"];
    }
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
}

- (MacWSCatalystDrawableFrame *)authoritativeFullscreenDrawableFrame {
    // This is the same pixel authority used by both the renderer and the
    // fullscreen hit test. A live desktop catalog may describe a window
    // *behind* this opaque drawable; it cannot be consulted for visible hits.
    if (_streamClient.mode != MacWSStreamModeFullscreen ||
        self.targetWindowID != 0 || !_surfaceFrame || !_surfaceTexture ||
        !_opaquePipeline || self.targetPID <= 1 ||
        ![_fullscreenCanvasPIDs containsObject:@(self.targetPID)] ||
        _directDrawableHeartbeatPID != self.targetPID ||
        _reportedFullscreenCanvasPID != self.targetPID ||
        _reportedFullscreenCanvasWindowID == 0 ||
        _reportedFullscreenCanvasWindowID !=
            _directDrawableHeartbeatLayerID ||
        CGRectIsEmpty(_reportedFullscreenCanvasPixels) ||
        !MacWSAppInputEndpointReady(self.targetPID) ||
        _lastDirectDrawableHeartbeatTime <= 0.0) return nil;
    CFTimeInterval age =
        CACurrentMediaTime() - _lastDirectDrawableHeartbeatTime;
    if (age < 0.0 || age > 3.0) return nil;
    MacWSSurfaceFrame *layer =
        _overlayFrames[@(_directDrawableHeartbeatLayerID)];
    if (layer && (layer.descriptor.layerOwnerPID != self.targetPID ||
                  layer.descriptor.layerWindowID !=
                      _directDrawableHeartbeatLayerID)) return nil;
    MacWSCatalystDrawableFrame *frame =
        _scheduledCatalystDrawableFrame.record.ownerPID == self.targetPID
            ? _scheduledCatalystDrawableFrame
            : [_catalystDrawableCompositor frameForOwnerPID:self.targetPID];
    BOOL geometryMatchesHeartbeat = frame &&
        frame.record.width == _directDrawableHeartbeatWidth &&
        frame.record.height == _directDrawableHeartbeatHeight;
    return frame.texture && geometryMatchesHeartbeat ? frame : nil;
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_pipeline || !_commandQueue) return;
    BOOL directSchedulerCandidate = NO;
    MacWSDirectDrawableScheduleOutcome directScheduleOutcome =
        MacWSDirectDrawableScheduleOutcomeUnknown;
    if (_directDrawableContinuousPacing) {
        if (!_scheduledCatalystDrawableFrame) {
            // Resize does not invalidate already-completed drawable records.
            // Consume and release predecessors until the FIFO reaches the
            // geometry generation independently joined to the focused
            // window. Otherwise an old-size record can remain selected
            // forever: it is correctly refused by the renderer, but was
            // previously cleared only after a successful submission.
            for (;;) {
                MacWSCatalystDrawableFrame *candidate =
                    [_catalystDrawableCompositor dequeueFrameForOwnerPID:
                        self.targetPID];
                if (!candidate) break;
                BOOL joinedGeometry =
                    _directDrawableHeartbeatPID == self.targetPID &&
                    _directDrawableHeartbeatWidth != 0 &&
                    _directDrawableHeartbeatHeight != 0;
                if (!joinedGeometry ||
                    (candidate.record.width ==
                         _directDrawableHeartbeatWidth &&
                     candidate.record.height ==
                         _directDrawableHeartbeatHeight)) {
                    _scheduledCatalystDrawableFrame = candidate;
                    break;
                }
            }
        }
        BOOL hasScheduledFrame = _scheduledCatalystDrawableFrame != nil;
        directSchedulerCandidate = hasScheduledFrame;
        [_performanceMonitor
            recordDirectDrawableSchedulerTickWithFrame:hasScheduledFrame];
        if (!_reportedDirectDrawableTickWitness) {
            CFTimeInterval now = CACurrentMediaTime();
            if (_directDrawableTickWitnessCount == 0)
                _directDrawableTickWitnessStart = now;
            _directDrawableTickWitnessCount++;
            if (hasScheduledFrame)
                _directDrawableTickWitnessPendingCount++;
            if (_directDrawableTickWitnessCount >= 120) {
                CFTimeInterval elapsed =
                    now - _directDrawableTickWitnessStart;
                _reportedDirectDrawableTickWitness = YES;
                MacWSLog(@"runtime-confirmed mtk-scheduler-witness "
                         "ticks=%lu pending=%lu elapsed-ms=%.3f tick-fps=%.3f",
                         (unsigned long)_directDrawableTickWitnessCount,
                         (unsigned long)_directDrawableTickWitnessPendingCount,
                         elapsed * 1000.0,
                         elapsed > 0.0
                            ? (_directDrawableTickWitnessCount - 1) / elapsed
                            : 0.0);
            }
        }
        if (!hasScheduledFrame) {
            // Do not acquire or submit a drawable when the producer has not
            // completed a new IOSurface. Runtime-confirmed by the first
            // scheduler witness: pausing after two empty callbacks made 120
            // active ticks span 13.50 seconds even though 115 already had a
            // new frame. Keep the scheduler stable across producer/display
            // phase crossings, then restore event-driven desktop mode only
            // after a genuine 250-ms content silence.
            CFTimeInterval idle = CACurrentMediaTime() -
                _lastDirectDrawableReceiptTime;
            if (idle >= 0.25) {
                _directDrawableContinuousPacing = NO;
                self.paused = YES;
                MacWSClearMTKDisplayLinkHighFrameRateReason(self);
                self.enableSetNeedsDisplay = YES;
                ((CAMetalLayer *)self.layer).maximumDrawableCount = 2;
                [self setNeedsDisplay];
            }
            return;
        }
    }
    BOOL drewCatalystDrawable = NO;
    MacWSCatalystDrawableFrame *catalystWitnessFrame = nil;
    // A newly delivered producer frame can replace the compositor's current
    // dictionary entry while this command buffer is still reading the old
    // IOSurface texture.  Retain every exact frame encoded below until Metal
    // completes this Host submission; the frame owns the producer-transferred
    // IOSurface use count.
    NSMutableArray<MacWSCatalystDrawableFrame *> *submittedCatalystFrames =
        [NSMutableArray array];
    BOOL directSurface = _surfaceFrame != nil && _surfaceTexture != nil;
    BOOL finalComposite = directSurface &&
        (_surfaceFrame.descriptor.flags &
            MacWSStreamFrameFinalComposite) != 0;
    CFTimeInterval directHeartbeatAge =
        CACurrentMediaTime() - _lastDirectDrawableHeartbeatTime;
    MacWSSurfaceFrame *fullscreenDirectLayer =
        _overlayFrames[@(_directDrawableHeartbeatLayerID)];
    MacWSCatalystDrawableFrame *fullscreenDirectFrame =
        [self authoritativeFullscreenDrawableFrame];
    BOOL fullscreenDirectAuthoritative = fullscreenDirectFrame != nil;
    MacWSCatalystDrawableFrame *baseCatalystFrame =
        _scheduledCatalystDrawableFrame.record.ownerPID == self.targetPID
            ? _scheduledCatalystDrawableFrame
            : [_catalystDrawableCompositor frameForOwnerPID:self.targetPID];
    BOOL focusedLayerDirect = baseCatalystFrame &&
        baseCatalystFrame.record.ownerPID == self.targetPID &&
        baseCatalystFrame.record.producerPID !=
            baseCatalystFrame.record.ownerPID;
    BOOL focusedDirectAuthorityLive = focusedLayerDirect &&
        baseCatalystFrame.texture && self.targetPID > 1 &&
        _directDrawableHeartbeatPID == self.targetPID &&
        _directDrawableHeartbeatLayerID != 0 &&
        _directDrawableHeartbeatWidth != 0 &&
        _directDrawableHeartbeatHeight != 0 &&
        baseCatalystFrame.record.width == _directDrawableHeartbeatWidth &&
        baseCatalystFrame.record.height == _directDrawableHeartbeatHeight &&
        _lastDirectDrawableHeartbeatTime > 0.0 &&
        directHeartbeatAge >= 0.0 && directHeartbeatAge <= 3.0;
    BOOL focusedDirectBaseGenerationReady = !finalComposite ||
        _directDrawableGeometryBarrierTime == 0 ||
        (_surfaceFrame.descriptor.displayTime != 0 &&
         _surfaceFrame.descriptor.displayTime >=
            _directDrawableGeometryBarrierTime);
    if (focusedDirectBaseGenerationReady && finalComposite &&
        _directDrawableGeometryBarrierTime != 0) {
        _directDrawableGeometryBarrierTime = 0;
    }
    if (directSchedulerCandidate) {
        if (!directSurface)
            directScheduleOutcome =
                MacWSDirectDrawableScheduleOutcomeNoBaseSurface;
        else if (!focusedLayerDirect)
            directScheduleOutcome =
                MacWSDirectDrawableScheduleOutcomeNotDescendantDrawable;
        else if (!focusedDirectAuthorityLive)
            directScheduleOutcome =
                MacWSDirectDrawableScheduleOutcomeHeartbeatMismatch;
    }
    // Window-mode Chromium publishes the exact focused client IOSurface. If
    // it matches the retained base frame pixel-for-pixel and the independently
    // joined PID/window heartbeat is fresh, that drawable completely replaces
    // the captured base. Sampling the old DisplayStream texture first only to
    // overdraw every pixel doubled Host's full-resolution fragment work.
    BOOL focusedWindowDirectAuthoritative = directSurface && !finalComposite &&
        focusedDirectAuthorityLive && self.targetWindowID != 0 &&
        _directDrawableHeartbeatLayerID == self.targetWindowID &&
        baseCatalystFrame.record.width ==
            _surfaceFrame.descriptor.contentWidth &&
        baseCatalystFrame.record.height ==
            _surfaceFrame.descriptor.contentHeight;
    // A catalog-validated fullscreen canvas has no AppKit title bar. Every
    // ordinary window does: runtime snapshots at 1790785175 showed the
    // descendant Chromium texture contained the title-bar background but not
    // AppKit's traffic lights. Preserve that 24-point/48-pixel strip from the
    // WindowServer authority instead of letting direct pixels erase it.
    CGFloat catalystTitlebarHeightPixels =
        [_fullscreenCanvasPIDs containsObject:@(self.targetPID)]
            ? 0.0 : 48.0;
    MacWSSurfaceFrame *focusedDirectCompositeLayer = nil;
    BOOL focusedDirectCompositeIdentitySeen = NO;
    if (finalComposite && focusedLayerDirect &&
        _directCompositePipeline &&
        focusedDirectBaseGenerationReady &&
        _directDrawableHeartbeatPID == self.targetPID &&
        _directDrawableHeartbeatLayerID != 0 &&
        _lastDirectDrawableHeartbeatTime > 0.0 &&
        directHeartbeatAge >= 0.0 && directHeartbeatAge <= 3.0) {
        for (MacWSSurfaceFrame *candidate in _overlayFrames.allValues) {
            MacWSStreamFrameDescriptor descriptor = candidate.descriptor;
            if (descriptor.layerOwnerPID == self.targetPID &&
                descriptor.layerWindowID ==
                    _directDrawableHeartbeatLayerID) {
                focusedDirectCompositeIdentitySeen = YES;
                if (fabs(descriptor.destinationWidth -
                         baseCatalystFrame.record.width) >
                        MACWS_DIRECT_DRAWABLE_GEOMETRY_TOLERANCE_PIXELS ||
                    fabs(descriptor.destinationHeight -
                         baseCatalystFrame.record.height) >
                        MACWS_DIRECT_DRAWABLE_GEOMETRY_TOLERANCE_PIXELS)
                    continue;
                focusedDirectCompositeLayer = candidate;
                break;
            }
        }
    }
    if (directSchedulerCandidate && focusedDirectAuthorityLive &&
        directScheduleOutcome == MacWSDirectDrawableScheduleOutcomeUnknown) {
        if (finalComposite) {
            if (!_directCompositePipeline)
                directScheduleOutcome =
                    MacWSDirectDrawableScheduleOutcomeCompositePipelineMissing;
            else if (!focusedDirectBaseGenerationReady)
                directScheduleOutcome =
                    MacWSDirectDrawableScheduleOutcomeBaseGenerationPending;
            else if (!focusedDirectCompositeLayer)
                directScheduleOutcome = focusedDirectCompositeIdentitySeen
                    ? MacWSDirectDrawableScheduleOutcomeLayerGeometryMismatch
                    : MacWSDirectDrawableScheduleOutcomeLayerMissing;
        } else if (!focusedWindowDirectAuthoritative) {
            directScheduleOutcome =
                MacWSDirectDrawableScheduleOutcomeWindowBaseMismatch;
        }
    }
    if (directSurface) {
        _sourceTexture = _surfaceTexture;
    } else {
        if (self.targetWindowID != 0 ||
            !MacWSLegacyFramebufferFallbackEnabled()) {
            [self publishStatus:self.targetWindowID != 0
                ? @"等待该窗口的 DisplayStream IOSurface 直传帧"
                : @"等待全屏 DisplayStream IOSurface 直传帧"];
            // MTKView retains its previous drawable if no command buffer is
            // submitted.  During a window -> fullscreen Scene transaction
            // iPadOS then scales that old window-sized drawable to the panel,
            // which looks like a cropped desktop and cannot share the new
            // input coordinate generation.  Clear through the real Metal
            // render pass while waiting; the first new IOSurface replaces it
            // through the normal draw path below.
            MTLRenderPassDescriptor *waitingPass =
                view.currentRenderPassDescriptor;
            id<CAMetalDrawable> waitingDrawable = view.currentDrawable;
            if (waitingPass && waitingDrawable) {
                waitingPass.colorAttachments[0].loadAction =
                    MTLLoadActionClear;
                waitingPass.colorAttachments[0].storeAction =
                    MTLStoreActionStore;
                waitingPass.colorAttachments[0].clearColor =
                    MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
                id<MTLCommandBuffer> waitingBuffer =
                    [_commandQueue commandBuffer];
                id<MTLRenderCommandEncoder> waitingEncoder =
                    [waitingBuffer renderCommandEncoderWithDescriptor:
                        waitingPass];
                [waitingEncoder endEncoding];
                [waitingBuffer presentDrawable:waitingDrawable];
                [waitingBuffer commit];
            }
            return;
        }
        if (![_frame refresh]) {
            [self publishStatus:_frame.lastError ?: @"等待共享帧"];
            return;
        }
        if (![self ensureSourceTexture]) {
            [self publishStatus:@"无法创建帧上传纹理"];
            return;
        }

        MTLRegion region = MTLRegionMake2D(0, 0, _frame.width, _frame.height);
        [_sourceTexture replaceRegion:region mipmapLevel:0 withBytes:_frame.pixels
                          bytesPerRow:_frame.stride];

        if (!_reportedNonzeroFrame && [self frameHasSampledContent]) {
            _reportedNonzeroFrame = YES;
            MacWSLog(@"runtime-confirmed source frame nonzero %ux%u stride=%u path=%@",
                     _frame.width, _frame.height, _frame.stride, MacWSFramePath);
        }
    }

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;
    if (fullscreenDirectAuthoritative) {
        // The exact direct drawable covers the complete semantic game canvas.
        // Ordinary windows still need their WindowServer title bar, so only a
        // true FullscreenCanvas may clear/elide the base.
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor =
            MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    }
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    simd_float4 vertices[4];
    [self updateContentRectAndVertices:vertices];
    if (directSurface) {
        MacWSStreamFrameDescriptor descriptor = _surfaceFrame.descriptor;
        float originU = descriptor.contentX / (float)descriptor.width;
        float originV = descriptor.contentY / (float)descriptor.height;
        float scaleU = descriptor.contentWidth / (float)descriptor.width;
        float scaleV = descriptor.contentHeight / (float)descriptor.height;
        for (NSUInteger index = 0; index < 4; index++) {
            vertices[index].z = originU + vertices[index].z * scaleU;
            vertices[index].w = originV + vertices[index].w * scaleV;
        }
    }
    BOOL fusedFocusedDirect = NO;
    if (!fullscreenDirectAuthoritative) {
        [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
        [encoder setFragmentTexture:_sourceTexture atIndex:0];
        if (focusedWindowDirectAuthoritative && _directCompositePipeline) {
            MacWSStreamFrameDescriptor base = _surfaceFrame.descriptor;
            float left = base.contentX / (float)base.width;
            float top = (base.contentY + catalystTitlebarHeightPixels) /
                (float)base.height;
            float right = (base.contentX + base.contentWidth) /
                (float)base.width;
            float bottom = (base.contentY + base.contentHeight) /
                (float)base.height;
            float directTop = catalystTitlebarHeightPixels /
                (float)baseCatalystFrame.record.height;
            simd_float4 geometry[2] = {
                {left, top, right, bottom},
                {0.0f, directTop, 1.0f, 1.0f},
            };
            [encoder setRenderPipelineState:_directCompositePipeline];
            [encoder setFragmentTexture:baseCatalystFrame.texture atIndex:1];
            [encoder setFragmentBytes:geometry
                                length:sizeof(geometry) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                        vertexStart:0 vertexCount:4];
            fusedFocusedDirect = YES;
            drewCatalystDrawable = YES;
            catalystWitnessFrame = baseCatalystFrame;
            [submittedCatalystFrames addObject:baseCatalystFrame];
        } else if (focusedDirectCompositeLayer) {
            MacWSStreamFrameDescriptor base = _surfaceFrame.descriptor;
            MacWSStreamFrameDescriptor direct =
                focusedDirectCompositeLayer.descriptor;
            float left = (base.contentX + direct.destinationX) /
                (float)base.width;
            float top = (base.contentY + direct.destinationY +
                catalystTitlebarHeightPixels) /
                (float)base.height;
            float right = (base.contentX + direct.destinationX +
                direct.destinationWidth) / (float)base.width;
            float bottom = (base.contentY + direct.destinationY +
                direct.destinationHeight) / (float)base.height;
            BOOL geometryValid = isfinite(left) && isfinite(top) &&
                isfinite(right) && isfinite(bottom) && right > left &&
                bottom > top && left < 1.0f && top < 1.0f &&
                right > 0.0f && bottom > 0.0f;
            if (geometryValid) {
                simd_float4 geometry[2] = {
                    {left, top, right, bottom},
                    {0.0f,
                     catalystTitlebarHeightPixels /
                         (float)baseCatalystFrame.record.height,
                     1.0f, 1.0f},
                };
                [encoder setRenderPipelineState:_directCompositePipeline];
                [encoder setFragmentTexture:baseCatalystFrame.texture
                                    atIndex:1];
                [encoder setFragmentBytes:geometry
                                    length:sizeof(geometry) atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                            vertexStart:0 vertexCount:4];
                fusedFocusedDirect = YES;
                drewCatalystDrawable = YES;
                catalystWitnessFrame = baseCatalystFrame;
                [submittedCatalystFrames addObject:baseCatalystFrame];
                static BOOL reportedFusedDirectComposite = NO;
                if (!reportedFusedDirectComposite) {
                    reportedFusedDirectComposite = YES;
                    double desktopArea =
                        (double)base.contentWidth * base.contentHeight;
                    double directArea =
                        (double)direct.destinationWidth *
                        direct.destinationHeight;
                    MacWSLog(@"runtime-confirmed focused-direct-fused-"
                             "composite pid=%d layer=%u base=%ux%u "
                             "direct=%ux%u coverage-percent=%.1f",
                             self.targetPID, direct.layerWindowID,
                             base.contentWidth, base.contentHeight,
                             direct.destinationWidth,
                             direct.destinationHeight,
                             desktopArea > 0.0
                                ? directArea / desktopArea * 100.0 : 0.0);
                }
            } else if (directSchedulerCandidate) {
                directScheduleOutcome =
                    MacWSDirectDrawableScheduleOutcomeDestinationInvalid;
            }
        }
        if (!fusedFocusedDirect) {
            [encoder setRenderPipelineState:_pipeline];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                        vertexStart:0 vertexCount:4];
        }
    } else if (!_reportedDirectDrawableBaseElision) {
        _reportedDirectDrawableBaseElision = YES;
        MacWSLog(@"runtime-confirmed direct-base-elided pid=%d "
                 "layer=%u mode=%@ drawable=%ux%u heartbeat-age-ms=%.1f",
                 self.targetPID, _directDrawableHeartbeatLayerID,
                 fullscreenDirectAuthoritative ? @"fullscreen" : @"window",
                 baseCatalystFrame.record.width,
                 baseCatalystFrame.record.height,
                 directHeartbeatAge * 1000.0);
    }

    // A Host-carried Catalyst CAMetalLayer can bypass SkyLight's client-area
    // capture while its native AppKit title bar remains present. Draw the
    // completed producer IOSurface over only the content portion, preserving
    // the captured traffic lights/title bar and the exact existing viewport.
    if (directSurface && !finalComposite &&
        !fullscreenDirectAuthoritative &&
        focusedWindowDirectAuthoritative && !fusedFocusedDirect) {
        // The base-elision path above intentionally skips its texture draw,
        // including the pipeline binding which that draw used to establish
        // for this encoder. MacWSEncodeCatalystDrawable only supplies the
        // direct vertices/texture; make its required render state explicit
        // here. Runtime-confirmed on iPad13,6: leaving the encoder unbound
        // crashed AGXMetal13_3 at drawPrimitives (MacWSHost crash reports
        // 2026-09-30 15:56:33 and 16:00:42, fault address 0x388).
        [encoder setRenderPipelineState:_pipeline];
        CGFloat baseWidth = _surfaceFrame.descriptor.contentWidth;
        CGFloat baseHeight = _surfaceFrame.descriptor.contentHeight;
        CGRect basePixels = CGRectMake(0, 0, baseWidth, baseHeight);
        CGRect visiblePixels = CGRectMake(
            _visibleSourceRect.origin.x * baseWidth,
            _visibleSourceRect.origin.y * baseHeight,
            _visibleSourceRect.size.width * baseWidth,
            _visibleSourceRect.size.height * baseHeight);
        visiblePixels = CGRectIntersection(visiblePixels, basePixels);
        if (MacWSEncodeCatalystDrawable(
                encoder, baseCatalystFrame, basePixels, visiblePixels,
                _contentRect, self.bounds.size,
                catalystTitlebarHeightPixels)) {
            drewCatalystDrawable = YES;
            catalystWitnessFrame = baseCatalystFrame;
            [submittedCatalystFrames addObject:baseCatalystFrame];
        }
    }

    if (fullscreenDirectAuthoritative) {
        // The controller-validated FullscreenCanvas identity and the live
        // AppInput endpoint establish the semantic destination.  The
        // completed Catalyst drawable is then a self-contained fullscreen
        // pixel source; it must not depend on a simultaneous final-composite
        // frame.  MacWSFinalCompositePublisher intentionally withholds stale
        // composites, and requiring one here regressed the same valid game
        // drawable into a small desktop overlay (R24: final=NO while every
        // PID/window/endpoint/drawable identity check was YES).
        CGRect basePixels = CGRectMake(
            0, 0, _surfaceFrame.descriptor.contentWidth,
            _surfaceFrame.descriptor.contentHeight);
        CGRect destination = CGRectIntersection(
            _reportedFullscreenCanvasPixels, basePixels);
        if (!CGRectIsNull(destination) && !CGRectIsEmpty(destination)) {
            [encoder setRenderPipelineState:_opaquePipeline];
            if (MacWSEncodeCatalystDrawable(
                    encoder, fullscreenDirectFrame, destination, destination,
                    _contentRect, self.bounds.size, 0.0)) {
                drewCatalystDrawable = YES;
                catalystWitnessFrame = fullscreenDirectFrame;
                [submittedCatalystFrames addObject:fullscreenDirectFrame];
                if (!_reportedDirectDrawableExactLayerSuppression) {
                    _reportedDirectDrawableExactLayerSuppression = YES;
                    MacWSLog(@"runtime-confirmed direct-drawable "
                             "fullscreen-present pid=%d layer=%u "
                             "drawable=%ux%u authority=controller-validated-"
                             "canvas-plus-live-endpoint-plus-completed-drawable",
                             self.targetPID,
                             _reportedFullscreenCanvasWindowID,
                             fullscreenDirectFrame.record.width,
                             fullscreenDirectFrame.record.height);
                }
            }
            [encoder setRenderPipelineState:_pipeline];
        }
    }

    MacWSSurfaceFrame *performanceFrame = directSurface ? _surfaceFrame : nil;
    // A FinalComposite frame is WindowServer's completed desktop image, not a
    // wallpaper/material underlay. Runtime snapshots on iPad13,6 at
    // 1787945412 captured the same Terminal window in both the base surface
    // and exact layer 58. Painting that layer again produced a synthetic
    // second shadow; while dragging, the independently-timed base and layer
    // occupied different positions and visibly ghosted. Keep exact-window
    // layers solely as the fallback graph when no final composite is live.
    // Catalyst drawables which really are absent from a final composite are
    // joined by the narrowly-scoped pass below instead.
    //
    // A controller-validated fullscreen drawable likewise owns the complete
    // semantic canvas. Steam's FPS overlay is already in that texture.
    if (directSurface && _overlayFrames.count &&
        !finalComposite && !fullscreenDirectAuthoritative) {
        [self overlayKeysBackToFront];
        CGFloat baseWidth = _surfaceFrame.descriptor.contentWidth;
        CGFloat baseHeight = _surfaceFrame.descriptor.contentHeight;
        CGRect basePixels = CGRectMake(0, 0, baseWidth, baseHeight);
        CGRect visiblePixels = CGRectMake(
            _visibleSourceRect.origin.x * baseWidth,
            _visibleSourceRect.origin.y * baseHeight,
            _visibleSourceRect.size.width * baseWidth,
            _visibleSourceRect.size.height * baseHeight);
        visiblePixels = CGRectIntersection(visiblePixels, basePixels);
        CGFloat viewWidth = CGRectGetWidth(self.bounds);
        CGFloat viewHeight = CGRectGetHeight(self.bounds);
        for (NSNumber *key in _sortedOverlayKeys) {
            MacWSSurfaceFrame *overlayFrame = _overlayFrames[key];
            id<MTLTexture> overlayTexture = _overlayTextures[key];
            MacWSStreamFrameDescriptor overlay = overlayFrame.descriptor;
            CGRect destination = CGRectMake(
                overlay.destinationX, overlay.destinationY,
                overlay.destinationWidth, overlay.destinationHeight);
            BOOL nativePopup = (overlay.flags &
                MacWSStreamFrameNativePopupComposite) != 0;
            CGRect paintDestination = destination;
            if (nativePopup) {
                // The descriptor retains the exact menu bounds for input.
                // Its texture also contains WindowServer's native shadow:
                // paint that bounded surrounding region, not an invented SDF.
                // displayd validates this same 20-point region for occlusion.
                CGFloat outset = 20.0 * overlay.backingScale;
                CGRect textureDestination = CGRectMake(
                    destination.origin.x - overlay.contentX *
                        destination.size.width / overlay.contentWidth,
                    destination.origin.y - overlay.contentY *
                        destination.size.height / overlay.contentHeight,
                    overlay.width * destination.size.width / overlay.contentWidth,
                    overlay.height * destination.size.height / overlay.contentHeight);
                paintDestination = CGRectIntersection(
                    CGRectInset(destination, -outset, -outset), textureDestination);
            }
            CGRect clipped = CGRectIntersection(paintDestination, visiblePixels);
            if (!overlayTexture || CGRectIsNull(clipped) ||
                CGRectIsEmpty(clipped) || viewWidth <= 0 || viewHeight <= 0 ||
                visiblePixels.size.width <= 0 ||
                visiblePixels.size.height <= 0) continue;
            if (!performanceFrame ||
                overlayFrame.receiptTime > performanceFrame.receiptTime)
                performanceFrame = overlayFrame;

            MacWSCatalystDrawableFrame *catalystFrame =
                _scheduledCatalystDrawableFrame.record.ownerPID ==
                    overlay.layerOwnerPID
                    ? _scheduledCatalystDrawableFrame
                    : [_catalystDrawableCompositor frameForOwnerPID:
                        overlay.layerOwnerPID];
            CFTimeInterval layerDirectHeartbeatAge =
                CACurrentMediaTime() - _lastDirectDrawableHeartbeatTime;
            BOOL directLayerAuthoritative = finalComposite &&
                catalystFrame.texture &&
                _directDrawableHeartbeatPID == overlay.layerOwnerPID &&
                _directDrawableHeartbeatLayerID == overlay.layerWindowID &&
                _lastDirectDrawableHeartbeatTime > 0.0 &&
                layerDirectHeartbeatAge >= 0.0 &&
                layerDirectHeartbeatAge <= 3.0;
            if (directLayerAuthoritative &&
                !_reportedDirectDrawableExactLayerSuppression) {
                _reportedDirectDrawableExactLayerSuppression = YES;
                MacWSLog(@"runtime-confirmed direct-drawable exact-layer-"
                         "suppressed pid=%d layer=%u heartbeat-age-ms=%.1f "
                         "authority=final-composite-plus-completed-drawable",
                         overlay.layerOwnerPID, overlay.layerWindowID,
                         layerDirectHeartbeatAge * 1000.0);
            }

            // SkyLight's exact-window stream contains the window backing but
            // not the compositor's external drop shadow.  The private stream
            // boolean was runtime-probed both ways on window 88 and returned
            // the same 960x656 surface, so no native shadow pixels exist to
            // copy.  AppInputBridge now publishes NSWindow.hasShadow from the
            // real window; render one inexpensive rounded Gaussian SDF behind
            // that layer on the GPU before painting its authoritative pixels.
            if (!directLayerAuthoritative && !nativePopup && _shadowPipeline &&
                [_shadowWindowIDs containsObject:
                    @(overlay.layerWindowID)]) {
                const CGFloat marginLeft = 32.0;
                const CGFloat marginTop = 24.0;
                const CGFloat marginRight = 32.0;
                const CGFloat marginBottom = 40.0;
                CGRect shadowDestination = CGRectMake(
                    destination.origin.x - marginLeft,
                    destination.origin.y - marginTop,
                    destination.size.width + marginLeft + marginRight,
                    destination.size.height + marginTop + marginBottom);
                CGRect shadowClipped = CGRectIntersection(
                    shadowDestination, visiblePixels);
                if (!CGRectIsNull(shadowClipped) &&
                    !CGRectIsEmpty(shadowClipped)) {
                    CGFloat shadowLeft = CGRectGetMinX(_contentRect) +
                        (CGRectGetMinX(shadowClipped) -
                         CGRectGetMinX(visiblePixels)) /
                            CGRectGetWidth(visiblePixels) *
                            CGRectGetWidth(_contentRect);
                    CGFloat shadowRight = CGRectGetMinX(_contentRect) +
                        (CGRectGetMaxX(shadowClipped) -
                         CGRectGetMinX(visiblePixels)) /
                            CGRectGetWidth(visiblePixels) *
                            CGRectGetWidth(_contentRect);
                    CGFloat shadowTop = CGRectGetMinY(_contentRect) +
                        (CGRectGetMinY(shadowClipped) -
                         CGRectGetMinY(visiblePixels)) /
                            CGRectGetHeight(visiblePixels) *
                            CGRectGetHeight(_contentRect);
                    CGFloat shadowBottom = CGRectGetMinY(_contentRect) +
                        (CGRectGetMaxY(shadowClipped) -
                         CGRectGetMinY(visiblePixels)) /
                            CGRectGetHeight(visiblePixels) *
                            CGRectGetHeight(_contentRect);
                    float u0 = (CGRectGetMinX(shadowClipped) -
                                CGRectGetMinX(shadowDestination)) /
                               CGRectGetWidth(shadowDestination);
                    float u1 = (CGRectGetMaxX(shadowClipped) -
                                CGRectGetMinX(shadowDestination)) /
                               CGRectGetWidth(shadowDestination);
                    float v0 = (CGRectGetMinY(shadowClipped) -
                                CGRectGetMinY(shadowDestination)) /
                               CGRectGetHeight(shadowDestination);
                    float v1 = (CGRectGetMaxY(shadowClipped) -
                                CGRectGetMinY(shadowDestination)) /
                               CGRectGetHeight(shadowDestination);
                    simd_float4 shadowVertices[4] = {
                        {(float)(shadowLeft / viewWidth * 2.0 - 1.0),
                         (float)(1.0 - shadowBottom / viewHeight * 2.0),
                         u0, v1},
                        {(float)(shadowRight / viewWidth * 2.0 - 1.0),
                         (float)(1.0 - shadowBottom / viewHeight * 2.0),
                         u1, v1},
                        {(float)(shadowLeft / viewWidth * 2.0 - 1.0),
                         (float)(1.0 - shadowTop / viewHeight * 2.0),
                         u0, v0},
                        {(float)(shadowRight / viewWidth * 2.0 - 1.0),
                         (float)(1.0 - shadowTop / viewHeight * 2.0),
                         u1, v0},
                    };
                    simd_float4 shadowGeometry[2] = {
                        {(float)shadowDestination.size.width,
                         (float)shadowDestination.size.height,
                         (float)marginLeft, (float)marginTop},
                        {(float)destination.size.width,
                         (float)destination.size.height, 12.0f, 13.0f},
                    };
                    [encoder setRenderPipelineState:_shadowPipeline];
                    [encoder setVertexBytes:shadowVertices
                                      length:sizeof(shadowVertices) atIndex:0];
                    [encoder setFragmentBytes:shadowGeometry
                                        length:sizeof(shadowGeometry) atIndex:0];
                    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                vertexStart:0 vertexCount:4];
                    [encoder setRenderPipelineState:_pipeline];
                }
            }

            if (!directLayerAuthoritative) {
                CGFloat relativeLeft =
                    (CGRectGetMinX(clipped) - CGRectGetMinX(visiblePixels)) /
                    CGRectGetWidth(visiblePixels);
                CGFloat relativeRight =
                    (CGRectGetMaxX(clipped) - CGRectGetMinX(visiblePixels)) /
                    CGRectGetWidth(visiblePixels);
                CGFloat relativeTop =
                    (CGRectGetMinY(clipped) - CGRectGetMinY(visiblePixels)) /
                    CGRectGetHeight(visiblePixels);
                CGFloat relativeBottom =
                    (CGRectGetMaxY(clipped) - CGRectGetMinY(visiblePixels)) /
                    CGRectGetHeight(visiblePixels);
                CGFloat viewLeft = CGRectGetMinX(_contentRect) +
                    relativeLeft * CGRectGetWidth(_contentRect);
                CGFloat viewRight = CGRectGetMinX(_contentRect) +
                    relativeRight * CGRectGetWidth(_contentRect);
                CGFloat viewTop = CGRectGetMinY(_contentRect) +
                    relativeTop * CGRectGetHeight(_contentRect);
                CGFloat viewBottom = CGRectGetMinY(_contentRect) +
                    relativeBottom * CGRectGetHeight(_contentRect);

                float sourceLeft = (overlay.contentX +
                    (CGRectGetMinX(clipped) - CGRectGetMinX(destination)) /
                        CGRectGetWidth(destination) * overlay.contentWidth) /
                    (float)overlay.width;
                float sourceRight = (overlay.contentX +
                    (CGRectGetMaxX(clipped) - CGRectGetMinX(destination)) /
                        CGRectGetWidth(destination) * overlay.contentWidth) /
                    (float)overlay.width;
                float sourceTop = (overlay.contentY +
                    (CGRectGetMinY(clipped) - CGRectGetMinY(destination)) /
                        CGRectGetHeight(destination) * overlay.contentHeight) /
                    (float)overlay.height;
                float sourceBottom = (overlay.contentY +
                    (CGRectGetMaxY(clipped) - CGRectGetMinY(destination)) /
                        CGRectGetHeight(destination) * overlay.contentHeight) /
                    (float)overlay.height;
                simd_float4 overlayVertices[4] = {
                    {(float)(viewLeft / viewWidth * 2.0 - 1.0),
                     (float)(1.0 - viewBottom / viewHeight * 2.0),
                     sourceLeft, sourceBottom},
                    {(float)(viewRight / viewWidth * 2.0 - 1.0),
                     (float)(1.0 - viewBottom / viewHeight * 2.0),
                     sourceRight, sourceBottom},
                    {(float)(viewLeft / viewWidth * 2.0 - 1.0),
                     (float)(1.0 - viewTop / viewHeight * 2.0),
                     sourceLeft, sourceTop},
                    {(float)(viewRight / viewWidth * 2.0 - 1.0),
                     (float)(1.0 - viewTop / viewHeight * 2.0),
                     sourceRight, sourceTop},
                };
                [encoder setVertexBytes:overlayVertices
                                  length:sizeof(overlayVertices) atIndex:0];
                [encoder setFragmentTexture:overlayTexture atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                            vertexStart:0 vertexCount:4];
            }
            if (directLayerAuthoritative && _opaquePipeline)
                [encoder setRenderPipelineState:_opaquePipeline];
            if (MacWSEncodeCatalystDrawable(
                    encoder, catalystFrame, destination, visiblePixels,
                    _contentRect, self.bounds.size,
                    catalystTitlebarHeightPixels)) {
                drewCatalystDrawable = YES;
                catalystWitnessFrame = catalystFrame;
                if (![submittedCatalystFrames containsObject:catalystFrame])
                    [submittedCatalystFrames addObject:catalystFrame];
            }
            if (directLayerAuthoritative && _opaquePipeline)
                [encoder setRenderPipelineState:_pipeline];
            // The lease token is the unique ownership identity across stream
            // recreation.  A later frame can now distinguish an IOSurface
            // actually referenced by an in-flight command buffer from one
            // merely imported and superseded before this draw.
            _submittedOverlayLeaseTokens[key] =
                @(overlayFrame.descriptor.leaseToken);
        }
    }
    if (directSurface && finalComposite && _overlayFrames.count &&
        focusedDirectAuthorityLive &&
        !fusedFocusedDirect &&
        ![_fullscreenCanvasPIDs containsObject:@(self.targetPID)]) {
        // Final-composite is authoritative for native SkyLight effects, but a
        // Host-carried Catalyst CAMetalLayer is absent from that snapshot even
        // though its real drawable is complete. Replace only the focused
        // Catalyst client's rectangle. Restricting this to targetPID keeps an
        // obscured/background game from painting over native windows already
        // resolved by WindowServer in the final composite.
        [self overlayKeysBackToFront];
        CGFloat baseWidth = _surfaceFrame.descriptor.contentWidth;
        CGFloat baseHeight = _surfaceFrame.descriptor.contentHeight;
        CGRect basePixels = CGRectMake(0, 0, baseWidth, baseHeight);
        CGRect visiblePixels = CGRectMake(
            _visibleSourceRect.origin.x * baseWidth,
            _visibleSourceRect.origin.y * baseHeight,
            _visibleSourceRect.size.width * baseWidth,
            _visibleSourceRect.size.height * baseHeight);
        visiblePixels = CGRectIntersection(visiblePixels, basePixels);
        MacWSCatalystDrawableFrame *focusedFrame =
            _scheduledCatalystDrawableFrame.record.ownerPID == self.targetPID
                ? _scheduledCatalystDrawableFrame
                : [_catalystDrawableCompositor frameForOwnerPID:
                    self.targetPID];
        for (NSNumber *key in _sortedOverlayKeys) {
            MacWSSurfaceFrame *overlayFrame = _overlayFrames[key];
            MacWSStreamFrameDescriptor overlay = overlayFrame.descriptor;
            if (overlay.layerOwnerPID != self.targetPID ||
                overlay.layerWindowID !=
                    _directDrawableHeartbeatLayerID) continue;
            CGRect destination = CGRectMake(
                overlay.destinationX, overlay.destinationY,
                overlay.destinationWidth, overlay.destinationHeight);
            BOOL geometryMatches =
                fabs(destination.size.width - focusedFrame.record.width) <=
                    2.0 &&
                fabs(destination.size.height - focusedFrame.record.height) <=
                    2.0;
            if (!geometryMatches) continue;
            BOOL opaqueDirect = focusedFrame &&
                (focusedFrame.record.flags &
                    MacWSCatalystDrawableOpaque) != 0 &&
                _opaquePipeline != nil;
            if (opaqueDirect)
                [encoder setRenderPipelineState:_opaquePipeline];
            BOOL encodedDirect = MacWSEncodeCatalystDrawable(
                    encoder, focusedFrame, destination, visiblePixels,
                    _contentRect, self.bounds.size,
                    catalystTitlebarHeightPixels);
            if (opaqueDirect)
                [encoder setRenderPipelineState:_pipeline];
            if (encodedDirect) {
                drewCatalystDrawable = YES;
                catalystWitnessFrame = focusedFrame;
                if (![submittedCatalystFrames containsObject:focusedFrame])
                    [submittedCatalystFrames addObject:focusedFrame];
                break;
            }
        }
    }
    [encoder endEncoding];
    NSString *renderedSnapshotPath = _pendingRenderedDrawableSnapshotPath;
    _pendingRenderedDrawableSnapshotPath = nil;
    NSUInteger renderedSnapshotWidth = drawable.texture.width;
    NSUInteger renderedSnapshotHeight = drawable.texture.height;
    MTLPixelFormat renderedSnapshotPixelFormat = drawable.texture.pixelFormat;
    NSUInteger renderedSnapshotBytesPerRow =
        ((renderedSnapshotWidth * 4 + 255) / 256) * 256;
    id<MTLBuffer> renderedSnapshotBuffer = nil;
    if (renderedSnapshotPath.length != 0) {
        MacWSLog(@"rendered-drawable-authority target=%d authoritative=%@ "
                 "final=%@ capability=%@ controller-identity=%@ "
                 "layer=%@ retained=%@ heartbeat-pid=%d "
                 "heartbeat-window=%u heartbeat-size=%ux%u "
                 "heartbeat-age-ms=%.1f base-stream=%llu "
                 "base-sequence=%llu focused-direct-sequence=%llu "
                 "focused-direct-size=%ux%u focused-destination=%d,%d/%ux%u "
                 "endpoint=%@",
                 self.targetPID,
                 fullscreenDirectAuthoritative ? @"YES" : @"NO",
                 finalComposite ? @"YES" : @"NO",
                 [_fullscreenCanvasPIDs containsObject:@(self.targetPID)]
                    ? @"YES" : @"NO",
                 (_reportedFullscreenCanvasPID == self.targetPID &&
                  _reportedFullscreenCanvasWindowID != 0 &&
                  _reportedFullscreenCanvasWindowID ==
                      _directDrawableHeartbeatLayerID &&
                  !CGRectIsEmpty(_reportedFullscreenCanvasPixels) &&
                  MacWSAppInputEndpointReady(self.targetPID))
                    ? @"YES" : @"NO",
                 fullscreenDirectLayer ? @"YES" : @"NO",
                 (!fullscreenDirectLayer &&
                  _reportedFullscreenCanvasPID == self.targetPID &&
                  _reportedFullscreenCanvasWindowID ==
                      _directDrawableHeartbeatLayerID)
                    ? @"YES" : @"NO",
                 _directDrawableHeartbeatPID,
                 _directDrawableHeartbeatLayerID,
                 _directDrawableHeartbeatWidth,
                 _directDrawableHeartbeatHeight,
                 directHeartbeatAge * 1000.0,
                 (unsigned long long)_surfaceFrame.descriptor.streamID,
                 (unsigned long long)_surfaceFrame.descriptor.sequence,
                 (unsigned long long)baseCatalystFrame.record.sequence,
                 baseCatalystFrame.record.width,
                 baseCatalystFrame.record.height,
                 focusedDirectCompositeLayer.descriptor.destinationX,
                 focusedDirectCompositeLayer.descriptor.destinationY,
                 focusedDirectCompositeLayer.descriptor.destinationWidth,
                 focusedDirectCompositeLayer.descriptor.destinationHeight,
                 MacWSAppInputEndpointReady(self.targetPID)
                    ? @"YES" : @"NO");
    }
    if (renderedSnapshotPath.length != 0 &&
        renderedSnapshotWidth != 0 && renderedSnapshotHeight != 0 &&
        (renderedSnapshotPixelFormat == MTLPixelFormatBGRA8Unorm ||
         renderedSnapshotPixelFormat == MTLPixelFormatBGRA8Unorm_sRGB)) {
        renderedSnapshotBuffer = [self.device newBufferWithLength:
            renderedSnapshotBytesPerRow * renderedSnapshotHeight
            options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = renderedSnapshotBuffer
            ? [commandBuffer blitCommandEncoder] : nil;
        if (blit) {
            [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(renderedSnapshotWidth,
                                         renderedSnapshotHeight, 1)
                    toBuffer:renderedSnapshotBuffer destinationOffset:0
           destinationBytesPerRow:renderedSnapshotBytesPerRow
         destinationBytesPerImage:
             renderedSnapshotBytesPerRow * renderedSnapshotHeight];
            [blit endEncoding];
        }
    }
    if (renderedSnapshotPath.length != 0) {
        id<MTLBuffer> completedSnapshotBuffer = renderedSnapshotBuffer;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            NSData *png = nil;
            NSError *writeError = nil;
            if (completed.status == MTLCommandBufferStatusCompleted &&
                completedSnapshotBuffer) {
                NSData *pixels = [NSData dataWithBytes:
                    completedSnapshotBuffer.contents length:
                    renderedSnapshotBytesPerRow * renderedSnapshotHeight];
                CGDataProviderRef provider = CGDataProviderCreateWithCFData(
                    (__bridge CFDataRef)pixels);
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                CGImageRef image = provider && colorSpace ? CGImageCreate(
                    renderedSnapshotWidth, renderedSnapshotHeight, 8, 32,
                    renderedSnapshotBytesPerRow, colorSpace,
                    kCGBitmapByteOrder32Little |
                        kCGImageAlphaPremultipliedFirst,
                    provider, NULL, false, kCGRenderingIntentDefault) : NULL;
                if (image) {
                    png = UIImagePNGRepresentation(
                        [UIImage imageWithCGImage:image]);
                    CGImageRelease(image);
                }
                if (colorSpace) CGColorSpaceRelease(colorSpace);
                if (provider) CGDataProviderRelease(provider);
                if (png.length)
                    [png writeToFile:renderedSnapshotPath
                             options:NSDataWritingAtomic error:&writeError];
            }
            MacWSLog(@"rendered-drawable-snapshot written=%@ bytes=%lu "
                     "size=%lux%lu pixel-format=%lu status=%ld path=%@ "
                     "error=%@",
                     png.length && !writeError ? @"YES" : @"NO",
                     (unsigned long)png.length,
                     (unsigned long)renderedSnapshotWidth,
                     (unsigned long)renderedSnapshotHeight,
                     (unsigned long)renderedSnapshotPixelFormat,
                     (long)completed.status, renderedSnapshotPath,
                     writeError ?: completed.error ?: @"nil");
        }];
    }
    uint64_t submitTime = mach_absolute_time();
    uint64_t performanceStreamID = performanceFrame
        ? performanceFrame.descriptor.streamID : 0;
    uint64_t performanceSequence = performanceFrame
        ? performanceFrame.descriptor.sequence : 0;
    uint64_t performanceCaptureTime = performanceFrame
        ? performanceFrame.descriptor.displayTime : 0;
    uint64_t performanceReceiptTime = performanceFrame
        ? performanceFrame.receiptTime : submitTime;
    // Give a newly completed target-owned direct drawable first claim on a
    // pending input sample.  In fullscreen game mode this exact texture is
    // the visible authority; the retained FinalComposite underneath it is a
    // lower-cadence fallback and must not inflate input-to-visible latency.
    for (MacWSCatalystDrawableFrame *directFrame in
            submittedCatalystFrames) {
        MacWSCatalystDrawableRecord record = directFrame.record;
        int32_t performanceOwnerPID = record.ownerPID;
        [_performanceMonitor
            recordDirectDrawableSubmissionForOwnerPID:performanceOwnerPID
            sequence:record.sequence completionTime:record.completionTime
            isTarget:self.targetPID == performanceOwnerPID drawable:drawable];
    }
    [_performanceMonitor recordSubmissionForStream:performanceStreamID
        sequence:performanceSequence captureTime:performanceCaptureTime
        receiptTime:performanceReceiptTime submitTime:submitTime
        directTargetAuthoritative:(fullscreenDirectAuthoritative ||
                                   focusedWindowDirectAuthoritative)
        commandBuffer:commandBuffer drawable:drawable];
    [commandBuffer presentDrawable:drawable];
    if (directSchedulerCandidate) {
        if ([submittedCatalystFrames containsObject:
                _scheduledCatalystDrawableFrame]) {
            directScheduleOutcome =
                MacWSDirectDrawableScheduleOutcomeSubmitted;
        }
        [_performanceMonitor recordDirectDrawableScheduleOutcome:
            directScheduleOutcome];
        if (directScheduleOutcome ==
                MacWSDirectDrawableScheduleOutcomeBaseGenerationPending) {
            // Do not pin the first producer frame seen at the new geometry
            // while waiting for WindowServer's base to catch up. The bounded
            // FIFO then presents the newest completed content as soon as the
            // generation barrier opens.
            _scheduledCatalystDrawableFrame = nil;
        }
    }
    if (_scheduledCatalystDrawableFrame &&
        [submittedCatalystFrames containsObject:
            _scheduledCatalystDrawableFrame]) {
        _scheduledCatalystDrawableFrame = nil;
    }
    if (submittedCatalystFrames.count) {
        NSArray<MacWSCatalystDrawableFrame *> *leasedCatalystFrames =
            submittedCatalystFrames;
        [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> cb) {
            // No caller mutates the per-submission array after this point.
            // Capturing it is the lifetime fence: releasing this completion
            // block releases each frame and only then returns its transferred
            // IOSurface use count to CAMetalLayer, without another array copy
            // in the 120-Hz hot path.
            (void)leasedCatalystFrames.count;
        }];
    }
    if (drewCatalystDrawable && !_submittedCatalystDrawableWitness) {
        _submittedCatalystDrawableWitness = YES;
        MacWSCatalystDrawableRecord witness = catalystWitnessFrame.record;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            MacWSLog(@"runtime-confirmed catalyst-drawable presented pid=%d "
                     "surface=%u sequence=%llu size=%ux%u status=%ld "
                     "error=%@",
                     witness.ownerPID, witness.surfaceID,
                     (unsigned long long)witness.sequence, witness.width,
                     witness.height, (long)completed.status,
                     completed.error ?: @"nil");
        }];
    }
    uint32_t presentedWidth = [self currentFrameWidth];
    uint32_t presentedHeight = [self currentFrameHeight];
    MacWSSurfaceFrame *submittedFrame = directSurface ? _surfaceFrame : nil;
    NSArray<MacWSSurfaceFrame *> *framesToRelease =
        _retiredSurfaceFrames.count ? [_retiredSurfaceFrames copy] : @[];
    [_retiredSurfaceFrames removeAllObjects];
    if (submittedFrame)
        _submittedSurfaceLeaseToken = submittedFrame.descriptor.leaseToken;
    if (MacWSHostDiagnosticsEnabled() && performanceFrame &&
        (performanceFrame.descriptor.sequence % 120) == 0 &&
        (_lastPerformanceLogStreamID != performanceFrame.descriptor.streamID ||
         _lastPerformanceLogSequence != performanceFrame.descriptor.sequence)) {
        uint64_t captureTime = performanceFrame.descriptor.displayTime;
        uint64_t receiptTime = performanceFrame.receiptTime;
        uint64_t sequence = performanceFrame.descriptor.sequence;
        uint64_t streamID = performanceFrame.descriptor.streamID;
        _lastPerformanceLogStreamID = streamID;
        _lastPerformanceLogSequence = sequence;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            uint64_t completeTime = mach_absolute_time();
            MacWSLog(@"display-perf stream=%llu sequence=%llu "
                     "capture-to-receipt-ms=%.3f receipt-to-submit-ms=%.3f "
                     "submit-to-complete-ms=%.3f status=%ld error=%@",
                     (unsigned long long)streamID,
                     (unsigned long long)sequence,
                     MacWSMachMilliseconds(captureTime, receiptTime),
                     MacWSMachMilliseconds(receiptTime, submitTime),
                     MacWSMachMilliseconds(submitTime, completeTime),
                     (long)completed.status, completed.error ?: @"nil");
        }];
    }
    if ((directSurface || _reportedNonzeroFrame) && !_submittedPresentWitness) {
        _submittedPresentWitness = YES;
        uint32_t witnessWidth = presentedWidth;
        uint32_t witnessHeight = presentedHeight;
        uint64_t witnessScene = self.sceneID;
        float witnessBackingScale = directSurface
            ? submittedFrame.descriptor.backingScale : 1.0f;
        CGSize witnessDrawableSize = self.drawableSize;
        CGRect witnessContentRect = _contentRect;
        CGFloat witnessDensity = self.effectiveDensityScale;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            NSError *error = completed.error;
            MacWSLog(@"runtime-confirmed native Metal present scene=%llx "
                     "frame=%ux%u backing=%.3f drawable=%.0fx%.0f "
                     "content=(%.2f,%.2f %.2fx%.2f) density=%.2f "
                     "source=%@ status=%ld error=%@",
                     witnessScene, witnessWidth, witnessHeight,
                     witnessBackingScale, witnessDrawableSize.width,
                     witnessDrawableSize.height, witnessContentRect.origin.x,
                     witnessContentRect.origin.y, witnessContentRect.size.width,
                     witnessContentRect.size.height, witnessDensity,
                     directSurface ? @"IOSurface" : @"mmap-upload",
                     (long)completed.status, error ?: @"nil");
        }];
    }
    if (framesToRelease.count) {
        __weak MacWSStreamClient *weakClient = _streamClient;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            (void)completed;
            for (MacWSSurfaceFrame *frame in framesToRelease)
                [weakClient releaseFrame:frame];
        }];
    }
    [commandBuffer commit];
    if (directSurface) {
        // The direct dimensions are stable for thousands of frames. Avoid
        // formatting and copying an identical NSString on every 120-Hz
        // submission; republish the cached object if another status replaced
        // it between frames.
        if (!_directSurfaceStatus ||
            _directSurfaceStatusWidth != presentedWidth ||
            _directSurfaceStatusHeight != presentedHeight) {
            _directSurfaceStatusWidth = presentedWidth;
            _directSurfaceStatusHeight = presentedHeight;
            _directSurfaceStatus = [NSString stringWithFormat:
                @"%u×%u  ·  DisplayStream  ·  IOSurface 直传",
                presentedWidth, presentedHeight];
        }
        if (_lastStatus != _directSurfaceStatus)
            [self publishStatus:_directSurfaceStatus];
    } else {
        _presentedCaptureGeneration = _pendingCaptureGeneration;
        _pendingCaptureGeneration = 0;
        NSString *content = _reportedNonzeroFrame ? @"有效像素" : @"全黑";
        [self publishStatus:[NSString stringWithFormat:
            @"%u×%u  ·  快照 #%llu  ·  %@",
            _frame.width, _frame.height,
            (unsigned long long)_presentedCaptureGeneration, content]];
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
    [self updatePresentationGeometry];
    [self scheduleWindowConfiguration];
    [self setNeedsDisplay];
}

- (BOOL)framePointForViewPoint:(CGPoint)viewPoint
                       output:(CGPoint *)framePoint
           clampContinuationToContent:(BOOL)clampContinuation {
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    if (frameWidth == 0 || frameHeight == 0 || CGRectIsEmpty(_contentRect)) {
        return NO;
    }
    if (!CGRectContainsPoint(_contentRect, viewPoint) && !clampContinuation)
        return NO;
    // A pointer transaction which began on the macOS surface must always
    // receive its Move/Up/Cancel boundary.  In a fitted Scene, UIKit can keep
    // delivering the finger in the one-pixel letterbox or deferred top/bottom
    // system-gesture inset.  Dropping those samples froze a title-bar drag
    // before it reached the native macOS screen edge and could also strand the
    // primary button down.  Clamp only continuations; an independent tap or
    // hover outside the rendered desktop remains rejected.
    if (clampContinuation) {
        viewPoint.x = fmin(fmax(viewPoint.x, CGRectGetMinX(_contentRect)),
                           CGRectGetMaxX(_contentRect));
        viewPoint.y = fmin(fmax(viewPoint.y, CGRectGetMinY(_contentRect)),
                           CGRectGetMaxY(_contentRect));
    }
    CGFloat nx = (viewPoint.x - CGRectGetMinX(_contentRect)) /
        _contentRect.size.width;
    CGFloat ny = (viewPoint.y - CGRectGetMinY(_contentRect)) /
        _contentRect.size.height;
    CGFloat sourceX = CGRectGetMinX(_visibleSourceRect) +
        fmin(fmax(nx, 0.0), 1.0) * CGRectGetWidth(_visibleSourceRect);
    CGFloat sourceY = CGRectGetMinY(_visibleSourceRect) +
        fmin(fmax(ny, 0.0), 1.0) * CGRectGetHeight(_visibleSourceRect);
    framePoint->x = sourceX * (frameWidth - 1);
    framePoint->y = sourceY * (frameHeight - 1);
    return YES;
}

- (BOOL)framePointForViewPoint:(CGPoint)viewPoint output:(CGPoint *)framePoint {
    return [self framePointForViewPoint:viewPoint output:framePoint
                    clampContinuationToContent:NO];
}

- (BOOL)viewPointForFramePoint:(CGPoint)framePoint output:(CGPoint *)viewPoint {
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    CGFloat visibleWidth = CGRectGetWidth(_visibleSourceRect);
    CGFloat visibleHeight = CGRectGetHeight(_visibleSourceRect);
    if (frameWidth == 0 || frameHeight == 0 || CGRectIsEmpty(_contentRect) ||
        visibleWidth <= 0 || visibleHeight <= 0) return NO;
    CGFloat sourceX = framePoint.x / MAX(frameWidth - 1, 1u);
    CGFloat sourceY = framePoint.y / MAX(frameHeight - 1, 1u);
    CGFloat nx = (sourceX - CGRectGetMinX(_visibleSourceRect)) / visibleWidth;
    CGFloat ny = (sourceY - CGRectGetMinY(_visibleSourceRect)) / visibleHeight;
    nx = fmin(fmax(nx, 0.0), 1.0);
    ny = fmin(fmax(ny, 0.0), 1.0);
    if (viewPoint) {
        *viewPoint = CGPointMake(CGRectGetMinX(_contentRect) +
            nx * CGRectGetWidth(_contentRect),
            CGRectGetMinY(_contentRect) + ny * CGRectGetHeight(_contentRect));
    }
    return YES;
}

- (NSArray<NSNumber *> *)overlayKeysBackToFront {
    if (!_sortedOverlayKeys) {
        _sortedOverlayKeys = [_overlayFrames.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(
                NSNumber *lhs, NSNumber *rhs) {
                MacWSStreamFrameDescriptor left =
                    self->_overlayFrames[lhs].descriptor;
                MacWSStreamFrameDescriptor right =
                    self->_overlayFrames[rhs].descriptor;
                if (left.layerLevel < right.layerLevel)
                    return NSOrderedAscending;
                if (left.layerLevel > right.layerLevel)
                    return NSOrderedDescending;
                return [lhs compare:rhs];
            }];
    }
    return _sortedOverlayKeys;
}

- (BOOL)resolveFinalCompositeCatalogAtPoint:(CGPoint)point
                                        pid:(int32_t *)pidOut
                                   windowID:(uint32_t *)windowIDOut
                                 descriptor:(MacWSStreamFrameDescriptor *)descriptorOut {
    if (![self hasFinalCompositeFrame] || !_streamConnected ||
        _latestWindows.count == 0) return NO;
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    if (frameWidth == 0 || frameHeight == 0 || point.x < 0.0 ||
        point.y < 0.0 || point.x >= frameWidth || point.y >= frameHeight)
        return NO;

    // displayd preserves CGWindowList's front-to-back catalog order.  Its
    // catalog contains only validated AppKit layer-zero windows, so the first
    // live endpoint whose backing-pixel rectangle contains this point is the
    // application represented by the already-composited pixels there.
    for (MacWSStreamWindow *window in _latestWindows) {
        MacWSStreamWindowDescriptor candidate = window.descriptor;
        MacWSStreamWindowFlags required =
            MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
        if (candidate.ownerPID <= 1 || candidate.windowID == 0 ||
            (candidate.flags & required) != required ||
            (candidate.flags & MacWSStreamWindowMenuBar) != 0 ||
            !MacWSAppInputEndpointReady(candidate.ownerPID) ||
            !isfinite(candidate.logicalX) ||
            !isfinite(candidate.logicalY) ||
            !isfinite(candidate.logicalWidth) ||
            !isfinite(candidate.logicalHeight) ||
            !isfinite(candidate.backingScale) ||
            candidate.logicalWidth <= 0.0f ||
            candidate.logicalHeight <= 0.0f ||
            candidate.backingScale < 0.5f ||
            candidate.backingScale > 8.0f) continue;
        CGFloat scale = candidate.backingScale;
        CGRect destination = CGRectMake(
            candidate.logicalX * scale, candidate.logicalY * scale,
            candidate.logicalWidth * scale,
            candidate.logicalHeight * scale);
        if (!CGRectContainsPoint(destination, point)) continue;
        if (pidOut) *pidOut = candidate.ownerPID;
        if (windowIDOut) *windowIDOut = candidate.windowID;
        if (descriptorOut) {
            // Scroll/magnify/rotate are routed application-locally.  Build
            // their affine mapping from the same catalog geometry instead of
            // requiring a duplicate overlay IOSurface to remain leased.
            *descriptorOut = (MacWSStreamFrameDescriptor){
                .magic = MACWS_STREAM_MAGIC,
                .version = MACWS_STREAM_VERSION,
                .size = sizeof(MacWSStreamFrameDescriptor),
                .width = candidate.pixelWidth,
                .height = candidate.pixelHeight,
                .backingScale = scale,
                .contentWidth = candidate.pixelWidth,
                .contentHeight = candidate.pixelHeight,
                .layerWindowID = candidate.windowID,
                .layerOwnerPID = candidate.ownerPID,
                .destinationX = (int32_t)llround(CGRectGetMinX(destination)),
                .destinationY = (int32_t)llround(CGRectGetMinY(destination)),
                .destinationWidth = (uint32_t)llround(
                    CGRectGetWidth(destination)),
                .destinationHeight = (uint32_t)llround(
                    CGRectGetHeight(destination)),
            };
        }
        return YES;
    }
    return NO;
}

- (int32_t)frontmostInputApplicationPIDAmongPIDs:(NSSet<NSNumber *> *)pids {
    // Prefer the session-wide LaunchServices authority published by
    // macwsdisplayd.  Unlike process-local keyWindow/Focused state, exactly
    // one application owns this flag.  It also follows the already-composited
    // final desktop when an old independent capture layer has stopped
    // producing and therefore retains obsolete z-order metadata.
    for (MacWSStreamWindow *window in _latestWindows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        if ((descriptor.flags &
                MacWSStreamWindowFrontmostApplication) == 0 ||
            descriptor.ownerPID <= 1 ||
            (pids.count != 0 &&
             ![pids containsObject:@(descriptor.ownerPID)]) ||
            !MacWSAppInputEndpointReady(descriptor.ownerPID)) continue;
        return descriptor.ownerPID;
    }
    BOOL restrictToCatalogPIDs = pids.count != 0;
    if ([self hasFinalCompositeFrame] && _streamConnected) {
        // FinalComposite is the live desktop generation. displayd builds the
        // matching catalog from CGWindowListCopyWindowInfo(OnScreenOnly), in
        // the same front-to-back order as those pixels. Exact layer captures
        // are intentionally suspended once FinalComposite is authoritative;
        // their retained layerLevel values can consequently be minutes old.
        // Runtime-confirmed by the 2026-09-30 TestUFO profile: selecting that
        // retired graph oscillated the target Code -> Terminal -> Activity
        // Monitor and repeatedly revoked Code's valid direct-drawable lease.
        // Use the catalog from the live composite generation before consulting
        // retained fallback layers. The unique LaunchServices frontmost flag
        // above remains the first choice when it is available.
        for (MacWSStreamWindow *window in _latestWindows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            MacWSStreamWindowFlags required =
                MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
            if (descriptor.ownerPID <= 1 || descriptor.windowID == 0 ||
                (restrictToCatalogPIDs &&
                 ![pids containsObject:@(descriptor.ownerPID)]) ||
                (descriptor.flags & required) != required ||
                !MacWSAppInputEndpointReady(descriptor.ownerPID)) continue;
            MacWSLog(@"fullscreen-frontmost route=final-composite-live-"
                     "catalog pid=%d window=%u flags=%#x",
                     descriptor.ownerPID, descriptor.windowID,
                     descriptor.flags);
            return descriptor.ownerPID;
        }
    }
    // Without a live final composite, the exact layer graph is the pixels Host
    // actually draws and its layerLevel order is the correct fallback. An
    // empty catalog is also a real fullscreen-game state (runtime: Stray PID
    // 22119 kept layer 67 and its input endpoint while publishing no AppKit
    // catalog item), so do not require a catalog identity in that case.
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        if (descriptor.layerOwnerPID <= 1 ||
            (restrictToCatalogPIDs &&
             ![pids containsObject:@(descriptor.layerOwnerPID)]) ||
            descriptor.layerWindowID == 0 ||
            (descriptor.flags & MacWSStreamFrameGlobalSystemSurface) != 0 ||
            (descriptor.flags & MacWSStreamFrameInputPassthrough) != 0 ||
            !MacWSAppInputEndpointReady(descriptor.layerOwnerPID)) continue;
        return descriptor.layerOwnerPID;
    }
    return 0;
}

- (void)logPerformanceSnapshotWithReason:(NSString *)reason {
    NSMutableArray<NSString *> *layers = [NSMutableArray array];
    for (NSNumber *key in [self overlayKeysBackToFront]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        [layers addObject:[NSString stringWithFormat:
            @"layer=%u/pid=%d/stream=%llu/sequence=%llu/surface=%u/age-ms=%.2f",
            descriptor.layerWindowID, descriptor.layerOwnerPID,
            (unsigned long long)descriptor.streamID,
            (unsigned long long)descriptor.sequence,
            IOSurfaceGetID(frame.surface),
            MacWSMachMilliseconds(frame.receiptTime, mach_absolute_time())]];
    }
    MacWSStreamFrameDescriptor base = _surfaceFrame.descriptor;
    MacWSLog(@"display-performance-snapshot reason=%@ "
             "base-stream=%llu base-sequence=%llu base-surface=%u "
             "texture-imports=%llu texture-reuses=%llu layers=[%@]",
             reason.length ? reason : @"manual",
             (unsigned long long)base.streamID,
             (unsigned long long)base.sequence,
             _surfaceFrame ? IOSurfaceGetID(_surfaceFrame.surface) : 0,
             (unsigned long long)_surfaceTextureImports,
             (unsigned long long)_surfaceTextureReuses,
             [layers componentsJoinedByString:@", "]);
}

- (BOOL)writeBaseSurfaceSnapshotToPath:(NSString *)path {
    IOSurfaceRef surface = _surfaceFrame.surface;
    if (!surface || path.length == 0) return NO;
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    if (width == 0 || height == 0 || bytesPerRow < width * 4) return NO;
    int32_t locked = IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    if (locked != 0) return NO;
    void *base = IOSurfaceGetBaseAddress(surface);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = base && colorSpace
        ? CGBitmapContextCreate(base, width, height, 8, bytesPerRow,
              colorSpace, kCGBitmapByteOrder32Little |
                  kCGImageAlphaPremultipliedFirst)
        : NULL;
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
    NSData *png = image
        ? UIImagePNGRepresentation([UIImage imageWithCGImage:image]) : nil;
    NSError *error = nil;
    BOOL written = png.length &&
        [png writeToFile:path options:NSDataWritingAtomic error:&error];
    if (image) CGImageRelease(image);
    if (context) CGContextRelease(context);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    MacWSLog(@"base-surface-snapshot written=%@ bytes=%lu stream=%llu "
             "sequence=%llu surface=%u path=%@ error=%@",
             written ? @"YES" : @"NO", (unsigned long)png.length,
             (unsigned long long)_surfaceFrame.descriptor.streamID,
             (unsigned long long)_surfaceFrame.descriptor.sequence,
             IOSurfaceGetID(surface), path, error ?: @"");
    return written;
}

- (BOOL)writeSurface:(IOSurfaceRef)surface
              toPath:(NSString *)path
          sampleName:(NSString *)sampleName
          descriptor:(MacWSStreamFrameDescriptor)descriptor {
    if (!surface || path.length == 0) return NO;
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    if (width == 0 || height == 0 || bytesPerRow < width * 4) return NO;
    int32_t locked = IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    if (locked != 0) {
        MacWSLog(@"workspace-layer-snapshot name=%@ lock=%d", sampleName,
                 locked);
        return NO;
    }
    const uint8_t *base = IOSurfaceGetBaseAddress(surface);
    NSUInteger sampled = 0;
    NSUInteger nonzeroRGB = 0;
    NSUInteger nonzeroAlpha = 0;
    uint8_t minAlpha = UINT8_MAX;
    uint8_t maxAlpha = 0;
    if (base) {
        const NSUInteger targetSamples = 8192;
        size_t pixelCount = width * height;
        size_t step = MAX((size_t)1, pixelCount / targetSamples);
        for (size_t index = 0; index < pixelCount; index += step) {
            size_t x = index % width;
            size_t y = index / width;
            const uint8_t *pixel = base + y * bytesPerRow + x * 4;
            sampled++;
            if (pixel[0] || pixel[1] || pixel[2]) nonzeroRGB++;
            if (pixel[3]) nonzeroAlpha++;
            minAlpha = MIN(minAlpha, pixel[3]);
            maxAlpha = MAX(maxAlpha, pixel[3]);
        }
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = base && colorSpace
        ? CGBitmapContextCreate((void *)base, width, height, 8, bytesPerRow,
              colorSpace, kCGBitmapByteOrder32Little |
                  kCGImageAlphaPremultipliedFirst)
        : NULL;
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
    NSData *png = image
        ? UIImagePNGRepresentation([UIImage imageWithCGImage:image]) : nil;
    NSError *error = nil;
    BOOL written = png.length &&
        [png writeToFile:path options:NSDataWritingAtomic error:&error];
    if (image) CGImageRelease(image);
    if (context) CGContextRelease(context);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    MacWSLog(@"workspace-layer-snapshot name=%@ written=%@ bytes=%lu "
             "surface=%u size=%zux%zu bpr=%zu sampled=%lu rgb=%lu "
             "alpha=%lu alpha-range=%u..%u flags=0x%x level=%d "
             "destination=%d,%d %ux%u content=%u,%u %ux%u "
             "path=%@ error=%@",
             sampleName, written ? @"YES" : @"NO", (unsigned long)png.length,
             IOSurfaceGetID(surface), width, height, bytesPerRow,
             (unsigned long)sampled, (unsigned long)nonzeroRGB,
             (unsigned long)nonzeroAlpha,
             sampled ? minAlpha : 0, maxAlpha, descriptor.flags,
             descriptor.layerLevel, descriptor.destinationX,
             descriptor.destinationY, descriptor.destinationWidth,
             descriptor.destinationHeight, descriptor.contentX,
             descriptor.contentY, descriptor.contentWidth,
             descriptor.contentHeight, path, error ?: @"");
    return written;
}

- (NSUInteger)writeWorkspaceSurfaceSnapshotsToDirectory:(NSString *)directory {
    if (directory.length == 0) return 0;
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager]
            createDirectoryAtPath:directory
       withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        MacWSLog(@"workspace-layer-snapshot directory=%@ error=%@", directory,
                 directoryError ?: @"unknown");
        return 0;
    }
    NSUInteger written = 0;
    if (_surfaceFrame && [self writeSurface:_surfaceFrame.surface
        toPath:[directory stringByAppendingPathComponent:@"base.png"]
        sampleName:@"base" descriptor:_surfaceFrame.descriptor]) written++;
    for (NSNumber *key in [self overlayKeysBackToFront]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        NSString *name = [NSString stringWithFormat:@"layer-%u-pid-%d",
            frame.descriptor.layerWindowID, frame.descriptor.layerOwnerPID];
        NSString *path = [directory stringByAppendingPathComponent:
            [name stringByAppendingPathExtension:@"png"]];
        if ([self writeSurface:frame.surface toPath:path sampleName:name
                    descriptor:frame.descriptor]) written++;
    }
    MacWSLog(@"workspace-layer-snapshot-complete directory=%@ written=%lu "
             "expected=%lu", directory, (unsigned long)written,
             (unsigned long)(_overlayFrames.count + (_surfaceFrame ? 1 : 0)));
    return written;
}

- (BOOL)resolveFullscreenLayerAtPoint:(CGPoint)point
                                  pid:(int32_t *)pidOut
                             windowID:(uint32_t *)windowIDOut
                           descriptor:(MacWSStreamFrameDescriptor *)descriptorOut {
    // Input-only system surfaces are above the AppKit catalog. Their current
    // WindowServer visibility, not a stale independent texture, owns the hit.
    if (_streamConnected) for (MacWSStreamWindow *window in
                               _streamClient.systemInputWindows) {
        MacWSStreamWindowDescriptor candidate = window.descriptor;
        CGFloat scale = candidate.backingScale;
        CGRect bounds = CGRectMake(candidate.logicalX * scale,
            candidate.logicalY * scale, candidate.logicalWidth * scale,
            candidate.logicalHeight * scale);
        if (candidate.ownerPID != [self dockSystemGestureTargetPID] ||
            !CGRectContainsPoint(bounds, point)) continue;
        if (pidOut) *pidOut = candidate.ownerPID;
        if (windowIDOut) *windowIDOut = candidate.windowID;
        if (descriptorOut) *descriptorOut = (MacWSStreamFrameDescriptor){
            .magic = MACWS_STREAM_MAGIC, .version = MACWS_STREAM_VERSION,
            .size = sizeof(MacWSStreamFrameDescriptor),
            .flags = MacWSStreamFrameGlobalSystemSurface,
            .width = candidate.pixelWidth, .height = candidate.pixelHeight,
            .backingScale = scale,
            .contentWidth = candidate.pixelWidth,
            .contentHeight = candidate.pixelHeight,
            .layerWindowID = candidate.windowID,
            .layerOwnerPID = candidate.ownerPID,
            .destinationX = (int32_t)llround(bounds.origin.x),
            .destinationY = (int32_t)llround(bounds.origin.y),
            .destinationWidth = candidate.pixelWidth,
            .destinationHeight = candidate.pixelHeight,
        };
        return YES;
    }
    MacWSCatalystDrawableFrame *fullscreenDrawable =
        [self authoritativeFullscreenDrawableFrame];
    if (fullscreenDrawable) {
        CGRect desktop = CGRectMake(0, 0, [self currentFrameWidth],
                                    [self currentFrameHeight]);
        CGRect canvas = CGRectIntersection(
            _reportedFullscreenCanvasPixels, desktop);
        // drawInMTKView clears the space outside this exact canvas instead of
        // painting the retained desktop. Never activate a hidden catalog
        // window by hitting that letterbox. System input-only surfaces above
        // the drawable were already considered by the loop above.
        if (CGRectIsNull(canvas) || !CGRectContainsPoint(canvas, point))
            return NO;
        MacWSSurfaceFrame *layer =
            _overlayFrames[@(_reportedFullscreenCanvasWindowID)];
        MacWSStreamFrameDescriptor descriptor = layer
            ? layer.descriptor : (MacWSStreamFrameDescriptor){0};
        if (!layer) {
            uint32_t width = (uint32_t)llround(canvas.size.width);
            uint32_t height = (uint32_t)llround(canvas.size.height);
            descriptor = (MacWSStreamFrameDescriptor){
                .magic = MACWS_STREAM_MAGIC,
                .version = MACWS_STREAM_VERSION,
                .size = sizeof(MacWSStreamFrameDescriptor),
                .width = width, .height = height,
                .contentWidth = width, .contentHeight = height,
                .layerWindowID = _reportedFullscreenCanvasWindowID,
                .layerOwnerPID = self.targetPID,
                .destinationX = (int32_t)llround(canvas.origin.x),
                .destinationY = (int32_t)llround(canvas.origin.y),
                .destinationWidth = width, .destinationHeight = height,
            };
        }
        if (pidOut) *pidOut = self.targetPID;
        if (windowIDOut) *windowIDOut =
            _reportedFullscreenCanvasWindowID;
        if (descriptorOut) *descriptorOut = descriptor;
        return YES;
    }
    // A live FinalComposite is the surface drawInMTKView actually presents.
    // Resolve it against displayd's live front-to-back OnScreenOnly catalog
    // before consulting independent layer captures. Those captures are
    // intentionally suspended once FinalComposite is authoritative and can
    // therefore be minutes stale: runtime snapshot on 2026-08-30 measured
    // Settings child 302 at 144 s old and its main layer at 2212 s old while
    // the base composite was current. Overlay-first hit-testing consequently
    // sent Activity Monitor scrolling to stale Settings PID 95665.
    if ([self resolveFinalCompositeCatalogAtPoint:point pid:pidOut
                                         windowID:windowIDOut
                                       descriptor:descriptorOut]) return YES;

    // Without a catalog-resolvable final composite (notably a fullscreen game
    // drawable), traverse the exact independent graph in reverse paint order.
    // This is main-thread, in-process O(visible layers): no WindowServer IPC
    // and no bounded all-process target-probe round trip.
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        if (descriptor.layerOwnerPID <= 1 ||
            descriptor.layerWindowID == 0 ||
            (descriptor.flags & MacWSStreamFrameInputPassthrough) != 0 ||
            descriptor.destinationWidth == 0 ||
            descriptor.destinationHeight == 0) continue;
        CGRect destination = CGRectMake(
            descriptor.destinationX, descriptor.destinationY,
            descriptor.destinationWidth, descriptor.destinationHeight);
        if (!CGRectContainsPoint(destination, point)) continue;
        // Full-display Dock/menu surfaces are intentionally transparent away
        // from their controls. Rectangle-only hit testing therefore selects
        // Dock above every application even though Metal visibly composites
        // the application through that pixel. Read the same BGRA alpha byte
        // used by the fragment blend and skip only a proven transparent pixel.
        // The leased DisplayStream IOSurface is already CPU-mapped; this is a
        // single-byte read at gesture start, not an IOSurface lock or scan.
        const uint8_t *base = IOSurfaceGetBaseAddress(frame.surface);
        size_t stride = IOSurfaceGetBytesPerRow(frame.surface);
        size_t surfaceWidth = IOSurfaceGetWidth(frame.surface);
        size_t surfaceHeight = IOSurfaceGetHeight(frame.surface);
        if (base && stride >= surfaceWidth * 4 && surfaceWidth > 0 &&
            surfaceHeight > 0 && descriptor.contentWidth > 0 &&
            descriptor.contentHeight > 0) {
            double u = (point.x - CGRectGetMinX(destination)) /
                CGRectGetWidth(destination);
            double v = (point.y - CGRectGetMinY(destination)) /
                CGRectGetHeight(destination);
            size_t sourceX = MIN((size_t)descriptor.contentX +
                (size_t)floor(fmax(0.0, fmin(u, 0.999999)) *
                              descriptor.contentWidth), surfaceWidth - 1);
            size_t sourceY = MIN((size_t)descriptor.contentY +
                (size_t)floor(fmax(0.0, fmin(v, 0.999999)) *
                              descriptor.contentHeight), surfaceHeight - 1);
            if (base[sourceY * stride + sourceX * 4 + 3] == 0) continue;
        }
        if (pidOut) *pidOut = descriptor.layerOwnerPID;
        if (windowIDOut) *windowIDOut = descriptor.layerWindowID;
        if (descriptorOut) *descriptorOut = descriptor;
        return YES;
    }
    return NO;
}

- (BOOL)performanceVisiblePointForTargetPID:(int32_t)targetPID
                                      point:(CGPoint *)point {
    if (targetPID <= 1) return NO;
    static const CGFloat fractions[][2] = {
        {0.50, 0.50}, {0.35, 0.35}, {0.65, 0.35}, {0.35, 0.65},
        {0.65, 0.65}, {0.50, 0.30}, {0.50, 0.70}, {0.30, 0.50},
        {0.70, 0.50}, {0.20, 0.20}, {0.80, 0.20}, {0.20, 0.80},
        {0.80, 0.80},
    };
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        MacWSStreamFrameDescriptor descriptor = frame.descriptor;
        if (descriptor.layerOwnerPID != targetPID ||
            descriptor.destinationWidth == 0 ||
            descriptor.destinationHeight == 0) continue;
        CGRect destination = CGRectMake(
            descriptor.destinationX, descriptor.destinationY,
            descriptor.destinationWidth, descriptor.destinationHeight);
        for (NSUInteger index = 0;
             index < sizeof(fractions) / sizeof(fractions[0]); index++) {
            CGPoint candidate = CGPointMake(
                CGRectGetMinX(destination) +
                    CGRectGetWidth(destination) * fractions[index][0],
                CGRectGetMinY(destination) +
                    CGRectGetHeight(destination) * fractions[index][1]);
            int32_t resolvedPID = 0;
            uint32_t resolvedWindowID = 0;
            if ([self resolveFullscreenLayerAtPoint:candidate
                                                pid:&resolvedPID
                                           windowID:&resolvedWindowID
                                         descriptor:NULL] &&
                resolvedPID == targetPID &&
                resolvedWindowID == descriptor.layerWindowID) {
                if (point) *point = candidate;
                return YES;
            }
        }
    }

    // A FinalComposite surface already contains every WindowServer layer, so
    // displayd intentionally retires the duplicate per-window overlay
    // surfaces after that producer becomes authoritative.  Keep the
    // performance probe evidence-based in that mode: require both a live
    // final-composite frame and a current visible/on-screen catalog entry for
    // this exact PID, then select a point inside the catalog rectangle.  The
    // normal fullscreen input path still sends this point through Dock's
    // global CGEvent endpoint, leaving WindowServer as the actual hit tester.
    if (![self hasFinalCompositeFrame] || !_streamConnected ||
        _latestWindows.count == 0) return NO;
    uint32_t frameWidth = [self currentFrameWidth];
    uint32_t frameHeight = [self currentFrameHeight];
    if (frameWidth == 0 || frameHeight == 0) return NO;
    for (MacWSStreamWindow *window in _latestWindows) {
        MacWSStreamWindowDescriptor candidate = window.descriptor;
        MacWSStreamWindowFlags required =
            MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
        if (candidate.ownerPID != targetPID ||
            (candidate.flags & required) != required ||
            (candidate.flags & MacWSStreamWindowMenuBar) != 0 ||
            !isfinite(candidate.logicalX) ||
            !isfinite(candidate.logicalY) ||
            !isfinite(candidate.logicalWidth) ||
            !isfinite(candidate.logicalHeight) ||
            candidate.logicalWidth <= 0.0f ||
            candidate.logicalHeight <= 0.0f) continue;
        CGFloat scale = candidate.backingScale;
        if (!isfinite(scale) || scale < 0.5 || scale > 8.0) continue;
        CGRect destination = CGRectMake(
            candidate.logicalX * scale, candidate.logicalY * scale,
            candidate.logicalWidth * scale,
            candidate.logicalHeight * scale);
        CGRect intersection = CGRectIntersection(destination,
            CGRectMake(0.0, 0.0, frameWidth, frameHeight));
        if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection))
            continue;
        for (NSUInteger index = 0;
             index < sizeof(fractions) / sizeof(fractions[0]); index++) {
            CGPoint visiblePoint = CGPointMake(
                CGRectGetMinX(intersection) + CGRectGetWidth(intersection) *
                    fractions[index][0],
                CGRectGetMinY(intersection) + CGRectGetHeight(intersection) *
                    fractions[index][1]);
            int32_t resolvedPID = 0;
            uint32_t resolvedWindowID = 0;
            if (![self resolveFinalCompositeCatalogAtPoint:visiblePoint
                                                       pid:&resolvedPID
                                                  windowID:&resolvedWindowID
                                                descriptor:NULL] ||
                resolvedPID != targetPID ||
                resolvedWindowID != candidate.windowID) continue;
            if (point) *point = visiblePoint;
            MacWSLog(@"performance-visible-target "
                     "route=final-composite-catalog pid=%d window=%u "
                     "flags=%#x point=(%.1f,%.1f) frame=%ux%u",
                     targetPID, candidate.windowID, candidate.flags,
                     visiblePoint.x, visiblePoint.y, frameWidth, frameHeight);
            return YES;
        }
    }
    return NO;
}

- (BOOL)performanceTitlebarPointForTargetPID:(int32_t)targetPID
                                       point:(CGPoint *)point {
    if (targetPID <= 1 || _streamClient.mode != MacWSStreamModeFullscreen)
        return NO;
    for (MacWSStreamWindow *window in _latestWindows) {
        MacWSStreamWindowDescriptor candidate = window.descriptor;
        MacWSStreamWindowFlags required =
            MacWSStreamWindowVisible | MacWSStreamWindowOnScreen;
        if (candidate.ownerPID != targetPID || candidate.windowID == 0 ||
            (candidate.flags & required) != required ||
            !isfinite(candidate.logicalX) ||
            !isfinite(candidate.logicalY) ||
            !isfinite(candidate.logicalWidth) ||
            !isfinite(candidate.logicalHeight) ||
            !isfinite(candidate.backingScale) ||
            candidate.logicalWidth <= 80.0 ||
            candidate.logicalHeight <= 40.0 ||
            candidate.backingScale < 0.5 ||
            candidate.backingScale > 8.0) continue;
        CGFloat scale = candidate.backingScale;
        CGRect destination = CGRectMake(
            candidate.logicalX * scale, candidate.logicalY * scale,
            candidate.logicalWidth * scale,
            candidate.logicalHeight * scale);
        // Standard AppKit traffic lights occupy the leading edge, while
        // Electron's command center occupies the middle/right. One quarter
        // width and 18 logical points below the top is a stable draggable
        // title-bar region for both without relying on application-specific
        // controls. Confirm the point against the currently composited layer
        // so an overlapping window can never receive this diagnostic drag.
        CGPoint candidatePoint = CGPointMake(
            CGRectGetMinX(destination) + CGRectGetWidth(destination) * 0.25,
            CGRectGetMinY(destination) + 18.0 * scale);
        int32_t resolvedPID = 0;
        uint32_t resolvedWindowID = 0;
        if (![self resolveFullscreenLayerAtPoint:candidatePoint
                                             pid:&resolvedPID
                                        windowID:&resolvedWindowID
                                      descriptor:NULL] ||
            resolvedPID != targetPID ||
            resolvedWindowID != candidate.windowID) continue;
        if (point) *point = candidatePoint;
        MacWSLog(@"performance-window-titlebar pid=%d window=%u point=(%.1f,%.1f) destination=(%.1f,%.1f %.1fx%.1f)",
                 targetPID, candidate.windowID, candidatePoint.x,
                 candidatePoint.y, destination.origin.x,
                 destination.origin.y, destination.size.width,
                 destination.size.height);
        return YES;
    }
    return NO;
}

- (BOOL)routeFullscreenInputRecord:(MacWSInputRecord *)record
             presentationTargetPID:(int32_t *)presentationTargetPID {
    if (!record || _streamClient.mode != MacWSStreamModeFullscreen)
        return NO;
    if (presentationTargetPID) *presentationTargetPID = record->targetPID;
    BOOL globalPointer =
        record->kind == MacWSInputKindTouchDown ||
        record->kind == MacWSInputKindTouchMove ||
        record->kind == MacWSInputKindTouchUp ||
        record->kind == MacWSInputKindTouchCancel ||
        record->kind == MacWSInputKindHover ||
        record->kind == MacWSInputKindMenuHover ||
        record->kind == MacWSInputKindTap ||
        record->kind == MacWSInputKindSecondaryTap;
    if (globalPointer) {
        // A fullscreen desktop is one WindowServer input surface, just like a
        // physical Mac display or OSXvnc.  Do not route pointer input into the
        // AppKit process whose *captured* pixels happen to be under the
        // finger: Mission Control applies compositor-only transforms to those
        // windows, so their local NSWindow coordinates are no longer the
        // visible card coordinates.  Runtime A/B on 2026-08-08 proved that
        // the old route ignored or crashed on a Mission Control card, while
        // the same point through OSXvnc's global CGPostMouseEvent selected the
        // card and completed with stable WindowServer/Dock/Terminal PIDs.
        //
        // Dock is already the verified CGS-connected owner used for native
        // three-finger gestures.  A zero encoded window deliberately tells
        // its endpoint to preserve full-desktop coordinates and let
        // WindowServer perform the authoritative, current global hit test.
        int32_t dockPID = [self dockSystemGestureTargetPID];
        if (dockPID > 1) {
            int32_t visualPID = 0;
            uint32_t visualWindowID = 0;
            BOOL beginsGlobalDrag = record->kind == MacWSInputKindTouchDown;
            BOOL continuesGlobalDrag = record->kind == MacWSInputKindTouchMove ||
                record->kind == MacWSInputKindTouchUp ||
                record->kind == MacWSInputKindTouchCancel;
            if (continuesGlobalDrag &&
                _fullscreenGlobalPointerRouteActive &&
                record->contactID ==
                    _fullscreenGlobalPointerPresentationContactID) {
                visualPID = _fullscreenGlobalPointerPresentationPID;
            } else {
                (void)[self resolveFullscreenLayerAtPoint:
                    CGPointMake(record->x, record->y) pid:&visualPID
                    windowID:&visualWindowID descriptor:NULL];
            }
            if (beginsGlobalDrag) {
                _fullscreenGlobalPointerRouteActive = YES;
                _fullscreenGlobalPointerPresentationPID = visualPID;
                _fullscreenGlobalPointerPresentationContactID =
                    record->contactID;
            }
            if (presentationTargetPID) {
                // An explicit fullscreen regression probe measures the
                // global WindowServer/Dock transaction, including a
                // compositor-only Mission Control card retirement. Ordinary
                // physical input remains correlated with the visual app so
                // app-owned content latency keeps its existing meaning. A
                // controller-validated fullscreen direct drawable is also
                // app-owned visible output, even though Dock remains the
                // transport endpoint for its global pointer event. Preserve
                // that visual PID for the latency correlation; Mission
                // Control cards still use Dock because they have no such
                // authoritative application drawable.
                BOOL directVisualAuthority = visualPID == self.targetPID &&
                    [self authoritativeFullscreenDrawableFrame] != nil;
                *presentationTargetPID =
                    (record->flags & MacWSInputFlagLatencyDiagnostic) &&
                    !directVisualAuthority ? dockPID : visualPID;
            }
            if (visualPID > 1 &&
                visualPID != dockPID &&
                (record->kind == MacWSInputKindTouchDown ||
                 record->kind == MacWSInputKindTap ||
                 record->kind == MacWSInputKindSecondaryTap)) {
                // The clicked pixels are the strongest foreground witness in
                // fullscreen mode. Keep later hardware/software keyboard
                // records on that exact application without asking a stale
                // process-local focused flag to reorder the desktop.
                self.targetPID = visualPID;
            } else if (visualPID == dockPID && self.targetPID != dockPID &&
                       (record->kind == MacWSInputKindTouchDown ||
                        record->kind == MacWSInputKindTap ||
                        record->kind == MacWSInputKindSecondaryTap)) {
                // Dock is the global CGEvent transport endpoint, not the
                // semantic owner of the application pixels being presented.
                // Keep the current application target until the app/window
                // catalog observes the result of the Dock click.  Assigning
                // Dock here used to clear the live fullscreen drawable join:
                // runtime logs at 1787944038.743 retired Stray's SkyLight
                // layer, 1787944042.808 then retained Dock as target, and the
                // Host immediately fell back to the desktop while Stray kept
                // rendering at 94%% GPU.  A real Dock launch still travels
                // through record->targetPID=dockPID below and the newly
                // frontmost application becomes the target from the catalog.
                MacWSLog(@"fullscreen-presentation-target retained=%d "
                         "ignored-system-proxy=%d kind=%u point=(%.1f,%.1f)",
                         self.targetPID, dockPID, record->kind,
                         record->x, record->y);
            }
            uint32_t modifiers =
                MacWSInputModifiersForScene(record->sceneID);
            record->targetPID = dockPID;
            // Ordinary fullscreen input stays a zero-window system stream so
            // WindowServer remains the final hit-test authority. An explicit
            // regression sample additionally carries Host's already-resolved
            // CGWindowID as a correlation key; Dock still posts the same
            // global CGPostMouseEvent and does not route by this identity.
            // A held button must remain one OSXvnc/WindowServer transaction.
            // Encoding an exact window only on diagnostic TouchDown made
            // inputd choose its exact-system-surface route for Down, then the
            // window-zero global proxy for Move/Up. That split owner produced
            // the same apparent mid-drag release this profiler is meant to
            // detect. presentationTargetPID already provides correlation, so
            // keep every sustained pointer edge on the production global
            // route; atomic taps may still carry a diagnostic window key.
            BOOL sustainedPointer =
                record->kind == MacWSInputKindTouchDown ||
                record->kind == MacWSInputKindTouchMove ||
                record->kind == MacWSInputKindTouchUp ||
                record->kind == MacWSInputKindTouchCancel;
            uint32_t diagnosticWindowID =
                (record->flags & MacWSInputFlagLatencyDiagnostic) &&
                !sustainedPointer ? visualWindowID : 0;
            record->sceneID = MacWSInputSceneForWindow(
                diagnosticWindowID, modifiers);
            record->flags |= MacWSInputFlagGlobalSystemSurface;
            if ((record->kind == MacWSInputKindTouchDown ||
                 record->kind == MacWSInputKindTouchUp ||
                 record->kind == MacWSInputKindTouchCancel) &&
                MacWSHostTouchDiagnosticsEnabled()) {
                MacWSLog(@"fullscreen-global-pointer kind=%u contact=%u dock=%d visual=%d visual-window=%u point=(%.1f,%.1f) frame=%ux%u",
                         record->kind, record->contactID, dockPID,
                         visualPID, visualWindowID, record->x, record->y,
                         record->frameWidth, record->frameHeight);
            }
            if ((record->kind == MacWSInputKindTouchUp ||
                 record->kind == MacWSInputKindTouchCancel) &&
                record->contactID ==
                    _fullscreenGlobalPointerPresentationContactID) {
                _fullscreenGlobalPointerRouteActive = NO;
                _fullscreenGlobalPointerPresentationPID = 0;
                _fullscreenGlobalPointerPresentationContactID = 0;
            }
            return YES;
        }
    }
    BOOL terminal = record->kind == MacWSInputKindTouchUp ||
        record->kind == MacWSInputKindTouchCancel ||
        (record->kind == MacWSInputKindScroll &&
         (record->flags & (MacWSInputFlagScrollEnded |
                           MacWSInputFlagScrollCancelled))) ||
        ((record->kind == MacWSInputKindMagnify ||
          record->kind == MacWSInputKindRotate) &&
         (record->flags & (MacWSInputFlagGestureEnded |
                           MacWSInputFlagGestureCancelled)));
    BOOL begins = record->kind == MacWSInputKindTouchDown ||
        (record->kind == MacWSInputKindScroll &&
         (record->flags & MacWSInputFlagScrollBegan)) ||
        ((record->kind == MacWSInputKindMagnify ||
          record->kind == MacWSInputKindRotate) &&
         (record->flags & MacWSInputFlagGestureBegan));
    BOOL continuation = record->kind == MacWSInputKindTouchMove || terminal ||
        (record->kind == MacWSInputKindScroll && !begins) ||
        ((record->kind == MacWSInputKindMagnify ||
          record->kind == MacWSInputKindRotate) && !begins);
    // Continuous scroll records encode horizontal delta bits in contactID, so
    // the URL performance suite cannot use the legacy "DIAG" contact value.
    // Its typed latency flag is the common diagnostic identity for pointer,
    // scroll, magnify and rotate. Log only transaction edges to keep a 120 Hz
    // validation run bounded while retaining the resolved Begin descriptor
    // and the frozen End route as runtime evidence.
    BOOL diagnostic =
        record->contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC ||
        (record->flags & MacWSInputFlagLatencyDiagnostic) != 0 ||
        ((begins || terminal) && MacWSHostTouchDiagnosticsEnabled());
    BOOL diagnosticEdge = diagnostic &&
        (!continuation || begins || terminal);
    if (diagnosticEdge) {
        MacWSLog(@"fullscreen-route-entry view=%p kind=%u begin=%@ continuation=%@ terminal=%@ active=%@ contact=%u owner-contact=%u frozen-destination=(%d,%d %ux%u)",
                 self, record->kind, begins ? @"YES" : @"NO",
                 continuation ? @"YES" : @"NO", terminal ? @"YES" : @"NO",
                 _fullscreenGestureRouteActive ? @"YES" : @"NO",
                 record->contactID, _fullscreenGestureRouteContactID,
                 _fullscreenGestureRouteDescriptor.destinationX,
                 _fullscreenGestureRouteDescriptor.destinationY,
                 _fullscreenGestureRouteDescriptor.destinationWidth,
                 _fullscreenGestureRouteDescriptor.destinationHeight);
    }

    int32_t ownerPID = 0;
    uint32_t windowID = 0;
    MacWSStreamFrameDescriptor descriptor = {0};
    BOOL resolved = NO;
    BOOL atomicPrimaryTap = record->kind == MacWSInputKindTap;
    BOOL reuseDoubleTapRoute = atomicPrimaryTap &&
        (record->flags & MacWSInputFlagDoubleClick) != 0 &&
        _fullscreenLastTapRouteTimestamp > 0.0 &&
        record->timestamp >= _fullscreenLastTapRouteTimestamp &&
        record->timestamp - _fullscreenLastTapRouteTimestamp <=
            MACWS_DIRECT_DOUBLE_TAP_SECONDS + 0.05 &&
        _fullscreenLastTapRoutePID > 1 &&
        _fullscreenLastTapRouteWindowID != 0 &&
        _overlayFrames[@(_fullscreenLastTapRouteWindowID)] != nil;
    if (reuseDoubleTapRoute) {
        ownerPID = _fullscreenLastTapRoutePID;
        windowID = _fullscreenLastTapRouteWindowID;
        descriptor = _fullscreenLastTapRouteDescriptor;
        resolved = YES;
    } else if (continuation && _fullscreenGestureRouteActive) {
        ownerPID = _fullscreenGestureRoutePID;
        windowID = _fullscreenGestureRouteWindowID;
        resolved = ownerPID > 1 && windowID != 0;
        // A gesture is one affine transaction. WindowServer changes the live
        // layer destination after every native title-bar drag sample. Mapping
        // the next fixed desktop point through that moving destination
        // subtracts the displacement just applied and makes the window bounce
        // left/right. The Begin descriptor is already retained specifically as
        // the coordinate snapshot, so keep it authoritative through End.
        descriptor = _fullscreenGestureRouteDescriptor;
    } else {
        resolved = [self resolveFullscreenLayerAtPoint:
            CGPointMake(record->x, record->y) pid:&ownerPID
                     windowID:&windowID descriptor:&descriptor];
    }
    if (resolved) {
        if (presentationTargetPID) *presentationTargetPID = ownerPID;
        float desktopX = record->x;
        float desktopY = record->y;
        uint32_t modifiers = MacWSInputModifiersForScene(record->sceneID);
        BOOL globalSystemSurface =
            (descriptor.flags & MacWSStreamFrameGlobalSystemSurface) != 0;
        BOOL ownerHasEndpoint = MacWSAppInputEndpointReady(ownerPID);
        if (!globalSystemSurface && ownerHasEndpoint) {
            float layerX = 0.0f, layerY = 0.0f;
            resolved = MacWSStreamMapDesktopPointToLayer(
                &descriptor, desktopX, desktopY, &layerX, &layerY);
            if (!resolved) return NO;
            record->x = layerX;
            record->y = layerY;
            BOOL popupComposite = (descriptor.flags &
                MacWSStreamFrameNativePopupComposite) != 0;
            record->frameWidth = popupComposite ? descriptor.contentWidth : descriptor.width;
            record->frameHeight = popupComposite ? descriptor.contentHeight : descriptor.height;
            record->targetPID = ownerPID;
        } else {
            // Dock and similar global owners use a real process-local CGS
            // endpoint, but they are not AppKit windows and their capture is
            // the complete desktop coordinate space. Preserve those desktop
            // coordinates and identify the route explicitly from displayd's
            // catalog metadata; endpoint existence alone cannot distinguish
            // Dock from an ordinary exact-window application.
            record->targetPID = ownerPID;
            record->flags |= MacWSInputFlagGlobalSystemSurface;
        }
        record->sceneID = MacWSInputSceneForWindow(windowID, modifiers);
        if (diagnosticEdge) {
            MacWSLog(@"fullscreen-layer-input runtime-confirmed pid=%d target=%d route=%@ window=%u flags=%#x desktop=(%.1f,%.1f) local=(%.1f,%.1f)/%ux%u destination=(%d,%d %ux%u)",
                     ownerPID, record->targetPID,
                     globalSystemSurface ? @"global-system" : @"app",
                     windowID, descriptor.flags, desktopX, desktopY,
                     record->x, record->y, record->frameWidth,
                     record->frameHeight, descriptor.destinationX,
                     descriptor.destinationY, descriptor.destinationWidth,
                     descriptor.destinationHeight);
        }
    }
    // The first click can activate/reorder a native window and the event-
    // driven catalog refresh may land before the second physical click. Keep
    // a short-lived identity snapshot so a UIKit-authoritative double tap is
    // one AppKit transaction, matching VNC's proven same-connection pair.
    // Do not retain vanished popup/menu layers: a dismissal must expose the
    // newly hit-tested surface beneath it for the next independent tap.
    if (atomicPrimaryTap) {
        if (resolved) {
            _fullscreenLastTapRouteTimestamp = record->timestamp;
            _fullscreenLastTapRoutePID = ownerPID;
            _fullscreenLastTapRouteWindowID = windowID;
            _fullscreenLastTapRouteDescriptor = descriptor;
        } else if ((record->flags & MacWSInputFlagDoubleClick) == 0) {
            _fullscreenLastTapRouteTimestamp = 0.0;
            _fullscreenLastTapRoutePID = 0;
            _fullscreenLastTapRouteWindowID = 0;
            _fullscreenLastTapRouteDescriptor =
                (MacWSStreamFrameDescriptor){0};
        }
    }
    if (begins) {
        _fullscreenGestureRouteActive = resolved;
        _fullscreenGestureRouteContactID = resolved ? record->contactID : 0;
        _fullscreenGestureRoutePID = resolved ? ownerPID : 0;
        _fullscreenGestureRouteWindowID = resolved ? windowID : 0;
        _fullscreenGestureRouteDescriptor = resolved
            ? descriptor : (MacWSStreamFrameDescriptor){0};
    }
    // UIKit can deliver an unrelated pointer/finger cancellation while a
    // fullscreen title-bar tracker is active (URL/Scene activation is one
    // reproducible source). A Touch route belongs to its Begin contact; only
    // that contact may release it. Scroll carries horizontal delta bits in
    // contactID, so its native phase boundary remains the owner there.
    BOOL touchTerminal = record->kind == MacWSInputKindTouchUp ||
        record->kind == MacWSInputKindTouchCancel;
    BOOL terminalOwnsRoute = !touchTerminal ||
        !_fullscreenGestureRouteActive ||
        record->contactID == _fullscreenGestureRouteContactID;
    if (terminal && terminalOwnsRoute) {
        _fullscreenGestureRouteActive = NO;
        _fullscreenGestureRouteContactID = 0;
        _fullscreenGestureRoutePID = 0;
        _fullscreenGestureRouteWindowID = 0;
        _fullscreenGestureRouteDescriptor =
            (MacWSStreamFrameDescriptor){0};
    }
    if (resolved && record->kind == MacWSInputKindScroll &&
        (descriptor.flags & MacWSStreamFrameGlobalSystemSurface) &&
        ownerPID == [self dockSystemGestureTargetPID]) {
        // Launchpad is a Dock/WindowServer surface, not an NSWindow. Keep
        // the frozen descriptor above for gesture ownership, but deliver its
        // precise wheel stream through the same global session as pointers.
        // AppKit windows (including fullscreen VSCode) retain their existing
        // process-local scroll route and calibration.
        record->sceneID = MacWSInputSceneForWindow(0,
            MacWSInputModifiersForScene(record->sceneID));
    }
    if (diagnostic) {
        MacWSLog(@"fullscreen-route-exit view=%p kind=%u resolved=%@ active=%@ owner-contact=%u destination=(%d,%d %ux%u)",
                 self, record->kind, resolved ? @"YES" : @"NO",
                 _fullscreenGestureRouteActive ? @"YES" : @"NO",
                 _fullscreenGestureRouteContactID, descriptor.destinationX,
                 descriptor.destinationY, descriptor.destinationWidth,
                 descriptor.destinationHeight);
    }
    return resolved;
}

- (void)updatePointerVisibility {
    BOOL available = self.isMacWSInputEnabled &&
        [self currentFrameWidth] > 0 && [self currentFrameHeight] > 0;
    if (self.inputMode != MacWSHostInputModeDirect || !available ||
        !_directTouch) {
        _directTouchIndicator.hidden = YES;
    }
    BOOL showTrackpad = self.inputMode == MacWSHostInputModeTrackpad &&
        available && _trackpadCursorWasTouched && !_externalPointerHoverActive;
    if (showTrackpad) {
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (_trackpadCursor.x < 0 || _trackpadCursor.y < 0 ||
            _trackpadCursor.x >= width || _trackpadCursor.y >= height) {
            _trackpadCursor = CGPointMake(width * 0.5, height * 0.5);
        }
        CGPoint pointerCenter = CGPointZero;
        showTrackpad = [self viewPointForFramePoint:_trackpadCursor
                                             output:&pointerCenter];
        if (showTrackpad) {
            _trackpadCursorView.frame = CGRectMake(pointerCenter.x - 12.0,
                pointerCenter.y - 12.0, 24.0, 24.0);
        }
    }
    _trackpadCursorView.hidden = !showTrackpad;
    if (showTrackpad) [self bringSubviewToFront:_trackpadCursorView];
    BOOL showPencil = available && (_pencilHoverActive || _pencilTouch != nil);
    _pencilCursorView.hidden = !showPencil;
    if (showPencil) [self bringSubviewToFront:_pencilCursorView];
}

- (UIView *)makeMultitouchIndicator {
    UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    indicator.backgroundColor =
        [UIColor.systemCyanColor colorWithAlphaComponent:0.16];
    indicator.layer.borderWidth = 1.5;
    indicator.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.86].CGColor;
    indicator.layer.cornerRadius = 15.0;
    indicator.layer.shadowColor = UIColor.blackColor.CGColor;
    indicator.layer.shadowOpacity = 0.24;
    indicator.layer.shadowRadius = 5.0;
    indicator.layer.shadowOffset = CGSizeMake(0, 2);
    indicator.userInteractionEnabled = NO;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(11, 11, 8, 8)];
    dot.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.94];
    dot.layer.cornerRadius = 4.0;
    dot.userInteractionEnabled = NO;
    [indicator addSubview:dot];
    indicator.hidden = YES;
    [self addSubview:indicator];
    return indicator;
}

- (void)hideMultitouchIndicators {
    for (UIView *indicator in _multitouchIndicators) indicator.hidden = YES;
}

- (void)updateMultitouchIndicatorsForRecognizer:
        (UIGestureRecognizer *)recognizer {
    NSUInteger count = recognizer.numberOfTouches;
    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed || count < 2) {
        [self hideMultitouchIndicators];
        return;
    }
    while (_multitouchIndicators.count < count)
        [_multitouchIndicators addObject:[self makeMultitouchIndicator]];
    for (NSUInteger index = 0; index < _multitouchIndicators.count; index++) {
        UIView *indicator = _multitouchIndicators[index];
        indicator.hidden = index >= count;
        if (index < count) {
            indicator.center = [recognizer locationOfTouch:index inView:self];
            [self bringSubviewToFront:indicator];
        }
    }
}

- (void)setDirectTouchHeld:(BOOL)held dragging:(BOOL)dragging
                  animated:(BOOL)animated {
    UIView *contactDot = [_directTouchIndicator viewWithTag:501];
    _directTouchStateGlyph.image = [UIImage systemImageNamed:
        dragging ? @"hand.draw.fill" : @"hand.point.up.left.fill"];
    _directTouchStateGlyph.hidden = !held;
    contactDot.hidden = held;
    UIColor *accent = dragging ? UIColor.systemPurpleColor
                               : UIColor.systemOrangeColor;
    void (^changes)(void) = ^{
        self->_directTouchIndicator.transform = held
            ? CGAffineTransformMakeScale(1.22, 1.22)
            : CGAffineTransformIdentity;
        self->_directTouchIndicator.backgroundColor = held
            ? [accent colorWithAlphaComponent:0.58]
            : [UIColor.systemCyanColor colorWithAlphaComponent:0.15];
        self->_directTouchIndicator.layer.borderWidth = held ? 2.25 : 1.5;
        self->_directTouchIndicator.layer.borderColor = held
            ? UIColor.whiteColor.CGColor
            : [UIColor.whiteColor colorWithAlphaComponent:0.82].CGColor;
        self->_directTouchIndicator.layer.shadowColor = held
            ? accent.CGColor : UIColor.blackColor.CGColor;
        self->_directTouchIndicator.layer.shadowOpacity = held ? 0.72 : 0.22;
        self->_directTouchIndicator.layer.shadowRadius = held ? 9.0 : 5.0;
    };
    if (animated) {
        [UIView animateWithDuration:0.14 delay:0
            usingSpringWithDamping:0.72 initialSpringVelocity:0
            options:UIViewAnimationOptionBeginFromCurrentState |
                    UIViewAnimationOptionAllowUserInteraction
            animations:changes completion:nil];
    } else {
        changes();
    }
}

- (void)setTrackpadPointerPressed:(BOOL)pressed animated:(BOOL)animated {
    _trackpadStateGlyph.hidden = !pressed;
    void (^changes)(void) = ^{
        self->_trackpadCursorView.transform = pressed
            ? CGAffineTransformMakeScale(1.20, 1.20)
            : CGAffineTransformIdentity;
        self->_trackpadCursorView.alpha = 1.0;
        self->_trackpadCursorView.backgroundColor = pressed
            ? [UIColor.systemOrangeColor colorWithAlphaComponent:0.86]
            : [UIColor.systemGrayColor colorWithAlphaComponent:0.74];
        self->_trackpadCursorView.layer.borderWidth = pressed ? 2.0 : 1.0;
        self->_trackpadCursorView.layer.shadowColor = pressed
            ? UIColor.systemOrangeColor.CGColor : UIColor.blackColor.CGColor;
        self->_trackpadCursorView.layer.shadowOpacity = pressed ? 0.68 : 0.30;
        self->_trackpadCursorView.layer.shadowRadius = pressed ? 8.0 : 3.0;
    };
    if (animated) {
        [UIView animateWithDuration:0.12 delay:0
            options:UIViewAnimationOptionBeginFromCurrentState |
                    UIViewAnimationOptionAllowUserInteraction
            animations:changes completion:nil];
    } else {
        changes();
    }
}

- (void)emitKind:(MacWSInputKind)kind
      framePoint:(CGPoint)framePoint
        pressure:(float)pressure
       contactID:(uint32_t)contactID
       timestamp:(NSTimeInterval)timestamp
          source:(MacWSInputSource)source {
    if (!self.isMacWSInputEnabled) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = kind,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = pressure,
        .contactID = contactID,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = source,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)emitKind:(MacWSInputKind)kind
      framePoint:(CGPoint)framePoint
        pressure:(float)pressure
       contactID:(uint32_t)contactID
       timestamp:(NSTimeInterval)timestamp {
    [self emitKind:kind framePoint:framePoint pressure:pressure
         contactID:contactID timestamp:timestamp
            source:MacWSInputSourceFinger];
}

- (BOOL)beginInteropDragProbeAtViewPoint:(CGPoint)viewPoint {
    if (!self.isMacWSInputEnabled || _interopDragProbeActive ||
        self.targetPID <= 1) return NO;
    CGPoint startFrame = CGPointZero;
    if (![self framePointForViewPoint:viewPoint output:&startFrame]) return NO;
    CGFloat direction = viewPoint.x + 16.0 <= CGRectGetMaxX(_contentRect)
        ? 16.0 : -16.0;
    CGPoint movedPoint = CGPointMake(viewPoint.x + direction, viewPoint.y);
    CGPoint movedFrame = CGPointZero;
    if (![self framePointForViewPoint:movedPoint output:&movedFrame
                    clampContinuationToContent:YES]) return NO;
    _interopDragProbeActive = YES;
    _interopDragProbeFramePoint = movedFrame;
    _interopDragProbeContactID = 0x44524700u |
        ((++_directTouchSerial) & 0xffu); // "DRG"
    NSTimeInterval now = CACurrentMediaTime();
    [self emitKind:MacWSInputKindTouchDown framePoint:startFrame pressure:1.0f
         contactID:_interopDragProbeContactID timestamp:now
            source:MacWSInputSourceInteropDragProbe];
    [self emitKind:MacWSInputKindTouchMove framePoint:movedFrame pressure:1.0f
         contactID:_interopDragProbeContactID timestamp:now + 0.001
            source:MacWSInputSourceInteropDragProbe];
    return YES;
}

- (void)finishInteropDragProbeCancelled:(BOOL)cancelled {
    if (!_interopDragProbeActive) return;
    [self emitKind:cancelled ? MacWSInputKindTouchCancel : MacWSInputKindTouchUp
          framePoint:_interopDragProbeFramePoint pressure:0.0f
           contactID:_interopDragProbeContactID timestamp:CACurrentMediaTime()
              source:MacWSInputSourceInteropDragProbe];
    _interopDragProbeActive = NO;
    _interopDragProbeContactID = 0;
}

- (void)requireSecondaryTapToFailGestureRecognizer:
        (UIGestureRecognizer *)gestureRecognizer {
    if (!gestureRecognizer || !_secondaryTapRecognizer) return;
    // UIKit's failure dependency is the state-machine boundary we need:
    // lifting both fingers before the hold duration fails LongPress and then
    // permits SecondaryTap; reaching the hold duration recognizes LongPress
    // and permanently fails SecondaryTap for that same touch sequence.
    [_secondaryTapRecognizer
        requireGestureRecognizerToFail:gestureRecognizer];
}

- (void)performInteropPasteAtViewPoint:(CGPoint)viewPoint {
    if (!self.isMacWSInputEnabled || self.targetPID <= 1) {
        MacWSLog(@"interop-paste-route skipped reason=input enabled=%@ target=%d window=%u",
            self.isMacWSInputEnabled ? @"YES" : @"NO", self.targetPID,
            self.targetWindowID);
        return;
    }
    CGPoint framePoint = CGPointZero;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) {
        MacWSLog(@"interop-paste-route skipped reason=point view=(%.1f,%.1f) "
            "bounds=(%.1f,%.1f %.1fx%.1f) content=(%.1f,%.1f %.1fx%.1f)",
            viewPoint.x, viewPoint.y, self.bounds.origin.x,
            self.bounds.origin.y, self.bounds.size.width,
            self.bounds.size.height, _contentRect.origin.x,
            _contentRect.origin.y, _contentRect.size.width,
            _contentRect.size.height);
        return;
    }
    MacWSLog(@"interop-paste-route emit target=%d window=%u view=(%.1f,%.1f) frame=(%.1f,%.1f)",
        self.targetPID, self.targetWindowID, viewPoint.x, viewPoint.y,
        framePoint.x, framePoint.y);
    uint32_t contactID = 0x50535400u |
        ((++_directTouchSerial) & 0xffu); // "PST"
    NSTimeInterval now = CACurrentMediaTime();
    [self emitKind:MacWSInputKindTouchDown framePoint:framePoint pressure:1.0f
         contactID:contactID timestamp:now];
    [self emitKind:MacWSInputKindTouchUp framePoint:framePoint pressure:0.0f
         contactID:contactID timestamp:now + 0.001];
    _trackpadCursor = framePoint;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (width != 0 && height != 0) {
            self->_lastKeyboardFrameWidth = width;
            self->_lastKeyboardFrameHeight = height;
        } else {
            width = self->_lastKeyboardFrameWidth;
            height = self->_lastKeyboardFrameHeight;
        }
        if (width == 0 || height == 0) return;
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = MacWSInputKindPerformPaste,
            .sceneID = [self inputSceneIDWithModifiers:0],
            .timestamp = CACurrentMediaTime(),
            .x = (float)framePoint.x,
            .y = (float)framePoint.y,
            .frameWidth = width,
            .frameHeight = height,
            .targetPID = self.targetPID,
            .source = MacWSInputSourceSoftwareKeyboard,
            .sampleSequence = ++self->_inputSampleSequence,
        };
        [self.statusDelegate metalView:self emittedInput:record];
    });
}

- (void)emitKind:(MacWSInputKind)kind
           touch:(UITouch *)touch
           point:(CGPoint)viewPoint
      extraFlags:(uint16_t)extraFlags {
    if (touch.type == UITouchTypePencil)
        viewPoint = [touch preciseLocationInView:self];
    CGPoint framePoint;
    BOOL pointerContinuation = kind == MacWSInputKindTouchMove ||
        kind == MacWSInputKindTouchUp ||
        kind == MacWSInputKindTouchCancel;
    if (![self framePointForViewPoint:viewPoint output:&framePoint
                   clampContinuationToContent:pointerContinuation]) return;
    float pressure = touch.maximumPossibleForce > 0
        ? touch.force / touch.maximumPossibleForce : 0.0f;
    MacWSInputSource source = MacWSInputSourceFinger;
    if (touch.type == UITouchTypePencil)
        source = MacWSInputSourcePencil;
    else if (touch.type == UITouchTypeIndirectPointer)
        source = MacWSInputSourceIndirectPointer;
    float altitude = 0.0f;
    float azimuth = 0.0f;
    float tiltX = 0.0f;
    float tiltY = 0.0f;
    uint16_t inputFlags = 0;
    if (source == MacWSInputSourcePencil) {
        altitude = (float)touch.altitudeAngle;
        azimuth = (float)[touch azimuthAngleInView:self];
        float tiltMagnitude = fmaxf(0.0f, fminf(1.0f, cosf(altitude)));
        tiltX = tiltMagnitude * cosf(azimuth);
        tiltY = tiltMagnitude * sinf(azimuth);
        inputFlags |= MacWSInputFlagPreciseLocation;
    }
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = kind,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = touch.timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = pressure,
        .contactID = (uint32_t)touch.hash,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = source,
        .flags = inputFlags | extraFlags,
        .altitude = altitude,
        .azimuth = azimuth,
        .tiltX = tiltX,
        .tiltY = tiltY,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
    if (source == MacWSInputSourceFinger &&
        self.inputMode == MacWSHostInputModeDirect) {
        _directTouchIndicator.center = viewPoint;
        _directTouchIndicator.hidden = kind == MacWSInputKindTouchUp ||
                                       kind == MacWSInputKindTouchCancel;
        if (!_directTouchIndicator.hidden)
            [self bringSubviewToFront:_directTouchIndicator];
    }
}

- (void)emitKind:(MacWSInputKind)kind touch:(UITouch *)touch point:(CGPoint)viewPoint {
    [self emitKind:kind touch:touch point:viewPoint extraFlags:0];
}

- (void)emitTouches:(NSSet<UITouch *> *)touches kind:(MacWSInputKind)kind {
    for (UITouch *touch in touches)
        [self emitKind:kind touch:touch point:[touch locationInView:self]];
}

- (void)flushPendingPointerDownForTouch:(UITouch *)touch {
    if (!touch || touch != _pendingPointerDoubleTouch) return;
    _pendingPointerDoubleTouch = nil;
    [self emitKind:MacWSInputKindTouchDown touch:touch
           point:_primaryPointerStartPoint];
    _primaryPointerDownEmitted = YES;
}

- (void)emitPencilHoverForTouch:(UITouch *)touch point:(CGPoint)viewPoint {
    if (!touch) return;
    viewPoint = [touch preciseLocationInView:self];
    [self emitKind:MacWSInputKindHover touch:touch point:viewPoint];
    _pencilCursorView.center = viewPoint;
    _pencilCursorView.hidden = NO;
    [self bringSubviewToFront:_pencilCursorView];
}

- (void)cancelDirectTouchForMultitouch {
    _directTouchSerial++;
    if (_directTouch && _directTouchState == MacWSDirectTouchStateDragging) {
        [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                 point:[_directTouch locationInView:self]];
    } else if (_directTouch &&
               _directTouchState == MacWSDirectTouchStateScrolling) {
        [self emitScrollAtFramePoint:_directScrollFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollCancelled
                           timestamp:CACurrentMediaTime()];
    }
    _directTouch = nil;
    _directTouchState = MacWSDirectTouchStateIdle;
    _directScrollAxis = MacWSDirectScrollAxisNone;
    [self setDirectTouchHeld:NO dragging:NO animated:NO];
    _directTouchIndicator.hidden = YES;
}

- (void)setCrossAppDragModeEnabled:(BOOL)enabled {
    if (_crossAppDragModeEnabled == enabled) return;
    _crossAppDragModeEnabled = enabled;
    if (enabled) [self cancelDirectTouchForMultitouch];
    MacWSLog(@"interop-drag-arbitration window=%u pid=%d cross-app=%@",
        self.targetWindowID, self.targetPID, enabled ? @"YES" : @"NO");
}

- (BOOL)crossAppDragModeEnabled {
    return _crossAppDragModeEnabled;
}

- (void)beginDirectTouchCandidate:(UITouch *)touch {
    _directTouch = touch;
    _directTouchState = MacWSDirectTouchStateCandidate;
    _directTouchStartPoint = [touch locationInView:self];
    _directTouchPreviousPoint = _directTouchStartPoint;
    _directScrollVelocity = CGPointZero;
    _directScrollFramePoint = CGPointZero;
    _directScrollAxis = MacWSDirectScrollAxisNone;
    _directTouchStartTimestamp = touch.timestamp;
    _directTouchPreviousTimestamp = touch.timestamp;
    // A real finger now owns the interaction transaction. Any delayed
    // ConfigureWindow settlement from Scene creation would otherwise re-anchor
    // the AppKit window underneath a native title-bar drag. A subsequent UIKit
    // geometry change cancels this touch in geometryDidChange and starts its own
    // fresh configuration transaction.
    _windowConfigurationSettlementSerial++;
    _windowConfigurationAwaitingAcknowledgement = NO;
    _windowConfigurationRequestSequence = 0;
    uint64_t serial = ++_directTouchSerial;
    [_directTouchFeedback prepare];
    _directTouchIndicator.center = _directTouchStartPoint;
    [self setDirectTouchHeld:NO dragging:NO animated:NO];
    _directTouchIndicator.hidden = NO;
    [self bringSubviewToFront:_directTouchIndicator];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(MACWS_DIRECT_LONG_PRESS_SECONDS * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (serial != self->_directTouchSerial ||
            self->_directTouch != touch ||
            self->_directTouchState != MacWSDirectTouchStateCandidate)
            return;
        CGPoint point = [touch locationInView:self];
        double travel = hypot(point.x - self->_directTouchStartPoint.x,
                              point.y - self->_directTouchStartPoint.y);
        if (MacWSDecideTouchCandidate(MACWS_DIRECT_LONG_PRESS_SECONDS,
                                      travel, false) !=
            MacWSTouchCandidateDecisionLongPress)
            return;
        // Holding only arms a primary-button drag.  Sending right-click here
        // made it structurally impossible to drag after the long press.  If
        // the armed finger is released without moving, release handling keeps
        // the useful long-press-as-context-menu behavior.
        self->_directTouchState = MacWSDirectTouchStateLongPressArmed;
        [self setDirectTouchHeld:YES dragging:NO animated:YES];
        [self->_directTouchFeedback impactOccurred];
        [self publishStatus:@"已进入拖动状态 · 滑动即可拖动"];
    });
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // A new physical contact supersedes deceleration at the OLD scroll point.
    // Close that stream before focus/routing or any finger, pointer or Pencil
    // contact is emitted. Waiting for a new scroll threshold leaves a simple
    // outside tap interleaved with the previous gesture's momentum tail.
    if (touches.count != 0)
        [self stopScrollMomentumWithTerminalPhase:YES];
    // The hidden UITextField owns the software keyboard. Taking first
    // responder here used to dismiss it on the very first touch inside the
    // macOS surface. Hardware-key focus remains on the Metal view whenever
    // the software keyboard is not intentionally active.
    [self restoreHardwareKeyboardFocusWithReason:@"pointer-down"];
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (touch.type == UITouchTypePencil) {
        _pencilTouch = touch;
        _pencilHoverActive = NO;
        _pencilTouchStartPoint = [touch preciseLocationInView:self];
        _pencilTouchTravel = 0;
        _pencilTouchBeganAt = touch.timestamp;
        // Pencil contact is a real tablet-button lifecycle, not a hovering
        // preview. Runtime A/B with Amadine's Rectangle tool confirmed that
        // the old Hover-only route could select the tool but could not create
        // a Path layer, while this down/move/up route with tablet metadata
        // created a visible rectangle and Path layer. Preserve UIKit's
        // precise point, pressure, altitude and azimuth; the separate
        // UIHoverGestureRecognizer remains the non-contact route.
        [self emitKind:MacWSInputKindTouchDown touch:touch
                 point:_pencilTouchStartPoint];
        _pencilCursorView.center = _pencilTouchStartPoint;
        _pencilCursorView.hidden = NO;
        [self bringSubviewToFront:_pencilCursorView];
    } else if (pointerTouch) {
        if (@available(iOS 13.4, *)) {
            // buttonMask is the complete current button state.  A primary
            // transition can briefly coexist with a stale secondary bit after
            // scene/focus handoff; never reinterpret that primary transition
            // as a right click.  A genuine secondary click has Secondary set
            // without Primary.
            BOOL primaryButton =
                (event.buttonMask & UIEventButtonMaskPrimary) != 0;
            BOOL secondaryButton =
                (event.buttonMask & UIEventButtonMaskSecondary) != 0;
            if (secondaryButton && !primaryButton) {
                _secondaryPointerTouch = touch;
                _lastPointerTapTimestamp = 0.0;
                [self emitKind:MacWSInputKindSecondaryTap touch:touch
                         point:[touch locationInView:self]];
            } else {
                CGPoint point = [touch locationInView:self];
                _primaryPointerTouch = touch;
                _primaryPointerStartPoint = point;
                _primaryPointerStartTimestamp = touch.timestamp;
                _primaryPointerTravel = 0.0;
                _primaryPointerDownEmitted = NO;
                BOOL secondClick =
                    _lastPointerTapPID == self.targetPID &&
                    _lastPointerTapWindowID == self.targetWindowID &&
                    MacWSIsPointerDoubleClick(
                        _lastPointerTapTimestamp, touch.timestamp,
                        point.x - _lastPointerTapPoint.x,
                        point.y - _lastPointerTapPoint.y);
                if (MacWSHostTouchDiagnosticsEnabled())
                    MacWSLog(@"pointer-click began pid=%d window=%u contact=%u second=%d tapCount=%lu point=(%.1f,%.1f)",
                        self.targetPID, self.targetWindowID,
                        (uint32_t)touch.hash, secondClick,
                        (unsigned long)touch.tapCount, point.x, point.y);
                _lastPointerTapTimestamp = 0.0;
                if (secondClick) {
                    // The first click has already reached AppKit. Hold only
                    // this stationary second press until its release so the
                    // proven native double-click route receives one Tap with
                    // clickCount=2, not an extra ordinary down/up pair.
                    // Movement flushes the original down, keeping pointer
                    // dragging intact. Do not use a wall-clock timer here:
                    // it can overtake an already-recorded touch-up when the
                    // UIKit main queue is busy presenting a surface.
                    _pendingPointerDoubleTouch = touch;
                } else {
                    [self emitKind:MacWSInputKindTouchDown touch:touch
                           point:point];
                    _primaryPointerDownEmitted = YES;
                }
            }
        } else {
            _primaryPointerTouch = touch;
            _primaryPointerStartPoint = [touch locationInView:self];
            _primaryPointerStartTimestamp = touch.timestamp;
            _primaryPointerTravel = 0.0;
            _primaryPointerDownEmitted = YES;
            [self emitTouches:touches kind:MacWSInputKindTouchDown];
        }
    } else if (_crossAppDragModeEnabled) {
        // UIDragInteraction owns this one explicitly armed contact. Starting
        // MacWS's direct-touch candidate here would race the same long press
        // into a context click or an AppKit-internal drag.
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (event.allTouches.count > 1) {
            [self cancelDirectTouchForMultitouch];
            _directGestureBlocked = YES;
        } else if (!_directGestureBlocked && !_directTouch && touch) {
            [self beginDirectTouchCandidate:touch];
            if (MacWSHostDiagnosticsEnabled() ||
                MacWSHostTouchDiagnosticsEnabled()) {
                CGPoint point = [touch locationInView:self];
                MacWSLog(@"direct-touch lifecycle=began window=%u contact=%u point=(%.1f,%.1f) recognizers=%@",
                    self.targetWindowID, (uint32_t)touch.hash,
                    point.x, point.y,
                    [self.gestureRecognizers valueForKey:@"state"]);
            }
            if (_directTouchUsesPrimaryDrag) {
                // Spatial canvases map one finger to the native primary-drag
                // lifecycle immediately. Waiting for MacWS's document-scroll
                // threshold would first emit a scroll wheel, which Maps
                // correctly interprets as zoom and cannot later reinterpret
                // as a pan. The existing Dragging move/up/cancel path retains
                // AppKit's synchronous control tracking and two-finger input
                // still cancels this contact before magnification begins.
                _directTouchState = MacWSDirectTouchStateDragging;
                [self setDirectTouchHeld:YES dragging:YES animated:YES];
                [self emitKind:MacWSInputKindTouchDown touch:touch
                         point:_directTouchStartPoint];
            }
        }
    } else if (!_trackpadTouch && touch) {
        _trackpadTouch = touch;
        _trackpadCursorWasTouched = YES;
        _externalPointerHoverActive = NO;
        _trackpadPreviousPoint = [touch locationInView:self];
        _trackpadTravel = 0;
        _trackpadBeganAt = touch.timestamp;
        _trackpadHadMultipleTouches = event.allTouches.count > 1;
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (_trackpadCursor.x < 0 || _trackpadCursor.y < 0 ||
            _trackpadCursor.x >= width || _trackpadCursor.y >= height) {
            _trackpadCursor = CGPointMake(width * 0.5, height * 0.5);
        }
        [self updatePointerVisibility];
        uint32_t contactID = (uint32_t)touch.hash;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (self->_trackpadTouch == touch &&
                self->_trackpadTravel < 6.0 &&
                !self->_trackpadHadMultipleTouches &&
                !self->_trackpadButtonDown) {
                self->_trackpadButtonDown = YES;
                [self setTrackpadPointerPressed:YES animated:YES];
                [self emitKind:MacWSInputKindTouchDown
                     framePoint:self->_trackpadCursor pressure:1.0f
                      contactID:contactID timestamp:CACurrentMediaTime()];
            }
        });
    } else if (event.allTouches.count > 1) {
        _trackpadHadMultipleTouches = YES;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (_pencilTouch && [touches containsObject:_pencilTouch]) {
        CGPoint point = [_pencilTouch preciseLocationInView:self];
        _pencilTouchTravel = MAX(_pencilTouchTravel,
            hypot(point.x - _pencilTouchStartPoint.x,
                  point.y - _pencilTouchStartPoint.y));
        [self emitKind:MacWSInputKindTouchMove touch:_pencilTouch point:point];
        _pencilCursorView.center = point;
        _pencilCursorView.hidden = NO;
        [self bringSubviewToFront:_pencilCursorView];
    } else if (pointerTouch) {
        if (touch != _secondaryPointerTouch) {
            BOOL suppressStationarySecondClickMove = NO;
            if (touch == _primaryPointerTouch) {
                CGPoint point = [touch locationInView:self];
                _primaryPointerTravel = MAX(_primaryPointerTravel,
                    hypot(point.x - _primaryPointerStartPoint.x,
                          point.y - _primaryPointerStartPoint.y));
                if (_pendingPointerDoubleTouch == touch) {
                    if (_primaryPointerTravel <
                        MACWS_POINTER_CLICK_TRAVEL_POINTS)
                        suppressStationarySecondClickMove = YES;
                    else
                        [self flushPendingPointerDownForTouch:touch];
                }
            }
            if (!suppressStationarySecondClickMove)
                [self emitTouches:touches kind:MacWSInputKindTouchMove];
        }
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            CGPoint point = [_directTouch locationInView:self];
            CGFloat travel = hypot(point.x - _directTouchStartPoint.x,
                                   point.y - _directTouchStartPoint.y);
            NSTimeInterval elapsed =
                _directTouch.timestamp - _directTouchStartTimestamp;
            // dispatch_after can run before an already-recorded UIKit move
            // when the main queue was stalled.  Its LongPressArmed state is
            // provisional; the touch hardware timestamp is authoritative.
            if (_directTouchState == MacWSDirectTouchStateLongPressArmed &&
                !MacWSTouchReachedLongPress(elapsed)) {
                _directTouchState = MacWSDirectTouchStateCandidate;
                [self setDirectTouchHeld:NO dragging:NO animated:YES];
            }
            MacWSTouchCandidateDecision decision =
                MacWSDecideTouchCandidate(
                    elapsed, travel, false);
            if (_directTouchState == MacWSDirectTouchStateCandidate &&
                decision == MacWSTouchCandidateDecisionScroll) {
                _directTouchSerial++;
                _directTouchState = MacWSDirectTouchStateScrolling;
                [self setDirectTouchHeld:NO dragging:NO animated:YES];
                _directScrollAxis = MacWSChooseDirectScrollAxis(
                    point.x - _directTouchStartPoint.x,
                    point.y - _directTouchStartPoint.y);
                [self stopScrollMomentumWithTerminalPhase:YES];
                CGPoint framePoint = CGPointZero;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    _directScrollFramePoint = framePoint;
                    [self emitScrollAtFramePoint:framePoint
                                     translation:CGPointZero
                                           flags:MacWSInputFlagScrollBegan
                                       timestamp:_directTouch.timestamp];
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    double deltaX = delta.x, deltaY = delta.y;
                    MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                    &deltaX, &deltaY);
                    delta = CGPointMake(deltaX, deltaY);
                    [self emitScrollAtFramePoint:framePoint translation:delta
                                           flags:MacWSInputFlagScrollChanged
                                       timestamp:_directTouch.timestamp];
                    NSTimeInterval dt = MAX(_directTouch.timestamp -
                        _directTouchPreviousTimestamp, 1.0 / 240.0);
                    _directScrollVelocity = CGPointMake(delta.x / dt,
                                                        delta.y / dt);
                }
                _directTouchPreviousPoint = point;
                _directTouchPreviousTimestamp = _directTouch.timestamp;
            } else if (_directTouchState ==
                           MacWSDirectTouchStateCandidate &&
                       decision == MacWSTouchCandidateDecisionLongPress) {
                _directTouchSerial++;
                _directTouchState = MacWSDirectTouchStateLongPressArmed;
                [self setDirectTouchHeld:YES dragging:NO animated:YES];
                [_directTouchFeedback impactOccurred];
                if (MacWSHostDiagnosticsEnabled() ||
                    MacWSHostTouchDiagnosticsEnabled()) {
                    MacWSLog(@"direct-touch lifecycle=armed-by-hardware-time window=%u contact=%u elapsed=%.3f travel=%.1f",
                        self.targetWindowID, (uint32_t)_directTouch.hash,
                        elapsed, travel);
                }
            } else if (_directTouchState ==
                           MacWSDirectTouchStateLongPressArmed &&
                       travel >= MACWS_DIRECT_GESTURE_THRESHOLD_POINTS) {
                _directTouchState = MacWSDirectTouchStateDragging;
                [self setDirectTouchHeld:YES dragging:YES animated:YES];
                CGPoint startFrame = CGPointZero;
                if ([self framePointForViewPoint:_directTouchStartPoint
                                          output:&startFrame]) {
                    [self emitKind:MacWSInputKindTouchDown
                        framePoint:startFrame pressure:1.0f
                         contactID:(uint32_t)_directTouch.hash
                          timestamp:_directTouchStartTimestamp];
                }
                [self emitKind:MacWSInputKindTouchMove touch:_directTouch
                         point:point];
                if (MacWSHostDiagnosticsEnabled() ||
                    MacWSHostTouchDiagnosticsEnabled()) {
                    MacWSLog(@"direct-touch lifecycle=dragging window=%u contact=%u elapsed=%.3f travel=%.1f",
                        self.targetWindowID, (uint32_t)_directTouch.hash,
                        elapsed, travel);
                }
            } else if (_directTouchState == MacWSDirectTouchStateScrolling) {
                CGPoint framePoint = CGPointZero;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    double deltaX = delta.x, deltaY = delta.y;
                    MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                    &deltaX, &deltaY);
                    delta = CGPointMake(deltaX, deltaY);
                    if (delta.x != 0 || delta.y != 0) {
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchPreviousTimestamp, 1.0 / 240.0);
                        CGPoint instant = CGPointMake(delta.x / dt,
                                                       delta.y / dt);
                        _directScrollVelocity.x =
                            _directScrollVelocity.x * 0.72 + instant.x * 0.28;
                        _directScrollVelocity.y =
                            _directScrollVelocity.y * 0.72 + instant.y * 0.28;
                    }
                    _directScrollFramePoint = framePoint;
                }
                _directTouchPreviousPoint = point;
                _directTouchPreviousTimestamp = _directTouch.timestamp;
            } else if (_directTouchState == MacWSDirectTouchStateDragging) {
                [self emitKind:MacWSInputKindTouchMove touch:_directTouch
                         point:point];
            }
            _directTouchIndicator.center = point;
        }
    } else if (_trackpadTouch && [touches containsObject:_trackpadTouch]) {
        if (event.allTouches.count > 1) _trackpadHadMultipleTouches = YES;
        CGPoint point = [_trackpadTouch locationInView:self];
        CGFloat dx = point.x - _trackpadPreviousPoint.x;
        CGFloat dy = point.y - _trackpadPreviousPoint.y;
        _trackpadPreviousPoint = point;
        _trackpadTravel += hypot(dx, dy);
        // The two-finger pan recognizer intentionally does not cancel raw
        // touches. Once a gesture becomes multi-touch, keep its translation
        // exclusively on the scroll route so scrolling cannot also move or
        // drag the macOS pointer.
        if (!_trackpadHadMultipleTouches) {
            CGFloat scaleX = CGRectGetWidth(_contentRect) > 0
                ? [self currentFrameWidth] / CGRectGetWidth(_contentRect) : 1.0;
            CGFloat scaleY = CGRectGetHeight(_contentRect) > 0
                ? [self currentFrameHeight] / CGRectGetHeight(_contentRect) : 1.0;
            _trackpadCursor.x = fmin(fmax(_trackpadCursor.x + dx * scaleX * 1.25,
                                          0.0), [self currentFrameWidth] - 1.0);
            _trackpadCursor.y = fmin(fmax(_trackpadCursor.y + dy * scaleY * 1.25,
                                          0.0), [self currentFrameHeight] - 1.0);
            [self emitKind:_trackpadButtonDown ? MacWSInputKindTouchMove
                                                : MacWSInputKindHover
                 framePoint:_trackpadCursor pressure:_trackpadButtonDown ? 1.0f : 0.0f
                  contactID:(uint32_t)_trackpadTouch.hash
                   timestamp:_trackpadTouch.timestamp];
            CGFloat sourceX = _trackpadCursor.x /
                MAX([self currentFrameWidth] - 1, 1u);
            CGFloat sourceY = _trackpadCursor.y /
                MAX([self currentFrameHeight] - 1, 1u);
            CGPoint previousViewportCenter = _viewportCenter;
            if (sourceX < CGRectGetMinX(_visibleSourceRect))
                _viewportCenter.x -= CGRectGetMinX(_visibleSourceRect) - sourceX;
            else if (sourceX > CGRectGetMaxX(_visibleSourceRect))
                _viewportCenter.x += sourceX - CGRectGetMaxX(_visibleSourceRect);
            if (sourceY < CGRectGetMinY(_visibleSourceRect))
                _viewportCenter.y -= CGRectGetMinY(_visibleSourceRect) - sourceY;
            else if (sourceY > CGRectGetMaxY(_visibleSourceRect))
                _viewportCenter.y += sourceY - CGRectGetMaxY(_visibleSourceRect);
            simd_float4 unusedVertices[4];
            [self updateContentRectAndVertices:unusedVertices];
            [self updatePointerVisibility];
            // The pointer is a native UIKit subview. At 1x, moving it must not
            // re-present an unchanged multi-megabyte macOS IOSurface; redraw
            // Metal only if a zoomed viewport was actually panned.
            if (fabs(previousViewportCenter.x - _viewportCenter.x) > 0.00001 ||
                fabs(previousViewportCenter.y - _viewportCenter.y) > 0.00001)
                [self setNeedsDisplay];
        }
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (_pencilTouch && [touches containsObject:_pencilTouch]) {
        CGPoint point = [_pencilTouch preciseLocationInView:self];
        _pencilTouchTravel = MAX(_pencilTouchTravel,
            hypot(point.x - _pencilTouchStartPoint.x,
                  point.y - _pencilTouchStartPoint.y));
        [self emitKind:MacWSInputKindTouchUp touch:_pencilTouch point:point];
        _pencilTouch = nil;
        _pencilCursorView.hidden = !_pencilHoverActive;
    } else if (pointerTouch) {
        if (touch == _secondaryPointerTouch)
            _secondaryPointerTouch = nil;
        else if (touch == _primaryPointerTouch) {
            CGPoint point = [touch locationInView:self];
            _primaryPointerTravel = MAX(_primaryPointerTravel,
                hypot(point.x - _primaryPointerStartPoint.x,
                      point.y - _primaryPointerStartPoint.y));
            BOOL shortClick = MacWSIsPointerClick(
                touch.timestamp - _primaryPointerStartTimestamp,
                _primaryPointerTravel);
            BOOL doubleClick = _pendingPointerDoubleTouch == touch &&
                shortClick && self.targetPID == _lastPointerTapPID &&
                self.targetWindowID == _lastPointerTapWindowID;
            if (MacWSHostTouchDiagnosticsEnabled())
                MacWSLog(@"pointer-click ended pid=%d window=%u contact=%u short=%d double=%d down=%d elapsed=%.3f travel=%.1f",
                    self.targetPID, self.targetWindowID,
                    (uint32_t)touch.hash, shortClick, doubleClick,
                    _primaryPointerDownEmitted,
                    touch.timestamp - _primaryPointerStartTimestamp,
                    _primaryPointerTravel);
            if (doubleClick) {
                _pendingPointerDoubleTouch = nil;
                [self emitKind:MacWSInputKindTap touch:touch point:point
                    extraFlags:MacWSInputFlagDoubleClick];
            } else {
                [self flushPendingPointerDownForTouch:touch];
                if (_primaryPointerDownEmitted)
                    [self emitKind:MacWSInputKindTouchUp touch:touch
                           point:point];
                if (shortClick) {
                    _lastPointerTapTimestamp = touch.timestamp;
                    _lastPointerTapPoint = point;
                    _lastPointerTapPID = self.targetPID;
                    _lastPointerTapWindowID = self.targetWindowID;
                } else {
                    _lastPointerTapTimestamp = 0.0;
                }
            }
            _primaryPointerTouch = nil;
            _primaryPointerDownEmitted = NO;
        } else {
            [self emitTouches:touches kind:MacWSInputKindTouchUp];
        }
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            if (MacWSHostDiagnosticsEnabled() ||
                MacWSHostTouchDiagnosticsEnabled()) {
                MacWSLog(@"direct-touch lifecycle=ended window=%u contact=%u state=%u recognizers=%@",
                    self.targetWindowID, (uint32_t)_directTouch.hash,
                    (unsigned)_directTouchState,
                    [self.gestureRecognizers valueForKey:@"state"]);
            }
            CGPoint point = [_directTouch locationInView:self];
            NSTimeInterval elapsed =
                _directTouch.timestamp - _directTouchStartTimestamp;
            // The long-press timer is deliberately not authoritative.  If a
            // short tap's touch-up was queued behind that timer during a main
            // thread stall, restore Candidate so the normal tap/scroll policy
            // below classifies it from the real hardware duration.
            if (_directTouchState == MacWSDirectTouchStateLongPressArmed &&
                !MacWSTouchReachedLongPress(elapsed)) {
                _directTouchState = MacWSDirectTouchStateCandidate;
                [self setDirectTouchHeld:NO dragging:NO animated:YES];
            }
            if (_directTouchState == MacWSDirectTouchStateCandidate) {
                MacWSTouchCandidateDecision decision = MacWSDecideTouchCandidate(
                    elapsed,
                    hypot(point.x - _directTouchStartPoint.x,
                          point.y - _directTouchStartPoint.y), true);
                if (decision == MacWSTouchCandidateDecisionLongPress) {
                    [self emitKind:MacWSInputKindSecondaryTap
                             touch:_directTouch point:point];
                    [_directTouchFeedback impactOccurred];
                } else if (decision == MacWSTouchCandidateDecisionTap) {
                    // Report the already-classified physical tap directly.
                    // A second one-finger UITapGestureRecognizer used only to
                    // remember this point stayed Possible throughout a long
                    // press and participated in UIKit arbitration before the
                    // raw touch could become an AppKit file drag.
                    [self.statusDelegate metalView:self
                        completedDirectTapAtViewPoint:point];
                    BOOL doubleTap = _directTouch.tapCount >= 2 ||
                        MacWSIsDirectDoubleTap(
                            _lastDirectTapTimestamp, _directTouch.timestamp,
                            point.x - _lastDirectTapPoint.x,
                            point.y - _lastDirectTapPoint.y);
                    if (doubleTap) {
                        _lastDirectTapTimestamp = 0.0;
                    } else {
                        _lastDirectTapTimestamp = _directTouch.timestamp;
                        _lastDirectTapPoint = point;
                    }
                    [self emitKind:MacWSInputKindTap
                             touch:_directTouch point:point
                        extraFlags:doubleTap
                            ? MacWSInputFlagDoubleClick : 0];
                } else if (decision == MacWSTouchCandidateDecisionScroll) {
                    _lastDirectTapTimestamp = 0.0;
                    // Preserve a quick flick even when UIKit coalesces it to a
                    // final sample; movement in direct mode is scrolling, not
                    // an implicit primary-button drag.
                    CGPoint framePoint = CGPointZero;
                    if ([self framePointForViewPoint:point output:&framePoint]) {
                        CGPoint delta = CGPointMake(
                            point.x - _directTouchStartPoint.x,
                            point.y - _directTouchStartPoint.y);
                        _directScrollAxis = MacWSChooseDirectScrollAxis(
                            delta.x, delta.y);
                        double deltaX = delta.x, deltaY = delta.y;
                        MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                        &deltaX, &deltaY);
                        delta = CGPointMake(deltaX, deltaY);
                        [self emitScrollAtFramePoint:framePoint
                                         translation:CGPointZero
                                               flags:MacWSInputFlagScrollBegan
                                           timestamp:_directTouchStartTimestamp];
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchStartTimestamp, 1.0 / 120.0);
                        CGPoint velocity = CGPointMake(delta.x / dt,
                                                       delta.y / dt);
                        uint16_t endedFlags = MacWSInputFlagScrollEnded;
                        if (MacWSShouldStartScrollMomentum(
                                velocity.x, velocity.y))
                            endedFlags |= MacWSInputFlagScrollWillMomentum;
                        [self emitScrollAtFramePoint:framePoint
                                         translation:CGPointZero
                                               flags:endedFlags
                                           timestamp:_directTouch.timestamp];
                        [self startScrollMomentumWithVelocity:velocity
                                                   framePoint:framePoint];
                    }
                }
            } else if (_directTouchState ==
                       MacWSDirectTouchStateLongPressArmed) {
                _lastDirectTapTimestamp = 0.0;
                CGFloat armedTravel = hypot(
                    point.x - _directTouchStartPoint.x,
                    point.y - _directTouchStartPoint.y);
                if (armedTravel >= MACWS_DIRECT_GESTURE_THRESHOLD_POINTS) {
                    // Preserve hold-then-drag if UIKit coalesces the threshold
                    // crossing into the terminal touch sample.
                    CGPoint startFrame = CGPointZero;
                    if ([self framePointForViewPoint:_directTouchStartPoint
                                              output:&startFrame]) {
                        [self emitKind:MacWSInputKindTouchDown
                            framePoint:startFrame pressure:1.0f
                             contactID:(uint32_t)_directTouch.hash
                              timestamp:_directTouchStartTimestamp];
                        [self emitKind:MacWSInputKindTouchMove
                                 touch:_directTouch point:point];
                        [self emitKind:MacWSInputKindTouchUp
                                 touch:_directTouch point:point];
                    }
                } else {
                    [self emitKind:MacWSInputKindSecondaryTap
                             touch:_directTouch point:point];
                }
            } else if (_directTouchState ==
                       MacWSDirectTouchStateDragging) {
                _lastDirectTapTimestamp = 0.0;
                [self emitKind:MacWSInputKindTouchUp touch:_directTouch
                         point:point];
            } else if (_directTouchState ==
                       MacWSDirectTouchStateScrolling) {
                _lastDirectTapTimestamp = 0.0;
                CGPoint framePoint = _directScrollFramePoint;
                if ([self framePointForViewPoint:point output:&framePoint]) {
                    CGPoint delta = CGPointMake(
                        point.x - _directTouchPreviousPoint.x,
                        point.y - _directTouchPreviousPoint.y);
                    double deltaX = delta.x, deltaY = delta.y;
                    MacWSConstrainDirectScrollDelta(_directScrollAxis,
                                                    &deltaX, &deltaY);
                    delta = CGPointMake(deltaX, deltaY);
                    if (delta.x != 0 || delta.y != 0) {
                        [self emitScrollAtFramePoint:framePoint translation:delta
                                               flags:MacWSInputFlagScrollChanged
                                           timestamp:_directTouch.timestamp];
                        NSTimeInterval dt = MAX(_directTouch.timestamp -
                            _directTouchPreviousTimestamp, 1.0 / 240.0);
                        CGPoint instant = CGPointMake(delta.x / dt,
                                                       delta.y / dt);
                        // Include the final hardware segment in release
                        // velocity. Omitting it made a short iOS-style flick
                        // inherit an older, often sub-threshold sample and
                        // silently skip the momentum phase.
                        _directScrollVelocity.x =
                            _directScrollVelocity.x * 0.55 + instant.x * 0.45;
                        _directScrollVelocity.y =
                            _directScrollVelocity.y * 0.55 + instant.y * 0.45;
                    }
                    _directScrollFramePoint = framePoint;
                }
                uint16_t endedFlags = MacWSInputFlagScrollEnded;
                if (MacWSShouldStartScrollMomentum(
                        _directScrollVelocity.x, _directScrollVelocity.y))
                    endedFlags |= MacWSInputFlagScrollWillMomentum;
                [self emitScrollAtFramePoint:_directScrollFramePoint
                                 translation:CGPointZero
                                       flags:endedFlags
                                   timestamp:_directTouch.timestamp];
                [self startScrollMomentumWithVelocity:_directScrollVelocity
                                           framePoint:_directScrollFramePoint];
            }
            _directTouchSerial++;
            _directTouch = nil;
            _directTouchState = MacWSDirectTouchStateIdle;
            _directScrollAxis = MacWSDirectScrollAxisNone;
            [self setDirectTouchHeld:NO dragging:NO animated:NO];
            _directTouchIndicator.hidden = YES;
        }
        if (event.allTouches.count <= touches.count)
            _directGestureBlocked = NO;
    } else if (_trackpadTouch && [touches containsObject:_trackpadTouch]) {
        MacWSInputKind kind = _trackpadButtonDown ? MacWSInputKindTouchUp
            : MacWSInputKindTap;
        if (_trackpadButtonDown ||
            (!_trackpadHadMultipleTouches && _trackpadTravel < 10.0 &&
             touch.timestamp - _trackpadBeganAt < 0.40)) {
            [self emitKind:kind framePoint:_trackpadCursor pressure:0
                  contactID:(uint32_t)_trackpadTouch.hash
                   timestamp:touch.timestamp];
        }
        _trackpadTouch = nil;
        _trackpadButtonDown = NO;
        _trackpadHadMultipleTouches = NO;
        [self setTrackpadPointerPressed:NO animated:YES];
        [self updatePointerVisibility];
    }
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    BOOL pointerTouch = touch.type == UITouchTypeIndirectPointer;
    if (_pencilTouch && [touches containsObject:_pencilTouch]) {
        [self emitKind:MacWSInputKindTouchCancel touch:_pencilTouch
                 point:[_pencilTouch preciseLocationInView:self]];
        _pencilTouch = nil;
        _pencilCursorView.hidden = !_pencilHoverActive;
    } else if (pointerTouch) {
        if (touch == _secondaryPointerTouch)
            _secondaryPointerTouch = nil;
        else if (touch == _primaryPointerTouch) {
            if (_pendingPointerDoubleTouch == touch) {
                _pendingPointerDoubleTouch = nil;
            } else if (_primaryPointerDownEmitted) {
                [self emitKind:MacWSInputKindTouchCancel touch:touch
                       point:[touch locationInView:self]];
            }
            _primaryPointerTouch = nil;
            _primaryPointerDownEmitted = NO;
            _lastPointerTapTimestamp = 0.0;
        } else {
            [self emitTouches:touches kind:MacWSInputKindTouchCancel];
        }
    } else if (self.inputMode == MacWSHostInputModeDirect) {
        if (_directTouch && [touches containsObject:_directTouch]) {
            if (MacWSHostDiagnosticsEnabled() ||
                MacWSHostTouchDiagnosticsEnabled()) {
                MacWSLog(@"direct-touch lifecycle=cancelled window=%u contact=%u state=%u recognizers=%@",
                    self.targetWindowID, (uint32_t)_directTouch.hash,
                    (unsigned)_directTouchState,
                    [self.gestureRecognizers valueForKey:@"state"]);
            }
            if (_directTouchState == MacWSDirectTouchStateDragging) {
                [self emitKind:MacWSInputKindTouchCancel touch:_directTouch
                         point:[_directTouch locationInView:self]];
            } else if (_directTouchState ==
                       MacWSDirectTouchStateScrolling) {
                [self emitScrollAtFramePoint:_directScrollFramePoint
                                 translation:CGPointZero
                                       flags:MacWSInputFlagScrollCancelled
                                   timestamp:_directTouch.timestamp];
            }
            _directTouchSerial++;
            _directTouch = nil;
            _directTouchState = MacWSDirectTouchStateIdle;
            _directScrollAxis = MacWSDirectScrollAxisNone;
            [self setDirectTouchHeld:NO dragging:NO animated:NO];
            _directTouchIndicator.hidden = YES;
        }
        if (event.allTouches.count <= touches.count)
            _directGestureBlocked = NO;
    } else if (_trackpadTouch && [touches containsObject:_trackpadTouch]) {
        if (_trackpadButtonDown) {
            [self emitKind:MacWSInputKindTouchCancel framePoint:_trackpadCursor
                 pressure:0 contactID:(uint32_t)_trackpadTouch.hash
                 timestamp:touch.timestamp];
        }
        _trackpadTouch = nil;
        _trackpadButtonDown = NO;
        _trackpadHadMultipleTouches = NO;
        [self setTrackpadPointerPressed:NO animated:YES];
        [self updatePointerVisibility];
    }
    [super touchesCancelled:touches withEvent:event];
}

- (void)resetViewportZoom {
    CGFloat previousZoom = _viewportZoom;
    CGPoint previousCenter = _viewportCenter;
    _viewportZoom = 1.0;
    _viewportCenter = CGPointMake(0.5, 0.5);
    _contentGesturesPassthrough = NO;
    [self updateZoomHUD];
    [self setNeedsDisplay];
    MacWSLog(@"viewport-reset previous-zoom=%.3f previous-center=(%.3f,%.3f) zoom=%.3f center=(%.3f,%.3f)",
             previousZoom, previousCenter.x, previousCenter.y,
             _viewportZoom, _viewportCenter.x, _viewportCenter.y);
}

- (void)viewportZoomToggled:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized) return;
    if ([self isViewportZoomed]) {
        [self resetViewportZoom];
        [self publishStatus:@"已退出放大视角"];
    } else {
        if ([self currentFrameWidth] == 0 || [self currentFrameHeight] == 0)
            return;
        simd_float4 unusedVertices[4];
        [self updateContentRectAndVertices:unusedVertices];
        CGPoint location = [recognizer locationInView:self];
        CGPoint normalized = CGPointMake(
            self.bounds.size.width > 0
                ? location.x / self.bounds.size.width : 0.5,
            self.bounds.size.height > 0
                ? location.y / self.bounds.size.height : 0.5);
        CGPoint sourcePoint = CGPointMake(
            CGRectGetMinX(_visibleSourceRect) +
                normalized.x * CGRectGetWidth(_visibleSourceRect),
            CGRectGetMinY(_visibleSourceRect) +
                normalized.y * CGRectGetHeight(_visibleSourceRect));
        _viewportZoom = _fixedZoomScale;
        // First derive the enlarged visible size, then choose a center that
        // keeps the tapped source point under the same two-finger centroid.
        // The viewport clamp may adjust this only near texture boundaries.
        [self updateContentRectAndVertices:unusedVertices];
        MacWSNormalizedPoint requestedCenter = MacWSViewportCenterKeepingAnchor(
            (MacWSNormalizedRect){
                .x = CGRectGetMinX(_visibleSourceRect),
                .y = CGRectGetMinY(_visibleSourceRect),
                .width = CGRectGetWidth(_visibleSourceRect),
                .height = CGRectGetHeight(_visibleSourceRect),
            },
            (MacWSNormalizedPoint){sourcePoint.x, sourcePoint.y},
            normalized.x, normalized.y);
        _viewportCenter = CGPointMake(requestedCenter.x, requestedCenter.y);
        [self updateContentRectAndVertices:unusedVertices];
        [self updateZoomHUD];
        [self setNeedsDisplay];
        [self publishStatus:[NSString stringWithFormat:
            @"已进入 %.1f× 放大视角", _fixedZoomScale]];
    }
}

- (BOOL)scrollFramePointForRecognizer:(UIGestureRecognizer *)recognizer
                               output:(CGPoint *)scrollPoint {
    CGPoint point = _trackpadCursor;
    if (self.inputMode == MacWSHostInputModeDirect) {
        if (![self framePointForViewPoint:[recognizer locationInView:self]
                                   output:&point]) return NO;
    } else {
        uint32_t width = [self currentFrameWidth];
        uint32_t height = [self currentFrameHeight];
        if (point.x < 0 || point.y < 0 ||
            point.x >= width || point.y >= height)
            point = CGPointMake(width * 0.5, height * 0.5);
    }
    if (scrollPoint) *scrollPoint = point;
    return YES;
}

- (void)emitMagnifyAtFramePoint:(CGPoint)framePoint
                          amount:(CGFloat)amount
                           flags:(uint16_t)flags
                       timestamp:(NSTimeInterval)timestamp {
    if (!self.isMacWSInputEnabled || !isfinite(amount)) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindMagnify,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = (float)amount,
        .contactID = 0x50494e43u, // "PINC"
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceFinger,
        .flags = flags,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)emitRotationAtFramePoint:(CGPoint)framePoint
                         degrees:(CGFloat)degrees
                           flags:(uint16_t)flags
                       timestamp:(NSTimeInterval)timestamp {
    if (!self.isMacWSInputEnabled || !isfinite(degrees)) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindRotate,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = (float)degrees,
        .contactID = 0x524f5441u, // "ROTA"
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceFinger,
        .flags = flags,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)emitScrollAtFramePoint:(CGPoint)framePoint
                    translation:(CGPoint)translation
                          flags:(uint16_t)flags
                      timestamp:(NSTimeInterval)timestamp {
    CGFloat direction = self.inputMode == MacWSHostInputModeDirect ? 1.0 : -1.0;
    [self emitScrollAtFramePoint:framePoint translation:translation
                          flags:flags timestamp:timestamp
                          source:MacWSInputSourceFinger
               directionMultiplier:direction];
}

- (BOOL)dockExposeOwnsScroll {
    if (_streamClient.mode != MacWSStreamModeFullscreen) return NO;
    if (_dockExposeStateToken < 0) {
        int candidate = -1;
        if (notify_register_check(MACWS_DOCK_EXPOSE_STATE_NAME,
                                  &candidate) != NOTIFY_STATUS_OK) return NO;
        _dockExposeStateToken = candidate;
    }
    uint64_t state = 0;
    uint32_t status = notify_get_state(_dockExposeStateToken, &state);
    if (status == NOTIFY_STATUS_INVALID_TOKEN ||
        status == NOTIFY_STATUS_SERVER_NOT_FOUND) {
        notify_cancel(_dockExposeStateToken);
        _dockExposeStateToken = -1;
        return NO;
    }
    if (status != NOTIFY_STATUS_OK ||
        !MacWSDockExposeIsActive(state)) return NO;
    int32_t writerPID = (int32_t)MacWSDockExposeWriter(state);
    // A crashed/relaunched Dock must not leave its old notify state blocking
    // application scrolling. Match the live Dock endpoint already selected
    // by the fullscreen system-gesture route, not a process-name guess.
    return writerPID > 1 &&
        writerPID == [self dockSystemGestureTargetPID] &&
        MacWSAppInputEndpointReady(writerPID);
}

- (void)emitScrollAtFramePoint:(CGPoint)framePoint
                    translation:(CGPoint)translation
                          flags:(uint16_t)flags
                      timestamp:(NSTimeInterval)timestamp
                         source:(MacWSInputSource)source
            directionMultiplier:(CGFloat)direction {
    if (!self.isMacWSInputEnabled) return;
    BOOL startsGesture = (flags & MacWSInputFlagScrollBegan) != 0 &&
        (flags & MacWSInputFlagScrollMomentum) == 0;
    BOOL exposeOwnsScroll = [self dockExposeOwnsScroll];
    if (startsGesture) {
        _scrollSuppressedByDockExpose = exposeOwnsScroll;
        if (_scrollSuppressedByDockExpose) {
            MacWSLog(@"dock-expose-scroll-suppressed dock=%d source=%u",
                [self dockSystemGestureTargetPID], source);
        }
    } else if (exposeOwnsScroll && !_scrollSuppressedByDockExpose) {
        // Expose can claim the desktop between Begin and Changed, or while a
        // pre-existing app scroll is decelerating. Retire that momentum loop
        // and transfer ownership at the first subsequent sample too.
        _scrollSuppressedByDockExpose = YES;
        [self stopScrollMomentumWithTerminalPhase:NO];
        MacWSLog(@"dock-expose-scroll-takeover dock=%d source=%u",
            [self dockSystemGestureTargetPID], source);
    }
    // Mission Control cards are compositor transforms, not live application
    // hit targets. Keep the entire Begin/Changed/End transaction (including
    // the optional momentum tail) away from the app until the next gesture
    // begins. Dock's independent one-finger global pointer route is untouched.
    if (_scrollSuppressedByDockExpose) {
        if (flags & (MacWSInputFlagScrollEnded |
                     MacWSInputFlagScrollCancelled))
            _scrollEmissionResidual = CGPointZero;
        return;
    }
    // UIKit translation is measured in Host points, while AppKit precise
    // scrollingDelta is measured in target logical points. The old fixed 2x
    // multiplier made a Retina 1770px/885pt Terminal move roughly twice the
    // finger distance. Derive the transform from the current exact surface,
    // viewport and backing scale so scrolling stays 1:1 at every Scene size.
    CGFloat backingScale = _surfaceFrame.descriptor.backingScale;
    if (!isfinite(backingScale) || backingScale < 0.5) backingScale = 1.0;
    CGFloat contentWidth = CGRectGetWidth(_contentRect);
    CGFloat contentHeight = CGRectGetHeight(_contentRect);
    CGFloat sourceWidth = [self currentFrameWidth] *
        CGRectGetWidth(_visibleSourceRect) / backingScale;
    CGFloat sourceHeight = [self currentFrameHeight] *
        CGRectGetHeight(_visibleSourceRect) / backingScale;
    CGFloat scaleX = contentWidth > 1.0 ? sourceWidth / contentWidth : 1.0;
    CGFloat scaleY = contentHeight > 1.0 ? sourceHeight / contentHeight : 1.0;
    scaleX = fmin(fmax(scaleX, 0.25), 4.0);
    scaleY = fmin(fmax(scaleY, 0.25), 4.0);
    // Direct manipulation follows iOS: moving content down requests a
    // positive AppKit scroll delta. Relative and hardware trackpads keep
    // MacBook-style natural scrolling, whose UIKit translation is inverted at
    // this bridge. The caller supplies the input-device policy so a physical
    // scroll never changes direction when the HUD touch mode is switched.
    float horizontal = (float)(direction * translation.x * scaleX);
    float vertical = (float)(direction * translation.y * scaleY);
    BOOL momentum = (flags & MacWSInputFlagScrollMomentum) != 0;
    BOOL began = (flags & MacWSInputFlagScrollBegan) != 0;
    BOOL changed = (flags & MacWSInputFlagScrollChanged) != 0;
    BOOL terminal = (flags & (MacWSInputFlagScrollEnded |
                              MacWSInputFlagScrollCancelled)) != 0;
    if (began && !momentum) _scrollEmissionResidual = CGPointZero;
    if (changed) {
        // CGEventCreateScrollWheelEvent2 accepts integral pixel deltas. Keep
        // the sub-pixel remainder across 60/120 Hz UIKit and deceleration
        // samples so slow motion is accumulated into real pixels instead of
        // every tail sample being rounded independently to zero.
        double accumulatedX = horizontal + _scrollEmissionResidual.x;
        double accumulatedY = vertical + _scrollEmissionResidual.y;
        horizontal = (float)nearbyint(accumulatedX);
        vertical = (float)nearbyint(accumulatedY);
        _scrollEmissionResidual.x = accumulatedX - horizontal;
        _scrollEmissionResidual.y = accumulatedY - vertical;
    }
    // Preserve every UIKit movement sample. AppInputBridge already performs
    // lossless adjacent-scroll coalescing when the consumer is backpressured;
    // a second one-logical-pixel dead zone here delayed slow direct
    // manipulation by one or more display frames in Maps and web content.
    uint32_t horizontalBits = 0;
    memcpy(&horizontalBits, &horizontal, sizeof(horizontalBits));
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindScroll,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .pressure = vertical,
        .contactID = horizontalBits,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = source,
        .flags = flags,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
    if (terminal &&
        (momentum || !(flags & MacWSInputFlagScrollWillMomentum)))
        _scrollEmissionResidual = CGPointZero;
}

- (void)consumeIndirectScrollTranslation:(CGPoint)translation
                       recognizerVelocity:(CGPoint)recognizerVelocity
                               framePoint:(CGPoint)scrollPoint
                                timestamp:(CFTimeInterval)timestamp {
    if (translation.x == 0.0 && translation.y == 0.0) {
        _indirectScrollPreviousTimestamp = timestamp;
        return;
    }

    CFTimeInterval deltaTime = _indirectScrollPreviousTimestamp > 0
        ? timestamp - _indirectScrollPreviousTimestamp : 0;
    CGPoint sampled = CGPointZero;
    BOOL hasSample = NO;
    if (isfinite(recognizerVelocity.x) &&
        isfinite(recognizerVelocity.y) &&
        hypot(recognizerVelocity.x, recognizerVelocity.y) > 0.01) {
        // UIKit's velocity estimator spans multiple hardware samples and is
        // more reliable than dividing a coalesced callback delta by wall time.
        sampled = recognizerVelocity;
        hasSample = YES;
    } else if (deltaTime >= 1.0 / 1000.0 && deltaTime <= 0.10) {
        sampled = CGPointMake(translation.x / deltaTime,
                              translation.y / deltaTime);
        hasSample = isfinite(sampled.x) && isfinite(sampled.y);
    }
    if (hasSample) {
        _indirectScrollSampledVelocity = sampled;
        _indirectScrollLastMotionTimestamp = timestamp;
    }

    [self emitScrollAtFramePoint:scrollPoint
                     translation:translation
                           flags:MacWSInputFlagScrollChanged
                       timestamp:timestamp
                          source:MacWSInputSourceIndirectPointer
             directionMultiplier:-1.0];
    _indirectScrollMotionSegmentCount++;
    _indirectScrollPreviousTimestamp = timestamp;
}

- (void)indirectScrolled:(UIPanGestureRecognizer *)recognizer
    API_AVAILABLE(ios(13.4)) {
    if (!self.isMacWSInputEnabled) return;
    CGPoint translation = [recognizer translationInView:self];
    [recognizer setTranslation:CGPointZero inView:self];
    CGPoint recognizerVelocity = [recognizer velocityInView:self];
    CGPoint scrollPoint = CGPointZero;
    BOOL begins = recognizer.state == UIGestureRecognizerStateBegan;
    if (begins || !_indirectScrollFramePointValid) {
        if (![self scrollFramePointForRecognizer:recognizer
                                          output:&scrollPoint]) {
            if (MacWSHostTouchDiagnosticsEnabled()) {
                CGPoint location = [recognizer locationInView:self];
                MacWSLog(@"indirect-scroll route-rejected window=%u state=%ld location=(%.2f,%.2f) content=(%.2f,%.2f %.2fx%.2f)",
                    self.targetWindowID, (long)recognizer.state,
                    location.x, location.y, _contentRect.origin.x,
                    _contentRect.origin.y, _contentRect.size.width,
                    _contentRect.size.height);
            }
            return;
        }
        _indirectScrollFramePoint = scrollPoint;
        _indirectScrollFramePointValid = YES;
    } else {
        // Scroll is one input transaction. UIKit's terminal scroll event can
        // report a transient/out-of-content location after the pointer or
        // scene focus changes. Freeze the Begin-time AppKit point just like
        // the fullscreen router freezes its Begin descriptor.
        scrollPoint = _indirectScrollFramePoint;
    }
    NSTimeInterval timestamp = CACurrentMediaTime();
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self stopScrollMomentumWithTerminalPhase:YES];
            _indirectScrollSampledVelocity = CGPointZero;
            _indirectScrollPreviousTimestamp = timestamp;
            _indirectScrollLastMotionTimestamp = 0;
            _indirectScrollMotionSegmentCount = 0;
            [self emitScrollAtFramePoint:scrollPoint
                             translation:CGPointZero
                                   flags:MacWSInputFlagScrollBegan
                               timestamp:timestamp
                                  source:MacWSInputSourceIndirectPointer
                     directionMultiplier:-1.0];
            // A scroll recognizer enters Began only after it has accumulated
            // enough device movement.  That first callback can already carry
            // the complete motion of a short trackpad flick, so it must be
            // forwarded and sampled instead of being reset and discarded.
            [self consumeIndirectScrollTranslation:translation
                                recognizerVelocity:recognizerVelocity
                                        framePoint:scrollPoint
                                         timestamp:timestamp];
            if (MacWSHostTouchDiagnosticsEnabled()) {
                MacWSLog(@"indirect-scroll begin window=%u translation=(%.2f,%.2f) velocity=(%.1f,%.1f) segments=%lu",
                    self.targetWindowID, translation.x, translation.y,
                    recognizerVelocity.x, recognizerVelocity.y,
                    (unsigned long)_indirectScrollMotionSegmentCount);
            }
            break;
        case UIGestureRecognizerStateChanged:
            [self consumeIndirectScrollTranslation:translation
                                recognizerVelocity:recognizerVelocity
                                        framePoint:scrollPoint
                                         timestamp:timestamp];
            break;
        case UIGestureRecognizerStateEnded:
        {
            // UIKit can coalesce the final hardware segment directly into
            // Ended.  Consume it before resolving release velocity so a short
            // Began -> Ended gesture has a complete transaction.
            [self consumeIndirectScrollTranslation:translation
                                recognizerVelocity:recognizerVelocity
                                        framePoint:scrollPoint
                                         timestamp:timestamp];
            CFTimeInterval sampledAge =
                _indirectScrollLastMotionTimestamp > 0
                ? timestamp - _indirectScrollLastMotionTimestamp
                : INFINITY;
            double velocityX = 0;
            double velocityY = 0;
            BOOL startsMomentum = MacWSResolveIndirectScrollReleaseVelocity(
                recognizerVelocity.x, recognizerVelocity.y,
                _indirectScrollSampledVelocity.x,
                _indirectScrollSampledVelocity.y,
                sampledAge, &velocityX, &velocityY);
            CGPoint velocity = CGPointMake(velocityX, velocityY);
            uint16_t endedFlags = MacWSInputFlagScrollEnded;
            if (startsMomentum)
                endedFlags |= MacWSInputFlagScrollWillMomentum;
            if (MacWSHostTouchDiagnosticsEnabled()) {
                MacWSLog(@"indirect-scroll release window=%u recognizer=(%.1f,%.1f) sampled=(%.1f,%.1f) age=%.4f resolved=(%.1f,%.1f) segments=%lu momentum=%@",
                    self.targetWindowID,
                    recognizerVelocity.x, recognizerVelocity.y,
                    _indirectScrollSampledVelocity.x,
                    _indirectScrollSampledVelocity.y,
                    sampledAge, velocity.x, velocity.y,
                    (unsigned long)_indirectScrollMotionSegmentCount,
                    startsMomentum ? @"YES" : @"NO");
            }
            [self emitScrollAtFramePoint:scrollPoint
                             translation:CGPointZero
                                   flags:endedFlags
                               timestamp:timestamp
                                  source:MacWSInputSourceIndirectPointer
                     directionMultiplier:-1.0];
            [self startScrollMomentumWithVelocity:velocity
                                       framePoint:scrollPoint
                                           source:MacWSInputSourceIndirectPointer
                              directionMultiplier:-1.0];
            _indirectScrollFramePointValid = NO;
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (MacWSHostTouchDiagnosticsEnabled()) {
                MacWSLog(@"indirect-scroll cancelled window=%u state=%ld sampled=(%.1f,%.1f) segments=%lu",
                    self.targetWindowID, (long)recognizer.state,
                    _indirectScrollSampledVelocity.x,
                    _indirectScrollSampledVelocity.y,
                    (unsigned long)_indirectScrollMotionSegmentCount);
            }
            [self emitScrollAtFramePoint:scrollPoint
                             translation:CGPointZero
                                   flags:MacWSInputFlagScrollCancelled
                               timestamp:timestamp
                                  source:MacWSInputSourceIndirectPointer
                     directionMultiplier:-1.0];
            [self stopScrollMomentumWithTerminalPhase:NO];
            _indirectScrollSampledVelocity = CGPointZero;
            _indirectScrollPreviousTimestamp = 0;
            _indirectScrollLastMotionTimestamp = 0;
            _indirectScrollMotionSegmentCount = 0;
            _indirectScrollFramePointValid = NO;
            break;
        default:
            break;
    }
}

- (void)stopScrollMomentumWithTerminalPhase:(BOOL)terminalPhase {
    if (terminalPhase && _scrollMomentumDisplayLink) {
        [self emitScrollAtFramePoint:_scrollMomentumFramePoint
                         translation:CGPointZero
                               flags:MacWSInputFlagScrollEnded |
                                     MacWSInputFlagScrollMomentum
                           timestamp:CACurrentMediaTime()
                              source:_scrollMomentumSource
                 directionMultiplier:_scrollMomentumDirectionMultiplier];
    }
    [_scrollMomentumDisplayLink invalidate];
    _scrollMomentumDisplayLink = nil;
    _scrollMomentumVelocity = CGPointZero;
    _scrollMomentumSource = MacWSInputSourceUnknown;
    _scrollMomentumDirectionMultiplier = 1.0;
    _scrollMomentumLastTimestamp = 0;
    _scrollMomentumBegan = NO;
}

- (void)startScrollMomentumWithVelocity:(CGPoint)velocity
                             framePoint:(CGPoint)framePoint {
    [self startScrollMomentumWithVelocity:velocity
                               framePoint:framePoint
                                   source:MacWSInputSourceFinger
                      directionMultiplier:self.inputMode == MacWSHostInputModeDirect
                          ? 1.0 : -1.0];
}

- (void)startScrollMomentumWithVelocity:(CGPoint)velocity
                             framePoint:(CGPoint)framePoint
                                 source:(MacWSInputSource)source
                    directionMultiplier:(CGFloat)directionMultiplier {
    if (_scrollSuppressedByDockExpose) return;
    BOOL indirect = source == MacWSInputSourceIndirectPointer;
    BOOL shouldStart = indirect
        ? MacWSShouldStartIndirectScrollMomentum(velocity.x, velocity.y)
        : MacWSShouldStartScrollMomentum(velocity.x, velocity.y);
    if (!shouldStart) return;
    [self stopScrollMomentumWithTerminalPhase:NO];
    _scrollMomentumVelocity = velocity;
    _scrollMomentumFramePoint = framePoint;
    _scrollMomentumSource = source;
    _scrollMomentumDirectionMultiplier = directionMultiplier;
    _scrollMomentumBegan = NO;
    _scrollMomentumLastTimestamp = 0;
    _scrollMomentumDisplayLink = [CADisplayLink
        displayLinkWithTarget:self selector:@selector(scrollMomentumTick:)];
    NSInteger maximumFPS = UIScreen.mainScreen.maximumFramesPerSecond;
    _scrollMomentumDisplayLink.preferredFramesPerSecond =
        MAX(60, MIN(maximumFPS, 120));
    [_scrollMomentumDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                     forMode:NSRunLoopCommonModes];
}

- (void)scrollMomentumTick:(CADisplayLink *)link {
    CFTimeInterval timestamp = link.timestamp;
    CFTimeInterval deltaTime = _scrollMomentumLastTimestamp > 0
        ? timestamp - _scrollMomentumLastTimestamp : link.duration;
    _scrollMomentumLastTimestamp = timestamp;
    deltaTime = fmin(fmax(deltaTime, 1.0 / 240.0), 1.0 / 20.0);
    // UIScrollView's normal deceleration rate is approximately 0.998 per ms.
    CGFloat decay = pow(0.998, deltaTime * 1000.0);
    _scrollMomentumVelocity.x *= decay;
    _scrollMomentumVelocity.y *= decay;
    CGFloat speed = hypot(_scrollMomentumVelocity.x,
                          _scrollMomentumVelocity.y);
    CGFloat stopSpeed = _scrollMomentumSource ==
        MacWSInputSourceIndirectPointer
        ? MACWS_INDIRECT_SCROLL_MOMENTUM_STOP_POINTS_PER_SECOND
        : MACWS_SCROLL_MOMENTUM_STOP_POINTS_PER_SECOND;
    if (speed < stopSpeed) {
        [self stopScrollMomentumWithTerminalPhase:YES];
        return;
    }
    uint16_t phase = _scrollMomentumBegan
        ? MacWSInputFlagScrollChanged : MacWSInputFlagScrollBegan;
    _scrollMomentumBegan = YES;
    CGPoint translation = CGPointMake(_scrollMomentumVelocity.x * deltaTime,
                                      _scrollMomentumVelocity.y * deltaTime);
    [self emitScrollAtFramePoint:_scrollMomentumFramePoint
                     translation:translation
                           flags:phase | MacWSInputFlagScrollMomentum
                       timestamp:CACurrentMediaTime()
                          source:_scrollMomentumSource
             directionMultiplier:_scrollMomentumDirectionMultiplier];
}

- (void)twoFingerPanned:(UIPanGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled) return;
    [self updateMultitouchIndicatorsForRecognizer:recognizer];
    CGPoint translation = [recognizer translationInView:self];
    [recognizer setTranslation:CGPointZero inView:self];
    BOOL moveViewport = self.inputMode == MacWSHostInputModeDirect &&
        [self isViewportZoomed] && !_contentGesturesPassthrough;
    if (moveViewport) {
        if (self.bounds.size.width > 0 && self.bounds.size.height > 0) {
            _viewportCenter.x -= translation.x / self.bounds.size.width *
                CGRectGetWidth(_visibleSourceRect);
            _viewportCenter.y -= translation.y / self.bounds.size.height *
                CGRectGetHeight(_visibleSourceRect);
            simd_float4 unusedVertices[4];
            [self updateContentRectAndVertices:unusedVertices];
            [self setNeedsDisplay];
        }
        return;
    }
    CGPoint scrollPoint = CGPointZero;
    if (![self scrollFramePointForRecognizer:recognizer output:&scrollPoint])
        return;
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self stopScrollMomentumWithTerminalPhase:YES];
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:MacWSInputFlagScrollBegan
                               timestamp:CACurrentMediaTime()];
            break;
        case UIGestureRecognizerStateChanged:
            if (translation.x != 0 || translation.y != 0) {
                [self emitScrollAtFramePoint:scrollPoint translation:translation
                                       flags:MacWSInputFlagScrollChanged
                                   timestamp:CACurrentMediaTime()];
            }
            break;
        case UIGestureRecognizerStateEnded: {
            CGPoint velocity = [recognizer velocityInView:self];
            uint16_t endedFlags = MacWSInputFlagScrollEnded;
            if (MacWSShouldStartScrollMomentum(velocity.x, velocity.y))
                endedFlags |= MacWSInputFlagScrollWillMomentum;
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:endedFlags
                               timestamp:CACurrentMediaTime()];
            [self startScrollMomentumWithVelocity:velocity
                                       framePoint:scrollPoint];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self emitScrollAtFramePoint:scrollPoint translation:CGPointZero
                                   flags:MacWSInputFlagScrollCancelled
                               timestamp:CACurrentMediaTime()];
            [self stopScrollMomentumWithTerminalPhase:NO];
            break;
        default:
            break;
    }
}

- (void)pinched:(UIPinchGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled) return;
    [self updateMultitouchIndicatorsForRecognizer:recognizer];
    CGPoint framePoint = CGPointZero;
    if (![self scrollFramePointForRecognizer:recognizer output:&framePoint])
        return;
    NSTimeInterval timestamp = CACurrentMediaTime();
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            // UIKit has already accumulated real movement while Possible,
            // including the short three-finger chord interval. Preserve that
            // first delta. The Ventura event bridge deliberately encodes a
            // scalar only for Changed, because Began establishes the latched
            // AppKit responder. Emit those two native phases in order before
            // resetting UIKit's cumulative value.
            CGFloat initialAmount = recognizer.scale - 1.0;
            recognizer.scale = 1.0;
            [self emitMagnifyAtFramePoint:framePoint amount:0.0
                                    flags:MacWSInputFlagGestureBegan
                                timestamp:timestamp];
            if (fabs(initialAmount) > 0.00001) {
                [self emitMagnifyAtFramePoint:framePoint amount:initialAmount
                                        flags:MacWSInputFlagGestureChanged
                                    timestamp:timestamp];
            }
            break;
        }
        case UIGestureRecognizerStateChanged: {
            // UIPinchGestureRecognizer.scale is cumulative. AppKit's
            // magnification is an incremental delta, so consume and reset the
            // ratio at every UIKit sample instead of accelerating over time.
            CGFloat amount = recognizer.scale - 1.0;
            recognizer.scale = 1.0;
            if (fabs(amount) > 0.00001) {
                [self emitMagnifyAtFramePoint:framePoint amount:amount
                                        flags:MacWSInputFlagGestureChanged
                                    timestamp:timestamp];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
            [self emitMagnifyAtFramePoint:framePoint amount:0.0
                                    flags:MacWSInputFlagGestureEnded
                                timestamp:timestamp];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self emitMagnifyAtFramePoint:framePoint amount:0.0
                                    flags:MacWSInputFlagGestureCancelled
                                timestamp:timestamp];
            break;
        default:
            break;
    }
}

- (void)rotated:(UIRotationGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled) return;
    [self updateMultitouchIndicatorsForRecognizer:recognizer];
    CGPoint framePoint = CGPointZero;
    if (![self scrollFramePointForRecognizer:recognizer output:&framePoint])
        return;
    NSTimeInterval timestamp = CACurrentMediaTime();
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            // Source-confirmed: the chord gate can leave this recognizer
            // Possible while it accumulates rotation. The Ventura event
            // bridge intentionally consumes rotation only on Changed, so a
            // nonzero Began scalar would still be discarded. Establish the
            // native responder with Began, then deliver the accumulated
            // physical delta as the immediately following Changed phase.
            CGFloat initialDegrees =
                MacWSAppKitRotationDegreesForUIKitRadians(
                    recognizer.rotation);
            recognizer.rotation = 0.0;
            [self emitRotationAtFramePoint:framePoint degrees:0.0
                                     flags:MacWSInputFlagGestureBegan
                                 timestamp:timestamp];
            if (fabs(initialDegrees) > 0.0001) {
                [self emitRotationAtFramePoint:framePoint
                                       degrees:initialDegrees
                                         flags:MacWSInputFlagGestureChanged
                                     timestamp:timestamp];
            }
            break;
        }
        case UIGestureRecognizerStateChanged: {
            // UIKit reports cumulative radians; Ventura NSEvent.rotation is
            // an incremental degree value. Consume each delta once.
            CGFloat degrees =
                MacWSAppKitRotationDegreesForUIKitRadians(
                    recognizer.rotation);
            recognizer.rotation = 0.0;
            if (fabs(degrees) > 0.0001) {
                [self emitRotationAtFramePoint:framePoint degrees:degrees
                                         flags:MacWSInputFlagGestureChanged
                                     timestamp:timestamp];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
            [self emitRotationAtFramePoint:framePoint degrees:0.0
                                     flags:MacWSInputFlagGestureEnded
                                 timestamp:timestamp];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self emitRotationAtFramePoint:framePoint degrees:0.0
                                     flags:MacWSInputFlagGestureCancelled
                                 timestamp:timestamp];
            break;
        default:
            break;
    }
}

- (void)threeFingerChordChanged:
        (MacWSThreeFingerChordGateGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        MacWSLog(@"three-finger-chord admitted grace-ms=%.0f touches=%lu",
                 MACWS_THREE_FINGER_CHORD_GRACE_SECONDS * 1000.0,
                 (unsigned long)recognizer.numberOfTouches);
    } else if (recognizer.state == UIGestureRecognizerStateEnded ||
               recognizer.state == UIGestureRecognizerStateCancelled) {
        MacWSLog(@"three-finger-chord terminal state=%ld",
                 (long)recognizer.state);
    }
}

- (int32_t)dockSystemGestureTargetPID {
    // The system input owner belongs to the desktop session contract.  A
    // retained final-composite Dock layer can outlive the process that created
    // it, so prefer the exact current launchd owner supplied by hostd.
    if (_systemInputPID > 1 &&
        MacWSAppInputEndpointReady(_systemInputPID))
        return _systemInputPID;

    // displayd marks only real Dock-owned capture layers with
    // GlobalSystemSurface.  Use that catalog identity instead of guessing a
    // PID from process names on the iOS side or borrowing the front app's CGS
    // connection as the old keyboard-shortcut path did.
    for (NSNumber *key in [[self overlayKeysBackToFront]
            reverseObjectEnumerator]) {
        MacWSStreamFrameDescriptor descriptor =
            _overlayFrames[key].descriptor;
        if ((descriptor.flags & MacWSStreamFrameGlobalSystemSurface) != 0 &&
            descriptor.layerOwnerPID > 1 &&
            MacWSAppInputEndpointReady(descriptor.layerOwnerPID))
            return descriptor.layerOwnerPID;
    }
    return 0;
}

- (void)emitSystemGestureAxis:(MacWSSystemGestureAxis)axis
                      progress:(CGFloat)progress
                      velocity:(CGFloat)velocity
                         flags:(uint16_t)flags
                     timestamp:(NSTimeInterval)timestamp {
    BOOL terminalPhase = (flags & (MacWSInputFlagGestureEnded |
        MacWSInputFlagGestureCancelled)) != 0;
    // Once Begin reached Dock, its terminal record is mandatory even if a
    // Scene transition has already disabled new pointer input. The endpoint
    // and geometry below are latched precisely so this close can outlive the
    // current DisplayStream/UI input-ready state.
    if ((!self.isMacWSInputEnabled && !terminalPhase) ||
        !_threeFingerSystemGestureActive ||
        (axis != MacWSSystemGestureAxisHorizontal &&
         axis != MacWSSystemGestureAxisVertical) ||
        !isfinite(progress) || !isfinite(velocity)) return;
    // A hardware gesture has one device/endpoint for its complete phase
    // lifetime.  Mission Control can temporarily remove or reorder Dock's
    // captured layers, and a UIKit scene transition can unsubscribe the
    // fullscreen stream before delivering its recognizer cancellation.  Use
    // the Begin-time identity rather than re-resolving a moving capture graph
    // for every Changed/End record.
    int32_t dockPID = _threeFingerSystemGestureTargetPID;
    uint32_t width = _threeFingerSystemGestureFrameWidth;
    uint32_t height = _threeFingerSystemGestureFrameHeight;
    if (width == 0 || height == 0 || dockPID <= 1) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindSystemGesture,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = timestamp,
        .x = width * 0.5f,
        .y = height * 0.5f,
        .pressure = (float)fmax(-2.0, fmin(progress, 2.0)),
        .contactID = _threeFingerSystemGestureContactID,
        .frameWidth = width,
        .frameHeight = height,
        .targetPID = dockPID,
        .source = MacWSInputSourceFinger,
        .flags = flags | MacWSInputFlagGlobalSystemSurface,
        .buttons = axis,
        .altitude = (float)fmax(-12.0, fmin(velocity, 12.0)),
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)resetActiveThreeFingerSystemGesture {
    _threeFingerSystemGestureActive = NO;
    _threeFingerSystemGestureAxis = 0;
    _threeFingerSystemGestureReferenceDistance = 0.0;
    _threeFingerSystemGestureContactID = 0;
    _threeFingerSystemGestureTargetPID = 0;
    _threeFingerSystemGestureFrameWidth = 0;
    _threeFingerSystemGestureFrameHeight = 0;
    _threeFingerSystemGestureLastProgress = 0.0;
    _threeFingerSystemGestureLastVelocity = 0.0;
}

- (void)cancelActiveThreeFingerSystemGestureAtTimestamp:
        (NSTimeInterval)timestamp {
    if (!_threeFingerSystemGestureActive) return;
    [self emitSystemGestureAxis:_threeFingerSystemGestureAxis
                       progress:_threeFingerSystemGestureLastProgress
                       velocity:_threeFingerSystemGestureLastVelocity
                          flags:MacWSInputFlagGestureCancelled
                      timestamp:timestamp > 0.0 ? timestamp :
                          CACurrentMediaTime()];
    [self resetActiveThreeFingerSystemGesture];
}

- (void)threeFingerPanned:(UIPanGestureRecognizer *)recognizer {
    [self updateMultitouchIndicatorsForRecognizer:recognizer];
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [self cancelActiveThreeFingerSystemGestureAtTimestamp:
            CACurrentMediaTime()];
        [self stopScrollMomentumWithTerminalPhase:YES];
        return;
    }
    BOOL terminalState =
        recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed;
    // UIKit is allowed to report cancellation after the Scene has suspended
    // or changed stream mode.  A live latched gesture must still close; only
    // an attempt to begin a new gesture requires a current fullscreen stream.
    if (_streamClient.mode != MacWSStreamModeFullscreen &&
        !_threeFingerSystemGestureActive) return;
    if (terminalState && !_threeFingerSystemGestureActive) return;
    CGPoint translation = [recognizer translationInView:self];
    CGPoint velocity = [recognizer velocityInView:self];
    NSTimeInterval timestamp = CACurrentMediaTime();
    if (!_threeFingerSystemGestureActive &&
        recognizer.state == UIGestureRecognizerStateChanged) {
        CGFloat minimumDimension = MIN(self.bounds.size.width,
                                       self.bounds.size.height);
        _threeFingerSystemGestureAxis =
            MacWSSystemGestureAxisForTranslation(
                translation.x, translation.y, minimumDimension);
        if (_threeFingerSystemGestureAxis == 0) return;
        _threeFingerSystemGestureReferenceDistance =
            MacWSSystemGestureReferenceDistance(minimumDimension);
        _threeFingerSystemGestureContactID =
            0x33464700u | ((++_directTouchSerial) & 0xffu); // "3FG"
        _threeFingerSystemGestureTargetPID =
            [self dockSystemGestureTargetPID];
        _threeFingerSystemGestureFrameWidth = [self currentFrameWidth];
        _threeFingerSystemGestureFrameHeight = [self currentFrameHeight];
        if (_threeFingerSystemGestureTargetPID <= 1 ||
            _threeFingerSystemGestureFrameWidth == 0 ||
            _threeFingerSystemGestureFrameHeight == 0) {
            [self resetActiveThreeFingerSystemGesture];
            return;
        }
        _threeFingerSystemGestureActive = YES;
        CGFloat initialDisplacement = _threeFingerSystemGestureAxis ==
            MacWSSystemGestureAxisHorizontal ? translation.x : translation.y;
        CGFloat initialVelocity = _threeFingerSystemGestureAxis ==
            MacWSSystemGestureAxisHorizontal ? velocity.x : velocity.y;
        [self emitSystemGestureAxis:_threeFingerSystemGestureAxis
                           progress:MacWSSystemGestureProgressForDisplacement(
                                _threeFingerSystemGestureAxis,
                                initialDisplacement,
                                _threeFingerSystemGestureReferenceDistance)
                           velocity:MacWSSystemGestureProgressForDisplacement(
                                _threeFingerSystemGestureAxis,
                                initialVelocity,
                                _threeFingerSystemGestureReferenceDistance)
                              flags:MacWSInputFlagGestureBegan
                          timestamp:timestamp];
    }
    if (!_threeFingerSystemGestureActive) return;

    CGFloat displacement = _threeFingerSystemGestureAxis ==
        MacWSSystemGestureAxisHorizontal ? translation.x : translation.y;
    CGFloat pointVelocity = _threeFingerSystemGestureAxis ==
        MacWSSystemGestureAxisHorizontal ? velocity.x : velocity.y;
    // Use Dock's RE- and runtime-confirmed per-axis sign convention. A single
    // Cartesian sign flip misroutes finger-up to the disabled App Expose slot
    // instead of the live native Mission Control fluid controller.
    CGFloat progress = MacWSSystemGestureProgressForDisplacement(
        _threeFingerSystemGestureAxis, displacement,
        _threeFingerSystemGestureReferenceDistance);
    CGFloat progressVelocity = MacWSSystemGestureProgressForDisplacement(
        _threeFingerSystemGestureAxis, pointVelocity,
        _threeFingerSystemGestureReferenceDistance);
    _threeFingerSystemGestureLastProgress = progress;
    _threeFingerSystemGestureLastVelocity = progressVelocity;
    uint16_t phase = 0;
    switch (recognizer.state) {
        case UIGestureRecognizerStateChanged:
            phase = MacWSInputFlagGestureChanged;
            break;
        case UIGestureRecognizerStateEnded:
            phase = MacWSInputFlagGestureEnded;
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            phase = MacWSInputFlagGestureCancelled;
            break;
        default:
            return;
    }
    [self emitSystemGestureAxis:_threeFingerSystemGestureAxis
                       progress:progress velocity:progressVelocity
                          flags:phase timestamp:timestamp];
    if (phase & (MacWSInputFlagGestureEnded |
                 MacWSInputFlagGestureCancelled)) {
        [self resetActiveThreeFingerSystemGesture];
    }
}

- (void)runPerformanceGestureScenario:(NSString *)scenario
    completion:(void (^)(BOOL success, NSString *message))completion {
    void (^finish)(BOOL, NSString *) = completion
        ? [completion copy]
        : [^(BOOL success, NSString *message) {
            (void)success;
            (void)message;
        } copy];
    if (!self.isMacWSInputEnabled) {
        finish(NO, @"触控桥尚未就绪");
        return;
    }

    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (!width || !height) {
        finish(NO, @"DisplayStream 尚无有效画面尺寸");
        return;
    }
    CGPoint center = CGPointMake(width * 0.5, height * 0.5);
    BOOL systemScenario = [scenario hasPrefix:@"three-"] ||
        [scenario isEqualToString:@"mission-select"];
    if (!systemScenario && _streamClient.mode == MacWSStreamModeFullscreen) {
        BOOL resolvedPerformancePoint =
            [scenario isEqualToString:@"window-drag"]
                ? [self performanceTitlebarPointForTargetPID:self.targetPID
                                                       point:&center]
                : [self performanceVisiblePointForTargetPID:self.targetPID
                                                      point:&center];
        if (!resolvedPerformancePoint) {
            finish(NO, [scenario isEqualToString:@"window-drag"]
                ? @"当前目标没有可验证的可见标题栏"
                : @"目标应用当前没有可见、可命中的性能测试区域");
            return;
        }
    }

    MacWSPerformanceGestureScenario *adapter =
        [MacWSPerformanceGestureScenario new];
    adapter.name = scenario;
    adapter.targetPoint = center;
    CGPoint alternate = center;
    if (_streamClient.mode == MacWSStreamModeFullscreen) {
        int32_t centerPID = 0;
        uint32_t centerWindowID = 0;
        if ([self resolveFullscreenLayerAtPoint:center pid:&centerPID
                                       windowID:&centerWindowID
                                     descriptor:NULL]) {
            static const CGFloat offsets[][2] = {
                {16.0, 0.0}, {-16.0, 0.0}, {0.0, 16.0},
                {0.0, -16.0}, {24.0, 0.0}, {-24.0, 0.0},
            };
            for (NSUInteger index = 0;
                 index < sizeof(offsets) / sizeof(offsets[0]); index++) {
                CGPoint candidate = CGPointMake(
                    center.x + offsets[index][0],
                    center.y + offsets[index][1]);
                int32_t candidatePID = 0;
                uint32_t candidateWindowID = 0;
                if ([self resolveFullscreenLayerAtPoint:candidate
                                                    pid:&candidatePID
                                               windowID:&candidateWindowID
                                             descriptor:NULL] &&
                    candidatePID == centerPID &&
                    candidateWindowID == centerWindowID) {
                    alternate = candidate;
                    break;
                }
            }
        }
    } else {
        alternate.x = fmin(width - 1.0, center.x + 16.0);
    }
    adapter.alternateTargetPoint = alternate;
    adapter.frameWidth = width;
    adapter.frameHeight = height;
    adapter.targetPID = self.targetPID;
    adapter.dockPID = systemScenario ? [self dockSystemGestureTargetPID] : 0;
    adapter.fullscreen =
        _streamClient.mode == MacWSStreamModeFullscreen;
    adapter.contactID = 0x50524600u |
        ((++_directTouchSerial) & 0xffu); // "PRF"
    adapter.pointerFlags = MacWSInputFlagLatencyDiagnostic;

    __weak typeof(self) weakSelf = self;
    __weak MacWSPerformanceGestureScenario *weakAdapter = adapter;
    adapter.emitPointer = ^(MacWSInputKind kind, CGPoint point,
                            float pressure, uint16_t flags) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        MacWSPerformanceGestureScenario *strongAdapter = weakAdapter;
        if (!strongSelf || !strongAdapter) return;
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = kind,
            .sceneID = [strongSelf inputSceneIDWithModifiers:0],
            .timestamp = CACurrentMediaTime(),
            .x = (float)point.x,
            .y = (float)point.y,
            .pressure = pressure,
            .contactID = strongAdapter.contactID,
            .frameWidth = width,
            .frameHeight = height,
            .targetPID = strongSelf.targetPID,
            // The performance hover is the regression surrogate for the
            // Magic Keyboard's UIHoverGestureRecognizer path.  Preserve its
            // indirect-pointer source identity instead of labelling that one
            // stream as a finger; down/move/up scenarios remain direct touch.
            .source = kind == MacWSInputKindHover
                ? MacWSInputSourceIndirectPointer
                : MacWSInputSourceFinger,
            .flags = flags,
            .sampleSequence = ++strongSelf->_inputSampleSequence,
        };
        [strongSelf.statusDelegate metalView:strongSelf emittedInput:record];
    };
    adapter.emitScroll = ^(CGPoint point, CGPoint translation,
                           uint16_t flags, NSTimeInterval timestamp) {
        [weakSelf emitScrollAtFramePoint:point translation:translation
                                   flags:flags timestamp:timestamp];
    };
    adapter.emitMagnify = ^(CGPoint point, CGFloat amount, uint16_t flags,
                            NSTimeInterval timestamp) {
        [weakSelf emitMagnifyAtFramePoint:point amount:amount flags:flags
                                timestamp:timestamp];
    };
    adapter.startMomentum = ^(CGPoint velocity, CGPoint point) {
        [weakSelf startScrollMomentumWithVelocity:velocity framePoint:point];
    };
    adapter.stopMomentum = ^(BOOL terminalPhase) {
        [weakSelf stopScrollMomentumWithTerminalPhase:terminalPhase];
    };
    adapter.prepareSystemGesture = ^(
            MacWSSystemGestureAxis axis, uint32_t contactID, int32_t dockPID,
            uint32_t frameWidth, uint32_t frameHeight, CGFloat velocity) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_threeFingerSystemGestureActive = YES;
        strongSelf->_threeFingerSystemGestureAxis = axis;
        strongSelf->_threeFingerSystemGestureContactID = contactID;
        strongSelf->_threeFingerSystemGestureTargetPID = dockPID;
        strongSelf->_threeFingerSystemGestureFrameWidth = frameWidth;
        strongSelf->_threeFingerSystemGestureFrameHeight = frameHeight;
        strongSelf->_threeFingerSystemGestureLastProgress = 0.0;
        strongSelf->_threeFingerSystemGestureLastVelocity = velocity;
    };
    adapter.emitSystemGesture = ^(
            MacWSSystemGestureAxis axis, CGFloat progress, CGFloat velocity,
            uint16_t flags, NSTimeInterval timestamp) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_threeFingerSystemGestureLastProgress = progress;
        strongSelf->_threeFingerSystemGestureLastVelocity = velocity;
        [strongSelf emitSystemGestureAxis:axis progress:progress
                                 velocity:velocity flags:flags
                                timestamp:timestamp];
    };
    adapter.resetSystemGesture = ^{
        [weakSelf resetActiveThreeFingerSystemGesture];
    };
    adapter.missionControlDidCommit = ^{
        // Dock's native modal router must see a real pointer-family event
        // before a card click. Prime that exact hit context immediately after
        // Mission Control settles; this is a normal hover and is also what a
        // physical trackpad produces before pressing.
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        MacWSPerformanceGestureScenario *strongAdapter = weakAdapter;
        if (!strongAdapter) return;
        strongAdapter.emitPointer(
            MacWSInputKindHover, strongAdapter.targetPoint, 0.0f,
            MacWSInputFlagLatencyDiagnostic);
    };
    [adapter runWithCompletion:finish];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == _threeFingerPanRecognizer ||
        gestureRecognizer == _threeFingerChordGate)
        return self.isMacWSInputEnabled &&
            _streamClient.mode == MacWSStreamModeFullscreen;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    // A physical two-finger gesture can carry translation, scale and rotation
    // in the same sample. Preserve every native stream so Maps can pan, zoom
    // and rotate without UIKit forcing one recognizer to win.
    NSSet *twoFingerRecognizers = [NSSet setWithObjects:
        _twoFingerPanRecognizer, _pinchRecognizer, _rotationRecognizer, nil];
    BOOL gateAndThreeFinger =
        (gestureRecognizer == _threeFingerChordGate &&
         otherGestureRecognizer == _threeFingerPanRecognizer) ||
        (otherGestureRecognizer == _threeFingerChordGate &&
         gestureRecognizer == _threeFingerPanRecognizer);
    if (gateAndThreeFinger) return YES;
    return [twoFingerRecognizers containsObject:gestureRecognizer] &&
           [twoFingerRecognizers containsObject:otherGestureRecognizer];
}

- (void)trackpadSecondaryTapped:(UITapGestureRecognizer *)recognizer {
    if (!self.isMacWSInputEnabled ||
        recognizer.state != UIGestureRecognizerStateEnded) return;
    if (self.inputMode == MacWSHostInputModeDirect) {
        CGPoint framePoint = CGPointZero;
        if (![self framePointForViewPoint:[recognizer locationInView:self]
                                   output:&framePoint]) return;
        [self emitKind:MacWSInputKindSecondaryTap framePoint:framePoint
             pressure:0 contactID:0x53454332u
             timestamp:CACurrentMediaTime()];
        return;
    }
    uint32_t width = [self currentFrameWidth];
    uint32_t height = [self currentFrameHeight];
    if (_trackpadCursor.x < 0 || _trackpadCursor.y < 0 ||
        _trackpadCursor.x >= width || _trackpadCursor.y >= height)
        _trackpadCursor = CGPointMake(width * 0.5, height * 0.5);
    [self emitKind:MacWSInputKindSecondaryTap framePoint:_trackpadCursor
         pressure:0 contactID:0x53454332u timestamp:CACurrentMediaTime()];
}

- (void)hovered:(UIHoverGestureRecognizer *)recognizer API_AVAILABLE(ios(13.4)) {
    if (!self.isMacWSInputEnabled) return;
    if (recognizer.state == UIGestureRecognizerStateBegan)
        [self restoreHardwareKeyboardFocusWithReason:@"pointer-enter"];
    CGPoint viewPoint = [recognizer locationInView:self];
    CGPoint framePoint;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) return;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindHover,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = CACurrentMediaTime(),
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourceIndirectPointer,
        .sampleSequence = ++_inputSampleSequence,
    };
    _externalPointerHoverActive = recognizer.state ==
            UIGestureRecognizerStateBegan ||
        recognizer.state == UIGestureRecognizerStateChanged;
    _trackpadCursor = framePoint;
    if (self.inputMode == MacWSHostInputModeTrackpad)
        [self updatePointerVisibility];
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)pencilHovered:(UIHoverGestureRecognizer *)recognizer
    API_AVAILABLE(ios(13.4)) {
    if (!self.isMacWSInputEnabled) return;
    CGPoint viewPoint = [recognizer locationInView:self];
    CGPoint framePoint = CGPointZero;
    if (![self framePointForViewPoint:viewPoint output:&framePoint]) return;
    BOOL active = recognizer.state == UIGestureRecognizerStateBegan ||
                  recognizer.state == UIGestureRecognizerStateChanged;
    _pencilHoverActive = active;
    _pencilCursorView.center = viewPoint;
    [self updatePointerVisibility];
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindHover,
        .sceneID = [self inputSceneIDWithModifiers:0],
        .timestamp = CACurrentMediaTime(),
        .x = (float)framePoint.x,
        .y = (float)framePoint.y,
        .frameWidth = [self currentFrameWidth],
        .frameHeight = [self currentFrameHeight],
        .targetPID = self.targetPID,
        .source = MacWSInputSourcePencil,
        .flags = MacWSInputFlagPreciseLocation,
        .sampleSequence = ++_inputSampleSequence,
    };
    [self.statusDelegate metalView:self emittedInput:record];
}

- (void)streamClient:(MacWSStreamClient *)client
       statusChanged:(NSString *)status
           connected:(BOOL)connected {
    (void)client;
    MacWSLog(@"display-stream status connected=%@ message=%@",
             connected ? @"YES" : @"NO", status ?: @"");
    _streamConnected = connected;
    if (!connected) {
        _latestWindows = @[];
        _catalogRevalidationRequestedForPresentation = NO;
    }
    if (!connected && (_surfaceFrame || _overlayFrames.count)) {
        _framePollDisplayLink.paused = self.targetWindowID != 0 ||
            !MacWSLegacyFramebufferFallbackEnabled();
        if (_surfaceFrame) {
            if (_surfaceFrame.descriptor.leaseToken ==
                _submittedSurfaceLeaseToken)
                [_retiredSurfaceFrames addObject:_surfaceFrame];
            else
                [_streamClient releaseFrame:_surfaceFrame];
        }
        for (NSNumber *key in _overlayFrames) {
            MacWSSurfaceFrame *frame = _overlayFrames[key];
            if (frame.descriptor.leaseToken ==
                [_submittedOverlayLeaseTokens[key] unsignedLongLongValue])
                [_retiredSurfaceFrames addObject:frame];
            else
                [_streamClient releaseFrame:frame];
        }
        _surfaceFrame = nil;
        _surfaceTexture = nil;
        [_overlayFrames removeAllObjects];
        [_overlayTextures removeAllObjects];
        [_submittedOverlayLeaseTokens removeAllObjects];
        _submittedSurfaceLeaseToken = 0;
        _sortedOverlayKeys = nil;
        _sourceTexture = nil;
        _textureWidth = 0;
        _textureHeight = 0;
        [self updateDrawableResolution];
        [self setNeedsDisplay];
    }
    if (!_surfaceFrame) [self publishStatus:status];
}

- (void)streamClient:(MacWSStreamClient *)client
      receivedWindows:(NSArray<MacWSStreamWindow *> *)windows {
    (void)client;
    ++_windowCatalogRevision;
    _latestWindows = [windows copy];
    NSMutableSet<NSNumber *> *spatialCanvasPIDs = [NSMutableSet set];
    NSMutableSet<NSNumber *> *fullscreenCanvasPIDs =
        [_fullscreenCanvasPIDs mutableCopy] ?: [NSMutableSet set];
    // A fullscreen conversion briefly removes every catalog entry for the
    // game while its process and AppInput endpoint remain alive. Preserve the
    // controller-validated current target even during the earlier
    // endpoint-not-yet-registered phase. A real target change removes that
    // PID in setTargetPID:; non-target capabilities still use endpoint
    // liveness as their revocation edge.
    for (NSNumber *pidValue in [fullscreenCanvasPIDs.allObjects copy]) {
        BOOL controllerValidatedCurrentTarget =
            pidValue.intValue == self.targetPID &&
            _reportedFullscreenCanvasPID == self.targetPID &&
            _reportedFullscreenCanvasWindowID != 0;
        if (!controllerValidatedCurrentTarget &&
            !MacWSAppInputEndpointReady(pidValue.intValue))
            [fullscreenCanvasPIDs removeObject:pidValue];
    }
    NSMutableSet<NSNumber *> *shadowWindowIDs = [NSMutableSet set];
    for (MacWSStreamWindow *window in windows) {
        if (window.descriptor.ownerPID > 1 &&
            (window.descriptor.flags & MacWSStreamWindowSpatialCanvas) != 0)
            [spatialCanvasPIDs addObject:@(window.descriptor.ownerPID)];
        if (window.descriptor.ownerPID > 1 &&
            (window.descriptor.flags &
                MacWSStreamWindowFullscreenCanvas) != 0)
            [fullscreenCanvasPIDs addObject:@(window.descriptor.ownerPID)];
        if (window.descriptor.windowID != 0 &&
            (window.descriptor.flags & MacWSStreamWindowHasShadow) != 0)
            [shadowWindowIDs addObject:@(window.descriptor.windowID)];
    }
    _spatialCanvasPIDs = [spatialCanvasPIDs copy];
    _fullscreenCanvasPIDs = [fullscreenCanvasPIDs copy];
    _shadowWindowIDs = [shadowWindowIDs copy];
    _directTouchUsesPrimaryDrag = self.targetPID > 1 &&
        [_spatialCanvasPIDs containsObject:@(self.targetPID)];
    if (_streamClient.mode == MacWSStreamModeFullscreen &&
        self.targetPID <= 1) {
        NSMutableArray<NSString *> *catalog = [NSMutableArray array];
        for (MacWSStreamWindow *window in windows) {
            if (catalog.count >= 32) break;
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            [catalog addObject:[NSString stringWithFormat:
                @"%d/%u/%#x/endpoint=%@", descriptor.ownerPID,
                descriptor.windowID, descriptor.flags,
                MacWSAppInputEndpointReady(descriptor.ownerPID)
                    ? @"YES" : @"NO"]];
        }
        NSMutableArray<NSString *> *layers = [NSMutableArray array];
        for (NSNumber *key in [self overlayKeysBackToFront]) {
            if (layers.count >= 32) break;
            MacWSStreamFrameDescriptor descriptor =
                _overlayFrames[key].descriptor;
            [layers addObject:[NSString stringWithFormat:
                @"%d/%u/%#x", descriptor.layerOwnerPID,
                descriptor.layerWindowID, descriptor.flags]];
        }
        MacWSLog(@"fullscreen-target-candidates final=%@ catalog=[%@] "
                 "layers=[%@]",
                 [self hasFinalCompositeFrame] ? @"YES" : @"NO",
                 [catalog componentsJoinedByString:@","],
                 [layers componentsJoinedByString:@","]);
    }
    if (MacWSHostDiagnosticsEnabled())
        MacWSLog(@"display-stream window-list count=%lu",
                 (unsigned long)windows.count);
    [self updateDrawableResolution];
    [self setNeedsDisplay];
    [self.statusDelegate metalView:self receivedWindows:windows];
}

- (void)streamClient:(MacWSStreamClient *)client
        receivedFrame:(MacWSSurfaceFrame *)frame {
    uint32_t format = frame.descriptor.pixelFormat;
    // SkyLight/CGDisplayStream is requested as 32BGRA.  Reject another
    // explicit FourCC instead of silently interpreting it with the wrong
    // Metal pixel format.  A zero FourCC is accepted for older IOSurfaces
    // whose pixel-format property is absent.
    if (format != 0 && format != 0x42475241u) {
        [client releaseFrame:frame];
        [self publishStatus:@"DisplayStream 返回了非 BGRA IOSurface"];
        return;
    }
    if (!self.device) {
        [client releaseFrame:frame];
        return;
    }
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(frame.surface);
    NSUInteger requiredAlignment =
        MacWSIOSurfaceReadOnlyTextureAlignment(self.device);
    if (requiredAlignment != 0 &&
        bytesPerRow % requiredAlignment != 0) {
        MacWSLog(@"display-stream reject-metal-stride stream=%llu frame=%llu "
                 "window=%u layer=%u surface=%ux%u bpr=%zu required=%lu",
            (unsigned long long)frame.descriptor.streamID,
            (unsigned long long)frame.descriptor.sequence,
            frame.descriptor.windowID, frame.descriptor.layerWindowID,
            frame.descriptor.width, frame.descriptor.height, bytesPerRow,
            (unsigned long)requiredAlignment);
        [client releaseFrame:frame];
        [self publishStatus:[NSString stringWithFormat:
            @"DisplayStream IOSurface 行跨度未按 Metal 要求对齐（%zu / %lu）",
            bytesPerRow, (unsigned long)requiredAlignment]];
        return;
    }
    BOOL overlayFrame =
        (frame.descriptor.flags & MacWSStreamFrameOverlay) != 0;
    NSNumber *overlayKey = overlayFrame
        ? @(frame.descriptor.layerWindowID) : nil;
    MacWSSurfaceFrame *texturePredecessor = overlayFrame
        ? _overlayFrames[overlayKey] : _surfaceFrame;
    if (texturePredecessor &&
        ((frame.descriptor.streamID ==
              texturePredecessor.descriptor.streamID &&
          frame.descriptor.sequence <=
              texturePredecessor.descriptor.sequence) ||
         frame.descriptor.streamID <
              texturePredecessor.descriptor.streamID)) {
        // XPC is ordered, but frame delivery is paced to the next display
        // link while geometry batches are applied immediately on main. A
        // delayed content frame must not roll the compositor back behind an
        // already-visible geometry transaction or a newer producer stream.
        [client releaseFrame:frame];
        return;
    }
    id<MTLTexture> texture = overlayFrame
        ? _overlayTextures[overlayKey] : _surfaceTexture;
    uint32_t incomingSurfaceID = IOSurfaceGetID(frame.surface);
    uint32_t predecessorSurfaceID = texturePredecessor
        ? IOSurfaceGetID(texturePredecessor.surface) : 0;
    BOOL reusedTexture = texture && incomingSurfaceID != 0 &&
        incomingSurfaceID == predecessorSurfaceID &&
        texture.width == frame.descriptor.width &&
        texture.height == frame.descriptor.height &&
        texture.pixelFormat == MTLPixelFormatBGRA8Unorm;
    if (!reusedTexture) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:frame.descriptor.width
                                                              height:frame.descriptor.height
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        texture = [self.device newTextureWithDescriptor:descriptor
                                              iosurface:frame.surface
                                                  plane:0];
    }
    if (!texture) {
        [client releaseFrame:frame];
        [self publishStatus:@"无法从 DisplayStream IOSurface 创建 Metal 纹理"];
        return;
    }
    if (!overlayFrame) {
        [_performanceMonitor recordBaseTransportFinalComposite:
            ((frame.descriptor.flags &
              MacWSStreamFrameFinalComposite) != 0)
            streamID:frame.descriptor.streamID
            sequence:frame.descriptor.sequence
            surfaceID:incomingSurfaceID];
    }
    [_performanceMonitor recordFrameReceivedForStream:
        frame.descriptor.streamID sequence:frame.descriptor.sequence
        layerWindowID:frame.descriptor.layerWindowID
        ownerPID:frame.descriptor.layerOwnerPID
        captureTime:frame.descriptor.displayTime receiptTime:frame.receiptTime];
    if (reusedTexture) {
        _surfaceTextureReuses++;
    } else {
        _surfaceTextureImports++;
        texture.label = [NSString stringWithFormat:
            @"MacWS stream %llu frame %llu",
            (unsigned long long)frame.descriptor.streamID,
            (unsigned long long)frame.descriptor.sequence];
    }

    if (overlayFrame) {
        NSNumber *key = overlayKey;
        MacWSSurfaceFrame *previous = texturePredecessor;
        if (!previous ||
            previous.descriptor.layerLevel != frame.descriptor.layerLevel)
            _sortedOverlayKeys = nil;
        if (previous) {
            if (previous.descriptor.leaseToken ==
                [_submittedOverlayLeaseTokens[key] unsignedLongLongValue])
                [_retiredSurfaceFrames addObject:previous];
            else
                [client releaseFrame:previous];
        }
        _overlayFrames[key] = frame;
        _overlayTextures[key] = texture;
        _streamConnected = YES;
        if (_streamClient.mode == MacWSStreamModeFullscreen &&
            !_catalogRevalidationRequestedForPresentation) {
            _catalogRevalidationRequestedForPresentation = YES;
            MacWSLog(@"display-stream catalog-revalidate "
                     "reason=first-overlay-presentation window=%u pid=%d",
                     frame.descriptor.layerWindowID,
                     frame.descriptor.layerOwnerPID);
            [_streamClient requestWindowList];
        }
        [self setNeedsDisplay];
        return;
    }

    MacWSSurfaceFrame *previous = texturePredecessor;
    BOOL becameFinalComposite =
        (frame.descriptor.flags & MacWSStreamFrameFinalComposite) != 0 &&
        (!previous || (previous.descriptor.flags &
                       MacWSStreamFrameFinalComposite) == 0);
    BOOL geometryChanged = !previous ||
        !MacWSStreamFrameGeometryEqual(previous.descriptor,
                                       frame.descriptor);
    if (previous) {
        if (previous.descriptor.leaseToken == _submittedSurfaceLeaseToken)
            [_retiredSurfaceFrames addObject:previous];
        else
            [client releaseFrame:previous];
    }
    _surfaceFrame = frame;
    _surfaceTexture = texture;
    if (frame.descriptor.contentWidth != 0 &&
        frame.descriptor.contentHeight != 0) {
        _lastKeyboardFrameWidth = frame.descriptor.contentWidth;
        _lastKeyboardFrameHeight = frame.descriptor.contentHeight;
    }
    _streamConnected = YES;
    if (!self.windowConfigurationAcknowledgementsAvailable &&
        _windowConfigurationAwaitingAcknowledgement &&
        !self.windowConfigurationHasQueuedRequest &&
        self.targetWindowID != 0 &&
        frame.descriptor.windowID == self.targetWindowID &&
        frame.descriptor.backingScale > 0.0f) {
        CGSize applied = {
            frame.descriptor.contentWidth / frame.descriptor.backingScale,
            frame.descriptor.contentHeight / frame.descriptor.backingScale,
        };
        if (fabs(applied.width - _lastRequestedWindowSize.width) < 0.75 &&
            fabs(applied.height - _lastRequestedWindowSize.height) < 0.75) {
            // Compatibility with an old producer: a matching IOSurface can
            // establish convergence, but a different size is not a rejection
            // of this request. New producers use the explicit configure ACK.
            _windowConfigurationAwaitingAcknowledgement = NO;
            _windowConfigurationSettlementSerial++;
            _windowConfigurationRequestSequence = 0;
        }
    }
    if (!previous) {
        // suspendStream deliberately releases the old stream's base frame.
        // applyStatus consequently disables input until the replacement has
        // an IOSurface.  A DisplayStream connection notification can precede
        // this frame, so publish a distinct first-frame state transition and
        // let the controller re-evaluate the complete input invariant.
        [self publishStatus:@"DisplayStream IOSurface 首帧已就绪"];
    }
    // DisplayStream is now authoritative. Stop polling the legacy mmap
    // acknowledgement files until this Scene changes streams or disconnects.
    _framePollDisplayLink.paused = YES;
    if (geometryChanged) {
        [self updateDrawableResolution];
        [self updatePresentationGeometry];
        [self scheduleWindowConfiguration];
    }
    if (becameFinalComposite) {
        // The initial catalog can arrive before this first surface, when the
        // final-composite fallback is intentionally not yet eligible. Ask for
        // one fresh catalog after the surface becomes authoritative so target
        // selection and pointer correlation converge after a Host relaunch
        // without waiting for an unrelated AppKit window mutation.
        if (!_catalogRevalidationRequestedForPresentation) {
            _catalogRevalidationRequestedForPresentation = YES;
            MacWSLog(@"display-stream catalog-revalidate "
                     "reason=first-final-composite");
            [_streamClient requestWindowList];
        }
    }
    [self setNeedsDisplay];
}

- (void)streamClient:(MacWSStreamClient *)client
 receivedLayerGeometryUpdates:(NSData *)updates
                   receiptTime:(uint64_t)receiptTime {
    (void)client;
    if (!updates.length ||
        updates.length % sizeof(MacWSStreamLayerGeometry) != 0 ||
        updates.length / sizeof(MacWSStreamLayerGeometry) >
            MACWS_STREAM_MAX_LAYER_GEOMETRY) return;
    const MacWSStreamLayerGeometry *records = updates.bytes;
    NSUInteger count = updates.length / sizeof(*records);
    [_performanceMonitor recordGeometryBatchReceived];
    BOOL changed = NO;
    BOOL presentationOrderChanged = NO;
    for (NSUInteger index = 0; index < count; index++) {
        const MacWSStreamLayerGeometry *geometry = &records[index];
        if (!MacWSStreamLayerGeometryIsValid(geometry,
                                              sizeof(*geometry))) continue;
        NSNumber *key = @(geometry->layerWindowID);
        MacWSSurfaceFrame *frame = _overlayFrames[key];
        if (!frame) continue;
        MacWSStreamFrameDescriptor current = frame.descriptor;
        if (!MacWSStreamLayerGeometrySupersedesFrame(
                geometry, &current)) continue;
        BOOL directLayerPresentationChanged =
            geometry->layerOwnerPID == self.targetPID &&
            geometry->layerWindowID == _directDrawableHeartbeatLayerID &&
            _directDrawableHeartbeatPID == self.targetPID &&
            (current.layerLevel != geometry->layerLevel ||
             current.destinationX != geometry->destinationX ||
             current.destinationY != geometry->destinationY ||
             current.destinationWidth != geometry->destinationWidth ||
             current.destinationHeight != geometry->destinationHeight);
        if (directLayerPresentationChanged) {
            uint64_t barrier = geometry->displayTime ?: receiptTime;
            _directDrawableGeometryBarrierTime = MAX(
                _directDrawableGeometryBarrierTime, barrier);
            _scheduledCatalystDrawableFrame = nil;
        }
        MacWSStreamFrameDescriptor descriptor = current;
        BOOL levelChanged = descriptor.layerLevel != geometry->layerLevel;
        descriptor.sequence = geometry->sequence;
        descriptor.displayTime = geometry->displayTime;
        descriptor.layerOwnerPID = geometry->layerOwnerPID;
        descriptor.layerLevel = geometry->layerLevel;
        descriptor.destinationX = geometry->destinationX;
        descriptor.destinationY = geometry->destinationY;
        descriptor.destinationWidth = geometry->destinationWidth;
        descriptor.destinationHeight = geometry->destinationHeight;
        descriptor.flags = (descriptor.flags &
            ~(MacWSStreamFrameGlobalSystemSurface |
              MacWSStreamFrameInputPassthrough)) |
            (geometry->flags &
                (MacWSStreamFrameGlobalSystemSurface |
                 MacWSStreamFrameInputPassthrough));
        _overlayFrames[key] = [[MacWSSurfaceFrame alloc]
            initWithDescriptor:descriptor surface:frame.surface
            receiptTime:receiptTime];
        if (levelChanged) {
            _sortedOverlayKeys = nil;
            presentationOrderChanged = YES;
        }
        [_performanceMonitor recordGeometryReceivedForStream:
            descriptor.streamID sequence:descriptor.sequence
            layerWindowID:descriptor.layerWindowID
            ownerPID:descriptor.layerOwnerPID
            captureTime:descriptor.displayTime receiptTime:receiptTime];
        changed = YES;
    }
    if (changed) [self setNeedsDisplay];
    if (presentationOrderChanged && _latestWindows.count) {
        // A native activation reorders retained layers without necessarily
        // changing the OptionAll identity catalog. Re-evaluate targetPID on
        // that exact ordered-geometry transaction; otherwise the visible app
        // changes while subsequent hardware keys remain bound to the previous
        // PID until an unrelated catalog mutation occurs. This is local and
        // event-driven, so dragging a window (geometry only, same level) does
        // not trigger catalog work or a target-selection loop.
        MacWSLog(@"display-stream input-target-revalidate "
                 "reason=layer-order-changed layers=%lu windows=%lu",
                 (unsigned long)_overlayFrames.count,
                 (unsigned long)_latestWindows.count);
        [self.statusDelegate metalView:self receivedWindows:_latestWindows];
    }
}

- (void)streamClient:(MacWSStreamClient *)client
 removedLayerWindowID:(uint32_t)layerWindowID {
    (void)client;
    NSNumber *key = @(layerWindowID);
    MacWSSurfaceFrame *frame = _overlayFrames[key];
    if (!frame) return;
    MacWSStreamFrameDescriptor retiredDescriptor = frame.descriptor;
    int32_t retiredOwnerPID = frame.descriptor.layerOwnerPID;
    if (frame.descriptor.leaseToken ==
        [_submittedOverlayLeaseTokens[key] unsignedLongLongValue])
        [_retiredSurfaceFrames addObject:frame];
    else
        [_streamClient releaseFrame:frame];
    [_overlayFrames removeObjectForKey:key];
    [_overlayTextures removeObjectForKey:key];
    [_submittedOverlayLeaseTokens removeObjectForKey:key];
    _sortedOverlayKeys = nil;
    // A layer removal changes the next drawable without delivering a new
    // IOSurface. Record that real geometry transaction before requesting the
    // redraw so input-to-visible measurement can pair a Mission Control card
    // click with the presentation that actually removes its Dock layers.
    uint64_t retirementTime = mach_absolute_time();
    [_performanceMonitor recordGeometryReceivedForStream:
        retiredDescriptor.streamID sequence:retiredDescriptor.sequence
        layerWindowID:retiredDescriptor.layerWindowID
        ownerPID:retiredDescriptor.layerOwnerPID
        captureTime:retirementTime receiptTime:retirementTime];
    MacWSDiagnosticLog(@"display-stream overlay-retire-ui layer=%u immediate=YES",
             layerWindowID);
    [self setNeedsDisplay];
    // Layer retirement is the authoritative edge that can invalidate the
    // exact NSWindow cached for fullscreen keyboard routing.  Re-read the
    // low-rate window catalog once at this lifecycle boundary; the controller
    // will follow the target only when the retired identity is truly absent.
    // This does not add work to frame or pointer-move paths.
    if (retiredOwnerPID > 1 && retiredOwnerPID == self.targetPID &&
        !_targetRetirementCatalogRequeryScheduled) {
        _targetRetirementCatalogRequeryScheduled = YES;
        MacWSDiagnosticLog(@"display-stream catalog-requery-scheduled reason=target-layer-retired pid=%d layer=%u",
                 retiredOwnerPID, layerWindowID);
        // WindowServer commonly retires every layer in one transaction.  One
        // catalog snapshot after that batch is authoritative; requesting once
        // per sibling layer duplicated XPC/CGWindow work at application exit.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     75 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            self->_targetRetirementCatalogRequeryScheduled = NO;
            if (!self->_streamConnected) return;
            MacWSDiagnosticLog(@"display-stream catalog-requery reason=target-layer-retirement-batch");
            [self->_streamClient requestWindowList];
        });
    }
}
@end
