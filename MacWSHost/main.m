#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <IOKit/IOKitLib.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <simd/simd.h>

#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#import "MacWSControlClient.h"
#import "MacWSInteropClient.h"
#import "MacWSMenuClient.h"
#import "MacWSPerformanceMonitor.h"
#import "MacWSPerformanceGestureScenario.h"
#import "MacWSCatalystDrawableProbe.h"
#import "MacWSStreamClient.h"
#import "MacWSHostDiagnostics.h"
#import "MacWSHostRuntime.h"
#import "MacWSKeyMapping.h"
#import "MacWSCatalystDrawableReceiver.h"
#import "MacWSCatalystDrawableCompositor.h"
#import "MacWSMetalView.h"
#import "MacWSCatalystLaunchCoordinator.h"
#import "MacWSMappedFrame.h"
#include "macws_control_protocol.h"
#include "macws_catalyst_drawable_protocol.h"
#include "macws_host_protocol.h"
#include "macws_keyboard_text_input.h"
#include "macws_text_input.h"
#include "macws_touch_policy.h"
#include "macws_viewport_math.h"
#include "macws_window_configuration.h"
#include "macws_windowing_notify.h"

@interface UIWindowScene (MacWSFullscreenState)
@property(nonatomic, readonly, getter=isFullScreen) BOOL fullScreen;
@end

@interface UIWindow (MacWSApplicationKeyWindow)
- (BOOL)_isApplicationKeyWindow;
@end

// UIKitCore 20D67 distinguishes each Scene's local key window from the one
// application-wide keyboard target. Both notification names are present in
// the running cache; the application-key getter at 0x189170a48 compares the
// receiver with _UIKeyWindowEvaluator's selected window, not Scene.keyWindow.
static NSString *const MacWSApplicationKeyWindowNotification =
    @"_UIWindowDidBecomeApplicationKeyNotification";
static NSString *const MacWSKeyboardTargetSceneNotification =
    @"_UISceneDidBecomeTargetOfKeyboardEventDeferringEnvironmentNotification";
// Runtime-confirmed on iPadOS 16.3.1: UIKitCore's exported
// _UIApplicationSceneOcclusionChangedNotification constant resolves to this
// value. Its FBS settings expose the occlusion/background state consumed by
// UIKit's own _UIWindowSceneOcclusionSettingsDiffAction.
static NSString *const MacWSSceneOcclusionChangedNotification =
    @"UIApplicationSceneOcclusionChangedNotification";
static const CGFloat MacWSNativeMenuBarHeight = 24.0;

@interface UIScene (MacWSSceneIdentity)
// RE-confirmed via UIKitCore 16.3.1 -[UIScene _sceneIdentifier] at
// 0x189322ff0. This is the FBS identifier used as SBDisplayItem's
// uniqueIdentifier, unlike UISceneSession.persistentIdentifier.
- (NSString *)_sceneIdentifier;
- (id)_effectiveSettings;
@end

@interface NSObject (MacWSSceneOcclusionSettings)
- (BOOL)isOccluded;
- (BOOL)isForeground;
- (BOOL)isBackgrounded;
@end

static BOOL MacWSReadEffectiveSceneLifecycle(UIScene *scene,
                                              BOOL *occluded,
                                              BOOL *foreground,
                                              BOOL *backgrounded) {
    if (occluded) *occluded = NO;
    if (foreground) *foreground = NO;
    if (backgrounded) *backgrounded = NO;
    if (![scene respondsToSelector:@selector(_effectiveSettings)]) return NO;
    id settings = [scene _effectiveSettings];
    if (![settings respondsToSelector:@selector(isOccluded)] ||
        ![settings respondsToSelector:@selector(isForeground)] ||
        ![settings respondsToSelector:@selector(isBackgrounded)]) return NO;
    if (occluded) *occluded = [settings isOccluded];
    if (foreground) *foreground = [settings isForeground];
    if (backgrounded) *backgrounded = [settings isBackgrounded];
    return YES;
}

@interface UISceneActivationRequestOptions (MacWSFullscreenRequest)
- (void)_setRequestFullscreen:(BOOL)fullscreen;
- (void)setPreserveLayout:(BOOL)preserveLayout;
- (BOOL)preserveLayout;
@end

@interface UIWindowSceneActivationRequestOptions (MacWSWindowPlacement)
- (void)_setPreserveLayout:(BOOL)preserveLayout;
- (BOOL)_preserveLayout;
@end

@interface NSObject (MacWSMetalIOSurfaceAlignment)
- (NSUInteger)iosurfaceReadOnlyTextureAlignmentBytes;
@end

static NSMutableSet<NSString *> *MacWSSceneSessionsPreservingMacWindow;
static NSMutableDictionary<NSString *, NSUserActivity *> *MacWSSceneBindings;
static NSMutableSet<NSString *> *MacWSSceneCloseRequestsSent;
static NSMutableSet<NSString *> *MacWSObservedWindowIdentities;
static NSMutableSet<NSString *> *MacWSPreviouslyFrontmostWindowIdentities;
static NSMutableSet<NSString *> *MacWSPendingWindowSceneIdentities;
static NSMutableDictionary<NSString *, NSNumber *> *MacWSSceneCreationsInFlight;
static NSString *MacWSWindowIdentity(int32_t ownerPID, uint32_t windowID,
                                     uint32_t logicalGroupID);
static NSMutableDictionary<NSString *, NSNumber *> *MacWSClosingWindowIdentities;
static NSString *const MacWSSceneBindingsDefaultsKey =
    @"MacWSPersistedSceneWindowBindings";
static CFStringRef const MacWSRequestFullscreenNotification =
    CFSTR("com.macwsguide.windowing.request-fullscreen");
static CFStringRef const MacWSRequestResizeNotification =
    CFSTR("com.macwsguide.windowing.request-resize");
static CFStringRef const MacWSRequestInitialSizeNotification =
    CFSTR("com.macwsguide.windowing.request-initial-size");
static NSString *const MacWSResizeRequestDirectory =
    @MACWS_WINDOWING_REQUEST_DIRECTORY;
static NSString *const MacWSFullscreenRequestPrefix =
    @"com.macwsguide.windowing.fullscreen-request.";
static NSString *const MacWSResizeRequestPrefix =
    @"com.macwsguide.windowing.resize-request.";
static NSString *const MacWSInitialSizeRequestPrefix =
    @"com.macwsguide.windowing.initial-size-request.";
static NSString *const MacWSControlCenterLanguageDefaultsKey =
    @"MacWSControlCenterLanguage";

static BOOL MacWSControlCenterUsesEnglish(void) {
    return [[NSUserDefaults.standardUserDefaults
        stringForKey:MacWSControlCenterLanguageDefaultsKey]
        isEqualToString:@"en"];
}

static NSString *MacWSLocalized(NSString *chinese, NSString *english) {
    return MacWSControlCenterUsesEnglish() ? english : chinese;
}

static BOOL MacWSWindowingInitialSizeBridgeIsLoaded(void) {
    return MacWSWindowingLiveCapabilities(MacWSWindowingInitialSize, NULL);
}

typedef NS_ENUM(uint8_t, MacWSIndependentWindowingState) {
    MacWSIndependentWindowingUnknown = 0,
    MacWSIndependentWindowingInactive = 1,
    MacWSIndependentWindowingActive = 2,
};

static MacWSIndependentWindowingState
MacWSCurrentIndependentWindowingState(uint64_t *rawStateOut) {
    uint64_t state = 0;
    NSOperatingSystemVersion version =
        NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion < 16 ||
        (version.majorVersion == 16 && version.minorVersion < 1)) {
        // Runtime-confirmed on iPad14,5 / 20A8372: requesting a second
        // 700-point Scene produces a 678x1024 Split View column even though
        // UIApplication.supportsMultipleScenes is YES.  Treat this exact
        // pre-16.1 system family as non-Chamois without depending on tweak
        // injection, so an unavailable publisher cannot recreate the split.
        if (rawStateOut) *rawStateOut = state;
        return MacWSIndependentWindowingInactive;
    }
    BOOL publisherLive = MacWSWindowingLiveCapabilities(
        MacWSWindowingFullscreen, &state);
    if (rawStateOut) *rawStateOut = state;
    if (!publisherLive) return MacWSIndependentWindowingUnknown;
    uint8_t capabilities = MacWSWindowingStateCapabilities(state);
    if ((capabilities & MacWSWindowingChamoisKnown) == 0)
        return MacWSIndependentWindowingUnknown;
    return (capabilities & MacWSWindowingChamoisActive)
        ? MacWSIndependentWindowingActive
        : MacWSIndependentWindowingInactive;
}

static CGFloat MacWSSceneMaximumAxis(CGFloat logicalMaximum, CGFloat density,
                                     CGFloat chrome, CGFloat minimum) {
    if (!isfinite(logicalMaximum) || logicalMaximum < 64.0) return 0.0;
    // Scene request v1 has a 4096-point representable ceiling. An AppKit
    // sentinel such as 16384 must not invalidate the entire initial request.
    return MIN(4096.0, MAX(minimum, round(logicalMaximum * density + chrome)));
}

// Publish the AppKit geometry before UIKit asks FrontBoard to create a Scene.
// SpringBoard can then use it as an input to its normal initial AppLayout/grid
// transaction instead of replacing the visible layout several seconds later.
// Both AppKit and UIKit dimensions here are logical points; the compact
// semantic menu and the requesting display's live status-bar height are the
// only Host chrome outside the streamed AppKit content.
static NSDictionary *MacWSPublishInitialSceneSizeRequest(
        UIScene *requestingScene, uint32_t windowID, int32_t ownerPID,
        CGSize preferredSize, CGSize minimumSize, CGSize maximumSize, BOOL resizable,
        BOOL fixedWidth, BOOL fixedHeight) {
    if (!MacWSWindowingInitialSizeBridgeIsLoaded() ||
        !isfinite(preferredSize.width) || !isfinite(preferredSize.height) ||
        preferredSize.width < 64.0 || preferredSize.height < 64.0)
        return nil;

    MacWSHostDisplayDensity density = (MacWSHostDisplayDensity)
        [NSUserDefaults.standardUserDefaults integerForKey:
            @"MacWSDisplayDensity"];
    density = MacWSNormalizedDisplayDensity(density);
    CGFloat densityScale = MacWSDensityModeFactor(density);
    CGFloat systemTop = 0.0;
    if ([requestingScene isKindOfClass:UIWindowScene.class]) {
        UIWindowScene *windowScene = (UIWindowScene *)requestingScene;
        systemTop = windowScene.statusBarManager.statusBarFrame.size.height;
        for (UIWindow *window in windowScene.windows)
            systemTop = MAX(systemTop, window.safeAreaInsets.top);
    }
    // Target iPad13,6/20D67 reports a 24-point status-bar inset for ordinary
    // Stage Manager windows. A fullscreen requesting Scene legitimately has a
    // zero inset, but the new Standard Scene receives the ordinary inset. Use
    // UIScreen's 24-point native top inset as the bounded pre-connection value
    // only in that case; the postcondition below still records any mismatch.
    if (systemTop < 1.0) systemTop = 24.0;
    CGFloat chromeHeight = MacWSNativeMenuBarHeight + systemTop;
    CGSize target = CGSizeMake(
        preferredSize.width * densityScale,
        preferredSize.height * densityScale + chromeHeight);
    CGSize minimum = CGSizeMake(
        ceil(MAX(150.0, minimumSize.width * densityScale)),
        ceil(MAX(150.0, minimumSize.height * densityScale + chromeHeight)));
    BOOL effectiveFixedWidth = !resizable || fixedWidth;
    BOOL effectiveFixedHeight = !resizable || fixedHeight;
    if (effectiveFixedWidth) minimum.width = ceil(target.width);
    if (effectiveFixedHeight) minimum.height = ceil(target.height);
    target.width = MacWSWindowSceneExtentAtLeastMinimum(target.width, minimum.width);
    target.height = MacWSWindowSceneExtentAtLeastMinimum(target.height, minimum.height);
    CGSize maximum = CGSizeMake(
        effectiveFixedWidth ? target.width : MacWSSceneMaximumAxis(
            maximumSize.width, densityScale, 0.0, minimum.width),
        effectiveFixedHeight ? target.height : MacWSSceneMaximumAxis(
            maximumSize.height, densityScale, chromeHeight, minimum.height));

    NSString *nonce = NSUUID.UUID.UUIDString;
    NSString *path = [MacWSResizeRequestDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"%@%@.plist", MacWSInitialSizeRequestPrefix, nonce]];
    NSDictionary *request = @{
        @"version": @1,
        @"bundle_identifier": NSBundle.mainBundle.bundleIdentifier ?:
            @"com.macwsguide.host",
        @"window_id": @(windowID),
        @"owner_pid": @(ownerPID),
        @"activation_nonce": nonce,
        @"target_width": @(target.width),
        @"target_height": @(target.height),
        @"minimum_width": @(minimum.width),
        @"minimum_height": @(minimum.height),
        @"maximum_width": @(maximum.width),
        @"maximum_height": @(maximum.height),
        @"fixed_width": @(effectiveFixedWidth),
        @"fixed_height": @(effectiveFixedHeight),
        @"issued_at": @(NSDate.date.timeIntervalSince1970),
    };
    if (![request writeToFile:path atomically:YES]) return nil;
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        MacWSRequestInitialSizeNotification, NULL, NULL, true);
    MacWSLog(@"scene-initial-size published nonce=%@ owner=%d window=%u preferred=%.1fx%.1f target=%.1fx%.1f minimum=%.1fx%.1f fixed=%@x%@ density=%.3f chrome-height=%.1f",
        nonce, ownerPID, windowID, preferredSize.width, preferredSize.height,
        target.width, target.height, minimum.width, minimum.height,
        effectiveFixedWidth ? @"YES" : @"NO",
        effectiveFixedHeight ? @"YES" : @"NO",
        densityScale, chromeHeight);
    return @{
        @"initial_scene_size_published": @YES,
        @"initial_scene_size_nonce": nonce,
        @"initial_scene_window_id": @(windowID),
        @"initial_scene_owner_pid": @(ownerPID),
        @"initial_scene_width": @(target.width),
        @"initial_scene_height": @(target.height),
        @"initial_scene_minimum_width": @(minimum.width),
        @"initial_scene_minimum_height": @(minimum.height),
    };
}

static NSString *MacWSLocalizedPhase(NSString *phase) {
    if (!MacWSControlCenterUsesEnglish() || phase.length == 0) return phase;
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        translations = @{
            @"就绪": @"Ready",
            @"操作失败": @"Operation Failed",
            @"检查并修复启动环境…": @"Checking and repairing the environment…",
            @"等待 WindowServer、触控与窗口流…": @"Waiting for WindowServer, touch, and window streaming…",
            @"停止 macOS GUI…": @"Stopping the macOS GUI…",
            @"停止工作区并修复启动环境…": @"Stopping and repairing the workspace…",
            @"重新签名并恢复信任缓存…": @"Re-signing and restoring the trust cache…",
            @"执行安全恢复…": @"Running safe recovery…",
            @"启动 macOS 应用…": @"Launching a macOS app…",
            @"启动 macOS 路径…": @"Launching a macOS path…",
            @"正在验证系统设置扩展运行时…": @"Verifying System Settings extensions…",
            @"正在增量更新系统设置依赖…": @"Updating System Settings dependencies…",
            @"正在完整修复系统设置扩展…": @"Fully repairing System Settings extensions…",
            @"请求刷新共享帧…": @"Requesting a display refresh…",
            @"安全保护已触发": @"Safety protection triggered",
            @"正在生成启动配置…": @"Generating startup configuration…",
            @"正在清理旧的服务状态…": @"Cleaning previous service state…",
            @"正在准备应用运行环境…": @"Preparing the application runtime…",
            @"正在验证图形启动条件…": @"Validating graphics startup requirements…",
            @"正在启动安全保护…": @"Starting safety protection…",
            @"正在启动 macOS 系统服务…": @"Starting macOS system services…",
            @"正在等待第一帧画面…": @"Waiting for the first frame…",
            @"macOS 工作区已就绪": @"macOS workspace is ready",
        };
    });
    return translations[phase] ?: phase;
}

@interface MacWSViewController : UIViewController
    <MacWSMetalViewStatusDelegate, MacWSInteropClientDelegate,
     UIDragInteractionDelegate, UITextFieldDelegate,
     UIDropInteractionDelegate, UIGestureRecognizerDelegate>
- (instancetype)initWithSceneIdentifier:(NSString *)identifier
                              streamMode:(MacWSStreamMode)streamMode
                                windowID:(uint32_t)windowID
                                ownerPID:(int32_t)ownerPID
                          logicalGroupID:(uint32_t)logicalGroupID
                             minimumSize:(CGSize)minimumSize
                             maximumSize:(CGSize)maximumSize
                           preferredSize:(CGSize)preferredSize
                               resizable:(BOOL)resizable
                              fixedWidth:(BOOL)fixedWidth
                             fixedHeight:(BOOL)fixedHeight;
- (void)performURLAction:(NSString *)action;
- (void)resetPerformanceMeasurementForTargetPID:(int32_t)targetPID;
- (void)launchApplicationIdentifier:(NSString *)identifier;
- (void)openExternalDocumentURL:(NSURL *)url;
- (void)setFullscreenWorkspaceEnabled:(BOOL)enabled;
- (void)openWindowInCurrentScene:(MacWSStreamWindow *)window
                          reason:(NSString *)reason;
- (void)openWindowIDInCurrentScene:(uint32_t)windowID
                          ownerPID:(int32_t)ownerPID
                    logicalGroupID:(uint32_t)logicalGroupID
                             title:(NSString *)title
                            reason:(NSString *)reason;
- (void)openRequestedWindowInCurrentScene:(uint32_t)windowID
                                  ownerPID:(int32_t)ownerPID
                            logicalGroupID:(uint32_t)logicalGroupID
                             preferredSize:(CGSize)preferredSize
                               minimumSize:(CGSize)minimumSize
                               maximumSize:(CGSize)maximumSize
                                 resizable:(BOOL)resizable
                                fixedWidth:(BOOL)fixedWidth
                               fixedHeight:(BOOL)fixedHeight
                                     title:(NSString *)title
                                    reason:(NSString *)reason;
- (NSUserActivity *)streamRestorationActivity;
- (void)suspendSceneStream;
- (void)resumeSceneStream;
- (void)requestWindowLifetimeReconciliation;
- (void)cancelBootstrapTerminal;
- (void)sceneGeometryDidChange;
- (void)followNativeSceneSizeForAppliedLogicalSize:(CGSize)logicalSize
                                            reason:(NSString *)reason;
- (void)prepareInitialWindowSceneGeometryForScene:(UIWindowScene *)scene
                                     initialBounds:(CGRect)initialBounds
                              publishedInitialSize:(CGSize)publishedInitialSize
                           publishedMinimumSize:(CGSize)publishedMinimumSize;
- (void)restoreDefaultSceneSizeRestrictions;
- (BOOL)activateCurrentMacWindow;
- (void)synchronizeMacWindowFocusWithReason:(NSString *)reason;
- (void)synchronizeSceneOcclusionWithReason:(NSString *)reason;
- (void)applyDeferredForegroundSceneSize;
- (BOOL)activateMacWindow:(MacWSStreamWindow *)window;
- (BOOL)isFullscreenWorkspace;
- (BOOL)activateMacWindowIDInFullscreenWorkspace:(uint32_t)windowID
                                        ownerPID:(int32_t)ownerPID
                                           title:(NSString *)title;
- (void)reassertFullscreenScenePresentation;
- (void)restoreHardwareKeyboardFocusWithReason:(NSString *)reason;
- (BOOL)forwardHardwarePressEvent:(UIPressesEvent *)event;
- (void)observeHardwareModifiersForEvent:(UIEvent *)event;
- (void)releaseHardwareKeyboardState;
- (void)updateGamePointerLockPreferenceWithReason:(NSString *)reason;
- (void)restoreWorkspaceReturnFromActivity:(NSUserActivity *)activity;
- (BOOL)detachMissingWorkspaceReturnOwnerPID:(int32_t)ownerPID
                                    windowID:(uint32_t)windowID;
@end

static MacWSViewController *MacWSControllerForScene(UIScene *scene) {
    if (![scene isKindOfClass:UIWindowScene.class]) return nil;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
        if ([window.rootViewController isKindOfClass:MacWSViewController.class])
            return (MacWSViewController *)window.rootViewController;
    }
    return nil;
}

static void MacWSScheduleSingleSceneWindowingEnforcement(NSUInteger attempt);

// A fullscreen workspace remains the presentation of the exact AppKit window
// from which it was entered. Resolve that owned identity uniformly anywhere
// Scene lifecycle code needs to deduplicate, prune, close or restore it.
static BOOL MacWSSceneOwnedWindowFields(NSDictionary *info,
                                        int32_t *ownerPIDOut,
                                        uint32_t *windowIDOut,
                                        uint32_t *logicalGroupIDOut) {
    MacWSStreamMode mode = (MacWSStreamMode)[info[@"mode"] unsignedIntValue];
    int32_t ownerPID = 0;
    uint32_t windowID = 0, logicalGroupID = 0;
    if (mode == MacWSStreamModeWindow) {
        ownerPID = [info[@"owner_pid"] intValue];
        windowID = [info[@"window_id"] unsignedIntValue];
        logicalGroupID = [info[@"logical_group_id"] unsignedIntValue];
    } else if (mode == MacWSStreamModeFullscreen) {
        ownerPID = [info[@"return_owner_pid"] intValue];
        windowID = [info[@"return_window_id"] unsignedIntValue];
        logicalGroupID =
            [info[@"return_logical_group_id"] unsignedIntValue];
    }
    if (ownerPID <= 1 || windowID == 0) return NO;
    if (ownerPIDOut) *ownerPIDOut = ownerPID;
    if (windowIDOut) *windowIDOut = windowID;
    if (logicalGroupIDOut) *logicalGroupIDOut = logicalGroupID;
    return YES;
}

static BOOL MacWSSceneIsFullscreenWorkspace(NSDictionary *info) {
    return [info isKindOfClass:NSDictionary.class] &&
        [info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen;
}

// UIWindowSceneActivationRequestOptions is the public activation contract for
// a multi-window UIKit Scene. Runtime evidence from the target showed that a
// Prominent request first connected a new Finder panel in layout role 2 at the
// stock 891x705 size, then moved it to role 1 before the exact-size transaction
// could land. That first transaction necessarily missed and the retry exposed
// the large black-bordered intermediate window. Request the system's Standard
// window role directly. Runtime-confirmed on 20D67 by
// misc/scene_activation_metadata_probe.m: calling the superclass
// -setPreserveLayout: leaves UIWindowSceneActivationRequestOptions'
// independent _preserveLayout value NO (`public=YES window=NO`). Use the
// window-options setter whose getter is carried by this activation object;
// otherwise this request does not preserve the current window arrangement.
static UISceneActivationRequestOptions *MacWSSceneActivationOptions(
        UIScene *requestingScene, BOOL windowed) {
    UISceneActivationRequestOptions *options = nil;
    if (windowed) {
        UIWindowSceneActivationRequestOptions *windowOptions =
            [UIWindowSceneActivationRequestOptions new];
        // Runtime-confirmed by the Standard/Prominent A/B on 20D67:
        // Standard kept the requesting Scene foreground with two connected
        // windows (MacWSHost.log 1789139805.503), while Prominent backgrounded
        // it and left only one foreground window (1789140530.119). Preserve
        // Standard here; per-item geometry is handled by SpringBoard's exact
        // Scene sizing bridge rather than changing activation semantics.
        windowOptions.preferredPresentationStyle =
            UIWindowScenePresentationStyleStandard;
        options = windowOptions;
    } else {
        options = [UISceneActivationRequestOptions new];
    }
    options.requestingScene = requestingScene;
    if (windowed) {
        // These are independent ivars on 20D67. The public value describes
        // the Scene activation request while the UIWindowScene subclass value
        // describes placement of the new window. Runtime probe output after
        // setting both is public=YES/window=YES; setting either one alone
        // leaves the other false.
        options.preserveLayout = YES;
        if ([options respondsToSelector:@selector(_setPreserveLayout:)])
            [(UIWindowSceneActivationRequestOptions *)options
                _setPreserveLayout:YES];
    }
    return options;
}

static void MacWSEnsureRequestedSceneIsForeground(
        UIWindowScene *windowScene, NSUserActivity *activity,
        UIScene *preferredRequestingScene, NSUInteger attempt) {
    if (!windowScene || !windowScene.session || attempt > 2) return;
    if (MacWSCurrentIndependentWindowingState(NULL) !=
            MacWSIndependentWindowingActive) {
        // A stale session restored on pre-Chamois iPadOS can reach this
        // postcondition helper before single-Scene enforcement destroys it.
        // Reactivating that exact session would recreate the Split View column
        // that the new-scene gate is designed to prevent.
        MacWSLog(@"scene-foreground-postcondition skipped id=%@ reason=independent-windowing-inactive",
                 windowScene.session.persistentIdentifier);
        MacWSScheduleSingleSceneWindowingEnforcement(0);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (attempt == 0 ? 250 : 500) * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        UISceneActivationState state = windowScene.activationState;
        if (MacWSCurrentIndependentWindowingState(NULL) !=
                MacWSIndependentWindowingActive) {
            MacWSLog(@"scene-foreground-postcondition skipped id=%@ attempt=%lu reason=independent-windowing-became-inactive",
                     windowScene.session.persistentIdentifier,
                     (unsigned long)attempt);
            MacWSScheduleSingleSceneWindowingEnforcement(0);
            return;
        }
        MacWSLog(@"scene-foreground-postcondition id=%@ attempt=%lu state=%ld",
                 windowScene.session.persistentIdentifier,
                 (unsigned long)attempt, (long)state);
        // A Stage Manager window which coexists with the key window is
        // normally ForegroundInactive, not Background. Retrying activation
        // for that already-visible state asks FrontBoard to rebuild/focus the
        // layout again and can evict the requesting window from the current
        // stage. Only a genuinely background/unattached Scene needs a retry.
        if (state == UISceneActivationStateForegroundActive ||
            state == UISceneActivationStateForegroundInactive) return;

        UIScene *requestingScene = nil;
        if (preferredRequestingScene != windowScene &&
            preferredRequestingScene.activationState ==
                UISceneActivationStateForegroundActive) {
            requestingScene = preferredRequestingScene;
        } else {
            for (UIScene *candidate in
                    UIApplication.sharedApplication.connectedScenes) {
                if (candidate != windowScene && candidate.activationState ==
                        UISceneActivationStateForegroundActive) {
                    requestingScene = candidate;
                    break;
                }
            }
        }
        BOOL windowed = [activity.userInfo[@"mode"] unsignedIntValue] ==
            MacWSStreamModeWindow;
        UISceneActivationRequestOptions *options =
            MacWSSceneActivationOptions(requestingScene ?: windowScene,
                                        windowed);
        [UIApplication.sharedApplication
            requestSceneSessionActivation:windowScene.session
            userActivity:activity
            options:options
            errorHandler:^(NSError *error) {
                MacWSLog(@"scene-foreground-retry failed id=%@ attempt=%lu error=%@",
                         windowScene.session.persistentIdentifier,
                         (unsigned long)attempt, error);
            }];
        MacWSLog(@"scene-foreground-retry requested id=%@ attempt=%lu source=%@",
                 windowScene.session.persistentIdentifier,
                 (unsigned long)attempt,
                 requestingScene.session.persistentIdentifier ?: @"self");
        MacWSEnsureRequestedSceneIsForeground(
            windowScene, activity, requestingScene, attempt + 1);
    });
}

static void MacWSRequestNewScene(UIScene *requestingScene,
                                 uint32_t windowID,
                                 int32_t ownerPID,
                                 uint32_t logicalGroupID,
                                 CGSize preferredSize,
                                 CGSize minimumSize,
                                 CGSize maximumSize,
                                 BOOL resizable,
                                 BOOL fixedWidth,
                                 BOOL fixedHeight,
                                 NSString *title,
                                 BOOL activateExistingForeground,
                                 void (^failureHandler)(NSError *error)) {
    UIApplication *application = UIApplication.sharedApplication;
    uint64_t windowingState = 0;
    MacWSIndependentWindowingState independentWindowing =
        MacWSCurrentIndependentWindowingState(&windowingState);
    if (independentWindowing != MacWSIndependentWindowingActive) {
        // Runtime-confirmed on iPad14,5 / 20A8372: UIKit reports
        // supportsMultipleScenes=YES while a requested 700-point window lands
        // as a 678x1024 Split View column. SpringBoard's live Chamois state is
        // the authority for independent floating Scenes. Reuse the current
        // Scene when it is inactive (or not yet known) instead of requesting
        // a layout mode this OS is not currently presenting.
        MacWSViewController *controller =
            MacWSControllerForScene(requestingScene);
        NSString *reason = independentWindowing ==
                MacWSIndependentWindowingInactive
            ? @"当前系统未启用台前调度，已在同一个 macPad 窗口中切换，避免误入分屏。"
            : @"正在确认系统窗口模式，已先在当前 macPad 窗口中打开，避免误入分屏。";
        if (controller) {
            if (windowID != 0) {
                [controller openRequestedWindowInCurrentScene:windowID
                    ownerPID:ownerPID logicalGroupID:logicalGroupID
                    preferredSize:preferredSize minimumSize:minimumSize
                    maximumSize:maximumSize resizable:resizable
                    fixedWidth:fixedWidth fixedHeight:fixedHeight
                    title:title reason:reason];
            } else {
                // `macwshost://new` with no exact window asks for another
                // fullscreen workspace Scene.  Reuse is still required on a
                // pre-Chamois system; the idempotent setter cannot toggle an
                // already-fullscreen controller back to window mode.
                [controller setFullscreenWorkspaceEnabled:YES];
            }
            MacWSLog(@"scene-activation reused-current reason=independent-windowing-%@ supportsMultiple=%@ state=%#llx window=%u owner=%d",
                independentWindowing == MacWSIndependentWindowingInactive
                    ? @"inactive" : @"unknown",
                application.supportsMultipleScenes ? @"YES" : @"NO",
                (unsigned long long)windowingState, windowID, ownerPID);
            MacWSScheduleSingleSceneWindowingEnforcement(0);
        } else if (failureHandler) {
            NSError *error = [NSError errorWithDomain:
                @"MacWSWindowingErrorDomain" code:1 userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"当前 iPadOS 窗口不支持独立 macPad Scene，且没有可复用的活动窗口。"
                }];
            failureHandler(error);
        }
        return;
    }
    NSString *creationIdentity = MacWSWindowIdentity(ownerPID, windowID, logicalGroupID);
    __block NSNumber *creationStarted = nil;
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = title.length ? title : @"MacWS Workspace";
    NSMutableDictionary *activityInfo = [@{
        @"mode": @(windowID ? MacWSStreamModeWindow : MacWSStreamModeFullscreen),
        @"window_id": @(windowID),
        @"owner_pid": @(windowID ? ownerPID : 0),
        @"logical_group_id": @(windowID ? logicalGroupID : 0),
        @"preferred_width": @(windowID ? preferredSize.width : 0),
        @"preferred_height": @(windowID ? preferredSize.height : 0),
        @"minimum_width": @(windowID ? minimumSize.width : 0),
        @"minimum_height": @(windowID ? minimumSize.height : 0),
        @"maximum_width": @(windowID ? maximumSize.width : 0),
        @"maximum_height": @(windowID ? maximumSize.height : 0),
        @"resizable": @(windowID ? resizable : NO),
        @"fixed_width": @(windowID ? fixedWidth : NO),
        @"fixed_height": @(windowID ? fixedHeight : NO),
        @"title": activity.title,
        // A user action or a newly discovered AppKit document requested this
        // Scene for immediate presentation.  Preserve that intent through
        // willConnectToSession:, where UIKit has finally created a concrete
        // UIWindowScene whose foreground state can be verified.
        @"foreground_on_connect": @YES,
    } mutableCopy];
    activity.userInfo = activityInfo;
    UISceneSession *existingSession = nil;
    if (windowID != 0 && ownerPID > 1) {
        for (UISceneSession *session in application.openSessions) {
            NSUserActivity *candidate = session.stateRestorationActivity;
            for (UIScene *scene in application.connectedScenes) {
                if (scene.session != session ||
                    ![scene isKindOfClass:UIWindowScene.class]) continue;
                UIViewController *root = ((UIWindowScene *)scene).windows.firstObject
                    .rootViewController;
                if ([root isKindOfClass:MacWSViewController.class])
                    candidate = [(MacWSViewController *)root
                        streamRestorationActivity];
                break;
            }
            NSDictionary *info = candidate.userInfo;
            int32_t candidateOwner = 0;
            uint32_t candidateWindow = 0, candidateGroup = 0;
            if (!MacWSSceneOwnedWindowFields(info, &candidateOwner,
                    &candidateWindow, &candidateGroup) ||
                candidateOwner != ownerPID) continue;
            BOOL sameIdentity = logicalGroupID != 0 && candidateGroup != 0
                ? logicalGroupID == candidateGroup
                : windowID == candidateWindow;
            if (sameIdentity) {
                existingSession = session;
                break;
            }
        }
    }
    MacWSLog(@"scene-activation requested supportsMultiple=%@ connected=%lu open=%lu origin=%@ window=%u",
             application.supportsMultipleScenes ? @"YES" : @"NO",
             (unsigned long)application.connectedScenes.count,
             (unsigned long)application.openSessions.count,
             requestingScene.session.persistentIdentifier, windowID);
    if (existingSession) {
        if (!activateExistingForeground) {
            for (UIScene *candidate in application.connectedScenes) {
                if (candidate.session == existingSession &&
                    (candidate.activationState == UISceneActivationStateForegroundActive ||
                     candidate.activationState == UISceneActivationStateForegroundInactive)) {
                    // The launch completion and catalog discovery can both
                    // observe the same new window. Runtime: Terminal 193 was
                    // reactivated 115 ms after its Scene connected. A visible
                    // result already satisfies either automatic observer;
                    // a second placement transaction is not needed.
                    MacWSLog(@"scene-activation coalesced window=%u id=%@ reason=automatic-already-visible",
                             windowID, existingSession.persistentIdentifier);
                    return;
                }
            }
        }
        MacWSLog(@"scene-activation reusing id=%@ owner=%d group=%u window=%u",
                 existingSession.persistentIdentifier, ownerPID,
                 logicalGroupID, windowID);
    } else if (windowID != 0) {
        if (creationIdentity && MacWSSceneCreationsInFlight[creationIdentity]) {
            MacWSLog(@"scene-activation coalesced window=%u identity=%@ reason=creation-in-flight",
                     windowID, creationIdentity);
            return;
        }
        if (creationIdentity) {
            if (!MacWSSceneCreationsInFlight)
                MacWSSceneCreationsInFlight = [NSMutableDictionary dictionary];
            creationStarted = @(CACurrentMediaTime());
            MacWSSceneCreationsInFlight[creationIdentity] = creationStarted;
            // Covers the gap before a new UISceneSession is observable.
            // A real connection or explicit error retires this entry first;
            // the bounded expiry permits recovery if UIKit supplies neither.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                if ([MacWSSceneCreationsInFlight[creationIdentity]
                        isEqual:creationStarted])
                    [MacWSSceneCreationsInFlight removeObjectForKey:creationIdentity];
            });
        }
        NSDictionary *initialSize = MacWSPublishInitialSceneSizeRequest(
            requestingScene, windowID, ownerPID, preferredSize, minimumSize, maximumSize,
            resizable, fixedWidth, fixedHeight);
        if (initialSize.count) {
            [activityInfo addEntriesFromDictionary:initialSize];
            activity.userInfo = activityInfo;
        }
    }
    UISceneActivationRequestOptions *options =
        MacWSSceneActivationOptions(requestingScene, windowID != 0);
    BOOL publicPreserve = windowID != 0 && options.preserveLayout;
    BOOL windowPreserve = windowID != 0 &&
        [options respondsToSelector:@selector(_preserveLayout)] &&
        [(UIWindowSceneActivationRequestOptions *)options _preserveLayout];
    NSString *originSessionIdentifier =
        requestingScene.session.persistentIdentifier ?: @"none";
    MacWSLog(@"scene-activation options window=%u public-preserve=%@ window-preserve=%@ origin-state=%ld",
             windowID, publicPreserve ? @"YES" : @"NO",
             windowPreserve ? @"YES" : @"NO",
             (long)requestingScene.activationState);
    [application requestSceneSessionActivation:existingSession
                                  userActivity:activity
                                       options:options
                                  errorHandler:^(NSError *error) {
        MacWSLog(@"scene-activation failed: %@", error);
        if (creationIdentity && creationStarted &&
            [MacWSSceneCreationsInFlight[creationIdentity] isEqual:creationStarted])
            [MacWSSceneCreationsInFlight removeObjectForKey:creationIdentity];
        if (failureHandler) failureHandler(error);
    }];
    if (!existingSession && windowID != 0) {
        // Preserve-layout is meaningful only if the requesting Scene remains
        // in the same foreground Stage Manager set after the new Scene has
        // connected. Record that concrete postcondition rather than treating
        // the two option bits as proof that SpringBoard honored them.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     900 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            NSUInteger foregroundWindowScenes = 0;
            UISceneActivationState originState =
                UISceneActivationStateUnattached;
            for (UIScene *candidate in application.connectedScenes) {
                if ([candidate isKindOfClass:UIWindowScene.class] &&
                    (candidate.activationState ==
                         UISceneActivationStateForegroundActive ||
                     candidate.activationState ==
                         UISceneActivationStateForegroundInactive))
                    foregroundWindowScenes++;
                if ([candidate.session.persistentIdentifier
                        isEqualToString:originSessionIdentifier])
                    originState = candidate.activationState;
            }
            MacWSLog(@"scene-activation layout-postcondition window=%u origin=%@ origin-state=%ld foreground-window-scenes=%lu",
                     windowID, originSessionIdentifier, (long)originState,
                     (unsigned long)foregroundWindowScenes);
        });
    }
    if (existingSession) {
        // willConnectToSession: does not run when a document belongs to an
        // already connected background Scene. Verify that reuse path here as
        // well, otherwise opening the same Finder item can update the AppKit
        // window without bringing its existing iPadOS window to the front.
        for (UIScene *candidate in application.connectedScenes) {
            if (candidate.session != existingSession ||
                ![candidate isKindOfClass:UIWindowScene.class]) continue;
            MacWSEnsureRequestedSceneIsForeground(
                (UIWindowScene *)candidate, activity, requestingScene, 0);
            break;
        }
    }
}

// A fullscreen Scene is a Primary AppLayout.  On iPadOS 16, asking
// SpringBoard to mutate that existing layout back to Center accepts the
// transaction but leaves the UIWindow panel-sized (runtime-confirmed by the
// resize-postcondition witness).  A newly activated ordinary window Scene,
// however, is placed by the system in the current Stage Manager layout.  Use
// that native lifecycle for the return transition and transfer ownership of
// the exact AppKit window; never close it while the old fullscreen Scene is
// being discarded.
static BOOL MacWSRequestWindowedReplacementScene(
        UIScene *requestingScene, uint32_t windowID, int32_t ownerPID,
        uint32_t logicalGroupID, CGSize preferredSize, CGSize minimumSize, CGSize maximumSize,
        BOOL resizable, BOOL fixedWidth, BOOL fixedHeight, NSString *title,
        void (^failureHandler)(NSError *error)) {
    if (MacWSCurrentIndependentWindowingState(NULL) !=
            MacWSIndependentWindowingActive) {
        // The caller already has an in-place restoration path. Use it when
        // SpringBoard is not presenting independent Chamois windows.
        return NO;
    }
    UISceneSession *oldSession = requestingScene.session;
    NSString *oldIdentifier = oldSession.persistentIdentifier;
    if (!oldSession || !oldIdentifier.length || windowID == 0 || ownerPID <= 1)
        return NO;

    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = title.length ? title : @"MacWS Window";
    NSMutableDictionary *activityInfo = [@{
        @"mode": @(MacWSStreamModeWindow),
        @"window_id": @(windowID),
        @"owner_pid": @(ownerPID),
        @"logical_group_id": @(logicalGroupID),
        @"preferred_width": @(preferredSize.width),
        @"preferred_height": @(preferredSize.height),
        @"minimum_width": @(minimumSize.width),
        @"minimum_height": @(minimumSize.height),
        @"maximum_width": @(maximumSize.width),
        @"maximum_height": @(maximumSize.height),
        @"resizable": @(resizable),
        @"fixed_width": @(fixedWidth),
        @"fixed_height": @(fixedHeight),
        @"title": activity.title,
        @"replaces_session_identifier": oldIdentifier,
    } mutableCopy];
    NSDictionary *initialSize = MacWSPublishInitialSceneSizeRequest(
        requestingScene, windowID, ownerPID, preferredSize, minimumSize, maximumSize,
        resizable, fixedWidth, fixedHeight);
    if (initialSize.count)
        [activityInfo addEntriesFromDictionary:initialSize];
    activity.userInfo = activityInfo;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    [MacWSSceneSessionsPreservingMacWindow addObject:oldIdentifier];

    UISceneActivationRequestOptions *options =
        MacWSSceneActivationOptions(requestingScene, YES);
    MacWSLog(@"scene-windowed-replacement requested old=%@ owner=%d window=%u group=%u preferred=%.1fx%.1f route=new-system-window-scene",
             oldIdentifier, ownerPID, windowID, logicalGroupID,
             preferredSize.width, preferredSize.height);
    [UIApplication.sharedApplication
        requestSceneSessionActivation:nil userActivity:activity options:options
        errorHandler:^(NSError *error) {
            [MacWSSceneSessionsPreservingMacWindow removeObject:oldIdentifier];
            MacWSLog(@"scene-windowed-replacement failed old=%@ error=%@",
                     oldIdentifier, error);
            if (failureHandler) failureHandler(error);
        }];
    return YES;
}

static BOOL MacWSWindowingFullscreenBridgeIsLoaded(void) {
    return MacWSWindowingLiveCapabilities(MacWSWindowingFullscreen, NULL);
}

static BOOL MacWSWindowingResizeBridgeIsLoaded(void) {
    return MacWSWindowingLiveCapabilities(
        MacWSWindowingResize | MacWSWindowingSceneConstraints, NULL);
}

static BOOL MacWSRequestNativeSceneSizeWithRole(UIWindowScene *scene,
                                                CGSize preferredSize,
                                                CGSize minimumSize,
                                                CGSize maximumSize,
                                                BOOL fixedWidth,
                                                BOOL fixedHeight,
                                                BOOL requestWindowedRole,
                                                BOOL policyOnly,
                                                void (^completion)(
                                                    CGSize actualSize,
                                                    BOOL landed)) {
    if (!scene || !scene.session || !isfinite(preferredSize.width) ||
        !isfinite(preferredSize.height) || preferredSize.width < 150.0 ||
        preferredSize.height < 150.0) {
        return NO;
    }
    if (!MacWSWindowingResizeBridgeIsLoaded()) {
        MacWSLog(@"scene-native-size unavailable id=%@ requested=%.1fx%.1f reason=windowing-bridge-not-loaded",
                 scene.session.persistentIdentifier, preferredSize.width,
                 preferredSize.height);
        return NO;
    }

    NSString *sceneIdentifier = [scene respondsToSelector:
        @selector(_sceneIdentifier)] ? [scene _sceneIdentifier] : nil;
    if (sceneIdentifier.length == 0) {
        MacWSLog(@"scene-native-size unavailable id=%@ requested=%.1fx%.1f reason=fbs-scene-identifier-missing",
                 scene.session.persistentIdentifier, preferredSize.width,
                 preferredSize.height);
        return NO;
    }

    NSString *nonce = NSUUID.UUID.UUIDString;
    NSString *path = [MacWSResizeRequestDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"%@%@.plist", MacWSResizeRequestPrefix, nonce]];
    NSDictionary *request = @{
        @"version": @1,
        @"bundle_identifier": NSBundle.mainBundle.bundleIdentifier ?:
            @"com.macwsguide.host",
        @"scene_identifier": sceneIdentifier,
        @"session_identifier": scene.session.persistentIdentifier ?: @"",
        @"width": @(MacWSWindowSceneExtentAtLeastMinimum(preferredSize.width, minimumSize.width)),
        @"height": @(MacWSWindowSceneExtentAtLeastMinimum(preferredSize.height, minimumSize.height)),
        @"minimum_width": @(ceil(minimumSize.width)),
        @"minimum_height": @(ceil(minimumSize.height)),
        @"maximum_width": @(MAX(ceil(minimumSize.width), round(maximumSize.width))),
        @"maximum_height": @(MAX(ceil(minimumSize.height), round(maximumSize.height))),
        @"policy_only": @(policyOnly),
        @"fixed_width": @(fixedWidth),
        @"fixed_height": @(fixedHeight),
        @"windowed_role": @(requestWindowedRole),
        @"issued_at": @(NSDate.date.timeIntervalSince1970),
        @"nonce": nonce,
    };
    BOOL wrote = [request writeToFile:path atomically:YES];
    if (!wrote) {
        MacWSLog(@"scene-native-size unavailable id=%@ fbs=%@ requested=%.1fx%.1f reason=request-write-failed",
                 scene.session.persistentIdentifier, sceneIdentifier,
                 preferredSize.width, preferredSize.height);
        return NO;
    }

    MacWSDiagnosticLog(@"scene-native-size requested id=%@ fbs=%@ requested=%.1fx%.1f minimum=%.1fx%.1f fixed=%@x%@ windowed-role=%@ route=SBMainWorkspace",
             scene.session.persistentIdentifier, sceneIdentifier,
             preferredSize.width, preferredSize.height,
             minimumSize.width, minimumSize.height,
             fixedWidth ? @"YES" : @"NO",
             fixedHeight ? @"YES" : @"NO",
             requestWindowedRole ? @"YES" : @"NO");
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        MacWSRequestResizeNotification, NULL, NULL, true);
    if (policyOnly) {
        MacWSDiagnosticLog(@"scene-native-policy published id=%@ minimum=%.1fx%.1f maximum=%.1fx%.1f action=constraints-only",
                 scene.session.persistentIdentifier, minimumSize.width,
                 minimumSize.height, maximumSize.width, maximumSize.height);
        return YES;
    }
    __block BOOL completionDelivered = NO;
    void (^samplePostcondition)(BOOL, NSString *) =
        ^(BOOL force, NSString *stage) {
        if (completionDelivered) return;
        // SpringBoard owns this request file until its AppLayout
        // postcondition completes.  An animation-disabled transaction which
        // has already removed the file can be checked promptly; a request
        // still being sampled keeps the historical 1.5-second final bound.
        if (!force && [[NSFileManager defaultManager]
                fileExistsAtPath:path]) return;
        completionDelivered = YES;
        UIWindow *sceneWindow = nil;
        for (UIWindow *candidate in scene.windows) {
            if (candidate.isKeyWindow) {
                sceneWindow = candidate;
                break;
            }
            if (!sceneWindow && !candidate.hidden && candidate.alpha > 0.01)
                sceneWindow = candidate;
        }
        CGRect sceneBounds = sceneWindow ? sceneWindow.bounds
                                         : scene.coordinateSpace.bounds;
        CGRect screenBounds = scene.screen.bounds;
        BOOL fillsScreen = fabs(sceneBounds.size.width - screenBounds.size.width) <= 1.0 &&
            fabs(sceneBounds.size.height - screenBounds.size.height) <= 1.0;
        BOOL landed =
            fabs(sceneBounds.size.width - preferredSize.width) <= 1.5 &&
            fabs(sceneBounds.size.height - preferredSize.height) <= 1.5;
        MacWSDiagnosticLog(@"scene-native-size result id=%@ fbs=%@ requested=%.1fx%.1f windowed-role=%@ fills-screen=%@ bounds=%.1fx%.1f landed=%@ stage=%@",
                 scene.session.persistentIdentifier, sceneIdentifier,
                 preferredSize.width, preferredSize.height,
                 requestWindowedRole ? @"YES" : @"NO",
                 fillsScreen ? @"YES" : @"NO",
                 sceneBounds.size.width, sceneBounds.size.height,
                 landed ? @"YES" : @"NO", stage);
        if (completion) completion(sceneBounds.size, landed);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 350 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        samplePostcondition(NO, @"request-completed-early");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 1500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        samplePostcondition(YES, @"final");
    });
    return YES;
}

static BOOL MacWSRequestCurrentSceneMaximization(
        UIWindowScene *scene, BOOL expectedFullscreen,
        void (^failureHandler)(NSError *error)) {
    if (!scene || !scene.session ||
        scene.activationState != UISceneActivationStateForegroundActive) {
        MacWSLog(@"scene-fullscreen unavailable reason=scene-not-active session=%@",
                 scene.session.persistentIdentifier ?: @"none");
        return NO;
    }

    if (!MacWSWindowingFullscreenBridgeIsLoaded()) {
        MacWSLog(@"scene-fullscreen unavailable reason=windowing-bridge-not-loaded session=%@",
                 scene.session.persistentIdentifier);
        return NO;
    }

    NSString *sceneIdentifier = [scene respondsToSelector:
        @selector(_sceneIdentifier)] ? [scene _sceneIdentifier] : nil;
    if (sceneIdentifier.length == 0) {
        MacWSLog(@"scene-fullscreen unavailable reason=fbs-scene-identifier-missing session=%@",
                 scene.session.persistentIdentifier);
        return NO;
    }

    NSString *nonce = NSUUID.UUID.UUIDString;
    UIWindow *sceneWindow = nil;
    for (UIWindow *candidate in scene.windows) {
        if (candidate.isKeyWindow) {
            sceneWindow = candidate;
            break;
        }
        if (!sceneWindow && !candidate.hidden && candidate.alpha > 0.01)
            sceneWindow = candidate;
    }
    // UIWindowScene.coordinateSpace is panel-sized under Stage Manager even
    // while the actual app window is 1004x807 (runtime-confirmed on scene
    // DCEB78D2).  UIWindow.bounds is the user-visible scene extent and is the
    // only valid source/postcondition for the maximize transaction.
    CGRect sceneBounds = sceneWindow ? sceneWindow.bounds
                                     : scene.coordinateSpace.bounds;
    CGRect screenBounds = scene.screen.bounds;
    BOOL sourceGeometryFullscreen =
        fabs(sceneBounds.origin.x - screenBounds.origin.x) <= 1.0 &&
        fabs(sceneBounds.origin.y - screenBounds.origin.y) <= 1.0 &&
        fabs(sceneBounds.size.width - screenBounds.size.width) <= 1.0 &&
        fabs(sceneBounds.size.height - screenBounds.size.height) <= 1.0;
    NSString *path = [MacWSResizeRequestDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"%@%@.plist", MacWSFullscreenRequestPrefix, nonce]];
    NSDictionary *request = @{
        @"version": @1,
        @"bundle_identifier": NSBundle.mainBundle.bundleIdentifier ?:
            @"com.macwsguide.host",
        @"scene_identifier": sceneIdentifier,
        @"session_identifier": scene.session.persistentIdentifier ?: @"",
        @"expected_fullscreen": @(expectedFullscreen),
        @"source_geometry_fullscreen": @(sourceGeometryFullscreen),
        @"issued_at": @(NSDate.date.timeIntervalSince1970),
        @"nonce": nonce,
    };
    if (![request writeToFile:path atomically:YES]) {
        MacWSLog(@"scene-fullscreen unavailable reason=request-write-failed session=%@ fbs=%@",
                 scene.session.persistentIdentifier, sceneIdentifier);
        return NO;
    }

    MacWSLog(@"scene-maximization requested session=%@ fbs=%@ expected-fullscreen=%@ source-geometry-fullscreen=%@ route=springboard-maximization-toggle-action-17 current-bounds=%@ screen-bounds=%@",
             scene.session.persistentIdentifier, sceneIdentifier,
             expectedFullscreen ? @"YES" : @"NO",
             sourceGeometryFullscreen ? @"YES" : @"NO",
             NSStringFromCGRect(sceneBounds), NSStringFromCGRect(screenBounds));
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        MacWSRequestFullscreenNotification, NULL, NULL, true);

    // The SpringBoard transaction is asynchronous.  A Primary AppLayout is
    // not sufficient evidence of full-screen geometry under Stage Manager;
    // runtime showed Primary/center=0 while this Scene remained 1194x807 on a
    // 1389x970 screen.  Re-sample the owning UIWindowScene after the system
    // action; MacWSWindowing's AppLayout record is a model observation only.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 1500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        BOOL supportsState = [scene respondsToSelector:@selector(isFullScreen)];
        BOOL systemState = supportsState && scene.isFullScreen;
        UIWindow *sceneWindow = nil;
        for (UIWindow *candidate in scene.windows) {
            if (candidate.isKeyWindow) {
                sceneWindow = candidate;
                break;
            }
            if (!sceneWindow && !candidate.hidden && candidate.alpha > 0.01)
                sceneWindow = candidate;
        }
        CGRect sceneBounds = sceneWindow ? sceneWindow.bounds
                                         : scene.coordinateSpace.bounds;
        CGRect screenBounds = scene.screen.bounds;
        BOOL fillsScreen = fabs(sceneBounds.origin.x - screenBounds.origin.x) <= 1.0 &&
            fabs(sceneBounds.origin.y - screenBounds.origin.y) <= 1.0 &&
            fabs(sceneBounds.size.width - screenBounds.size.width) <= 1.0 &&
            fabs(sceneBounds.size.height - screenBounds.size.height) <= 1.0;
        MacWSLog(@"scene-maximization UIKit-observation session=%@ expected-fullscreen=%@ is-fullscreen=%@ fills-screen=%@ bounds=%@ screen=%@ authoritative-postcondition=UIKit-scene-screen-geometry",
                 scene.session.persistentIdentifier,
                 expectedFullscreen ? @"YES" : @"NO",
                 systemState ? @"YES" : @"NO",
                 fillsScreen ? @"YES" : @"NO",
                 NSStringFromCGRect(sceneBounds),
                 NSStringFromCGRect(screenBounds));
        (void)failureHandler;
    });
    return YES;
}

// UIKit's current-session fullscreen activation is the private route closest
// to video/game presentation: it asks FrontBoard to make this exact existing
// session fullscreen rather than resizing a Metal layer.  Earlier builds lost
// the display subscription when FrontBoard reconnected the Scene; the Scene
// ownership and compositor handoff are now persistent, so retry the real
// system request before falling back to the Stage Manager maximization bridge.
static BOOL MacWSRequestCurrentSceneImmersiveFullscreen(
        UIWindowScene *scene, NSUserActivity *activity,
        void (^failureHandler)(NSError *error)) {
    if (!scene || !scene.session ||
        scene.activationState != UISceneActivationStateForegroundActive)
        return NO;
    UISceneActivationRequestOptions *options =
        [UISceneActivationRequestOptions new];
    SEL selector = @selector(_setRequestFullscreen:);
    if (![options respondsToSelector:selector]) return NO;
    [options _setRequestFullscreen:YES];
    options.requestingScene = scene;
    MacWSLog(@"scene-immersive requested session=%@ fbs=%@ route=current-session-activation",
             scene.session.persistentIdentifier,
             [scene respondsToSelector:@selector(_sceneIdentifier)]
                ? [scene _sceneIdentifier] : @"unknown");
    [UIApplication.sharedApplication
        requestSceneSessionActivation:scene.session
        userActivity:activity
        options:options
        errorHandler:^(NSError *error) {
            MacWSLog(@"scene-immersive failed session=%@ error=%@",
                     scene.session.persistentIdentifier, error);
            if (failureHandler) failureHandler(error);
        }];
    return YES;
}

static BOOL MacWSSendCloseWindow(uint32_t windowID, int32_t ownerPID,
                                 int *errorOut) {
    if (windowID == 0 || ownerPID <= 1) {
        if (errorOut) *errorOut = EINVAL;
        return NO;
    }
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindCloseWindow,
        .sceneID = MacWSInputSceneForWindow(windowID, 0),
        .timestamp = CACurrentMediaTime(),
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = ownerPID,
        .source = MacWSInputSourceUnknown,
    };
    return MacWSSendInputRecord(&record, errorOut);
}

static BOOL MacWSSendPerformQuit(int32_t ownerPID, int *errorOut) {
    if (ownerPID <= 1) {
        if (errorOut) *errorOut = EINVAL;
        return NO;
    }
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindPerformQuit,
        .timestamp = CACurrentMediaTime(),
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = ownerPID,
        .source = MacWSInputSourceUnknown,
    };
    return MacWSSendInputRecord(&record, errorOut);
}

static NSString *MacWSWindowIdentity(int32_t ownerPID, uint32_t windowID,
                                     uint32_t logicalGroupID) {
    if (ownerPID <= 1 || windowID == 0) return nil;
    return logicalGroupID != 0
        ? [NSString stringWithFormat:@"%d:g:%u", ownerPID, logicalGroupID]
        : [NSString stringWithFormat:@"%d:w:%u", ownerPID, windowID];
}

static NSDictionary *MacWSPersistedSceneBinding(NSString *identifier) {
    if (!identifier.length) return nil;
    NSDictionary *bindings = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:MacWSSceneBindingsDefaultsKey];
    id value = bindings[identifier];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static void MacWSSetPersistedSceneBinding(NSString *identifier,
                                          NSDictionary *info) {
    if (!identifier.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *bindings = [[defaults
        dictionaryForKey:MacWSSceneBindingsDefaultsKey] mutableCopy] ?:
        [NSMutableDictionary dictionary];
    if (info) bindings[identifier] = info;
    else [bindings removeObjectForKey:identifier];
    [defaults setObject:bindings forKey:MacWSSceneBindingsDefaultsKey];
    // Binding changes are rare lifecycle transactions. Flush them before a
    // possible FrontBoard process eviction so a reconnected Scene does not
    // regress to its original bootstrap activity.
    [defaults synchronize];
}

static NSUserActivity *MacWSPersistedSceneActivity(NSString *identifier) {
    NSDictionary *info = MacWSPersistedSceneBinding(identifier);
    if (!MacWSSceneOwnedWindowFields(info, NULL, NULL, NULL) &&
        !MacWSSceneIsFullscreenWorkspace(info)) return nil;
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = [info[@"title"] isKindOfClass:NSString.class]
        ? info[@"title"] : @"MacWS Window";
    activity.userInfo = info;
    return activity;
}

static NSUserActivity *MacWSRecoverOrphanedWorkspaceActivity(
        UISceneSession *newSession) {
    NSString *newIdentifier = newSession.persistentIdentifier;
    if (!newIdentifier.length) return nil;
    NSDictionary *bindings = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:MacWSSceneBindingsDefaultsKey];
    if (bindings.count == 0) return nil;
    NSString *candidateIdentifier = nil;
    NSDictionary *candidateInfo = nil;
    for (NSString *identifier in bindings) {
        if ([identifier isEqualToString:newIdentifier]) continue;
        NSDictionary *info = [bindings[identifier]
            isKindOfClass:NSDictionary.class] ? bindings[identifier] : nil;
        if ([info[@"mode"] unsignedIntValue] != MacWSStreamModeFullscreen)
            continue;
        int32_t ownerPID = 0;
        BOOL ownsReturnWindow = MacWSSceneOwnedWindowFields(
            info, &ownerPID, NULL, NULL);
        if (ownsReturnWindow) {
            errno = 0;
            if (kill(ownerPID, 0) != 0 && errno == ESRCH) continue;
        }
        // More than one orphaned workspace cannot be assigned safely without
        // a stable token from UIKit. Refuse ambiguity instead of restoring an
        // unrelated AppKit window into the new Scene.
        if (candidateInfo) return nil;
        candidateIdentifier = identifier;
        candidateInfo = info;
    }
    if (!candidateInfo) return nil;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    [MacWSSceneSessionsPreservingMacWindow addObject:candidateIdentifier];
    [MacWSSceneBindings removeObjectForKey:candidateIdentifier];
    MacWSSetPersistedSceneBinding(newIdentifier, candidateInfo);
    MacWSSetPersistedSceneBinding(candidateIdentifier, nil);
    MacWSLog(@"scene-workspace-binding-migrated old=%@ new=%@ return-window=%u owner=%d",
             candidateIdentifier, newIdentifier,
             [candidateInfo[@"return_window_id"] unsignedIntValue],
             [candidateInfo[@"return_owner_pid"] intValue]);
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = [candidateInfo[@"title"] isKindOfClass:NSString.class]
        ? candidateInfo[@"title"] : @"MacWS Workspace";
    activity.userInfo = candidateInfo;
    return activity;
}

// UISceneSession.stateRestorationActivity is not updated continuously while a
// Scene changes from the bootstrap workspace to an exact macOS window. Keep
// the live binding by persistent session identifier, and make closing a
// transaction that is idempotent across the explicit close button,
// didDiscardSceneSessions:, and a late sceneDidDisconnect: callback.
static void MacWSRememberSceneBinding(UISceneSession *session,
                                      NSUserActivity *activity) {
    NSString *identifier = session.persistentIdentifier;
    if (!identifier.length) return;
    if (!MacWSSceneBindings) MacWSSceneBindings = [NSMutableDictionary dictionary];
    if (!MacWSSceneCloseRequestsSent)
        MacWSSceneCloseRequestsSent = [NSMutableSet set];
    // Once this session has committed a close transaction, a late state
    // restoration callback must not resurrect the binding and send a second
    // performClose: while UIKit is tearing the Scene down.
    if ([MacWSSceneCloseRequestsSent containsObject:identifier]) return;
    NSDictionary *info = activity.userInfo;
    int32_t ownerPID = 0;
    uint32_t windowID = 0;
    if (MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, NULL) ||
        MacWSSceneIsFullscreenWorkspace(info)) {
        MacWSSceneBindings[identifier] = activity;
        [MacWSSceneCloseRequestsSent removeObject:identifier];
        MacWSSetPersistedSceneBinding(identifier, info);
    } else {
        [MacWSSceneBindings removeObjectForKey:identifier];
        MacWSSetPersistedSceneBinding(identifier, nil);
    }
}

static BOOL MacWSCloseMacWindowForSceneSession(UISceneSession *session,
                                                NSString *source) {
    NSString *identifier = session.persistentIdentifier;
    if (!identifier.length) return NO;
    if ([MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
        return NO;
    if (!MacWSSceneBindings) MacWSSceneBindings = [NSMutableDictionary dictionary];
    if (!MacWSSceneCloseRequestsSent)
        MacWSSceneCloseRequestsSent = [NSMutableSet set];
    if ([MacWSSceneCloseRequestsSent containsObject:identifier]) return YES;
    NSUserActivity *activity = MacWSSceneBindings[identifier] ?:
        MacWSPersistedSceneActivity(identifier) ?:
        session.stateRestorationActivity;
    NSDictionary *info = activity.userInfo;
    int32_t ownerPID = 0;
    uint32_t windowID = 0, logicalGroupID = 0;
    if (!MacWSSceneOwnedWindowFields(
            info, &ownerPID, &windowID, &logicalGroupID))
        return NO;
    int sendError = 0;
    BOOL sent = MacWSSendCloseWindow(windowID, ownerPID, &sendError);
    if (sent) {
        NSString *windowIdentity = MacWSWindowIdentity(
            ownerPID, windowID, logicalGroupID);
        if (windowIdentity) {
            if (!MacWSClosingWindowIdentities)
                MacWSClosingWindowIdentities = [NSMutableDictionary dictionary];
            MacWSClosingWindowIdentities[windowIdentity] =
                @(CACurrentMediaTime());
            [MacWSObservedWindowIdentities removeObject:windowIdentity];
            [MacWSPendingWindowSceneIdentities removeObject:windowIdentity];
        }
        [MacWSSceneCloseRequestsSent addObject:identifier];
        [MacWSSceneBindings removeObjectForKey:identifier];
        MacWSSetPersistedSceneBinding(identifier, nil);

        // Do not mutate Dock from the Scene teardown. Runtime log
        // 1788447667.111..1788447668.038 proved that the former delayed
        // request explicitly sent SIGTERM to a healthy Dock after VS Code had
        // already exited. The app-session supervisor remains the process-exit
        // authority; the native Dock must keep its own menu/Space lifetime.
    }
    MacWSLog(@"scene-close source=%@ id=%@ window=%u target=%d sent=%@ errno=%d",
             source ?: @"unknown", identifier, windowID, ownerPID,
             sent ? @"YES" : @"NO", sendError);
    return sent;
}

typedef void (^MacWSCompactMenuSelection)(MacWSMenuItem *item);

// UIAlertController action sheets have a fixed iOS row metric and do not
// relayout reliably when actions are appended after presentation. A macOS menu
// snapshot is already a complete immutable tree, so render one compact table
// only after that tree arrives. This keeps every row present on the first
// frame and gives the semantic menu macOS-like density without private UIKit
// APIs.
@interface MacWSCompactMenuController : UIViewController
    <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithItems:(NSArray<MacWSMenuItem *> *)items
                    appearance:(MacWSMenuAppearance)appearance
                     selection:(MacWSCompactMenuSelection)selection;
@end

@implementation MacWSCompactMenuController {
    NSArray<MacWSMenuItem *> *_items;
    MacWSCompactMenuSelection _selection;
    UITableView *_tableView;
}

- (instancetype)initWithItems:(NSArray<MacWSMenuItem *> *)items
                    appearance:(MacWSMenuAppearance)appearance
                     selection:(MacWSCompactMenuSelection)selection {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _items = [items copy];
    _selection = [selection copy];
    self.modalPresentationStyle = UIModalPresentationPopover;
    if (appearance == MacWSMenuAppearanceDark)
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    else if (appearance == MacWSMenuAppearanceLight)
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;

    CGFloat width = 168.0;
    CGFloat height = 2.0;
    NSDictionary *titleAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14.0]
    };
    NSDictionary *shortcutAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:12.0]
    };
    for (MacWSMenuItem *item in _items) {
        if (item.flags & MacWSMenuNodeHidden) continue;
        if (item.flags & MacWSMenuNodeSeparator) {
            height += 8.0;
            continue;
        }
        CGFloat titleWidth = [item.title sizeWithAttributes:titleAttributes].width;
        CGFloat shortcutWidth = [item.shortcut
            sizeWithAttributes:shortcutAttributes].width;
        width = MAX(width, titleWidth + shortcutWidth +
            ((item.flags & MacWSMenuNodeHasSubmenu) ? 60.0 : 48.0));
        height += 29.0;
    }
    self.preferredContentSize = CGSizeMake(MIN(320.0, ceil(width)),
                                            MIN(380.0, ceil(height)));
    return self;
}

- (void)loadView {
    UIView *root = [UIView new];
    root.backgroundColor = UIColor.clearColor;
    UIVisualEffectView *material = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    material.frame = root.bounds;
    material.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                               UIViewAutoresizingFlexibleHeight;
    material.layer.cornerRadius = 10.0;
    material.layer.cornerCurve = kCACornerCurveContinuous;
    material.clipsToBounds = YES;
    [root addSubview:material];
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                               style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.contentInset = UIEdgeInsetsMake(1, 0, 1, 0);
    _tableView.scrollEnabled = self.preferredContentSize.height >= 380.0;
    _tableView.showsVerticalScrollIndicator = _tableView.scrollEnabled;
    _tableView.frame = material.contentView.bounds;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
    _tableView.layer.cornerRadius = 10.0;
    _tableView.clipsToBounds = YES;
    [material.contentView addSubview:_tableView];
    self.view = root;
}

- (NSInteger)tableView:(UITableView *)tableView
  numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)_items.count;
}

- (CGFloat)tableView:(UITableView *)tableView
  heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    MacWSMenuItem *item = _items[(NSUInteger)indexPath.row];
    return (item.flags & MacWSMenuNodeSeparator) ? 8.0 : 29.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MacWSMenuItem *item = _items[(NSUInteger)indexPath.row];
    if (item.flags & MacWSMenuNodeSeparator) {
        UITableViewCell *cell = [tableView
            dequeueReusableCellWithIdentifier:@"MacWSMenuSeparator"];
        if (!cell) {
            cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleDefault
              reuseIdentifier:@"MacWSMenuSeparator"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = UIColor.clearColor;
            UIView *line = [UIView new];
            line.tag = 91;
            line.translatesAutoresizingMaskIntoConstraints = NO;
            line.backgroundColor = UIColor.separatorColor;
            [cell.contentView addSubview:line];
            [NSLayoutConstraint activateConstraints:@[
                [line.leadingAnchor constraintEqualToAnchor:
                    cell.contentView.leadingAnchor constant:8],
                [line.trailingAnchor constraintEqualToAnchor:
                    cell.contentView.trailingAnchor constant:-8],
                [line.centerYAnchor constraintEqualToAnchor:
                    cell.contentView.centerYAnchor],
                [line.heightAnchor constraintEqualToConstant:0.5],
            ]];
        }
        return cell;
    }

    UITableViewCell *cell = [tableView
        dequeueReusableCellWithIdentifier:@"MacWSMenuItem"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                       reuseIdentifier:@"MacWSMenuItem"];
        cell.backgroundColor = UIColor.clearColor;
        cell.textLabel.font = [UIFont systemFontOfSize:14.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
        UIView *selection = [UIView new];
        selection.backgroundColor = UIColor.systemBlueColor;
        cell.selectedBackgroundView = selection;
    }
    NSString *prefix = @"";
    if (item.flags & MacWSMenuNodeChecked) prefix = @"✓  ";
    else if (item.flags & MacWSMenuNodeMixed) prefix = @"—  ";
    cell.textLabel.text = [prefix stringByAppendingString:item.title ?: @""];
    NSString *suffix = item.shortcut ?: @"";
    if (item.flags & MacWSMenuNodeHasSubmenu)
        suffix = suffix.length ? [suffix stringByAppendingString:@"   ›"] : @"›";
    cell.detailTextLabel.text = suffix;
    BOOL enabled = (item.flags & (MacWSMenuNodeEnabled |
                                  MacWSMenuNodeBridgedQuit)) != 0;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.enabled = enabled;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault
                                  : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    MacWSMenuItem *item = _items[(NSUInteger)indexPath.row];
    if ((item.flags & (MacWSMenuNodeHidden | MacWSMenuNodeSeparator)) ||
        (item.flags & (MacWSMenuNodeEnabled |
                       MacWSMenuNodeBridgedQuit)) == 0) return;
    MacWSCompactMenuSelection selection = _selection;
    if (selection) selection(item);
}

@end

@implementation MacWSViewController {
    __weak UIWindowScene *_connectedWindowScene;
    NSString *_sceneIdentifier;
    MacWSStreamMode _streamMode;
    uint32_t _windowID;
    int32_t _windowOwnerPID;
    uint32_t _windowGroupID;
    CGSize _windowMinimumSize;
    CGSize _windowMaximumSize;
    CGSize _windowPreferredSize;
    BOOL _windowResizable;
    BOOL _windowWidthFixed;
    BOOL _windowHeightFixed;
    BOOL _initialSceneSizePending;
    CGSize _publishedInitialSceneSize;
    uint64_t _initialSceneSizePostconditionSerial;
    uint64_t _nativeFocusRequestSerial;
    uint64_t _sceneOcclusionEvaluationSerial;
    CFTimeInterval _lastNativeFocusRequestTime;
    BOOL _sceneStreamSuspendedForOcclusion;
    BOOL _gamePointerLockViewVisible;
    BOOL _lastGamePointerLockPreference;
    BOOL _automaticGamePointerActive;
    MacWSHostInputMode _inputModeBeforeAutomaticGame;
    int32_t _automaticGamePointerPID;
    uint32_t _automaticGamePointerWindowID;
    int32_t _automaticGamePointerSuppressedPID;
    uint32_t _automaticGamePointerSuppressedWindowID;
    uint64_t _automaticGamePointerRevocationSerial;
    CGSize _deferredBackgroundSceneLogicalSize;
    CGSize _deferredAppKitSceneLogicalSize;
    uint32_t _deferredAppKitSceneWindowID;
    int32_t _deferredAppKitSceneOwnerPID;
    uint32_t _deferredBackgroundSceneWindowID;
    int32_t _deferredBackgroundSceneOwnerPID;
    MacWSControlClient *_controlClient;
    MacWSInteropClient *_interopClient;
    MacWSMenuClient *_menuClient;
    MacWSMenuSnapshot *_menuSnapshot;
    UIVisualEffectView *_semanticMenuBar;
    NSLayoutConstraint *_semanticMenuHeightConstraint;
    NSLayoutConstraint *_semanticMenuContentTopConstraint;
    UIScrollView *_semanticMenuScroll;
    UIStackView *_semanticMenuTitles;
    UIViewController *_semanticMenuPanel;
    UIControl *_semanticMenuDismissLayer;
    UIVisualEffectView *_controlPanel;
    UIControl *_controlDismissLayer;
    UIVisualEffectView *_showControlsMaterial;
    UIButton *_showControlsButton;
    UILabel *_serviceLabel;
    UILabel *_phaseLabel;
    UILabel *_rootfsLabel;
    UILabel *_windowServerLabel;
    UILabel *_bridgeLabel;
    UILabel *_frameLabel;
    UILabel *_statusLabel;
    UILabel *_inputLabel;
    UILabel *_interopLabel;
    UILabel *_noticeLabel;
    UILabel *_controlTitleLabel;
    UILabel *_controlSubtitleLabel;
    UILabel *_touchSectionLabel;
    UILabel *_displaySectionLabel;
    UILabel *_performanceSectionLabel;
    UILabel *_applicationsSectionLabel;
    UILabel *_zoomSectionLabel;
    UILabel *_languageSectionLabel;
    UILabel *_startupLogSectionLabel;
    UILabel *_systemHUDTitleLabel;
    UILabel *_systemHUDDetailLabel;
    UIButton *_primaryButton;
    UIButton *_repairDesktopButton;
    UIButton *_repairButton;
    UIButton *_recoverButton;
    UIButton *_captureButton;
    UIButton *_logsButton;
    UIButton *_exportButton;
    UIButton *_windowPickerButton;
    UIButton *_closeWindowButton;
    UIButton *_menuBarButton;
    UIButton *_crossAppDragButton;
    UIButton *_crossAppDragSurface;
    UIButton *_crossAppDragHandle;
    UIVisualEffectView *_crossAppDragHandleMaterial;
    UIView *_crossAppDragHandleTint;
    UIImageView *_crossAppDragHandleBackIcon;
    UIImageView *_crossAppDragHandleMiddleIcon;
    UIImageView *_crossAppDragHandleIcon;
    UILabel *_crossAppDragHandleBadge;
    UILabel *_crossAppDragHandleTitle;
    UIDragInteraction *_contentDragInteraction;
    UITapGestureRecognizer *_crossAppDragPrepareTap;
    UILongPressGestureRecognizer *_crossAppDragTwoFingerHold;
    CGPoint _crossAppDragSelectionPoint;
    BOOL _crossAppDragSelectionPointValid;
    NSArray<NSItemProvider *> *_preparedMacOSDragProviders;
    NSArray<NSURL *> *_preparedMacOSDragURLs;
    BOOL _crossAppDragPreparing;
    uint64_t _crossAppDragPrepareSerial;
    BOOL _crossAppDragArmed;
    BOOL _crossAppDragTransferPending;
    UIButton *_keyboardButton;
    UIButton *_retryStartupButton;
    UITextField *_keyboardProxy;
    BOOL _keyboardProxyResetting;
    UIView *_softwareKeyBar;
    NSLayoutConstraint *_softwareKeyBarHeightConstraint;
    NSLayoutConstraint *_softwareKeyBarTrailingConstraint;
    UITextField *_appSearchField;
    NSArray<UIButton *> *_softModifierButtons;
    uint32_t _softModifiers;
    UITextView *_logsView;
    UISegmentedControl *_inputModeControl;
    UISegmentedControl *_densityControl;
    UISegmentedControl *_presentationResolutionControl;
    UISegmentedControl *_zoomScaleControl;
    UISegmentedControl *_performanceHUDControl;
    UISegmentedControl *_languageControl;
    UISwitch *_systemPerformanceHUDSwitch;
    UIButton *_performanceResetButton;
    UIButton *_performanceExportButton;
    UIButton *_performanceRunButton;
    UIButton *_resetZoomButton;
    NSArray<UIButton *> *_applicationButtons;
    MacWSMetalView *_metalView;
    NSTimer *_statusTimer;
    NSDictionary<NSString *, id> *_latestStatus;
    uint64_t _inputLogSequence;
    NSString *_lastLoggedControlSummary;
    NSString *_lastStartupLog;
    NSArray<MacWSStreamWindow *> *_streamWindows;
    int32_t _pendingFinderWindowPID;
    NSUInteger _pendingFinderMenuAttempts;
    BOOL _finderMenuRequestInFlight;
    int32_t _pendingApplicationWindowPID;
    NSString *_pendingApplicationIdentifier;
    NSUInteger _pendingApplicationWindowAttempts;
    BOOL _pendingApplicationWindowRetryScheduled;
    uint32_t _pendingApplicationCandidateWindowID;
    CFTimeInterval _pendingApplicationCandidateSince;
    uint64_t _constrainedSceneResizeSerial;
    CGSize _lastConstrainedSceneTargetSize;
    CFTimeInterval _lastConstrainedSceneResizeRequestTime;
    BOOL _capturedSceneSizeRestrictions;
    BOOL _reportedSceneSizeRestrictionsUnavailable;
    CGSize _defaultSceneMinimumSize;
    CGSize _defaultSceneMaximumSize;
    CGSize _appliedSceneRestrictionMinimumSize;
    CGSize _appliedSceneRestrictionMaximumSize;
    int32_t _fullscreenCatalogRetainedInputPID;
    BOOL _fullscreenInputTargetDeferredForActiveTransaction;
    uint32_t _fullscreenActivatedInputWindowID;
    int32_t _fullscreenActivatedInputOwnerPID;
    uint32_t _pendingFullscreenActivationWindowID;
    int32_t _pendingFullscreenActivationOwnerPID;
    NSString *_pendingFullscreenActivationTitle;
    CFTimeInterval _pendingFullscreenActivationDeadline;
    BOOL _bootstrapTerminalPending;
    BOOL _bootstrapWindowReplacementPending;
    BOOL _bootstrapWorkspaceStartInFlight;
    BOOL _bootstrapWorkspaceStartAttempted;
    BOOL _targetWindowObservedInCatalog;
    BOOL _targetWindowMissingCheckPending;
    BOOL _sceneDestructionRequested;
    uint64_t _targetWindowMissingSerial;
    BOOL _workspaceReturnValid;
    uint32_t _workspaceReturnWindowID;
    int32_t _workspaceReturnOwnerPID;
    uint32_t _workspaceReturnGroupID;
    CGSize _workspaceReturnMinimumSize;
    CGSize _workspaceReturnMaximumSize;
    CGSize _workspaceReturnPreferredSize;
    CGSize _workspaceReturnSceneSize;
    BOOL _workspaceReturnResizable;
    BOOL _workspaceReturnWidthFixed;
    BOOL _workspaceReturnHeightFixed;
    NSString *_workspaceReturnTitle;
}

- (BOOL)prefersStatusBarHidden {
    return _streamMode == MacWSStreamModeFullscreen;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return _streamMode == MacWSStreamModeFullscreen;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return _streamMode == MacWSStreamModeFullscreen
        ? UIRectEdgeAll : UIRectEdgeNone;
}

- (void)updateImmersivePresentation {
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    BOOL expected = _streamMode == MacWSStreamModeFullscreen;
    for (NSNumber *delay in @[@0, @250, @1250]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     delay.longLongValue * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UIWindowScene *scene = self.view.window.windowScene;
            BOOL actualStatusHidden = scene.statusBarManager.statusBarHidden;
            MacWSDiagnosticLog(@"immersive-postcondition expected=%@ status-request=%@ status-hidden=%@ home-indicator-auto-hide=%@ deferred-edges=%lu bounds=%@ screen=%@ safe-insets=%@",
                     expected ? @"YES" : @"NO",
                     self.prefersStatusBarHidden ? @"YES" : @"NO",
                     actualStatusHidden ? @"YES" : @"NO",
                     self.prefersHomeIndicatorAutoHidden ? @"YES" : @"NO",
                     (unsigned long)self.preferredScreenEdgesDeferringSystemGestures,
                     NSStringFromCGRect(scene.coordinateSpace.bounds),
                     NSStringFromCGRect(scene.screen.bounds),
                     NSStringFromUIEdgeInsets(self.view.safeAreaInsets));
        });
    }
}

- (void)updateWorkspaceChrome {
    BOOL fullscreen = _streamMode == MacWSStreamModeFullscreen;
    _semanticMenuBar.hidden = fullscreen;
    CGFloat safeTop = MAX(0.0, self.view.safeAreaInsets.top);
    _semanticMenuHeightConstraint.constant = fullscreen ? 0.0 :
        MacWSNativeMenuBarHeight + safeTop;
    _semanticMenuContentTopConstraint.constant = fullscreen ? 0.0 : safeTop;
    if (_menuBarButton) {
        [self setButton:_menuBarButton
                  title:fullscreen
                      ? MacWSLocalized(@"进入窗口模式", @"Enter Window Mode")
                      : MacWSLocalized(@"打开全屏 macOS 工作区",
                                       @"Open Full-Screen macOS Workspace")
                  image:fullscreen
                      ? @"arrow.down.right.and.arrow.up.left"
                      : @"arrow.up.left.and.arrow.down.right"];
    }
    _closeWindowButton.hidden = fullscreen || _windowID == 0;
    [self.view setNeedsLayout];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    // In Stage Manager the native scene title strip is represented by the
    // top safe-area inset. Extend the same semantic material through it so
    // the scene no longer exposes the root view's black background above the
    // simulated menu bar.
    [self updateWorkspaceChrome];
}

- (void)restoreWorkspaceReturnFromActivity:(NSUserActivity *)activity {
    NSDictionary *info = activity.userInfo;
    BOOL explicitFullscreenRestoration = activity &&
        [info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen;
    if (_streamMode != MacWSStreamModeFullscreen ||
        !explicitFullscreenRestoration) return;

    // An explicit restored workspace remains a real desktop even when its
    // optional return AppKit window is already gone.  The old early return
    // left both bootstrap flags set whenever return_window_id was zero, so the
    // next Maps/Terminal catalog entry converted the live fullscreen Scene
    // into a per-window Scene.  A nil activity still represents the genuine
    // first-launch placeholder and deliberately keeps these flags set.
    _bootstrapTerminalPending = NO;
    _bootstrapWindowReplacementPending = NO;
    if ([info[@"return_window_id"] unsignedIntValue] == 0 ||
        [info[@"return_owner_pid"] intValue] <= 1) return;
    _workspaceReturnValid = YES;
    _workspaceReturnWindowID = [info[@"return_window_id"] unsignedIntValue];
    _workspaceReturnOwnerPID = [info[@"return_owner_pid"] intValue];
    _workspaceReturnGroupID = [info[@"return_logical_group_id"] unsignedIntValue];
    _workspaceReturnMinimumSize = CGSizeMake(
        [info[@"return_minimum_width"] doubleValue],
        [info[@"return_minimum_height"] doubleValue]);
    _workspaceReturnMaximumSize = CGSizeMake(
        [info[@"return_maximum_width"] doubleValue],
        [info[@"return_maximum_height"] doubleValue]);
    _workspaceReturnPreferredSize = CGSizeMake(
        [info[@"return_preferred_width"] doubleValue],
        [info[@"return_preferred_height"] doubleValue]);
    _workspaceReturnSceneSize = CGSizeMake(
        [info[@"return_scene_width"] doubleValue],
        [info[@"return_scene_height"] doubleValue]);
    _workspaceReturnResizable = [info[@"return_resizable"] boolValue];
    _workspaceReturnWidthFixed = !_workspaceReturnResizable ||
        [info[@"return_fixed_width"] boolValue];
    _workspaceReturnHeightFixed = !_workspaceReturnResizable ||
        [info[@"return_fixed_height"] boolValue];
    _workspaceReturnTitle = [info[@"return_title"] isKindOfClass:NSString.class]
        ? [info[@"return_title"] copy] : @"MacWS Window";
}

- (BOOL)detachMissingWorkspaceReturnOwnerPID:(int32_t)ownerPID
                                    windowID:(uint32_t)windowID {
    if (_streamMode != MacWSStreamModeFullscreen ||
        !_workspaceReturnValid || _workspaceReturnOwnerPID != ownerPID ||
        _workspaceReturnWindowID != windowID) return NO;

    // The return window is navigation history, not the owner of the full
    // desktop stream.  If that AppKit process exits while the workspace is
    // visible, preserve the compositor subscription and merely make the
    // transition back to that exact window unavailable.
    _workspaceReturnValid = NO;
    _workspaceReturnWindowID = 0;
    _workspaceReturnOwnerPID = 0;
    _workspaceReturnGroupID = 0;
    _workspaceReturnMinimumSize = CGSizeZero;
    _workspaceReturnMaximumSize = CGSizeZero;
    _workspaceReturnPreferredSize = CGSizeZero;
    _workspaceReturnSceneSize = CGSizeZero;
    _workspaceReturnResizable = NO;
    _workspaceReturnWidthFixed = NO;
    _workspaceReturnHeightFixed = NO;
    _workspaceReturnTitle = nil;
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    [self setNotice:@"来源窗口已关闭；完整 macOS 工作区仍保持运行。"
             success:YES];
    MacWSLog(@"workspace-return-detached owner-missing pid=%d window=%u scene=%@",
             ownerPID, windowID,
             self.view.window.windowScene.session.persistentIdentifier);
    return YES;
}

- (instancetype)initWithSceneIdentifier:(NSString *)identifier
                              streamMode:(MacWSStreamMode)streamMode
                                windowID:(uint32_t)windowID
                                ownerPID:(int32_t)ownerPID
                          logicalGroupID:(uint32_t)logicalGroupID
                             minimumSize:(CGSize)minimumSize
                             maximumSize:(CGSize)maximumSize
                           preferredSize:(CGSize)preferredSize
                               resizable:(BOOL)resizable
                              fixedWidth:(BOOL)fixedWidth
                             fixedHeight:(BOOL)fixedHeight {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _sceneIdentifier = [identifier copy];
        _streamMode = streamMode;
        _windowID = windowID;
        _windowOwnerPID = windowID ? ownerPID : 0;
        _windowGroupID = windowID ? logicalGroupID : 0;
        _windowMinimumSize = windowID ? minimumSize : CGSizeZero;
        _windowMaximumSize = windowID ? maximumSize : CGSizeZero;
        _windowPreferredSize = windowID ? preferredSize : CGSizeZero;
        _windowResizable = windowID ? resizable : NO;
        _windowWidthFixed = windowID && (!resizable || fixedWidth);
        _windowHeightFixed = windowID && (!resizable || fixedHeight);
        _bootstrapTerminalPending = streamMode != MacWSStreamModeWindow ||
            windowID == 0;
        _bootstrapWindowReplacementPending = _bootstrapTerminalPending;
        _controlClient = [MacWSControlClient new];
        _interopClient = [MacWSInteropClient new];
        _interopClient.delegate = self;
        _menuClient = [MacWSMenuClient new];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        // Retired compatibility/debug preferences must not survive upgrades
        // as invisible production feature selectors.
        [defaults removeObjectForKey:@"MacWSExperimentalMode"];
        [defaults removeObjectForKey:@"MacWSLegacyFramebufferFallback"];
    }
    return self;
}

static UILabel *MacWSMakeLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title image:(NSString *)imageName
                        action:(SEL)action prominent:(BOOL)prominent {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = prominent
        ? [UIButtonConfiguration filledButtonConfiguration]
        : [UIButtonConfiguration grayButtonConfiguration];
    // Neutral, adaptive surfaces retain contrast over dark games and bright
    // documents. Reserve the accent for the primary action and selection.
    configuration.baseForegroundColor = prominent ? UIColor.whiteColor
                                                   : UIColor.labelColor;
    configuration.baseBackgroundColor = prominent ? UIColor.systemBlueColor
                                                   : UIColor.secondarySystemFillColor;
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:imageName];
    configuration.imagePadding = 8;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)setButton:(UIButton *)button title:(NSString *)title image:(NSString *)imageName {
    UIButtonConfiguration *configuration = [button.configuration copy];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:imageName];
    button.configuration = configuration;
}

- (UIStackView *)statusRowWithTitle:(NSString *)title
                              value:(UILabel * __strong *)valueOut {
    UILabel *name = MacWSMakeLabel(title,
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline],
        UIColor.secondaryLabelColor);
    UILabel *value = MacWSMakeLabel(@"检查中…",
        [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold],
        UIColor.tertiaryLabelColor);
    value.textAlignment = NSTextAlignmentRight;
    [value setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, value]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionFill;
    if (valueOut) *valueOut = value;
    return row;
}

- (UIView *)divider {
    UIView *line = [UIView new];
    line.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.45];
    [line.heightAnchor constraintEqualToConstant:0.5].active = YES;
    return line;
}

- (UILabel *)sectionTitle:(NSString *)title {
    UILabel *label = MacWSMakeLabel(title.uppercaseString,
        [UIFont systemFontOfSize:11 weight:UIFontWeightBold],
        UIColor.secondaryLabelColor);
    label.accessibilityTraits = UIAccessibilityTraitHeader;
    return label;
}

- (UIButton *)keyboardAccessoryButton:(NSString *)title
                                   tag:(NSInteger)tag
                              modifier:(BOOL)modifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = title;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleSmall;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(7, 10, 7, 10);
    button.configuration = configuration;
    button.tag = tag;
    [button addTarget:self
               action:modifier ? @selector(softModifierTapped:)
                               : @selector(softKeyTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)makeKeyboardAccessoryView {
    UIInputView *input = [[UIInputView alloc]
        initWithFrame:CGRectMake(0, 0, 0, 52)
        inputViewStyle:UIInputViewStyleKeyboard];
    UIButton *escape = [self keyboardAccessoryButton:@"esc" tag:0xff1b
                                             modifier:NO];
    UIButton *control = [self keyboardAccessoryButton:@"control" tag:(1u << 18)
                                              modifier:YES];
    UIButton *option = [self keyboardAccessoryButton:@"option" tag:(1u << 19)
                                             modifier:YES];
    UIButton *command = [self keyboardAccessoryButton:@"⌘" tag:(1u << 20)
                                              modifier:YES];
    UIButton *shift = [self keyboardAccessoryButton:@"⇧" tag:(1u << 17)
                                            modifier:YES];
    UIButton *tab = [self keyboardAccessoryButton:@"tab" tag:0xff09
                                          modifier:NO];
    UIButton *left = [self keyboardAccessoryButton:@"←" tag:0xff51
                                           modifier:NO];
    UIButton *up = [self keyboardAccessoryButton:@"↑" tag:0xff52
                                         modifier:NO];
    UIButton *down = [self keyboardAccessoryButton:@"↓" tag:0xff54
                                           modifier:NO];
    UIButton *right = [self keyboardAccessoryButton:@"→" tag:0xff53
                                            modifier:NO];
    UIButton *dismiss = [self keyboardAccessoryButton:@"键盘↓" tag:0
                                              modifier:NO];
    [dismiss removeTarget:self action:@selector(softKeyTapped:)
          forControlEvents:UIControlEventTouchUpInside];
    [dismiss addTarget:self action:@selector(dismissSoftwareKeyboardTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    dismiss.translatesAutoresizingMaskIntoConstraints = NO;
    dismiss.accessibilityIdentifier = @"dismiss-keyboard";
    _softModifierButtons = @[control, option, command, shift];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        escape, control, option, command, shift, tab, left, up, down, right
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 6;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    [scroll addSubview:stack];
    [input addSubview:scroll];
    [input addSubview:dismiss];
    UILayoutGuide *inputSafe = input.safeAreaLayoutGuide;
    _softwareKeyBarTrailingConstraint =
        [dismiss.trailingAnchor constraintEqualToAnchor:inputSafe.trailingAnchor
                                                constant:-144];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:inputSafe.leadingAnchor],
        // Keep the scrolling viewport wholly left of the fixed dismiss
        // button. Its separate trailing constraint then reserves the entire
        // iPadOS hardware-keyboard/input-method control cluster, so narrow
        // Stage Manager windows cannot scroll a MacWS key under that overlay.
        [scroll.trailingAnchor constraintEqualToAnchor:dismiss.leadingAnchor
                                               constant:-6],
        _softwareKeyBarTrailingConstraint,
        [scroll.topAnchor constraintEqualToAnchor:input.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:input.bottomAnchor],
        [dismiss.centerYAnchor constraintEqualToAnchor:input.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    ]];
    return input;
}

- (void)renderSemanticMenuTitles {
    if (!_semanticMenuTitles) return;
    for (UIView *view in [_semanticMenuTitles.arrangedSubviews copy]) {
        [_semanticMenuTitles removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<MacWSMenuItem *> *roots = [_menuSnapshot childrenOfItemID:0];
    NSMutableArray<MacWSMenuItem *> *visible = [NSMutableArray array];
    for (MacWSMenuItem *item in roots) {
        if ((item.flags & MacWSMenuNodeHidden) == 0 && item.title.length)
            [visible addObject:item];
    }
    UIButton *apple = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *appleConfiguration =
        [UIButtonConfiguration plainButtonConfiguration];
    appleConfiguration.title = @"";
    appleConfiguration.baseForegroundColor = UIColor.labelColor;
    appleConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(0, 7, 0, 7);
    appleConfiguration.titleTextAttributesTransformer =
        ^NSDictionary *(NSDictionary *attributes) {
            NSMutableDictionary *result = [attributes mutableCopy];
            result[NSFontAttributeName] = [UIFont systemFontOfSize:16
                weight:UIFontWeightSemibold];
            return result;
        };
    apple.configuration = appleConfiguration;
    apple.userInteractionEnabled = NO;
    apple.accessibilityLabel = @"Apple 菜单";
    [_semanticMenuTitles addArrangedSubview:apple];
    // The containing UIScrollView already handles narrow iPad windows. Keep
    // every real macOS root menu visible instead of collapsing to three
    // arbitrary titles and an iOS-style "more" action.
    NSUInteger limit = visible.count;
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSMenuItem *item = visible[index];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *configuration =
            [UIButtonConfiguration plainButtonConfiguration];
        configuration.title = item.title;
        configuration.baseForegroundColor = UIColor.labelColor;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 8, 0, 8);
        configuration.titleTextAttributesTransformer =
            ^NSDictionary *(NSDictionary *attributes) {
                NSMutableDictionary *result = [attributes mutableCopy];
                result[NSFontAttributeName] = [UIFont systemFontOfSize:14.0
                    weight:index == 0 ? UIFontWeightSemibold
                                      : UIFontWeightRegular];
                return result;
            };
        button.configuration = configuration;
        button.configurationUpdateHandler = ^(UIButton *updated) {
            UIButtonConfiguration *state = [updated.configuration copy];
            state.baseForegroundColor = updated.highlighted
                ? UIColor.whiteColor : UIColor.labelColor;
            state.background.backgroundColor = updated.highlighted
                ? UIColor.systemBlueColor : UIColor.clearColor;
            state.background.cornerRadius = 4.0;
            updated.configuration = state;
        };
        button.tag = (NSInteger)item.itemID;
        button.accessibilityLabel = [NSString stringWithFormat:
            @"%@ 菜单", item.title];
        [button addTarget:self action:@selector(semanticMenuTitleTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [_semanticMenuTitles addArrangedSubview:button];
    }
    if (visible.count == 0) {
        UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *configuration =
            [UIButtonConfiguration plainButtonConfiguration];
        configuration.title = @"macOS 菜单…";
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 8, 0, 8);
        configuration.titleTextAttributesTransformer =
            ^NSDictionary *(NSDictionary *attributes) {
                NSMutableDictionary *result = [attributes mutableCopy];
                result[NSFontAttributeName] = [UIFont systemFontOfSize:14.0];
                return result;
            };
        retry.configuration = configuration;
        retry.tag = -1;
        [retry addTarget:self action:@selector(semanticMenuTitleTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [_semanticMenuTitles addArrangedSubview:retry];
    }
}

- (void)applyMacOSMenuAppearance:(MacWSMenuAppearance)appearance {
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    if (appearance == MacWSMenuAppearanceDark)
        style = UIUserInterfaceStyleDark;
    else if (appearance == MacWSMenuAppearanceLight)
        style = UIUserInterfaceStyleLight;
    _semanticMenuBar.overrideUserInterfaceStyle = style;
    _showControlsMaterial.overrideUserInterfaceStyle = style;
    _controlPanel.overrideUserInterfaceStyle = style;
    [_semanticMenuBar setNeedsLayout];
    [_showControlsMaterial setNeedsLayout];
    [_controlPanel setNeedsLayout];
}

- (void)refreshSemanticMenuWithCompletion:(void (^ _Nullable)(
        MacWSMenuSnapshot * _Nullable, NSError * _Nullable))completion {
    if (_windowID == 0 || _windowOwnerPID <= 1) {
        if (completion) completion(nil, [NSError errorWithDomain:@"MacWSMenu"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"全屏工作区使用真实 macOS 菜单栏"}]);
        return;
    }
    [_menuClient requestSnapshotForPID:_windowOwnerPID windowID:_windowID
        completion:^(MacWSMenuSnapshot *snapshot, NSError *error) {
            if (snapshot && snapshot.representedWindowID == self->_windowID &&
                snapshot.representedOwnerPID == self->_windowOwnerPID) {
                if (snapshot.ownerPID != snapshot.representedOwnerPID)
                    MacWSDiagnosticLog(@"semantic-menu provider=%d/%u represented=%d/%u nodes=%lu",
                        snapshot.ownerPID, snapshot.windowID,
                        snapshot.representedOwnerPID, snapshot.representedWindowID,
                        (unsigned long)snapshot.items.count);
                self->_menuSnapshot = snapshot;
                [self applyMacOSMenuAppearance:snapshot.appearance];
                [self renderSemanticMenuTitles];
            }
            if (completion) completion(snapshot, error);
        }];
}

- (BOOL)activateCurrentMacWindow {
    if (_windowID == 0 || _windowOwnerPID <= 1) return NO;
    uint32_t frameWidth = [_metalView currentFrameWidth];
    uint32_t frameHeight = [_metalView currentFrameHeight];
    MacWSInputRecord activation = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindActivateTarget,
        .sceneID = MacWSInputSceneForWindow(_windowID, 0),
        .timestamp = CACurrentMediaTime(),
        .x = (float)(frameWidth * 0.5),
        .y = (float)(frameHeight * 0.5),
        .frameWidth = MAX(frameWidth, 1u),
        .frameHeight = MAX(frameHeight, 1u),
        .targetPID = _windowOwnerPID,
        .source = MacWSInputSourceFinger,
    };
    [self metalView:_metalView emittedInput:activation];
    return YES;
}

- (void)nativeApplicationFocusDidChange:(NSNotification *)notification {
    id target = notification.object;
    UIWindow *window = self.viewIfLoaded.window;
    if (!window) return;
    if ([target isKindOfClass:UIWindow.class] && target != window) return;
    if ([target isKindOfClass:UIScene.class] && target != window.windowScene)
        return;
    [self synchronizeMacWindowFocusWithReason:notification.name];
}

- (void)nativeSceneOcclusionDidChange:(NSNotification *)notification {
    UIWindowScene *scene = self.viewIfLoaded.window.windowScene ?:
        _connectedWindowScene;
    if (!scene) return;
    id target = notification.object;
    // UIKit currently posts the Scene as the object. Keep nil/opaque-object
    // compatibility by reevaluating this controller rather than dropping a
    // lifecycle edge we cannot classify.
    if ([target isKindOfClass:UIScene.class] && target != scene) return;
    uint64_t serial = ++_sceneOcclusionEvaluationSerial;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (serial != self->_sceneOcclusionEvaluationSerial) return;
        [self synchronizeSceneOcclusionWithReason:notification.name];
    });
}

- (void)synchronizeSceneOcclusionWithReason:(NSString *)reason {
    if (_sceneDestructionRequested) return;
    UIWindowScene *scene = self.viewIfLoaded.window.windowScene ?:
        _connectedWindowScene;
    if (!scene) return;
    BOOL occluded = NO, foreground = NO, backgrounded = NO;
    BOOL hasEffectiveSettings = MacWSReadEffectiveSceneLifecycle(
        scene, &occluded, &foreground, &backgrounded);
    UISceneActivationState activation = scene.activationState;
    BOOL lifecycleBackground =
        activation == UISceneActivationStateBackground ||
        activation == UISceneActivationStateUnattached;
    BOOL shouldSuspend = lifecycleBackground ||
        (hasEffectiveSettings && (occluded || backgrounded));
    NSString *action = @"keep-live";
    if (shouldSuspend) {
        if (!_sceneStreamSuspendedForOcclusion) {
            _sceneStreamSuspendedForOcclusion = YES;
            action = @"suspend-and-release-surfaces";
            [self suspendSceneStream];
        } else {
            action = @"keep-suspended";
        }
    } else if (_sceneStreamSuspendedForOcclusion) {
        _sceneStreamSuspendedForOcclusion = NO;
        action = @"resume-visible-stream";
        [self resumeSceneStream];
    }
    // Runtime witness for the power policy: activationState alone remained 0
    // for nine Stage Manager scenes during the 2026-09-29 stress run. The FBS
    // settings are the upstream visibility state that actually transitions.
    MacWSLog(@"runtime-confirmed scene-occlusion id=%@ window=%u "
             "settings=%@ occluded=%@ foreground=%@ backgrounded=%@ "
             "activation=%ld suspended=%@ action=%@ reason=%@",
             scene.session.persistentIdentifier ?: @"none", _windowID,
             hasEffectiveSettings ? @"YES" : @"NO",
             occluded ? @"YES" : @"NO", foreground ? @"YES" : @"NO",
             backgrounded ? @"YES" : @"NO", (long)activation,
             _sceneStreamSuspendedForOcclusion ? @"YES" : @"NO", action,
             reason ?: @"unknown");
}

- (void)synchronizeMacWindowFocusWithReason:(NSString *)reason {
    uint64_t serial = ++_nativeFocusRequestSerial;
    // Scene activation and evaluator notifications can share one UIKit
    // transaction. Wait one main-queue turn for its application-wide target;
    // do not race every ForegroundActive Scene into becoming the macOS key.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (serial != self->_nativeFocusRequestSerial ||
            self->_sceneDestructionRequested ||
            self->_streamMode != MacWSStreamModeWindow ||
            self->_windowID == 0 || self->_windowOwnerPID <= 1) return;
        UIWindow *window = self.viewIfLoaded.window;
        UIWindowScene *scene = window.windowScene;
        BOOL applicationKey = [window respondsToSelector:
            @selector(_isApplicationKeyWindow)] &&
            [window _isApplicationKeyWindow];
        if (!window || window.hidden || !applicationKey ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            MacWSLog(@"scene-focus skipped reason=%@ scene=%@ window=%u pid=%d local-key=%@ application-key=%@ state=%ld",
                reason, scene.session.persistentIdentifier ?: @"none",
                self->_windowID, self->_windowOwnerPID,
                window.isKeyWindow ? @"YES" : @"NO",
                applicationKey ? @"YES" : @"NO", (long)scene.activationState);
            return;
        }
        CFTimeInterval now = CACurrentMediaTime();
        if (now - self->_lastNativeFocusRequestTime < 0.04) return;
        self->_lastNativeFocusRequestTime = now;
        BOOL issued = [self activateCurrentMacWindow];
        MacWSLog(@"scene-focus request reason=%@ scene=%@ window=%u pid=%d application-key=YES issued=%@",
            reason, scene.session.persistentIdentifier, self->_windowID,
            self->_windowOwnerPID, issued ? @"YES" : @"NO");
        [self restoreHardwareKeyboardFocusWithReason:@"application-key-window"];
        [self->_metalView requestStreamWindowList];
    });
}

- (BOOL)activateMacWindow:(MacWSStreamWindow *)window {
    if (!window || window.descriptor.windowID == 0 ||
        window.descriptor.ownerPID <= 1) return NO;
    uint32_t frameWidth = [_metalView currentFrameWidth];
    uint32_t frameHeight = [_metalView currentFrameHeight];
    // Bind subsequent keyboard input immediately to the same explicit user
    // target. Waiting for another catalog callback reintroduced stale focus
    // from unrelated processes before this activation had even committed.
    _metalView.targetPID = window.descriptor.ownerPID;
    if (_streamMode == MacWSStreamModeFullscreen) {
        _fullscreenActivatedInputWindowID = window.descriptor.windowID;
        _fullscreenActivatedInputOwnerPID = window.descriptor.ownerPID;
        if ((window.descriptor.flags &
                MacWSStreamWindowFullscreenCanvas) != 0) {
            [_metalView noteValidatedFullscreenCanvasForPID:
                window.descriptor.ownerPID
                                                   windowID:
                window.descriptor.windowID];
        }
    }
    MacWSInputRecord activation = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindActivateTarget,
        .sceneID = MacWSInputSceneForWindow(
            window.descriptor.windowID, 0),
        .timestamp = CACurrentMediaTime(),
        .x = (float)(frameWidth * 0.5),
        .y = (float)(frameHeight * 0.5),
        .frameWidth = MAX(frameWidth, 1u),
        .frameHeight = MAX(frameHeight, 1u),
        .targetPID = window.descriptor.ownerPID,
        .source = MacWSInputSourceFinger,
    };
    [self metalView:_metalView emittedInput:activation];
    NSString *title = window.title.length ? window.title :
        [NSString stringWithFormat:@"Window %u",
            window.descriptor.windowID];
    [self setNotice:[NSString stringWithFormat:@"已切换到 %@", title]
             success:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (self->_streamMode == MacWSStreamModeFullscreen)
            [self->_metalView requestStreamWindowList];
    });
    return YES;
}

- (BOOL)isFullscreenWorkspace {
    return _streamMode == MacWSStreamModeFullscreen;
}

- (BOOL)activateMacWindowIDInFullscreenWorkspace:(uint32_t)windowID
                                        ownerPID:(int32_t)ownerPID
                                           title:(NSString *)title {
    if (_streamMode != MacWSStreamModeFullscreen ||
        windowID == 0 || ownerPID <= 1) return NO;
    for (MacWSStreamWindow *window in _streamWindows) {
        if (window.descriptor.windowID == windowID &&
            window.descriptor.ownerPID == ownerPID) {
            // A newer exact request supersedes any unresolved cold-catalog
            // request. Do not let the latter reactivate an older window when
            // the next catalog arrives.
            _pendingFullscreenActivationOwnerPID = 0;
            _pendingFullscreenActivationWindowID = 0;
            _pendingFullscreenActivationTitle = nil;
            _pendingFullscreenActivationDeadline = 0.0;
            return [self activateMacWindow:window];
        }
    }
    // A URL/new-window request can connect a cold fullscreen Scene before its
    // first DisplayStream catalog arrives. Runtime-confirmed on the iPad14,5
    // 7DTD target: the exact 96438/125 request reached this branch, the first
    // catalog arrived 38 ms later, and the old one-shot implementation forgot
    // the identity and selected Steam Helper 96255 instead. Retain only the
    // exact PID/window request for a bounded interval; receivedWindows:
    // validates both fields against the authoritative catalog before calling
    // the ordinary activation transaction.
    _pendingFullscreenActivationWindowID = windowID;
    _pendingFullscreenActivationOwnerPID = ownerPID;
    _pendingFullscreenActivationTitle = [title copy];
    _pendingFullscreenActivationDeadline = CACurrentMediaTime() + 10.0;
    [_metalView requestStreamWindowList];
    [self setNotice:[NSString stringWithFormat:@"%@ 已在当前全屏工作区中打开，正在等待窗口目录更新。",
        title.length ? title : @"macOS 应用"] success:YES];
    MacWSLog(@"fullscreen-window-route pending pid=%d window=%u title=%@",
             ownerPID, windowID, title ?: @"");
    return YES;
}

- (void)performSemanticShortcutForDiagnostics:(NSString *)shortcut {
    uint32_t targetWindowID = _windowID;
    int32_t targetOwnerPID = _windowOwnerPID;
    if (_streamMode == MacWSStreamModeFullscreen && targetWindowID == 0) {
        targetOwnerPID = _metalView.targetPID;
        for (MacWSStreamWindow *window in _streamWindows) {
            if (window.descriptor.ownerPID != targetOwnerPID ||
                window.descriptor.windowID == 0 ||
                (window.descriptor.flags & MacWSStreamWindowVisible) == 0)
                continue;
            targetWindowID = window.descriptor.windowID;
            break;
        }
    }
    if (targetWindowID == 0 || targetOwnerPID <= 1 || !shortcut.length) {
        MacWSLog(@"diagnostic-menu shortcut=%@ result=no-exact-window",
                 shortcut ?: @"");
        return;
    }
    [_menuClient requestSnapshotForPID:targetOwnerPID
                              windowID:targetWindowID
                            completion:^(MacWSMenuSnapshot *snapshot,
                                         NSError *error) {
        if (!snapshot || error) {
            MacWSLog(@"diagnostic-menu shortcut=%@ result=snapshot-failed "
                     "error=%@", shortcut,
                     error.localizedDescription ?: @"unknown");
            return;
        }
        MacWSMenuItem *match = nil;
        for (MacWSMenuItem *item in snapshot.items) {
            if ([item.shortcut isEqualToString:shortcut] &&
                (item.flags & MacWSMenuNodeEnabled) &&
                !(item.flags & (MacWSMenuNodeHidden |
                                MacWSMenuNodeHasSubmenu |
                                MacWSMenuNodeRequiresWorkspace))) {
                match = item;
                break;
            }
        }
        if (!match) {
            MacWSLog(@"diagnostic-menu shortcut=%@ result=item-not-found",
                     shortcut);
            return;
        }
        MacWSLog(@"diagnostic-menu shortcut=%@ item=%@ owner=%d window=%u",
                 shortcut, match.title, snapshot.ownerPID,
                 snapshot.windowID);
        if (self->_streamMode == MacWSStreamModeFullscreen) {
            [self activateMacWindowIDInFullscreenWorkspace:targetWindowID
                ownerPID:targetOwnerPID title:match.title];
        } else {
            [self activateCurrentMacWindow];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      120 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [self->_menuClient performItem:match inSnapshot:snapshot
                completion:^(MacWSMenuStatus status, NSError *actionError) {
                    MacWSLog(@"diagnostic-menu shortcut=%@ item=%@ "
                             "status=%u error=%@", shortcut, match.title,
                             (unsigned)status,
                             actionError.localizedDescription ?: @"none");
                }];
        });
    }];
}

- (void)dismissSemanticMenu {
    [_semanticMenuDismissLayer removeFromSuperview];
    _semanticMenuDismissLayer = nil;
    if (!_semanticMenuPanel) return;
    [_semanticMenuPanel willMoveToParentViewController:nil];
    [_semanticMenuPanel.view removeFromSuperview];
    [_semanticMenuPanel removeFromParentViewController];
    _semanticMenuPanel = nil;
}

- (void)presentSemanticMenuForParent:(uint64_t)parentID
                             snapshot:(MacWSMenuSnapshot *)snapshot
                               source:(UIView *)source
                                title:(NSString *)title {
    NSMutableArray<MacWSMenuItem *> *items = [NSMutableArray array];
    for (MacWSMenuItem *item in [snapshot childrenOfItemID:parentID]) {
        if ((item.flags & MacWSMenuNodeHidden) == 0) [items addObject:item];
    }
    if (items.count == 0) {
        [self setNotice:[NSString stringWithFormat:@"“%@”菜单当前没有可见项目。",
            title.length ? title : @"macOS"] success:NO];
        return;
    }
    __weak typeof(self) weakSelf = self;
    MacWSCompactMenuController *panel = [[MacWSCompactMenuController alloc]
        initWithItems:items appearance:snapshot.appearance
        selection:^(MacWSMenuItem *item) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self dismissSemanticMenu];
            if (item.flags & MacWSMenuNodeRequiresWorkspace) {
                [self setNotice:@"此菜单项包含 macOS 自定义视图，请在全屏工作区中使用。"
                         success:NO];
                return;
            }
            if (item.flags & MacWSMenuNodeHasSubmenu) {
                [self presentSemanticMenuForParent:item.itemID
                                          snapshot:snapshot source:source
                                             title:item.title];
                return;
            }
            if ((item.flags & MacWSMenuNodeBridgedQuit) &&
                !(item.flags & MacWSMenuNodeEnabled)) {
                // Runtime-confirmed from Maps' live Ventura menu snapshot:
                // the standard depth-one "Quit Maps" Command-Q item is
                // present with flags=0 (disabled). Do not mutate that real
                // NSMenuItem. Route this one semantic to the exact process's
                // PerformQuit control; AppKit still owns termination checks,
                // prompts, cancellation and final process exit.
                int sendError = 0;
                BOOL sent = MacWSSendPerformQuit(
                    snapshot.representedOwnerPID, &sendError);
                [self setNotice:sent
                    ? [NSString stringWithFormat:@"已发送“%@”", item.title]
                    : [NSString stringWithFormat:
                        @"无法发送退出请求（%d）", sendError]
                         success:sent];
                return;
            }
            // The iOS menu is outside AppKit, so selecting it does not itself
            // focus the represented NSWindow.  Send the same control-plane
            // activation as a real click and let AppKit finish its documented
            // activation transaction before routing a First Responder action.
            // Unlike the old bridge-side makeKeyAndOrderFront:, this happens
            // only for explicit user intent and never during passive refresh.
            [self activateCurrentMacWindow];
            uint32_t selectedWindowID = snapshot.representedWindowID;
            int32_t selectedOwnerPID = snapshot.representedOwnerPID;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          120 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (self->_windowID != selectedWindowID ||
                    self->_windowOwnerPID != selectedOwnerPID) {
                    [self setNotice:@"窗口已经切换，请重新选择菜单项" success:NO];
                    return;
                }
                [self->_menuClient performItem:item inSnapshot:snapshot
                    completion:^(MacWSMenuStatus status, NSError *error) {
                        if (status == MacWSMenuStatusOK) {
                            [self setNotice:[NSString stringWithFormat:
                                @"已发送“%@”", item.title] success:YES];
                        } else {
                            [self setNotice:error.localizedDescription ?:
                                @"菜单项无法执行" success:NO];
                            [self refreshSemanticMenuWithCompletion:nil];
                        }
                    }];
            });
        }];
    [self dismissSemanticMenu];
    [self.view layoutIfNeeded];
    CGRect sourceRect = [source convertRect:source.bounds toView:self.view];
    CGRect safeBounds = UIEdgeInsetsInsetRect(self.view.bounds,
                                               self.view.safeAreaInsets);
    CGSize preferred = panel.preferredContentSize;
    CGFloat width = MIN(preferred.width, MAX(120.0, safeBounds.size.width));
    CGFloat height = MIN(preferred.height,
                         MAX(80.0, safeBounds.size.height - 4.0));
    CGFloat x = MIN(MAX(CGRectGetMinX(sourceRect), CGRectGetMinX(safeBounds)),
        MAX(CGRectGetMinX(safeBounds), CGRectGetMaxX(safeBounds) - width));
    CGFloat y = CGRectGetMaxY(sourceRect) + 1.0;
    if (y + height > CGRectGetMaxY(safeBounds))
        y = MAX(CGRectGetMinY(safeBounds),
                CGRectGetMinY(sourceRect) - height - 1.0);

    UIControl *dismissLayer = [[UIControl alloc] initWithFrame:self.view.bounds];
    dismissLayer.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
    dismissLayer.backgroundColor = UIColor.clearColor;
    [dismissLayer addTarget:self action:@selector(dismissSemanticMenu)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:dismissLayer];
    _semanticMenuDismissLayer = dismissLayer;

    [self addChildViewController:panel];
    panel.view.frame = CGRectMake(x, y, width, height);
    panel.view.backgroundColor = UIColor.clearColor;
    panel.view.layer.cornerRadius = 10.0;
    panel.view.layer.cornerCurve = kCACornerCurveContinuous;
    panel.view.layer.borderWidth = 0.5;
    panel.view.layer.borderColor =
        [UIColor.separatorColor colorWithAlphaComponent:0.7].CGColor;
    panel.view.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.view.layer.shadowOpacity = 0.25;
    panel.view.layer.shadowRadius = 10;
    panel.view.layer.shadowOffset = CGSizeMake(0, 4);
    [self.view addSubview:panel.view];
    [panel didMoveToParentViewController:self];
    _semanticMenuPanel = panel;
    if (MacWSHostDiagnosticsEnabled()) {
        MacWSLog(@"menu-present parent=%llu source=(%.1f,%.1f %.1fx%.1f) panel=(%.1f,%.1f %.1fx%.1f)",
                 parentID, sourceRect.origin.x, sourceRect.origin.y,
                 sourceRect.size.width, sourceRect.size.height,
                 x, y, width, height);
    }
}

- (void)semanticMenuTitleTapped:(UIButton *)sender {
    uint32_t siblingIndex = UINT32_MAX;
    if (sender.tag >= 0) {
        MacWSMenuItem *old = [_menuSnapshot itemWithID:(uint64_t)sender.tag];
        siblingIndex = old.siblingIndex;
    }
    sender.enabled = NO;
    [self activateCurrentMacWindow];
    [self refreshSemanticMenuWithCompletion:^(MacWSMenuSnapshot *snapshot,
                                               NSError *error) {
        sender.enabled = YES;
        if (error || !snapshot) {
            [self setNotice:error.localizedDescription ?: @"菜单暂不可用"
                     success:NO];
            return;
        }
        uint64_t parentID = 0;
        NSString *title = @"macOS 菜单";
        if (siblingIndex != UINT32_MAX) {
            for (MacWSMenuItem *root in [snapshot childrenOfItemID:0]) {
                if (root.siblingIndex == siblingIndex) {
                    parentID = root.itemID;
                    title = root.title;
                    break;
                }
            }
        }
        [self presentSemanticMenuForParent:parentID snapshot:snapshot
                                    source:sender title:title];
    }];
}

- (void)loadView {
    UIView *root = [UIView new];
    root.backgroundColor = UIColor.systemBackgroundColor;
    self.view = root;
    for (NSString *name in @[MacWSApplicationKeyWindowNotification,
                             MacWSKeyboardTargetSceneNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(nativeApplicationFocusDidChange:)
            name:name object:nil];
    }
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(nativeSceneOcclusionDidChange:)
        name:MacWSSceneOcclusionChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(systemKeyboardFrameDidChange:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
    if (@available(iOS 14.0, *)) {
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(pointerLockStateDidChange:)
            name:UIPointerLockStateDidChangeNotification object:nil];
    }

    _metalView = [[MacWSMetalView alloc] initWithFrame:CGRectZero];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    _metalView.statusDelegate = self;
    _metalView.sceneID = ((uint64_t)_sceneIdentifier.hash) &
        ~MACWS_INPUT_WINDOW_SCENE_FLAG;
    _metalView.minimumLogicalSize = _windowMinimumSize;
    _metalView.maximumLogicalSize = _windowMaximumSize;
    _metalView.targetWindowResizable = _windowResizable;
    _metalView.targetWindowFixedWidth = _windowWidthFixed;
    _metalView.targetWindowFixedHeight = _windowHeightFixed;
    MacWSHostDisplayDensity savedDensity = (MacWSHostDisplayDensity)
        [NSUserDefaults.standardUserDefaults integerForKey:@"MacWSDisplayDensity"];
    savedDensity = MacWSNormalizedDisplayDensity(savedDensity);
    [NSUserDefaults.standardUserDefaults setInteger:savedDensity
        forKey:@"MacWSDisplayDensity"];
    _metalView.displayDensity = savedDensity;
    MacWSHostPresentationResolution savedPresentationResolution =
        (MacWSHostPresentationResolution)
        [NSUserDefaults.standardUserDefaults integerForKey:
            @"MacWSPresentationResolution"];
    if (savedPresentationResolution !=
            MacWSHostPresentationResolutionAutomatic &&
        savedPresentationResolution !=
            MacWSHostPresentationResolutionSourceNative &&
        savedPresentationResolution !=
            MacWSHostPresentationResolutionPerformance)
        savedPresentationResolution =
            MacWSHostPresentationResolutionAutomatic;
    _metalView.presentationResolution = savedPresentationResolution;
    CGFloat savedZoomScale =
        [NSUserDefaults.standardUserDefaults doubleForKey:@"MacWSFixedZoomScale"];
    _metalView.fixedZoomScale = savedZoomScale >= 1.75 ? 2.0 : 1.5;
    // Scene restoration constructs background controllers too.  Record the
    // target here, but defer the actual DisplayStream subscription until the
    // Scene enters the foreground so dormant Scenes cannot consume leases.
    _metalView.targetWindowID = _streamMode == MacWSStreamModeWindow ? _windowID : 0;
    _metalView.targetPID = _windowOwnerPID;
    [root addSubview:_metalView];
    // A stationary two-finger hold is an explicit cross-App intent that does
    // not overlap Finder's ordinary single-finger selection or internal drag.
    // The view's short two-finger context click waits for this recognizer to
    // fail, so one physical chord can commit to exactly one action.
    if (_windowID != 0) {
        _crossAppDragTwoFingerHold = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(crossAppDragTwoFingerHeld:)];
        _crossAppDragTwoFingerHold.minimumPressDuration = 0.48;
        _crossAppDragTwoFingerHold.numberOfTouchesRequired = 2;
        _crossAppDragTwoFingerHold.allowableMovement = 12.0;
        // The recognizer observes a two-finger chord but must never cancel the
        // Metal view's real touch lifecycle. In particular, one finger held on
        // a Finder item must remain owned by MacWSMetalView so the subsequent
        // movement reaches AppKit's synchronous NSCoreDragManager tracker.
        // Once a second finger arrives MacWSMetalView already cancels its
        // single-touch candidate through its explicit multitouch branch.
        _crossAppDragTwoFingerHold.cancelsTouchesInView = NO;
        _crossAppDragTwoFingerHold.delaysTouchesBegan = NO;
        _crossAppDragTwoFingerHold.allowedTouchTypes = @[@(UITouchTypeDirect)];
        _crossAppDragTwoFingerHold.delegate = self;
        [_metalView addGestureRecognizer:_crossAppDragTwoFingerHold];
        [_metalView requireSecondaryTapToFailGestureRecognizer:
            _crossAppDragTwoFingerHold];
    }
    // A plain UIKit source surface isolates the system drag recognizer from
    // MTKView's rendering/input recognizers. It is present only for the one
    // explicitly armed cross-app transaction and otherwise cannot intercept
    // macOS clicks, context clicks, or internal drags.
    _crossAppDragSurface = [UIButton buttonWithType:UIButtonTypeCustom];
    _crossAppDragSurface.translatesAutoresizingMaskIntoConstraints = NO;
    _crossAppDragSurface.backgroundColor = UIColor.clearColor;
    _crossAppDragSurface.accessibilityLabel = @"macOS 跨 App 拖动区域";
    _crossAppDragSurface.hidden = YES;
    [root addSubview:_crossAppDragSurface];
    // Runtime-confirmed via /var/mobile/Library/Logs/MacWSHost.log: the same
    // staged provider ended with Files operation=1 from the full-canvas source
    // and operation=2 from a compact 58x58 source at the picked file. Keep the
    // real UIDragInteraction source compact; decorative text lives outside it.
    _crossAppDragHandle = [UIButton buttonWithType:UIButtonTypeSystem];
    _crossAppDragHandle.bounds = CGRectMake(0, 0, 58, 58);
    _crossAppDragHandle.backgroundColor = UIColor.clearColor;
    _crossAppDragHandle.layer.cornerRadius = 16;
    _crossAppDragHandle.layer.shadowColor = UIColor.blackColor.CGColor;
    _crossAppDragHandle.layer.shadowOpacity = 0.30;
    _crossAppDragHandle.layer.shadowRadius = 8;
    _crossAppDragHandle.layer.shadowOffset = CGSizeMake(0, 4);

    _crossAppDragHandleMaterial = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:
            UIBlurEffectStyleSystemChromeMaterialDark]];
    _crossAppDragHandleMaterial.frame = _crossAppDragHandle.bounds;
    _crossAppDragHandleMaterial.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _crossAppDragHandleMaterial.userInteractionEnabled = NO;
    _crossAppDragHandleMaterial.clipsToBounds = YES;
    _crossAppDragHandleMaterial.layer.cornerRadius = 16;
    _crossAppDragHandleMaterial.layer.borderWidth = 1.0;
    _crossAppDragHandleMaterial.layer.borderColor =
        [UIColor.whiteColor colorWithAlphaComponent:0.36].CGColor;
    [_crossAppDragHandle addSubview:_crossAppDragHandleMaterial];

    _crossAppDragHandleTint = [[UIView alloc]
        initWithFrame:_crossAppDragHandleMaterial.bounds];
    _crossAppDragHandleTint.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _crossAppDragHandleTint.userInteractionEnabled = NO;
    _crossAppDragHandleTint.backgroundColor =
        [UIColor.systemIndigoColor colorWithAlphaComponent:0.20];
    [_crossAppDragHandleMaterial.contentView
        addSubview:_crossAppDragHandleTint];

    // iPadOS represents a multi-item drag as a small fan of the actual item
    // previews. Keep those cards inside the runtime-confirmed 58x58 UIKit drag
    // source so Files still negotiates a copy operation, while the file-name
    // pill remains a noninteractive sibling below it.
    _crossAppDragHandleBackIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _crossAppDragHandleMiddleIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _crossAppDragHandleIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    for (UIImageView *thumbnailView in @[
             _crossAppDragHandleBackIcon,
             _crossAppDragHandleMiddleIcon,
             _crossAppDragHandleIcon]) {
        thumbnailView.contentMode = UIViewContentModeScaleAspectFit;
        thumbnailView.backgroundColor = UIColor.secondarySystemBackgroundColor;
        thumbnailView.tintColor = UIColor.systemIndigoColor;
        thumbnailView.clipsToBounds = YES;
        thumbnailView.layer.cornerRadius = 6.5;
        thumbnailView.layer.borderWidth = 1.0;
        thumbnailView.layer.borderColor =
            [UIColor.whiteColor colorWithAlphaComponent:0.72].CGColor;
        thumbnailView.userInteractionEnabled = NO;
        thumbnailView.hidden = YES;
        [_crossAppDragHandle addSubview:thumbnailView];
    }

    _crossAppDragHandleBadge = [[UILabel alloc]
        initWithFrame:CGRectMake(39, -5, 24, 24)];
    _crossAppDragHandleBadge.backgroundColor = UIColor.systemOrangeColor;
    _crossAppDragHandleBadge.textColor = UIColor.whiteColor;
    _crossAppDragHandleBadge.font = [UIFont monospacedDigitSystemFontOfSize:12
                                                                    weight:UIFontWeightBold];
    _crossAppDragHandleBadge.textAlignment = NSTextAlignmentCenter;
    _crossAppDragHandleBadge.adjustsFontSizeToFitWidth = YES;
    _crossAppDragHandleBadge.minimumScaleFactor = 0.7;
    _crossAppDragHandleBadge.layer.cornerRadius = 12;
    _crossAppDragHandleBadge.layer.borderWidth = 2;
    _crossAppDragHandleBadge.layer.borderColor =
        UIColor.systemBackgroundColor.CGColor;
    _crossAppDragHandleBadge.clipsToBounds = YES;
    _crossAppDragHandleBadge.userInteractionEnabled = NO;
    _crossAppDragHandleBadge.hidden = YES;
    [_crossAppDragHandle addSubview:_crossAppDragHandleBadge];

    _crossAppDragHandle.accessibilityLabel = @"已准备的 macOS 文件";
    _crossAppDragHandle.accessibilityHint = @"长按并拖到另一个应用";
    [_crossAppDragHandle addTarget:self
                            action:@selector(cancelPreparedCrossAppDragHandle)
                  forControlEvents:UIControlEventTouchUpInside];
    _crossAppDragHandle.hidden = YES;
    [root addSubview:_crossAppDragHandle];

    _crossAppDragHandleTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _crossAppDragHandleTitle.bounds = CGRectMake(0, 0, 110, 26);
    _crossAppDragHandleTitle.backgroundColor =
        [UIColor.labelColor colorWithAlphaComponent:0.78];
    _crossAppDragHandleTitle.textColor = UIColor.systemBackgroundColor;
    _crossAppDragHandleTitle.font = [UIFont systemFontOfSize:12
                                                     weight:UIFontWeightSemibold];
    _crossAppDragHandleTitle.textAlignment = NSTextAlignmentCenter;
    _crossAppDragHandleTitle.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _crossAppDragHandleTitle.layer.cornerRadius = 9;
    _crossAppDragHandleTitle.layer.shadowColor = UIColor.blackColor.CGColor;
    _crossAppDragHandleTitle.layer.shadowOpacity = 0.22;
    _crossAppDragHandleTitle.layer.shadowRadius = 4;
    _crossAppDragHandleTitle.layer.shadowOffset = CGSizeMake(0, 2);
    _crossAppDragHandleTitle.clipsToBounds = YES;
    _crossAppDragHandleTitle.userInteractionEnabled = NO;
    _crossAppDragHandleTitle.hidden = YES;
    [root addSubview:_crossAppDragHandleTitle];
    // The performance controls are no longer part of the product control
    // center. Clear a previously persisted HUD selection as well; otherwise a
    // user who enabled it on an older build would retain an overlay with no UI
    // affordance for turning it back off.
    [NSUserDefaults.standardUserDefaults removeObjectForKey:
        @"MacWSPerformanceHUDMode"];
    _metalView.performanceMonitor.HUDMode = MacWSPerformanceHUDModeOff;
    [_metalView.performanceMonitor attachHUDToView:root];

    // The iPadOS Scene exists before its default Terminal window is launched.
    // Keep a native menu bar during that short bootstrap interval too, so an
    // empty DisplayStream never presents as an unexplained black workspace
    // with a detached control button in the upper-left corner.
    _semanticMenuBar = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        _semanticMenuBar.translatesAutoresizingMaskIntoConstraints = NO;
        _semanticMenuBar.clipsToBounds = YES;
        _semanticMenuBar.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        _semanticMenuScroll = [UIScrollView new];
        _semanticMenuScroll.translatesAutoresizingMaskIntoConstraints = NO;
        _semanticMenuScroll.showsHorizontalScrollIndicator = NO;
        _semanticMenuTitles = [UIStackView new];
        _semanticMenuTitles.translatesAutoresizingMaskIntoConstraints = NO;
        _semanticMenuTitles.axis = UILayoutConstraintAxisHorizontal;
        _semanticMenuTitles.alignment = UIStackViewAlignmentFill;
        _semanticMenuTitles.spacing = 0;
        [_semanticMenuScroll addSubview:_semanticMenuTitles];
        [_semanticMenuBar.contentView addSubview:_semanticMenuScroll];
        UIView *menuSeparator = [UIView new];
        menuSeparator.translatesAutoresizingMaskIntoConstraints = NO;
        menuSeparator.backgroundColor = [UIColor.separatorColor
            colorWithAlphaComponent:0.58];
        [_semanticMenuBar.contentView addSubview:menuSeparator];
        [root addSubview:_semanticMenuBar];
        _semanticMenuContentTopConstraint = [_semanticMenuScroll.topAnchor
            constraintEqualToAnchor:_semanticMenuBar.contentView.topAnchor];
        [NSLayoutConstraint activateConstraints:@[
            [_semanticMenuScroll.leadingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.leadingAnchor constant:4],
            [_semanticMenuScroll.trailingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.trailingAnchor constant:-40],
            _semanticMenuContentTopConstraint,
            [_semanticMenuScroll.bottomAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.bottomAnchor],
            [_semanticMenuTitles.leadingAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.leadingAnchor],
            [_semanticMenuTitles.trailingAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.trailingAnchor],
            [_semanticMenuTitles.topAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.topAnchor],
            [_semanticMenuTitles.bottomAnchor constraintEqualToAnchor:
                _semanticMenuScroll.contentLayoutGuide.bottomAnchor],
            [_semanticMenuTitles.heightAnchor constraintEqualToAnchor:
                _semanticMenuScroll.frameLayoutGuide.heightAnchor],
            [menuSeparator.leadingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.leadingAnchor],
            [menuSeparator.trailingAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.trailingAnchor],
            [menuSeparator.bottomAnchor constraintEqualToAnchor:
                _semanticMenuBar.contentView.bottomAnchor],
            [menuSeparator.heightAnchor constraintEqualToConstant:0.5],
        ]];
    [self renderSemanticMenuTitles];

    _keyboardProxy = [UITextField new];
    _keyboardProxy.translatesAutoresizingMaskIntoConstraints = NO;
    _keyboardProxy.delegate = self;
    _keyboardProxy.text = @" ";
    _keyboardProxy.keyboardType = UIKeyboardTypeDefault;
    _keyboardProxy.autocorrectionType = UITextAutocorrectionTypeDefault;
    _keyboardProxy.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _keyboardProxy.smartDashesType = UITextSmartDashesTypeNo;
    _keyboardProxy.smartQuotesType = UITextSmartQuotesTypeNo;
    _keyboardProxy.spellCheckingType = UITextSpellCheckingTypeNo;
    _keyboardProxy.alpha = 0.01;
    [_keyboardProxy addTarget:self
                       action:@selector(keyboardProxyEditingChanged:)
             forControlEvents:UIControlEventEditingChanged];
    [root addSubview:_keyboardProxy];
    // The modifier row belongs to the MacWS window layout, not to the floating
    // iPad keyboard. Giving it an explicit 52-point region prevents it from
    // covering macOS pixels while leaving the movable software keyboard free
    // to overlap wherever the user places it.
    _softwareKeyBar = [self makeKeyboardAccessoryView];
    _softwareKeyBar.translatesAutoresizingMaskIntoConstraints = NO;
    _softwareKeyBar.hidden = YES;
    [root addSubview:_softwareKeyBar];
    _softwareKeyBarHeightConstraint = [_softwareKeyBar.heightAnchor
        constraintEqualToConstant:0];

    _controlDismissLayer = [UIControl new];
    _controlDismissLayer.translatesAutoresizingMaskIntoConstraints = NO;
    _controlDismissLayer.backgroundColor = UIColor.clearColor;
    _controlDismissLayer.hidden = YES;
    [_controlDismissLayer addTarget:self action:@selector(hideControls)
                   forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_controlDismissLayer];

    // Regular material attenuates saturated game/content backdrops more than
    // thin material while retaining native live blur in light and dark modes.
    _controlPanel = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    _controlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _controlPanel.layer.cornerRadius = 22;
    _controlPanel.layer.cornerCurve = kCACornerCurveContinuous;
    _controlPanel.clipsToBounds = YES;
    _controlPanel.contentView.backgroundColor = UIColor.clearColor;
    _controlPanel.layer.borderWidth = 0.5;
    _controlPanel.layer.borderColor = [UIColor.separatorColor
        colorWithAlphaComponent:0.35].CGColor;
    [root addSubview:_controlPanel];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [_controlPanel.contentView addSubview:scroll];

    _controlTitleLabel = MacWSMakeLabel(@"macPad 控制中心",
        [UIFont systemFontOfSize:23 weight:UIFontWeightBold], UIColor.labelColor);
    _controlSubtitleLabel = MacWSMakeLabel(@"iPadOS 原生窗口 · macOS AGX 工作区",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.secondaryLabelColor);
    UIStackView *titleLabels = [[UIStackView alloc]
        initWithArrangedSubviews:@[_controlTitleLabel, _controlSubtitleLabel]];
    titleLabels.axis = UILayoutConstraintAxisVertical;
    titleLabels.spacing = 1;

    UIButton *hide = [self buttonWithTitle:@"" image:@"sidebar.left"
                                    action:@selector(hideControls) prominent:NO];
    UIButtonConfiguration *hideConfiguration = [hide.configuration copy];
    hideConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(8, 10, 8, 10);
    hide.configuration = hideConfiguration;
    [hide.widthAnchor constraintEqualToConstant:52].active = YES;
    [hide setContentHuggingPriority:UILayoutPriorityRequired
                           forAxis:UILayoutConstraintAxisHorizontal];
    [hide setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabels, hide]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;

    _serviceLabel = MacWSMakeLabel(@"正在连接 root 控制服务…",
        [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold],
        UIColor.systemOrangeColor);
    _phaseLabel = MacWSMakeLabel(@"打开 App 后会自动检查重启恢复状态",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.secondaryLabelColor);

    UIStackView *serviceCard = [[UIStackView alloc]
        initWithArrangedSubviews:@[_serviceLabel, _phaseLabel]];
    serviceCard.axis = UILayoutConstraintAxisVertical;
    serviceCard.spacing = 5;
    serviceCard.layoutMargins = UIEdgeInsetsMake(12, 13, 12, 13);
    serviceCard.layoutMarginsRelativeArrangement = YES;
    serviceCard.backgroundColor = [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.48];
    serviceCard.layer.cornerRadius = 12;

    UIStackView *statusRows = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self statusRowWithTitle:@"macOS RootFS" value:&_rootfsLabel],
        [self divider],
        [self statusRowWithTitle:@"WindowServer" value:&_windowServerLabel],
        [self divider],
        [self statusRowWithTitle:@"触控桥" value:&_bridgeLabel],
        [self divider],
        [self statusRowWithTitle:@"共享帧" value:&_frameLabel],
    ]];
    statusRows.axis = UILayoutConstraintAxisVertical;
    statusRows.spacing = 8;
    statusRows.layoutMargins = UIEdgeInsetsMake(12, 13, 12, 13);
    statusRows.layoutMarginsRelativeArrangement = YES;
    statusRows.backgroundColor = [UIColor.tertiarySystemFillColor colorWithAlphaComponent:0.42];
    statusRows.layer.cornerRadius = 12;

    _primaryButton = [self buttonWithTitle:@"初始化并启动" image:@"play.fill"
                                    action:@selector(primaryAction) prominent:YES];
    [_primaryButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;

    UIButton *glassDemo = [self buttonWithTitle:@"GlassDemo" image:@"sparkles.rectangle.stack"
                                         action:@selector(launchApplication:) prominent:NO];
    glassDemo.accessibilityIdentifier = @"glassdemo";
    UIButton *terminal = [self buttonWithTitle:@"终端" image:@"terminal"
                                        action:@selector(launchApplication:) prominent:NO];
    terminal.accessibilityIdentifier = @"terminal";
    UIButton *activity = [self buttonWithTitle:@"活动监视器" image:@"waveform.path.ecg.rectangle"
                                        action:@selector(launchApplication:) prominent:NO];
    activity.accessibilityIdentifier = @"activity-monitor";
    UIButton *finder = [self buttonWithTitle:@"Finder" image:@"folder"
                                      action:@selector(launchApplication:) prominent:NO];
    finder.accessibilityIdentifier = @"finder";
    UIButton *vscode = [self buttonWithTitle:@"VS Code" image:@"chevron.left.forwardslash.chevron.right"
                                      action:@selector(launchApplication:) prominent:NO];
    vscode.accessibilityIdentifier = @"vscode";
    UIButton *settings = [self buttonWithTitle:@"系统设置" image:@"gearshape"
                                        action:@selector(launchApplication:) prominent:NO];
    settings.accessibilityIdentifier = @"system-settings";
    UIButton *maps = [self buttonWithTitle:@"地图" image:@"map"
                                    action:@selector(launchApplication:) prominent:NO];
    maps.accessibilityIdentifier = @"maps";
    UIButton *amadine = [self buttonWithTitle:@"Amadine"
                                        image:@"paintbrush.pointed"
                                       action:@selector(launchApplication:)
                                    prominent:NO];
    amadine.accessibilityIdentifier = @"amadine";
    UIButton *word = [self buttonWithTitle:@"Word" image:@"doc.richtext"
                                     action:@selector(launchApplication:)
                                  prominent:NO];
    word.accessibilityIdentifier = @"word";
    UIButton *excel = [self buttonWithTitle:@"Excel" image:@"tablecells"
                                      action:@selector(launchApplication:)
                                   prominent:NO];
    excel.accessibilityIdentifier = @"excel";
    UIButton *powerpoint = [self buttonWithTitle:@"PowerPoint"
                                           image:@"play.rectangle"
                                          action:@selector(launchApplication:)
                                       prominent:NO];
    powerpoint.accessibilityIdentifier = @"powerpoint";
    UIButton *steam = [self buttonWithTitle:@"Steam"
                                      image:@"gamecontroller"
                                     action:@selector(launchApplication:)
                                  prominent:NO];
    steam.accessibilityIdentifier = @"steam";
    UIButton *weather = [self buttonWithTitle:@"天气"
                                        image:@"cloud.sun"
                                       action:@selector(launchApplication:)
                                    prominent:NO];
    weather.accessibilityIdentifier = @"weather";
    UIButton *sublime = [self buttonWithTitle:@"Sublime Text"
                                        image:@"chevron.left.forwardslash.chevron.right"
                                       action:@selector(launchApplication:)
                                    prominent:NO];
    sublime.accessibilityIdentifier = @"sublime";
    _applicationButtons = @[
        glassDemo, terminal, activity, finder, vscode, settings, maps,
        weather, sublime, steam, amadine, word, excel, powerpoint,
    ];
    UIStackView *appRow1 = [[UIStackView alloc] initWithArrangedSubviews:@[glassDemo, terminal]];
    UIStackView *appRow2 = [[UIStackView alloc] initWithArrangedSubviews:@[activity, finder]];
    UIStackView *appRow3 = [[UIStackView alloc] initWithArrangedSubviews:@[vscode, settings]];
    UIStackView *appRow4 = [[UIStackView alloc]
        initWithArrangedSubviews:@[maps, weather]];
    UIStackView *appRow5 = [[UIStackView alloc]
        initWithArrangedSubviews:@[sublime, steam]];
    UIStackView *appRow6 = [[UIStackView alloc]
        initWithArrangedSubviews:@[amadine, word]];
    UIStackView *appRow7 = [[UIStackView alloc]
        initWithArrangedSubviews:@[excel, powerpoint]];
    for (UIStackView *row in @[
             appRow1, appRow2, appRow3, appRow4, appRow5, appRow6, appRow7]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
    }

    _appSearchField = [UITextField new];
    _appSearchField.delegate = self;
    _appSearchField.placeholder = @"搜索应用或输入 macOS 绝对路径";
    _appSearchField.returnKeyType = UIReturnKeyGo;
    _appSearchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _appSearchField.autocorrectionType = UITextAutocorrectionTypeNo;
    _appSearchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _appSearchField.backgroundColor = [UIColor.secondarySystemFillColor
        colorWithAlphaComponent:0.52];
    _appSearchField.layer.cornerRadius = 11;
    _appSearchField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _appSearchField.leftViewMode = UITextFieldViewModeAlways;
    [_appSearchField.heightAnchor constraintEqualToConstant:44].active = YES;

    _keyboardButton = [self buttonWithTitle:@"打开虚拟键盘"
                                     image:@"keyboard"
                                    action:@selector(keyboardAction)
                                 prominent:NO];

    _captureButton = [self buttonWithTitle:@"刷新画面" image:@"camera.viewfinder"
                                    action:@selector(captureAction) prominent:NO];
    _repairDesktopButton = [self buttonWithTitle:@"修复桌面"
                                           image:@"arrow.clockwise.circle"
                                          action:@selector(repairDesktopAction)
                                       prominent:NO];
    _repairDesktopButton.accessibilityIdentifier = @"repair-desktop";
    _repairButton = [self buttonWithTitle:@"修复环境" image:@"wrench.and.screwdriver"
                                   action:@selector(repairAction) prominent:NO];
    _recoverButton = [self buttonWithTitle:@"安全恢复" image:@"lifepreserver"
                                    action:@selector(recoverAction) prominent:NO];
    _logsButton = [self buttonWithTitle:@"查看日志" image:@"doc.text.magnifyingglass"
                                 action:@selector(logsAction) prominent:NO];
    _exportButton = [self buttonWithTitle:@"导出诊断" image:@"square.and.arrow.up"
                                   action:@selector(exportDiagnostics) prominent:NO];
    _windowPickerButton = [self buttonWithTitle:@"打开 macOS 窗口"
                                          image:@"macwindow.on.rectangle"
                                         action:@selector(openWindowPicker)
                                      prominent:NO];
    _closeWindowButton = [self buttonWithTitle:@"关闭此 macOS 窗口"
                                         image:@"xmark.square"
                                        action:@selector(closeCurrentWindow)
                                     prominent:NO];
    _closeWindowButton.hidden = _windowID == 0;
    _menuBarButton = [self buttonWithTitle:@"打开全屏 macOS 工作区"
                                     image:@"arrow.up.left.and.arrow.down.right"
                                    action:@selector(openFullscreenWorkspace)
                                 prominent:NO];
    // Interoperability no longer needs manual Control Center entry points.
    // Clipboard exchange is automatic, rendered content remains a native drop
    // target, and a stationary two-finger hold prepares the Finder selection
    // for a cross-application drag. Keep only those direct interactions here.
    if (_windowID != 0) {
        _contentDragInteraction = [[UIDragInteraction alloc]
            initWithDelegate:self];
        _contentDragInteraction.enabled = NO;
        [_crossAppDragHandle addInteraction:_contentDragInteraction];
        _crossAppDragPrepareTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(prepareCrossAppDrag:)];
        _crossAppDragPrepareTap.enabled = NO;
        [_crossAppDragSurface addGestureRecognizer:_crossAppDragPrepareTap];
    }
    [_metalView addInteraction:[[UIDropInteraction alloc]
        initWithDelegate:self]];
    UIStackView *toolRow1 = [[UIStackView alloc]
        initWithArrangedSubviews:@[_captureButton, _repairButton]];
    UIStackView *toolRow2 = [[UIStackView alloc]
        initWithArrangedSubviews:@[_recoverButton, _logsButton]];
    for (UIStackView *row in @[toolRow1, toolRow2]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
    }

    _statusLabel = [UILabel new];
    _statusLabel.text = @"画面：正在连接 WindowServer 共享帧…";
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _statusLabel.numberOfLines = 0;

    _inputLabel = [UILabel new];
    _inputLabel.text = @"触控：等待桥接服务";
    _inputLabel.textColor = UIColor.systemCyanColor;
    _inputLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _inputLabel.numberOfLines = 0;

    _interopLabel = [UILabel new];
    _interopLabel.text = @"互操作：等待 macOS 剪贴板与文件桥";
    _interopLabel.textColor = UIColor.systemIndigoColor;
    _interopLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                     weight:UIFontWeightRegular];
    _interopLabel.numberOfLines = 0;

    _inputModeControl = [[UISegmentedControl alloc]
        initWithItems:@[@"直接触控", @"精确触控板", @"游戏视角"]];
    MacWSHostInputMode savedInputMode = (MacWSHostInputMode)
        [NSUserDefaults.standardUserDefaults integerForKey:@"MacWSInputMode"];
    if (savedInputMode != MacWSHostInputModeTrackpad &&
        savedInputMode != MacWSHostInputModeGame)
        savedInputMode = MacWSHostInputModeDirect;
    _inputModeControl.selectedSegmentIndex = savedInputMode ==
        MacWSHostInputModeGame ? 2 :
        (savedInputMode == MacWSHostInputModeTrackpad ? 1 : 0);
    _metalView.inputMode = savedInputMode;
    [_inputModeControl addTarget:self action:@selector(inputModeChanged:)
                forControlEvents:UIControlEventValueChanged];

    _densityControl = [[UISegmentedControl alloc]
        initWithItems:@[@"Retina 标准", @"Retina 放大"]];
    _densityControl.selectedSegmentIndex =
        _metalView.displayDensity == MacWSHostDisplayDensityRetinaLarger
            ? 1 : 0;
    [_densityControl addTarget:self action:@selector(densityChanged:)
               forControlEvents:UIControlEventValueChanged];

    _zoomScaleControl = [[UISegmentedControl alloc]
        initWithItems:@[@"双指双击 1.5×", @"双指双击 2.0×"]];
    _zoomScaleControl.selectedSegmentIndex =
        _metalView.fixedZoomScale >= 1.75 ? 1 : 0;
    [_zoomScaleControl addTarget:self action:@selector(zoomScaleChanged:)
                 forControlEvents:UIControlEventValueChanged];
    _resetZoomButton = [self buttonWithTitle:@"退出放大视角"
        image:@"arrow.counterclockwise"
        action:@selector(resetZoomAction) prominent:NO];

    _noticeLabel = MacWSMakeLabel(@"",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.systemCyanColor);
    _noticeLabel.hidden = YES;

    _logsView = [UITextView new];
    _logsView.editable = NO;
    _logsView.selectable = YES;
    _logsView.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.35];
    _logsView.textColor = UIColor.systemGreenColor;
    _logsView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _logsView.layer.cornerRadius = 10;
    _logsView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    _logsView.hidden = YES;
    _logsView.accessibilityLabel = @"macPad 启动日志";
    [_logsView.heightAnchor constraintEqualToConstant:220].active = YES;

    // Interaction choices are the first controls a user needs. Detailed
    // subsystem rows and recovery/debug tools stay out of the production UI;
    // a compact readiness summary remains at the bottom.
    _languageSectionLabel = [self sectionTitle:@"语言"];
    _touchSectionLabel = [self sectionTitle:@"触摸方式"];
    _displaySectionLabel = [self sectionTitle:@"显示密度"];
    _applicationsSectionLabel = [self sectionTitle:@"macOS 应用"];
    _zoomSectionLabel = [self sectionTitle:@"放大视角"];
    _startupLogSectionLabel = [self sectionTitle:@"启动日志（实时）"];
    _startupLogSectionLabel.hidden = YES;
    _retryStartupButton = [self buttonWithTitle:@"重新尝试启动"
        image:@"arrow.clockwise" action:@selector(retryStartupAction)
        prominent:YES];
    _retryStartupButton.hidden = YES;
    _languageControl = [[UISegmentedControl alloc]
        initWithItems:@[@"中文", @"English"]];
    _languageControl.selectedSegmentIndex =
        MacWSControlCenterUsesEnglish() ? 1 : 0;
    [_languageControl addTarget:self action:@selector(languageChanged:)
               forControlEvents:UIControlEventValueChanged];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        header,
        _languageSectionLabel,
        _languageControl,
        _touchSectionLabel,
        _inputModeControl,
        _displaySectionLabel,
        _densityControl,
        _keyboardButton,
        _primaryButton,
        _repairDesktopButton,
        _applicationsSectionLabel,
        _appSearchField,
        appRow1,
        appRow2,
        appRow3,
        appRow4,
        appRow5,
        appRow6,
        appRow7,
        _windowPickerButton,
        _menuBarButton,
        _closeWindowButton,
        _zoomSectionLabel,
        _zoomScaleControl,
        _resetZoomButton,
        _noticeLabel,
        [self divider],
        serviceCard,
        _statusLabel,
        _inputLabel,
        _interopLabel,
        _retryStartupButton,
        _startupLogSectionLabel,
        _logsView,
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 10;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    content.layoutMarginsRelativeArrangement = YES;
    [scroll addSubview:content];

    _showControlsMaterial = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    _showControlsMaterial.translatesAutoresizingMaskIntoConstraints = NO;
    _showControlsMaterial.layer.cornerRadius = 7;
    _showControlsMaterial.layer.cornerCurve = kCACornerCurveContinuous;
    _showControlsMaterial.layer.borderWidth = 0.5;
    _showControlsMaterial.layer.borderColor =
        [UIColor.separatorColor colorWithAlphaComponent:0.28].CGColor;
    _showControlsMaterial.clipsToBounds = YES;
    [root addSubview:_showControlsMaterial];

    _showControlsButton = [self buttonWithTitle:@"控制中心" image:@"sidebar.left"
                                         action:@selector(showControls) prominent:NO];
    _showControlsButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration plainButtonConfiguration];
    configuration.image = [UIImage systemImageNamed:@"switch.2"];
    configuration.preferredSymbolConfigurationForImage =
        [UIImageSymbolConfiguration configurationWithPointSize:14
            weight:UIImageSymbolWeightMedium];
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(2, 6, 2, 6);
    _showControlsButton.configuration = configuration;
    _showControlsButton.accessibilityLabel = @"MacWS 控制中心";
    [_showControlsMaterial.contentView addSubview:_showControlsButton];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    NSLayoutConstraint *responsiveWidth = [_controlPanel.widthAnchor
        constraintEqualToAnchor:safe.widthAnchor multiplier:0.92];
    responsiveWidth.priority = 999;
    NSLayoutYAxisAnchor *metalTop = _semanticMenuBar
        ? _semanticMenuBar.bottomAnchor : root.topAnchor;
    NSLayoutYAxisAnchor *controlTop = _semanticMenuBar
        ? _semanticMenuBar.bottomAnchor : safe.topAnchor;
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_metalView.topAnchor constraintEqualToAnchor:metalTop],
        [_metalView.bottomAnchor constraintEqualToAnchor:_softwareKeyBar.topAnchor],
        [_crossAppDragSurface.leadingAnchor constraintEqualToAnchor:_metalView.leadingAnchor],
        [_crossAppDragSurface.trailingAnchor constraintEqualToAnchor:_metalView.trailingAnchor],
        [_crossAppDragSurface.topAnchor constraintEqualToAnchor:_metalView.topAnchor],
        [_crossAppDragSurface.bottomAnchor constraintEqualToAnchor:_metalView.bottomAnchor],
        [_softwareKeyBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_softwareKeyBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_softwareKeyBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        _softwareKeyBarHeightConstraint,
        [_keyboardProxy.widthAnchor constraintEqualToConstant:1],
        [_keyboardProxy.heightAnchor constraintEqualToConstant:1],
        [_keyboardProxy.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_keyboardProxy.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_controlDismissLayer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_controlDismissLayer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_controlDismissLayer.topAnchor constraintEqualToAnchor:root.topAnchor],
        // Keep the transparent control-center dismissal surface out of the
        // interactive software-keyboard row. When the row is hidden, its top
        // equals root.bottom and the original dismissal area is preserved.
        [_controlDismissLayer.bottomAnchor constraintEqualToAnchor:
            _softwareKeyBar.topAnchor],
        [_controlPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_controlPanel.topAnchor constraintEqualToAnchor:controlTop constant:12],
        [_controlPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [_controlPanel.widthAnchor constraintLessThanOrEqualToConstant:420],
        responsiveWidth,
        [scroll.leadingAnchor constraintEqualToAnchor:_controlPanel.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_controlPanel.contentView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_controlPanel.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_controlPanel.contentView.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [_showControlsMaterial.trailingAnchor constraintEqualToAnchor:
            safe.trailingAnchor constant:-6],
        [_showControlsMaterial.topAnchor constraintEqualToAnchor:
            safe.topAnchor constant:1],
        [_showControlsMaterial.widthAnchor constraintEqualToConstant:38],
        [_showControlsMaterial.heightAnchor constraintEqualToConstant:22],
        [_showControlsButton.leadingAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.leadingAnchor],
        [_showControlsButton.trailingAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.trailingAnchor],
        [_showControlsButton.topAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.topAnchor],
        [_showControlsButton.bottomAnchor constraintEqualToAnchor:
            _showControlsMaterial.contentView.bottomAnchor],
    ]];
    if (_semanticMenuBar) {
        _semanticMenuHeightConstraint = [_semanticMenuBar.heightAnchor
            constraintEqualToConstant:MacWSNativeMenuBarHeight];
        [NSLayoutConstraint activateConstraints:@[
            [_semanticMenuBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [_semanticMenuBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [_semanticMenuBar.topAnchor constraintEqualToAnchor:root.topAnchor],
            _semanticMenuHeightConstraint,
        ]];
        // _semanticMenuBar is constructed for every controller and hidden by
        // updateWorkspaceChrome in fullscreen mode.  Its mere existence is
        // therefore not evidence that this Scene owns a concrete AppKit
        // window. Runtime-confirmed via MacWSHost-ui.png on 2026-08-29: after
        // the desktop had been stopped, a freshly launched fullscreen Scene
        // entered this branch and showed a black canvas with only the tiny
        // Control Center affordance. Hide the panel only for an exact native
        // macOS window; a workspace/bootstrap Scene must remain an operable
        // launcher while its display service is offline.
        if (_streamMode == MacWSStreamModeWindow && _windowID != 0) {
            _controlPanel.hidden = YES;
            _showControlsMaterial.hidden = NO;
        }
    }
    [self applyControlCenterLanguage];
    [self updateWorkspaceChrome];
}

- (void)languageChanged:(UISegmentedControl *)sender {
    NSString *language = sender.selectedSegmentIndex == 1 ? @"en" : @"zh-Hans";
    [NSUserDefaults.standardUserDefaults setObject:language
        forKey:MacWSControlCenterLanguageDefaultsKey];
    [self applyControlCenterLanguage];
    [self updateWorkspaceChrome];
    if (_latestStatus) [self applyStatus:_latestStatus];
}

- (void)applyControlCenterLanguage {
    BOOL english = MacWSControlCenterUsesEnglish();
    _controlTitleLabel.text = english ? @"macPad Control Center" : @"macPad 控制中心";
    _controlSubtitleLabel.text = english
        ? @"Native iPadOS windows · macOS AGX workspace"
        : @"iPadOS 原生窗口 · macOS AGX 工作区";
    _languageSectionLabel.text = (english ? @"LANGUAGE" : @"语言");
    _touchSectionLabel.text = (english ? @"TOUCH MODE" : @"触摸方式");
    _displaySectionLabel.text = (english ? @"DISPLAY DENSITY" : @"显示密度");
    _performanceSectionLabel.text = (english ? @"PERFORMANCE" : @"性能测量");
    _applicationsSectionLabel.text = (english ? @"MACOS APPS" : @"MACOS 应用");
    _zoomSectionLabel.text = (english ? @"ZOOM VIEW" : @"放大视角");
    _startupLogSectionLabel.text = english
        ? @"STARTUP LOG (LIVE)" : @"启动日志（实时）";
    _systemHUDTitleLabel.text = english ? @"Apple System Rendering HUD" : @"Apple 系统渲染 HUD";
    _systemHUDDetailLabel.text = english
        ? @"QuartzCore RenderServer system FPS / GPU / hitch view"
        : @"QuartzCore RenderServer 全系统 FPS / GPU / 卡顿视图";

    [_inputModeControl setTitle:(english ? @"Direct Touch" : @"直接触控")
              forSegmentAtIndex:0];
    [_inputModeControl setTitle:(english ? @"Precision Trackpad" : @"精确触控板")
              forSegmentAtIndex:1];
    [_inputModeControl setTitle:(english ? @"Game Camera" : @"游戏视角")
              forSegmentAtIndex:2];
    NSArray *density = english
        ? @[@"Retina Standard", @"Retina Larger"]
        : @[@"Retina 标准", @"Retina 放大"];
    NSArray *presentationResolution = english
        ? @[@"Auto Sharp", @"Always Sharp", @"Performance"]
        : @[@"自动清晰", @"始终清晰", @"性能优先"];
    NSArray *hud = english ? @[@"Off", @"Compact", @"Full"]
                           : @[@"关闭", @"简洁", @"完整"];
    NSArray *zoom = english ? @[@"Two-Finger Double-Tap 1.5×",
                                @"Two-Finger Double-Tap 2.0×"]
                            : @[@"双指双击 1.5×", @"双指双击 2.0×"];
    for (NSInteger index = 0; index < 2; index++)
        [_densityControl setTitle:density[(NSUInteger)index]
                forSegmentAtIndex:index];
    for (NSInteger index = 0; index < 3; index++) {
        [_performanceHUDControl setTitle:hud[(NSUInteger)index]
                forSegmentAtIndex:index];
        [_presentationResolutionControl
            setTitle:presentationResolution[(NSUInteger)index]
            forSegmentAtIndex:index];
    }
    for (NSInteger index = 0; index < 2; index++)
        [_zoomScaleControl setTitle:zoom[(NSUInteger)index]
                  forSegmentAtIndex:index];

    NSDictionary<NSString *, NSArray<NSString *> *> *appTitles = @{
        @"glassdemo": @[@"GlassDemo", @"GlassDemo"],
        @"terminal": @[@"终端", @"Terminal"],
        @"activity-monitor": @[@"活动监视器", @"Activity Monitor"],
        @"finder": @[@"Finder", @"Finder"],
        @"vscode": @[@"VS Code", @"VS Code"],
        @"system-settings": @[@"系统设置", @"System Settings"],
        @"maps": @[@"地图", @"Maps"],
        @"weather": @[@"天气", @"Weather"],
        @"sublime": @[@"Sublime Text", @"Sublime Text"],
        @"steam": @[@"Steam", @"Steam"],
        @"amadine": @[@"Amadine", @"Amadine"],
        @"word": @[@"Word", @"Word"],
        @"excel": @[@"Excel", @"Excel"],
        @"powerpoint": @[@"PowerPoint", @"PowerPoint"],
    };
    for (UIButton *button in _applicationButtons) {
        NSArray<NSString *> *titles = appTitles[button.accessibilityIdentifier];
        if (!titles) continue;
        UIButtonConfiguration *configuration = [button.configuration copy];
        configuration.title = titles[english ? 1 : 0];
        button.configuration = configuration;
    }
    _appSearchField.placeholder = english
        ? @"Search apps or enter an absolute macOS path"
        : @"搜索应用或输入 macOS 绝对路径";
    [self setButton:_keyboardButton
              title:english ? @"Open Software Keyboard" : @"打开虚拟键盘"
              image:@"keyboard"];
    [self setButton:_captureButton title:english ? @"Refresh Display" : @"刷新画面"
              image:@"camera.viewfinder"];
    [self setButton:_repairDesktopButton
              title:english ? @"Repair Desktop" : @"修复桌面"
              image:@"arrow.clockwise.circle"];
    [self setButton:_repairButton title:english ? @"Repair Environment" : @"修复环境"
              image:@"wrench.and.screwdriver"];
    [self setButton:_recoverButton title:english ? @"Safe Recovery" : @"安全恢复"
              image:@"lifepreserver"];
    [self setButton:_logsButton title:english ? @"View Logs" : @"查看日志"
              image:@"doc.text.magnifyingglass"];
    [self setButton:_exportButton title:english ? @"Export Diagnostics" : @"导出诊断"
              image:@"square.and.arrow.up"];
    [self setButton:_windowPickerButton title:english ? @"Open macOS Window" : @"打开 macOS 窗口"
              image:@"macwindow.on.rectangle"];
    [self setButton:_closeWindowButton title:english ? @"Close This macOS Window" : @"关闭此 macOS 窗口"
              image:@"xmark.square"];
    [self updateCrossAppDragButton];
    [self setButton:_performanceResetButton title:english ? @"Reset Timing" : @"重新计时"
              image:@"stopwatch"];
    [self setButton:_performanceExportButton title:english ? @"Export JSON" : @"导出 JSON"
              image:@"square.and.arrow.up"];
    [self setButton:_performanceRunButton title:english ? @"Run Touch / Gesture Regression" : @"运行标准触摸 / 手势回归"
              image:@"hand.draw"];
    [self setButton:_resetZoomButton title:english ? @"Exit Zoom View" : @"退出放大视角"
              image:@"arrow.counterclockwise"];
    [self setButton:_retryStartupButton
              title:english ? @"Try Starting Again" : @"重新尝试启动"
              image:@"arrow.clockwise"];
    _showControlsButton.accessibilityLabel = english
        ? @"macPad Control Center" : @"macPad 控制中心";
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _gamePointerLockViewVisible = YES;
    UISceneActivationState activation = self.view.window.windowScene.activationState;
    if (activation != UISceneActivationStateBackground &&
        activation != UISceneActivationStateUnattached &&
        !(_bootstrapTerminalPending && _windowID == 0)) {
        [_metalView configureStreamMode:_streamMode windowID:_windowID];
        // Configure first so targetWindowID is the synchronous presentation
        // authority before any logical AppKit size is converted into Scene
        // points. willConnectToSession previously requested geometry before
        // this boundary, when the display client still reported its old
        // fullscreen subscription and effectiveDensityScale took the 2.2x
        // desktop path for exactly one transaction.
        if (_streamMode == MacWSStreamModeWindow && _windowID != 0 &&
            _windowPreferredSize.width > 0.0 &&
            _windowPreferredSize.height > 0.0) {
            if (_initialSceneSizePending &&
                _publishedInitialSceneSize.width >= 150.0 &&
                _publishedInitialSceneSize.height >= 150.0) {
                uint64_t serial = ++_initialSceneSizePostconditionSerial;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             350 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    if (serial != self->_initialSceneSizePostconditionSerial ||
                        !self->_initialSceneSizePending) return;
                    CGSize actual = self.view.window.bounds.size;
                    CGSize expected = self->_publishedInitialSceneSize;
                    BOOL landed = fabs(actual.width - expected.width) <= 1.5 &&
                        fabs(actual.height - expected.height) <= 1.5;
                    self->_initialSceneSizePending = NO;
                    MacWSLog(@"scene-initial-size postcondition id=%@ landed=%@ expected=%.1fx%.1f actual=%.1fx%.1f action=%@",
                        self.view.window.windowScene.session.persistentIdentifier,
                        landed ? @"YES" : @"NO", expected.width,
                        expected.height, actual.width, actual.height,
                        landed ? @"keep-initial-layout" : @"fallback-resize");
                    if (!landed) {
                        [self followNativeSceneSizeForAppliedLogicalSize:
                            self->_windowPreferredSize
                                                          reason:
                            @"initial-layout-postcondition-failed"];
                    }
                    [self applyDeferredForegroundSceneSize];
                });
            } else {
                [self followNativeSceneSizeForAppliedLogicalSize:
                    _windowPreferredSize reason:@"view-did-appear"];
            }
        }
    }
    if (_windowID != 0) [self refreshSemanticMenuWithCompletion:nil];
    [self refreshStatus];
    [_statusTimer invalidate];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
        selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    [_metalView requestStreamWindowList];
    [_interopClient connect];
    [self restoreHardwareKeyboardFocusWithReason:@"view-did-appear"];
    [self updateGamePointerLockPreferenceWithReason:@"view-did-appear"];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self dismissSemanticMenu];
    [_metalView geometryDidChange];
    [coordinator animateAlongsideTransition:nil completion:^(
        id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        [self sceneGeometryDidChange];
    }];
}

- (void)sceneGeometryDidChange {
    if (_sceneDestructionRequested) return;
    // UIWindowScene reports Stage Manager resizing as coordinate-space
    // updates, while ordinary split/full-screen transitions arrive through
    // view-controller layout.  Converge both on one transform/configuration
    // boundary so input and pixels never use different generations.
    [self dismissSemanticMenu];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [_metalView geometryDidChange];
}

- (void)captureDefaultSceneSizeRestrictionsIfNeeded {
    if (_capturedSceneSizeRestrictions) return;
    UIWindowScene *windowScene = self.view.window.windowScene ?:
        _connectedWindowScene;
    UISceneSizeRestrictions *restrictions =
        windowScene.sizeRestrictions;
    if (!restrictions) {
        if (!_reportedSceneSizeRestrictionsUnavailable) {
            _reportedSceneSizeRestrictionsUnavailable = YES;
            MacWSLog(@"scene-size-restrictions unavailable id=%@ route=springboard-exact-scene-policy",
                     windowScene.session.persistentIdentifier);
        }
        return;
    }
    _defaultSceneMinimumSize = restrictions.minimumSize;
    _defaultSceneMaximumSize = restrictions.maximumSize;
    _appliedSceneRestrictionMinimumSize = _defaultSceneMinimumSize;
    _appliedSceneRestrictionMaximumSize = _defaultSceneMaximumSize;
    _capturedSceneSizeRestrictions = YES;
    MacWSLog(@"scene-size-restrictions captured id=%@ minimum=%.1fx%.1f maximum=%.1fx%.1f",
             windowScene.session.persistentIdentifier,
             _defaultSceneMinimumSize.width,
             _defaultSceneMinimumSize.height,
             _defaultSceneMaximumSize.width,
             _defaultSceneMaximumSize.height);
}

- (void)applySceneSizeRestrictionMinimum:(CGSize)minimum
                                  maximum:(CGSize)maximum
                                   reason:(NSString *)reason {
    [self captureDefaultSceneSizeRestrictionsIfNeeded];
    UIWindowScene *windowScene = self.view.window.windowScene ?:
        _connectedWindowScene;
    UISceneSizeRestrictions *restrictions =
        windowScene.sizeRestrictions;
    if (!restrictions || !_capturedSceneSizeRestrictions ||
        !isfinite(minimum.width) || !isfinite(minimum.height) ||
        !isfinite(maximum.width) || !isfinite(maximum.height) ||
        minimum.width < 0.0 || minimum.height < 0.0 ||
        maximum.width < minimum.width || maximum.height < minimum.height)
        return;
    if (fabs(minimum.width - _appliedSceneRestrictionMinimumSize.width) < 0.5 &&
        fabs(minimum.height - _appliedSceneRestrictionMinimumSize.height) < 0.5 &&
        fabs(maximum.width - _appliedSceneRestrictionMaximumSize.width) < 0.5 &&
        fabs(maximum.height - _appliedSceneRestrictionMaximumSize.height) < 0.5)
        return;

    // UISceneSizeRestrictions is UIKit's public, per-Scene sizing policy.
    // Widen maximum first, then change minimum, then install the real maximum
    // so no intermediate assignment has maximum < minimum on either axis.
    CGSize bridgeMaximum = CGSizeMake(
        MAX(MAX(restrictions.maximumSize.width, maximum.width), minimum.width),
        MAX(MAX(restrictions.maximumSize.height, maximum.height), minimum.height));
    restrictions.maximumSize = bridgeMaximum;
    restrictions.minimumSize = minimum;
    restrictions.maximumSize = maximum;
    _appliedSceneRestrictionMinimumSize = minimum;
    _appliedSceneRestrictionMaximumSize = maximum;
    MacWSLog(@"scene-size-restrictions applied id=%@ reason=%@ minimum=%.1fx%.1f maximum=%.1fx%.1f fixed=%@",
             windowScene.session.persistentIdentifier,
             reason ?: @"unknown", minimum.width, minimum.height,
             maximum.width, maximum.height,
             CGSizeEqualToSize(minimum, maximum) ? @"YES" : @"NO");
}

- (void)restoreDefaultSceneSizeRestrictions {
    if (!_capturedSceneSizeRestrictions) return;
    [self applySceneSizeRestrictionMinimum:_defaultSceneMinimumSize
                                    maximum:_defaultSceneMaximumSize
                                     reason:@"restore-system-default"];
}

- (void)prepareInitialWindowSceneGeometryForScene:(UIWindowScene *)scene
                                     initialBounds:(CGRect)initialBounds
                              publishedInitialSize:(CGSize)publishedInitialSize
                           publishedMinimumSize:(CGSize)publishedMinimumSize {
    if (_sceneDestructionRequested ||
        _streamMode != MacWSStreamModeWindow || _windowID == 0 ||
        _windowPreferredSize.width < 64.0 ||
        _windowPreferredSize.height < 64.0 || !scene)
        return;

    // Setting rootViewController attaches the hierarchy to the concrete
    // UIWindowScene before makeKeyAndVisible. Resolve the real menu-bar/safe-
    // area chrome now and submit the exact AppKit size while the UIKit window
    // is still hidden. The prior viewDidAppear-only route exposed UIKit's
    // stock 1004x807 panel before the first 331x411 transaction even existed.
    _connectedWindowScene = scene;
    [self loadViewIfNeeded];
    if (initialBounds.size.width >= 150.0 &&
        initialBounds.size.height >= 150.0)
        self.view.frame = initialBounds;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    if (publishedInitialSize.width >= 150.0 &&
        publishedInitialSize.height >= 150.0) {
        // Install the same AppKit-derived policy on UIKit's public per-Scene
        // contract before the UIWindow becomes visible.  SpringBoard's
        // initial AppLayout hook chooses the first geometry, while these
        // restrictions prevent the first resize gesture from temporarily
        // accepting a size that the target NSWindow cannot represent.  A
        // fixed axis receives one value; the other axis retains the system's
        // captured maximum and the AppKit minimum.
        CGSize restrictionMinimum = CGSizeMake(
            MAX(150.0, publishedMinimumSize.width),
            MAX(150.0, publishedMinimumSize.height));
        if (!isfinite(restrictionMinimum.width))
            restrictionMinimum.width = 150.0;
        if (!isfinite(restrictionMinimum.height))
            restrictionMinimum.height = 150.0;
        [self captureDefaultSceneSizeRestrictionsIfNeeded];
        CGSize restrictionMaximum = _capturedSceneSizeRestrictions
            ? _defaultSceneMaximumSize : CGSizeMake(4096.0, 4096.0);
        if (_windowWidthFixed) {
            restrictionMinimum.width = publishedInitialSize.width;
            restrictionMaximum.width = publishedInitialSize.width;
        }
        if (_windowHeightFixed) {
            restrictionMinimum.height = publishedInitialSize.height;
            restrictionMaximum.height = publishedInitialSize.height;
        }
        restrictionMaximum.width = MAX(restrictionMaximum.width,
                                       restrictionMinimum.width);
        restrictionMaximum.height = MAX(restrictionMaximum.height,
                                        restrictionMinimum.height);
        [self applySceneSizeRestrictionMinimum:restrictionMinimum
                                        maximum:restrictionMaximum
                                         reason:@"pre-visible-appkit-policy"];
        _initialSceneSizePending = YES;
        _publishedInitialSceneSize = publishedInitialSize;
        MacWSLog(@"scene-initial-size awaiting-layout id=%@ expected=%.1fx%.1f minimum=%.1fx%.1f fixed=%@x%@ current=%.1fx%.1f",
            scene.session.persistentIdentifier, publishedInitialSize.width,
            publishedInitialSize.height, restrictionMinimum.width,
            restrictionMinimum.height, _windowWidthFixed ? @"YES" : @"NO",
            _windowHeightFixed ? @"YES" : @"NO",
            scene.coordinateSpace.bounds.size.width,
            scene.coordinateSpace.bounds.size.height);
        return;
    }
    [self followNativeSceneSizeForAppliedLogicalSize:_windowPreferredSize
                                              reason:@"pre-visible-connect"];
}

- (void)followNativeSceneSizeForAppliedLogicalSize:(CGSize)logicalSize
                                            reason:(NSString *)reason {
    [self updateNativeSceneSizeForAppliedLogicalSize:logicalSize
        reason:reason policyOnly:NO];
}

- (void)updateNativeSceneSizeForAppliedLogicalSize:(CGSize)logicalSize
                                            reason:(NSString *)reason
                                        policyOnly:(BOOL)policyOnly {
    if (_sceneDestructionRequested ||
        _streamMode != MacWSStreamModeWindow || _windowID == 0 ||
        !isfinite(logicalSize.width) || !isfinite(logicalSize.height) ||
        logicalSize.width < 64.0 || logicalSize.height < 64.0) return;
    UIWindowScene *owningScene = self.viewIfLoaded.window.windowScene ?:
        _connectedWindowScene;
    // Native corner ownership outlives a pause in bounds notifications. Do
    // not submit a reciprocal workspace transaction while that finger is down.
    if (_metalView.nativeWindowResizeGestureActive) policyOnly = YES;
    if (!policyOnly &&
        owningScene.activationState == UISceneActivationStateBackground) {
        // A background app can change its own size. Publish only its limits
        // now; applying a geometry transaction would pull its old Stage to
        // the front. Keep the latest exact target because catalog handling
        // already updates _windowPreferredSize and will not rediscover this
        // same geometry as a change when the user returns.
        _deferredBackgroundSceneLogicalSize = logicalSize;
        _deferredBackgroundSceneWindowID = _windowID;
        _deferredBackgroundSceneOwnerPID = _windowOwnerPID;
        policyOnly = YES;
        MacWSLog(@"scene-size deferred-background window=%u pid=%d logical=%.1fx%.1f reason=%@",
            _windowID, _windowOwnerPID, logicalSize.width, logicalSize.height,
            reason ?: @"unknown");
    }
    // The pre-activation SpringBoard transaction is already authoritative for
    // a new Scene. Runtime-confirmed by MacWSHost.log 1789110580.857-.898:
    // About Finder connected at 330x410 for the published 331x411 target, but
    // the first catalog refresh submitted the same geometry again before the
    // 350-ms initial postcondition. That second Primary-role transaction
    // changed UIKit to the stock 327x603 preset. Wait for the initial
    // transaction's concrete UIWindow postcondition before allowing normal
    // AppKit-autonomous size synchronization.
    if (_initialSceneSizePending && !policyOnly) {
        MacWSLog(@"window-size follows-appkit deferred window=%u pid=%d reason=%@ state=initial-layout-pending",
                 _windowID, _windowOwnerPID, reason ?: @"unknown");
        return;
    }
    CGFloat density = _metalView.effectiveDensityScale;
    if (!isfinite(density) || density <= 0.0) density = 1.0;
    [self.view layoutIfNeeded];
    UIWindowScene *windowScene = self.view.window.windowScene ?:
        _connectedWindowScene;
    CGSize chrome = CGSizeMake(
        MAX(0.0, self.view.bounds.size.width - _metalView.bounds.size.width),
        MAX(0.0, self.view.bounds.size.height - _metalView.bounds.size.height));
    if (_streamMode == MacWSStreamModeWindow) {
        CGFloat systemTop = MAX(self.view.safeAreaInsets.top,
            windowScene.statusBarManager.statusBarFrame.size.height);
        // Before makeKeyAndVisible, UIKit has not attached the controller's
        // safe-area guide yet. The visible hierarchy uses the same compact
        // semantic menu plus the status-bar inset; use that same public
        // geometry instead of issuing one undersized pre-visible request.
        chrome.height = MAX(chrome.height, MacWSNativeMenuBarHeight + systemTop);
    }
    CGSize sceneTarget = CGSizeMake(logicalSize.width * density + chrome.width,
                                    logicalSize.height * density + chrome.height);
    [self captureDefaultSceneSizeRestrictionsIfNeeded];
    // A frame update and its window-catalog metadata are separate producer
    // messages. Runtime-confirmed by Finder.host.log generation 36/37 and
    // MacWSWindowing.log 1789070739.052: Get Info had already contracted from
    // 501 to 467 points, while the controller still carried the preceding
    // 501-point minimum. That produced target=440x566, minimum=292x603 and
    // SpringBoard correctly rejected the impossible request. The concrete
    // AppKit frame is proof that a preceding minimum is no longer current;
    // bound each stale catalog axis by the applied size until the matching
    // catalog generation arrives.
    CGSize effectiveMinimumLogical = CGSizeMake(
        _windowMinimumSize.width > 0.0
            ? MIN(_windowMinimumSize.width, logicalSize.width) : 0.0,
        _windowMinimumSize.height > 0.0
            ? MIN(_windowMinimumSize.height, logicalSize.height) : 0.0);
    CGSize restrictionMinimum = CGSizeMake(
        ceil(MAX(150.0, effectiveMinimumLogical.width * density + chrome.width)),
        ceil(MAX(150.0, effectiveMinimumLogical.height * density + chrome.height)));
    BOOL fixedWidth = !_windowResizable || _windowWidthFixed;
    BOOL fixedHeight = !_windowResizable || _windowHeightFixed;
    CGSize restrictionMaximum = _capturedSceneSizeRestrictions
        ? _defaultSceneMaximumSize
        : CGSizeMake(4096.0, 4096.0);
    CGFloat sourceMaximumWidth = MacWSSceneMaximumAxis(
        _windowMaximumSize.width, density, chrome.width, restrictionMinimum.width);
    CGFloat sourceMaximumHeight = MacWSSceneMaximumAxis(
        _windowMaximumSize.height, density, chrome.height, restrictionMinimum.height);
    if (sourceMaximumWidth > 0.0) restrictionMaximum.width = sourceMaximumWidth;
    if (sourceMaximumHeight > 0.0) restrictionMaximum.height = sourceMaximumHeight;
    if (fixedWidth) {
        sceneTarget.width = ceil(sceneTarget.width);
        restrictionMinimum.width = sceneTarget.width;
        restrictionMaximum.width = sceneTarget.width;
    }
    if (fixedHeight) {
        sceneTarget.height = ceil(sceneTarget.height);
        restrictionMinimum.height = sceneTarget.height;
        restrictionMaximum.height = sceneTarget.height;
    }
    if (!fixedWidth || !fixedHeight) {
        if (!fixedWidth)
            restrictionMaximum.width = MAX(restrictionMaximum.width,
                                           restrictionMinimum.width);
        if (!fixedHeight)
            restrictionMaximum.height = MAX(restrictionMaximum.height,
                                            restrictionMinimum.height);
    }
    [self applySceneSizeRestrictionMinimum:restrictionMinimum
                                    maximum:restrictionMaximum
                                     reason:reason];
    if (policyOnly) {
        // Runtime-confirmed Get Info 1789182729.058-.421: an animation's
        // first 466-point request was still in flight when the 555-point
        // terminal size arrived. Policy-only publication lost that latest
        // geometry. Keep one exact-target successor, but never retain a
        // catalog snapshot over a native gesture or a pending configure ACK.
        if (_metalView.sceneResizeFollowingTargetWindow &&
            !_metalView.nativeWindowResizeGestureActive &&
            !_metalView.windowConfigurationAwaitingAcknowledgement &&
            !_metalView.windowConfigurationAwaitingSettlement &&
            !_metalView.windowConfigurationHasQueuedRequest) {
            _deferredAppKitSceneLogicalSize = logicalSize;
            _deferredAppKitSceneWindowID = _windowID;
            _deferredAppKitSceneOwnerPID = _windowOwnerPID;
            MacWSLog(@"window-size appkit-animation deferred window=%u pid=%d latest=%.1fx%.1f",
                _windowID, _windowOwnerPID, logicalSize.width, logicalSize.height);
        }
        MacWSRequestNativeSceneSizeWithRole(windowScene, sceneTarget,
            restrictionMinimum, restrictionMaximum, fixedWidth, fixedHeight,
            NO, YES, nil);
        return;
    }
    UIWindow *sceneWindow = self.view.window;
    CGSize currentSceneSize = sceneWindow
        ? sceneWindow.bounds.size : windowScene.coordinateSpace.bounds.size;
    // Do not submit an AppLayout transition when the visible UIKit window
    // already represents the AppKit target. Besides avoiding a redundant
    // animation, this preserves the exact Center-window geometry selected by
    // the initial layout path. The 1.5-point tolerance matches the rounded
    // Scene postcondition and covers the observed 331x411 -> 330x410 UIKit
    // edge rounding without accepting a stock preset or a black-border-sized
    // mismatch.
    if (currentSceneSize.width >= restrictionMinimum.width &&
        currentSceneSize.height >= restrictionMinimum.height &&
        fabs(sceneTarget.width - currentSceneSize.width) <= 1.5 &&
        fabs(sceneTarget.height - currentSceneSize.height) <= 1.5) {
        // Update the exact Scene policy even when no geometry transaction is
        // needed. Otherwise newly discovered AppKit limits never reach the
        // SpringBoard resize gesture until the first over-sized request.
        MacWSRequestNativeSceneSizeWithRole(windowScene, sceneTarget,
            restrictionMinimum, restrictionMaximum, fixedWidth, fixedHeight,
            NO, YES, nil);
        _lastConstrainedSceneTargetSize = sceneTarget;
        _lastConstrainedSceneResizeRequestTime = CACurrentMediaTime();
        MacWSLog(@"window-size follows-appkit skipped window=%u pid=%d reason=%@ scene=%.1fx%.1f current=%.1fx%.1f state=already-matches",
                 _windowID, _windowOwnerPID, reason ?: @"unknown",
                 sceneTarget.width, sceneTarget.height,
                 currentSceneSize.width, currentSceneSize.height);
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (fabs(sceneTarget.width - _lastConstrainedSceneTargetSize.width) < 1.0 &&
        fabs(sceneTarget.height - _lastConstrainedSceneTargetSize.height) < 1.0 &&
        now - _lastConstrainedSceneResizeRequestTime < 0.75) return;
    _lastConstrainedSceneTargetSize = sceneTarget;
    _lastConstrainedSceneResizeRequestTime = now;
    _deferredAppKitSceneWindowID = 0;
    uint64_t resizeSerial = ++_constrainedSceneResizeSerial;
    uint32_t expectedWindowID = _windowID;
    NSString *expectedSessionIdentifier =
        windowScene.session.persistentIdentifier;
    [_metalView beginSceneResizeFollowingTargetWindowLogicalSize:logicalSize];
    __weak typeof(self) weakSelf = self;
    BOOL requested = MacWSRequestNativeSceneSizeWithRole(
        windowScene, sceneTarget, restrictionMinimum, restrictionMaximum,
        fixedWidth, fixedHeight, NO, NO,
        ^(CGSize actualSceneSize, BOOL landed) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf ||
                strongSelf->_constrainedSceneResizeSerial != resizeSerial ||
                strongSelf->_windowID != expectedWindowID ||
                ![strongSelf.view.window.windowScene.session
                    .persistentIdentifier
                    isEqualToString:expectedSessionIdentifier]) return;
            [strongSelf->_metalView
                cancelSceneResizeFollowingTargetWindow];
            if (strongSelf.view.window.windowScene.activationState ==
                    UISceneActivationStateBackground) {
                if (strongSelf->_deferredBackgroundSceneWindowID == 0) {
                    strongSelf->_deferredBackgroundSceneLogicalSize = logicalSize;
                    strongSelf->_deferredBackgroundSceneWindowID = expectedWindowID;
                    strongSelf->_deferredBackgroundSceneOwnerPID =
                        strongSelf->_windowOwnerPID;
                }
                return;
            }
            if (strongSelf->_deferredAppKitSceneWindowID == expectedWindowID &&
                strongSelf->_deferredAppKitSceneOwnerPID ==
                    strongSelf->_windowOwnerPID) {
                CGSize latest = strongSelf->_deferredAppKitSceneLogicalSize;
                strongSelf->_deferredAppKitSceneWindowID = 0;
                if (!strongSelf->_metalView.nativeWindowResizeGestureActive &&
                    !strongSelf->_metalView.windowConfigurationAwaitingAcknowledgement &&
                    !strongSelf->_metalView.windowConfigurationHasQueuedRequest) {
                    [strongSelf followNativeSceneSizeForAppliedLogicalSize:latest
                        reason:@"appkit-animation-latest"];
                    return;
                }
            }
            if (landed) return;
            BOOL flexibleAxisMismatch =
                (!fixedWidth && fabs(actualSceneSize.width -
                                     sceneTarget.width) > 1.5) ||
                (!fixedHeight && fabs(actualSceneSize.height -
                                      sceneTarget.height) > 1.5);
            if (!flexibleAxisMismatch) {
                MacWSLog(@"scene-native-size mismatch window=%u pid=%d requested=%.1fx%.1f actual=%.1fx%.1f fixed=%@x%@ action=preserve-appkit-fixed-axis",
                         strongSelf->_windowID,
                         strongSelf->_windowOwnerPID,
                         sceneTarget.width, sceneTarget.height,
                         actualSceneSize.width, actualSceneSize.height,
                         fixedWidth ? @"YES" : @"NO",
                         fixedHeight ? @"YES" : @"NO");
                return;
            }
            // Runtime-confirmed by MacWSHost.log at
            // 1789117729.733-1789117731.261: a restored Finder Scene can be
            // packed by Stage Manager to 440x603 even after SpringBoard's
            // AppLayout accepted the requested 490x603 model size.  Once the
            // completed transaction's concrete UIWindow disagrees, that
            // visible Scene is authoritative on each flexible axis.  Feed
            // its geometry through the ordinary ConfigureWindow path instead
            // of retaining a clipped 445-point AppKit source indefinitely.
            MacWSLog(@"scene-native-size mismatch window=%u pid=%d requested=%.1fx%.1f actual=%.1fx%.1f fixed=%@x%@ action=configure-appkit-to-visible-scene",
                     strongSelf->_windowID, strongSelf->_windowOwnerPID,
                     sceneTarget.width, sceneTarget.height,
                     actualSceneSize.width, actualSceneSize.height,
                     fixedWidth ? @"YES" : @"NO",
                     fixedHeight ? @"YES" : @"NO");
            [strongSelf sceneGeometryDidChange];
        });
    if (!requested)
        [_metalView cancelSceneResizeFollowingTargetWindow];
    MacWSLog(@"window-size follows-appkit window=%u pid=%d reason=%@ logical=%.1fx%.1f density=%.3f chrome=%.1fx%.1f scene=%.1fx%.1f fixed=%@x%@ requested=%@",
             _windowID, _windowOwnerPID, reason ?: @"unknown",
             logicalSize.width, logicalSize.height, density,
             chrome.width, chrome.height, sceneTarget.width,
             sceneTarget.height, fixedWidth ? @"YES" : @"NO",
             fixedHeight ? @"YES" : @"NO",
             requested ? @"YES" : @"NO");
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _gamePointerLockViewVisible = NO;
    [self updateGamePointerLockPreferenceWithReason:@"view-will-disappear"];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)hideControls {
    _controlPanel.hidden = YES;
    _controlDismissLayer.hidden = YES;
    _showControlsMaterial.hidden = NO;
    // The tapped control remains UIKit's responder until this event returns.
    // Reclaim the workspace's physical-keyboard focus on the next main turn.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self restoreHardwareKeyboardFocusWithReason:@"controls-hidden"];
        [self updateGamePointerLockPreferenceWithReason:@"controls-hidden"];
    });
}

- (void)showControls {
    _controlDismissLayer.hidden = NO;
    _controlPanel.hidden = NO;
    _showControlsMaterial.hidden = YES;
    [self updateGamePointerLockPreferenceWithReason:@"controls-shown"];
}

- (BOOL)prefersPointerLocked API_AVAILABLE(ios(14.0)) {
    UIWindowScene *scene = self.viewIfLoaded.window.windowScene ?:
        _connectedWindowScene;
    return _gamePointerLockViewVisible &&
        _metalView.inputMode == MacWSHostInputModeGame &&
        _controlPanel.hidden && _metalView.isMacWSInputEnabled &&
        _metalView.targetPID > 1 &&
        scene.activationState == UISceneActivationStateForegroundActive;
}

- (void)updateGamePointerLockPreferenceWithReason:(NSString *)reason {
    if (@available(iOS 14.0, *)) {
        UIWindowScene *scene = self.viewIfLoaded.window.windowScene ?:
            _connectedWindowScene;
        BOOL requested = [self prefersPointerLocked];
        [self setNeedsUpdateOfPrefersPointerLocked];
        BOOL locked = requested && scene.pointerLockState.isLocked;
        _metalView.gamePointerLockActive = locked;
        if (_lastGamePointerLockPreference != requested ||
            MacWSHostGamePointerDiagnosticsEnabled()) {
            MacWSLog(@"game-pointer-preference requested=%@ locked=%@ reason=%@ scene=%@ state=%ld pid=%d window=%u",
                requested ? @"YES" : @"NO", locked ? @"YES" : @"NO",
                reason ?: @"unknown", scene.session.persistentIdentifier,
                (long)scene.activationState, _metalView.targetPID,
                _metalView.targetWindowID);
        }
        _lastGamePointerLockPreference = requested;
    }
}

- (void)pointerLockStateDidChange:(NSNotification *)notification
    API_AVAILABLE(ios(14.0)) {
    UIScene *changedScene = notification.userInfo[
        UIPointerLockStateSceneUserInfoKey];
    UIWindowScene *ownScene = self.viewIfLoaded.window.windowScene ?:
        _connectedWindowScene;
    if (changedScene && changedScene != ownScene) return;
    [self updateGamePointerLockPreferenceWithReason:@"lock-state-changed"];
}

- (void)restoreHardwareKeyboardFocusWithReason:(NSString *)reason {
    // Ownership, not overlay visibility, decides where a physical key goes.
    // Runtime-confirmed via MacWSHost.log 1788452170.166: the current
    // fullscreen workspace (mode=1) can restore hardware focus while this
    // source keeps its control panel visible. The former `_controlPanel.hidden`
    // predicate rejected that route before the already-healthy broker could
    // see it. Preserve UIKit typing only for the two real text responders
    // owned by this controller.
    if (_keyboardProxy.isFirstResponder || _appSearchField.isFirstResponder)
        return;
    UIWindow *window = self.viewIfLoaded.window;
    if ([window respondsToSelector:@selector(_isApplicationKeyWindow)] &&
        ![window _isApplicationKeyWindow]) return;
    [_metalView restoreHardwareKeyboardFocusWithReason:reason];
}

- (BOOL)forwardHardwarePressEvent:(UIPressesEvent *)event {
    if (_appSearchField.isFirstResponder || !event)
        return NO;
    BOOL textInputActive = _keyboardProxy.isFirstResponder;
    BOOL forwarded = NO;
    for (UIPress *press in event.allPresses) {
        UIKey *key = press.key;
        if (textInputActive &&
            (!key || !MacWSHardwareKeyRequiresMacRouteDuringTextInput(
                (uint32_t)key.keyCode, (uint32_t)key.modifierFlags))) {
            continue;
        }
        BOOL keyDown = NO;
        switch (press.phase) {
            case UIPressPhaseBegan:
                if (!_metalView.isMacWSInputEnabled) continue;
                keyDown = YES;
                break;
            case UIPressPhaseEnded:
            case UIPressPhaseCancelled:
                keyDown = NO;
                break;
            default:
                continue;
        }
        forwarded = [_metalView forwardHardwarePresses:[NSSet setWithObject:press]
                                               keyDown:keyDown] || forwarded;
    }
    if (forwarded && MacWSHostDiagnosticsEnabled()) {
        MacWSLog(@"hardware-key-window-route presses=%lu target=%d "
                 "text-input-active=%@",
                 (unsigned long)event.allPresses.count, _metalView.targetPID,
                 textInputActive ? @"YES" : @"NO");
    }
    return forwarded;
}

- (void)observeHardwareModifiersForEvent:(UIEvent *)event {
    UIWindow *window = self.viewIfLoaded.window;
    if ([window respondsToSelector:@selector(_isApplicationKeyWindow)] &&
        ![window _isApplicationKeyWindow]) return;
    if (_appSearchField.isFirstResponder) {
        [_metalView releaseHardwareKeyboardState];
        return;
    }
    // A real hardware modifier/navigation event still belongs to the macOS
    // window while the hidden UITextField keeps iOS IME composition alive.
    // Releasing ownership here erased Control/Command immediately before the
    // matching shortcut key arrived at the UIWindow boundary.
    [_metalView observeHardwareModifiersForEvent:event];
}

- (void)releaseHardwareKeyboardState {
    [_metalView releaseHardwareKeyboardState];
}

- (void)setNotice:(NSString *)notice success:(BOOL)success {
    _noticeLabel.hidden = notice.length == 0;
    _noticeLabel.text = notice;
    _noticeLabel.textColor = success ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
}

- (void)setControlsEnabled:(BOOL)enabled {
    _primaryButton.enabled = enabled;
    _repairDesktopButton.enabled = enabled;
    _repairButton.enabled = enabled;
    _recoverButton.enabled = enabled;
    _captureButton.enabled = enabled;
    _exportButton.enabled = enabled;
    _windowPickerButton.enabled = enabled;
    _closeWindowButton.enabled = enabled && _windowID != 0;
    _menuBarButton.enabled = enabled;
    _crossAppDragButton.enabled = enabled && _windowID != 0 &&
        !_crossAppDragTransferPending;
    _inputModeControl.enabled = enabled;
    _performanceHUDControl.enabled = YES;
    _performanceResetButton.enabled = YES;
    _performanceExportButton.enabled = YES;
    _performanceRunButton.enabled = enabled;
    _densityControl.enabled = enabled;
    _presentationResolutionControl.enabled = enabled;
    _zoomScaleControl.enabled = enabled;
    _resetZoomButton.enabled = enabled;
    _retryStartupButton.enabled = enabled;
    for (UIButton *button in _applicationButtons) button.enabled = enabled;
}

- (void)closeCurrentWindow {
    if (_windowID == 0 || _windowOwnerPID <= 1) {
        [self setNotice:@"当前是工作区，不对应单独的 macOS 窗口。" success:NO];
        return;
    }
    UISceneSession *session = self.view.window.windowScene.session;
    if (!session) return;
    MacWSRememberSceneBinding(session, [self streamRestorationActivity]);
    if (!MacWSCloseMacWindowForSceneSession(session, @"control-center")) {
        [self setNotice:@"关闭请求发送失败；macOS 窗口保持打开。" success:NO];
        return;
    }
    [UIApplication.sharedApplication
        requestSceneSessionDestruction:session
                              options:nil
                         errorHandler:^(NSError *error) {
        [self setNotice:[NSString stringWithFormat:
            @"macOS 窗口已请求关闭，但 iPadOS 场景未能移除：%@",
            error.localizedDescription ?: @"未知错误"] success:NO];
    }];
}

- (void)resetKeyboardProxyBuffer {
    if (!_keyboardProxy) return;
    _keyboardProxyResetting = YES;
    _keyboardProxy.text = @" ";
    UITextPosition *end = _keyboardProxy.endOfDocument;
    if (end) {
        _keyboardProxy.selectedTextRange =
            [_keyboardProxy textRangeFromPosition:end toPosition:end];
    }
    _keyboardProxyResetting = NO;
}

- (void)systemKeyboardFrameDidChange:(NSNotification *)notification {
    if (!_softwareKeyBarTrailingConstraint || !self.isViewLoaded) return;
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:NSValue.class]) return;
    CGRect keyboardFrame = [frameValue CGRectValue];
    CGRect localFrame = [self.view convertRect:keyboardFrame fromView:nil];
    CGRect overlap = CGRectIntersection(self.view.bounds, localFrame);
    BOOL fullWidthSoftwareKeyboard = !CGRectIsNull(overlap) &&
        !CGRectIsEmpty(overlap) && overlap.size.height > 100.0 &&
        overlap.size.width >= self.view.bounds.size.width * 0.75;
    // A docked software keyboard already owns the complete lower edge. With
    // Magic Keyboard (or a floating keyboard), iPadOS instead leaves its
    // compact input-method control over the bottom-right of the app window.
    // Reserve the complete 144-point control cluster, not merely the input
    // button itself. Keeping the bar pinned to the root bottom avoids a strip
    // below macOS content, while the fixed dismiss button stays tappable.
    _softwareKeyBarTrailingConstraint.constant =
        fullWidthSoftwareKeyboard ? 0.0 : -144.0;
}

- (void)keyboardProxyEditingChanged:(UITextField *)textField {
    if (textField != _keyboardProxy || _keyboardProxyResetting) return;
    NSString *buffer = textField.text ?: @"";
    BOOL beginsWithSentinel = [buffer hasPrefix:@" "];
    BOOL hasMarkedText = textField.markedTextRange != nil;
    MacWSKeyboardProxyEditAction action = MacWSClassifyKeyboardProxyEdit(
        buffer.length, beginsWithSentinel, hasMarkedText);
    if (action == MacWSKeyboardProxyEditAwaitingComposition ||
        action == MacWSKeyboardProxyEditIdle) return;
    if (action == MacWSKeyboardProxyEditCommitText) {
        NSString *committed = beginsWithSentinel
            ? [buffer substringFromIndex:1] : buffer;
        if (committed.length) {
            [_metalView emitSoftwareText:committed modifiers:_softModifiers];
            MacWSDiagnosticLog(@"software-text-commit utf16=%lu target=%d "
                "window=%u input-mode=%@",
                (unsigned long)committed.length, _windowOwnerPID, _windowID,
                textField.textInputMode.primaryLanguage ?: @"unknown");
        }
    }
    [self resetKeyboardProxyBuffer];
}

- (void)keyboardAction {
    if (_keyboardProxy.isFirstResponder) {
        if (_keyboardProxy.markedTextRange) {
            [_keyboardProxy unmarkText];
            [self keyboardProxyEditingChanged:_keyboardProxy];
        }
        BOOL resigned = [_keyboardProxy resignFirstResponder];
        if (!resigned || _keyboardProxy.isFirstResponder) {
            [self.view endEditing:YES];
            [self.view.window endEditing:YES];
        }
        MacWSDiagnosticLog(@"software-keyboard-dismiss requested=YES "
            "resigned=%@ first-responder=%@",
            resigned ? @"YES" : @"NO",
            _keyboardProxy.isFirstResponder ? @"YES" : @"NO");
        if (!_keyboardProxy.isFirstResponder) {
            [self setButton:_keyboardButton title:@"打开虚拟键盘"
                       image:@"keyboard"];
        }
    } else {
        [self resetKeyboardProxyBuffer];
        if ([_keyboardProxy becomeFirstResponder]) {
            _metalView.softwareKeyboardActive = YES;
            [self setButton:_keyboardButton title:@"收起虚拟键盘"
                       image:@"keyboard.chevron.compact.down"];
        }
    }
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    if (textField != _keyboardProxy) return;
    if (MacWSClassifyKeyboardProxyEdit(
            textField.text.length, [textField.text hasPrefix:@" "],
            textField.markedTextRange != nil) ==
            MacWSKeyboardProxyEditRestoreSentinel) {
        [self resetKeyboardProxyBuffer];
    }
    _metalView.softwareKeyboardActive = YES;
    _softwareKeyBar.hidden = NO;
    _softwareKeyBarHeightConstraint.constant = 52;
    // The control-center dismiss layer and panel are intentionally installed
    // after the workspace during view construction. Once the keyboard row
    // becomes interactive it must be above both; otherwise the transparent
    // dismiss layer wins hit-testing instead of delivering the key action.
    [self.view bringSubviewToFront:_softwareKeyBar];
    BOOL activated = [self activateCurrentMacWindow];
    MacWSDiagnosticLog(@"software-keyboard-focus target=%d window=%u "
        "activated=%@", _windowOwnerPID, _windowID,
        activated ? @"YES" : @"NO");
    [UIView animateWithDuration:0.20 animations:^{
        [self.view layoutIfNeeded];
    }];
    [self setButton:_keyboardButton title:@"收起虚拟键盘"
               image:@"keyboard.chevron.compact.down"];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField != _keyboardProxy) return;
    if (textField.markedTextRange) [textField unmarkText];
    [self keyboardProxyEditingChanged:textField];
    _metalView.softwareKeyboardActive = NO;
    _softwareKeyBarHeightConstraint.constant = 0;
    [UIView animateWithDuration:0.20 animations:^{
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        self->_softwareKeyBar.hidden = YES;
    }];
    [self setButton:_keyboardButton title:@"打开虚拟键盘"
               image:@"keyboard"];
    [_metalView becomeFirstResponder];
}

- (void)softModifierTapped:(UIButton *)sender {
    uint32_t mask = (uint32_t)sender.tag;
    _softModifiers ^= mask;
    sender.selected = (_softModifiers & mask) != 0;
    UIButtonConfiguration *configuration = sender.selected
        ? [UIButtonConfiguration filledButtonConfiguration]
        : [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = sender.configuration.title;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleSmall;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(7, 10, 7, 10);
    sender.configuration = configuration;
    BOOL activated = [self activateCurrentMacWindow];
    MacWSDiagnosticLog(@"software-toolbar-modifier mask=%#x selected=%@ "
        "modifiers=%#x target=%d window=%u activated=%@",
        mask, sender.selected ? @"YES" : @"NO", _softModifiers,
        _windowOwnerPID, _windowID, activated ? @"YES" : @"NO");
}

- (void)softKeyTapped:(UIButton *)sender {
    BOOL activated = [self activateCurrentMacWindow];
    MacWSDiagnosticLog(@"software-toolbar-key keysym=%#lx modifiers=%#x "
        "target=%d window=%u activated=%@ input-enabled=%@",
        (long)sender.tag, _softModifiers, _windowOwnerPID, _windowID,
        activated ? @"YES" : @"NO",
        _metalView.isMacWSInputEnabled ? @"YES" : @"NO");
    [_metalView emitSoftwareKeySym:(uint32_t)sender.tag
                         modifiers:_softModifiers];
}

- (void)dismissSoftwareKeyboardTapped:(UIButton *)sender {
    (void)sender;
    [self keyboardAction];
}

- (BOOL)textField:(UITextField *)textField
    shouldChangeCharactersInRange:(NSRange)range
                replacementString:(NSString *)string {
    (void)range;
    if (textField != _keyboardProxy) return YES;
    if (textField.markedTextRange) return YES;
    BOOL deletesSentinel = string.length == 0 &&
        [textField.text isEqualToString:@" "] &&
        range.location == 0 && range.length == 1;
    if (deletesSentinel) {
        [_metalView emitSoftwareKeySym:0xff08 modifiers:_softModifiers];
        return NO;
    }
    // Let UIKit mutate its real text-input client. While a Chinese/Japanese
    // IME owns markedTextRange, editingChanged waits without forwarding the
    // composing Latin letters. Once the candidate is committed and the marked
    // range disappears, keyboardProxyEditingChanged: forwards only the final
    // text to the exact AppKit window/caret and restores the sentinel.
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == _keyboardProxy) {
        if (textField.markedTextRange) {
            [textField unmarkText];
            [self keyboardProxyEditingChanged:textField];
        }
        [_metalView emitSoftwareKeySym:0xff0d modifiers:_softModifiers];
        return NO;
    }
    if (textField != _appSearchField) return YES;
    NSString *query = [textField.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) return NO;
    NSString *lower = query.lowercaseString;
    NSString *identifier = nil;
    if ([lower containsString:@"visual studio"] ||
        [lower containsString:@"vscode"] || [lower isEqualToString:@"code"])
        identifier = @"vscode";
    else if ([lower containsString:@"terminal"] ||
             [query containsString:@"终端"])
        identifier = @"terminal";
    else if ([lower containsString:@"glass"])
        identifier = @"glassdemo";
    else if ([lower containsString:@"activity"] ||
             [query containsString:@"活动"])
        identifier = @"activity-monitor";
    else if ([lower containsString:@"finder"])
        identifier = @"finder";
    else if ([lower containsString:@"maps"] ||
             [query containsString:@"地图"])
        identifier = @"maps";
    else if ([lower containsString:@"settings"] ||
             [query containsString:@"设置"])
        identifier = @"system-settings";
    else if ([lower containsString:@"amadine"])
        identifier = @"amadine";
    else if ([lower isEqualToString:@"word"] ||
             [lower containsString:@"microsoft word"])
        identifier = @"word";
    else if ([lower isEqualToString:@"excel"] ||
             [lower containsString:@"microsoft excel"])
        identifier = @"excel";
    else if ([lower containsString:@"powerpoint"] ||
             [lower isEqualToString:@"ppt"])
        identifier = @"powerpoint";
    else if ([lower containsString:@"steam"])
        identifier = @"steam";
    else if ([lower containsString:@"weather"] ||
             [query containsString:@"天气"])
        identifier = @"weather";
    else if ([lower containsString:@"sublime"])
        identifier = @"sublime";
    [textField resignFirstResponder];
    if (identifier) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                 arguments:@{@MACWS_CONTROL_KEY_APP_ID: identifier}];
    } else if ([query hasPrefix:@"/"]) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_PATH
                 arguments:@{@MACWS_CONTROL_KEY_APP_PATH: query}];
    } else {
        [self setNotice:@"未找到应用；可搜索 Steam、天气、Sublime、Office，或输入 / 开头的 macOS 绝对路径。"
                 success:NO];
    }
    return NO;
}

- (void)applyInputMode:(MacWSHostInputMode)mode
             automatic:(BOOL)automatic
                persist:(BOOL)persist {
    _inputModeControl.selectedSegmentIndex = mode == MacWSHostInputModeGame
        ? 2 : (mode == MacWSHostInputModeTrackpad ? 1 : 0);
    _metalView.inputMode = mode;
    if (persist)
        [NSUserDefaults.standardUserDefaults setInteger:mode
                                                  forKey:@"MacWSInputMode"];
    if (mode == MacWSHostInputModeGame) {
        _inputLabel.text = automatic ? MacWSLocalized(
            @"输入：已按游戏的相对鼠标请求自动进入游戏视角 · 妙控键盘与屏幕触摸均可无限转动",
            @"Input: Game Camera entered from the game's relative-mouse request · Magic Keyboard and screen touch both rotate without an edge")
            : MacWSLocalized(
            @"输入：游戏视角 · 收起控制中心后锁定妙控键盘指针；屏幕触摸同样发送无限相对位移",
            @"Input: Game Camera · hide Control Center to lock the Magic Keyboard pointer; screen touch also emits unlimited relative motion");
        [self hideControls];
    } else {
        _inputLabel.text = mode == MacWSHostInputModeTrackpad
            ? MacWSLocalized(@"输入：单指移动圆形指针，轻点单击，长按拖动，双指滚动/右击",
                             @"Input: move the circular pointer with one finger; tap, hold-drag, two-finger scroll/right-click")
            : MacWSLocalized(@"输入：轻点单击、单指滑动滚动；长按后滑动拖动，长按释放右击",
                             @"Input: tap to click, swipe to scroll; hold-drag, or hold and release to right-click");
        [self updateGamePointerLockPreferenceWithReason:@"input-mode-changed"];
    }
}

- (void)inputModeChanged:(UISegmentedControl *)sender {
    MacWSHostInputMode mode = sender.selectedSegmentIndex == 2
        ? MacWSHostInputModeGame :
        (sender.selectedSegmentIndex == 1
            ? MacWSHostInputModeTrackpad : MacWSHostInputModeDirect);
    if (_automaticGamePointerActive) {
        if (mode != MacWSHostInputModeGame) {
            _automaticGamePointerSuppressedPID = _automaticGamePointerPID;
            _automaticGamePointerSuppressedWindowID =
                _automaticGamePointerWindowID;
        }
        _automaticGamePointerActive = NO;
        _automaticGamePointerPID = 0;
        _automaticGamePointerWindowID = 0;
        ++_automaticGamePointerRevocationSerial;
    }
    [self applyInputMode:mode automatic:NO persist:YES];
}

- (MacWSStreamWindow *)relativePointerRequestWindowInWindows:
        (NSArray<MacWSStreamWindow *> *)windows {
    int32_t targetPID = _streamMode == MacWSStreamModeWindow
        ? _windowOwnerPID : _metalView.targetPID;
    if (targetPID <= 1) return nil;
    for (MacWSStreamWindow *window in windows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        MacWSStreamWindowFlags required =
            MacWSStreamWindowFocused |
            MacWSStreamWindowRelativePointerRequested;
        if (descriptor.ownerPID != targetPID || descriptor.windowID == 0 ||
            (descriptor.flags & required) != required) continue;
        if (_streamMode == MacWSStreamModeWindow &&
            descriptor.windowID != _windowID &&
            (_windowGroupID == 0 ||
             descriptor.logicalGroupID != _windowGroupID)) continue;
        return window;
    }
    return nil;
}

- (void)updateAutomaticGameInputForWindows:
        (NSArray<MacWSStreamWindow *> *)windows {
    MacWSStreamWindow *request =
        [self relativePointerRequestWindowInWindows:windows];
    if (request) {
        ++_automaticGamePointerRevocationSerial;
        int32_t ownerPID = request.descriptor.ownerPID;
        uint32_t windowID = request.descriptor.windowID;
        if (_automaticGamePointerSuppressedPID == ownerPID &&
            _automaticGamePointerSuppressedWindowID == windowID) return;
        _automaticGamePointerSuppressedPID = 0;
        _automaticGamePointerSuppressedWindowID = 0;
        if (_automaticGamePointerActive &&
            _automaticGamePointerPID == ownerPID &&
            _automaticGamePointerWindowID == windowID) return;
        if (_automaticGamePointerActive) {
            MacWSLog(@"game-pointer-auto retargeted old=%d/%u new=%d/%u",
                     _automaticGamePointerPID,
                     _automaticGamePointerWindowID, ownerPID, windowID);
            _automaticGamePointerPID = ownerPID;
            _automaticGamePointerWindowID = windowID;
            return;
        }
        // A manually selected Game mode already owns its lifecycle. Do not
        // turn it into an automatic mode that would later restore another
        // choice when the application opens a menu.
        if (_metalView.inputMode == MacWSHostInputModeGame) return;
        _inputModeBeforeAutomaticGame = _metalView.inputMode;
        _automaticGamePointerActive = YES;
        _automaticGamePointerPID = ownerPID;
        _automaticGamePointerWindowID = windowID;
        MacWSLog(@"game-pointer-auto entered pid=%d window=%u previous=%u source=app-relative-pointer-contract",
                 ownerPID, windowID, _inputModeBeforeAutomaticGame);
        [self applyInputMode:MacWSHostInputModeGame
                   automatic:YES persist:NO];
        return;
    }

    if (_automaticGamePointerSuppressedPID != 0) {
        _automaticGamePointerSuppressedPID = 0;
        _automaticGamePointerSuppressedWindowID = 0;
    }
    if (!_automaticGamePointerActive) return;
    uint64_t serial = ++_automaticGamePointerRevocationSerial;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (serial != self->_automaticGamePointerRevocationSerial ||
            !self->_automaticGamePointerActive ||
            [self relativePointerRequestWindowInWindows:
                self->_streamWindows ?: @[]]) return;
        MacWSHostInputMode restore = self->_inputModeBeforeAutomaticGame;
        if (restore != MacWSHostInputModeDirect &&
            restore != MacWSHostInputModeTrackpad)
            restore = MacWSHostInputModeDirect;
        MacWSLog(@"game-pointer-auto exited pid=%d window=%u restore=%u source=relative-request-revoked",
                 self->_automaticGamePointerPID,
                 self->_automaticGamePointerWindowID, restore);
        self->_automaticGamePointerActive = NO;
        self->_automaticGamePointerPID = 0;
        self->_automaticGamePointerWindowID = 0;
        [self applyInputMode:restore automatic:NO persist:NO];
    });
}

- (void)densityChanged:(UISegmentedControl *)sender {
    MacWSHostDisplayDensity density = sender.selectedSegmentIndex == 1
        ? MacWSHostDisplayDensityRetinaLarger
        : MacWSHostDisplayDensityRetinaStandard;
    _metalView.displayDensity = density;
    [NSUserDefaults.standardUserDefaults setInteger:density
                                              forKey:@"MacWSDisplayDensity"];
    if (density == MacWSHostDisplayDensityRetinaLarger) {
        _inputLabel.text = MacWSLocalized(
            @"显示：Retina 放大 · 原生 2× iPad drawable，由 Metal 高质量放大 macOS Retina 源",
            @"Display: Retina Larger · native 2x iPad drawable with quality Metal scaling of the macOS Retina source");
    } else {
        _inputLabel.text = MacWSLocalized(
            @"显示：Retina 标准 · macOS backing 像素与 iPad drawable 逐像素匹配",
            @"Display: Retina Standard · macOS backing pixels match the iPad drawable one for one");
    }
}

- (void)presentationResolutionChanged:(UISegmentedControl *)sender {
    MacWSHostPresentationResolution resolution =
        (MacWSHostPresentationResolution)sender.selectedSegmentIndex;
    _metalView.presentationResolution = resolution;
    [NSUserDefaults.standardUserDefaults setInteger:resolution
        forKey:@"MacWSPresentationResolution"];
    if (resolution == MacWSHostPresentationResolutionSourceNative) {
        [self setNotice:@"显示清晰度：始终保留 WindowServer 源像素；全屏游戏会增加显示合成负载。"
                 success:YES];
    } else if (resolution == MacWSHostPresentationResolutionPerformance) {
        [self setNotice:@"显示清晰度：性能优先；输出为每个 UIKit 点一个像素。"
                 success:YES];
    } else {
        [self setNotice:@"显示清晰度：桌面保留源像素，全屏游戏自动切换性能分辨率。"
                 success:YES];
    }
}

- (void)performanceHUDChanged:(UISegmentedControl *)sender {
    MacWSPerformanceHUDMode mode = (MacWSPerformanceHUDMode)
        sender.selectedSegmentIndex;
    _metalView.performanceMonitor.HUDMode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode
        forKey:@"MacWSPerformanceHUDMode"];
    if (mode == MacWSPerformanceHUDModeOff) {
        [self setNotice:@"MacWS 性能 HUD 已隐藏；手动计时会持续到导出，普通生产热路径停止采样"
                 success:YES];
    } else {
        [self setNotice:mode == MacWSPerformanceHUDModeFull
            ? @"完整性能 HUD 已开启（2 Hz 刷新，不改变 DisplayStream 帧率）"
            : @"简洁性能 HUD 已开启（实际 drawable 呈现 FPS / 1% low）"
                 success:YES];
    }
}

- (void)systemPerformanceHUDChanged:(UISwitch *)sender {
    NSError *error = nil;
    // CAPerfHUD level 5 is Apple's Full render-server view. Keep this
    // explicit and independently switchable because it is system-wide and
    // persists until disabled or backboardd restarts.
    NSInteger requestedLevel = sender.isOn ? 5 : 0;
    BOOL applied = [MacWSPerformanceMonitor
        setSystemPerformanceHUDLevel:requestedLevel error:&error];
    if (!applied) sender.on = !sender.isOn;
    [self setNotice:applied
        ? (sender.isOn ? @"Apple 全系统渲染 HUD 已开启"
                       : @"Apple 全系统渲染 HUD 已关闭")
        : (error.localizedDescription ?: @"无法切换 Apple 系统渲染 HUD")
        success:applied];
}

- (void)resetPerformanceMeasurement {
    [_metalView.performanceMonitor resetWithReason:@"control-center"];
    [self setNotice:@"性能计时已清零；请立即执行要测量的触摸手势"
             success:YES];
}

- (void)exportPerformanceMeasurement {
    NSError *error = nil;
    NSString *path = [_metalView.performanceMonitor
        exportSnapshotWithReason:@"control-center" error:&error];
    if (!path) {
        [self setNotice:error.localizedDescription ?: @"性能 JSON 导出失败"
                 success:NO];
        return;
    }
    MacWSLog(@"performance-profile-export path=%@", path);
    [self setNotice:[NSString stringWithFormat:@"性能报告已保存：%@", path]
             success:YES];
}

- (void)runPerformanceGestureSuite {
    if (!_metalView.isMacWSInputEnabled) {
        [self setNotice:@"触控桥或 DisplayStream 尚未就绪，不能开始回归"
                 success:NO];
        return;
    }
    _performanceRunButton.enabled = NO;
    NSError *systemHUDError = nil;
    (void)[MacWSPerformanceMonitor setSystemPerformanceHUDLevel:0
        error:&systemHUDError];
    _systemPerformanceHUDSwitch.on = NO;
    [_metalView.performanceMonitor resetWithReason:@"gesture-suite"];
    NSMutableArray<NSString *> *scenarios = [@[
        @"tap", @"double-tap", @"right-tap", @"hover", @"drag",
        @"long-drag", @"scroll", @"scroll-momentum", @"magnify",
    ] mutableCopy];
    if (_streamMode == MacWSStreamModeFullscreen) {
        [scenarios addObjectsFromArray:@[
            @"three-up", @"three-down", @"three-left", @"three-right",
        ]];
    }
    [self setNotice:[NSString stringWithFormat:
        @"正在运行 %lu 个标准手势；请暂时不要触摸屏幕",
        (unsigned long)scenarios.count] success:YES];

    __block NSUInteger index = 0;
    __weak typeof(self) weakSelf = self;
    __block void (^runNext)(void) = nil;
    runNext = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (index >= scenarios.count) {
            NSError *error = nil;
            NSString *path = [strongSelf->_metalView.performanceMonitor
                exportSnapshotWithReason:@"gesture-suite" error:&error];
            strongSelf->_performanceRunButton.enabled = YES;
            [strongSelf setNotice:path
                ? [NSString stringWithFormat:
                    @"标准手势回归完成，性能报告：%@", path]
                : (error.localizedDescription ?: @"手势完成，但报告导出失败")
                success:path != nil];
            MacWSLog(@"performance-gesture-suite-end count=%lu path=%@ error=%@",
                     (unsigned long)scenarios.count, path ?: @"",
                     error ?: @"");
            runNext = nil;
            return;
        }
        NSString *scenario = scenarios[index++];
        [strongSelf->_metalView runPerformanceGestureScenario:scenario
            completion:^(BOOL success, NSString *message) {
                typeof(self) innerSelf = weakSelf;
                if (!innerSelf) return;
                if (!success) {
                    innerSelf->_performanceRunButton.enabled = YES;
                    [innerSelf setNotice:[NSString stringWithFormat:
                        @"手势 %@ 失败：%@", scenario, message] success:NO];
                    MacWSLog(@"performance-gesture-suite-abort scenario=%@ reason=%@",
                             scenario, message);
                    runNext = nil;
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              250 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), runNext);
            }];
    };
    MacWSLog(@"performance-gesture-suite-start count=%lu",
             (unsigned long)scenarios.count);
    runNext();
}

- (void)zoomScaleChanged:(UISegmentedControl *)sender {
    CGFloat scale = sender.selectedSegmentIndex == 1 ? 2.0 : 1.5;
    _metalView.fixedZoomScale = scale;
    [NSUserDefaults.standardUserDefaults setDouble:scale
                                             forKey:@"MacWSFixedZoomScale"];
    [self setNotice:[NSString stringWithFormat:
        @"双指双击放大倍率已设为 %.1f×", scale] success:YES];
}

- (void)resetZoomAction {
    [_metalView resetViewportZoom];
    [self setNotice:@"已退出放大视角并恢复中心位置" success:YES];
}

- (NSString *)crossAppDragSymbolForURL:(NSURL *)url {
    if (url.hasDirectoryPath) return @"folder.fill";
    UTType *type = url.pathExtension.length
        ? [UTType typeWithFilenameExtension:url.pathExtension] : nil;
    if ([type conformsToType:UTTypeImage]) return @"photo.fill";
    if ([type conformsToType:UTTypeMovie]) return @"film.fill";
    if ([type conformsToType:UTTypeAudio]) return @"waveform";
    if ([type conformsToType:UTTypePDF]) return @"doc.richtext.fill";
    if ([type conformsToType:UTTypeArchive]) return @"doc.zipper";
    if ([type conformsToType:UTTypeText]) return @"doc.text.fill";
    return @"doc.fill";
}

- (UIColor *)crossAppDragTintForURL:(NSURL *)url {
    if (url.hasDirectoryPath) return UIColor.systemBlueColor;
    UTType *type = url.pathExtension.length
        ? [UTType typeWithFilenameExtension:url.pathExtension] : nil;
    if ([type conformsToType:UTTypeImage]) return UIColor.systemPurpleColor;
    if ([type conformsToType:UTTypeMovie]) return UIColor.systemPinkColor;
    if ([type conformsToType:UTTypeAudio]) return UIColor.systemOrangeColor;
    if ([type conformsToType:UTTypePDF]) return UIColor.systemRedColor;
    if ([type conformsToType:UTTypeArchive]) return UIColor.systemTealColor;
    return UIColor.systemIndigoColor;
}

- (void)configureCrossAppDragThumbnailView:(UIImageView *)thumbnailView
                                    forURL:(NSURL *)url {
    NSString *symbolName = [self crossAppDragSymbolForURL:url];
    UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration
        configurationWithPointSize:27 weight:UIImageSymbolWeightSemibold];
    thumbnailView.image = [UIImage systemImageNamed:symbolName
                                  withConfiguration:symbol];
    thumbnailView.contentMode = UIViewContentModeScaleAspectFit;
    thumbnailView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    thumbnailView.tintColor = [self crossAppDragTintForURL:url];
}

- (UIImage *)crossAppDragPDFThumbnailAtURL:(NSURL *)url {
    CGPDFDocumentRef document = CGPDFDocumentCreateWithURL(
        (__bridge CFURLRef)url);
    if (!document) return nil;
    CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
    if (!page) {
        CGPDFDocumentRelease(document);
        return nil;
    }
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
    if (CGRectIsEmpty(box)) box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    if (CGRectIsEmpty(box)) {
        CGPDFDocumentRelease(document);
        return nil;
    }

    CGSize canvasSize = CGSizeMake(180, 180);
    UIGraphicsImageRendererFormat *format =
        [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:canvasSize format:format];
    UIImage *thumbnail = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *rendererContext) {
        [UIColor.whiteColor setFill];
        UIRectFill((CGRect){CGPointZero, canvasSize});
        CGFloat scale = MIN(canvasSize.width / CGRectGetWidth(box),
                            canvasSize.height / CGRectGetHeight(box));
        CGFloat width = CGRectGetWidth(box) * scale;
        CGFloat height = CGRectGetHeight(box) * scale;
        CGContextRef context = rendererContext.CGContext;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context,
            (canvasSize.width - width) * 0.5,
            (canvasSize.height - height) * 0.5 + height);
        CGContextScaleCTM(context, scale, -scale);
        CGContextTranslateCTM(context, -CGRectGetMinX(box),
                              -CGRectGetMinY(box));
        CGContextDrawPDFPage(context, page);
        CGContextRestoreGState(context);
    }];
    CGPDFDocumentRelease(document);
    return thumbnail;
}

- (UIImage *)crossAppDragContentThumbnailAtURL:(NSURL *)url {
    if (!url.isFileURL || url.hasDirectoryPath) return nil;
    UTType *type = url.pathExtension.length
        ? [UTType typeWithFilenameExtension:url.pathExtension] : nil;
    if ([type conformsToType:UTTypePDF])
        return [self crossAppDragPDFThumbnailAtURL:url];
    if ([type conformsToType:UTTypeMovie]) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetImageGenerator *generator =
            [[AVAssetImageGenerator alloc] initWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.maximumSize = CGSizeMake(180, 180);
        generator.requestedTimeToleranceBefore = kCMTimePositiveInfinity;
        generator.requestedTimeToleranceAfter = kCMTimePositiveInfinity;
        NSError *error = nil;
        CGImageRef frame = [generator copyCGImageAtTime:
            CMTimeMakeWithSeconds(0.05, 600) actualTime:NULL error:&error];
        (void)error;
        if (!frame) return nil;
        UIImage *thumbnail = [UIImage imageWithCGImage:frame];
        CGImageRelease(frame);
        return thumbnail;
    }
    if (![type conformsToType:UTTypeImage]) return nil;

    CGImageSourceRef source = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:
            @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:
            @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @180,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(
        source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return nil;
    UIImage *thumbnail = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    return thumbnail;
}

- (void)configureCrossAppDragThumbnailStackForURLs:(NSArray<NSURL *> *)urls
                                              count:(NSUInteger)count {
    NSArray<UIImageView *> *allViews = @[
        _crossAppDragHandleBackIcon,
        _crossAppDragHandleMiddleIcon,
        _crossAppDragHandleIcon
    ];
    for (UIImageView *thumbnailView in allViews) {
        thumbnailView.hidden = YES;
        thumbnailView.transform = CGAffineTransformIdentity;
    }

    NSUInteger cardCount = MIN(MAX(count, (NSUInteger)1), (NSUInteger)3);
    NSMutableArray<NSDictionary *> *jobs = [NSMutableArray array];
    void (^configure)(UIImageView *, NSUInteger, CGRect, CGFloat) =
        ^(UIImageView *view, NSUInteger urlIndex, CGRect frame,
          CGFloat rotationDegrees) {
        NSURL *url = urlIndex < urls.count ? urls[urlIndex] : nil;
        [self configureCrossAppDragThumbnailView:view forURL:url];
        view.frame = frame;
        view.transform = CGAffineTransformMakeRotation(
            rotationDegrees * M_PI / 180.0);
        view.hidden = NO;
        if (url) [jobs addObject:@{ @"url": url, @"view": view }];
    };

    if (cardCount == 1) {
        configure(_crossAppDragHandleIcon, 0, CGRectMake(7, 5, 44, 48), 0);
    } else if (cardCount == 2) {
        configure(_crossAppDragHandleBackIcon, 1,
                  CGRectMake(8, 7, 39, 44), -9);
        configure(_crossAppDragHandleIcon, 0,
                  CGRectMake(12, 6, 40, 45), 7);
    } else {
        configure(_crossAppDragHandleBackIcon, 2,
                  CGRectMake(6, 8, 37, 42), -11);
        configure(_crossAppDragHandleMiddleIcon, 1,
                  CGRectMake(10, 5, 38, 43), 0);
        configure(_crossAppDragHandleIcon, 0,
                  CGRectMake(14, 7, 39, 44), 9);
    }

    uint64_t serial = _crossAppDragPrepareSerial;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSDictionary *job in jobs) {
            typeof(self) self = weakSelf;
            if (!self) return;
            NSURL *url = job[@"url"];
            UIImageView *view = job[@"view"];
            UIImage *thumbnail = [self crossAppDragContentThumbnailAtURL:url];
            if (!thumbnail) continue;
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self || serial != self->_crossAppDragPrepareSerial ||
                    self->_crossAppDragHandle.hidden ||
                    ![self->_preparedMacOSDragURLs containsObject:url]) return;
                view.image = thumbnail;
                view.contentMode = UIViewContentModeScaleAspectFill;
                view.backgroundColor = UIColor.secondarySystemBackgroundColor;
            });
        }
    });
}

- (void)hideCrossAppDragHandle {
    _crossAppDragHandle.hidden = YES;
    _crossAppDragHandleTitle.hidden = YES;
    _crossAppDragHandle.alpha = 1.0;
    _crossAppDragHandleTitle.alpha = 1.0;
    _crossAppDragHandle.transform = CGAffineTransformIdentity;
    _crossAppDragHandleTitle.transform = CGAffineTransformIdentity;
}

- (void)presentCrossAppDragHandleAtRootPoint:(CGPoint)rootPoint
                                    providers:(NSArray<NSItemProvider *> *)providers
                                         URLs:(NSArray<NSURL *> *)urls {
    NSUInteger count = MAX(providers.count, urls.count);
    if (count == 0) {
        [self hideCrossAppDragHandle];
        return;
    }

    BOOL multiple = count > 1;
    NSURL *primaryURL = urls.firstObject;
    [self configureCrossAppDragThumbnailStackForURLs:urls count:count];
    _crossAppDragHandleBadge.hidden = !multiple;
    _crossAppDragHandleBadge.text = count > 99 ? @"99+"
        : [NSString stringWithFormat:@"%lu", (unsigned long)count];
    _crossAppDragHandleBadge.frame = count > 99
        ? CGRectMake(35, -5, 30, 24) : CGRectMake(39, -5, 24, 24);
    _crossAppDragHandleTint.backgroundColor =
        [[self crossAppDragTintForURL:primaryURL] colorWithAlphaComponent:0.20];

    NSString *title = nil;
    if (multiple) {
        title = MacWSControlCenterUsesEnglish()
            ? [NSString stringWithFormat:@"%lu files", (unsigned long)count]
            : [NSString stringWithFormat:@"%lu 个文件", (unsigned long)count];
    } else {
        title = primaryURL.lastPathComponent ?:
            providers.firstObject.suggestedName ?:
            MacWSLocalized(@"文件", @"File");
    }
    _crossAppDragHandleTitle.text = title;
    CGFloat titleWidth = ceil([title sizeWithAttributes:@{
        NSFontAttributeName: _crossAppDragHandleTitle.font
    }].width) + 22.0;
    titleWidth = MIN(MAX(titleWidth, 72.0), 184.0);
    _crossAppDragHandleTitle.bounds = CGRectMake(0, 0, titleWidth, 26);

    CGRect safeBounds = UIEdgeInsetsInsetRect(self.view.bounds,
                                               self.view.safeAreaInsets);
    CGFloat halfWidth = CGRectGetWidth(_crossAppDragHandle.bounds) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(_crossAppDragHandle.bounds) * 0.5;
    rootPoint.x = MIN(MAX(rootPoint.x, CGRectGetMinX(safeBounds) + halfWidth),
        CGRectGetMaxX(safeBounds) - halfWidth);
    rootPoint.y = MIN(MAX(rootPoint.y, CGRectGetMinY(safeBounds) + halfHeight),
        CGRectGetMaxY(safeBounds) - halfHeight);
    _crossAppDragHandle.center = rootPoint;

    CGFloat titleHalfWidth = titleWidth * 0.5;
    CGFloat titleX = MIN(MAX(rootPoint.x,
        CGRectGetMinX(safeBounds) + titleHalfWidth),
        CGRectGetMaxX(safeBounds) - titleHalfWidth);
    CGFloat titleY = rootPoint.y + halfHeight + 8.0 + 13.0;
    if (titleY + 13.0 > CGRectGetMaxY(safeBounds))
        titleY = rootPoint.y - halfHeight - 8.0 - 13.0;
    _crossAppDragHandleTitle.center = CGPointMake(titleX, titleY);

    _crossAppDragHandle.accessibilityLabel = multiple
        ? title
        : [NSString stringWithFormat:MacWSLocalized(@"已准备：%@",
                                                     @"Ready: %@"), title];
    [self.view bringSubviewToFront:_crossAppDragHandleTitle];
    [self.view bringSubviewToFront:_crossAppDragHandle];
    _crossAppDragHandle.hidden = NO;
    _crossAppDragHandleTitle.hidden = NO;
    _crossAppDragHandle.alpha = 0.0;
    _crossAppDragHandleTitle.alpha = 0.0;
    _crossAppDragHandle.transform = CGAffineTransformMakeScale(0.74, 0.74);
    _crossAppDragHandleTitle.transform = CGAffineTransformMakeTranslation(0, -4);
    [UIView animateWithDuration:0.42
                          delay:0
         usingSpringWithDamping:0.68
          initialSpringVelocity:0.45
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self->_crossAppDragHandle.alpha = 1.0;
        self->_crossAppDragHandleTitle.alpha = 1.0;
        self->_crossAppDragHandle.transform = CGAffineTransformIdentity;
        self->_crossAppDragHandleTitle.transform = CGAffineTransformIdentity;
    } completion:nil];
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [feedback prepare];
    [feedback impactOccurred];
}

- (void)updateCrossAppDragButton {
    BOOL english = MacWSControlCenterUsesEnglish();
    NSString *title = nil;
    NSString *image = nil;
    if (_crossAppDragTransferPending) {
        title = english ? @"Transferring…" : @"正在传输…";
        image = @"arrow.left.arrow.right";
    } else if (_crossAppDragPreparing) {
        title = english ? @"Preparing File…" : @"正在准备文件…";
        image = @"hourglass";
    } else if (_crossAppDragArmed && _preparedMacOSDragProviders.count) {
        title = english ? @"Ready · Cancel" : @"已准备 · 取消";
        image = @"checkmark.circle";
    } else if (_crossAppDragArmed) {
        title = english ? @"Tap File to Prepare" : @"轻点文件以准备";
        image = @"hand.tap";
    } else {
        title = english ? @"Prepare Drag Manually" : @"手动准备拖出";
        image = @"hand.draw";
    }
    [self setButton:_crossAppDragButton title:title image:image];
    if (_crossAppDragTransferPending) _crossAppDragButton.enabled = NO;
}

- (void)setCrossAppDragArmed:(BOOL)armed notice:(BOOL)showNotice {
    _crossAppDragArmed = armed && _windowID != 0;
    if (!_crossAppDragArmed) {
        _crossAppDragPrepareSerial++;
        _crossAppDragPreparing = NO;
        _preparedMacOSDragProviders = nil;
        _preparedMacOSDragURLs = nil;
    }
    _crossAppDragSurface.hidden = !_crossAppDragArmed;
    [self hideCrossAppDragHandle];
    _contentDragInteraction.enabled = _crossAppDragArmed &&
        _preparedMacOSDragProviders.count > 0;
    _crossAppDragPrepareTap.enabled = _crossAppDragArmed &&
        !_crossAppDragPreparing && !_preparedMacOSDragProviders.count;
    _metalView.crossAppDragModeEnabled = _crossAppDragArmed;
    [self updateCrossAppDragButton];
    if (!showNotice) return;
    if (_crossAppDragArmed) {
        [self setNotice:@"请先轻点要拖出的 macOS 文件；显示“已准备”后再长按拖到 iPadOS。"
                 success:YES];
    } else {
        [self setNotice:@"已恢复 macOS 长按右键与窗口内拖动。" success:YES];
    }
}

- (void)toggleCrossAppDrag {
    if (!_interopClient.isConnected) {
        [self setNotice:@"iOS/macOS 互操作服务尚未连接" success:NO];
        return;
    }
    if (_crossAppDragTransferPending) {
        [self setNotice:@"上一次跨 App 文件仍在传输" success:NO];
        return;
    }
    [self setCrossAppDragArmed:!_crossAppDragArmed notice:YES];
}

- (void)cancelPreparedCrossAppDragHandle {
    if (_crossAppDragTransferPending) return;
    [self setCrossAppDragArmed:NO notice:NO];
}

- (void)beginCrossAppDragPreparationAtPoint:(CGPoint)point
                            usingFullSurface:(BOOL)usingFullSurface
                                      source:(NSString *)source {
    if (_crossAppDragTransferPending || _crossAppDragPreparing ||
        _preparedMacOSDragProviders.count || !_interopClient.isConnected ||
        (usingFullSurface && !_crossAppDragArmed)) return;
    if (!usingFullSurface) {
        _crossAppDragArmed = YES;
        _crossAppDragSurface.hidden = YES;
        // The drag source is the small sibling UIButton, so normal touches
        // elsewhere still belong to AppKit. No full-surface arbitration is
        // needed for automatic preparation.
        _metalView.crossAppDragModeEnabled = NO;
    }
    _crossAppDragPreparing = YES;
    _crossAppDragPrepareTap.enabled = NO;
    _contentDragInteraction.enabled = NO;
    uint64_t serial = ++_crossAppDragPrepareSerial;
    [self updateCrossAppDragButton];
    [self setNotice:@"正在准备所选文件…" success:YES];
    MacWSLog(@"interop-drag-prepare requested window=%u pid=%d point=(%.1f,%.1f) serial=%llu source=%@",
        _windowID, _metalView.targetPID, point.x, point.y,
        (unsigned long long)serial, source ?: @"unknown");

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        uint64_t changeCount = [self->_interopClient
            macOSDragPasteboardChangeCount];
        __block BOOL began = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (serial != self->_crossAppDragPrepareSerial ||
                !self->_crossAppDragArmed) return;
            began = [self->_metalView
                beginInteropDragProbeAtViewPoint:point];
            if (began)
                [self->_metalView finishInteropDragProbeCancelled:YES];
        });
        NSArray<NSURL *> *stagedURLs = nil;
        NSArray<NSItemProvider *> *providers = began ? [self->_interopClient
            macOSDragItemProvidersAfterChangeCount:changeCount
                                      waitMilliseconds:500
                                            stagedURLs:&stagedURLs] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (serial != self->_crossAppDragPrepareSerial ||
                !self->_crossAppDragArmed) return;
            self->_crossAppDragPreparing = NO;
            self->_preparedMacOSDragProviders = [providers copy];
            // The staged URLs are part of this exact pasteboard snapshot.
            // Do not recover them indirectly through the asynchronous
            // clipboard delegate: another scene or clipboard event can race
            // that shared state to an empty/older array. Retain both the URLs
            // and their file-backed providers until UIKit confirms that its
            // cross-process copy has completed.
            self->_preparedMacOSDragURLs = [stagedURLs copy];
            self->_contentDragInteraction.enabled = providers.count > 0;
            self->_crossAppDragPrepareTap.enabled =
                usingFullSurface && providers.count == 0;
            self->_crossAppDragSurface.hidden =
                !usingFullSurface || providers.count > 0;
            if (providers.count) {
                // The handle itself isolates UIKit drag recognition. Restore
                // ordinary macOS gestures everywhere outside its 58x58 frame.
                self->_metalView.crossAppDragModeEnabled = NO;
                CGPoint rootPoint = [self.view convertPoint:point
                                                   fromView:self->_metalView];
                [self presentCrossAppDragHandleAtRootPoint:rootPoint
                                                 providers:providers
                                                      URLs:self->_preparedMacOSDragURLs];
            } else {
                [self hideCrossAppDragHandle];
                if (!usingFullSurface) {
                    self->_crossAppDragArmed = NO;
                    self->_preparedMacOSDragProviders = nil;
                    self->_preparedMacOSDragURLs = nil;
                    self->_metalView.crossAppDragModeEnabled = NO;
                }
            }
            [self updateCrossAppDragButton];
            NSMutableArray<NSString *> *types = [NSMutableArray array];
            for (NSItemProvider *provider in providers)
                [types addObject:[provider.registeredTypeIdentifiers
                    componentsJoinedByString:@","]];
            MacWSLog(@"interop-drag-prepare completed window=%u pid=%d "
                "serial=%llu source=%@ began=%@ providers=%lu urls=%lu types=%@",
                self->_windowID, self->_metalView.targetPID,
                (unsigned long long)serial, source ?: @"unknown",
                began ? @"YES" : @"NO",
                (unsigned long)providers.count,
                (unsigned long)self->_preparedMacOSDragURLs.count,
                [types componentsJoinedByString:@" | "]);
            [self setNotice:providers.count
                ? @"文件已准备；请长按文件堆栈并拖到 iPadOS。"
                : @"当前位置没有可拖出的项目，请在所选文件上两指长按。"
                success:providers.count > 0];
        });
    });
}

- (void)prepareCrossAppDrag:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;
    [self beginCrossAppDragPreparationAtPoint:
        [recognizer locationInView:_metalView]
                              usingFullSurface:YES
                                        source:@"manual-surface"];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == _crossAppDragTwoFingerHold)
        return touch.type != UITouchTypePencil;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == _crossAppDragTwoFingerHold) {
        return _streamMode == MacWSStreamModeWindow && _windowID != 0 &&
            _interopClient.isConnected && !_crossAppDragTransferPending;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
 shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer {
    // The two-finger hold is intentionally exclusive: MacWSMetalView's
    // secondary tap waits for it to fail, so a short chord becomes one
    // context click and a long chord becomes one export preparation.
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
}

- (void)metalView:(MacWSMetalView *)view
    completedDirectTapAtViewPoint:(CGPoint)viewPoint {
    (void)view;
    _crossAppDragSelectionPoint = viewPoint;
    _crossAppDragSelectionPointValid = YES;
    if (_crossAppDragArmed && _preparedMacOSDragProviders.count &&
        !_crossAppDragTransferPending)
        [self setCrossAppDragArmed:NO notice:NO];
}

- (void)crossAppDragTwoFingerHeld:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan ||
        _crossAppDragTransferPending || !_interopClient.isConnected) return;
    CGPoint holdPoint = [recognizer locationInView:_metalView];
    CGPoint probePoint = holdPoint;
    if (_crossAppDragSelectionPointValid) {
        CGFloat distance = hypot(
            holdPoint.x - _crossAppDragSelectionPoint.x,
            holdPoint.y - _crossAppDragSelectionPoint.y);
        // A two-finger centroid naturally falls around rather than exactly on
        // a small Finder icon. Reuse the preceding selection point only while
        // it is local to this hold; a distant or scrolled selection is stale.
        if (distance <= 140.0) probePoint = _crossAppDragSelectionPoint;
    }

    _crossAppDragPrepareSerial++;
    _crossAppDragPreparing = NO;
    _crossAppDragArmed = NO;
    _preparedMacOSDragProviders = nil;
    _preparedMacOSDragURLs = nil;
    _contentDragInteraction.enabled = NO;
    _crossAppDragPrepareTap.enabled = NO;
    _crossAppDragSurface.hidden = YES;
    _metalView.crossAppDragModeEnabled = NO;
    [self hideCrossAppDragHandle];
    [self updateCrossAppDragButton];
    MacWSLog(@"interop-drag-two-finger recognized window=%u pid=%d hold=(%.1f,%.1f) probe=(%.1f,%.1f) reused-selection=%@",
        _windowID, _metalView.targetPID, holdPoint.x, holdPoint.y,
        probePoint.x, probePoint.y,
        CGPointEqualToPoint(holdPoint, probePoint) ? @"NO" : @"YES");
    [self beginCrossAppDragPreparationAtPoint:probePoint
                              usingFullSurface:NO
                                        source:@"two-finger-hold"];
}

- (void)interopClient:(MacWSInteropClient *)client
        statusChanged:(NSString *)status
            connected:(BOOL)connected {
    (void)client;
    MacWSDiagnosticLog(@"interop-status connected=%@ message=%@",
             connected ? @"YES" : @"NO", status ?: @"");
    _interopLabel.text = [@"互操作：" stringByAppendingString:status];
    _interopLabel.textColor = connected ? UIColor.systemGreenColor
                                        : UIColor.systemOrangeColor;
}

- (void)interopClient:(MacWSInteropClient *)client
 receivedMacOSFilesAtURLs:(NSArray<NSURL *> *)urls {
    (void)client;
    // The remote file representations are already installed atomically on
    // UIPasteboard by MacWSInteropClient. There is intentionally no manual
    // Control Center export button; Files/Notes/Photos consume the native
    // pasteboard or drag representations directly.
    MacWSLog(@"interop-remote-files-ready count=%lu route=native-pasteboard",
             (unsigned long)urls.count);
}

- (NSArray<UIDragItem *> *)dragInteraction:(UIDragInteraction *)interaction
                     itemsForBeginningSession:(id<UIDragSession>)session {
    NSMutableArray<UIDragItem *> *items = [NSMutableArray array];
    if (interaction == _contentDragInteraction) {
        if (_windowID == 0 || !_interopClient.isConnected ||
            !_crossAppDragArmed || !_preparedMacOSDragProviders.count)
            return @[];
        CGPoint point = [session locationInView:_metalView];
        NSMutableArray<NSString *> *typeSummaries = [NSMutableArray array];
        NSArray<NSItemProvider *> *providers = _preparedMacOSDragProviders;
        NSString *route = @"prepared-file-representation";
        for (NSItemProvider *provider in providers) {
            [items addObject:[[UIDragItem alloc] initWithItemProvider:provider]];
            [typeSummaries addObject:[NSString stringWithFormat:@"%@[%@]",
                provider.suggestedName ?: @"(nil)",
                [provider.registeredTypeIdentifiers componentsJoinedByString:@","]]];
        }
        if (items.count) {
            [self setNotice:[NSString stringWithFormat:
                @"已从 macOS 窗口提取 %lu 个可跨 App 拖放项目",
                (unsigned long)items.count] success:YES];
        }
        CGRect sourceRect = [interaction.view convertRect:interaction.view.bounds
                                                   toView:nil];
        MacWSLog(@"interop-drag-source window=%u pid=%d point=(%.1f,%.1f) "
            "source=(%.1f,%.1f %.1fx%.1f) route=%@ providers=%lu types=%@",
            _windowID, _metalView.targetPID, point.x, point.y,
            sourceRect.origin.x, sourceRect.origin.y,
            sourceRect.size.width, sourceRect.size.height,
            route, (unsigned long)items.count,
            [typeSummaries componentsJoinedByString:@" | "]);
        if (!items.count) [self setCrossAppDragArmed:NO notice:NO];
        return items;
    }
    return @[];
}

- (void)dragInteraction:(UIDragInteraction *)interaction
         sessionWillBegin:(id<UIDragSession>)session {
    (void)session;
    if (interaction == _contentDragInteraction)
        MacWSLog(@"interop-drag-session began window=%u pid=%d",
                 _windowID, _metalView.targetPID);
}

- (BOOL)dragInteraction:(UIDragInteraction *)interaction
 sessionIsRestrictedToDraggingApplication:(id<UIDragSession>)session {
    (void)session;
    if (interaction == _contentDragInteraction) {
        MacWSLog(@"interop-drag-session cross-app-allowed window=%u pid=%d",
                 _windowID, _metalView.targetPID);
    }
    return NO;
}

- (void)dragInteraction:(UIDragInteraction *)interaction
                 session:(id<UIDragSession>)session
     didEndWithOperation:(UIDropOperation)operation {
    (void)session;
    if (interaction == _contentDragInteraction) {
        MacWSLog(@"interop-drag-session ended window=%u pid=%d operation=%lu",
                 _windowID, _metalView.targetPID, (unsigned long)operation);
        if (operation == UIDropOperationCopy ||
            operation == UIDropOperationMove) {
            // UIDragInteraction.h states that cross-process data transfer
            // starts *after* this callback. Restore MacWS touch arbitration
            // now, but keep the interaction/provider alive until UIKit sends
            // sessionDidTransferItems:.
            _crossAppDragArmed = NO;
            _crossAppDragTransferPending = YES;
            _metalView.crossAppDragModeEnabled = NO;
            [self updateCrossAppDragButton];
            MacWSLog(@"interop-drag-session transfer-pending window=%u pid=%d",
                     _windowID, _metalView.targetPID);
        } else {
            _crossAppDragTransferPending = NO;
            [self setCrossAppDragArmed:NO notice:NO];
        }
    }
}

- (void)dragInteraction:(UIDragInteraction *)interaction
 sessionDidTransferItems:(id<UIDragSession>)session {
    (void)session;
    if (interaction != _contentDragInteraction) return;
    _crossAppDragTransferPending = NO;
    _contentDragInteraction.enabled = NO;
    _crossAppDragSurface.hidden = YES;
    [self hideCrossAppDragHandle];
    _preparedMacOSDragProviders = nil;
    _preparedMacOSDragURLs = nil;
    _metalView.crossAppDragModeEnabled = NO;
    [self updateCrossAppDragButton];
    _crossAppDragButton.enabled = _windowID != 0 && _interopClient.isConnected;
    MacWSLog(@"interop-drag-session transfer-complete window=%u pid=%d",
             _windowID, _metalView.targetPID);
}

- (BOOL)dropInteraction:(UIDropInteraction *)interaction
        canHandleSession:(id<UIDropSession>)session {
    (void)interaction;
    return session.items.count > 0;
}

- (void)dropInteraction:(UIDropInteraction *)interaction
       sessionDidEnter:(id<UIDropSession>)session {
    if (MacWSHostTouchDiagnosticsEnabled())
        MacWSLog(@"interop-drop-session entered window=%u items=%lu view=%@",
            _windowID, (unsigned long)session.items.count, interaction.view);
}

- (void)dropInteraction:(UIDropInteraction *)interaction
         sessionDidEnd:(id<UIDropSession>)session {
    (void)interaction;
    if (MacWSHostTouchDiagnosticsEnabled())
        MacWSLog(@"interop-drop-session ended window=%u items=%lu",
            _windowID, (unsigned long)session.items.count);
}

- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction
                    sessionDidUpdate:(id<UIDropSession>)session {
    (void)interaction;
    (void)session;
    return [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
}

- (void)dropInteraction:(UIDropInteraction *)interaction
      performDrop:(id<UIDropSession>)session {
    CGPoint point = [session locationInView:_metalView];
    NSMutableArray<NSItemProvider *> *providers = [NSMutableArray array];
    for (UIDragItem *dragItem in session.items)
        if (dragItem.itemProvider) [providers addObject:dragItem.itemProvider];
    NSMutableArray<NSString *> *typeSummaries = [NSMutableArray array];
    for (NSItemProvider *provider in providers)
        [typeSummaries addObject:[provider.registeredTypeIdentifiers
            componentsJoinedByString:@","]];
    MacWSLog(@"interop-drop-received window=%u pid=%d point=(%.1f,%.1f) providers=%lu types=%@",
        _windowID, _metalView.targetPID, point.x, point.y,
        (unsigned long)providers.count,
        [typeSummaries componentsJoinedByString:@" | "]);
    [_interopClient publishItemProviders:providers
        completion:^(BOOL applied, NSError *error) {
            MacWSLog(@"interop-drop-target window=%u pid=%d point=(%.1f,%.1f) providers=%lu applied=%@ error=%@",
                self->_windowID, self->_metalView.targetPID, point.x, point.y,
                (unsigned long)providers.count, applied ? @"YES" : @"NO",
                error ?: @"nil");
            if (applied) {
                [self->_metalView performInteropPasteAtViewPoint:point];
                [self setNotice:[NSString stringWithFormat:
                    @"已在 macOS 落点粘贴 %lu 个拖放项目（保留多格式）",
                    (unsigned long)providers.count] success:YES];
            } else {
                [self setNotice:error.localizedDescription success:NO];
            }
        }];
}

- (NSArray<MacWSStreamWindow *> *)logicalWindowRepresentatives {
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, MacWSStreamWindow *> *representatives =
        [NSMutableDictionary dictionary];
    for (MacWSStreamWindow *window in _streamWindows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        NSString *identity = MacWSWindowIdentity(descriptor.ownerPID,
            descriptor.windowID, descriptor.logicalGroupID);
        if (!identity) continue;
        MacWSStreamWindow *current = representatives[identity];
        if (!current) {
            representatives[identity] = window;
            [order addObject:identity];
            continue;
        }
        MacWSStreamWindowFlags flags = descriptor.flags;
        MacWSStreamWindowFlags currentFlags = current.descriptor.flags;
        NSUInteger score = ((flags & MacWSStreamWindowFocused) ? 4 : 0) |
            ((flags & MacWSStreamWindowOnScreen) ? 2 : 0) |
            ((descriptor.windowID == _windowID) ? 1 : 0);
        NSUInteger currentScore =
            ((currentFlags & MacWSStreamWindowFocused) ? 4 : 0) |
            ((currentFlags & MacWSStreamWindowOnScreen) ? 2 : 0) |
            ((current.descriptor.windowID == _windowID) ? 1 : 0);
        if (score > currentScore) representatives[identity] = window;
    }
    NSMutableArray<MacWSStreamWindow *> *result = [NSMutableArray array];
    for (NSString *identity in order) {
        MacWSStreamWindow *window = representatives[identity];
        if (window) [result addObject:window];
    }
    return result;
}

- (void)openWindowPicker {
    [_metalView requestStreamWindowList];
    NSArray<MacWSStreamWindow *> *logicalWindows =
        [self logicalWindowRepresentatives];
    if (logicalWindows.count == 0) {
        [self setNotice:@"正在读取 macOS 窗口；DisplayStream 服务就绪后请再试一次。"
                 success:YES];
        return;
    }
    BOOL fullscreenWorkspace = [self isFullscreenWorkspace];
    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:fullscreenWorkspace
            ? @"切换 macOS 窗口" : @"在新 iPadOS 窗口中打开"
                         message:fullscreenWorkspace
            ? @"所选窗口会留在当前全屏桌面中，不会创建新的 iPadOS 窗口。"
            : @"每个 Scene 只订阅一个 macOS 窗口的 IOSurface 流。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger limit = MIN(logicalWindows.count, 24);
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSStreamWindow *window = logicalWindows[index];
        NSString *title = window.title.length ? window.title :
            [NSString stringWithFormat:@"Window %u", window.descriptor.windowID];
        [picker addAction:[UIAlertAction actionWithTitle:title
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                if ([self isFullscreenWorkspace]) {
                    [self activateMacWindow:window];
                    return;
                }
                MacWSRequestNewScene(self.view.window.windowScene,
                    window.descriptor.windowID, window.descriptor.ownerPID,
                    window.descriptor.logicalGroupID,
                    CGSizeMake(window.descriptor.logicalWidth,
                               window.descriptor.logicalHeight),
                    CGSizeMake(window.descriptor.minimumLogicalWidth,
                               window.descriptor.minimumLogicalHeight),
                    window.maximumLogicalSize,
                    (window.descriptor.flags & MacWSStreamWindowResizable) != 0,
                    (window.descriptor.flags & MacWSStreamWindowFixedWidth) != 0,
                    (window.descriptor.flags & MacWSStreamWindowFixedHeight) != 0,
                    title, YES, ^(NSError *error) {
                        if ([error.domain isEqualToString:@"FBSWorkspaceErrorDomain"] &&
                            error.code == 2) {
                            [self openWindowInCurrentScene:window
                                reason:@"iPadOS 暂未接受新窗口，已在当前窗口中打开；启用台前调度后可并排组织多个 macOS 窗口。"];
                        } else {
                            [self setNotice:error.localizedDescription success:NO];
                        }
                    });
            }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = _windowPickerButton;
    picker.popoverPresentationController.sourceRect = _windowPickerButton.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openWindowInCurrentScene:(MacWSStreamWindow *)window
                          reason:(NSString *)reason {
    if (_sceneDestructionRequested || !window ||
        window.descriptor.windowID == 0) return;
    [self openRequestedWindowInCurrentScene:window.descriptor.windowID
        ownerPID:window.descriptor.ownerPID
        logicalGroupID:window.descriptor.logicalGroupID
        preferredSize:CGSizeMake(window.descriptor.logicalWidth,
                                 window.descriptor.logicalHeight)
        minimumSize:CGSizeMake(window.descriptor.minimumLogicalWidth,
                               window.descriptor.minimumLogicalHeight)
        maximumSize:window.maximumLogicalSize
        resizable:(window.descriptor.flags & MacWSStreamWindowResizable) != 0
        fixedWidth:(window.descriptor.flags & MacWSStreamWindowFixedWidth) != 0
        fixedHeight:(window.descriptor.flags & MacWSStreamWindowFixedHeight) != 0
        title:window.title reason:reason];
}

- (void)openRequestedWindowInCurrentScene:(uint32_t)windowID
                                  ownerPID:(int32_t)ownerPID
                            logicalGroupID:(uint32_t)logicalGroupID
                             preferredSize:(CGSize)preferredSize
                               minimumSize:(CGSize)minimumSize
                               maximumSize:(CGSize)maximumSize
                                 resizable:(BOOL)resizable
                                fixedWidth:(BOOL)fixedWidth
                               fixedHeight:(BOOL)fixedHeight
                                     title:(NSString *)title
                                    reason:(NSString *)reason {
    if (_sceneDestructionRequested || windowID == 0 || ownerPID <= 1) return;
    [self openWindowIDInCurrentScene:windowID ownerPID:ownerPID
        logicalGroupID:logicalGroupID title:title reason:reason];
    _windowMinimumSize = minimumSize;
    _windowMaximumSize = maximumSize;
    _windowPreferredSize = preferredSize;
    _windowResizable = resizable;
    _windowWidthFixed = fixedWidth || !resizable;
    _windowHeightFixed = fixedHeight || !resizable;
    if (isfinite(preferredSize.width) && isfinite(preferredSize.height) &&
        preferredSize.width > 0.0 && preferredSize.height > 0.0) {
        [_metalView observeTargetWindowLogicalSize:preferredSize];
    }
    _metalView.minimumLogicalSize = _windowMinimumSize;
    _metalView.maximumLogicalSize = _windowMaximumSize;
    _metalView.targetWindowResizable = _windowResizable;
    _metalView.targetWindowFixedWidth = _windowWidthFixed;
    _metalView.targetWindowFixedHeight = _windowHeightFixed;
    // openWindowIDInCurrentScene: establishes the stream before catalog
    // metadata is installed. Persist once more with the authoritative AppKit
    // size so a later FrontBoard reconnect can reproduce the same small
    // native Scene instead of falling back to a stock category.
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
}

- (void)openWindowIDInCurrentScene:(uint32_t)windowID
                          ownerPID:(int32_t)ownerPID
                    logicalGroupID:(uint32_t)logicalGroupID
                             title:(NSString *)title
                            reason:(NSString *)reason {
    if (windowID == 0 || ownerPID <= 1) return;
    if (_sceneDestructionRequested) return;
    // A failed orphan-Scene retirement keeps a no-close tombstone. Only a
    // genuine new binding may replace it; never let a delayed discard send
    // CloseWindow through the retired owner's restoration metadata.
    NSString *sessionIdentifier =
        self.view.window.windowScene.session.persistentIdentifier;
    if (sessionIdentifier.length) {
        [MacWSSceneSessionsPreservingMacWindow removeObject:sessionIdentifier];
        [MacWSSceneCloseRequestsSent removeObject:sessionIdentifier];
    }
    [self restoreDefaultSceneSizeRestrictions];
    [_metalView suspendStream];
    // A Scene is reused across per-window and desktop presentation. A
    // double-tap zoom belongs to the old stream's coordinate space; carrying
    // it into the new stream crops the desktop and maps input into that stale
    // crop. Reset before installing the new stream identity.
    [_metalView resetViewportZoom];
    _streamMode = MacWSStreamModeWindow;
    _windowID = windowID;
    _windowOwnerPID = ownerPID;
    _windowGroupID = logicalGroupID;
    _targetWindowObservedInCatalog = NO;
    _targetWindowMissingCheckPending = NO;
    _sceneDestructionRequested = NO;
    _targetWindowMissingSerial++;
    _windowMinimumSize = CGSizeZero;
    _windowMaximumSize = CGSizeZero;
    _windowPreferredSize = CGSizeZero;
    _windowResizable = NO;
    _windowWidthFixed = NO;
    _windowHeightFixed = NO;
    _metalView.minimumLogicalSize = CGSizeZero;
    _metalView.maximumLogicalSize = CGSizeZero;
    _metalView.targetWindowResizable = NO;
    _metalView.targetWindowFixedWidth = NO;
    _metalView.targetWindowFixedHeight = NO;
    _metalView.targetPID = ownerPID;
    [self updateImmersivePresentation];
    [self updateWorkspaceChrome];
    self.view.window.windowScene.title = title.length ? title :
        [NSString stringWithFormat:@"MacWS Window %u", windowID];
    [_metalView configureStreamMode:_streamMode windowID:_windowID];
    [_metalView requestStreamWindowList];
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    if (_semanticMenuBar) [self refreshSemanticMenuWithCompletion:nil];
    [self refreshStatus];
    [self setNotice:reason.length ? reason : @"已在当前 iPadOS 窗口中打开 macOS 窗口"
             success:YES];
    MacWSLog(@"scene-reused mode=window window=%u owner=%d reason=%@",
             windowID, ownerPID, reason ?: @"");
}

- (void)openFullscreenWorkspace {
    if (_sceneDestructionRequested) return;
    if (_streamMode == MacWSStreamModeFullscreen) {
        if (!_workspaceReturnValid || _workspaceReturnWindowID == 0 ||
            _workspaceReturnOwnerPID <= 1) {
            // A restored desktop can legitimately outlive the AppKit window
            // from which it was entered.  Use the current focused, visible
            // catalog window as the return destination instead of making the
            // fullscreen toggle one-way. This is the same generic window
            // identity used by the picker and input router.
            MacWSStreamWindow *fallback = nil;
            for (MacWSStreamWindow *candidate in _streamWindows) {
                MacWSStreamWindowFlags flags = candidate.descriptor.flags;
                if (candidate.descriptor.ownerPID <= 1 ||
                    (flags & MacWSStreamWindowVisible) == 0 ||
                    (flags & MacWSStreamWindowOnScreen) == 0) continue;
                if (!fallback) fallback = candidate;
                if (flags & MacWSStreamWindowFocused) {
                    fallback = candidate;
                    break;
                }
            }
            if (!fallback) {
                [self setNotice:@"当前工作区没有可恢复的 macOS 窗口；请先打开一个应用。"
                         success:NO];
                return;
            }
            _workspaceReturnValid = YES;
            _workspaceReturnWindowID = fallback.descriptor.windowID;
            _workspaceReturnOwnerPID = fallback.descriptor.ownerPID;
            _workspaceReturnGroupID = fallback.descriptor.logicalGroupID;
            _workspaceReturnMinimumSize = CGSizeMake(
                fallback.descriptor.minimumLogicalWidth,
                fallback.descriptor.minimumLogicalHeight);
            _workspaceReturnMaximumSize = fallback.maximumLogicalSize;
            _workspaceReturnPreferredSize = CGSizeMake(
                fallback.descriptor.logicalWidth,
                fallback.descriptor.logicalHeight);
            _workspaceReturnSceneSize = _workspaceReturnPreferredSize;
            _workspaceReturnResizable =
                (fallback.descriptor.flags & MacWSStreamWindowResizable) != 0;
            _workspaceReturnWidthFixed =
                (fallback.descriptor.flags & MacWSStreamWindowFixedWidth) != 0 ||
                !_workspaceReturnResizable;
            _workspaceReturnHeightFixed =
                (fallback.descriptor.flags & MacWSStreamWindowFixedHeight) != 0 ||
                !_workspaceReturnResizable;
            _workspaceReturnTitle = fallback.title.length
                ? [fallback.title copy] : @"macOS Window";
            MacWSLog(@"workspace-return recovered-from-catalog owner=%d window=%u group=%u title=%@",
                     _workspaceReturnOwnerPID, _workspaceReturnWindowID,
                     _workspaceReturnGroupID, _workspaceReturnTitle);
        }

        uint32_t returnWindowID = _workspaceReturnWindowID;
        int32_t returnOwnerPID = _workspaceReturnOwnerPID;
        uint32_t returnGroupID = _workspaceReturnGroupID;
        CGSize returnMinimumSize = _workspaceReturnMinimumSize;
        CGSize returnMaximumSize = _workspaceReturnMaximumSize;
        CGSize returnPreferredSize = _workspaceReturnPreferredSize;
        CGSize returnSceneSize = _workspaceReturnSceneSize;
        BOOL returnResizable = _workspaceReturnResizable;
        BOOL returnWidthFixed = _workspaceReturnWidthFixed;
        BOOL returnHeightFixed = _workspaceReturnHeightFixed;
        NSString *returnTitle = [_workspaceReturnTitle copy];
        UIWindowScene *scene = self.view.window.windowScene;
        __weak MacWSViewController *weakSelf = self;
        void (^restoreInCurrentScene)(NSError *) = ^(NSError *error) {
            MacWSViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_sceneDestructionRequested = NO;
            BOOL requestedSystemWindowed =
                MacWSRequestCurrentSceneMaximization(scene, NO, nil);
            strongSelf->_workspaceReturnValid = NO;
            strongSelf->_workspaceReturnWindowID = 0;
            strongSelf->_workspaceReturnOwnerPID = 0;
            strongSelf->_workspaceReturnGroupID = 0;
            strongSelf->_workspaceReturnMinimumSize = CGSizeZero;
            strongSelf->_workspaceReturnMaximumSize = CGSizeZero;
            strongSelf->_workspaceReturnPreferredSize = CGSizeZero;
            strongSelf->_workspaceReturnSceneSize = CGSizeZero;
            strongSelf->_workspaceReturnResizable = NO;
            strongSelf->_workspaceReturnWidthFixed = NO;
            strongSelf->_workspaceReturnHeightFixed = NO;
            strongSelf->_workspaceReturnTitle = nil;
            [strongSelf openWindowIDInCurrentScene:returnWindowID
                                          ownerPID:returnOwnerPID
                                    logicalGroupID:returnGroupID
                                             title:returnTitle
                                            reason:nil];
            strongSelf->_windowMinimumSize = returnMinimumSize;
            strongSelf->_windowMaximumSize = returnMaximumSize;
            strongSelf->_windowPreferredSize = returnPreferredSize;
            strongSelf->_windowResizable = returnResizable;
            strongSelf->_windowWidthFixed = returnWidthFixed ||
                !returnResizable;
            strongSelf->_windowHeightFixed = returnHeightFixed ||
                !returnResizable;
            strongSelf->_metalView.minimumLogicalSize = returnMinimumSize;
            strongSelf->_metalView.maximumLogicalSize = returnMaximumSize;
            strongSelf->_metalView.targetWindowResizable = returnResizable;
            strongSelf->_metalView.targetWindowFixedWidth =
                strongSelf->_windowWidthFixed;
            strongSelf->_metalView.targetWindowFixedHeight =
                strongSelf->_windowHeightFixed;
            MacWSRememberSceneBinding(scene.session,
                                      [strongSelf streamRestorationActivity]);
            [strongSelf hideControls];
            [strongSelf setNotice:error
                ? [NSString stringWithFormat:
                    @"系统未能创建窗口场景，已在当前场景恢复：%@",
                    error.localizedDescription ?: @"未知错误"]
                : (requestedSystemWindowed
                    ? @"正在通过 iPadOS 系统动画恢复窗口模式"
                    : @"已恢复 macOS 窗口内容")
                         success:error == nil];
            MacWSLog(@"scene-reused mode=window restored-from-workspace window=%u owner=%d group=%u remembered-scene-size=%.1fx%.1f system-unzoom-requested=%@ replacement-error=%@",
                     returnWindowID, returnOwnerPID, returnGroupID,
                     returnSceneSize.width, returnSceneSize.height,
                     requestedSystemWindowed ? @"YES" : @"NO",
                     error ?: @"none");
        };

        if (_sceneDestructionRequested) return;
        _sceneDestructionRequested = YES;
        BOOL requestedReplacement = MacWSRequestWindowedReplacementScene(
            scene, returnWindowID, returnOwnerPID, returnGroupID,
            returnPreferredSize, returnMinimumSize, returnMaximumSize, returnResizable,
            returnWidthFixed, returnHeightFixed, returnTitle,
            restoreInCurrentScene);
        if (!requestedReplacement) {
            restoreInCurrentScene(nil);
            return;
        }
        [self hideControls];
        [self setNotice:@"正在通过 iPadOS 系统窗口动画恢复窗口模式"
                 success:YES];
        MacWSLog(@"scene-windowed-replacement submitted old=%@ window=%u owner=%d group=%u remembered-scene-size=%.1fx%.1f",
                 scene.session.persistentIdentifier, returnWindowID,
                 returnOwnerPID, returnGroupID, returnSceneSize.width,
                 returnSceneSize.height);
        return;
    }

    // Fullscreen is a presentation mode of the current Scene. The previous
    // implementation requested a second Scene session, so the button could
    // never make the window the user was operating become the workspace.
    // First activate the exact native window while its ID/PID mapping is still
    // authoritative, then detach this Scene from that identity and subscribe
    // it to the complete desktop producer.
    _workspaceReturnValid = _windowID != 0 && _windowOwnerPID > 1;
    _workspaceReturnWindowID = _windowID;
    _workspaceReturnOwnerPID = _windowOwnerPID;
    _workspaceReturnGroupID = _windowGroupID;
    _workspaceReturnMinimumSize = _windowMinimumSize;
    _workspaceReturnMaximumSize = _windowMaximumSize;
    _workspaceReturnPreferredSize = _windowPreferredSize;
    // UIWindowScene.coordinateSpace is panel-sized even for a Stage Manager
    // Center window on iPadOS 16 (runtime: 1389x970 in both roles). The root
    // view is the actual Scene content extent. Preserve it only as a witness;
    // SpringBoard's maximization toggle owns restoration of the native size.
    CGSize currentViewSize = self.view.bounds.size;
    _workspaceReturnSceneSize =
        currentViewSize.width >= 150.0 && currentViewSize.height >= 150.0
            ? currentViewSize : _windowPreferredSize;
    _workspaceReturnResizable = _windowResizable;
    _workspaceReturnWidthFixed = _windowWidthFixed;
    _workspaceReturnHeightFixed = _windowHeightFixed;
    _workspaceReturnTitle = [self.view.window.windowScene.title copy];
    BOOL activatedExactWindow = [self activateCurrentMacWindow];
    [_metalView suspendStream];
    [_metalView resetViewportZoom];
    _streamMode = MacWSStreamModeFullscreen;
    _windowID = 0;
    _windowOwnerPID = 0;
    _windowGroupID = 0;
    _windowMinimumSize = CGSizeZero;
    _windowMaximumSize = CGSizeZero;
    _windowPreferredSize = CGSizeZero;
    _windowResizable = NO;
    _windowWidthFixed = NO;
    _windowHeightFixed = NO;
    _targetWindowObservedInCatalog = NO;
    _targetWindowMissingCheckPending = NO;
    _sceneDestructionRequested = NO;
    _targetWindowMissingSerial++;
    _bootstrapTerminalPending = NO;
    _bootstrapWindowReplacementPending = NO;
    _metalView.targetPID = 0;
    _metalView.minimumLogicalSize = CGSizeZero;
    _metalView.maximumLogicalSize = CGSizeZero;
    _metalView.targetWindowResizable = NO;
    _metalView.targetWindowFixedWidth = NO;
    _metalView.targetWindowFixedHeight = NO;
    [self restoreDefaultSceneSizeRestrictions];
    [self dismissSemanticMenu];
    [self updateImmersivePresentation];
    [self updateWorkspaceChrome];
    self.view.window.windowScene.title = @"MacWS Workspace";
    [_metalView configureStreamMode:_streamMode windowID:0];
    [_metalView requestStreamWindowList];
    // Fullscreen is presentation state, not a new owner identity. Persist the
    // return identity in the Scene activity so a UIKit process eviction does
    // not strand the AppKit window or turn the toggle into a one-way action.
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    NSUserActivity *workspaceActivity = [self streamRestorationActivity];
    BOOL requestedSystemFullscreen =
        MacWSRequestCurrentSceneMaximization(
        self.view.window.windowScene, YES,
        ^(NSError *error) {
            [self setNotice:[NSString stringWithFormat:
                @"完整 macOS 桌面已经打开，但 iPadOS 无法最大化当前窗口：%@",
                error.localizedDescription ?: @"未知错误"] success:NO];
        });
    if (!requestedSystemFullscreen) {
        requestedSystemFullscreen = MacWSRequestCurrentSceneImmersiveFullscreen(
            self.view.window.windowScene, workspaceActivity,
            ^(NSError *error) {
                [self setNotice:[NSString stringWithFormat:
                    @"完整 macOS 桌面已经打开，但 iPadOS 无法最大化当前窗口：%@",
                    error.localizedDescription ?: @"未知错误"] success:NO];
            });
    }
    if (requestedSystemFullscreen) {
        // Both native presentation routes are asynchronous. Verify the real
        // UIWindow rather than treating request acceptance (or isFullScreen)
        // as a geometry witness. Retry the exact Scene action only if needed.
        __weak MacWSViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     1250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSViewController *strongSelf = weakSelf;
            if (!strongSelf ||
                strongSelf->_streamMode != MacWSStreamModeFullscreen) return;
            UIWindowScene *currentScene = strongSelf.view.window.windowScene;
            CGRect visibleBounds = strongSelf.view.window.bounds;
            CGRect screenBounds = currentScene.screen.bounds;
            BOOL systemState = [currentScene respondsToSelector:
                @selector(isFullScreen)] && currentScene.isFullScreen;
            BOOL fillsPanel = fabs(visibleBounds.size.width -
                                   screenBounds.size.width) <= 1.0 &&
                fabs(visibleBounds.size.height -
                     screenBounds.size.height) <= 1.0;
            if (fillsPanel) {
                MacWSLog(@"scene-immersive landed session=%@ is-fullscreen=%@ bounds=%@ screen=%@",
                         currentScene.session.persistentIdentifier,
                         systemState ? @"YES" : @"NO",
                         NSStringFromCGRect(visibleBounds),
                         NSStringFromCGRect(screenBounds));
                return;
            }
            MacWSLog(@"scene-immersive fallback session=%@ reason=window-bounds-not-fullscreen bounds=%@ screen=%@",
                     currentScene.session.persistentIdentifier,
                     NSStringFromCGRect(visibleBounds),
                     NSStringFromCGRect(screenBounds));
            MacWSRequestCurrentSceneMaximization(
                currentScene, YES, ^(NSError *error) {
                    [strongSelf setNotice:[NSString stringWithFormat:
                        @"完整 macOS 桌面已经打开，但 iPadOS 无法最大化当前窗口：%@",
                        error.localizedDescription ?: @"未知错误"] success:NO];
                });
        });
    }
    [self hideControls];
    [self refreshStatus];
    [self setNotice:requestedSystemFullscreen
        ? @"正在将当前 iPadOS 窗口最大化并显示完整 macOS 工作区"
        : @"已显示完整 macOS 工作区；当前 iPadOS 版本没有可用的最大化请求"
             success:requestedSystemFullscreen];
    MacWSLog(@"scene-reused mode=fullscreen previous-window-activated=%@ system-fullscreen-requested=%@",
             activatedExactWindow ? @"YES" : @"NO",
             requestedSystemFullscreen ? @"YES" : @"NO");
}

- (void)setFullscreenWorkspaceEnabled:(BOOL)enabled {
    BOOL active = _streamMode == MacWSStreamModeFullscreen;
    if (active == enabled) {
        MacWSLog(@"workspace-mode request idempotent requested=%@ active=%@ recovery=%@",
                 enabled ? @"fullscreen" : @"window",
                 active ? @"fullscreen" : @"window",
                 enabled ? @"YES" : @"NO");
        // A service restart does not change the controller's persisted mode,
        // but it can invalidate the DisplayStream connection and the system's
        // presentation transaction.  Treat a repeated enter-workspace request
        // as an explicit recovery operation: reassert the real UIKit scene
        // geometry and refreshStatus will reconnect the stream when its live
        // connection witness is false.  Exiting an already-windowed workspace
        // remains a true no-op.
        if (enabled) {
            // A Host restart can restore the persisted fullscreen stream mode
            // while the freshly-created controller still has its bootstrap
            // control panel visible.  Reasserting only the Scene geometry then
            // leaves a screen-filling control center over a healthy macOS
            // desktop.  Converge the presentation state as well as the stream
            // and geometry state, matching the first-entry path below.
            [self hideControls];
            [self reassertFullscreenScenePresentation];
            [self refreshStatus];
            MacWSLog(@"workspace-mode recovery controls-hidden=YES");
        }
        return;
    }
    [self openFullscreenWorkspace];
}

- (void)reassertFullscreenScenePresentation {
    if (_streamMode != MacWSStreamModeFullscreen) return;
    [self updateImmersivePresentation];
    BOOL requested = MacWSRequestCurrentSceneMaximization(
        self.view.window.windowScene, YES, ^(NSError *error) {
            [self setNotice:[NSString stringWithFormat:
                @"完整 macOS 桌面已恢复，但 iPadOS 无法重新最大化窗口：%@",
                error.localizedDescription ?: @"未知错误"] success:NO];
        });
    MacWSLog(@"scene-fullscreen foreground-reassert requested=%@",
             requested ? @"YES" : @"NO");
}

- (void)refreshStatus {
    [_controlClient fetchStatus:^(NSDictionary<NSString *,id> *reply) {
        [self applyStatus:reply];
    }];
}

- (void)applyStatus:(NSDictionary<NSString *, id> *)status {
    _latestStatus = status;
    BOOL connected = ![status[@"connection_error"] boolValue];
    BOOL busy = [status[@"busy"] boolValue];
    BOOL rootfs = [status[@"rootfs_ready"] boolValue];
    BOOL ws = [status[@"windowserver_running"] boolValue];
    BOOL input = [status[@"input_running"] boolValue];
    BOOL systemInputReady =
        [status[@MACWS_CONTROL_KEY_SYSTEM_INPUT_READY] boolValue];
    int32_t systemInputPID = systemInputReady
        ? [status[@MACWS_CONTROL_KEY_SYSTEM_INPUT_PID] intValue] : 0;
    BOOL frame = [status[@"frame_ready"] boolValue];
    BOOL startupRetry = [status[@"startup_retry_available"] boolValue];
    BOOL legacyFramebuffer = MacWSLegacyFramebufferFallbackEnabled();
    BOOL renderableFrame = _metalView.hasDirectSurfaceFrame ||
        (legacyFramebuffer && frame);
    int32_t catalogPID = _metalView.targetPID;
    int32_t targetPID = _streamMode == MacWSStreamModeWindow
        ? _windowOwnerPID
        : (MacWSAppInputEndpointReady(catalogPID) ? catalogPID : 0);
    // The full workspace must follow AppKit's actual focused window catalog,
    // not macwshostd's process-local "last app launched" cache.  The daemon
    // can restart while healthy chroot applications and their endpoints stay
    // alive; treating its empty cache as authoritative disabled all touch on
    // an otherwise visible desktop.  Endpoint existence is the invariant for
    // both exact-window and full-workspace routing.
    BOOL appInput = MacWSAppInputEndpointReady(targetPID);
    BOOL fullscreenSystemRoute =
        _streamMode == MacWSStreamModeFullscreen && targetPID <= 1 &&
        systemInputReady && systemInputPID > 1;
    NSString *controlSummary = [NSString stringWithFormat:
        @"connected=%@ busy=%@ rootfs=%@ ws=%@ input=%@ system-input=%@/%d frame=%@ phase=%@ error=%@",
        connected ? @"YES" : @"NO", busy ? @"YES" : @"NO",
        rootfs ? @"YES" : @"NO", ws ? @"YES" : @"NO",
        input ? @"YES" : @"NO", systemInputReady ? @"YES" : @"NO",
        systemInputPID, frame ? @"YES" : @"NO",
        status[@"phase"] ?: @"", status[@"last_error"] ?: @""];
    if (![_lastLoggedControlSummary isEqualToString:controlSummary]) {
        _lastLoggedControlSummary = controlSummary;
        MacWSLog(@"control-status %@", controlSummary);
    }
    // A persisted fullscreen Scene can reconnect before the root control
    // reply reveals that WindowServer is gone (for example after an iPadOS
    // respring retires the UIKit-hosted bridge generation).  The black Metal
    // canvas is not a usable recovery UI.  Converge any such stale Scene on
    // the Control Center as soon as the authoritative WindowServer state is
    // known. This also repairs already-persisted sessions created by older
    // builds rather than relying only on the initializer above.
    if (!ws && _controlPanel.hidden) {
        [self showControls];
        MacWSLog(@"workspace-offline controls-shown=YES mode=%u window=%u",
                 _streamMode, _windowID);
    }
    _serviceLabel.text = connected
        ? MacWSLocalized(@"● root 控制服务已连接", @"● Root control service connected")
        : MacWSLocalized(@"● root 控制服务离线", @"● Root control service offline");
    _serviceLabel.textColor = connected ? UIColor.systemGreenColor : UIColor.systemRedColor;
    NSString *rawPhase = status[@"phase"] ?: status[@"message"];
    _phaseLabel.text = MacWSLocalizedPhase(rawPhase) ?:
        MacWSLocalized(@"等待状态", @"Waiting for status");
    _rootfsLabel.text = rootfs ? MacWSLocalized(@"就绪", @"Ready")
                               : MacWSLocalized(@"缺失/未挂载", @"Missing / Unmounted");
    _rootfsLabel.textColor = rootfs ? UIColor.systemGreenColor : UIColor.systemRedColor;
    NSInteger wsPID = [status[@"windowserver_pid"] integerValue];
    _windowServerLabel.text = ws
        ? [NSString stringWithFormat:MacWSLocalized(@"运行中 · %ld", @"Running · %ld"),
                                     (long)wsPID]
        : MacWSLocalized(@"已停止", @"Stopped");
    _windowServerLabel.textColor = ws ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
    _bridgeLabel.text = input
        ? (targetPID > 1 && appInput
            ? [NSString stringWithFormat:MacWSLocalized(@"在线 · 目标 PID %d", @"Online · Target PID %d"), targetPID]
            : (fullscreenSystemRoute
                ? MacWSLocalized(@"在线 · 全桌面逐点命中", @"Online · Desktop hit testing")
                : (targetPID > 1
                    ? MacWSLocalized(@"在线 · 等待应用输入端点", @"Online · Waiting for app input endpoint")
                    : MacWSLocalized(@"在线 · 等待应用", @"Online · Waiting for app"))))
        : MacWSLocalized(@"离线", @"Offline");
    _bridgeLabel.textColor = input ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    if (_metalView.hasDirectSurfaceFrame) {
        _frameLabel.text = _metalView.hasFinalCompositeFrame
            ? MacWSLocalized(@"最终合成 · IOSurface", @"Final Composite · IOSurface")
            : MacWSLocalized(@"窗口层合成 · IOSurface", @"Window-Layer Composite · IOSurface");
        _frameLabel.textColor =
            (_streamMode == MacWSStreamModeFullscreen &&
             !_metalView.hasFinalCompositeFrame)
                ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
    } else if (legacyFramebuffer && frame) {
        _frameLabel.text = [NSString stringWithFormat:@"%@×%@",
                            status[@"frame_width"], status[@"frame_height"]];
        _frameLabel.textColor = UIColor.systemGreenColor;
    } else {
        _frameLabel.text = MacWSLocalized(@"等待 DisplayStream IOSurface 首帧",
                                          @"Waiting for first DisplayStream IOSurface frame");
        _frameLabel.textColor = UIColor.systemOrangeColor;
    }
    NSString *lastError = status[@"last_error"];
    if (lastError.length) [self setNotice:lastError success:NO];

    if (ws && !_metalView.streamServiceConnected &&
        !(_bootstrapTerminalPending && _windowID == 0))
        [_metalView configureStreamMode:_streamMode windowID:_windowID];
    if (ws && !_interopClient.isConnected) [_interopClient connect];

    _metalView.targetPID = targetPID;
    _metalView.systemInputPID = systemInputPID;
    // A root control transaction (for example a 30-second application launch
    // witness) does not stop WindowServer, DisplayStream, or the per-process
    // input sockets.  Coupling desktop input to hostd's unrelated `busy` bit
    // made the whole fullscreen workspace intentionally unresponsive while an
    // app was starting.  Keep controls serialized, but derive input readiness
    // solely from the live display/input transport invariants.
    BOOL inputReady = connected && ws && input && renderableFrame &&
        ((targetPID > 1 && appInput) || fullscreenSystemRoute);
    NSString *inputReason = nil;
    if (!connected) inputReason = MacWSLocalized(@"root 控制服务离线", @"Root control service offline");
    else if (!ws) inputReason = MacWSLocalized(@"macOS 工作区已停止", @"macOS workspace stopped");
    else if (!input) inputReason = MacWSLocalized(@"触控桥离线", @"Touch bridge offline");
    else if (!renderableFrame) inputReason = MacWSLocalized(@"等待 DisplayStream IOSurface 首帧", @"Waiting for first DisplayStream frame");
    else if (_streamMode == MacWSStreamModeFullscreen && targetPID <= 1 &&
             !fullscreenSystemRoute)
        inputReason = MacWSLocalized(@"等待桌面系统输入端点", @"Waiting for desktop system input endpoint");
    else if (targetPID <= 1 && !fullscreenSystemRoute)
        inputReason = MacWSLocalized(@"等待该窗口的所属应用", @"Waiting for this window's app");
    else if (!appInput) inputReason = MacWSLocalized(@"目标应用输入端点尚未就绪", @"Target app input endpoint is not ready");
    BOOL inputWasReady = _metalView.isMacWSInputEnabled;
    [_metalView setMacWSInputEnabled:inputReady reason:inputReason];
    [self updateGamePointerLockPreferenceWithReason:@"input-readiness"];
    if (inputReady && !inputWasReady) {
        // Scene activation and control dismissal can precede the first
        // DisplayStream frame. Their focus requests correctly decline while
        // input is unavailable; complete the same ownership transaction on
        // the actual not-ready -> ready edge instead of waiting for a click.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self restoreHardwareKeyboardFocusWithReason:@"input-ready"];
        });
    }
    _inputLabel.text = inputReady
        ? MacWSLocalized(@"触控：已就绪 · 直接点击或拖动 macOS 画面",
                         @"Touch: Ready · Tap or drag the macOS display")
        : [NSString stringWithFormat:MacWSLocalized(@"触控：不可用 · %@",
                                                     @"Touch: Unavailable · %@"),
           inputReason ?: MacWSLocalized(@"工作区未就绪", @"Workspace not ready")];
    _inputLabel.textColor = inputReady
        ? UIColor.systemGreenColor : UIColor.systemOrangeColor;

    [self setControlsEnabled:connected && !busy];
    if (busy) {
        [self setButton:_primaryButton title:MacWSControlCenterUsesEnglish()
            ? @"Working…" : (status[@"phase"] ?: @"处理中…")
                   image:@"hourglass"];
    } else if (ws) {
        [self setButton:_primaryButton title:MacWSLocalized(@"停止 macOS", @"Stop macOS") image:@"stop.fill"];
    } else if (startupRetry) {
        [self setButton:_primaryButton
                  title:MacWSLocalized(@"重新尝试启动", @"Try Starting Again")
                  image:@"arrow.clockwise"];
    } else {
        [self setButton:_primaryButton
                  title:rootfs ? MacWSLocalized(@"启动 macOS 工作区", @"Start macOS Workspace")
                               : MacWSLocalized(@"初始化并启动", @"Initialize and Start")
                  image:@"play.fill"];
    }

    NSString *startupLog = status[@"startup_log"] ?: @"";
    BOOL showStartupLog = startupLog.length > 0 || startupRetry;
    _startupLogSectionLabel.hidden = !showStartupLog;
    _logsView.hidden = !showStartupLog;
    _retryStartupButton.hidden = !startupRetry;
    if (showStartupLog && startupLog.length &&
        ![_lastStartupLog isEqualToString:startupLog]) {
        _lastStartupLog = [startupLog copy];
        _logsView.text = startupLog;
        [_logsView scrollRangeToVisible:NSMakeRange(startupLog.length - 1, 1)];
    }

    NSDictionary<NSString *, NSString *> *availability = @{
        @"glassdemo": @"glassdemo_available",
        @"terminal": @"terminal_available",
        @"activity-monitor": @"activity_monitor_available",
        @"finder": @"finder_available",
        @"vscode": @"vscode_available",
        @"system-settings": @"system_settings_available",
        @"maps": @"maps_available",
        @"amadine": @"amadine_available",
        @"word": @"word_available",
        @"excel": @"excel_available",
        @"powerpoint": @"powerpoint_available",
        @"steam": @"steam_available",
        @"weather": @"weather_available",
        @"sublime": @"sublime_available",
    };
    for (UIButton *button in _applicationButtons) {
        BOOL available = [status[availability[button.accessibilityIdentifier]] boolValue];
        button.enabled = connected && !busy && ws && available;
    }

    // A new Host Scene is a launcher for one concrete macOS window, not a
    // full-display workspace. Start production macOS if needed, then launch
    // Terminal exactly once. The first catalog entry replaces this Scene
    // in-place, so no redundant black Scene survives startup.
    if (_bootstrapTerminalPending && connected && !busy) {
        if (ws) {
            _bootstrapTerminalPending = NO;
            [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                     arguments:@{@MACWS_CONTROL_KEY_APP_ID: @"terminal"}];
        } else if (!_bootstrapWorkspaceStartInFlight &&
                   !_bootstrapWorkspaceStartAttempted) {
            // One Scene owns at most one automatic workspace start. A failed
            // start leaves ws=NO; applyStatus: is called again by the status
            // timer, so checking only the in-flight bit created an unbounded
            // restart loop. Runtime-confirmed on 2026-08-29 by consecutive
            // macos_gui.sh owners 40307 -> 42910 -> 45547. Explicit retry and
            // repair controls remain available after this one attempt.
            _bootstrapWorkspaceStartAttempted = YES;
            _bootstrapWorkspaceStartInFlight = YES;
            MacWSLog(@"bootstrap-workspace automatic-start attempt=1");
            [self setNotice:@"正在启动 macOS，并准备默认终端窗口…" success:YES];
            [_controlClient startWithExperimentalMode:YES
                completion:^(NSDictionary<NSString *,id> *reply) {
                    self->_bootstrapWorkspaceStartInFlight = NO;
                    BOOL ok = [reply[@"ok"] boolValue];
                    MacWSLog(@"bootstrap-workspace automatic-start completed=%@ message=%@",
                             ok ? @"YES" : @"NO",
                             reply[@"message"] ?: @"(nil)");
                    [self applyStatus:reply];
                    if (!ok) {
                        [self setNotice:reply[@"message"] ?:
                            @"macOS 工作区启动失败" success:NO];
                    }
                }];
        }
    }
}

- (void)runOperation:(NSString *)operation arguments:(NSDictionary *)arguments {
    [self setControlsEnabled:NO];
    NSString *submitted = [operation isEqualToString:
        @MACWS_CONTROL_OP_REPAIR_DESKTOP]
        ? MacWSLocalized(
            @"正在保留当前应用并重建 Dock、图标、桌布与菜单服务…",
            @"Keeping current apps open while rebuilding Dock, icons, wallpaper, and menu services…")
        : @"操作已提交，请保持 App 在前台…";
    [self setNotice:submitted success:YES];
    [_controlClient performOperation:operation arguments:arguments
        completion:^(NSDictionary<NSString *,id> *reply) {
            BOOL ok = [reply[@"ok"] boolValue];
            [self setNotice:reply[@"message"] ?: @"操作完成" success:ok];
            [self applyStatus:reply];
            if (ok && ([operation isEqualToString:@MACWS_CONTROL_OP_LAUNCH_APP] ||
                       [operation isEqualToString:@MACWS_CONTROL_OP_OPEN_DOCUMENTS])) {
                NSString *identifier = arguments[@MACWS_CONTROL_KEY_APP_ID] ?: @"document";
                int32_t launchedPID =
                    (int32_t)[reply[@"launched_app_pid"] intValue];
                if (launchedPID > 1) {
                    // hostd now completes Finder's native Command-N bootstrap
                    // before replying, so Finder follows the same catalog ->
                    // one Scene transaction as every other application. The
                    // old post-reply menu walk created a second browser window
                    // after the first had already become visible.
                    self->_pendingApplicationWindowPID = launchedPID;
                    self->_pendingApplicationIdentifier = identifier;
                    self->_pendingApplicationWindowAttempts = 0;
                    self->_pendingApplicationWindowRetryScheduled = NO;
                    self->_pendingApplicationCandidateWindowID = 0;
                    self->_pendingApplicationCandidateSince = 0;
                    [self schedulePendingApplicationWindowRetry];
                }
                [self->_metalView requestStreamWindowList];
            }
            if (ok && [operation isEqualToString:
                       @MACWS_CONTROL_OP_REPAIR_DESKTOP]) {
                // Dock/SystemUIServer replacement changes the fullscreen
                // layer graph while WindowServer and ordinary applications
                // remain alive. Reconnect only this Host's display stream so
                // the repaired final composite and icon-backed Dock windows
                // replace any retained pre-repair frame.
                [self->_metalView suspendStream];
                [self->_metalView configureStreamMode:self->_streamMode
                                              windowID:self->_windowID];
                [self->_metalView requestStreamWindowList];
                if (self->_windowID != 0)
                    [self refreshSemanticMenuWithCompletion:nil];
            }
            [self refreshStatus];
        }];
}

- (void)primaryAction {
    if ([_latestStatus[@"windowserver_running"] boolValue]) {
        [self runOperation:@MACWS_CONTROL_OP_STOP arguments:nil];
    } else {
        [self setControlsEnabled:NO];
        _retryStartupButton.hidden = YES;
        _startupLogSectionLabel.hidden = NO;
        _logsView.hidden = NO;
        _lastStartupLog = MacWSLocalized(@"正在请求启动…", @"Requesting startup…");
        _logsView.text = _lastStartupLog;
        [self setNotice:@"正在检查环境；重启后丢失的信任缓存会自动恢复。" success:YES];
        [_controlClient startWithExperimentalMode:NO
            completion:^(NSDictionary<NSString *,id> *reply) {
                BOOL ok = [reply[@"ok"] boolValue];
                [self setNotice:reply[@"message"] ?: @"启动完成" success:ok];
                [self applyStatus:reply];
                [self refreshStatus];
            }];
    }
}

- (void)retryStartupAction {
    [self setNotice:MacWSLocalized(
        @"正在重新执行启动检查；日志会在下方实时更新。",
        @"Retrying startup checks; the live log will update below.")
             success:YES];
    [self primaryAction];
}

- (void)launchApplication:(UIButton *)sender {
    [self launchApplicationIdentifier:sender.accessibilityIdentifier ?: @""];
}

- (void)openExternalDocumentURL:(NSURL *)url {
    [self cancelBootstrapTerminal];
    // Retain provider access while a stopped macOS workspace is starting.
    // Never restart a running WindowServer for a document import.
    BOOL scoped = [url startAccessingSecurityScopedResource];
    [self setNotice:MacWSLocalized(@"正在导入文件副本…",
                                   @"Importing a copy of the document…") success:YES];
    void (^stage)(void) = ^{
        [MacWSInteropClient importDocumentURL:url
            completion:^(NSString *path, NSError *error) {
                if (scoped) [url stopAccessingSecurityScopedResource];
                if (!path.length || error) {
                    [self setNotice:error.localizedDescription ?: @"文件导入失败"
                             success:NO];
                    return;
                }
                [self runOperation:@MACWS_CONTROL_OP_OPEN_DOCUMENTS
                    arguments:@{@MACWS_CONTROL_KEY_DOCUMENT_PATHS: @[path]}];
            }];
    };
    [_controlClient fetchStatus:^(NSDictionary<NSString *, id> *status) {
        if ([status[@"connection_error"] boolValue]) {
            if (scoped) [url stopAccessingSecurityScopedResource];
            [self setNotice:status[@"message"] ?: @"控制服务不可用" success:NO];
        } else if ([status[@"windowserver_running"] boolValue]) {
            stage();
        } else {
            [self->_controlClient startWithExperimentalMode:NO
                completion:^(NSDictionary<NSString *, id> *reply) {
                    if ([reply[@"ok"] boolValue]) stage();
                    else {
                        if (scoped) [url stopAccessingSecurityScopedResource];
                        [self setNotice:reply[@"message"] ?: @"macOS 启动失败"
                                 success:NO];
                    }
                }];
        }
    }];
}

- (void)launchApplicationIdentifier:(NSString *)identifier {
    // hostd owns application-launch serialization.  For Maps it sends one
    // Darwin request back to this already-foreground Host, whose observer
    // performs the responsible-process spawn.  Spawning here as well created
    // two Maps generations during the 200 ms hostd round trip and left both
    // competing for one UIKitSystem scene.  Keep one transaction and one
    // process generation for Control Center, Dock and URL launches alike.
    [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
             arguments:@{@MACWS_CONTROL_KEY_APP_ID: identifier ?: @""}];
}

- (void)captureAction {
    [_metalView suspendStream];
    [_metalView configureStreamMode:_streamMode windowID:_windowID];
    [_metalView requestStreamWindowList];
    [self setNotice:@"正在重新连接 DisplayStream；不会启动 VNC 或复制 framebuffer。"
             success:YES];
}

- (void)repairAction {
    [self runOperation:@MACWS_CONTROL_OP_REPAIR arguments:nil];
}

- (void)repairDesktopAction {
    [self runOperation:@MACWS_CONTROL_OP_REPAIR_DESKTOP arguments:nil];
}

- (void)recoverAction {
    [self runOperation:@MACWS_CONTROL_OP_RECOVER arguments:nil];
}

- (void)logsAction {
    if (!_logsView.hidden) {
        _logsView.hidden = YES;
        [self setButton:_logsButton title:@"查看日志" image:@"doc.text.magnifyingglass"];
        return;
    }
    [self setButton:_logsButton title:@"收起日志" image:@"doc.text.magnifyingglass"];
    [_controlClient fetchLogs:^(NSDictionary<NSString *,id> *reply) {
        NSString *text = [NSString stringWithFormat:
            @"=== macwshostd ===\n%@\n\n=== WindowServer ===\n%@\n\n=== input ===\n%@\n\n=== postinst ===\n%@",
            reply[@"hostd_log"] ?: @"", reply[@"windowserver_log"] ?: @"",
            reply[@"input_log"] ?: @"", reply[@"postinst_log"] ?: @""];
        self->_logsView.text = text;
        self->_logsView.hidden = NO;
        if (text.length) [self->_logsView scrollRangeToVisible:NSMakeRange(text.length - 1, 1)];
    }];
}

- (NSURL *)writeHostUISnapshot {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    // Automation classifies logical UI state, not individual Retina pixels.
    // Encoding the 1389x970-point workspace at the physical 2x scale produced
    // 2778x1940 PNGs of roughly 7.5 MB every observation cycle.  Keep the
    // content and coordinate space exact while avoiding that diagnostic-only
    // encode/transfer load. writeHostScreenSnapshot remains the full-density
    // system-composite capture when pixel-level evidence is required.
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:self.view.bounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES];
    }];
    NSData *png = UIImagePNGRepresentation(image);
    NSString *path = @"/var/mobile/Library/Logs/MacWSHost-ui.png";
    BOOL written = [png writeToFile:path options:NSDataWritingAtomic error:nil];
    MacWSLog(@"ui-snapshot written=%@ bytes=%lu scale=%.1f path=%@",
             written ? @"YES" : @"NO", (unsigned long)png.length,
             format.scale, path);
    return written ? [NSURL fileURLWithPath:path] : nil;
}

- (NSURL *)writeHostAutomationSnapshot {
    // The state machine needs scene identity and readable labels, not a
    // lossless Retina artifact. The hierarchy must still be rendered at its
    // exact logical bounds: runtime comparison showed that drawing MTKView
    // into a smaller target loses its CAMetalLayer pixels and preserves only
    // the UIKit FPS overlay. JPEG removes the expensive lossless encode and
    // transfer without changing that capture semantic.
    CGSize size = self.view.bounds.size;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES];
    }];
    NSData *jpeg = UIImageJPEGRepresentation(image, 0.58);
    NSString *path = @"/var/mobile/Library/Logs/MacWSHost-automation.jpg";
    BOOL written = [jpeg writeToFile:path options:NSDataWritingAtomic error:nil];
    MacWSLog(@"automation-snapshot written=%@ bytes=%lu size=%.0fx%.0f path=%@",
             written ? @"YES" : @"NO", (unsigned long)jpeg.length,
             size.width, size.height, path);
    return written ? [NSURL fileURLWithPath:path] : nil;
}

- (NSURL *)writeHostScreenSnapshot {
    // RE-confirmed in the target iOS 16.3.1 UIKitCore image: exported
    // _UICreateScreenUIImage at 0x189df62ac returns the foreground screen
    // composite. Keep this explicit diagnostic off every display/input hot
    // path; unlike drawViewHierarchy it can witness system chrome.
    UIImage *(*createScreenImage)(void) =
        (UIImage *(*)(void))dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    UIImage *image = createScreenImage ? createScreenImage() : nil;
    NSData *png = image ? UIImagePNGRepresentation(image) : nil;
    NSString *path = @"/var/mobile/Library/Logs/MacWSHost-screen.png";
    NSError *error = nil;
    BOOL written = png.length &&
        [png writeToFile:path options:NSDataWritingAtomic error:&error];
    MacWSLog(@"screen-snapshot written=%@ bytes=%lu symbol=%@ path=%@ error=%@",
             written ? @"YES" : @"NO", (unsigned long)png.length,
             createScreenImage ? @"YES" : @"NO", path, error ?: @"");
    return written ? [NSURL fileURLWithPath:path] : nil;
}

- (void)exportDiagnostics {
    NSURL *snapshot = [self writeHostUISnapshot];
    [_controlClient fetchLogs:^(NSDictionary<NSString *,id> *reply) {
        NSString *text = [NSString stringWithFormat:
            @"macPad diagnostics\n%@\n\n=== macwshostd ===\n%@\n\n=== WindowServer ===\n%@\n\n=== input ===\n%@\n\n=== postinst ===\n%@",
            self->_latestStatus ?: @{}, reply[@"hostd_log"] ?: @"",
            reply[@"windowserver_log"] ?: @"", reply[@"input_log"] ?: @"",
            reply[@"postinst_log"] ?: @""];
        NSString *path = @"/var/mobile/Library/Logs/MacWSHost-diagnostics.txt";
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURL fileURLWithPath:path]];
        if (snapshot) [items addObject:snapshot];
        UIActivityViewController *activity = [[UIActivityViewController alloc]
            initWithActivityItems:items applicationActivities:nil];
        activity.popoverPresentationController.sourceView = self->_exportButton;
        activity.popoverPresentationController.sourceRect = self->_exportButton.bounds;
        [self presentViewController:activity animated:YES completion:nil];
    }];
}

- (void)performURLAction:(NSString *)action {
    MacWSLog(@"url-control action=%@", action);
    if ([action isEqualToString:@"status"] || action.length == 0) {
        [self refreshStatus];
    } else if ([action isEqualToString:@"start"] ||
               [action isEqualToString:@"start-experimental"]) {
        if (![_latestStatus[@"windowserver_running"] boolValue]) {
            [self primaryAction];
        } else {
            [self setNotice:@"macOS 工作区已经在运行" success:YES];
        }
    } else if ([action isEqualToString:@"stop"]) {
        [self runOperation:@MACWS_CONTROL_OP_STOP arguments:nil];
    } else if ([action isEqualToString:@"glassdemo"]) {
        [self runOperation:@MACWS_CONTROL_OP_LAUNCH_APP
                 arguments:@{@MACWS_CONTROL_KEY_APP_ID: @"glassdemo"}];
    } else if ([action isEqualToString:@"terminal"] ||
               [action isEqualToString:@"vscode"] ||
               [action isEqualToString:@"activity-monitor"] ||
               [action isEqualToString:@"finder"] ||
               [action isEqualToString:@"system-settings"] ||
               [action isEqualToString:@"maps"] ||
               [action isEqualToString:@"weather"] ||
               [action isEqualToString:@"sublime"] ||
               [action isEqualToString:@"steam"] ||
               [action isEqualToString:@"amadine"] ||
               [action isEqualToString:@"word"] ||
               [action isEqualToString:@"excel"] ||
               [action isEqualToString:@"powerpoint"] ||
               [action isEqualToString:@"asphalt"]) {
        [self launchApplicationIdentifier:action];
    } else if ([action isEqualToString:@"recover"]) {
        [self recoverAction];
    } else if ([action isEqualToString:@"repair"]) {
        [self repairAction];
    } else if ([action isEqualToString:@"repair-desktop"]) {
        [self repairDesktopAction];
    } else if ([action isEqualToString:@"capture"]) {
        [self captureAction];
    } else if ([action isEqualToString:@"retina-standard"] ||
               [action isEqualToString:@"retina-larger"]) {
        _densityControl.selectedSegmentIndex =
            [action isEqualToString:@"retina-larger"] ? 1 : 0;
        [self densityChanged:_densityControl];
        [self setNotice:[action isEqualToString:@"retina-larger"]
            ? MacWSLocalized(@"已切换 Retina 放大", @"Retina Larger enabled")
            : MacWSLocalized(@"已切换 Retina 标准", @"Retina Standard enabled")
                 success:YES];
    } else if ([action isEqualToString:@"test-open-file"]) {
        [self performSemanticShortcutForDiagnostics:@"⌘O"];
    } else if ([action isEqualToString:@"test-quit"]) {
        // Exercise the same serialized NSMenuItem action used by macPad's
        // mirrored menu bar. This is an end-to-end quit witness, unlike a
        // signal or a direct process kill, and proves that the application
        // accepted its normal termination action without restarting Dock.
        [self performSemanticShortcutForDiagnostics:@"⌘Q"];
    } else if ([action isEqualToString:@"test-pasteboard-write"]) {
        NSString *directory = @"/var/mnt/rootfs/Users/Shared/MacWS Imports/Probe";
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil error:nil];
        NSString *path = [directory stringByAppendingPathComponent:
            @"ipad-rich-clipboard.txt"];
        [@"MacWS iPadOS file representation\n" writeToFile:path atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
        UIPasteboard.generalPasteboard.items = @[
            @{
                @"public.utf8-plain-text": @"MacWS iPadOS rich clipboard fixture",
                @"public.html": [@"<i>MacWS iPadOS rich clipboard fixture</i>"
                    dataUsingEncoding:NSUTF8StringEncoding],
                @"public.rtf": [@"{\\rtf1\\ansi MacWS iPadOS rich clipboard fixture}"
                    dataUsingEncoding:NSUTF8StringEncoding],
                @"com.macwsguide.ios-probe": [@"opaque-ios-representation"
                    dataUsingEncoding:NSUTF8StringEncoding],
            },
            @{ @"public.file-url": [NSURL fileURLWithPath:path] }
        ];
        MacWSLog(@"interop-pasteboard-probe wrote-ios items=%lu change=%ld",
            (unsigned long)UIPasteboard.generalPasteboard.items.count,
            (long)UIPasteboard.generalPasteboard.changeCount);
    } else if ([action isEqualToString:@"test-pasteboard-abstract-text"]) {
        // Exercise the representation used by iOS producers that publish the
        // abstract public.text supertype rather than AppKit's concrete
        // public.utf8-plain-text spelling.
        NSString *text = [NSString stringWithFormat:
            @"MacWS abstract iPadOS text %@", NSUUID.UUID.UUIDString];
        UIPasteboard.generalPasteboard.items = @[@{
            UTTypeText.identifier: text
        }];
        MacWSLog(@"interop-pasteboard-abstract-probe text=%@ change=%ld",
            text, (long)UIPasteboard.generalPasteboard.changeCount);
    } else if ([action isEqualToString:@"test-pasteboard-read"]) {
        NSMutableArray *types = [NSMutableArray array];
        NSUInteger representationCount = 0;
        for (NSDictionary<NSString *, id> *item in
                UIPasteboard.generalPasteboard.items) {
            representationCount += item.count;
            [types addObject:[[item.allKeys sortedArrayUsingSelector:
                @selector(compare:)] componentsJoinedByString:@","]];
        }
        MacWSLog(@"interop-pasteboard-probe read-ios items=%lu reps=%lu types=%@ change=%ld",
            (unsigned long)UIPasteboard.generalPasteboard.items.count,
            (unsigned long)representationCount,
            [types componentsJoinedByString:@" | "],
            (long)UIPasteboard.generalPasteboard.changeCount);
    } else if ([action isEqualToString:@"test-drag-snapshot"]) {
        uint64_t change = [_interopClient macOSDragPasteboardChangeCount];
        NSArray<NSURL *> *stagedURLs = nil;
        NSArray<NSItemProvider *> *providers = [_interopClient
            macOSDragItemProvidersAfterChangeCount:(change ? change - 1 : 0)
                                  waitMilliseconds:0
                                        stagedURLs:&stagedURLs];
        NSMutableArray *types = [NSMutableArray array];
        for (NSItemProvider *provider in providers)
            [types addObject:[provider.registeredTypeIdentifiers
                componentsJoinedByString:@","]];
        MacWSLog(@"interop-drag-probe change=%llu providers=%lu urls=%lu types=%@",
            (unsigned long long)change, (unsigned long)providers.count,
            (unsigned long)stagedURLs.count,
            [types componentsJoinedByString:@" | "]);
    } else if ([action isEqualToString:@"test-drop-file"]) {
        NSString *directory = @"/var/mobile/Library/Caches/MacWSDropProbe";
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil error:nil];
        NSString *name = [NSString stringWithFormat:@"macws-drop-probe-%@.txt",
            NSUUID.UUID.UUIDString];
        NSURL *url = [NSURL fileURLWithPath:
            [directory stringByAppendingPathComponent:name]];
        [@"MacWS iPadOS-to-macOS drop witness\n" writeToURL:url atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
        NSItemProvider *provider = [[NSItemProvider alloc]
            initWithContentsOfURL:url];
        CGPoint point = CGPointMake(CGRectGetMidX(_metalView.bounds),
                                    CGRectGetMidY(_metalView.bounds));
        [_interopClient publishItemProviders:provider ? @[provider] : @[]
            completion:^(BOOL applied, NSError *error) {
                if (applied)
                    [self->_metalView performInteropPasteAtViewPoint:point];
                MacWSLog(@"interop-drop-probe file=%@ window=%u pid=%d applied=%@ error=%@",
                    name, self->_windowID, self->_metalView.targetPID,
                    applied ? @"YES" : @"NO", error ?: @"nil");
            }];
    } else if ([action isEqualToString:@"test-drop-data"]) {
        NSString *name = [NSString stringWithFormat:
            @"macws-data-drop-probe-%@.txt", NSUUID.UUID.UUIDString];
        NSData *payload = [@"MacWS data-only iPadOS-to-macOS drop witness\n"
            dataUsingEncoding:NSUTF8StringEncoding];
        NSItemProvider *provider = [NSItemProvider new];
        provider.suggestedName = name;
        [provider registerDataRepresentationForTypeIdentifier:
            UTTypeUTF8PlainText.identifier
            visibility:NSItemProviderRepresentationVisibilityAll
            loadHandler:^NSProgress *(void (^handler)(NSData *, NSError *)) {
                handler(payload, nil);
                return nil;
            }];
        CGPoint point = CGPointMake(CGRectGetMidX(_metalView.bounds),
                                    CGRectGetMidY(_metalView.bounds));
        [_interopClient publishItemProviders:@[provider]
            completion:^(BOOL applied, NSError *error) {
                if (applied)
                    [self->_metalView performInteropPasteAtViewPoint:point];
                MacWSLog(@"interop-drop-data-probe file=%@ window=%u pid=%d applied=%@ error=%@",
                    name, self->_windowID, self->_metalView.targetPID,
                    applied ? @"YES" : @"NO", error ?: @"nil");
            }];
    } else if ([action isEqualToString:@"fullscreen"]) {
        [self openFullscreenWorkspace];
    } else if ([action isEqualToString:@"enter-workspace"]) {
        [self setFullscreenWorkspaceEnabled:YES];
    } else if ([action isEqualToString:@"exit-workspace"]) {
        [self setFullscreenWorkspaceEnabled:NO];
    } else if ([action isEqualToString:@"close-window"]) {
        [self closeCurrentWindow];
    } else if ([action isEqualToString:@"test-software-toolbar-hit"]) {
        if (!_keyboardProxy.isFirstResponder) [self keyboardAction];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [self.view layoutIfNeeded];
            UIButton *control = (UIButton *)[self->_softwareKeyBar
                viewWithTag:(1u << 18)];
            CGPoint point = control
                ? [control convertPoint:CGPointMake(
                    CGRectGetMidX(control.bounds),
                    CGRectGetMidY(control.bounds)) toView:self.view]
                : CGPointZero;
            UIView *hit = control
                ? [self.view hitTest:point withEvent:nil] : nil;
            BOOL controlOwnsHit = hit == control ||
                (hit && [hit isDescendantOfView:control]);
            MacWSLog(@"software-toolbar-hit control=%@ hidden=%@ enabled=%@ "
                "point=(%.1f,%.1f) hit=%@ exact=%@ bar-front=%@",
                control, control.hidden ? @"YES" : @"NO",
                control.enabled ? @"YES" : @"NO", point.x, point.y, hit,
                controlOwnsHit ? @"YES" : @"NO",
                self.view.subviews.lastObject == self->_softwareKeyBar
                    ? @"YES" : @"NO");
        });
    } else if ([action isEqualToString:@"screenshot-ui"]) {
        [self writeHostUISnapshot];
    } else if ([action isEqualToString:@"screenshot-automation"]) {
        [self writeHostAutomationSnapshot];
    } else if ([action isEqualToString:@"screenshot-screen"]) {
        [self writeHostScreenSnapshot];
    } else if ([action isEqualToString:@"screenshot-rendered"]) {
        [_metalView requestRenderedDrawableSnapshotToPath:
            @"/var/mobile/Library/Logs/MacWSHost-rendered.png"];
    } else if ([action isEqualToString:@"screenshot-base"]) {
        [_metalView writeBaseSurfaceSnapshotToPath:
            @"/var/mobile/Library/Logs/MacWSHost-base.png"];
    } else if ([action isEqualToString:@"screenshot-layers"]) {
        [_metalView writeWorkspaceSurfaceSnapshotsToDirectory:
            @"/var/mobile/Library/Logs/MacWSHost-layers"];
    } else if ([action isEqualToString:@"performance-snapshot"]) {
        [_metalView logPerformanceSnapshotWithReason:@"url-control"];
        [self exportPerformanceMeasurement];
    } else if ([action isEqualToString:@"performance-reset"]) {
        [self resetPerformanceMeasurementForTargetPID:0];
    } else if ([action isEqualToString:@"performance-gesture-suite"]) {
        [self runPerformanceGestureSuite];
    } else if ([action hasPrefix:@"performance-gesture-"]) {
        NSString *scenario = [action substringFromIndex:
            @"performance-gesture-".length];
        [_metalView runPerformanceGestureScenario:scenario
            completion:^(BOOL success, NSString *message) {
                MacWSLog(@"performance-url-gesture scenario=%@ success=%@ message=%@",
                         scenario, success ? @"YES" : @"NO", message);
            }];
    } else if ([action isEqualToString:@"performance-hud-off"] ||
               [action isEqualToString:@"performance-hud-compact"] ||
               [action isEqualToString:@"performance-hud-full"]) {
        _performanceHUDControl.selectedSegmentIndex =
            [action isEqualToString:@"performance-hud-full"] ? 2 :
            ([action isEqualToString:@"performance-hud-compact"] ? 1 : 0);
        [self performanceHUDChanged:_performanceHUDControl];
    } else if ([action isEqualToString:@"system-performance-hud-on"] ||
               [action isEqualToString:@"system-performance-hud-off"]) {
        _systemPerformanceHUDSwitch.on =
            [action isEqualToString:@"system-performance-hud-on"];
        [self systemPerformanceHUDChanged:_systemPerformanceHUDSwitch];
    } else if ([action isEqualToString:@"input-direct"] ||
               [action isEqualToString:@"input-trackpad"] ||
               [action isEqualToString:@"input-game"]) {
        // This is the same user-visible mode transaction as tapping the
        // segmented control.  In particular, input-game does not assert that
        // capture succeeded: inputModeChanged: requests pointer lock and the
        // relative route remains fail-closed until UIWindowScene reports a
        // real locked state and GCMouse publishes a raw-motion endpoint.
        _inputModeControl.selectedSegmentIndex =
            [action isEqualToString:@"input-game"] ? 2 :
            ([action isEqualToString:@"input-trackpad"] ? 1 : 0);
        [self inputModeChanged:_inputModeControl];
    } else if ([action isEqualToString:@"hide-controls"]) {
        [self hideControls];
    } else if ([action isEqualToString:@"show-controls"]) {
        [self showControls];
    }
}

- (void)resetPerformanceMeasurementForTargetPID:(int32_t)targetPID {
    int32_t previousPID = _metalView.targetPID;
    if (targetPID > 1) {
        // A benchmark has already proved the exact process and its AppKit
        // input endpoint before requesting a measurement generation.  Bind
        // the Host monitor to that explicit identity instead of whichever
        // ordinary desktop window happened to be foremost when the URL was
        // delivered.  Runtime-confirmed on 2026-08-29: an otherwise healthy
        // Stray run requested pid=68082 while stale VSCode pid=54057 was the
        // passive catalog target, invalidating the whole scored interval.
        if (!MacWSAppInputEndpointReady(targetPID)) {
            MacWSLog(@"performance-profile-target-rejected requested=%d "
                     "previous=%d reason=input-endpoint-missing",
                     targetPID, previousPID);
            return;
        }
        _metalView.targetPID = targetPID;
    }
    [_metalView.performanceMonitor resetWithReason:
        targetPID > 1 ? @"url-control-explicit-pid" : @"url-control"];
    // Give the external regression runner a fresh focus witness for this
    // exact reset.  Reading the last historical catalog message can bind a
    // new run to an application that was frontmost minutes earlier.
    MacWSLog(@"performance-profile-target pid=%d window=%u mode=%lu "
             "requested=%d previous=%d",
             _metalView.targetPID, _metalView.targetWindowID,
             (unsigned long)_streamMode, targetPID, previousPID);
}

- (void)metalView:(MacWSMetalView *)view statusChanged:(NSString *)status {
    _statusLabel.text = [@"画面：" stringByAppendingString:status];
    if (view.hasDirectSurfaceFrame && !view.isMacWSInputEnabled) {
        MacWSLog(@"display-stream first-frame revalidate-input mode=%lu target=%d status=%@",
                 (unsigned long)_streamMode, view.targetPID, status);
        [self refreshStatus];
    }
}

- (void)openInitialFinderBrowserWindowIfNeeded:
    (NSArray<MacWSStreamWindow *> *)windows {
    int32_t ownerPID = _pendingFinderWindowPID;
    if (ownerPID <= 1 || _finderMenuRequestInFlight) return;
    MacWSStreamWindow *seed = nil;
    for (MacWSStreamWindow *window in windows) {
        if (window.descriptor.ownerPID == ownerPID) {
            seed = window;
            break;
        }
    }
    if (!seed) return;
    if (_pendingFinderMenuAttempts >= 8) {
        _pendingFinderWindowPID = 0;
        [self setNotice:@"Finder 已启动；菜单在限定时间内尚未就绪，可稍后从窗口菜单选择“文件 → 新建 Finder 窗口”。"
                 success:NO];
        return;
    }
    _pendingFinderMenuAttempts++;
    _finderMenuRequestInFlight = YES;
    MacWSLog(@"finder-browser menu-attempt=%lu pid=%d seed-window=%u",
             (unsigned long)_pendingFinderMenuAttempts, ownerPID,
             seed.descriptor.windowID);
    [_menuClient requestSnapshotForPID:ownerPID
        windowID:seed.descriptor.windowID
        completion:^(MacWSMenuSnapshot *snapshot, NSError *error) {
            self->_finderMenuRequestInFlight = NO;
            if (self->_pendingFinderWindowPID != ownerPID) return;
            if (!snapshot || error) {
                MacWSLog(@"finder-browser menu-not-ready attempt=%lu error=%@",
                         (unsigned long)self->_pendingFinderMenuAttempts,
                         error.localizedDescription ?: @"无菜单快照");
                [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                return;
            }
            MacWSMenuItem *fileMenu = nil;
            for (MacWSMenuItem *root in [snapshot childrenOfItemID:0]) {
                if (root.siblingIndex == 1 ||
                    [root.title localizedCaseInsensitiveContainsString:@"file"] ||
                    [root.title containsString:@"文件"]) {
                    fileMenu = root;
                    break;
                }
            }
            if (!fileMenu) {
                MacWSLog(@"finder-browser file-menu-not-ready attempt=%lu",
                         (unsigned long)self->_pendingFinderMenuAttempts);
                [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                return;
            }
            MacWSMenuItem *newWindow = nil;
            for (MacWSMenuItem *item in
                    [snapshot childrenOfItemID:fileMenu.itemID]) {
                BOOL named = [item.title
                    localizedCaseInsensitiveContainsString:@"new finder window"] ||
                    [item.title containsString:@"新建 Finder 窗口"];
                BOOL commandN = [item.shortcut hasSuffix:@"⌘N"] ||
                    [item.shortcut isEqualToString:@"⌘N"];
                if ((named || commandN) &&
                    (item.flags & MacWSMenuNodeEnabled) &&
                    !(item.flags & MacWSMenuNodeHasSubmenu)) {
                    newWindow = item;
                    break;
                }
            }
            if (!newWindow) {
                MacWSLog(@"finder-browser new-window-not-ready attempt=%lu",
                         (unsigned long)self->_pendingFinderMenuAttempts);
                [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                return;
            }
            [self->_menuClient performItem:newWindow inSnapshot:snapshot
                completion:^(MacWSMenuStatus status, NSError *actionError) {
                    if (status == MacWSMenuStatusOK) {
                        self->_pendingFinderWindowPID = 0;
                        self->_pendingApplicationWindowPID = ownerPID;
                        self->_pendingApplicationIdentifier = @"finder";
                        self->_pendingApplicationWindowAttempts = 0;
                        self->_pendingApplicationWindowRetryScheduled = NO;
                        [self setNotice:@"Finder 浏览窗口已创建，可从“打开 macOS 窗口”进入。"
                                 success:YES];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                      500 * NSEC_PER_MSEC),
                                       dispatch_get_main_queue(), ^{
                            [self->_metalView requestStreamWindowList];
                        });
                    } else {
                        MacWSLog(@"finder-browser action-not-ready attempt=%lu status=%u error=%@",
                                 (unsigned long)self->_pendingFinderMenuAttempts,
                                 (unsigned)status,
                                 actionError.localizedDescription ?: @"无错误描述");
                        [self scheduleFinderBrowserMenuRetryForPID:ownerPID];
                    }
                }];
        }];
}

- (void)scheduleFinderBrowserMenuRetryForPID:(int32_t)ownerPID {
    if (_pendingFinderWindowPID != ownerPID || ownerPID <= 1) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (self->_pendingFinderWindowPID != ownerPID) return;
        [self openInitialFinderBrowserWindowIfNeeded:self->_streamWindows ?: @[]];
    });
}

- (void)schedulePendingApplicationWindowRetry {
    if (_pendingApplicationWindowPID <= 1 ||
        _pendingApplicationWindowRetryScheduled ||
        _pendingApplicationWindowAttempts >= 20) return;
    _pendingApplicationWindowRetryScheduled = YES;
    _pendingApplicationWindowAttempts++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        self->_pendingApplicationWindowRetryScheduled = NO;
        if (self->_pendingApplicationWindowPID <= 1) return;
        [self->_metalView requestStreamWindowList];
        [self schedulePendingApplicationWindowRetry];
    });
}

- (void)openPendingApplicationWindowFromCatalog:
    (NSArray<MacWSStreamWindow *> *)windows {
    int32_t ownerPID = _pendingApplicationWindowPID;
    if (ownerPID <= 1) return;
    MacWSStreamWindow *target = nil;
    NSUInteger targetScore = 0;
    for (MacWSStreamWindow *window in windows) {
        if (window.descriptor.ownerPID != ownerPID) continue;
        MacWSStreamWindowFlags flags = window.descriptor.flags;
        // Sheets and app-modal panels are transported as overlays of their
        // presenting logical window. They must never own an iPadOS Scene.
        if (flags & MacWSStreamWindowTransient) continue;
        NSUInteger score = ((flags & MacWSStreamWindowFocused) ? 8 : 0) |
            ((flags & MacWSStreamWindowOnScreen) ? 4 : 0) |
            ((flags & MacWSStreamWindowVisible) ? 2 : 0) |
            ((flags & MacWSStreamWindowTransient) ? 0 : 1);
        CGFloat area = window.descriptor.logicalWidth *
                       window.descriptor.logicalHeight;
        CGFloat targetArea = target ? target.descriptor.logicalWidth *
                                      target.descriptor.logicalHeight : 0.0;
        if (!target || score > targetScore ||
            (score == targetScore && area > targetArea)) {
            target = window;
            targetScore = score;
        }
    }
    if (!target) {
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    // Catalyst and ExtensionKit can publish a short-lived black bootstrap
    // NSWindow before their real scene/content window.  Wait for the best
    // candidate identity to remain stable for 500 ms; if focus or the window
    // number changes, restart the interval.  This is generic catalog
    // stabilization and does not special-case Maps or Settings titles.
    CFTimeInterval now = CACurrentMediaTime();
    if (_pendingApplicationCandidateWindowID != target.descriptor.windowID) {
        _pendingApplicationCandidateWindowID = target.descriptor.windowID;
        _pendingApplicationCandidateSince = now;
        MacWSLog(@"launch-auto-window candidate app=%@ pid=%d window=%u score=%lu state=new",
                 _pendingApplicationIdentifier ?: @"macOS app", ownerPID,
                 target.descriptor.windowID, (unsigned long)targetScore);
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    if (now - _pendingApplicationCandidateSince < 0.5) {
        [self schedulePendingApplicationWindowRetry];
        return;
    }
    NSString *identifier = _pendingApplicationIdentifier ?: @"macOS app";
    _pendingApplicationWindowPID = 0;
    _pendingApplicationIdentifier = nil;
    _pendingApplicationWindowAttempts = 0;
    _pendingApplicationWindowRetryScheduled = NO;
    _pendingApplicationCandidateWindowID = 0;
    _pendingApplicationCandidateSince = 0;
    NSString *title = target.title.length ? target.title : identifier;
    MacWSLog(@"launch-auto-window app=%@ pid=%d window=%u group=%u",
             identifier, ownerPID, target.descriptor.windowID,
             target.descriptor.logicalGroupID);
    NSString *targetIdentity = MacWSWindowIdentity(
        target.descriptor.ownerPID, target.descriptor.windowID,
        target.descriptor.logicalGroupID);
    if (!MacWSObservedWindowIdentities)
        MacWSObservedWindowIdentities = [NSMutableSet set];
    if (targetIdentity) [MacWSObservedWindowIdentities addObject:targetIdentity];
    if (_streamMode == MacWSStreamModeFullscreen &&
        _bootstrapWindowReplacementPending) {
        // This is the first-launch placeholder rather than an intentional
        // fullscreen desktop entered from an AppKit window.  Replace the
        // placeholder in place, matching the startup contract documented in
        // applyStatus:, instead of retaining a black workspace Scene.
        _bootstrapWindowReplacementPending = NO;
        NSString *reason = [identifier isEqualToString:@"terminal"]
            ? @"默认终端已经就绪。"
            : [NSString stringWithFormat:@"%@ 已经就绪。", identifier];
        [self openWindowInCurrentScene:target reason:reason];
        MacWSLog(@"launch-auto-window replaced-bootstrap app=%@ pid=%d window=%u group=%u",
                 identifier, ownerPID, target.descriptor.windowID,
                 target.descriptor.logicalGroupID);
        return;
    }
    if (_streamMode == MacWSStreamModeFullscreen) {
        // The fullscreen Scene already presents WindowServer's complete
        // desktop. Turning it into a per-window stream here both crops that
        // desktop and asks UIKit to create/restore a windowed Scene. Keep the
        // workspace identity intact and activate the exact catalog window in
        // place.  Merely waiting for the focused flag left newly launched
        // Catalyst/AppKit applications behind the previous frontmost app, so
        // both pixels and AppInput continued to target the old process.
        // ActivateTarget uses the window ID + owner PID already published by
        // DisplayStream; it neither creates a UIKit Scene nor starts another
        // application generation.
        [self activateMacWindow:target];
        [self setNotice:[NSString stringWithFormat:
            @"%@ 已在当前全屏工作区中打开。", identifier] success:YES];
        MacWSLog(@"launch-auto-window activated-fullscreen app=%@ pid=%d window=%u group=%u",
                 identifier, ownerPID, target.descriptor.windowID,
                 target.descriptor.logicalGroupID);
        return;
    }
    if (_windowID == 0) {
        NSString *reason = [identifier isEqualToString:@"terminal"]
            ? @"默认终端已经就绪。"
            : [NSString stringWithFormat:@"%@ 已经就绪。", identifier];
        [self openWindowInCurrentScene:target reason:reason];
        return;
    }
    MacWSRequestNewScene(self.view.window.windowScene,
        target.descriptor.windowID, target.descriptor.ownerPID,
        target.descriptor.logicalGroupID,
        CGSizeMake(target.descriptor.logicalWidth,
                   target.descriptor.logicalHeight),
        CGSizeMake(target.descriptor.minimumLogicalWidth,
                   target.descriptor.minimumLogicalHeight),
        target.maximumLogicalSize,
        (target.descriptor.flags & MacWSStreamWindowResizable) != 0,
        (target.descriptor.flags & MacWSStreamWindowFixedWidth) != 0,
        (target.descriptor.flags & MacWSStreamWindowFixedHeight) != 0,
        title, NO, ^(NSError *error) {
            if ([error.domain isEqualToString:@"FBSWorkspaceErrorDomain"] &&
                error.code == 2) {
                [self openWindowInCurrentScene:target
                    reason:@"iPadOS 暂未接受新窗口，已在当前窗口中打开。"];
            } else {
                [self setNotice:error.localizedDescription success:NO];
            }
        });
}

- (BOOL)isWindowDiscoveryCoordinator {
    UIScene *candidate = self.view.window.windowScene;
    if (!candidate || candidate.activationState !=
            UISceneActivationStateForegroundActive) return NO;
    NSString *candidateID = candidate.session.persistentIdentifier;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene == candidate || scene.activationState !=
                UISceneActivationStateForegroundActive) continue;
        NSString *identifier = scene.session.persistentIdentifier;
        if ([identifier compare:candidateID] == NSOrderedAscending) return NO;
    }
    return YES;
}

- (BOOL)hasForegroundFullscreenWorkspace {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        UIViewController *root = ((UIWindowScene *)scene).windows.firstObject
            .rootViewController;
        if ([root isKindOfClass:MacWSViewController.class] &&
            ((MacWSViewController *)root)->_streamMode ==
                MacWSStreamModeFullscreen)
            return YES;
    }
    return NO;
}

- (void)openNewMacWindowsFromCatalog:
    (NSArray<MacWSStreamWindow *> *)windows {
    if (!MacWSPendingWindowSceneIdentities)
        MacWSPendingWindowSceneIdentities = [NSMutableSet set];
    NSMutableDictionary<NSString *, MacWSStreamWindow *> *current =
        [NSMutableDictionary dictionary];
    for (MacWSStreamWindow *window in windows) {
        MacWSStreamWindowDescriptor descriptor = window.descriptor;
        if ((descriptor.flags & MacWSStreamWindowVisible) == 0) continue;
        NSString *identity = MacWSWindowIdentity(descriptor.ownerPID,
            descriptor.windowID, descriptor.logicalGroupID);
        if (identity) current[identity] = window;
    }
    NSMutableSet<NSString *> *closingGrace = [NSMutableSet set];
    CFTimeInterval now = CACurrentMediaTime();
    for (NSString *identity in [MacWSClosingWindowIdentities.allKeys copy]) {
        if (!current[identity]) {
            [MacWSClosingWindowIdentities removeObjectForKey:identity];
            continue;
        }
        CFTimeInterval issued =
            [MacWSClosingWindowIdentities[identity] doubleValue];
        if (issued > 0.0 && now - issued < 0.75) {
            [closingGrace addObject:identity];
        } else {
            // AppKit kept the window visible after the close transaction.
            // That is an application-owned veto or confirmation sheet, not a
            // stale count. Permit one Scene to present the real remaining UI
            // after the catalog has had time to commit an ordinary close.
            [MacWSClosingWindowIdentities removeObjectForKey:identity];
            MacWSLog(@"scene-close retained identity=%@ reason=appkit-window-still-visible-after-750ms",
                     identity);
        }
    }
    NSMutableSet<NSString *> *observableIdentities =
        [NSMutableSet setWithArray:current.allKeys];
    [observableIdentities minusSet:closingGrace];
    NSMutableSet<NSNumber *> *frontmostOwnerPIDs = [NSMutableSet set];
    for (NSString *identity in current) {
        MacWSStreamWindow *window = current[identity];
        if ((window.descriptor.flags &
                MacWSStreamWindowFrontmostApplication) != 0)
            [frontmostOwnerPIDs addObject:@(window.descriptor.ownerPID)];
    }
    NSMutableSet<NSNumber *> *frontmostOwnersWithKeyWindow =
        [NSMutableSet set];
    NSMutableSet<NSString *> *frontmostIdentities = [NSMutableSet set];
    for (NSString *identity in current) {
        MacWSStreamWindow *window = current[identity];
        MacWSStreamWindowFlags flags = window.descriptor.flags;
        if (![closingGrace containsObject:identity] &&
            [frontmostOwnerPIDs containsObject:
                @(window.descriptor.ownerPID)] &&
            (flags & MacWSStreamWindowFocused) != 0 &&
            (flags & MacWSStreamWindowOnScreen) != 0 &&
            (flags & MacWSStreamWindowTransient) == 0) {
            [frontmostIdentities addObject:identity];
            [frontmostOwnersWithKeyWindow addObject:
                @(window.descriptor.ownerPID)];
        }
    }
    // CGWindow's compositor order and AppKit's keyWindow can settle in
    // separate transactions. Runtime-confirmed after reopening IMG_0120 in
    // Preview PID 84629: CGWindow listed PDF 215 first while the process
    // sidecar identified image 214 as Focused. The process is globally
    // frontmost in either case; its real key window is the document the user
    // requested. Fall back to the CG identity only if that process publishes
    // no eligible AppKit key window.
    for (NSString *identity in current) {
        MacWSStreamWindow *window = current[identity];
        MacWSStreamWindowFlags flags = window.descriptor.flags;
        NSNumber *owner = @(window.descriptor.ownerPID);
        if (![closingGrace containsObject:identity] &&
            (flags & MacWSStreamWindowFrontmostApplication) != 0 &&
            ![frontmostOwnersWithKeyWindow containsObject:owner] &&
            (flags & MacWSStreamWindowOnScreen) != 0 &&
            (flags & MacWSStreamWindowTransient) == 0)
            [frontmostIdentities addObject:identity];
    }
    if ([self hasForegroundFullscreenWorkspace]) {
        // New AppKit windows are already visible in the desktop stream. They
        // must not become additional iPadOS Scenes until every foreground
        // workspace has returned to per-window mode. This must be a global
        // Scene invariant: a second foreground windowed controller also
        // receives the same catalog and used to create the unwanted Stage
        // Manager window even though the initiating controller was fullscreen.
        if (!MacWSObservedWindowIdentities)
            MacWSObservedWindowIdentities = [NSMutableSet set];
        // Dock and other macOS-native launch owners call hostd directly, so
        // they do not receive the Control Center's pending-PID callback. The
        // DisplayStream catalog is the common authoritative boundary for
        // every launch source. Activate the best newly published, ordinary
        // window in the existing desktop while retaining the one fullscreen
        // iPadOS Scene. Pending Control Center launches add their identity
        // before reaching this branch and therefore remain exactly-once.
        MacWSStreamWindow *newTarget = nil;
        NSUInteger newTargetScore = 0;
        for (NSString *identity in current) {
            if ([closingGrace containsObject:identity]) continue;
            if ([MacWSObservedWindowIdentities containsObject:identity])
                continue;
            MacWSStreamWindow *window = current[identity];
            MacWSStreamWindowFlags flags = window.descriptor.flags;
            if (window.descriptor.ownerPID <= 1 ||
                (flags & MacWSStreamWindowTransient) != 0) continue;
            NSUInteger score =
                ((flags & MacWSStreamWindowFocused) ? 4 : 0) |
                ((flags & MacWSStreamWindowVisible) ? 2 : 0) | 1;
            if (!newTarget || score > newTargetScore) {
                newTarget = window;
                newTargetScore = score;
            }
        }
        [MacWSObservedWindowIdentities setSet:observableIdentities];
        if (!MacWSPreviouslyFrontmostWindowIdentities)
            MacWSPreviouslyFrontmostWindowIdentities = [NSMutableSet set];
        [MacWSPreviouslyFrontmostWindowIdentities
            setSet:frontmostIdentities];
        [MacWSPendingWindowSceneIdentities removeAllObjects];
        BOOL changesInputOwner = newTarget &&
            newTarget.descriptor.ownerPID != _metalView.targetPID;
        BOOL isFocusedWindow = newTarget &&
            (newTarget.descriptor.flags & MacWSStreamWindowFocused) != 0;
        if (newTarget && (changesInputOwner || isFocusedWindow)) {
            [self activateMacWindow:newTarget];
            MacWSLog(@"window-auto-scene activated-fullscreen-catalog pid=%d window=%u group=%u score=%lu",
                     newTarget.descriptor.ownerPID,
                     newTarget.descriptor.windowID,
                     newTarget.descriptor.logicalGroupID,
                     (unsigned long)newTargetScore);
        } else if (newTarget) {
            // Runtime-confirmed with Stray pid=37813: its focused FCocoaWindow
            // 410 was followed by non-focused window 417 (score 3), which was
            // retired 571 ms later.  Activating every same-process catalog
            // edge replaced inputd's valid key target with that temporary
            // window, so AppInputBridge later rejected W as
            // target-window-closed.  A non-focused window from the already
            // active owner is observational only; pointer hit-testing still
            // reaches it, while a real focused replacement takes the branch
            // above and updates keyboard ownership.
            MacWSLog(@"window-auto-scene observed-same-owner-nonfocused pid=%d window=%u group=%u score=%lu activation=SKIPPED",
                     newTarget.descriptor.ownerPID,
                     newTarget.descriptor.windowID,
                     newTarget.descriptor.logicalGroupID,
                     (unsigned long)newTargetScore);
        }
        return;
    }
    if (![self isWindowDiscoveryCoordinator]) return;
    if (!MacWSObservedWindowIdentities) {
        MacWSObservedWindowIdentities = [observableIdentities mutableCopy];
        MacWSPreviouslyFrontmostWindowIdentities =
            [frontmostIdentities mutableCopy];
        MacWSPendingWindowSceneIdentities = [NSMutableSet set];
        return;
    }
    if (!MacWSPreviouslyFrontmostWindowIdentities)
        MacWSPreviouslyFrontmostWindowIdentities = [NSMutableSet set];

    NSMutableSet<NSString *> *occupied = [NSMutableSet set];
    NSMutableSet<NSString *> *keySceneIdentities = [NSMutableSet set];
    for (UISceneSession *session in UIApplication.sharedApplication.openSessions) {
        NSUserActivity *activity = MacWSSceneBindings[
            session.persistentIdentifier] ?:
            MacWSPersistedSceneActivity(session.persistentIdentifier) ?:
            session.stateRestorationActivity;
        NSDictionary *info = activity.userInfo;
        int32_t ownerPID = 0;
        uint32_t windowID = 0, groupID = 0;
        NSString *identity = MacWSSceneOwnedWindowFields(
            info, &ownerPID, &windowID, &groupID)
            ? MacWSWindowIdentity(ownerPID, windowID, groupID) : nil;
        if (!identity) continue;
        [occupied addObject:identity];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.session != session ||
                ![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive)
                continue;
            BOOL sceneIsKey = NO;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    sceneIsKey = YES;
                    break;
                }
            }
            if (sceneIsKey) [keySceneIdentities addObject:identity];
            break;
        }
    }

    // Scene ordering is owned by the user's Stage Manager gesture.  A catalog
    // update only describes AppKit ordering; using it to reactivate an already
    // bound iOS Scene creates a two-way focus loop. Runtime-confirmed by
    // MacWSHost.log on 2026-09-08: alternating
    // "scene-foreground follows-frontmost" requests repeatedly brought the
    // previous Scene back after the user selected another Stage Manager
    // window. The forward transaction observes the application-key-window
    // evaluator; per-Scene isKeyWindow and activation are not global focus.

    NSMutableArray<MacWSStreamWindow *> *newWindows = [NSMutableArray array];
    NSMutableSet<NSString *> *reusedFrontmostWindows = [NSMutableSet set];
    NSMutableSet<NSString *> *reusedBoundFrontmostWindows =
        [NSMutableSet set];
    for (NSString *identity in current) {
        if ([closingGrace containsObject:identity]) continue;
        if ([MacWSPendingWindowSceneIdentities containsObject:identity])
            continue;
        MacWSStreamWindow *window = current[identity];
        MacWSStreamWindowFlags flags = window.descriptor.flags;
        // A newly opened document can publish its real level-0 CGWindow one
        // catalog before AppKit changes keyWindow.  Tying Scene creation to
        // this coordinator's owner or to that first Focused bit therefore
        // made the result depend on which of several foreground Scenes won
        // the coordinator election.  Runtime-confirmed with Preview PID
        // 62596: image window 182 and PDF window 183 were both ordinary,
        // visible, on-screen level-0 windows, while the metrics sidecar could
        // focus only one of them.  Every such on-screen top-level identity is
        // already an independently presentable macOS window; dialogs and
        // sheets remain excluded by displayd's metrics/layer join and the
        // explicit Transient flag.
        BOOL presentableTopLevel = window.descriptor.ownerPID > 1 &&
            (flags & MacWSStreamWindowOnScreen) != 0 &&
            (flags & MacWSStreamWindowTransient) == 0;
        BOOL alreadyObserved =
            [MacWSObservedWindowIdentities containsObject:identity];
        BOOL hasSceneSession = [occupied containsObject:identity];
        BOOL becameFrontmost =
            [frontmostIdentities containsObject:identity] &&
            ![MacWSPreviouslyFrontmostWindowIdentities
                containsObject:identity];
        BOOL needsNewScene = !alreadyObserved && !hasSceneSession;
        BOOL needsFrontmostScene = becameFrontmost &&
            ![keySceneIdentities containsObject:identity];
        if (presentableTopLevel &&
            (needsNewScene || needsFrontmostScene)) {
            [newWindows addObject:window];
            if (alreadyObserved) [reusedFrontmostWindows addObject:identity];
            if (hasSceneSession)
                [reusedBoundFrontmostWindows addObject:identity];
        }
    }
    // Do not consume an identity merely because it appeared in one catalog.
    // In particular, an ordinary window that is initially off-screen must be
    // eligible again after AppKit orders it on-screen.  Keep only identities
    // that were already observed and are still live, plus identities with an
    // existing UIKit Scene.  A selected identity is protected by the pending
    // set until its Scene connects; the next catalog then moves it into the
    // occupied/observed set below.
    NSMutableSet<NSString *> *retainedObserved =
        [MacWSObservedWindowIdentities mutableCopy];
    [retainedObserved intersectSet:observableIdentities];
    [retainedObserved unionSet:occupied];
    [MacWSObservedWindowIdentities setSet:retainedObserved];
    [MacWSPreviouslyFrontmostWindowIdentities setSet:frontmostIdentities];

    // A user gesture normally creates one native window. Bound a pathological
    // application burst so one catalog invalidation cannot flood FrontBoard.
    NSUInteger limit = MIN(newWindows.count, 3);
    for (NSUInteger index = 0; index < limit; index++) {
        MacWSStreamWindow *window = newWindows[index];
        NSString *identity = MacWSWindowIdentity(window.descriptor.ownerPID,
            window.descriptor.windowID, window.descriptor.logicalGroupID);
        if (!identity) continue;
        [MacWSPendingWindowSceneIdentities addObject:identity];
        MacWSLog(@"window-auto-scene candidate identity=%@ pid=%d window=%u flags=%#x reason=%@",
                 identity, window.descriptor.ownerPID,
                 window.descriptor.windowID, window.descriptor.flags,
                 [reusedBoundFrontmostWindows containsObject:identity]
                    ? @"existing-session-became-frontmost"
                    : [reusedFrontmostWindows containsObject:identity]
                        ? @"existing-unbound-became-frontmost"
                        : @"new-onscreen-top-level");
        // AppKit publishes the NSWindow first and its final min/max axis
        // policy on the next 500-ms metrics generation. Runtime-confirmed for
        // Finder Get Info window 482: the first catalog flags were 0x24f
        // (resizable, no fixed axis), while Finder's next metrics generation
        // reported min=265x481, max=16384x481, fixed=NOxYES. Creating the
        // Scene at 250 ms therefore permanently seeded it with stale policy.
        // Ask displayd for fresh snapshots while AppKit settles, then create
        // the native Scene once from the post-publication descriptor. This
        // short invisible preparation is preferable to presenting a stock
        // 1004x807 Scene and visibly shrinking it seconds later.
        for (NSNumber *delay in @[@220, @520]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         delay.longLongValue * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if ([MacWSPendingWindowSceneIdentities
                        containsObject:identity])
                    [self->_metalView requestStreamWindowList];
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 680 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSStreamWindow *stableWindow = nil;
            for (MacWSStreamWindow *candidate in self->_streamWindows) {
                NSString *candidateIdentity = MacWSWindowIdentity(
                    candidate.descriptor.ownerPID,
                    candidate.descriptor.windowID,
                    candidate.descriptor.logicalGroupID);
                if ([candidateIdentity isEqualToString:identity] &&
                    (candidate.descriptor.flags & MacWSStreamWindowVisible) &&
                    (candidate.descriptor.flags & MacWSStreamWindowOnScreen) &&
                    (candidate.descriptor.flags &
                        MacWSStreamWindowTransient) == 0) {
                    stableWindow = candidate;
                    break;
                }
            }
            if (!stableWindow) {
                [MacWSPendingWindowSceneIdentities removeObject:identity];
                [MacWSPreviouslyFrontmostWindowIdentities
                    removeObject:identity];
                MacWSLog(@"window-auto-scene cancelled identity=%@ reason=transient",
                         identity);
                return;
            }
            if ([self hasForegroundFullscreenWorkspace]) {
                [MacWSPendingWindowSceneIdentities removeObject:identity];
                if (!MacWSObservedWindowIdentities)
                    MacWSObservedWindowIdentities = [NSMutableSet set];
                [MacWSObservedWindowIdentities addObject:identity];
                [self activateMacWindow:stableWindow];
                MacWSLog(@"window-auto-scene retained-fullscreen identity=%@ pid=%d window=%u",
                         identity, stableWindow.descriptor.ownerPID,
                         stableWindow.descriptor.windowID);
                return;
            }
            NSString *title = stableWindow.title.length
                ? stableWindow.title : @"macOS Window";
            MacWSLog(@"window-auto-scene identity=%@ title=%@ stable-ms=680 flags=%#x logical=%.1fx%.1f minimum=%.1fx%.1f fixed=%@x%@",
                     identity, title, stableWindow.descriptor.flags,
                     stableWindow.descriptor.logicalWidth,
                     stableWindow.descriptor.logicalHeight,
                     stableWindow.descriptor.minimumLogicalWidth,
                     stableWindow.descriptor.minimumLogicalHeight,
                     (stableWindow.descriptor.flags &
                        MacWSStreamWindowFixedWidth) ? @"YES" : @"NO",
                     (stableWindow.descriptor.flags &
                        MacWSStreamWindowFixedHeight) ? @"YES" : @"NO");
            MacWSRequestNewScene(self.view.window.windowScene,
                stableWindow.descriptor.windowID,
                stableWindow.descriptor.ownerPID,
                stableWindow.descriptor.logicalGroupID,
                CGSizeMake(stableWindow.descriptor.logicalWidth,
                           stableWindow.descriptor.logicalHeight),
                CGSizeMake(stableWindow.descriptor.minimumLogicalWidth,
                           stableWindow.descriptor.minimumLogicalHeight),
                stableWindow.maximumLogicalSize,
                (stableWindow.descriptor.flags & MacWSStreamWindowResizable) != 0,
                (stableWindow.descriptor.flags &
                    MacWSStreamWindowFixedWidth) != 0,
                (stableWindow.descriptor.flags &
                    MacWSStreamWindowFixedHeight) != 0,
                title, NO, ^(NSError *error) {
                    [MacWSPendingWindowSceneIdentities removeObject:identity];
                    [MacWSObservedWindowIdentities removeObject:identity];
                    [MacWSPreviouslyFrontmostWindowIdentities
                        removeObject:identity];
                    [self setNotice:error.localizedDescription success:NO];
                });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [MacWSPendingWindowSceneIdentities removeObject:identity];
        });
    }
}

- (void)metalView:(MacWSMetalView *)view
  receivedWindows:(NSArray<MacWSStreamWindow *> *)windows {
    (void)view;
    _streamWindows = [windows copy];
    if (_sceneDestructionRequested) return;
    if (_streamMode == MacWSStreamModeFullscreen) {
        if (_pendingFullscreenActivationOwnerPID > 1 &&
            _pendingFullscreenActivationWindowID != 0) {
            MacWSStreamWindow *requested = nil;
            for (MacWSStreamWindow *window in windows) {
                if (window.descriptor.ownerPID ==
                        _pendingFullscreenActivationOwnerPID &&
                    window.descriptor.windowID ==
                        _pendingFullscreenActivationWindowID) {
                    requested = window;
                    break;
                }
            }
            if (requested) {
                int32_t requestedPID =
                    _pendingFullscreenActivationOwnerPID;
                uint32_t requestedWindow =
                    _pendingFullscreenActivationWindowID;
                _pendingFullscreenActivationOwnerPID = 0;
                _pendingFullscreenActivationWindowID = 0;
                _pendingFullscreenActivationTitle = nil;
                _pendingFullscreenActivationDeadline = 0.0;
                MacWSLog(@"fullscreen-window-route matched pid=%d window=%u "
                         "flags=%#x source=deferred-exact-catalog",
                         requestedPID, requestedWindow,
                         requested.descriptor.flags);
                [self activateMacWindow:requested];
            } else if (CACurrentMediaTime() >=
                       _pendingFullscreenActivationDeadline) {
                MacWSLog(@"fullscreen-window-route expired pid=%d window=%u "
                         "title=%@ source=deferred-exact-catalog",
                         _pendingFullscreenActivationOwnerPID,
                         _pendingFullscreenActivationWindowID,
                         _pendingFullscreenActivationTitle ?: @"");
                _pendingFullscreenActivationOwnerPID = 0;
                _pendingFullscreenActivationWindowID = 0;
                _pendingFullscreenActivationTitle = nil;
                _pendingFullscreenActivationDeadline = 0.0;
            }
        }
        NSMutableSet<NSNumber *> *eligiblePIDs = [NSMutableSet set];
        for (MacWSStreamWindow *window in windows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            MacWSStreamWindowFlags flags = descriptor.flags;
            MacWSStreamWindowFlags fullscreenAuthority =
                MacWSStreamWindowFocused |
                MacWSStreamWindowFullscreenCanvas;
            BOOL ordinaryAuthority =
                (flags & MacWSStreamWindowVisible) != 0 &&
                (flags & MacWSStreamWindowOnScreen) != 0;
            BOOL focusedFullscreenCanvas =
                (flags & fullscreenAuthority) == fullscreenAuthority;
            if (descriptor.ownerPID > 1 &&
                MacWSAppInputEndpointReady(descriptor.ownerPID) &&
                (ordinaryAuthority || focusedFullscreenCanvas)) {
                [eligiblePIDs addObject:@(descriptor.ownerPID)];
            }
        }
        int32_t visualPID =
            [_metalView frontmostInputApplicationPIDAmongPIDs:eligiblePIDs];
        MacWSStreamWindow *frontmost = nil;
        for (MacWSStreamWindow *window in windows) {
            MacWSStreamWindowDescriptor descriptor = window.descriptor;
            MacWSStreamWindowFlags flags = descriptor.flags;
            MacWSStreamWindowFlags fullscreenAuthority =
                MacWSStreamWindowFocused |
                MacWSStreamWindowFullscreenCanvas;
            BOOL ordinaryAuthority =
                (flags & MacWSStreamWindowVisible) != 0 &&
                (flags & MacWSStreamWindowOnScreen) != 0;
            BOOL focusedFullscreenCanvas =
                (flags & fullscreenAuthority) == fullscreenAuthority;
            if (descriptor.ownerPID <= 1 ||
                !MacWSAppInputEndpointReady(descriptor.ownerPID) ||
                (!ordinaryAuthority && !focusedFullscreenCanvas)) continue;
            if (descriptor.ownerPID != visualPID) continue;
            // The compositor graph is already the exact presentation order
            // Host draws. Do not prefer the process-local Focused bit here:
            // runtime logs from
            // 1786551260-1786551560 captured Terminal, Finder, Excel and Code
            // concurrently publishing stale focused state.  The former
            // passive-catalog handler reacted by activating each reporter in
            // turn, reordered the real desktop, retired/restarted its exact
            // capture layers and visibly flashed while the pointer moved.
            frontmost = window;
            break;
        }
        int32_t previousPID = _metalView.targetPID;
        int32_t catalogFallbackPID = visualPID;
        BOOL retainedActiveInputTransaction =
            visualPID != previousPID && previousPID > 1 &&
            _metalView.fullscreenInputTransactionActive;
        BOOL retainedPreviousTarget =
            visualPID != previousPID && previousPID > 1 &&
            MacWSAppInputEndpointReady(previousPID) &&
            ![eligiblePIDs containsObject:@(previousPID)];
        BOOL activatedFullscreenCanvasPresent = NO;
        if (visualPID != previousPID && previousPID > 1 &&
            _fullscreenActivatedInputOwnerPID == previousPID &&
            MacWSAppInputEndpointReady(previousPID)) {
            for (MacWSStreamWindow *window in windows) {
                MacWSStreamWindowDescriptor descriptor = window.descriptor;
                MacWSStreamWindowFlags required =
                    MacWSStreamWindowFocused |
                    MacWSStreamWindowFullscreenCanvas;
                if (descriptor.ownerPID == previousPID &&
                    descriptor.windowID != 0 &&
                    (descriptor.flags & required) == required) {
                    activatedFullscreenCanvasPresent = YES;
                    break;
                }
            }
        }
        BOOL retainedCompletedFullscreen =
            visualPID != previousPID && previousPID > 1 &&
            _fullscreenActivatedInputOwnerPID == previousPID &&
            [_metalView hasCompletedFullscreenDrawableForPID:previousPID];
        if (retainedActiveInputTransaction) {
            // Window moves/resizes can change retained layer order before
            // WindowServer has published the matching catalog generation.
            // Never replace targetPID while the physical button is held:
            // setTargetPID: clears the direct-drawable join, and subsequent
            // global movement can then appear to hit the exposed window
            // underneath. TouchDown already selected the semantic owner; the
            // matching Up/Cancel requests a bounded catalog refresh.
            visualPID = previousPID;
            frontmost = nil;
            if (!_fullscreenInputTargetDeferredForActiveTransaction) {
                _fullscreenInputTargetDeferredForActiveTransaction = YES;
                MacWSLog(@"fullscreen-input-target retained-active-transaction pid=%d rejected-catalog-fallback-pid=%d",
                         previousPID, catalogFallbackPID);
            }
        } else if (retainedPreviousTarget || activatedFullscreenCanvasPresent ||
                   retainedCompletedFullscreen) {
            // A fullscreen Metal application may stop publishing its AppKit
            // catalog window while its process-local input endpoint and the
            // full-display stream remain live.  The next ordinary overlay in
            // paint order (usually Terminal) is not evidence of a foreground
            // change. Explicit activation and pointer hit-testing already set
            // targetPID at their user-action boundaries, so keep that live
            // target until it exits or a real user action selects another.
            // Runtime-confirmed with Stray pid=69410: layer 661 retired at
            // 1787255929.503, then the old callback incorrectly selected
            // Terminal pid=15404 at 1787255930.463 even though Stray's input
            // socket and display presentation continued.
            // The same ordinary launcher can become OnScreenOnly-frontmost
            // between explicit fullscreen activation and the first completed
            // game drawable. Preserve the exact focused fullscreen canvas at
            // that boundary as well, otherwise a first-frame-only witness is
            // too late: changing targetPID erases the activation and direct
            // presentation state before the drawable arrives. A real user
            // switch still changes targetPID at its input/activation boundary.
            visualPID = previousPID;
            frontmost = nil;
            if (_fullscreenCatalogRetainedInputPID != previousPID) {
                _fullscreenCatalogRetainedInputPID = previousPID;
                MacWSLog(@"fullscreen-input-target retained-%@ pid=%d rejected-catalog-fallback-pid=%d",
                         activatedFullscreenCanvasPresent ? @"activated-fullscreen-canvas" :
                            (retainedCompletedFullscreen ? @"completed-fullscreen-drawable" : @"live-endpoint"),
                         previousPID, catalogFallbackPID);
            }
        } else {
            _fullscreenCatalogRetainedInputPID = 0;
        }
        if (!retainedActiveInputTransaction)
            _fullscreenInputTargetDeferredForActiveTransaction = NO;
        MacWSStreamWindow *target = frontmost;
        int32_t targetPID = visualPID;
        if (target) {
            MacWSStreamWindowFlags fullscreenAuthority =
                MacWSStreamWindowFocused |
                MacWSStreamWindowFullscreenCanvas;
            if ((target.descriptor.flags & fullscreenAuthority) ==
                    fullscreenAuthority) {
                [_metalView noteValidatedFullscreenCanvasForPID:
                    target.descriptor.ownerPID
                                                       windowID:
                    target.descriptor.windowID];
            }
        }
        if (targetPID != previousPID) {
            _metalView.targetPID = targetPID;
            if (_fullscreenActivatedInputOwnerPID != targetPID) {
                _fullscreenActivatedInputWindowID = 0;
                _fullscreenActivatedInputOwnerPID = 0;
            }
            MacWSLog(@"fullscreen-input-target pid=%d window=%u source=%@ title=%@",
                     targetPID, target ? target.descriptor.windowID : 0,
                     target ? @"frontmost-presented-layer" :
                              @"system-point-hit-test",
                     target.title ?: @"");
            // Catalog reception is observational.  Explicit Control Center,
            // Dock/new-window, click and menu operations already call
            // activateMacWindow: at their user-action boundary.  Mutating
            // WindowServer ordering from this callback creates a feedback
            // loop (activation -> catalog -> activation) and makes a capture
            // transport bug look like application flicker.
            [self refreshStatus];
        }

        // An explicit activation carries an exact NSWindow number into
        // inputd's cached keyboard target.  If that native window is later
        // removed while its application remains the live fullscreen owner,
        // follow the best remaining ordinary window from the authoritative
        // catalog.  This is a lifecycle repair, not passive focus
        // reconciliation: it runs only after the exact activated identity is
        // absent, so it cannot create activation -> catalog feedback on an
        // otherwise stable desktop.
        if (_fullscreenActivatedInputWindowID != 0 &&
            _fullscreenActivatedInputOwnerPID == _metalView.targetPID) {
            BOOL activatedWindowPresent = NO;
            MacWSStreamWindow *replacement = nil;
            NSUInteger replacementScore = 0;
            CGFloat replacementArea = 0.0;
            for (MacWSStreamWindow *window in windows) {
                MacWSStreamWindowDescriptor descriptor = window.descriptor;
                if (descriptor.ownerPID !=
                    _fullscreenActivatedInputOwnerPID) continue;
                if (descriptor.windowID ==
                    _fullscreenActivatedInputWindowID) {
                    activatedWindowPresent = YES;
                    break;
                }
                MacWSStreamWindowFlags flags = descriptor.flags;
                if (descriptor.windowID == 0 ||
                    (flags & MacWSStreamWindowTransient) != 0 ||
                    (flags & MacWSStreamWindowVisible) == 0 ||
                    (flags & MacWSStreamWindowOnScreen) == 0) continue;
                NSUInteger score =
                    ((flags & MacWSStreamWindowFocused) ? 4 : 0) |
                    ((flags & MacWSStreamWindowOnScreen) ? 2 : 0) | 1;
                CGFloat area = descriptor.logicalWidth *
                               descriptor.logicalHeight;
                if (!replacement || score > replacementScore ||
                    (score == replacementScore && area > replacementArea)) {
                    replacement = window;
                    replacementScore = score;
                    replacementArea = area;
                }
            }
            if (!activatedWindowPresent && replacement) {
                uint32_t retiredWindowID =
                    _fullscreenActivatedInputWindowID;
                [self activateMacWindow:replacement];
                MacWSLog(@"fullscreen-input-window-follow pid=%d old=%u new=%u score=%lu reason=activated-window-absent",
                         replacement.descriptor.ownerPID, retiredWindowID,
                         replacement.descriptor.windowID,
                         (unsigned long)replacementScore);
            }
        }
    }
    // Establish the first complete catalog as a baseline before an explicit
    // launch transaction consumes it. This prevents restoring Host from
    // opening every pre-existing macOS window at once; subsequent identities
    // are the actual native windows created after Host became live.
    if (!MacWSObservedWindowIdentities) {
        MacWSObservedWindowIdentities = [NSMutableSet set];
        MacWSPreviouslyFrontmostWindowIdentities = [NSMutableSet set];
        NSMutableSet<NSNumber *> *frontmostOwners = [NSMutableSet set];
        for (MacWSStreamWindow *window in windows) {
            NSString *identity = MacWSWindowIdentity(
                window.descriptor.ownerPID, window.descriptor.windowID,
                window.descriptor.logicalGroupID);
            if (!identity) continue;
            [MacWSObservedWindowIdentities addObject:identity];
            if ((window.descriptor.flags &
                    MacWSStreamWindowFrontmostApplication) != 0)
                [frontmostOwners addObject:@(window.descriptor.ownerPID)];
        }
        NSMutableSet<NSNumber *> *ownersWithKeyWindow = [NSMutableSet set];
        for (MacWSStreamWindow *window in windows) {
            NSString *identity = MacWSWindowIdentity(
                window.descriptor.ownerPID, window.descriptor.windowID,
                window.descriptor.logicalGroupID);
            MacWSStreamWindowFlags flags = window.descriptor.flags;
            if (identity && [frontmostOwners containsObject:
                    @(window.descriptor.ownerPID)] &&
                (flags & MacWSStreamWindowFocused) != 0 &&
                (flags & MacWSStreamWindowOnScreen) != 0 &&
                (flags & MacWSStreamWindowTransient) == 0) {
                [MacWSPreviouslyFrontmostWindowIdentities
                    addObject:identity];
                [ownersWithKeyWindow addObject:@(window.descriptor.ownerPID)];
            }
        }
        for (MacWSStreamWindow *window in windows) {
            NSString *identity = MacWSWindowIdentity(
                window.descriptor.ownerPID, window.descriptor.windowID,
                window.descriptor.logicalGroupID);
            MacWSStreamWindowFlags flags = window.descriptor.flags;
            if (identity &&
                (flags & MacWSStreamWindowFrontmostApplication) != 0 &&
                ![ownersWithKeyWindow containsObject:
                    @(window.descriptor.ownerPID)] &&
                (flags & MacWSStreamWindowOnScreen) != 0 &&
                (flags & MacWSStreamWindowTransient) == 0)
                [MacWSPreviouslyFrontmostWindowIdentities
                    addObject:identity];
        }
    }
    [self openInitialFinderBrowserWindowIfNeeded:windows];
    [self openPendingApplicationWindowFromCatalog:windows];
    [self openNewMacWindowsFromCatalog:windows];
    // The explicit pending-launch path can rebind this Scene above. Probe
    // its current owner afterward; a retired owner's ESRCH must not become
    // absence evidence for the newly bound application.
    BOOL targetOwnerMissing = NO;
    if (_streamMode == MacWSStreamModeWindow && _windowID != 0 &&
        _windowOwnerPID > 1) {
        errno = 0;
        targetOwnerMissing = kill(_windowOwnerPID, 0) != 0 && errno == ESRCH;
        // Runtime-confirmed: MacWSHost.log 1789161045.785/.800 converted the
        // dead Finder owner's About/Get Info Scenes into desktop workspaces;
        // each then issued a fullscreen activation and displaced the stage.
        // A window Scene owns only this exact native window, not a fallback
        // desktop. Retire it through the confirmed missing-window path below.
        // ESRCH, not EPERM or one absent catalog entry, is process-death proof.
    }
    if (_windowID != 0) {
        MacWSStreamWindow *exactWindow = nil;
        MacWSStreamWindow *groupReplacement = nil;
        for (MacWSStreamWindow *window in windows) {
            // A retained catalog can outlive the process it describes. Never
            // adopt its stale entry, or another process's reused window ID.
            if (targetOwnerMissing ||
                window.descriptor.ownerPID != _windowOwnerPID) continue;
            if (window.descriptor.windowID == _windowID) {
                exactWindow = window;
            } else if (_windowGroupID != 0 &&
                       window.descriptor.ownerPID == _windowOwnerPID &&
                       window.descriptor.logicalGroupID == _windowGroupID) {
                MacWSStreamWindowFlags flags = window.descriptor.flags;
                MacWSStreamWindowFlags oldFlags =
                    groupReplacement ? groupReplacement.descriptor.flags : 0;
                NSUInteger score =
                    ((flags & MacWSStreamWindowFocused) ? 2 : 0) |
                    ((flags & MacWSStreamWindowOnScreen) ? 1 : 0);
                NSUInteger oldScore =
                    ((oldFlags & MacWSStreamWindowFocused) ? 2 : 0) |
                    ((oldFlags & MacWSStreamWindowOnScreen) ? 1 : 0);
                if (!groupReplacement || score > oldScore)
                    groupReplacement = window;
            }
        }
        // CGWindowListOptionAll intentionally retains Terminal's inactive tab
        // members. Selecting a tab can therefore leave the old exact ID in the
        // catalog even though a focused/on-screen member of the same native
        // NSWindowTabGroup is now the only visible representation. Resolve the
        // logical group by real screen state before falling back to exact ID.
        BOOL exactOnScreen = exactWindow &&
            (exactWindow.descriptor.flags & MacWSStreamWindowOnScreen) != 0;
        BOOL replacementFocused = groupReplacement &&
            (groupReplacement.descriptor.flags & MacWSStreamWindowFocused) != 0;
        BOOL replacementOnScreen = groupReplacement &&
            (groupReplacement.descriptor.flags & MacWSStreamWindowOnScreen) != 0;
        MacWSStreamWindow *resolvedWindow = exactWindow;
        if (groupReplacement && (replacementFocused ||
                (!exactOnScreen && replacementOnScreen)))
            resolvedWindow = groupReplacement;
        if (!resolvedWindow) resolvedWindow = groupReplacement;
        if (resolvedWindow) {
            BOOL previouslyObservedTarget = _targetWindowObservedInCatalog;
            CGSize previousPreferredSize = _windowPreferredSize;
            CGSize previousMinimumSize = _windowMinimumSize;
            CGSize previousMaximumSize = _windowMaximumSize;
            BOOL configurationPending =
                _metalView.nativeWindowResizeGestureActive ||
                _metalView.windowConfigurationAwaitingAcknowledgement ||
                _metalView.windowConfigurationAwaitingSettlement ||
                _metalView.windowConfigurationHasQueuedRequest;
            BOOL sceneFollowingAppKit =
                _metalView.sceneResizeFollowingTargetWindow;
            _targetWindowObservedInCatalog = YES;
            _targetWindowMissingCheckPending = NO;
            _targetWindowMissingSerial++;
            uint32_t resolvedID = resolvedWindow.descriptor.windowID;
            int32_t previousOwnerPID = _windowOwnerPID;
            uint32_t previousGroupID = _windowGroupID;
            _windowOwnerPID = resolvedWindow.descriptor.ownerPID;
            _windowGroupID = resolvedWindow.descriptor.logicalGroupID;
            _windowMinimumSize = CGSizeMake(
                resolvedWindow.descriptor.minimumLogicalWidth,
                resolvedWindow.descriptor.minimumLogicalHeight);
            _windowMaximumSize = resolvedWindow.maximumLogicalSize;
            CGSize observedLogicalSize = CGSizeMake(
                resolvedWindow.descriptor.logicalWidth,
                resolvedWindow.descriptor.logicalHeight);
            BOOL usableObservedGeometry =
                observedLogicalSize.width >= 64.0 &&
                observedLogicalSize.height >= 64.0;
            if (usableObservedGeometry)
                _windowPreferredSize = observedLogicalSize;
            BOOL previousWidthFixed = _windowWidthFixed;
            BOOL previousHeightFixed = _windowHeightFixed;
            _windowResizable =
                (resolvedWindow.descriptor.flags & MacWSStreamWindowResizable) != 0;
            _windowWidthFixed =
                (resolvedWindow.descriptor.flags &
                    MacWSStreamWindowFixedWidth) != 0 || !_windowResizable;
            _windowHeightFixed =
                (resolvedWindow.descriptor.flags &
                    MacWSStreamWindowFixedHeight) != 0 || !_windowResizable;
            // Install native limits before delivering the exact configure
            // ACK. A catalog minimum or a changed surface alone is not an
            // acknowledgement of the currently requested geometry.
            _metalView.minimumLogicalSize = _windowMinimumSize;
            _metalView.maximumLogicalSize = _windowMaximumSize;
            _metalView.windowConfigurationAcknowledgementsAvailable =
                resolvedWindow.supportsConfigurationAcknowledgements;
            _metalView.targetWindowResizable = _windowResizable;
            _metalView.targetWindowFixedWidth = _windowWidthFixed;
            _metalView.targetWindowFixedHeight = _windowHeightFixed;
            if (usableObservedGeometry)
                [_metalView observeTargetWindowLogicalSize:observedLogicalSize];
            if (resolvedWindow.supportsConfigurationAcknowledgements)
                [_metalView observeWindowConfigurationWithTimestamp:
                    resolvedWindow.latestConfigureTimestamp
                    sampleSequence:resolvedWindow.latestConfigureSequence
                    requestedSize:resolvedWindow.latestConfigureRequestedSize
                    appliedSize:resolvedWindow.latestConfigureAppliedSize];
            BOOL geometryTransactionBusy = configurationPending ||
                _metalView.nativeWindowResizeGestureActive ||
                sceneFollowingAppKit ||
                _metalView.windowConfigurationAwaitingAcknowledgement ||
                _metalView.windowConfigurationAwaitingSettlement ||
                _metalView.windowConfigurationHasQueuedRequest ||
                _metalView.sceneResizeFollowingTargetWindow;
            BOOL appKitChangedItsOwnSize = usableObservedGeometry &&
                previouslyObservedTarget &&
                resolvedID == _windowID && !geometryTransactionBusy &&
                previousPreferredSize.width > 0.0 &&
                previousPreferredSize.height > 0.0 &&
                (fabs(observedLogicalSize.width -
                      previousPreferredSize.width) >= 0.75 ||
                 fabs(observedLogicalSize.height -
                      previousPreferredSize.height) >= 0.75);
            BOOL axisPolicyChanged = previouslyObservedTarget &&
                (previousWidthFixed != _windowWidthFixed ||
                 previousHeightFixed != _windowHeightFixed ||
                 !CGSizeEqualToSize(previousMinimumSize, _windowMinimumSize) ||
                 !CGSizeEqualToSize(previousMaximumSize, _windowMaximumSize));
            // Restoration metadata can predate the axis flags added to the
            // stream protocol. The first authoritative catalog is therefore
            // also a policy transition when it discovers a fixed axis. Apply
            // that Scene restriction immediately instead of waiting for the
            // AppKit frame to change a second time.
            BOOL initialAxisPolicyDiscovered = !previouslyObservedTarget &&
                (_windowWidthFixed || _windowHeightFixed ||
                 _windowMaximumSize.width > 0.0 || _windowMaximumSize.height > 0.0);
            if (usableObservedGeometry &&
                (appKitChangedItsOwnSize || axisPolicyChanged ||
                 initialAxisPolicyDiscovered)) {
                // A policy update may accompany a stale geometry snapshot
                // while a newer configure is pending. Publish its limits,
                // but never cancel that transaction to follow the snapshot.
                [self updateNativeSceneSizeForAppliedLogicalSize:
                    observedLogicalSize reason:(axisPolicyChanged ||
                                                initialAxisPolicyDiscovered)
                        ? @"appkit-axis-policy" : @"appkit-autonomous"
                    policyOnly:geometryTransactionBusy];
            } else if (!usableObservedGeometry) {
                // Runtime-confirmed by MacWSHost.log at 1789061518.061: a
                // closing/transitioning AppKit window briefly appeared in the
                // catalog as 2x3 points.  It is not a usable window geometry
                // and must not overwrite the last stable restoration size or
                // become a reverse Scene-size request.
                MacWSLog(@"window-geometry transient-rejected window=%u pid=%d logical=%.1fx%.1f",
                         resolvedID, _windowOwnerPID,
                         observedLogicalSize.width,
                         observedLogicalSize.height);
            }
            if (resolvedID != _windowID) {
                uint32_t oldID = _windowID;
                // Runtime-confirmed in MacWSHost.log on iPad13,6/20D67:
                // Terminal tab selection replaces the focused CGWindow ID
                // inside the same logical group (819 <-> 820), and the next
                // IOSurface arrives 45-80 ms later. suspendStream used to
                // discard the still-valid group predecessor immediately,
                // exposing a clear drawable during that bounded handoff.
                // MacWSStreamClient rejects old-window frames after changing
                // its subscription, while receivedFrame retires the retained
                // predecessor behind the Metal completion fence. Preserve
                // only this exact same-owner, same-group identity handoff;
                // lifecycle/mode/cross-window transitions still suspend.
                BOOL preserveGroupPredecessor =
                    previousOwnerPID > 1 && previousGroupID != 0 &&
                    resolvedWindow.descriptor.ownerPID == previousOwnerPID &&
                    resolvedWindow.descriptor.logicalGroupID == previousGroupID;
                if (!preserveGroupPredecessor) [_metalView suspendStream];
                _windowID = resolvedID;
                _metalView.targetPID = _windowOwnerPID;
                [_metalView configureStreamMode:MacWSStreamModeWindow
                                        windowID:_windowID];
                self.view.window.windowScene.title = resolvedWindow.title.length
                    ? resolvedWindow.title
                    : [NSString stringWithFormat:@"MacWS Window %u", _windowID];
                MacWSLog(@"window-identity-follow owner=%d group=%u old=%u new=%u frame-preserved=%@",
                         _windowOwnerPID, _windowGroupID, oldID, _windowID,
                         preserveGroupPredecessor ? @"YES" : @"NO");
                MacWSRememberSceneBinding(self.view.window.windowScene.session,
                                          [self streamRestorationActivity]);
            }
        } else if ((_targetWindowObservedInCatalog || targetOwnerMissing) &&
                   !_targetWindowMissingCheckPending &&
                   !_sceneDestructionRequested) {
            // The catalog is authoritative, but one transient refresh can
            // occur while AppKit replaces a tab-group member. Re-query once
            // and require the exact ID and its logical group to remain absent
            // for a bounded interval before removing the corresponding Scene.
            _targetWindowMissingCheckPending = YES;
            uint64_t serial = ++_targetWindowMissingSerial;
            uint32_t expectedWindowID = _windowID;
            uint32_t expectedGroupID = _windowGroupID;
            int32_t expectedOwnerPID = _windowOwnerPID;
            uint64_t firstMissingCatalogRevision = _metalView.windowCatalogRevision;
            BOOL ownerWasMissing = targetOwnerMissing;
            [_metalView requestStreamWindowList];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         650 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (serial != self->_targetWindowMissingSerial ||
                    !self->_targetWindowMissingCheckPending ||
                    self->_sceneDestructionRequested ||
                    self->_streamMode != MacWSStreamModeWindow ||
                    self->_windowID != expectedWindowID ||
                    self->_windowOwnerPID != expectedOwnerPID ||
                    self->_windowGroupID != expectedGroupID) return;
                errno = 0;
                BOOL ownerStillMissing =
                    kill(expectedOwnerPID, 0) != 0 && errno == ESRCH;
                self->_targetWindowMissingCheckPending = NO;
                // Do not turn an unanswered re-query into a second absence
                // witness. A live/reused PID requires another catalog; two
                // ESRCH probes across the interval independently prove death.
                BOOL refreshedCatalog = self->_metalView.windowCatalogRevision >
                    firstMissingCatalogRevision;
                if (!refreshedCatalog &&
                    !(ownerWasMissing && ownerStillMissing)) {
                    MacWSLog(@"mac-window-removed confirmation-deferred owner=%d window=%u reason=no-fresh-catalog",
                             expectedOwnerPID, expectedWindowID);
                    [self->_metalView requestStreamWindowList];
                    return;
                }
                BOOL present = NO;
                for (MacWSStreamWindow *candidate in self->_streamWindows) {
                    if (ownerStillMissing ||
                        candidate.descriptor.ownerPID != expectedOwnerPID)
                        continue;
                    if (candidate.descriptor.windowID == expectedWindowID ||
                        (expectedGroupID != 0 &&
                         candidate.descriptor.logicalGroupID == expectedGroupID)) {
                        present = YES;
                        break;
                    }
                }
                if (present) return;
                UISceneSession *session = self.view.window.windowScene.session;
                NSString *identifier = session.persistentIdentifier;
                if (!session || !identifier.length) return;
                // A closing AppKit panel and the top-level windows exposed by
                // that close can share one DisplayStream catalog generation.
                // openNewMacWindowsFromCatalog: has already submitted their
                // UIKit Scene activations, but FrontBoard has not necessarily
                // connected either successor yet. Runtime-confirmed on
                // 2026-09-11: destroying About Finder's last connected Scene
                // 30 ms before the root/Get Info activation requests caused
                // iPadOS to synthesize an activity-less default Scene. That
                // Scene restored as fullscreen, launched bootstrap Terminal,
                // and discarded an unrelated Excel Stage Manager window.
                // Keep this now-orphaned presentation alive until one of the
                // exact pending successors has a real UISceneSession. If all
                // requests fail, their existing five-second expiry clears the
                // pending set and the ordinary missing-window path resumes.
                BOOL pendingSuccessorConnection = NO;
                if (MacWSPendingWindowSceneIdentities.count != 0) {
                    for (UISceneSession *candidate in
                            UIApplication.sharedApplication.openSessions) {
                        if (candidate == session) continue;
                        NSUserActivity *candidateActivity =
                            MacWSSceneBindings[
                                candidate.persistentIdentifier] ?:
                            MacWSPersistedSceneActivity(
                                candidate.persistentIdentifier) ?:
                            candidate.stateRestorationActivity;
                        int32_t candidateOwner = 0;
                        uint32_t candidateWindow = 0;
                        uint32_t candidateGroup = 0;
                        if (!MacWSSceneOwnedWindowFields(
                                candidateActivity.userInfo,
                                &candidateOwner, &candidateWindow,
                                &candidateGroup)) continue;
                        NSString *candidateIdentity = MacWSWindowIdentity(
                            candidateOwner, candidateWindow, candidateGroup);
                        if ([MacWSPendingWindowSceneIdentities
                                containsObject:candidateIdentity]) {
                            pendingSuccessorConnection = YES;
                            break;
                        }
                    }
                    if (!pendingSuccessorConnection) {
                        NSArray<NSString *> *pending =
                            [MacWSPendingWindowSceneIdentities.allObjects
                                sortedArrayUsingSelector:@selector(compare:)];
                        MacWSLog(@"mac-window-removed destruction-deferred id=%@ owner=%d window=%u pending-successors=%@",
                                 identifier, expectedOwnerPID,
                                 expectedWindowID,
                                 [pending componentsJoinedByString:@","]);
                        dispatch_after(dispatch_time(
                                DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                            dispatch_get_main_queue(), ^{
                                if (!self->_sceneDestructionRequested &&
                                    self->_windowID == expectedWindowID &&
                                    self->_windowOwnerPID == expectedOwnerPID)
                                    [self->_metalView
                                        requestStreamWindowList];
                            });
                        return;
                    }
                }
                if (!MacWSSceneSessionsPreservingMacWindow)
                    MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
                if (!MacWSSceneCloseRequestsSent)
                    MacWSSceneCloseRequestsSent = [NSMutableSet set];
                [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
                [MacWSSceneCloseRequestsSent addObject:identifier];
                [MacWSSceneBindings removeObjectForKey:identifier];
                MacWSSetPersistedSceneBinding(identifier, nil);
                self->_sceneDestructionRequested = YES;
                ++self->_nativeFocusRequestSerial;
                ++self->_constrainedSceneResizeSerial;
                self->_deferredBackgroundSceneWindowID = 0;
                [self->_metalView cancelSceneResizeFollowingTargetWindow];
                [self suspendSceneStream];
                MacWSLog(@"runtime-confirmed mac-window-removed id=%@ owner=%d window=%u group=%u catalog-count=%lu owner-missing=%@ refreshed-catalog=%@ recovery=retire-scene mac-window=preserved",
                         identifier, expectedOwnerPID, expectedWindowID,
                         expectedGroupID,
                         (unsigned long)self->_streamWindows.count,
                         ownerStillMissing ? @"YES" : @"NO",
                         refreshedCatalog ? @"YES" : @"NO");
                [UIApplication.sharedApplication
                    requestSceneSessionDestruction:session options:nil
                    errorHandler:^(NSError *error) {
                        self->_sceneDestructionRequested = NO;
                        // This Scene is still orphaned, even if FrontBoard
                        // rejected its destruction. Keep the no-close
                        // tombstones so a later discard cannot address a
                        // recycled PID/window identity through restoration.
                        MacWSLog(@"mac-window-removed scene-destruction failed id=%@ error=%@",
                                 identifier, error);
                        [self resumeSceneStream];
                    }];
            });
        }
    }
    // AppInput publishes the game's accepted relative-mouse state on its
    // exact focused window. Run this after fullscreen/window identity repair
    // above so an old catalog owner cannot acquire iPadOS pointer lock.
    [self updateAutomaticGameInputForWindows:windows];
    NSUInteger logicalWindowCount = [self logicalWindowRepresentatives].count;
    [self setButton:_windowPickerButton
              title:logicalWindowCount
                ? [NSString stringWithFormat:@"打开 macOS 窗口 · %lu",
                   (unsigned long)logicalWindowCount]
                : @"打开 macOS 窗口"
              image:@"macwindow.on.rectangle"];
}

- (NSUserActivity *)streamRestorationActivity {
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.macwsguide.host.window"];
    activity.title = _windowID
        ? [NSString stringWithFormat:@"MacWS Window %u", _windowID]
        : @"MacWS Workspace";
    activity.userInfo = @{
        @"mode": @(_streamMode),
        @"window_id": @(_windowID),
        @"owner_pid": @(_windowOwnerPID),
        @"logical_group_id": @(_windowGroupID),
        @"preferred_width": @(_windowPreferredSize.width),
        @"preferred_height": @(_windowPreferredSize.height),
        @"minimum_width": @(_windowMinimumSize.width),
        @"minimum_height": @(_windowMinimumSize.height),
        @"maximum_width": @(_windowMaximumSize.width),
        @"maximum_height": @(_windowMaximumSize.height),
        @"resizable": @(_windowResizable),
        @"fixed_width": @(_windowWidthFixed),
        @"fixed_height": @(_windowHeightFixed),
        @"title": activity.title,
        @"return_window_id": @(_workspaceReturnValid
            ? _workspaceReturnWindowID : 0),
        @"return_owner_pid": @(_workspaceReturnValid
            ? _workspaceReturnOwnerPID : 0),
        @"return_logical_group_id": @(_workspaceReturnValid
            ? _workspaceReturnGroupID : 0),
        @"return_preferred_width": @(_workspaceReturnValid
            ? _workspaceReturnPreferredSize.width : 0),
        @"return_preferred_height": @(_workspaceReturnValid
            ? _workspaceReturnPreferredSize.height : 0),
        @"return_minimum_width": @(_workspaceReturnValid
            ? _workspaceReturnMinimumSize.width : 0),
        @"return_minimum_height": @(_workspaceReturnValid
            ? _workspaceReturnMinimumSize.height : 0),
        @"return_maximum_width": @(_workspaceReturnValid
            ? _workspaceReturnMaximumSize.width : 0),
        @"return_maximum_height": @(_workspaceReturnValid
            ? _workspaceReturnMaximumSize.height : 0),
        @"return_scene_width": @(_workspaceReturnValid
            ? _workspaceReturnSceneSize.width : 0),
        @"return_scene_height": @(_workspaceReturnValid
            ? _workspaceReturnSceneSize.height : 0),
        @"return_resizable": @(_workspaceReturnValid
            ? _workspaceReturnResizable : NO),
        @"return_fixed_width": @(_workspaceReturnValid
            ? _workspaceReturnWidthFixed : NO),
        @"return_fixed_height": @(_workspaceReturnValid
            ? _workspaceReturnHeightFixed : NO),
        @"return_title": _workspaceReturnValid
            ? (_workspaceReturnTitle ?: @"MacWS Window") : @"",
    };
    return activity;
}

- (void)suspendSceneStream {
    [self dismissSemanticMenu];
    // viewWillDisappear is not guaranteed for a connected UIKit Scene that
    // merely enters the background. Stop the per-Scene status poll here so a
    // resident Host does not keep waking every three seconds while locked.
    [_statusTimer invalidate];
    _statusTimer = nil;
    [_metalView suspendStream];
}

- (void)resumeSceneStream {
    if (_sceneDestructionRequested) return;
    UIWindowScene *scene = self.viewIfLoaded.window.windowScene ?:
        _connectedWindowScene;
    BOOL occluded = NO, foreground = NO, backgrounded = NO;
    BOOL hasEffectiveSettings = MacWSReadEffectiveSceneLifecycle(
        scene, &occluded, &foreground, &backgrounded);
    UISceneActivationState activation = scene.activationState;
    if (activation == UISceneActivationStateBackground ||
        activation == UISceneActivationStateUnattached ||
        (hasEffectiveSettings && (occluded || backgrounded))) {
        _sceneStreamSuspendedForOcclusion = YES;
        MacWSLog(@"scene-stream resume-deferred id=%@ window=%u "
                 "settings=%@ occluded=%@ foreground=%@ backgrounded=%@ "
                 "activation=%ld",
                 scene.session.persistentIdentifier ?: @"none", _windowID,
                 hasEffectiveSettings ? @"YES" : @"NO",
                 occluded ? @"YES" : @"NO", foreground ? @"YES" : @"NO",
                 backgrounded ? @"YES" : @"NO", (long)activation);
        return;
    }
    _sceneStreamSuspendedForOcclusion = NO;
    if (!(_bootstrapTerminalPending && _windowID == 0))
        [_metalView configureStreamMode:_streamMode windowID:_windowID];
    [_metalView requestStreamWindowList];
    [_interopClient connect];
    if (_windowID != 0) [self refreshSemanticMenuWithCompletion:nil];
    [self refreshStatus];
    if (!_statusTimer) {
        _statusTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
            selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    }
}

- (void)requestWindowLifetimeReconciliation {
    if (!_sceneDestructionRequested)
        [_metalView requestStreamWindowList];
}

- (void)applyDeferredForegroundSceneSize {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_deferredBackgroundSceneWindowID == 0 ||
            self->_initialSceneSizePending ||
            self.viewIfLoaded.window.windowScene.activationState !=
                UISceneActivationStateForegroundActive) return;
        CGSize logicalSize = self->_deferredBackgroundSceneLogicalSize;
        BOOL exactTarget = self->_streamMode == MacWSStreamModeWindow &&
            self->_deferredBackgroundSceneWindowID == self->_windowID &&
            self->_deferredBackgroundSceneOwnerPID == self->_windowOwnerPID;
        self->_deferredBackgroundSceneWindowID = 0;
        self->_deferredBackgroundSceneOwnerPID = 0;
        self->_deferredBackgroundSceneLogicalSize = CGSizeZero;
        if (!exactTarget) return;
        [self followNativeSceneSizeForAppliedLogicalSize:logicalSize
            reason:@"foreground-deferred-appkit-size"];
    });
}

- (void)cancelBootstrapTerminal {
    _bootstrapTerminalPending = NO;
    _bootstrapWindowReplacementPending = NO;
}

- (void)metalView:(MacWSMetalView *)view emittedInput:(MacWSInputRecord)record {
    // A queued ConfigureWindow retry can outlive stream suspension. Retiring
    // this presentation must not resize/focus its old target, but terminal
    // gesture/key events must still release any input state it held.
    if (_sceneDestructionRequested &&
        (record.kind == MacWSInputKindConfigureWindow ||
         record.kind == MacWSInputKindActivateTarget)) return;
    int32_t presentationTargetPID = record.targetPID;
    // Fullscreen pointer records become one hardware-style global stream in
    // routeFullscreenInputRecord:, leaving WindowServer authoritative for
    // Dock/Mission Control transforms. Scroll, magnify and rotation still
    // freeze the captured layer selected at Begin because those gestures
    // belong to one
    // application-local responder for their complete lifetime.
    if (_streamMode == MacWSStreamModeFullscreen &&
        record.kind != MacWSInputKindKeyDown &&
        record.kind != MacWSInputKindKeyUp &&
        record.kind != MacWSInputKindModifierSnapshot &&
        record.kind != MacWSInputKindRelativePointer &&
        record.kind != MacWSInputKindPerformPaste &&
        record.kind != MacWSInputKindActivateTarget &&
        record.kind != MacWSInputKindDesktopCommand &&
        record.kind != MacWSInputKindSystemGesture) {
        if (![_metalView routeFullscreenInputRecord:&record
                              presentationTargetPID:
                                  &presentationTargetPID]) {
            record.targetPID = 0;
            record.sceneID &= UINT64_C(0x7fffffff);
            presentationTargetPID = 0;
        }
    }
    NSString *phase = @"?";
    switch ((MacWSInputKind)record.kind) {
        case MacWSInputKindTouchDown: phase = @"down"; break;
        case MacWSInputKindTouchMove: phase = @"move"; break;
        case MacWSInputKindTouchUp: phase = @"up"; break;
        case MacWSInputKindTouchCancel: phase = @"cancel"; break;
        case MacWSInputKindHover: phase = @"hover"; break;
        case MacWSInputKindTap: phase = @"tap"; break;
        case MacWSInputKindSecondaryTap: phase = @"secondary"; break;
        case MacWSInputKindScroll: phase = @"scroll"; break;
        case MacWSInputKindMagnify: phase = @"magnify"; break;
        case MacWSInputKindRotate: phase = @"rotate"; break;
        case MacWSInputKindPerformPaste: phase = @"perform-paste"; break;
        case MacWSInputKindDesktopCommand: phase = @"desktop-command"; break;
        case MacWSInputKindSystemGesture: phase = @"system-gesture"; break;
        case MacWSInputKindKeyDown: phase = @"key-down"; break;
        case MacWSInputKindKeyUp: phase = @"key-up"; break;
        case MacWSInputKindModifierSnapshot: phase = @"modifier-snapshot"; break;
        case MacWSInputKindRelativePointer: phase = @"relative-pointer"; break;
        case MacWSInputKindConfigureWindow: phase = @"configure-window"; break;
        case MacWSInputKindActivateTarget: phase = @"activate-target"; break;
        case MacWSInputKindCloseWindow: phase = @"close-window"; break;
        case MacWSInputKindCreateInitialWindow:
            phase = @"create-initial-window"; break;
        default: break;
    }
    int sendError = 0;
    uint16_t wireVersion = MacWSInputWireVersionForKind(record.kind);
    BOOL sent = MacWSSendInputRecord(&record, &sendError);
    [_metalView.performanceMonitor recordInputKind:record.kind
        sampleTime:record.timestamp targetPID:presentationTargetPID
        transportSuccess:sent];
    _inputLogSequence++;
    BOOL continuous = record.kind == MacWSInputKindTouchMove ||
                      record.kind == MacWSInputKindHover ||
                      record.kind == MacWSInputKindRelativePointer ||
                      record.kind == MacWSInputKindScroll ||
                      record.kind == MacWSInputKindMagnify ||
                      record.kind == MacWSInputKindRotate ||
                      record.kind == MacWSInputKindSystemGesture;
    BOOL traceTouchEdge =
        (record.kind == MacWSInputKindTouchDown ||
         record.kind == MacWSInputKindTouchUp ||
         record.kind == MacWSInputKindTouchCancel) &&
        MacWSHostTouchDiagnosticsEnabled();
    if (record.kind == MacWSInputKindPerformPaste ||
        record.kind == MacWSInputKindActivateTarget ||
        traceTouchEdge ||
        (MacWSHostDiagnosticsEnabled() &&
         (!continuous || (_inputLogSequence % 60) == 0))) {
        MacWSLog(@"input transport=%@ errno=%d wire=%u scene=%llx target=%d kind=%@ source=%u point=(%.2f,%.2f) frame=%ux%u pressure=%.3f contact=%u sample=%u seq=%llu",
                 sent ? @"sent" : @"failed", sendError, wireVersion,
                 record.sceneID,
                 record.targetPID, phase, record.source, record.x, record.y,
                 record.frameWidth, record.frameHeight,
                 record.pressure, record.contactID, record.sampleSequence,
                 (unsigned long long)_inputLogSequence);
    }
    if (!sent) {
        _inputLabel.text = [NSString stringWithFormat:
            @"触控桥离线 · %@ · errno=%d", phase, sendError];
        [_metalView setMacWSInputEnabled:NO reason:@"触控桥连接已中断"];
        [self refreshStatus];
    } else if (_streamMode == MacWSStreamModeFullscreen &&
               (record.kind == MacWSInputKindTap ||
                record.kind == MacWSInputKindSecondaryTap ||
                record.kind == MacWSInputKindTouchUp)) {
        // A global click can make another real AppKit window key. Refresh the
        // catalog at two bounded settlement points so subsequent keyboard and
        // gesture records follow that owner. This is event-driven, not a
        // frame-time poll.
        for (NSNumber *delay in @[@80, @280]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         delay.longLongValue * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (self->_streamMode == MacWSStreamModeFullscreen)
                    [self->_metalView requestStreamWindowList];
            });
        }
    }
}

- (void)metalView:(MacWSMetalView *)view
    windowConfigurationWasConstrainedToLogicalSize:(CGSize)appliedSize
                                      requestedSize:(CGSize)requestedSize {
    if (view != _metalView || _streamMode != MacWSStreamModeWindow ||
        _windowID == 0 || appliedSize.width <= 0.0 ||
        appliedSize.height <= 0.0) return;
    _windowPreferredSize = appliedSize;
    MacWSRememberSceneBinding(self.view.window.windowScene.session,
                              [self streamRestorationActivity]);
    // Runtime-confirmed by MacWSHost.log on 2026-09-08: unqualified feedback
    // caused Scene geometry -> ConfigureWindow -> constrained AppKit geometry
    // -> Scene geometry loops. The Metal view now marks this specific
    // AppKit->Scene transaction and suppresses only its reciprocal configure,
    // allowing the iOS window to follow the real constrained result without
    // reintroducing that oscillation.
    MacWSDiagnosticLog(@"window-size constrained-follow window=%u pid=%d requested-logical=%.1fx%.1f applied-logical=%.1fx%.1f",
             _windowID, _windowOwnerPID, requestedSize.width,
             requestedSize.height, appliedSize.width, appliedSize.height);
    [self followNativeSceneSizeForAppliedLogicalSize:appliedSize
                                              reason:@"appkit-constrained"];
}
@end

// Hardware keyboard UIPressesEvents always enter UIWindow before UIKit chooses
// a first responder. Route them at that stable public boundary while the macOS
// workspace is the active UI. The former MTKView-only pressesBegan: path had a
// responder ownership precondition even though this app intentionally moves
// first responder among the Metal view, controls, restored Scenes and a hidden
// keyboard proxy. Returning to UIKit while an actual Host text field owns the
// responder preserves native typing; merely showing the control panel does not
// take the macOS keyboard route away. A forwarded event is consumed exactly
// once so MTKView's responder fallback cannot duplicate it.
@interface MacWSWorkspaceWindow : UIWindow
@end

@implementation MacWSWorkspaceWindow
- (void)becomeKeyWindow {
    [super becomeKeyWindow];
    // This is Scene-local, not application-global key state. The evaluator
    // notification is the primary focus edge; this is only an initial-window
    // fallback, rechecked against the real application-key window.
    UIViewController *root = self.rootViewController;
    if ([root isKindOfClass:MacWSViewController.class]) {
        [(MacWSViewController *)root
            synchronizeMacWindowFocusWithReason:@"window-became-key"];
    }
}

- (void)sendEvent:(UIEvent *)event {
    UIViewController *root = self.rootViewController;
    if ([root isKindOfClass:MacWSViewController.class])
        [(MacWSViewController *)root observeHardwareModifiersForEvent:event];
    if ([event isKindOfClass:UIPressesEvent.class]) {
        UIViewController *root = self.rootViewController;
        if ([root isKindOfClass:MacWSViewController.class] &&
            [(MacWSViewController *)root
                forwardHardwarePressEvent:(UIPressesEvent *)event])
            return;
    }
    [super sendEvent:event];
}
- (void)resignKeyWindow {
    UIViewController *root = self.rootViewController;
    if ([root isKindOfClass:MacWSViewController.class])
        [(MacWSViewController *)root releaseHardwareKeyboardState];
    [super resignKeyWindow];
}
@end

static NSUserActivity *MacWSLiveRestorationActivity(UIScene *scene) {
    if (![scene isKindOfClass:UIWindowScene.class])
        return scene.session.stateRestorationActivity;
    UIViewController *root = ((UIWindowScene *)scene).windows.firstObject
        .rootViewController;
    if ([root isKindOfClass:MacWSViewController.class])
        return [(MacWSViewController *)root streamRestorationActivity];
    return scene.session.stateRestorationActivity;
}

static MacWSViewController *MacWSPerformanceControllerForTargetPID(
        int32_t targetPID, MacWSViewController *fallback) {
    if (targetPID <= 1) return fallback;
    MacWSViewController *fullscreenCandidate = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateBackground ||
            scene.activationState == UISceneActivationStateUnattached)
            continue;
        MacWSViewController *controller = nil;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window.rootViewController
                    isKindOfClass:MacWSViewController.class]) {
                controller = (MacWSViewController *)window.rootViewController;
                break;
            }
        }
        if (!controller) continue;
        NSDictionary *binding = controller.streamRestorationActivity.userInfo;
        if ([binding[@"owner_pid"] intValue] == targetPID)
            return controller;
        if ([binding[@"mode"] unsignedIntValue] ==
                MacWSStreamModeFullscreen && !fullscreenCandidate)
            fullscreenCandidate = controller;
    }
    // A fullscreen workspace can profile any focused child process and does
    // not have a fixed owner_pid binding. Prefer that visible controller when
    // no exact per-window Scene exists; otherwise preserve the URL receiver's
    // historical behavior.
    return fullscreenCandidate ?: fallback;
}

static void MacWSPruneDeadWindowSceneSessions(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    for (UISceneSession *session in [application.openSessions copy]) {
        NSUserActivity *activity = session.stateRestorationActivity;
        MacWSViewController *controller = nil;
        for (UIScene *scene in application.connectedScenes) {
            if (scene.session == session) {
                activity = MacWSLiveRestorationActivity(scene);
                if ([scene isKindOfClass:UIWindowScene.class]) {
                    UIViewController *root = ((UIWindowScene *)scene)
                        .windows.firstObject.rootViewController;
                    if ([root isKindOfClass:MacWSViewController.class])
                        controller = (MacWSViewController *)root;
                }
                break;
            }
        }
        NSDictionary *info = activity.userInfo;
        uint32_t windowID = 0;
        int32_t ownerPID = 0;
        if (!MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, NULL))
            continue;
        errno = 0;
        if (kill(ownerPID, 0) == 0 || errno != ESRCH) continue;
        if ([info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen &&
            [controller detachMissingWorkspaceReturnOwnerPID:ownerPID
                                                     windowID:windowID]) {
            continue;
        }
        if (controller && [info[@"mode"] unsignedIntValue] ==
                MacWSStreamModeWindow) {
            // Connected windows share the same two-observation retirement
            // path, including its in-flight successor-Scene protection.
            [controller requestWindowLifetimeReconciliation];
            continue;
        }
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
            continue;
        [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
        MacWSLog(@"runtime-confirmed stale-scene owner-missing id=%@ pid=%d window=%u",
                 identifier, ownerPID, windowID);
        [application requestSceneSessionDestruction:session options:nil
            errorHandler:^(NSError *error) {
                [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
                MacWSLog(@"stale-scene destruction failed id=%@ error=%@",
                         identifier, error);
            }];
    }
}

static void MacWSPruneDormantWorkspaceSessions(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    for (UISceneSession *session in [application.openSessions copy]) {
        NSUserActivity *activity = session.stateRestorationActivity;
        UIScene *connectedScene = nil;
        for (UIScene *scene in application.connectedScenes) {
            if (scene.session != session) continue;
            connectedScene = scene;
            activity = MacWSLiveRestorationActivity(scene);
            break;
        }
        // FrontBoard can retain restoration metadata after its corresponding
        // scene handle has already disappeared. Public destruction returns
        // SBApplicationSupportService/2 for those metadata-only entries, so
        // leave them to UIKit's persistence cleanup and prune only live,
        // dormant workspace Scenes.
        if (!connectedScene) continue;
        NSDictionary *info = activity.userInfo;
        BOOL ownsWindow = MacWSSceneOwnedWindowFields(
            info, NULL, NULL, NULL);
        BOOL fullscreenWorkspace = MacWSSceneIsFullscreenWorkspace(info);
        if (ownsWindow || fullscreenWorkspace ||
            (connectedScene && connectedScene.activationState ==
                UISceneActivationStateForegroundActive)) continue;
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
            continue;
        [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
        MacWSLog(@"workspace-scene-prune id=%@ state=%ld",
                 identifier, (long)connectedScene.activationState);
        [application requestSceneSessionDestruction:session options:nil
            errorHandler:^(NSError *error) {
                [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
                MacWSLog(@"workspace-scene-prune failed id=%@ error=%@",
                         identifier, error);
            }];
    }
}

static void MacWSScheduleSingleSceneWindowingEnforcement(NSUInteger attempt) {
    MacWSIndependentWindowingState state =
        MacWSCurrentIndependentWindowingState(NULL);
    if (state == MacWSIndependentWindowingActive) return;
    if (state == MacWSIndependentWindowingUnknown) {
        if (attempt < 12) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSScheduleSingleSceneWindowingEnforcement(attempt + 1);
            });
        } else {
            MacWSLog(@"single-scene enforcement deferred reason=chamois-state-unknown connected=%lu open=%lu",
                (unsigned long)UIApplication.sharedApplication.connectedScenes.count,
                (unsigned long)UIApplication.sharedApplication.openSessions.count);
        }
        return;
    }
    if (state != MacWSIndependentWindowingInactive) return;

    UIApplication *application = UIApplication.sharedApplication;
    UIWindowScene *keeper = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window respondsToSelector:@selector(_isApplicationKeyWindow)] &&
                [window _isApplicationKeyWindow]) {
                keeper = (UIWindowScene *)scene;
                break;
            }
        }
        if (keeper) break;
    }
    if (!keeper) {
        for (UIScene *scene in application.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                keeper = (UIWindowScene *)scene;
                break;
            }
        }
    }
    if (!keeper) {
        for (UIScene *scene in application.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) {
                keeper = (UIWindowScene *)scene;
                break;
            }
        }
    }
    if (!keeper || application.openSessions.count <= 1) return;

    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    NSString *keeperIdentifier = keeper.session.persistentIdentifier;
    for (UISceneSession *session in [application.openSessions copy]) {
        NSString *identifier = session.persistentIdentifier;
        if ([identifier isEqualToString:keeperIdentifier] ||
            [MacWSSceneSessionsPreservingMacWindow containsObject:identifier])
            continue;
        // On a system without active Chamois UI, multiple persistent Scenes
        // are presented as Split View columns. Retire only the redundant iOS
        // container and explicitly preserve its AppKit window so it remains
        // available in the kept Scene's window picker.
        [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
        MacWSLog(@"single-scene enforcement retire=%@ keep=%@ reason=chamois-inactive",
                 identifier, keeperIdentifier);
        [application requestSceneSessionDestruction:session options:nil
            errorHandler:^(NSError *error) {
                [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
                MacWSLog(@"single-scene enforcement failed retire=%@ keep=%@ error=%@",
                         identifier, keeperIdentifier, error);
            }];
    }
}

static NSString *MacWSSceneWindowIdentity(NSUserActivity *activity) {
    NSDictionary *info = activity.userInfo;
    int32_t ownerPID = 0;
    uint32_t windowID = 0, groupID = 0;
    if (!MacWSSceneOwnedWindowFields(info, &ownerPID, &windowID, &groupID))
        return nil;
    return MacWSWindowIdentity(ownerPID, windowID, groupID);
}

static NSInteger MacWSSceneRetentionRank(UIScene *scene) {
    switch (scene.activationState) {
        case UISceneActivationStateForegroundActive: return 0;
        case UISceneActivationStateForegroundInactive: return 1;
        case UISceneActivationStateBackground: return 2;
        case UISceneActivationStateUnattached: return 3;
    }
    return 4;
}

static void MacWSDeduplicateWindowScenes(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableDictionary<NSString *, NSMutableArray<UIScene *> *> *groups =
        [NSMutableDictionary dictionary];
    for (UIScene *scene in application.connectedScenes) {
        NSString *identity = MacWSSceneWindowIdentity(
            MacWSLiveRestorationActivity(scene));
        if (!identity) continue;
        if (!groups[identity]) groups[identity] = [NSMutableArray array];
        [groups[identity] addObject:scene];
    }
    if (!MacWSSceneSessionsPreservingMacWindow)
        MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
    for (NSString *identity in groups) {
        NSArray<UIScene *> *duplicates = [groups[identity]
            sortedArrayUsingComparator:^NSComparisonResult(UIScene *lhs,
                                                            UIScene *rhs) {
                NSInteger leftRank = MacWSSceneRetentionRank(lhs);
                NSInteger rightRank = MacWSSceneRetentionRank(rhs);
                if (leftRank < rightRank) return NSOrderedAscending;
                if (leftRank > rightRank) return NSOrderedDescending;
                return [lhs.session.persistentIdentifier compare:
                    rhs.session.persistentIdentifier];
            }];
        if (duplicates.count <= 1) continue;
        UIScene *keeper = duplicates.firstObject;
        for (NSUInteger index = 1; index < duplicates.count; index++) {
            UISceneSession *session = duplicates[index].session;
            NSString *identifier = session.persistentIdentifier;
            if ([MacWSSceneSessionsPreservingMacWindow
                    containsObject:identifier]) continue;
            [MacWSSceneSessionsPreservingMacWindow addObject:identifier];
            MacWSLog(@"scene-deduplicate identity=%@ keep=%@ discard=%@",
                     identity, keeper.session.persistentIdentifier,
                     identifier);
            [application requestSceneSessionDestruction:session
                options:nil errorHandler:^(NSError *error) {
                    [MacWSSceneSessionsPreservingMacWindow
                        removeObject:identifier];
                    MacWSLog(@"scene-deduplicate failed id=%@ error=%@",
                             identifier, error);
                }];
        }
    }
}

@interface MacWSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation MacWSSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    NSUserActivity *activity = connectionOptions.userActivities.anyObject;
    BOOL connectionHasExactWindow =
        [activity.userInfo[@"mode"] unsignedIntValue] ==
            MacWSStreamModeWindow &&
        [activity.userInfo[@"window_id"] unsignedIntValue] != 0;
    if (!connectionHasExactWindow) {
        NSUserActivity *persisted = MacWSPersistedSceneActivity(
            session.persistentIdentifier);
        activity = persisted ?: activity ?: session.stateRestorationActivity;
        NSDictionary *info = activity.userInfo;
        BOOL emptyWorkspace =
            [info[@"mode"] unsignedIntValue] == MacWSStreamModeFullscreen &&
            [info[@"return_window_id"] unsignedIntValue] == 0;
        if (emptyWorkspace) {
            activity = MacWSRecoverOrphanedWorkspaceActivity(session) ?:
                activity;
        }
    }
    MacWSStreamMode streamMode = (MacWSStreamMode)
        [activity.userInfo[@"mode"] unsignedIntValue];
    uint32_t windowID = [activity.userInfo[@"window_id"] unsignedIntValue];
    int32_t ownerPID = (int32_t)[activity.userInfo[@"owner_pid"] intValue];
    uint32_t logicalGroupID =
        [activity.userInfo[@"logical_group_id"] unsignedIntValue];
    NSString *connectedIdentity = MacWSWindowIdentity(ownerPID, windowID, logicalGroupID);
    if (connectedIdentity)
        [MacWSSceneCreationsInFlight removeObjectForKey:connectedIdentity];
    CGSize minimumSize = CGSizeMake(
        [activity.userInfo[@"minimum_width"] doubleValue],
        [activity.userInfo[@"minimum_height"] doubleValue]);
    CGSize maximumSize = CGSizeMake(
        [activity.userInfo[@"maximum_width"] doubleValue],
        [activity.userInfo[@"maximum_height"] doubleValue]);
    CGSize preferredSize = CGSizeMake(
        [activity.userInfo[@"preferred_width"] doubleValue],
        [activity.userInfo[@"preferred_height"] doubleValue]);
    BOOL resizable = [activity.userInfo[@"resizable"] boolValue];
    BOOL fixedWidth = !resizable ||
        [activity.userInfo[@"fixed_width"] boolValue];
    BOOL fixedHeight = !resizable ||
        [activity.userInfo[@"fixed_height"] boolValue];
    if (streamMode != MacWSStreamModeWindow || windowID == 0) {
        streamMode = MacWSStreamModeFullscreen;
        windowID = 0;
        ownerPID = 0;
        logicalGroupID = 0;
        minimumSize = CGSizeZero;
        maximumSize = CGSizeZero;
        preferredSize = CGSizeZero;
        resizable = NO;
        fixedWidth = NO;
        fixedHeight = NO;
    }
    NSString *shortID = session.persistentIdentifier;
    if (shortID.length > 8) shortID = [shortID substringToIndex:8];
    NSString *requestedTitle = activity.userInfo[@"title"];
    windowScene.title = requestedTitle.length ? requestedTitle :
        [NSString stringWithFormat:@"MacWS %@", shortID];
    MacWSViewController *controller = [[MacWSViewController alloc]
        initWithSceneIdentifier:session.persistentIdentifier
                     streamMode:streamMode windowID:windowID
                       ownerPID:ownerPID logicalGroupID:logicalGroupID
                    minimumSize:minimumSize
                    maximumSize:maximumSize
                  preferredSize:preferredSize
                      resizable:resizable
                     fixedWidth:fixedWidth
                    fixedHeight:fixedHeight];
    [controller restoreWorkspaceReturnFromActivity:activity];
    self.window = [[MacWSWorkspaceWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = controller;
    // Root attachment makes the concrete FBS Scene identifier and the real
    // Host chrome available. Publish sizing policy and request exact native
    // geometry before this UIWindow contributes its first visible frame.
    CGSize publishedInitialSize = CGSizeMake(
        [activity.userInfo[@"initial_scene_width"] doubleValue],
        [activity.userInfo[@"initial_scene_height"] doubleValue]);
    CGSize publishedMinimumSize = CGSizeMake(
        [activity.userInfo[@"initial_scene_minimum_width"] doubleValue],
        [activity.userInfo[@"initial_scene_minimum_height"] doubleValue]);
    [controller prepareInitialWindowSceneGeometryForScene:windowScene
                                            initialBounds:self.window.bounds
                                     publishedInitialSize:publishedInitialSize
                                  publishedMinimumSize:publishedMinimumSize];
    [self.window makeKeyAndVisible];
    // Scene restoration can reconnect directly in fullscreen mode without
    // passing through openFullscreenWorkspace. Re-assert and log UIKit's
    // authoritative status-bar/Home-Indicator policy after the real window
    // is visible so cold launch and interactive transition share the same
    // immersive postconditions.
    [controller updateImmersivePresentation];
    // viewDidAppear starts the stream and rechecks the geometry postcondition;
    // the first native sizing transaction was already submitted above.
    MacWSRememberSceneBinding(session, [controller streamRestorationActivity]);
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller synchronizeSceneOcclusionWithReason:@"scene-connected"];
    });
    MacWSLog(@"scene-connected id=%@ role=%@ mode=%u window=%u",
             session.persistentIdentifier, session.role, streamMode, windowID);
    NSString *FBSSceneIdentifier = [windowScene respondsToSelector:
        @selector(_sceneIdentifier)] ? [windowScene _sceneIdentifier] : nil;
    MacWSLog(@"scene-geometry id=%@ fbs=%@ bounds=%.1fx%.1f preferred=%.1fx%.1f minimum=%.1fx%.1f resizable=%@",
             session.persistentIdentifier, FBSSceneIdentifier ?: @"missing",
             windowScene.coordinateSpace.bounds.size.width,
             windowScene.coordinateSpace.bounds.size.height,
             preferredSize.width, preferredSize.height, minimumSize.width,
             minimumSize.height, resizable ? @"YES" : @"NO");
    MacWSScheduleSingleSceneWindowingEnforcement(0);
    if ([activity.userInfo[@"foreground_on_connect"] boolValue]) {
        // requestSceneSessionActivation may connect the requested window but
        // leave it Background under Stage Manager. Connection is not the
        // user's postcondition: accept either visible foreground state and
        // retry only when FrontBoard actually left the Scene in background.
        MacWSEnsureRequestedSceneIsForeground(
            windowScene, activity, nil, 0);
    }
    NSString *replacedIdentifier =
        [activity.userInfo[@"replaces_session_identifier"]
            isKindOfClass:NSString.class]
        ? activity.userInfo[@"replaces_session_identifier"] : nil;
    if (replacedIdentifier.length) {
        if (!MacWSSceneSessionsPreservingMacWindow)
            MacWSSceneSessionsPreservingMacWindow = [NSMutableSet set];
        [MacWSSceneSessionsPreservingMacWindow addObject:replacedIdentifier];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UISceneSession *replacedSession = nil;
            for (UISceneSession *candidate in
                    UIApplication.sharedApplication.openSessions) {
                if ([candidate.persistentIdentifier
                        isEqualToString:replacedIdentifier]) {
                    replacedSession = candidate;
                    break;
                }
            }
            if (!replacedSession) {
                [MacWSSceneSessionsPreservingMacWindow
                    removeObject:replacedIdentifier];
                MacWSLog(@"scene-windowed-replacement old-already-gone old=%@ new=%@",
                         replacedIdentifier, session.persistentIdentifier);
                return;
            }
            MacWSSetPersistedSceneBinding(replacedIdentifier, nil);
            MacWSLog(@"scene-windowed-replacement connected old=%@ new=%@ window=%u bounds=%@",
                     replacedIdentifier, session.persistentIdentifier,
                     windowID, NSStringFromCGRect(self.window.bounds));
            [UIApplication.sharedApplication
                requestSceneSessionDestruction:replacedSession options:nil
                errorHandler:^(NSError *error) {
                    [MacWSSceneSessionsPreservingMacWindow
                        removeObject:replacedIdentifier];
                    MacWSLog(@"scene-windowed-replacement old-destruction-failed old=%@ new=%@ error=%@",
                             replacedIdentifier,
                             session.persistentIdentifier, error);
                }];
        });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSDeduplicateWindowScenes();
        });
    }
    if (connectionOptions.URLContexts.count) {
        [controller cancelBootstrapTerminal];
        NSSet<UIOpenURLContext *> *contexts = connectionOptions.URLContexts;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scene:scene openURLContexts:contexts];
        });
    }
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    (void)scene;
    // Respect iPadOS Auto-Lock. RE-confirmed in the previous MacWSHost arm64
    // build at +0x27f4c: sceneWillEnterForeground passed w2=1 to
    // setIdleTimerDisabled:. UIKit input naturally postpones Auto-Lock while
    // the workspace is in active use; an actual lock edge is handled by the
    // workspace sleep coordinator.
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    [(MacWSViewController *)self.window.rootViewController resumeSceneStream];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    MacWSLog(@"scene-became-active id=%@ state=%ld",
             scene.session.persistentIdentifier,
             (long)scene.activationState);
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    MacWSViewController *controller =
        (MacWSViewController *)self.window.rootViewController;
    [controller reassertFullscreenScenePresentation];
    // The iPadOS Scene selected by Stage Manager is the user's focus intent.
    // Propagate that one-way to the exact AppKit window instead of letting a
    // later passive macOS catalog update reactivate some other iOS Scene.
    [controller synchronizeMacWindowFocusWithReason:@"scene-became-active"];
    [controller synchronizeSceneOcclusionWithReason:@"scene-became-active"];
    [controller applyDeferredForegroundSceneSize];
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller restoreHardwareKeyboardFocusWithReason:@"scene-active"];
        [controller updateGamePointerLockPreferenceWithReason:
            @"scene-became-active"];
    });
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    MacWSViewController *controller =
        (MacWSViewController *)self.window.rootViewController;
    [controller synchronizeSceneOcclusionWithReason:@"scene-entered-background"];
    [controller updateGamePointerLockPreferenceWithReason:
        @"scene-entered-background"];
}

- (void)windowScene:(UIWindowScene *)windowScene
 didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace
       interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation
            traitCollection:(UITraitCollection *)previousTraitCollection {
    (void)windowScene;
    (void)previousCoordinateSpace;
    (void)previousInterfaceOrientation;
    (void)previousTraitCollection;
    [(MacWSViewController *)self.window.rootViewController
        sceneGeometryDidChange];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    MacWSViewController *controller =
        [self.window.rootViewController
            isKindOfClass:MacWSViewController.class]
        ? (MacWSViewController *)self.window.rootViewController : nil;
    uint32_t disconnectedWindowID =
        [controller.streamRestorationActivity.userInfo[@"window_id"]
            unsignedIntValue];
    // A disconnected Scene has no presentation authority even when its
    // AppKit window is deliberately preserved for a replacement Scene.
    // Stop it synchronously: the Catalyst drawable receiver is process-global
    // and each delivery carries one transferable IOSurface use count, so a
    // retained controller with an admitted stream can otherwise claim every
    // frame before the visible replacement window. Runtime-confirmed on
    // 2026-10-01: after the fullscreen Scene disconnected, displayd kept
    // validating owner 63374/layer 497 as mode=fullscreen-layer while the
    // visible mode=2/window=497 profile received zero direct frames.
    [controller suspendSceneStream];
    MacWSLog(@"runtime-confirmed scene-disconnect stream-suspended id=%@ window=%u",
             scene.session.persistentIdentifier,
             disconnectedWindowID);
    // Disconnect alone can be ordinary resource reclamation. Close only after
    // UIKit has actually removed the persistent session from openSessions.
    // Stream ownership and AppKit-window lifetime are separate invariants:
    // suspending above releases presentation resources but does not close the
    // preserved macOS window.
    UISceneSession *session = scene.session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if ([UIApplication.sharedApplication.openSessions containsObject:session])
            return;
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow
                containsObject:identifier]) {
            [MacWSSceneSessionsPreservingMacWindow removeObject:identifier];
            MacWSLog(@"scene-disconnect preserved id=%@ mac-window=preserved",
                     identifier);
            return;
        }
        MacWSCloseMacWindowForSceneSession(session, @"disconnect-discarded");
    });
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *context in URLContexts) {
        if (context.URL.isFileURL) {
            [(MacWSViewController *)self.window.rootViewController
                openExternalDocumentURL:context.URL];
            continue;
        }
        if (![context.URL.scheme.lowercaseString isEqualToString:@"macwshost"])
            continue;
        if ([context.URL.host isEqualToString:@"toggle-workspace"]) {
            MacWSViewController *controller =
                [self.window.rootViewController
                    isKindOfClass:MacWSViewController.class]
                    ? (MacWSViewController *)self.window.rootViewController
                    : nil;
            if (controller) [controller openFullscreenWorkspace];
            break;
        }
        if ([context.URL.host isEqualToString:@"new"]) {
            uint32_t windowID = 0;
            int32_t ownerPID = 0;
            NSString *title = nil;
            CGSize preferredSize = CGSizeZero;
            CGSize minimumSize = CGSizeZero;
            CGSize maximumSize = CGSizeZero;
            BOOL resizable = NO;
            BOOL fixedWidth = NO;
            BOOL fixedHeight = NO;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"window"])
                    windowID = item.value.intValue;
                else if ([item.name isEqualToString:@"pid"])
                    ownerPID = item.value.intValue;
                else if ([item.name isEqualToString:@"title"])
                    title = item.value;
                else if ([item.name isEqualToString:@"preferred_width"])
                    preferredSize.width = item.value.doubleValue;
                else if ([item.name isEqualToString:@"preferred_height"])
                    preferredSize.height = item.value.doubleValue;
                else if ([item.name isEqualToString:@"minimum_width"])
                    minimumSize.width = item.value.doubleValue;
                else if ([item.name isEqualToString:@"minimum_height"])
                    minimumSize.height = item.value.doubleValue;
                else if ([item.name isEqualToString:@"maximum_width"])
                    maximumSize.width = item.value.doubleValue;
                else if ([item.name isEqualToString:@"maximum_height"])
                    maximumSize.height = item.value.doubleValue;
                else if ([item.name isEqualToString:@"resizable"])
                    resizable = item.value.boolValue;
                else if ([item.name isEqualToString:@"fixed_width"])
                    fixedWidth = item.value.boolValue;
                else if ([item.name isEqualToString:@"fixed_height"])
                    fixedHeight = item.value.boolValue;
            }
            MacWSViewController *controller =
                [self.window.rootViewController
                    isKindOfClass:MacWSViewController.class]
                    ? (MacWSViewController *)self.window.rootViewController
                    : nil;
            if ([controller isFullscreenWorkspace] && windowID != 0 &&
                ownerPID > 1) {
                [controller activateMacWindowIDInFullscreenWorkspace:windowID
                    ownerPID:ownerPID title:title];
                break;
            }
            MacWSRequestNewScene(scene, windowID, ownerPID, 0,
                                 preferredSize, minimumSize, maximumSize, resizable,
                                 fixedWidth, fixedHeight, title, YES,
                                 ^(NSError *error) {
                if ([error.domain isEqualToString:@"FBSWorkspaceErrorDomain"] &&
                    error.code == 2 && windowID != 0 && ownerPID > 1) {
                    MacWSViewController *controller =
                        (MacWSViewController *)self.window.rootViewController;
                    [controller openWindowIDInCurrentScene:windowID
                        ownerPID:ownerPID logicalGroupID:0 title:title
                        reason:@"iPadOS 暂未接受新窗口，已在当前窗口中打开；启用台前调度后可并排组织多个 macOS 窗口。"];
                }
            });
            break;
        }
        if ([context.URL.host isEqualToString:@"test-input"]) {
            // Explicit transport diagnostic. Query parameters allow two-point
            // cursor A/Bs or a complete down/move/up transaction without
            // fabricating UIKit touches:
            // macwshost://test-input?kind=down&x=1194&y=834&w=2388&h=1668
            uint32_t frameWidth = 2388;
            uint32_t frameHeight = 1668;
            float x = 1194.0f;
            float y = 834.0f;
            float scrollX = 0.0f;
            float scrollY = 0.0f;
            NSString *scrollPhase = @"changed";
            NSString *requestedKind = @"hover";
            BOOL diagnosticDoubleTap = NO;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"x"]) x = item.value.floatValue;
                else if ([item.name isEqualToString:@"y"]) y = item.value.floatValue;
                else if ([item.name isEqualToString:@"w"]) frameWidth = item.value.intValue;
                else if ([item.name isEqualToString:@"h"]) frameHeight = item.value.intValue;
                else if ([item.name isEqualToString:@"dx"]) scrollX = item.value.floatValue;
                else if ([item.name isEqualToString:@"dy"]) scrollY = item.value.floatValue;
                else if ([item.name isEqualToString:@"phase"] && item.value.length)
                    scrollPhase = item.value.lowercaseString;
                else if ([item.name isEqualToString:@"kind"] && item.value.length)
                    requestedKind = item.value.lowercaseString;
            }
            if (frameWidth == 0) frameWidth = 2388;
            if (frameHeight == 0) frameHeight = 1668;
            x = fminf(fmaxf(x, 0.0f), frameWidth - 1.0f);
            y = fminf(fmaxf(y, 0.0f), frameHeight - 1.0f);
            MacWSInputRecord record = {
                .magic = MACWS_INPUT_MAGIC,
                .version = MACWS_INPUT_VERSION,
                .kind = MacWSInputKindHover,
                .sceneID = ((uint64_t)scene.session.persistentIdentifier.hash) &
                    ~MACWS_INPUT_WINDOW_SCENE_FLAG,
                .timestamp = CACurrentMediaTime(),
                .x = x,
                .y = y,
                .contactID = MACWS_INPUT_CONTACT_DIAGNOSTIC,
                .frameWidth = frameWidth,
                .frameHeight = frameHeight,
                .targetPID = 0,
                .source = MacWSInputSourceUnknown,
            };
            MacWSViewController *controller =
                (MacWSViewController *)self.window.rootViewController;
            uint32_t targetWindowID = (uint32_t)[[controller
                valueForKey:@"windowID"] unsignedIntValue];
            int32_t targetOwnerPID = (int32_t)[[controller
                valueForKey:@"windowOwnerPID"] intValue];
            record.targetPID = targetWindowID != 0 ? targetOwnerPID : 0;
            if (targetWindowID != 0)
                record.sceneID = MacWSInputSceneForWindow(targetWindowID, 0);
            if ([requestedKind isEqualToString:@"tap"])
                record.kind = MacWSInputKindTap;
            else if ([requestedKind isEqualToString:@"double"]) {
                // Transport-only end-to-end witness for the same two physical
                // tap records emitted by direct touch. The title bar uses the
                // native CGPostMouseEvent route, whose double-click state is
                // derived from the ordered button transitions rather than the
                // NSEvent clickCount field, so diagnostics must preserve both
                // taps instead of fabricating one clickCount=2 event.
                record.kind = MacWSInputKindTap;
                diagnosticDoubleTap = YES;
            }
            else if ([requestedKind isEqualToString:@"secondary"])
                record.kind = MacWSInputKindSecondaryTap;
            else if ([requestedKind isEqualToString:@"down"])
                record.kind = MacWSInputKindTouchDown;
            else if ([requestedKind isEqualToString:@"move"])
                record.kind = MacWSInputKindTouchMove;
            else if ([requestedKind isEqualToString:@"up"])
                record.kind = MacWSInputKindTouchUp;
            else if ([requestedKind isEqualToString:@"cancel"])
                record.kind = MacWSInputKindTouchCancel;
            else if ([requestedKind isEqualToString:@"scroll"]) {
                record.kind = MacWSInputKindScroll;
                record.pressure = scrollY;
                memcpy(&record.contactID, &scrollX, sizeof(scrollX));
                record.flags = [scrollPhase isEqualToString:@"began"]
                    ? MacWSInputFlagScrollBegan
                    : [scrollPhase isEqualToString:@"ended"]
                        ? MacWSInputFlagScrollEnded
                        : [scrollPhase isEqualToString:@"cancelled"]
                            ? MacWSInputFlagScrollCancelled
                            : MacWSInputFlagScrollChanged;
                record.source = MacWSInputSourceFinger;
            }
            // Exercise the same controller boundary as a real UIKit touch.
            // Besides transport this schedules the post-AppKit window catalog
            // refresh required when a native tab selection swaps CGWindowID.
            [controller metalView:nil emittedInput:record];
            if (diagnosticDoubleTap) {
                MacWSInputRecord secondTap = record;
                secondTap.flags |= MacWSInputFlagDoubleClick;
                secondTap.timestamp += 0.10;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              100 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    [controller metalView:nil emittedInput:secondTap];
                });
            }
            MacWSLog(@"input synthetic kind=%@ wire=%u routed-through-controller scene=%llx target=%d point=(%.2f,%.2f) frame=%ux%u",
                     requestedKind,
                     MacWSInputWireVersionForKind(record.kind),
                     record.sceneID, record.targetPID,
                     record.x, record.y, record.frameWidth,
                     record.frameHeight);
            break;
        }
        if ([context.URL.host isEqualToString:@"test-drag-source"]) {
            MacWSViewController *controller =
                (MacWSViewController *)self.window.rootViewController;
            MacWSMetalView *metalView = [controller valueForKey:@"metalView"];
            MacWSInteropClient *interop = [controller valueForKey:@"interopClient"];
            CGFloat x = CGRectGetMidX(metalView.bounds);
            CGFloat y = CGRectGetMidY(metalView.bounds);
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"x"]) x = item.value.doubleValue;
                else if ([item.name isEqualToString:@"y"])
                    y = item.value.doubleValue;
            }
            CGPoint point = CGPointMake(x, y);
            uint64_t before = [interop macOSDragPasteboardChangeCount];
            BOOL began = [metalView beginInteropDragProbeAtViewPoint:point];
            if (began) [metalView finishInteropDragProbeCancelled:YES];
            NSArray<NSURL *> *stagedURLs = nil;
            NSArray<NSItemProvider *> *providers = began ? [interop
                macOSDragItemProvidersAfterChangeCount:before
                                      waitMilliseconds:500
                                            stagedURLs:&stagedURLs] : @[];
            NSMutableArray *types = [NSMutableArray array];
            for (NSItemProvider *provider in providers)
                [types addObject:[provider.registeredTypeIdentifiers
                    componentsJoinedByString:@","]];
            NSItemProvider *probeProvider = providers.firstObject;
            NSString *probeType = nil;
            for (NSString *type in probeProvider.registeredTypeIdentifiers) {
                if ([type isEqualToString:UTTypeFileURL.identifier] ||
                    [type isEqualToString:UTTypeURL.identifier] ||
                    [type hasPrefix:@"com.apple.finder."]) continue;
                probeType = type;
                break;
            }
            if (probeType.length) {
                [probeProvider loadFileRepresentationForTypeIdentifier:probeType
                    completionHandler:^(NSURL *url, NSError *providerError) {
                        NSError *readError = nil;
                        NSData *data = url ? [NSData dataWithContentsOfURL:url
                            options:NSDataReadingMappedIfSafe error:&readError] : nil;
                        MacWSLog(@"interop-drag-source-load type=%@ file=%@ bytes=%lu error=%@",
                            probeType, url.lastPathComponent ?: @"(nil)",
                            (unsigned long)data.length,
                            providerError ?: readError ?: @"nil");
                    }];
            }
            MacWSLog(@"interop-drag-source-probe window=%u pid=%d point=(%.1f,%.1f) before=%llu began=%@ providers=%lu urls=%lu types=%@",
                metalView.targetWindowID, metalView.targetPID, x, y,
                (unsigned long long)before, began ? @"YES" : @"NO",
                (unsigned long)providers.count,
                (unsigned long)stagedURLs.count,
                [types componentsJoinedByString:@" | "]);
            break;
        }
        if ([context.URL.host isEqualToString:@"test-catalyst-drawable"]) {
            MacWSViewController *controller =
                (MacWSViewController *)self.window.rootViewController;
            MacWSMetalView *metalView = [controller valueForKey:@"metalView"];
            int32_t ownerPID = metalView.targetPID;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"pid"] && item.value.intValue > 1)
                    ownerPID = item.value.intValue;
            }
            NSError *error = nil;
            NSString *path = [metalView exportCatalystDrawableProbeForPID:
                ownerPID error:&error];
            MacWSLog(@"test-catalyst-drawable pid=%d path=%@ error=%@",
                     ownerPID, path ?: @"", error ?: @"nil");
            break;
        }
        NSString *host = context.URL.host ?: @"status";
        if ([host isEqualToString:@"performance-reset"]) {
            int32_t targetPID = 0;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"pid"] &&
                    item.value.intValue > 1) {
                    targetPID = item.value.intValue;
                    break;
                }
            }
            MacWSViewController *fallback =
                [self.window.rootViewController
                    isKindOfClass:MacWSViewController.class]
                ? (MacWSViewController *)self.window.rootViewController : nil;
            MacWSViewController *controller =
                MacWSPerformanceControllerForTargetPID(targetPID, fallback);
            [controller resetPerformanceMeasurementForTargetPID:targetPID];
            break;
        }
        if ([host isEqualToString:@"performance-snapshot"]) {
            int32_t targetPID = 0;
            NSURLComponents *components = [NSURLComponents
                componentsWithURL:context.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"pid"] &&
                    item.value.intValue > 1) {
                    targetPID = item.value.intValue;
                    break;
                }
            }
            MacWSViewController *fallback =
                [self.window.rootViewController
                    isKindOfClass:MacWSViewController.class]
                ? (MacWSViewController *)self.window.rootViewController : nil;
            MacWSViewController *controller =
                MacWSPerformanceControllerForTargetPID(targetPID, fallback);
            [controller performURLAction:@"performance-snapshot"];
            break;
        }
        if ([@[@"status", @"start", @"start-experimental", @"stop",
               @"glassdemo", @"terminal", @"vscode", @"activity-monitor", @"finder",
               @"system-settings", @"maps", @"weather", @"sublime", @"steam",
               @"amadine", @"word", @"excel",
               @"powerpoint", @"asphalt",
               @"recover", @"repair", @"repair-desktop", @"capture",
               @"retina-standard", @"retina-larger",
               @"test-open-file", @"test-quit", @"test-pasteboard-write",
               @"test-pasteboard-abstract-text",
               @"test-pasteboard-read", @"test-drag-snapshot",
               @"test-drop-file", @"test-drop-data",
               @"test-software-toolbar-hit", @"fullscreen",
               @"enter-workspace", @"exit-workspace",
               @"close-window",
               @"screenshot-ui", @"screenshot-automation",
               @"screenshot-rendered",
               @"screenshot-screen", @"screenshot-base",
               @"screenshot-layers",
               @"performance-snapshot", @"performance-reset",
               @"performance-gesture-suite", @"performance-gesture-tap",
               @"performance-gesture-tap-burst",
               @"performance-gesture-double-tap",
               @"performance-gesture-right-tap",
               @"performance-gesture-hover",
               @"performance-gesture-drag",
               @"performance-gesture-window-drag",
               @"performance-gesture-long-drag",
               @"performance-gesture-scroll",
               @"performance-gesture-scroll-momentum",
               @"performance-gesture-magnify",
               @"performance-gesture-three-up",
               @"performance-gesture-three-down",
               @"performance-gesture-three-left",
               @"performance-gesture-three-right",
               @"performance-gesture-mission-select",
               @"performance-hud-off", @"performance-hud-compact",
               @"performance-hud-full", @"system-performance-hud-on",
               @"system-performance-hud-off",
               @"input-direct", @"input-trackpad", @"input-game",
               @"hide-controls", @"show-controls"]
              containsObject:host]) {
            MacWSViewController *controller = (MacWSViewController *)self.window.rootViewController;
            [controller performURLAction:host];
            break;
        }
    }
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    MacWSViewController *controller =
        (MacWSViewController *)self.window.rootViewController;
    NSUserActivity *activity = [controller streamRestorationActivity];
    MacWSRememberSceneBinding(scene.session, activity);
    return activity;
}
@end

@interface MacWSAppDelegate : UIResponder <UIApplicationDelegate>
@end

extern void MacWSRunIOSClearReference(void);

@implementation MacWSAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)launchOptions;
    id<MTLDevice> nativeDevice = MTLCreateSystemDefaultDevice();
    MacWSLog(@"launched native-device=%@ supportsMultiple=%@ "
             "display-transport=IOSurface legacy-mmap=%@ frame-path=%@",
             nativeDevice.name,
             application.supportsMultipleScenes ? @"YES" : @"NO",
             MacWSLegacyFramebufferFallbackEnabled() ? @"enabled" : @"disabled",
             MacWSFramePath);
    MacWSLogMetalRegistryState();
    MacWSInstallCatalystLaunchCoordinator();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        MacWSPruneDeadWindowSceneSessions();
        MacWSPruneDormantWorkspaceSessions();
        MacWSScheduleSingleSceneWindowingEnforcement(0);
    });
    // Diagnostic-only native AGX reference.  Keeping this behind a sentinel
    // lets the established, FrontBoard-launched host provide the foreground
    // GPU context needed for a trustworthy iOS command-ABI capture without
    // changing normal host startup or its scene lifecycle.
    if (access("/tmp/iosclear_run", F_OK) == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            MacWSLog(@"IOSCLEAR reference requested by sentinel");
            MacWSRunIOSClearReference();
        });
    }
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                    options:(UISceneConnectionOptions *)options {
    (void)application;
    (void)options;
    UISceneConfiguration *configuration =
        [UISceneConfiguration configurationWithName:@"MacWS Window"
                                        sessionRole:connectingSceneSession.role];
    configuration.sceneClass = UIWindowScene.class;
    configuration.delegateClass = MacWSSceneDelegate.class;
    return configuration;
}

- (void)application:(UIApplication *)application
    didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    (void)application;
    for (UISceneSession *session in sceneSessions) {
        NSString *identifier = session.persistentIdentifier;
        if ([MacWSSceneSessionsPreservingMacWindow
                containsObject:identifier]) {
            [MacWSSceneBindings removeObjectForKey:identifier];
            MacWSSetPersistedSceneBinding(identifier, nil);
            MacWSLog(@"scene-discard duplicate-only id=%@ mac-window=preserved",
                     identifier);
            continue;
        }
        MacWSCloseMacWindowForSceneSession(session, @"did-discard");
    }
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass(MacWSAppDelegate.class));
    }
}
