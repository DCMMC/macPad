#import <MetalKit/MetalKit.h>

#import "MacWSPerformanceMonitor.h"
#import "MacWSStreamClient.h"
#include "macws_host_protocol.h"

NS_ASSUME_NONNULL_BEGIN

@class MacWSMetalView;

typedef NS_ENUM(NSUInteger, MacWSHostPresentationResolution) {
    // Preserve the producer's pixels for desktop/window presentation, but
    // keep the one-pixel-per-point path for a validated fullscreen canvas.
    MacWSHostPresentationResolutionAutomatic = 0,
    MacWSHostPresentationResolutionSourceNative = 1,
    MacWSHostPresentationResolutionPerformance = 2,
};

@protocol MacWSMetalViewStatusDelegate <NSObject>
- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status;
- (void)metalView:(nullable MacWSMetalView *)view
      emittedInput:(MacWSInputRecord)record;
- (void)metalView:(MacWSMetalView *)view
    completedDirectTapAtViewPoint:(CGPoint)viewPoint;
- (void)metalView:(MacWSMetalView *)view
  receivedWindows:(NSArray<MacWSStreamWindow *> *)windows;
- (void)metalView:(MacWSMetalView *)view
    windowConfigurationWasConstrainedToLogicalSize:(CGSize)appliedSize
                                      requestedSize:(CGSize)requestedSize;
@end

/// Owns DisplayStream presentation and translates UIKit touch/keyboard input
/// into the versioned MacWS input protocol. Scene lifecycle and control-center
/// policy intentionally remain in MacWSViewController.
@interface MacWSMetalView : MTKView
    <MTKViewDelegate, MacWSStreamClientDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, weak) id<MacWSMetalViewStatusDelegate> statusDelegate;
@property(nonatomic) uint64_t sceneID;
@property(nonatomic) uint32_t targetWindowID;
@property(nonatomic) int32_t targetPID;
// Exact live Dock/session input owner published by macwshostd.  This is a
// lifecycle identity, not a visual-layer hint, and remains valid when the
// final-composite graph intentionally retains static pixels.
@property(nonatomic) int32_t systemInputPID;
@property(nonatomic, getter=isMacWSInputEnabled) BOOL macWSInputEnabled;
@property(nonatomic) MacWSHostInputMode inputMode;
@property(nonatomic) MacWSHostDisplayDensity displayDensity;
@property(nonatomic) MacWSHostPresentationResolution presentationResolution;
@property(nonatomic) CGFloat fixedZoomScale;
@property(nonatomic) CGSize minimumLogicalSize;
@property(nonatomic) CGSize maximumLogicalSize;
@property(nonatomic) BOOL windowConfigurationAcknowledgementsAvailable;
@property(nonatomic) BOOL targetWindowResizable;
@property(nonatomic) BOOL targetWindowFixedWidth;
@property(nonatomic) BOOL targetWindowFixedHeight;
@property(nonatomic) BOOL softwareKeyboardActive;
// A native iPadOS drag and a macOS long-press/right-click begin with the same
// physical gesture. The controller arms this explicitly for one cross-App
// drag so UIKit alone owns that contact; ordinary macOS touch semantics remain
// unchanged at all other times.
@property(nonatomic) BOOL crossAppDragModeEnabled;
@property(nonatomic, readonly) BOOL hasDirectSurfaceFrame;
@property(nonatomic, readonly) BOOL hasFinalCompositeFrame;
@property(nonatomic, readonly) BOOL streamServiceConnected;
// Advances only for a received native catalog, not local layer-order refresh.
@property(nonatomic, readonly) uint64_t windowCatalogRevision;
@property(nonatomic, readonly) CGFloat effectiveDensityScale;
@property(nonatomic, readonly) BOOL windowConfigurationAwaitingAcknowledgement;
@property(nonatomic, readonly) BOOL windowConfigurationAwaitingSettlement;
@property(nonatomic, readonly) BOOL nativeWindowResizeGestureActive;
@property(nonatomic, readonly) BOOL windowConfigurationHasQueuedRequest;
@property(nonatomic, readonly) BOOL sceneResizeFollowingTargetWindow;
// A fullscreen pointer/gesture owns one WindowServer transaction from its
// Begin edge through the matching End/Cancel. Passive catalog and retained
// layer-order updates may refresh pixels during that interval, but must not
// replace the semantic keyboard/direct-drawable target underneath it.
@property(nonatomic, readonly) BOOL fullscreenInputTransactionActive;
@property(nonatomic, readonly) MacWSPerformanceMonitor *performanceMonitor;
- (void)setMacWSInputEnabled:(BOOL)enabled
                      reason:(nullable NSString *)reason;
- (void)configureStreamMode:(MacWSStreamMode)mode windowID:(uint32_t)windowID;
- (void)requestStreamWindowList;
- (void)noteValidatedFullscreenCanvasForPID:(int32_t)ownerPID
                                   windowID:(uint32_t)windowID;
// A passive AppKit catalog refresh must not replace an explicitly activated
// fullscreen producer while its exact canvas and completed drawable are live.
- (BOOL)hasCompletedFullscreenDrawableForPID:(int32_t)ownerPID;
- (void)refreshPresentationPolicy;
- (void)resetViewportZoom;
- (void)geometryDidChange;
- (void)observeTargetWindowLogicalSize:(CGSize)logicalSize;
- (void)observeWindowConfigurationWithTimestamp:(double)timestamp
                                sampleSequence:(uint32_t)sampleSequence
                                 requestedSize:(CGSize)requestedSize
                                   appliedSize:(CGSize)appliedSize;
- (void)beginSceneResizeFollowingTargetWindowLogicalSize:(CGSize)logicalSize;
- (void)cancelSceneResizeFollowingTargetWindow;
- (void)suspendStream;
- (void)emitSoftwareText:(NSString *)text modifiers:(uint32_t)modifiers;
- (void)emitSoftwareKeySym:(uint32_t)keySym modifiers:(uint32_t)modifiers;
// Drag interoperability uses the same versioned input records as ordinary
// touch. The probe makes the target AppKit view populate NSDragPboard; the
// matching finish always releases the synthetic primary-button transaction.
- (BOOL)beginInteropDragProbeAtViewPoint:(CGPoint)viewPoint;
- (void)finishInteropDragProbeCancelled:(BOOL)cancelled;
// The two-finger context click and the controller's two-finger export hold
// share one physical chord.  Make the short tap wait for the hold recognizer
// to fail so one chord can commit to exactly one semantic action.
- (void)requireSecondaryTapToFailGestureRecognizer:
    (UIGestureRecognizer *)gestureRecognizer;
// A UIKit drop is committed to the exact visible macOS point, then routed
// through the target application's enabled Command-V menu action after
// macwsinteropd acknowledges the full pasteboard archive.
- (void)performInteropPasteAtViewPoint:(CGPoint)viewPoint;
- (BOOL)forwardHardwarePresses:(NSSet<UIPress *> *)presses
                       keyDown:(BOOL)keyDown;
- (void)observeHardwareModifiersForEvent:(UIEvent *)event;
- (void)releaseHardwareKeyboardState;
- (BOOL)restoreHardwareKeyboardFocusWithReason:(NSString *)reason;
- (void)updatePresentationGeometry;
- (void)updatePointerVisibility;
- (void)setTrackpadPointerPressed:(BOOL)pressed animated:(BOOL)animated;
- (void)startScrollMomentumWithVelocity:(CGPoint)velocity
                             framePoint:(CGPoint)framePoint;
- (void)startScrollMomentumWithVelocity:(CGPoint)velocity
                             framePoint:(CGPoint)framePoint
                                 source:(MacWSInputSource)source
                    directionMultiplier:(CGFloat)directionMultiplier;
- (void)stopScrollMomentumWithTerminalPhase:(BOOL)terminalPhase;
- (void)cancelActiveThreeFingerSystemGestureAtTimestamp:
    (NSTimeInterval)timestamp;
- (uint32_t)currentFrameWidth;
- (uint32_t)currentFrameHeight;
- (NSArray<NSNumber *> *)overlayKeysBackToFront;
- (int32_t)frontmostInputApplicationPIDAmongPIDs:(NSSet<NSNumber *> *)pids;
- (BOOL)routeFullscreenInputRecord:(MacWSInputRecord *)record
             presentationTargetPID:(int32_t *)presentationTargetPID;
- (BOOL)performanceVisiblePointForTargetPID:(int32_t)targetPID
                                      point:(CGPoint *)point;
- (void)logPerformanceSnapshotWithReason:(NSString *)reason;
- (void)requestRenderedDrawableSnapshotToPath:(NSString *)path;
- (BOOL)writeBaseSurfaceSnapshotToPath:(NSString *)path;
- (NSUInteger)writeWorkspaceSurfaceSnapshotsToDirectory:(NSString *)directory;
- (void)runPerformanceGestureScenario:(NSString *)scenario
    completion:(void (^)(BOOL success, NSString *message))completion;
- (nullable NSString *)exportCatalystDrawableProbeForPID:(int32_t)ownerPID
                                                    error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
