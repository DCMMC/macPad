@import Foundation;
@import UIKit;
@import Darwin;

#import <objc/message.h>
#import <objc/runtime.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <notify.h>
#include "../include/macws_resize_gesture.h"
#include "../include/macws_switcher_selection.h"
#include "../include/macws_diagnostics_policy.h"
#include "../include/macws_windowing_notify.h"

// Source-confirmed against TrollPad 1.3 and RE-confirmed against the target
// iPadOS 16.3.1 SpringBoard: SBSwitcherChamoisLayoutAttributes stores the
// width/height candidate arrays consumed by SBDisplayItemLayoutGrid.  Keep the
// system's original maximum and every original candidate, add modest 10-point
// fallback intermediates beginning at TrollPad's source-confirmed 150-point
// floor, and add the exact size proposed by the current Host transaction.
//
// The grid getters are expanded only while the real
// SBItemResizeGestureSwitcherModifier is synchronously resolving the selected
// com.macwsguide.host item.  Every setter stores Apple's untouched arrays and
// every non-Host lookup returns them untouched, so ordinary iPadOS apps retain
// their stock size presets. Final Scene geometry still goes through
// SpringBoard's nearest-grid, bounds and transition validation; no UIWindow
// transform or validation bypass is involved.

static const char *const MacWSDenseGridDisabled =
    "/tmp/com.macwsguide.dense-grid.disabled";
static CFStringRef const MacWSRequestFullscreenNotification =
    CFSTR("com.macwsguide.windowing.request-fullscreen");
static CFStringRef const MacWSRequestResizeNotification =
    CFSTR("com.macwsguide.windowing.request-resize");
static CFStringRef const MacWSRequestInitialSizeNotification =
    CFSTR("com.macwsguide.windowing.request-initial-size");
static const char *const MacWSWindowingLog =
    "/var/mobile/Library/Logs/MacWSWindowing.log";
static NSString *const MacWSResizeRequestDirectory =
    @MACWS_WINDOWING_REQUEST_DIRECTORY;
static NSString *const MacWSFullscreenRequestPrefix =
    @"com.macwsguide.windowing.fullscreen-request.";
static NSString *const MacWSResizeRequestPrefix =
    @"com.macwsguide.windowing.resize-request.";
static NSString *const MacWSInitialSizeRequestPrefix =
    @"com.macwsguide.windowing.initial-size-request.";
static NSMutableSet<NSString *> *MacWSFullscreenRequestsInFlight;
static NSMutableSet<NSString *> *MacWSResizeRequestsInFlight;
// Scene resize requests can be produced faster than SpringBoard completes an
// app-layout transition.  Keep one latest nonce per exact FBS Scene so an old
// retry or an arbitrary directory enumeration order can never overwrite a
// newer AppKit geometry.
static NSMutableDictionary<NSString *, NSString *> *
    MacWSLatestResizeNonceByScene;
// Exact per-Scene AppKit sizing policy published by MacWSHost. This remains
// inside SpringBoard so the real Stage Manager resize gesture can quantize or
// spring back before it submits geometry to the application. Keys are FBS
// Scene identifiers, never bundle-wide policy.
static NSMutableDictionary<NSString *, NSDictionary *> *
    MacWSResizePolicyByScene;
// Last authoritative exact size for each Host Scene. SpringBoard may create a
// replacement SBAppLayout whose attributes have already been re-quantized
// while adding/removing another window; keeping the prior per-Scene value
// prevents that derived layout from becoming the new source of truth. The
// value is updated only by a Host resize request, a real Host resize gesture,
// or the first observed model after this SpringBoard generation starts.
static NSMutableDictionary<NSString *, NSValue *> *
    MacWSStableModelSizeByScene;
// Native floating-Dock behavior assertions retained only while an exact Host
// Scene cannot fit between the standard Stage Manager margins and the Dock.
// The assertion object owns registration/invalidation with
// SBFloatingDockController; keys are FBS Scene identifiers.
static NSMutableDictionary<NSString *, id> *MacWSDockYieldAssertionByScene;
// `-invalidateWithCompletion:` is asynchronous. Keep the assertion strongly
// retained until that completion runs; dropping the dictionary entry first
// allowed a resize gesture to create a second assertion while the first one
// was still unwinding, and sometimes left the Dock hidden after the final
// window size once the local strong reference went away.
static NSMutableSet<NSString *> *MacWSDockYieldReleaseInFlightScenes;
// Bind an asynchronous invalidation to the exact assertion generation. A
// completion that arrives after a timeout/replacement must not clear the
// replacement's release state.
static NSMutableDictionary<NSString *, id> *
    MacWSDockYieldReleaseAssertionByScene;
// A gesture can cross back above the coexistence threshold while an earlier
// release is in flight. Record the latest geometry decision so completion can
// reassert native Dock yield instead of publishing a stale visible-Dock state.
static NSMutableSet<NSString *> *MacWSDockYieldWantedScenes;
// Geometry from the last pass where SpringBoard reported a visible Dock.
// Once our assertion wins, subsequent passes report a zero Dock height; retain
// the former exclusion so a later shrink can release the assertion exactly
// when the full native Dock + margins fit again. Bounds are stored too so a
// rotation never reuses stale portrait/landscape geometry.
static NSMutableDictionary<NSString *, NSDictionary *> *
    MacWSDockYieldGeometryByScene;
// Presentation owns whether AppKit geometry applies. A workspace still uses
// the same iPadOS Scene, but no longer presents one fixed AppKit window.
// Keep the transition timestamp so delayed window requests cannot reattach
// the old policy after the fullscreen transaction has begun.
static NSMutableDictionary<NSString *, NSNumber *> *MacWSWorkspaceSinceByScene;
// SpringBoard's gesture modifier and layout-grid calls are synchronous on its
// main thread.  This unsafe reference is live only inside handleGestureEvent:
// and is restored before that method returns.
static __unsafe_unretained id MacWSActiveResizeGestureModifier;
static __unsafe_unretained NSDictionary *MacWSActiveDenseGridPolicy;
// Exact proposal for the currently executing Host-only layout-grid lookup.
// Adding this one width and height to Apple's candidates makes the interaction
// effectively continuous without materializing a million-entry 1pt Cartesian
// grid. It is saved/restored on the same synchronous SpringBoard main-thread
// stack as the policy and is never populated for a stock application.
static CGSize MacWSActiveDenseGridProposal;
static NSUInteger MacWSDenseGridScopeDepth;
// A frame calculation may first calculate the entire stage, then recurse
// through a different (lower) selector for each item. A synchronous call stack
// is therefore NOT an item-identity boundary. The group scope carries no item
// policy; only the lower per-item frame scope may apply a Scene's fixed axes.
// RE-confirmed: SpringBoard 20D67 auto-layout at 0x1c78b50d0 computes the stage
// maximum at 0x1c78b527c and calls the per-item method at 0x1c78b5408/590c.
static NSUInteger MacWSGroupLayoutScopeDepth;
static __unsafe_unretained id MacWSGroupResizeGestureModifier;
static NSUInteger MacWSItemLayoutScopeDepth;
static NSString *MacWSActiveLayoutSceneIdentifier;
static NSUInteger MacWSInitialLayoutScopeDepth;
static BOOL MacWSInitialGridObserved;
static char MacWSLayoutGridLastHostScopeAssociationKey;
static char MacWSLayoutGridHostPolicyAssociationKey;
static char MacWSResizeGestureNotificationKey;

// RE-confirmed via SpringBoard 16.3.1
// -[SBItemResizeGestureSwitcherModifier
// _responseForSceneSizeUpdateToSize:center:sceneUpdatesOnly:] at
// 0x1c79cfaf4. _SBDisplayItemAttributedSizeInfer returns the opaque 56-byte
// value passed to -attributesByModifyingAttributedSize:. Keep the value
// opaque so this bridge follows the real ABI without inventing field
// semantics.
typedef struct {
    uint64_t words[7];
} MacWSDisplayItemAttributedSize;

typedef MacWSDisplayItemAttributedSize (*MacWSInferAttributedSizeFn)(
    CGSize proposedSize, CGRect containerBounds, CGSize defaultWindowSize,
    CGFloat screenEdgePadding);
typedef NSUInteger (*MacWSSizingPolicyFn)(NSUInteger supportedPolicies);

static CGPoint MacWSHostCenterAvoidingFloatingDock(
    CGPoint center, CGSize size, NSString *sceneIdentifier);
static id MacWSAppLayoutItemForRole(id appLayout, NSInteger layoutRole);
static void MacWSObserveChamoisWindowingState(BOOL active);
static void
MacWSReleaseFloatingDockYield(NSString *sceneIdentifier, NSString *reason);

static BOOL MacWSWindowingDiagnosticsEnabled(void) {
    static dispatch_once_t once;
    static BOOL enabled;
    dispatch_once(&once, ^{
        enabled = MacWSDiagnosticSwitchEnabled(
            getenv("MACWS_WINDOWING_DIAGNOSTICS"));
    });
    return enabled;
}

static void MacWSWindowingWriteDiagnosticLine(NSString *line) {
    int fd = open(MacWSWindowingLog,
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    struct timespec now = {0};
    clock_gettime(CLOCK_REALTIME, &now);
    dprintf(fd, "%lld.%03lld %s\n", (long long)now.tv_sec,
            (long long)(now.tv_nsec / 1000000), line.UTF8String ?: "");
    close(fd);
}

// The resize transaction/result files are functional and remain unconditional.
// Only human-readable traces and their argument construction are opt-in.
#define MacWSWindowingLogLine(...) do { \
    if (MacWSWindowingDiagnosticsEnabled()) \
        MacWSWindowingWriteDiagnosticLine(__VA_ARGS__); \
} while (0)

static id MacWSMessageObject(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static CGSize MacWSMessageSize(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector])
        return CGSizeZero;
    return ((CGSize (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static CGPoint MacWSMessagePoint(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector])
        return CGPointZero;
    return ((CGPoint (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static CGPoint MacWSMessagePointWithRect(id receiver, SEL selector,
                                         CGRect rect) {
    if (!receiver || ![receiver respondsToSelector:selector])
        return CGPointZero;
    return ((CGPoint (*)(id, SEL, CGRect))objc_msgSend)(
        receiver, selector, rect);
}

static CGRect MacWSMessageRect(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector])
        return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static CGFloat MacWSMessageFloat(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector]) return 0.0;
    return ((CGFloat (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static NSInteger MacWSMessageInteger(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static NSInteger MacWSMessageIntegerWithObject(id receiver, SEL selector,
                                               id object) {
    if (!receiver || ![receiver respondsToSelector:selector]) return 0;
    return ((NSInteger (*)(id, SEL, id))objc_msgSend)(
        receiver, selector, object);
}

// Runtime-confirmed on the target SpringBoard (2026-09-10):
// SBItemResizeGestureSwitcherModifier owns `_currentAppLayout` at +120 and
// `_selectedLayoutRole` at +128, and exposes -selectedAppLayout. Resolve the
// item through the layout's real role map so multi-window/multi-item layouts
// do not inherit another item's sizing policy.
static id MacWSResizeModifierSelectedItem(id modifier) {
    if (!modifier) return nil;
    id appLayout = MacWSMessageObject(
        modifier, NSSelectorFromString(@"selectedAppLayout"));
    Class modifierClass = object_getClass(modifier);
    Ivar roleIvar = modifierClass
        ? class_getInstanceVariable(modifierClass, "_selectedLayoutRole")
        : NULL;
    if (!appLayout || !roleIvar) return nil;
    NSInteger selectedRole = *(NSInteger *)(
        (uint8_t *)(__bridge void *)modifier + ivar_getOffset(roleIvar));
    NSArray *items = MacWSMessageObject(
        appLayout, NSSelectorFromString(@"allItems"));
    SEL roleSelector = NSSelectorFromString(@"layoutRoleForItem:");
    for (id item in items) {
        if (MacWSMessageIntegerWithObject(
                appLayout, roleSelector, item) != selectedRole) continue;
        return item;
    }
    return nil;
}

static BOOL MacWSResizeModifierTargetsHost(id modifier) {
    id item = MacWSResizeModifierSelectedItem(modifier);
    NSString *bundleIdentifier = MacWSMessageObject(
        item, NSSelectorFromString(@"bundleIdentifier"));
    NSString *scene = MacWSMessageObject(
        item, NSSelectorFromString(@"uniqueIdentifier"));
    return [bundleIdentifier isEqualToString:@"com.macwsguide.host"] && scene.length > 0 &&
        !MacWSWorkspaceSinceByScene[scene];
}

static NSDictionary *MacWSResizePolicyForModifier(id modifier) {
    id item = MacWSResizeModifierSelectedItem(modifier);
    NSString *bundleIdentifier = MacWSMessageObject(
        item, NSSelectorFromString(@"bundleIdentifier"));
    if (![bundleIdentifier isEqualToString:@"com.macwsguide.host"])
        return nil;
    NSString *sceneIdentifier = MacWSMessageObject(
        item, NSSelectorFromString(@"uniqueIdentifier"));
    return sceneIdentifier.length && !MacWSWorkspaceSinceByScene[sceneIdentifier]
        ? MacWSResizePolicyByScene[sceneIdentifier] : nil;
}

static void MacWSPublishResizeGestureState(id modifier, BOOL active) {
    NSDictionary *registration = objc_getAssociatedObject(
        modifier, &MacWSResizeGestureNotificationKey);
    if (active && registration) return;
    if (!active && !registration) return;
    if (!registration) {
        id item = MacWSResizeModifierSelectedItem(modifier);
        if (![MacWSMessageObject(item, NSSelectorFromString(@"bundleIdentifier"))
                isEqualToString:@"com.macwsguide.host"]) return;
        NSString *scene = MacWSMessageObject(item, NSSelectorFromString(@"uniqueIdentifier"));
        if (!scene.length) return;
        NSString *name = [@MACWS_RESIZE_GESTURE_NOTIFICATION_PREFIX stringByAppendingString:scene];
        int token = 0;
        uint32_t status = notify_register_check(name.UTF8String, &token);
        if (status != NOTIFY_STATUS_OK) {
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"resize-gesture registration-failed scene=%@ status=%u", scene, status]);
            return;
        }
        registration = @{@"name": name, @"scene": scene, @"token": @(token)};
        objc_setAssociatedObject(modifier, &MacWSResizeGestureNotificationKey,
            registration, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    int token = [registration[@"token"] intValue];
    uint32_t status = notify_set_state(token, MacWSResizeGestureState(getpid(), active));
    if (status == NOTIFY_STATUS_OK)
        status = notify_post([registration[@"name"] UTF8String]);
    MacWSWindowingLogLine([NSString stringWithFormat:
        @"resize-gesture scene=%@ active=%@ writer=%d status=%u",
        registration[@"scene"], active ? @"YES" : @"NO", getpid(), status]);
    if (!active) {
        notify_cancel(token);
        objc_setAssociatedObject(modifier, &MacWSResizeGestureNotificationKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static id MacWSResizeModifierLayoutGrid(id modifier) {
    if (!modifier) return nil;
    Ivar gridIvar = class_getInstanceVariable(
        object_getClass(modifier), "_layoutGrid");
    return gridIvar ? object_getIvar(modifier, gridIvar) : nil;
}

// RE-confirmed via the target SpringBoard text at image offsets
// 0x31bbac..0x31be00: -[SBDisplayItemLayoutAttributesCalculator
// frameForLayoutRole:inAppLayout:containerOrientation:windowScene:] receives
// the queried layout role in x2 and the immutable SBAppLayout in x3, then
// synchronously calls the frame/grid calculator at 0x31bd9c. Resolve the item
// with that exact role instead of treating any Host item in a multi-item
// layout as the new Scene.
static id MacWSAppLayoutItemForRole(id appLayout, NSInteger layoutRole) {
    NSArray *items = MacWSMessageObject(
        appLayout, NSSelectorFromString(@"allItems"));
    SEL roleSelector = NSSelectorFromString(@"layoutRoleForItem:");
    if (![items isKindOfClass:NSArray.class] ||
        ![appLayout respondsToSelector:roleSelector]) return nil;
    for (id item in items) {
        if (MacWSMessageIntegerWithObject(
                appLayout, roleSelector, item) == layoutRole)
            return item;
    }
    return nil;
}

static BOOL MacWSMessageBool(id receiver, SEL selector) {
    if (!receiver || ![receiver respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static MacWSDisplayItemAttributedSize MacWSAttributedSizeForAttributes(
        id attributes, SEL selector) {
    MacWSDisplayItemAttributedSize value = {0};
    if ([attributes respondsToSelector:selector]) {
        value = ((MacWSDisplayItemAttributedSize (*)(id, SEL))objc_msgSend)(
            attributes, selector);
    }
    return value;
}

static BOOL MacWSAttributedSizeIsUnspecified(
        MacWSDisplayItemAttributedSize value) {
    for (NSUInteger index = 0; index < 7; index++) {
        if (value.words[index] != 0) return NO;
    }
    return YES;
}

static BOOL MacWSStableModelSize(NSString *sceneIdentifier, CGSize *sizeOut) {
    if (!sceneIdentifier.length || !sizeOut) return NO;
    NSValue *value = MacWSStableModelSizeByScene[sceneIdentifier];
    if (!value) return NO;
    CGSize size = value.CGSizeValue;
    if (!isfinite(size.width) || !isfinite(size.height) ||
        size.width < 150.0 || size.height < 150.0 ||
        size.width > 4096.0 || size.height > 4096.0) return NO;
    *sizeOut = size;
    return YES;
}

static void MacWSSetStableModelSize(NSString *sceneIdentifier, CGSize size) {
    if (!sceneIdentifier.length ||
        !isfinite(size.width) || !isfinite(size.height) ||
        size.width < 150.0 || size.height < 150.0 ||
        size.width > 4096.0 || size.height > 4096.0) return;
    if (!MacWSStableModelSizeByScene)
        MacWSStableModelSizeByScene = [NSMutableDictionary dictionary];
    MacWSStableModelSizeByScene[sceneIdentifier] = [NSValue valueWithCGSize:size];
}

// Runtime-confirmed at MacWSWindowing.log 1789059115.823 and again during
// the v38 multi-Scene trace at 1789142611.835: the immutable
// SBDisplayItemLayoutAttributes object retains the existing Scene's exact
// 445x573 model size even while the native role-2 frame calculation tries to
// place it at the stock 327x603 grid size.  Ask the object's own decoded-size
// accessor for that model value; do not infer fields from the opaque
// SBDisplayItemAttributedSize representation.
static BOOL MacWSResolvedLayoutAttributesSize(id attributes,
                                               CGRect containerBounds,
                                               CGSize defaultWindowSize,
                                               CGFloat screenEdgePadding,
                                               CGSize *sizeOut) {
    if (!attributes || !sizeOut) return NO;
    SEL sizeSelector = NSSelectorFromString(
        @"sizeInBounds:defaultSize:screenEdgePadding:");
    if (CGRectIsEmpty(containerBounds) ||
        CGSizeEqualToSize(defaultWindowSize, CGSizeZero) ||
        ![attributes respondsToSelector:sizeSelector]) return NO;
    CGSize size = ((CGSize (*)(id, SEL, CGRect, CGSize, CGFloat))objc_msgSend)(
        attributes, sizeSelector, containerBounds, defaultWindowSize,
        screenEdgePadding);
    if (!isfinite(size.width) || !isfinite(size.height) ||
        size.width < 150.0 || size.height < 150.0 ||
        size.width > 4096.0 || size.height > 4096.0) return NO;
    *sizeOut = size;
    return YES;
}

static NSString *MacWSMethodInventory(Class cls, NSArray<NSString *> *needles) {
    if (!cls) return @"class-missing";
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = NSStringFromSelector(method_getName(methods[index]));
        BOOL matches = NO;
        for (NSString *needle in needles) {
            if ([name rangeOfString:needle options:NSCaseInsensitiveSearch]
                    .location != NSNotFound) {
                matches = YES;
                break;
            }
        }
        if (matches) [names addObject:[NSString stringWithFormat:@"%@:%s",
            name, method_getTypeEncoding(methods[index]) ?: "?"]];
    }
    free(methods);
    return [names componentsJoinedByString:@" | "];
}

static id MacWSObjectIvarWithClass(id object, Class expectedClass) {
    if (!object || !expectedClass) return nil;
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (!type || type[0] != '@') continue;
            id candidate = object_getIvar(object, ivars[index]);
            if ([candidate isKindOfClass:expectedClass]) {
                free(ivars);
                return candidate;
            }
        }
        free(ivars);
    }
    return nil;
}

static id MacWSResolveFloatingDockController(void) {
    static __weak id cachedController;
    id cached = cachedController;
    if (cached) return cached;
    Class dockWindowClass = NSClassFromString(@"SBFloatingDockWindow");
    Class oldDockWindowClass = NSClassFromString(@"SBOldFloatingDockWindow");
    Class dockControllerClass = NSClassFromString(@"SBFloatingDockController");
    if (!dockControllerClass) return nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (![window isKindOfClass:dockWindowClass] &&
                ![window isKindOfClass:oldDockWindowClass]) continue;
            id root = MacWSMessageObject(
                window, NSSelectorFromString(@"floatingDockRootViewController"));
            if (!root) root = window.rootViewController;
            for (NSString *name in @[@"floatingDockController", @"delegate"]) {
                id candidate = MacWSMessageObject(
                    root, NSSelectorFromString(name));
                if ([candidate isKindOfClass:dockControllerClass]) {
                    cachedController = candidate;
                    return candidate;
                }
            }
            id candidate = MacWSObjectIvarWithClass(root, dockControllerClass);
            if (candidate) {
                cachedController = candidate;
                return candidate;
            }
        }
    }
    return nil;
}

// Diagnostic-only screen-space witness for the exact floating-Dock UIWindow.
// The display-item calculator's `bounds` and returned frame are private
// SpringBoard layout coordinates; do not assume they share the Dock window's
// screen origin.  Keep this read-only and deduplicated at the caller so a
// visible overlap can be compared against the actual UIKit geometry instead
// of compensated with a guessed margin.
static NSString *MacWSFloatingDockWindowGeometry(void) {
    Class dockWindowClass = NSClassFromString(@"SBFloatingDockWindow");
    Class oldDockWindowClass = NSClassFromString(@"SBOldFloatingDockWindow");
    NSMutableArray<NSString *> *descriptions = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (![window isKindOfClass:dockWindowClass] &&
                ![window isKindOfClass:oldDockWindowClass]) continue;
            UIView *rootView = window.rootViewController.view;
            [descriptions addObject:[NSString stringWithFormat:
                @"class=%@ frame=%@ bounds=%@ root-frame=%@ root-bounds=%@ "
                 "hidden=%@ alpha=%.3f scene-bounds=%@ screen-bounds=%@",
                NSStringFromClass(window.class),
                NSStringFromCGRect(window.frame),
                NSStringFromCGRect(window.bounds),
                NSStringFromCGRect(rootView.frame),
                NSStringFromCGRect(rootView.bounds),
                window.hidden ? @"YES" : @"NO", window.alpha,
                NSStringFromCGRect(windowScene.coordinateSpace.bounds),
                NSStringFromCGRect(windowScene.screen.bounds)]];
        }
    }
    return descriptions.count
        ? [descriptions componentsJoinedByString:@" | "] : @"none";
}

static BOOL MacWSRequestFloatingDockYield(NSString *sceneIdentifier,
                                          CGRect frame) {
    if (!sceneIdentifier.length) return NO;
    if (!MacWSDockYieldWantedScenes)
        MacWSDockYieldWantedScenes = [NSMutableSet set];
    [MacWSDockYieldWantedScenes addObject:sceneIdentifier];
    id existingAssertion =
        MacWSDockYieldAssertionByScene[sceneIdentifier];
    id controller = MacWSResolveFloatingDockController();
    SEL presentedSelector = NSSelectorFromString(@"isFloatingDockPresented");
    SEL dismissSelector = NSSelectorFromString(
        @"dismissFloatingDockIfPresentedAnimated:completionHandler:");
    if (!controller || ![controller respondsToSelector:presentedSelector] ||
        ![controller respondsToSelector:dismissSelector])
        return existingAssertion != nil;
    BOOL dockPresented = ((BOOL (*)(id, SEL))objc_msgSend)(
        controller, presentedSelector);
    if (existingAssertion) {
        // Runtime-confirmed at 1790913015.425-.1790913077: an assertion can
        // remain retained while its invalidateWithCompletion: callback never
        // arrives and the Dock has already become visible again. Retention is
        // not proof that the assertion still owns controller state. Recycle
        // that exact generation; its bounded timeout below will finish the
        // handoff if SpringBoard again omits the completion.
        if (!dockPresented) return YES;
        if ([MacWSDockYieldReleaseInFlightScenes
                containsObject:sceneIdentifier])
            return YES;
        MacWSReleaseFloatingDockYield(
            sceneIdentifier, @"assertion-lost-visible-dock-authority");
        [MacWSDockYieldWantedScenes addObject:sceneIdentifier];
        if (!MacWSDockYieldAssertionByScene[sceneIdentifier])
            return MacWSRequestFloatingDockYield(sceneIdentifier, frame);
        return YES;
    }
    if (!dockPresented) return NO;

    id activeAssertion = MacWSMessageObject(
        controller, NSSelectorFromString(@"activeAssertion"));
    Class assertionClass = NSClassFromString(@"SBFloatingDockBehaviorAssertion");
    SEL initializerSelector = NSSelectorFromString(
        @"initWithFloatingDockController:visibleProgress:animated:gesturePossible:atLevel:reason:withCompletion:");
    Method initializer = assertionClass ? class_getInstanceMethod(
        assertionClass, initializerSelector) : NULL;
    NSUInteger activeLevel = activeAssertion && [activeAssertion respondsToSelector:
        NSSelectorFromString(@"level")]
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(
            activeAssertion, NSSelectorFromString(@"level")) : 0;
    CGFloat activeProgress = activeAssertion &&
        [activeAssertion respondsToSelector:NSSelectorFromString(@"progress")]
        ? ((CGFloat (*)(id, SEL))objc_msgSend)(
            activeAssertion, NSSelectorFromString(@"progress")) : NAN;
    MacWSWindowingLogLine([NSString stringWithFormat:
        @"dock-yield-state scene=%@ active-class=%@ active-level=%lu active-progress=%.3f active=%@ assertion-methods=[%@] init-imp=%p",
        sceneIdentifier ?: @"nil",
        activeAssertion ? NSStringFromClass([activeAssertion class]) : @"nil",
        (unsigned long)activeLevel, activeProgress,
        activeAssertion ?: @"nil",
        MacWSMethodInventory(assertionClass,
            @[@"progress", @"level", @"priority", @"reason", @"gesture",
              @"animated", @"invalidate"]),
        initializer ? method_getImplementation(initializer) : NULL]);

    if (initializer) {
        NSUInteger yieldLevel = activeLevel < NSUIntegerMax
            ? activeLevel + 1 : activeLevel;
        __weak id weakController = controller;
        void (^assertionCompletion)(void) = ^{
            id strongController = weakController;
            BOOL stillPresented = strongController &&
                [strongController respondsToSelector:presentedSelector] &&
                ((BOOL (*)(id, SEL))objc_msgSend)(
                    strongController, presentedSelector);
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"dock-yield-assertion-ready scene=%@ level=%lu presented=%@",
                sceneIdentifier, (unsigned long)yieldLevel,
                stillPresented ? @"YES" : @"NO"]);
        };
        id assertion = ((id (*)(id, SEL, id, CGFloat, BOOL, BOOL,
                                NSUInteger, id, id))objc_msgSend)(
            [assertionClass alloc], initializerSelector, controller, 0.0,
            YES, YES, yieldLevel, @"MacWSHost unobscured window",
            assertionCompletion);
        if (assertion) {
            if (!MacWSDockYieldAssertionByScene)
                MacWSDockYieldAssertionByScene =
                    [NSMutableDictionary dictionary];
            MacWSDockYieldAssertionByScene[sceneIdentifier] = assertion;
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"dock-yield-request scene=%@ frame=%@ controller=%@ route=native-behavior-assertion level=%lu",
                sceneIdentifier, NSStringFromCGRect(frame),
                NSStringFromClass([controller class]),
                (unsigned long)yieldLevel]);
            return YES;
        }
    }

    // Runtime-confirmed on iPad13,6 / 20D67 at 1790868919.484: the exact
    // SBFloatingDockController is reachable from the live floating-Dock
    // window and reports presented=YES. Runtime method metadata at
    // 1790868828.705 confirms this dismissal selector and its v28@0:8B16@?20
    // ABI. Ask the native controller to transition; do not hide its UIWindow,
    // replace its view, or bypass its assertion state machine.
    __weak id weakController = controller;
    void (^completion)(void) = ^{
        id strongController = weakController;
        BOOL stillPresented = strongController &&
            [strongController respondsToSelector:presentedSelector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(
                strongController, presentedSelector);
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"dock-yield-complete scene=%@ presented=%@ route=native-dismiss",
            sceneIdentifier ?: @"nil", stillPresented ? @"YES" : @"NO"]);
    };
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(
        controller, dismissSelector, YES, completion);
    MacWSWindowingLogLine([NSString stringWithFormat:
        @"dock-yield-request scene=%@ frame=%@ controller=%@ route=native-dismiss",
        sceneIdentifier ?: @"nil", NSStringFromCGRect(frame),
        NSStringFromClass([controller class])]);
    return YES;
}

static void MacWSFinishFloatingDockYieldRelease(
        NSString *sceneIdentifier, id assertion, NSString *reason,
        NSString *completionKind) {
    if (!sceneIdentifier.length || !assertion ||
        MacWSDockYieldReleaseAssertionByScene[sceneIdentifier] != assertion)
        return;
    if (MacWSDockYieldAssertionByScene[sceneIdentifier] == assertion)
        [MacWSDockYieldAssertionByScene removeObjectForKey:sceneIdentifier];
    [MacWSDockYieldReleaseAssertionByScene
        removeObjectForKey:sceneIdentifier];
    [MacWSDockYieldReleaseInFlightScenes removeObject:sceneIdentifier];
    BOOL reassert = [MacWSDockYieldWantedScenes
        containsObject:sceneIdentifier];
    // Preserve the last visible-Dock geometry while a replacement is wanted.
    // A hidden-Dock calculator pass reports height 0 and cannot reconstruct
    // the exclusion that caused the assertion in the first place.
    if (!reassert)
        [MacWSDockYieldGeometryByScene removeObjectForKey:sceneIdentifier];
    MacWSWindowingLogLine([NSString stringWithFormat:
        @"dock-yield-released scene=%@ reason=%@ reassert=%@ completion=%@",
        sceneIdentifier, reason ?: @"unknown",
        reassert ? @"YES" : @"NO", completionKind ?: @"unknown"]);
    if (reassert)
        MacWSRequestFloatingDockYield(sceneIdentifier, CGRectZero);
}

static void MacWSReleaseFloatingDockYield(NSString *sceneIdentifier,
                                          NSString *reason) {
    [MacWSDockYieldWantedScenes removeObject:sceneIdentifier];
    id assertion = MacWSDockYieldAssertionByScene[sceneIdentifier];
    if (!assertion) return;
    if ([MacWSDockYieldReleaseInFlightScenes containsObject:sceneIdentifier])
        return;
    if (!MacWSDockYieldReleaseInFlightScenes)
        MacWSDockYieldReleaseInFlightScenes = [NSMutableSet set];
    if (!MacWSDockYieldReleaseAssertionByScene)
        MacWSDockYieldReleaseAssertionByScene =
            [NSMutableDictionary dictionary];
    [MacWSDockYieldReleaseInFlightScenes addObject:sceneIdentifier];
    MacWSDockYieldReleaseAssertionByScene[sceneIdentifier] = assertion;
    SEL selector = NSSelectorFromString(@"invalidateWithCompletion:");
    if ([assertion respondsToSelector:selector]) {
        __weak id weakAssertion = assertion;
        ((void (*)(id, SEL, id))objc_msgSend)(assertion, selector, ^{
            id invalidatedAssertion = weakAssertion;
            MacWSFinishFloatingDockYieldRelease(
                sceneIdentifier, invalidatedAssertion, reason, @"callback");
        });
        // SpringBoard can supersede an assertion and make the Dock visible
        // without invoking that assertion's asynchronous completion. Never
        // leave the Scene permanently stuck in release-in-flight. The exact
        // assertion identity makes a late callback harmless after timeout.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id invalidatedAssertion = weakAssertion;
            MacWSFinishFloatingDockYieldRelease(
                sceneIdentifier, invalidatedAssertion, reason, @"timeout");
        });
    } else if ([assertion respondsToSelector:NSSelectorFromString(@"invalidate")]) {
        ((void (*)(id, SEL))objc_msgSend)(
            assertion, NSSelectorFromString(@"invalidate"));
        if (MacWSDockYieldAssertionByScene[sceneIdentifier] == assertion)
            [MacWSDockYieldAssertionByScene
                removeObjectForKey:sceneIdentifier];
        [MacWSDockYieldReleaseInFlightScenes removeObject:sceneIdentifier];
        [MacWSDockYieldReleaseAssertionByScene
            removeObjectForKey:sceneIdentifier];
        [MacWSDockYieldGeometryByScene removeObjectForKey:sceneIdentifier];
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"dock-yield-released scene=%@ reason=%@ completion=unavailable",
            sceneIdentifier, reason ?: @"unknown"]);
    }
}

static void MacWSReleaseDockYieldsOutsideCurrentStage(void) {
    if (MacWSDockYieldAssertionByScene.count == 0) return;
    UIApplication *application = UIApplication.sharedApplication;
    id windowSceneManager = MacWSMessageObject(
        application, NSSelectorFromString(@"windowSceneManager"));
    id displayWindowScene = MacWSMessageObject(
        windowSceneManager,
        NSSelectorFromString(@"activeDisplayWindowScene"));
    id switcherController = MacWSMessageObject(
        displayWindowScene, NSSelectorFromString(@"switcherController"));
    id currentLayout = MacWSMessageObject(
        switcherController, NSSelectorFromString(@"_currentMainAppLayout"));
    // During a switcher transition SpringBoard can temporarily publish no
    // current layout. Treat that as indeterminate rather than flashing the
    // Dock back over a still-visible Host window.
    if (!currentLayout) return;
    NSMutableSet<NSString *> *visibleScenes = [NSMutableSet set];
    for (id item in MacWSMessageObject(
             currentLayout, NSSelectorFromString(@"allItems"))) {
        if (![MacWSMessageObject(item, NSSelectorFromString(@"bundleIdentifier"))
                isEqualToString:@"com.macwsguide.host"]) continue;
        NSString *scene = MacWSMessageObject(
            item, NSSelectorFromString(@"uniqueIdentifier"));
        if (scene.length) [visibleScenes addObject:scene];
    }
    for (NSString *scene in [MacWSDockYieldAssertionByScene.allKeys copy]) {
        if (![visibleScenes containsObject:scene])
            MacWSReleaseFloatingDockYield(scene, @"scene-left-current-stage");
    }
}

static NSDictionary *MacWSClaimInitialSizePolicy(id displayItem,
                                                  BOOL allowNewClaim,
                                                  NSString **pathOut) {
    NSString *bundleIdentifier = MacWSMessageObject(
        displayItem, NSSelectorFromString(@"bundleIdentifier"));
    NSString *sceneIdentifier = MacWSMessageObject(
        displayItem, NSSelectorFromString(@"uniqueIdentifier"));
    if (![bundleIdentifier isEqualToString:@"com.macwsguide.host"] ||
        sceneIdentifier.length == 0)
        return nil;

    NSDictionary *existing = MacWSResizePolicyByScene[sceneIdentifier];
    NSTimeInterval existingAge = NSDate.date.timeIntervalSince1970 -
        [existing[@"initial_claimed_at"] doubleValue];
    if (existing && isfinite(existingAge) && existingAge >= 0.0 &&
        existingAge <= 3.0)
        return existing;
    if (!allowNewClaim) return nil;

    NSArray<NSString *> *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:MacWSResizeRequestDirectory error:nil];
    NSDictionary *winner = nil;
    NSString *winnerPath = nil;
    NSTimeInterval winnerIssued = DBL_MAX;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSString *name in names) {
        if (![name hasPrefix:MacWSInitialSizeRequestPrefix] ||
            ![name hasSuffix:@".plist"]) continue;
        NSString *path = [MacWSResizeRequestDirectory
            stringByAppendingPathComponent:name];
        NSDictionary *request =
            [NSDictionary dictionaryWithContentsOfFile:path];
        NSTimeInterval issued = [request[@"issued_at"] doubleValue];
        NSTimeInterval age = now - issued;
        CGFloat width = [request[@"target_width"] doubleValue];
        CGFloat height = [request[@"target_height"] doubleValue];
        CGFloat minimumWidth = [request[@"minimum_width"] doubleValue];
        CGFloat minimumHeight = [request[@"minimum_height"] doubleValue];
        CGFloat maximumWidth = [request[@"maximum_width"] doubleValue];
        CGFloat maximumHeight = [request[@"maximum_height"] doubleValue];
        BOOL valid = [request isKindOfClass:NSDictionary.class] &&
            [request[@"bundle_identifier"]
                isEqualToString:@"com.macwsguide.host"] &&
            [request[@"activation_nonce"] isKindOfClass:NSString.class] &&
            [request[@"activation_nonce"] length] > 0 &&
            isfinite(age) && age >= -2.0 && age <= 10.0 &&
            isfinite(width) && isfinite(height) &&
            isfinite(minimumWidth) && isfinite(minimumHeight) &&
            width >= 150.0 && height >= 150.0 &&
            width <= 4096.0 && height <= 4096.0 &&
            minimumWidth >= 150.0 && minimumHeight >= 150.0 &&
            minimumWidth <= width && minimumHeight <= height &&
            isfinite(maximumWidth) && isfinite(maximumHeight) &&
            maximumWidth >= 0.0 && maximumHeight >= 0.0 &&
            maximumWidth <= 4096.0 && maximumHeight <= 4096.0 &&
            (maximumWidth == 0.0 || maximumWidth >= minimumWidth) &&
            (maximumHeight == 0.0 || maximumHeight >= minimumHeight);
        if (!valid) {
            // A malformed or expired activation request must never attach to a
            // later Host Scene merely because the bundle identifier matches.
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"initial-size discarded path=%@ age=%.3f",
                name, age]);
            continue;
        }
        // THEORY, bounded by the runtime postcondition: activation calls are
        // issued on Host's main queue, so the oldest unconsumed request should
        // correspond to SpringBoard's next new Host display item.  A mismatch
        // is detected from the concrete Scene bounds and falls back to the
        // exact-scene transaction rather than being treated as success.
        if (!winner || issued < winnerIssued) {
            winner = request;
            winnerPath = path;
            winnerIssued = issued;
        }
    }
    if (!winner) return nil;

    NSMutableDictionary *policy = [winner mutableCopy];
    policy[@"scene_identifier"] = sceneIdentifier;
    policy[@"initial_claimed_at"] = @(now);
    if (!MacWSResizePolicyByScene)
        MacWSResizePolicyByScene = [NSMutableDictionary dictionary];
    MacWSResizePolicyByScene[sceneIdentifier] = policy;
    MacWSSetStableModelSize(sceneIdentifier, CGSizeMake(
        [policy[@"target_width"] doubleValue],
        [policy[@"target_height"] doubleValue]));
    if (pathOut) *pathOut = winnerPath;
    return policy;
}

static void MacWSMessageToggleMaximization(id receiver) {
    SEL selector = NSSelectorFromString(
        @"performKeyboardShortcutAction:forBundleIdentifier:");
    ((void (*)(id, SEL, NSInteger, NSString *))objc_msgSend)(
        receiver, selector, 0x11, nil);
}

static void MacWSFinishFullscreenRequest(NSString *path, NSString *message) {
    if (message.length) MacWSWindowingLogLine(message);
    if (path.length)
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [MacWSFullscreenRequestsInFlight removeObject:path];
}

static id MacWSAppLayoutExactSceneItem(id layout,
                                       NSString *bundleIdentifier,
                                       NSString *sceneIdentifier) {
    if (!layout || bundleIdentifier.length == 0 || sceneIdentifier.length == 0)
        return nil;
    NSArray *items = MacWSMessageObject(
        layout, NSSelectorFromString(@"allItems"));
    if (![items isKindOfClass:NSArray.class]) return nil;
    for (id item in items) {
        NSString *candidateBundle = MacWSMessageObject(
            item, NSSelectorFromString(@"bundleIdentifier"));
        NSString *candidateIdentifier = MacWSMessageObject(
            item, NSSelectorFromString(@"uniqueIdentifier"));
        if ([candidateBundle isEqualToString:bundleIdentifier] &&
            [candidateIdentifier isEqualToString:sceneIdentifier]) return item;
    }
    return nil;
}

static void MacWSVerifyMaximizationPostcondition(
        id coordinator, NSString *bundleIdentifier, NSString *sceneIdentifier,
        BOOL expectedFullscreen) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        NSArray *appLayouts = MacWSMessageObject(
            coordinator, NSSelectorFromString(@"recentAppLayouts"));
        id actualLayout = nil;
        id actualItem = nil;
        for (id layout in appLayouts) {
            id item = MacWSAppLayoutExactSceneItem(
                layout, bundleIdentifier, sceneIdentifier);
            if (item) {
                actualLayout = layout;
                actualItem = item;
                break;
            }
        }
        NSInteger actualRole = MacWSMessageIntegerWithObject(
            actualLayout, NSSelectorFromString(@"layoutRoleForItem:"),
            actualItem);
        NSInteger actualCenter = MacWSMessageInteger(
            actualLayout, NSSelectorFromString(@"centerConfiguration"));
        NSInteger actualEnvironment = MacWSMessageInteger(
            actualLayout, NSSelectorFromString(@"environment"));
        NSInteger *primaryRoleAddress = (NSInteger *)dlsym(
            RTLD_DEFAULT, "SBLayoutRolePrimary");
        NSInteger *centerRoleAddress = (NSInteger *)dlsym(
            RTLD_DEFAULT, "SBLayoutRoleCenter");
        BOOL modelFound = actualLayout && actualItem && primaryRoleAddress &&
            centerRoleAddress;
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"maximization-layout-observation scene=%@ model-found=%@ expected-fullscreen=%@ role=%ld center=%ld environment=%ld primary=%ld windowed=%ld final-geometry=MacWSHost-UIKit-observation",
            sceneIdentifier, modelFound ? @"YES" : @"NO",
            expectedFullscreen ? @"YES" : @"NO", (long)actualRole,
            (long)actualCenter, (long)actualEnvironment,
            (long)(primaryRoleAddress ? *primaryRoleAddress : -1),
            (long)(centerRoleAddress ? *centerRoleAddress : -1)]);
    });
}

// RE-confirmed on iPadOS 16.3.1 SpringBoard:
// - performSwitcherKeyboardShortcutAction: at 0x1c7add0c0 maps action 0x11
//   to top-affordance action type 9.
// - SBTopAffordanceViewController's _maximizationAction handler at
//   0x1c7c1f078 sends that same action type 9, while
//   updateContextMenuWithLayoutRole:... selects the localized
//   MAXIMIZATION_ZOOM / MAXIMIZATION_UNZOOM title from the current state.
// Therefore action 0x11 is the system's maximization toggle, not an enter-only
// operation. Use it in both directions so SpringBoard owns the Primary <- ->
// Center role transaction, animation, status bar and Home Indicator. This
// does not mutate private ivars, force a condition, or skip a system check.
//
// Runtime-confirmed on the same device: activeDisplayWindowScene is the
// enclosing SBWindowScene whose identifier is com.apple.springboard.  The
// foreground app identity instead lives in the switcher content controller's
// leafAppLayoutForKeyboardFocusedScene / keyboardFocusedAppLayout.  Validate
// the request against that focused layout's SBDisplayItem uniqueIdentifier;
// +[SBDisplayItem applicationDisplayItemWithBundleIdentifier:sceneIdentifier:]
// stores the exact FBS scene identifier there (RE-confirmed at 0x1c773f33c).
// Retry briefly while a just-activated Scene acquires keyboard focus.
static void MacWSApplyFullscreenRequest(NSDictionary *request,
                                        NSString *path,
                                        NSUInteger attempt) {
    NSString *bundleIdentifier = request[@"bundle_identifier"];
    NSString *requestedIdentifier = request[@"scene_identifier"];
    NSNumber *expectedFullscreenValue = request[@"expected_fullscreen"];
    NSNumber *sourceGeometryFullscreenValue =
        request[@"source_geometry_fullscreen"];
    BOOL expectedFullscreen = expectedFullscreenValue.boolValue;
    BOOL sourceGeometryFullscreen =
        sourceGeometryFullscreenValue.boolValue;
    NSTimeInterval issuedAt = [request[@"issued_at"] doubleValue];
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - issuedAt;
    if (![bundleIdentifier isEqualToString:@"com.macwsguide.host"] ||
        ![requestedIdentifier isKindOfClass:NSString.class] ||
        ![expectedFullscreenValue isKindOfClass:NSNumber.class] ||
        ![sourceGeometryFullscreenValue isKindOfClass:NSNumber.class] ||
        requestedIdentifier.length == 0 || !isfinite(age) || age < -2.0 ||
        age > 15.0) {
        MacWSFinishFullscreenRequest(path, [NSString stringWithFormat:
            @"fullscreen-rejected path=%@ scene=%@ age=%.3f",
            path.lastPathComponent, requestedIdentifier ?: @"nil", age]);
        return;
    }

    UIApplication *application = UIApplication.sharedApplication;
    id windowSceneManager = MacWSMessageObject(
        application, NSSelectorFromString(@"windowSceneManager"));
    id activeScene = MacWSMessageObject(
        windowSceneManager,
        NSSelectorFromString(@"activeDisplayWindowScene"));
    id switcherController = MacWSMessageObject(
        activeScene, NSSelectorFromString(@"switcherController"));
    id coordinator = MacWSMessageObject(
        switcherController, NSSelectorFromString(@"switcherCoordinator"));
    id contentController = MacWSMessageObject(
        switcherController, NSSelectorFromString(@"contentViewController"));
    if (!contentController) {
        contentController = MacWSMessageObject(
            switcherController, NSSelectorFromString(@"switcherViewController"));
    }
    id focusedLayout = MacWSMessageObject(
        contentController,
        NSSelectorFromString(@"leafAppLayoutForKeyboardFocusedScene"));
    NSString *focusSource = focusedLayout
        ? @"leafAppLayoutForKeyboardFocusedScene" : nil;
    if (!focusedLayout) {
        focusedLayout = MacWSMessageObject(
            contentController,
            NSSelectorFromString(@"keyboardFocusedAppLayout"));
        if (focusedLayout) focusSource = @"keyboardFocusedAppLayout";
    }
    if (!focusedLayout) {
        focusedLayout = MacWSMessageObject(
            switcherController,
            NSSelectorFromString(@"_currentMainAppLayout"));
        if (focusedLayout) focusSource = @"_currentMainAppLayout";
    }
    if (!focusedLayout) {
        focusedLayout = MacWSMessageObject(
            coordinator, NSSelectorFromString(@"_currentAppLayout"));
        if (focusedLayout) focusSource = @"_currentAppLayout";
    }
    id focusedItem = MacWSAppLayoutExactSceneItem(
        focusedLayout, bundleIdentifier, requestedIdentifier);
    BOOL exactScene = focusedItem != nil;
    NSInteger sourceRole = MacWSMessageIntegerWithObject(
        focusedLayout, NSSelectorFromString(@"layoutRoleForItem:"),
        focusedItem);
    NSInteger sourceCenter = MacWSMessageInteger(
        focusedLayout, NSSelectorFromString(@"centerConfiguration"));
    NSInteger *primaryRoleAddress = (NSInteger *)dlsym(
        RTLD_DEFAULT, "SBLayoutRolePrimary");
    NSInteger *centerRoleAddress = (NSInteger *)dlsym(
        RTLD_DEFAULT, "SBLayoutRoleCenter");
    BOOL sourceFullscreen = exactScene && primaryRoleAddress &&
        sourceRole == *primaryRoleAddress && sourceCenter == 0;
    BOOL sourceWindowed = exactScene && centerRoleAddress &&
        sourceRole == *centerRoleAddress && sourceCenter == 1;
    // Runtime-confirmed on this iPadOS 16.3.1 target: a Stage Manager Scene
    // can remain 1194x807 while SBAppLayout reports Primary/center=0.  The old
    // role-only test therefore suppressed action 17 even though UIKit's Scene
    // was smaller than the 1389x970 screen.  The requester supplies the live
    // Scene-vs-screen geometry it just measured; use that as the idempotence
    // condition while retaining the exact focused-scene identity and Apple's
    // own maximization transaction below.
    BOOL alreadyExpected =
        sourceGeometryFullscreen == expectedFullscreen;
    SEL performSelector = NSSelectorFromString(
        @"performKeyboardShortcutAction:forBundleIdentifier:");
    BOOL actionAvailable = switcherController &&
        [switcherController respondsToSelector:performSelector];
    BOOL allowed = exactScene && actionAvailable;

    // A multi-window Stage Manager group can have a different Scene at the
    // keyboard focus leaf even though the requesting Scene is present in the
    // same recent-layout model.  Find that Scene by its exact FBS identifier,
    // then use SpringBoard's ordinary activating-AppLayout transition to make
    // it the focused/front item before asking the system to maximize it.
    // The transition construction and coordinator route are RE-confirmed in
    // MacWSApplyResizeRequest below; no view frame or private ivar is changed.
    id exactTargetLayout = nil;
    id exactTargetItem = nil;
    if (!exactScene && coordinator) {
        NSArray *recentLayouts = MacWSMessageObject(
            coordinator, NSSelectorFromString(@"recentAppLayouts"));
        for (id layout in recentLayouts) {
            id item = MacWSAppLayoutExactSceneItem(
                layout, bundleIdentifier, requestedIdentifier);
            if (item) {
                exactTargetLayout = layout;
                exactTargetItem = item;
                break;
            }
        }
    }
    MacWSWindowingLogLine([NSString stringWithFormat:
        @"maximization-request requested=%@ expected-fullscreen=%@ source-geometry-fullscreen=%@ exact-focus=%@ exact-recent=%@ focus-source=%@ role=%ld center=%ld source-fullscreen=%@ source-windowed=%@ manager=%@ switcher=%@ content=%@ action=%@ attempt=%lu",
        requestedIdentifier, expectedFullscreen ? @"YES" : @"NO",
        sourceGeometryFullscreen ? @"YES" : @"NO",
        exactScene ? @"YES" : @"NO",
        exactTargetItem ? @"YES" : @"NO", focusSource ?: @"none",
        (long)sourceRole, (long)sourceCenter,
        sourceFullscreen ? @"YES" : @"NO",
        sourceWindowed ? @"YES" : @"NO",
        windowSceneManager ? @"YES" : @"NO",
        switcherController ? @"YES" : @"NO",
        contentController ? @"YES" : @"NO",
        actionAvailable ? @"YES" : @"NO",
        (unsigned long)(attempt + 1)]);
    if (alreadyExpected) {
        if (exactScene && expectedFullscreen) {
            MacWSReleaseFloatingDockYield(
                requestedIdentifier, @"entered-fullscreen-workspace");
            if (!MacWSWorkspaceSinceByScene)
                MacWSWorkspaceSinceByScene = [NSMutableDictionary dictionary];
            MacWSWorkspaceSinceByScene[requestedIdentifier] = @(issuedAt);
        }
        MacWSVerifyMaximizationPostcondition(
            MacWSMessageObject(switcherController,
                               NSSelectorFromString(@"switcherCoordinator")),
            bundleIdentifier, requestedIdentifier, expectedFullscreen);
        MacWSFinishFullscreenRequest(path, [NSString stringWithFormat:
            @"maximization-not-performed scene=%@ reason=geometry-already-in-requested-state expected-fullscreen=%@ source-geometry-fullscreen=%@ role=%ld center=%ld",
            requestedIdentifier, expectedFullscreen ? @"YES" : @"NO",
            sourceGeometryFullscreen ? @"YES" : @"NO",
            (long)sourceRole, (long)sourceCenter]);
        return;
    }
    if (!allowed) {
        if (!exactScene && exactTargetLayout && exactTargetItem &&
            contentController && coordinator && (attempt == 0 || attempt == 5)) {
            SEL bringFrontSelector = NSSelectorFromString(
                @"appLayoutByBringingItemToFront:inAppLayout:");
            id activatedLayout = exactTargetLayout;
            if ([contentController respondsToSelector:bringFrontSelector]) {
                activatedLayout = ((id (*)(id, SEL, id, id))objc_msgSend)(
                    contentController, bringFrontSelector, exactTargetItem,
                    exactTargetLayout);
            }
            Class requestClass = NSClassFromString(
                @"SBMutableSwitcherTransitionRequest");
            id transitionRequest = activatedLayout
                ? ((id (*)(id, SEL, id))objc_msgSend)(
                      requestClass,
                      NSSelectorFromString(@"requestForActivatingAppLayout:"),
                      activatedLayout)
                : nil;
            SEL transitionSelector = NSSelectorFromString(
                @"switcherContentController:performTransitionWithRequest:gestureInitiated:");
            if ([transitionRequest respondsToSelector:
                    NSSelectorFromString(@"setSceneUpdatesOnly:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(
                    transitionRequest,
                    NSSelectorFromString(@"setSceneUpdatesOnly:"), NO);
            }
            if ([transitionRequest respondsToSelector:
                    NSSelectorFromString(@"setSource:")]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                    transitionRequest, NSSelectorFromString(@"setSource:"),
                    0x33);
            }
            if (transitionRequest &&
                [coordinator respondsToSelector:transitionSelector]) {
                ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                    coordinator, transitionSelector, contentController,
                    transitionRequest, NO);
                MacWSWindowingLogLine([NSString stringWithFormat:
                    @"maximization-focus-submitted scene=%@ attempt=%lu route=exact-recent-app-layout source=0x33",
                    requestedIdentifier, (unsigned long)(attempt + 1)]);
            }
        }
        if (!exactScene && attempt < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSApplyFullscreenRequest(request, path, attempt + 1);
            });
            return;
        }
        MacWSFinishFullscreenRequest(path, [NSString stringWithFormat:
            @"maximization-not-performed requested=%@ expected-fullscreen=%@ reason=%@ attempts=%lu",
            requestedIdentifier,
            expectedFullscreen ? @"YES" : @"NO",
            exactScene ? @"system-action-unavailable" : @"focused-scene-mismatch",
            (unsigned long)(attempt + 1)]);
        return;
    }
    // Runtime-confirmed in MacWSWindowing.log at 1789194093.115-.116:
    // Apple's 1389x970 proposal was constrained back to the former 898x676
    // AppKit frame. Detach only this Scene's window-sizing scope BEFORE the
    // native action. Do not force a frame or bypass Apple's size validation.
    if (expectedFullscreen) {
        MacWSReleaseFloatingDockYield(
            requestedIdentifier, @"entering-fullscreen-workspace");
        if (!MacWSWorkspaceSinceByScene)
            MacWSWorkspaceSinceByScene = [NSMutableDictionary dictionary];
        MacWSWorkspaceSinceByScene[requestedIdentifier] = @(issuedAt);
    } else {
        [MacWSWorkspaceSinceByScene removeObjectForKey:requestedIdentifier];
    }
    MacWSWindowingLogLine([NSString stringWithFormat:
        @"scene-sizing-presentation scene=%@ workspace=%@ source=native-maximization",
        requestedIdentifier, expectedFullscreen ? @"YES" : @"NO"]);
    MacWSMessageToggleMaximization(switcherController);
    MacWSVerifyMaximizationPostcondition(
        MacWSMessageObject(switcherController,
                           NSSelectorFromString(@"switcherCoordinator")),
        bundleIdentifier, requestedIdentifier, expectedFullscreen);
    MacWSFinishFullscreenRequest(path, [NSString stringWithFormat:
        @"maximization-performed scene=%@ expected-fullscreen=%@ action=17 top-action=9 focus-source=%@",
        requestedIdentifier, expectedFullscreen ? @"YES" : @"NO",
        focusSource]);
}

static void MacWSHandleFullscreenRequest(
    __unused CFNotificationCenterRef center,
    __unused void *observer,
    __unused CFStringRef name,
    __unused const void *object,
    __unused CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSString *> *names = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:MacWSResizeRequestDirectory error:nil];
        for (NSString *name in names) {
            if (![name hasPrefix:MacWSFullscreenRequestPrefix] ||
                ![name hasSuffix:@".plist"]) continue;
            NSString *path = [MacWSResizeRequestDirectory
                stringByAppendingPathComponent:name];
            if ([MacWSFullscreenRequestsInFlight containsObject:path]) continue;
            NSDictionary *request =
                [NSDictionary dictionaryWithContentsOfFile:path];
            if (![request isKindOfClass:NSDictionary.class]) {
                [[NSFileManager defaultManager] removeItemAtPath:path
                                                           error:nil];
                continue;
            }
            if (!MacWSFullscreenRequestsInFlight)
                MacWSFullscreenRequestsInFlight = [NSMutableSet set];
            [MacWSFullscreenRequestsInFlight addObject:path];
            MacWSApplyFullscreenRequest(request, path, 0);
        }
    });
}

static void MacWSFinishResizeRequest(NSString *path, NSString *message) {
    if (message.length) MacWSWindowingLogLine(message);
    if (path.length)
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [MacWSResizeRequestsInFlight removeObject:path];
}

static void MacWSApplyResizeRequest(NSDictionary *request, NSString *path,
                                    NSUInteger attempt);

static NSArray *MacWSAppLayoutItemIdentifiers(id layout) {
    NSMutableArray *identifiers = [NSMutableArray array];
    for (id item in MacWSMessageObject(layout, NSSelectorFromString(@"allItems"))) {
        id identifier = MacWSMessageObject(item, NSSelectorFromString(@"uniqueIdentifier"));
        if ([identifier isKindOfClass:NSString.class])
            [identifiers addObject:identifier];
    }
    return identifiers;
}

static BOOL MacWSResizePreservesAppLayoutSiblings(id originalLayout,
                                                 id resizedLayout,
                                                 id resizedItem) {
    NSArray *originalItems = MacWSMessageObject(
        originalLayout, NSSelectorFromString(@"allItems"));
    NSArray *resizedItems = MacWSMessageObject(
        resizedLayout, NSSelectorFromString(@"allItems"));
    if (!originalItems.count || originalItems.count != resizedItems.count ||
        ![[NSSet setWithArray:originalItems]
            isEqualToSet:[NSSet setWithArray:resizedItems]]) return NO;
    for (id item in originalItems) {
        if (MacWSMessageIntegerWithObject(originalLayout,
                NSSelectorFromString(@"layoutRoleForItem:"), item) !=
            MacWSMessageIntegerWithObject(resizedLayout,
                NSSelectorFromString(@"layoutRoleForItem:"), item)) return NO;
        if ([item isEqual:resizedItem]) continue;
        id originalAttributes = ((id (*)(id, SEL, id))objc_msgSend)(
            originalLayout, NSSelectorFromString(@"layoutAttributesForItem:"), item);
        id resizedAttributes = ((id (*)(id, SEL, id))objc_msgSend)(
            resizedLayout, NSSelectorFromString(@"layoutAttributesForItem:"), item);
        if (![originalAttributes isEqual:resizedAttributes]) return NO;
    }
    return YES;
}

static void MacWSVerifyResizePostcondition(id coordinator,
                                           id contentController,
                                           id switcherController,
                                           NSArray *expectedStageItems,
                                           NSString *bundleIdentifier,
                                           NSString *sceneIdentifier,
                                           CGSize expectedSize,
                                           BOOL expectedWindowedRole,
                                           NSDictionary *request,
                                           NSString *path,
                                           NSUInteger transactionAttempt,
                                           NSUInteger sample) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        NSString *latestNonce =
            MacWSLatestResizeNonceByScene[sceneIdentifier];
        if (![latestNonce isEqualToString:request[@"nonce"]]) {
            MacWSFinishResizeRequest(path, [NSString stringWithFormat:
                @"resize-postcondition scene=%@ landed=NO reason=superseded",
                sceneIdentifier]);
            return;
        }
        id chamoisAttributes = MacWSMessageObject(
            contentController,
            NSSelectorFromString(@"chamoisLayoutAttributes"));
        CGRect containerBounds = MacWSMessageRect(
            contentController, NSSelectorFromString(@"containerViewBounds"));
        CGSize defaultWindowSize = MacWSMessageSize(
            chamoisAttributes, NSSelectorFromString(@"defaultWindowSize"));
        CGFloat screenEdgePadding = MacWSMessageFloat(
            chamoisAttributes, NSSelectorFromString(@"screenEdgePadding"));
        SEL sizeSelector = NSSelectorFromString(
            @"sizeInBounds:defaultSize:screenEdgePadding:");
        BOOL sizeAPIReady = !CGRectIsEmpty(containerBounds) &&
            !CGSizeEqualToSize(defaultWindowSize, CGSizeZero);
        NSInteger *centerRoleAddress = (NSInteger *)dlsym(
            RTLD_DEFAULT, "SBLayoutRoleCenter");
        NSMutableArray *candidateLayouts = [NSMutableArray array];
        id currentLayout = MacWSMessageObject(
            switcherController, NSSelectorFromString(@"_currentMainAppLayout"));
        if (!expectedWindowedRole) {
            // Observe the actual current stage, not whichever stale recent
            // or leaf model happens to match the requested dimensions.
            if (!MacWSAppLayoutExactSceneItem(currentLayout, bundleIdentifier,
                                             sceneIdentifier)) {
                MacWSFinishResizeRequest(path, [NSString stringWithFormat:
                    @"resize-postcondition scene=%@ landed=NO reason=left-current-stage current-items=%@",
                    sceneIdentifier, MacWSAppLayoutItemIdentifiers(currentLayout)]);
                return;
            }
            [candidateLayouts addObject:currentLayout];
        } else {
        for (NSString *selectorName in @[
                 @"leafAppLayoutForKeyboardFocusedScene",
                 @"keyboardFocusedAppLayout"]) {
            id candidate = MacWSMessageObject(
                contentController, NSSelectorFromString(selectorName));
            if (candidate && ![candidateLayouts containsObject:candidate])
                [candidateLayouts addObject:candidate];
        }
        NSArray *appLayouts = MacWSMessageObject(
            coordinator, NSSelectorFromString(@"recentAppLayouts"));
        for (id candidate in appLayouts) {
            if (candidate && ![candidateLayouts containsObject:candidate])
                [candidateLayouts addObject:candidate];
        }
        }
        id actualLayout = nil;
        id actualItem = nil;
        NSInteger actualRole = 0;
        NSInteger actualCenter = 0;
        NSInteger actualEnvironment = 0;
        CGSize actualSize = CGSizeZero;
        BOOL sizeAvailable = NO;
        NSInteger bestScore = NSIntegerMin;
        for (id candidateLayout in candidateLayouts) {
            id candidateItem = MacWSAppLayoutExactSceneItem(
                candidateLayout, bundleIdentifier, sceneIdentifier);
            if (!candidateItem) continue;
            NSInteger candidateRole = MacWSMessageIntegerWithObject(
                candidateLayout, NSSelectorFromString(@"layoutRoleForItem:"),
                candidateItem);
            NSInteger candidateCenter = MacWSMessageInteger(
                candidateLayout, NSSelectorFromString(@"centerConfiguration"));
            NSInteger candidateEnvironment = MacWSMessageInteger(
                candidateLayout, NSSelectorFromString(@"environment"));
            id candidateAttributes = ((id (*)(id, SEL, id))objc_msgSend)(
                candidateLayout,
                NSSelectorFromString(@"layoutAttributesForItem:"),
                candidateItem);
            BOOL candidateSizeAvailable = sizeAPIReady &&
                [candidateAttributes respondsToSelector:sizeSelector];
            CGSize candidateSize = CGSizeZero;
            if (candidateSizeAvailable) {
                // Runtime-confirmed at MacWSWindowing.log 1789059115.823:
                // SBDisplayItemLayoutAttributes implements this decoded
                // model-size accessor paired with the modifier API above.
                candidateSize = ((CGSize (*)(id, SEL, CGRect, CGSize,
                                              CGFloat))objc_msgSend)(
                    candidateAttributes, sizeSelector, containerBounds,
                    defaultWindowSize, screenEdgePadding);
            }
            BOOL candidateRoleLanded = !expectedWindowedRole ||
                (centerRoleAddress && candidateRole == *centerRoleAddress &&
                 candidateCenter == 1 && candidateEnvironment == 3);
            BOOL candidateSizeLanded = candidateSizeAvailable &&
                fabs(candidateSize.width - expectedSize.width) <= 1.5 &&
                fabs(candidateSize.height - expectedSize.height) <= 1.5;
            NSInteger score = (candidateRoleLanded ? 4 : 0) +
                (candidateSizeLanded ? 8 : 0);
            if (!actualItem || score > bestScore) {
                bestScore = score;
                actualLayout = candidateLayout;
                actualItem = candidateItem;
                actualRole = candidateRole;
                actualCenter = candidateCenter;
                actualEnvironment = candidateEnvironment;
                actualSize = candidateSize;
                sizeAvailable = candidateSizeAvailable;
            }
        }
        BOOL roleLanded = actualLayout && actualItem;
        if (expectedWindowedRole) {
            roleLanded = roleLanded && centerRoleAddress &&
                actualRole == *centerRoleAddress && actualCenter == 1 &&
                actualEnvironment == 3;
        }
        BOOL sizeLanded = sizeAvailable &&
            fabs(actualSize.width - expectedSize.width) <= 1.5 &&
            fabs(actualSize.height - expectedSize.height) <= 1.5;
        NSArray *actualStageItems = MacWSAppLayoutItemIdentifiers(currentLayout);
        BOOL stageMembersPreserved = !expectedStageItems.count ||
            [[NSSet setWithArray:expectedStageItems]
                isEqualToSet:[NSSet setWithArray:actualStageItems]];
        BOOL landed = roleLanded && sizeLanded && stageMembersPreserved;
        if (!landed && sample < 9) {
            MacWSVerifyResizePostcondition(
                coordinator, contentController, switcherController,
                expectedStageItems, bundleIdentifier,
                sceneIdentifier, expectedSize, expectedWindowedRole,
                request, path, transactionAttempt, sample + 1);
            return;
        }
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"resize-postcondition scene=%@ landed=%@ role-landed=%@ size-landed=%@ role=%ld center=%ld environment=%ld expected-windowed=%@ expected=%.1fx%.1f actual=%.1fx%.1f size-api=%@ samples=%lu transaction-attempt=%lu stage-members-preserved=%@ current-items=%@ visual-acceptance=UNVERIFIED",
            sceneIdentifier, landed ? @"YES" : @"NO",
            roleLanded ? @"YES" : @"NO",
            sizeLanded ? @"YES" : @"NO", (long)actualRole,
            (long)actualCenter, (long)actualEnvironment,
            expectedWindowedRole ? @"YES" : @"NO",
            expectedSize.width, expectedSize.height,
            actualSize.width, actualSize.height,
            sizeAvailable ? @"YES" : @"NO",
            (unsigned long)(sample + 1),
            (unsigned long)(transactionAttempt + 1),
            stageMembersPreserved ? @"YES" : @"NO",
            [actualStageItems componentsJoinedByString:@","]]);
        // Membership can also change because the user closes/moves a window.
        // Never reconstruct an earlier stage in an attempt to "repair" it.
        if (!landed && stageMembersPreserved && transactionAttempt < 2) {
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"resize-corrective-resubmit scene=%@ expected=%.1fx%.1f actual=%.1fx%.1f next-attempt=%lu",
                sceneIdentifier, expectedSize.width, expectedSize.height,
                actualSize.width, actualSize.height,
                (unsigned long)(transactionAttempt + 2)]);
            MacWSApplyResizeRequest(request, path, transactionAttempt + 1);
            return;
        }
        MacWSFinishResizeRequest(path, landed ? nil : [NSString stringWithFormat:
            @"resize-failed scene=%@ reason=%@ expected=%.1fx%.1f actual=%.1fx%.1f",
            sceneIdentifier, stageMembersPreserved ? @"postcondition-not-landed" :
                @"stage-membership-changed", expectedSize.width, expectedSize.height,
            actualSize.width, actualSize.height]);
    });
}

// RE-confirmed via SpringBoard 16.3.1:
//
// * +[SBDisplayItem applicationDisplayItemWithBundleIdentifier:
//   sceneIdentifier:] at 0x1c773f33c stores the FBS scene identifier as the
//   display item's uniqueIdentifier. This gives us an exact, non-title-based
//   match for a particular multi-window UIScene.
// * The real resize transaction at 0x1c79cfaf4 calls
//   _SBDisplayItemAttributedSizeInfer, immutable
//   attributesByModifyingAttributedSize:/SizingPolicy:, immutable
//   appLayoutByModifyingLayoutAttributes:forItem:, then creates an
//   SBMutableSwitcherTransitionRequest.
// * -[SBMainSwitcherControllerCoordinator
//   switcherContentController:performTransitionWithRequest:gestureInitiated:]
//   at 0x1c79e67b8 submits that request through SBMainWorkspace when the
//   transition is not gesture-initiated.
//
// Reproduce that complete model transaction. No UIWindow frame/transform or
// SpringBoard ivar is overwritten, and every ordinary system validation and
// scene update remains in the path.
//
// A full-screen AppLayout cannot be restored to a Chamois window by changing
// only its attributed size. RE-confirmed on the same SpringBoard build:
//
// * -[SBTransitionSwitcherModifierEvent isFullScreenToCenterWindowEvent] at
//   0x1c774138c requires the same item to move from SBLayoutRolePrimary to
//   SBLayoutRoleCenter, with from.configuration == 1.
// * _isEnteringPageCenterWindowEvent at 0x1c7740fac additionally requires
//   from.centerConfiguration == 0 and to.centerConfiguration == 1.
// * -[SBAppLayout appLayoutByModifyingRole:forItem:] at 0x1c7a36dd4 is the
//   immutable role-change API.  Apple's own center-window constructor at
//   0x1c79e0bec initializes a center layout with configuration=1 and
//   centerConfiguration=1.
//
// Only an explicit windowed_role request performs that role conversion;
// ordinary resize requests preserve their existing layout role.
static void MacWSApplyResizeRequest(NSDictionary *request, NSString *path,
                                    NSUInteger attempt) {
    NSString *bundleIdentifier = request[@"bundle_identifier"];
    NSString *sceneIdentifier = request[@"scene_identifier"];
    CGFloat width = [request[@"width"] doubleValue];
    CGFloat height = [request[@"height"] doubleValue];
    CGFloat minimumWidth = [request[@"minimum_width"] doubleValue];
    CGFloat minimumHeight = [request[@"minimum_height"] doubleValue];
    CGFloat maximumWidth = [request[@"maximum_width"] doubleValue];
    CGFloat maximumHeight = [request[@"maximum_height"] doubleValue];
    BOOL fixedWidth = [request[@"fixed_width"] boolValue];
    BOOL fixedHeight = [request[@"fixed_height"] boolValue];
    BOOL requestWindowedRole = [request[@"windowed_role"] boolValue];
    NSString *nonce = request[@"nonce"];
    NSTimeInterval issuedAt = [request[@"issued_at"] doubleValue];
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - issuedAt;
    if (![bundleIdentifier isEqualToString:@"com.macwsguide.host"] ||
        ![sceneIdentifier isKindOfClass:NSString.class] ||
        ![nonce isKindOfClass:NSString.class] || nonce.length == 0 ||
        sceneIdentifier.length == 0 || !isfinite(width) || !isfinite(height) ||
        width < 150.0 || height < 150.0 || width > 4096.0 || height > 4096.0 ||
        !isfinite(minimumWidth) || !isfinite(minimumHeight) ||
        minimumWidth < 150.0 || minimumHeight < 150.0 ||
        minimumWidth > width || minimumHeight > height ||
        !isfinite(maximumWidth) || !isfinite(maximumHeight) ||
        maximumWidth < 0.0 || maximumHeight < 0.0 ||
        maximumWidth > 4096.0 || maximumHeight > 4096.0 ||
        (maximumWidth > 0.0 && maximumWidth < minimumWidth) ||
        (maximumHeight > 0.0 && maximumHeight < minimumHeight) ||
        !isfinite(age) || age < -2.0 || age > 15.0) {
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-rejected path=%@ scene=%@ size=%.1fx%.1f age=%.3f",
            path.lastPathComponent, sceneIdentifier ?: @"nil", width, height,
            age]);
        return;
    }
    BOOL policyOnly = [request[@"policy_only"] boolValue];
    NSNumber *workspaceSince = MacWSWorkspaceSinceByScene[sceneIdentifier];
    if (workspaceSince && issuedAt <= workspaceSince.doubleValue) {
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-superseded scene=%@ reason=entered-workspace", sceneIdentifier]);
        return;
    }
    // A newer, valid window request is the reverse presentation transition.
    if (workspaceSince) {
        [MacWSWorkspaceSinceByScene removeObjectForKey:sceneIdentifier];
        [MacWSStableModelSizeByScene removeObjectForKey:sceneIdentifier];
    }
    NSString *latestNonce = MacWSLatestResizeNonceByScene[sceneIdentifier];
    if (!policyOnly && ![latestNonce isEqualToString:nonce]) {
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-superseded scene=%@ nonce=%@ latest=%@ attempt=%lu",
            sceneIdentifier, nonce, latestNonce ?: @"none",
            (unsigned long)(attempt + 1)]);
        return;
    }
    if (!MacWSResizePolicyByScene)
        MacWSResizePolicyByScene = [NSMutableDictionary dictionary];
    NSDictionary *currentPolicy = MacWSResizePolicyByScene[sceneIdentifier];
    BOOL newerPolicyExists =
        [currentPolicy[@"issued_at"] doubleValue] > issuedAt;
    if (!policyOnly && newerPolicyExists) {
        // A geometry transaction can outlive a newer metadata notification.
        // Keep its independent nonce/request, but never reinstate obsolete
        // limits when its delayed lookup or postcondition retries run.
        minimumWidth = [currentPolicy[@"minimum_width"] doubleValue];
        minimumHeight = [currentPolicy[@"minimum_height"] doubleValue];
        maximumWidth = [currentPolicy[@"maximum_width"] doubleValue];
        maximumHeight = [currentPolicy[@"maximum_height"] doubleValue];
        fixedWidth = [currentPolicy[@"fixed_width"] boolValue];
        fixedHeight = [currentPolicy[@"fixed_height"] boolValue];
        if (fixedWidth) width = [currentPolicy[@"target_width"] doubleValue];
        if (fixedHeight) height = [currentPolicy[@"target_height"] doubleValue];
    }
    width = MAX(width, minimumWidth);
    height = MAX(height, minimumHeight);
    if (maximumWidth > 0.0) width = MIN(width, maximumWidth);
    if (maximumHeight > 0.0) height = MIN(height, maximumHeight);
    NSDictionary *resizePolicy = @{
        @"scene_identifier": sceneIdentifier,
        @"issued_at": @(issuedAt),
        @"target_width": @(width),
        @"target_height": @(height),
        @"minimum_width": @(minimumWidth),
        @"minimum_height": @(minimumHeight),
        @"maximum_width": @(maximumWidth),
        @"maximum_height": @(maximumHeight),
        @"fixed_width": @(fixedWidth),
        @"fixed_height": @(fixedHeight),
    };
    if (!newerPolicyExists)
        MacWSResizePolicyByScene[sceneIdentifier] = resizePolicy;
    if (policyOnly) {
        // A newly learned AppKit bound need not trigger a layout transition
        // when the displayed size is already correct. Do not mutate the
        // stable model or activate/reorder any sibling Scene for metadata.
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"resize-policy-only scene=%@ minimum=%.1fx%.1f maximum=%.1fx%.1f fixed=%@x%@ applied=%@",
            sceneIdentifier, minimumWidth, minimumHeight,
            maximumWidth, maximumHeight, fixedWidth ? @"YES" : @"NO",
            fixedHeight ? @"YES" : @"NO",
            newerPolicyExists ? @"NO-older-policy" : @"YES"]);
        MacWSFinishResizeRequest(path, nil);
        return;
    }
    UIApplication *application = UIApplication.sharedApplication;
    id windowSceneManager = MacWSMessageObject(
        application, NSSelectorFromString(@"windowSceneManager"));
    id displayWindowScene = MacWSMessageObject(
        windowSceneManager,
        NSSelectorFromString(@"activeDisplayWindowScene"));
    id switcherController = MacWSMessageObject(
        displayWindowScene, NSSelectorFromString(@"switcherController"));
    id contentController = MacWSMessageObject(
        switcherController, NSSelectorFromString(@"contentViewController"));
    if (!contentController) {
        contentController = MacWSMessageObject(
            switcherController, NSSelectorFromString(@"switcherViewController"));
    }
    id coordinator = MacWSMessageObject(
        switcherController, NSSelectorFromString(@"switcherCoordinator"));

    NSArray *appLayouts = MacWSMessageObject(
        coordinator, NSSelectorFromString(@"recentAppLayouts"));
    id targetLayout = nil;
    id targetItem = nil;
    NSString *layoutSource = nil;
    if (!requestWindowedRole) {
        // RE-confirmed, SpringBoard 20D67: _currentMainAppLayout at
        // 0x1c79163cc returns _currentLayoutState.appLayout (the whole stage).
        // A leaf is NOT interchangeable: _leafAppLayoutForItem:role: at
        // 0x1c7a36730/750 constructs one-item dictionaries. Sending that
        // leaf through the non-gesture workspace transition replaces the
        // group's entity set with that single item, dismissing its siblings.
        // Never activate a background stage merely to follow AppKit geometry.
        targetLayout = MacWSMessageObject(switcherController,
            NSSelectorFromString(@"_currentMainAppLayout"));
        targetItem = MacWSAppLayoutExactSceneItem(
            targetLayout, bundleIdentifier, sceneIdentifier);
        layoutSource = @"current-stage";
        if (targetLayout && !targetItem) {
            // UIKit's foreground callback may precede SpringBoard publishing
            // the new current group. Recheck that authoritative group with
            // the SAME geometry nonce, without activating any stage. This
            // also bounds work for a genuinely background scene at two seconds.
            if (attempt < 20) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             100 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    MacWSApplyResizeRequest(request, path, attempt + 1);
                });
                return;
            }
            MacWSFinishResizeRequest(path, [NSString stringWithFormat:
                @"resize-deferred scene=%@ reason=not-current-stage current-items=%@ policy-retained=YES",
                sceneIdentifier, MacWSAppLayoutItemIdentifiers(targetLayout)]);
            return;
        }
    }

    NSInteger *preferredCenterRoleAddress = (NSInteger *)dlsym(
        RTLD_DEFAULT, "SBLayoutRoleCenter");
    if (requestWindowedRole && preferredCenterRoleAddress) {
        for (id candidateLayout in appLayouts) {
            id candidateItem = MacWSAppLayoutExactSceneItem(
                candidateLayout, bundleIdentifier, sceneIdentifier);
            if (!candidateItem) continue;
            NSInteger candidateRole = MacWSMessageIntegerWithObject(
                candidateLayout, NSSelectorFromString(@"layoutRoleForItem:"),
                candidateItem);
            NSInteger candidateCenter = MacWSMessageInteger(
                candidateLayout, NSSelectorFromString(@"centerConfiguration"));
            NSInteger candidateEnvironment = MacWSMessageInteger(
                candidateLayout, NSSelectorFromString(@"environment"));
            NSInteger candidateConfiguration = MacWSMessageInteger(
                candidateLayout, NSSelectorFromString(@"configuration"));
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"resize-layout-candidate scene=%@ role=%ld center=%ld environment=%ld configuration=%ld preferred-center=%@",
                sceneIdentifier, (long)candidateRole,
                (long)candidateCenter, (long)candidateEnvironment,
                (long)candidateConfiguration,
                (candidateRole == *preferredCenterRoleAddress &&
                 candidateCenter == 1 && candidateEnvironment == 3)
                    ? @"YES" : @"NO"]);
            if (candidateRole == *preferredCenterRoleAddress &&
                candidateCenter == 1 && candidateEnvironment == 3) {
                targetLayout = candidateLayout;
                targetItem = candidateItem;
                layoutSource = @"explicit-windowed-center";
                break;
            }
        }
    }

    // These legacy fallbacks are ONLY for explicit full-screen/windowed
    // role conversion, not for resizing a member of the currently shown stage.
    if (requestWindowedRole) {
    // Runtime-confirmed via MacWSWindowing.log at 1789057220.059: the former
    // "first recent layout containing this item" search selected a stale
    // Primary/center=0/environment=1 model for a live 331x411 Stage Manager
    // Scene.  Resizing that model produced a 327x603 intermediate Scene even
    // though the fixed-axis policy later converged to 330x410.  Prefer the
    // switcher's current keyboard-focused model when it owns this exact FBS
    // Scene; it is the same authoritative route already used by the working
    // maximization transaction.
    for (NSString *selectorName in @[
             @"leafAppLayoutForKeyboardFocusedScene",
             @"keyboardFocusedAppLayout"]) {
        if (targetItem) break;
        id candidateLayout = MacWSMessageObject(
            contentController, NSSelectorFromString(selectorName));
        id candidateItem = MacWSAppLayoutExactSceneItem(
            candidateLayout, bundleIdentifier, sceneIdentifier);
        if (candidateItem) {
            targetLayout = candidateLayout;
            targetItem = candidateItem;
            layoutSource = selectorName;
            break;
        }
    }
    if (!targetItem) {
        id candidateLayout = MacWSMessageObject(
            switcherController, NSSelectorFromString(@"_currentMainAppLayout"));
        id candidateItem = MacWSAppLayoutExactSceneItem(
            candidateLayout, bundleIdentifier, sceneIdentifier);
        if (candidateItem) {
            targetLayout = candidateLayout;
            targetItem = candidateItem;
            layoutSource = @"explicit-windowed-current";
        }
    }
    for (id layout in appLayouts) {
        if (targetItem) break;
        id item = MacWSAppLayoutExactSceneItem(
            layout, bundleIdentifier, sceneIdentifier);
        if (!item) continue;
        targetLayout = layout;
        targetItem = item;
        layoutSource = @"explicit-windowed-recent";
    }
    }

    if (!switcherController || !contentController || !coordinator ||
        !targetLayout || !targetItem) {
        if (attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSApplyResizeRequest(request, path, attempt + 1);
            });
            return;
        }
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-failed scene=%@ reason=scene-layout-not-ready attempts=%lu controller=%@ content=%@ coordinator=%@",
            sceneIdentifier, (unsigned long)(attempt + 1),
            switcherController ? @"YES" : @"NO",
            contentController ? @"YES" : @"NO",
            coordinator ? @"YES" : @"NO"]);
        return;
    }

    NSArray *expectedStageItems = requestWindowedRole ? nil :
        MacWSAppLayoutItemIdentifiers(targetLayout);

    MacWSInferAttributedSizeFn inferAttributedSize =
        (MacWSInferAttributedSizeFn)dlsym(
            RTLD_DEFAULT, "SBDisplayItemAttributedSizeInfer");
    MacWSSizingPolicyFn smallestSizingPolicy =
        (MacWSSizingPolicyFn)dlsym(
            RTLD_DEFAULT, "SBDisplayItemSizingPolicyAllowingSmallestSize");
    id attributes = ((id (*)(id, SEL, id))objc_msgSend)(
        targetLayout, NSSelectorFromString(@"layoutAttributesForItem:"),
        targetItem);
    id chamoisAttributes = MacWSMessageObject(
        contentController, NSSelectorFromString(@"chamoisLayoutAttributes"));
    CGRect containerBounds = MacWSMessageRect(
        contentController, NSSelectorFromString(@"containerViewBounds"));
    CGSize defaultWindowSize = MacWSMessageSize(
        chamoisAttributes, NSSelectorFromString(@"defaultWindowSize"));
    CGFloat screenEdgePadding = MacWSMessageFloat(
        chamoisAttributes, NSSelectorFromString(@"screenEdgePadding"));
    SEL supportedSelector = NSSelectorFromString(
        @"supportedSizingPoliciesForItem:inAppLayout:");
    NSUInteger supportedPolicies = 0;
    if ([contentController respondsToSelector:supportedSelector]) {
        supportedPolicies = ((NSUInteger (*)(id, SEL, id, id))objc_msgSend)(
            contentController, supportedSelector, targetItem, targetLayout);
    }
    if (!inferAttributedSize || !smallestSizingPolicy || !attributes ||
        !chamoisAttributes || CGRectIsEmpty(containerBounds) ||
        CGSizeEqualToSize(defaultWindowSize, CGSizeZero) ||
        supportedPolicies == 0) {
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-failed scene=%@ reason=transaction-capability infer=%@ policy=%@ attrs=%@ chamois=%@ bounds=%@ supported=0x%lx",
            sceneIdentifier, inferAttributedSize ? @"YES" : @"NO",
            smallestSizingPolicy ? @"YES" : @"NO",
            attributes ? @"YES" : @"NO",
            chamoisAttributes ? @"YES" : @"NO",
            NSStringFromCGRect(containerBounds),
            (unsigned long)supportedPolicies]);
        return;
    }

    // A windowed-role transition cannot preserve a request that is exactly
    // the full Chamois container: that size is presentation state from the
    // Primary/full-screen layout, not a valid remembered Center-window size.
    // This can happen after Host is restored while the Scene is full-screen.
    // Use SpringBoard's own per-device defaultWindowSize as the recovery
    // input; do not invent an iPad model-specific size or overwrite a frame.
    CGSize effectiveRequestedSize = CGSizeMake(width, height);
    BOOL normalizedFullscreenSize = requestWindowedRole &&
        fabs(width - containerBounds.size.width) <= 1.0 &&
        fabs(height - containerBounds.size.height) <= 1.0;
    if (normalizedFullscreenSize)
        effectiveRequestedSize = defaultWindowSize;

    MacWSDisplayItemAttributedSize attributedSize = inferAttributedSize(
        effectiveRequestedSize, containerBounds, defaultWindowSize,
        screenEdgePadding);
    SEL modifySizeSelector =
        NSSelectorFromString(@"attributesByModifyingAttributedSize:");
    id resizedAttributes = attributes &&
        [attributes respondsToSelector:modifySizeSelector]
        ? ((id (*)(id, SEL,
                   const MacWSDisplayItemAttributedSize *))objc_msgSend)(
              attributes, modifySizeSelector, &attributedSize)
        : nil;
    NSUInteger sizingPolicy = smallestSizingPolicy(supportedPolicies);
    SEL modifyPolicySelector =
        NSSelectorFromString(@"attributesByModifyingSizingPolicy:");
    resizedAttributes = resizedAttributes &&
        [resizedAttributes respondsToSelector:modifyPolicySelector]
        ? ((id (*)(id, SEL, NSUInteger))objc_msgSend)(
              resizedAttributes, modifyPolicySelector, sizingPolicy)
        : nil;
    // RE-confirmed on 20D67 at 0x1c79cfaf4: both native resize gestures and
    // this programmatic path publish the immutable attributes carried by the
    // transition request. A center returned only by the later whole-stage
    // calculator is transient and does not update that authoritative model.
    // Put the Dock-safe center into the same attributes transaction as size.
    CGSize resizedModelSize = CGSizeZero;
    BOOL resizedModelReady = MacWSResolvedLayoutAttributesSize(
        resizedAttributes, containerBounds, defaultWindowSize,
        screenEdgePadding, &resizedModelSize);
    SEL centerSelector = NSSelectorFromString(@"centerInBounds:");
    SEL normalizedSelector = NSSelectorFromString(@"normalizedCenter");
    SEL modifyCenterSelector = NSSelectorFromString(
        @"attributesByModifyingNormalizedCenter:");
    if (resizedModelReady &&
        [resizedAttributes respondsToSelector:centerSelector] &&
        [resizedAttributes respondsToSelector:normalizedSelector] &&
        [resizedAttributes respondsToSelector:modifyCenterSelector]) {
        CGPoint sourceCenter = MacWSMessagePointWithRect(
            resizedAttributes, centerSelector, containerBounds);
        CGPoint targetCenter = MacWSHostCenterAvoidingFloatingDock(
            sourceCenter, resizedModelSize, sceneIdentifier);
        if (fabs(targetCenter.x - sourceCenter.x) > 0.25 ||
            fabs(targetCenter.y - sourceCenter.y) > 0.25) {
            CGPoint normalizedCenter = MacWSMessagePoint(
                resizedAttributes, normalizedSelector);
            CGPoint targetNormalizedCenter = CGPointMake(
                normalizedCenter.x +
                    (targetCenter.x - sourceCenter.x) /
                        containerBounds.size.width,
                normalizedCenter.y +
                    (targetCenter.y - sourceCenter.y) /
                        containerBounds.size.height);
            id centeredAttributes =
                ((id (*)(id, SEL, CGPoint))objc_msgSend)(
                    resizedAttributes, modifyCenterSelector,
                    targetNormalizedCenter);
            CGPoint resolvedCenter = MacWSMessagePointWithRect(
                centeredAttributes, centerSelector, containerBounds);
            CGSize resolvedSize = CGSizeZero;
            BOOL sizePreserved = MacWSResolvedLayoutAttributesSize(
                centeredAttributes, containerBounds, defaultWindowSize,
                screenEdgePadding, &resolvedSize) &&
                fabs(resolvedSize.width - resizedModelSize.width) <= 0.25 &&
                fabs(resolvedSize.height - resizedModelSize.height) <= 0.25;
            BOOL centerResolved =
                fabs(resolvedCenter.x - targetCenter.x) <= 0.25 &&
                fabs(resolvedCenter.y - targetCenter.y) <= 0.25;
            if (centeredAttributes && sizePreserved && centerResolved) {
                resizedAttributes = centeredAttributes;
                MacWSWindowingLogLine([NSString stringWithFormat:
                    @"dock-center-transaction scene=%@ source=%@ target=%@ size=%@ route=programmatic-immutable-attributes",
                    sceneIdentifier, NSStringFromCGPoint(sourceCenter),
                    NSStringFromCGPoint(targetCenter),
                    NSStringFromCGSize(resizedModelSize)]);
            }
        }
    }
    SEL modifyLayoutSelector = NSSelectorFromString(
        @"appLayoutByModifyingLayoutAttributes:forItem:");
    id resizedLayout = resizedAttributes &&
        [targetLayout respondsToSelector:modifyLayoutSelector]
        ? ((id (*)(id, SEL, id, id))objc_msgSend)(
              targetLayout, modifyLayoutSelector, resizedAttributes,
              targetItem)
        : nil;
    SEL bringFrontSelector = NSSelectorFromString(
        @"appLayoutByBringingItemToFront:inAppLayout:");
    if (requestWindowedRole && resizedLayout &&
        [contentController respondsToSelector:bringFrontSelector]) {
        resizedLayout = ((id (*)(id, SEL, id, id))objc_msgSend)(
            contentController, bringFrontSelector, targetItem, resizedLayout);
    }

    NSInteger sourceRole = MacWSMessageIntegerWithObject(
        resizedLayout, NSSelectorFromString(@"layoutRoleForItem:"),
        targetItem);
    NSInteger sourceCenterConfiguration = MacWSMessageInteger(
        resizedLayout, NSSelectorFromString(@"centerConfiguration"));
    if (requestWindowedRole) {
        NSInteger *centerRoleAddress = (NSInteger *)dlsym(
            RTLD_DEFAULT, "SBLayoutRoleCenter");
        NSInteger *primaryRoleAddress = (NSInteger *)dlsym(
            RTLD_DEFAULT, "SBLayoutRolePrimary");
        SEL modifyRoleSelector = NSSelectorFromString(
            @"appLayoutByModifyingRole:forItem:");
        NSInteger centerRole = centerRoleAddress ? *centerRoleAddress : 0;
        NSInteger primaryRole = primaryRoleAddress ? *primaryRoleAddress : 0;
        if (centerRoleAddress && sourceRole == centerRole &&
            sourceCenterConfiguration == 1) {
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"resize-windowed-role scene=%@ already-center role=%ld center=%ld",
                sceneIdentifier, (long)sourceRole,
                (long)sourceCenterConfiguration]);
        } else if (!centerRoleAddress || !primaryRoleAddress ||
                   sourceRole != primaryRole ||
                   sourceCenterConfiguration != 0) {
            MacWSFinishResizeRequest(path, [NSString stringWithFormat:
                @"resize-failed scene=%@ reason=unexpected-fullscreen-layout source-role=%ld primary=%ld center=%ld source-center=%ld role-symbols=%@",
                sceneIdentifier, (long)sourceRole, (long)primaryRole,
                (long)centerRole, (long)sourceCenterConfiguration,
                centerRoleAddress && primaryRoleAddress ? @"YES" : @"NO"]);
            return;
        } else {
        id roleLayout = centerRoleAddress &&
            [resizedLayout respondsToSelector:modifyRoleSelector]
            ? ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(
                  resizedLayout, modifyRoleSelector, centerRole, targetItem)
            : nil;

        // appLayoutByModifyingRole: correctly moves the item but deliberately
        // retains the source centerConfiguration. Reconstruct the immutable
        // value with the same public model fields and Page Center
        // configuration, exactly as Apple's addCenterRole path does.
        // Runtime-confirmed via SpringBoard-2026-08-02-163302.ips and
        // RE-confirmed at 0x1c7a34234: the first initializer argument is the
        // complete item set. Passing itemsWithoutCenterOrFloatingItems trips
        // SBAppLayout.m:329, "`centerItem` must be nil or included in
        // `items`". Keep every item; the separate center/floating arguments
        // classify members of that same set.
        NSArray *allItems = MacWSMessageObject(
            roleLayout, NSSelectorFromString(@"allItems"));
        id centerItem = MacWSMessageObject(
            roleLayout, NSSelectorFromString(@"centerItem"));
        id floatingItem = MacWSMessageObject(
            roleLayout, NSSelectorFromString(@"floatingItem"));
        id attributesMap = MacWSMessageObject(
            roleLayout, NSSelectorFromString(@"itemsToLayoutAttributesMap"));
        NSInteger configuration = MacWSMessageInteger(
            roleLayout, NSSelectorFromString(@"configuration"));
        NSInteger sourceEnvironment = MacWSMessageInteger(
            roleLayout, NSSelectorFromString(@"environment"));
        BOOL hidden = MacWSMessageBool(
            roleLayout, NSSelectorFromString(@"isHidden"));
        NSInteger displayOrdinal = MacWSMessageInteger(
            roleLayout, NSSelectorFromString(@"preferredDisplayOrdinal"));
        SEL centerInitializer = NSSelectorFromString(
            @"initWithItems:centerItem:floatingItem:configuration:itemsToLayoutAttributes:centerConfiguration:environment:hidden:preferredDisplayOrdinal:");
        Class layoutClass = roleLayout ? [roleLayout class] : Nil;
        id pageCenterLayout = nil;
        BOOL centerIncluded = centerItem &&
            [allItems containsObject:centerItem];
        BOOL floatingIncluded = !floatingItem ||
            [allItems containsObject:floatingItem];
        // RE-confirmed via SpringBoard 20D67
        // -[SBMainSwitcherControllerCoordinator
        // addCenterRoleAppLayoutForDisplayItem:windowScene:completion:] at
        // 0x1c79e0d10: Apple's Page Center constructor passes environment=3.
        // _configureRequest:forSwitcherTransitionRequest:withEventLabel: then
        // takes its Chamois branch at 0x1c79e2c70 and installs the Center
        // entity plus requestedCenterConfiguration. Preserving the source
        // full-screen environment leaves that builder on the wrong branch;
        // the request can be submitted but cannot become a Center window.
        static const NSInteger pageCenterEnvironment = 3;
        if (layoutClass && centerItem == targetItem && centerIncluded &&
            floatingIncluded && attributesMap && configuration == 1 &&
            [layoutClass instancesRespondToSelector:centerInitializer]) {
            id allocated = ((id (*)(id, SEL))objc_msgSend)(
                layoutClass, @selector(alloc));
            pageCenterLayout =
                ((id (*)(id, SEL, id, id, id, NSInteger, id, NSInteger,
                          NSInteger, BOOL, NSInteger))objc_msgSend)(
                    allocated, centerInitializer, allItems, centerItem,
                    floatingItem, configuration, attributesMap, 1,
                    pageCenterEnvironment, hidden, displayOrdinal);
        }
        if (!pageCenterLayout) {
            MacWSFinishResizeRequest(path, [NSString stringWithFormat:
                @"resize-failed scene=%@ reason=center-role-conversion source-role=%ld source-center=%ld role-symbol=%@ role-layout=%@ center-match=%@ center-in-items=%@ floating-in-items=%@ attrs=%@ configuration=%ld",
                sceneIdentifier, (long)sourceRole,
                (long)sourceCenterConfiguration,
                centerRoleAddress ? @"YES" : @"NO",
                roleLayout ? @"YES" : @"NO",
                centerItem == targetItem ? @"YES" : @"NO",
                centerIncluded ? @"YES" : @"NO",
                floatingIncluded ? @"YES" : @"NO",
                attributesMap ? @"YES" : @"NO", (long)configuration]);
            return;
        }
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"resize-windowed-layout scene=%@ source-environment=%ld target-environment=%ld",
            sceneIdentifier, (long)sourceEnvironment,
            (long)pageCenterEnvironment]);
        resizedLayout = pageCenterLayout;
        }
    }

    // The immutable AppLayout clone preserves every member and every other
    // member's layout attributes (RE: 0x1c7a376cc..0x1c7a37714). Verify that
    // contract before handing the complete group to the workspace builder.
    // In particular, ordinary size synchronization must not change siblings'
    // lastInteractionTime by bringing the resized item to the front.
    if (!requestWindowedRole && !MacWSResizePreservesAppLayoutSiblings(
            targetLayout, resizedLayout, targetItem)) {
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-failed scene=%@ reason=stage-clone-contract source-items=%@ target-items=%@",
            sceneIdentifier, expectedStageItems,
            MacWSAppLayoutItemIdentifiers(resizedLayout)]);
        return;
    }

    Class requestClass = NSClassFromString(
        @"SBMutableSwitcherTransitionRequest");
    id transitionRequest = resizedLayout
        ? ((id (*)(id, SEL, id))objc_msgSend)(
              requestClass,
              NSSelectorFromString(@"requestForActivatingAppLayout:"),
              resizedLayout)
        : nil;
    if ([transitionRequest respondsToSelector:
            NSSelectorFromString(@"setSceneUpdatesOnly:")]) {
        // RE-confirmed at 0x1c79e67fc..0x1c79e6828: this property is consumed
        // ONLY on the gestureInitiated path. Our non-gesture request always
        // goes through SBMainWorkspace, so YES never protected siblings.
        // Preserve the complete current AppLayout instead of claiming a
        // fabricated gesture session or a scene-only workspace transaction.
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            transitionRequest,
            NSSelectorFromString(@"setSceneUpdatesOnly:"),
            NO);
    }
    // Runtime-confirmed from the target iPadOS 16.3.1 class metadata at
    // MacWSWindowing.log 1789059115.826: SBSwitcherTransitionRequest exposes
    // the real -setAnimationDisabled: property.  AppKit has already completed
    // its own window animation when this reverse synchronization begins, so a
    // second ~1.45 s Stage Manager animation only exposes a mismatched Scene
    // and IOSurface.  Submit the same validated SBMainWorkspace transaction
    // without that redundant animation; no layout or size validation is
    // bypassed.
    if ([transitionRequest respondsToSelector:
            NSSelectorFromString(@"setAnimationDisabled:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            transitionRequest,
            NSSelectorFromString(@"setAnimationDisabled:"), YES);
    }
    // 0x33 is the system keyboard/top-affordance transition source used by
    // -[SBMedusaDecoratedDeviceApplicationSceneViewController
    // performSwitcherKeyboardShortcutAction:] at 0x1c7add284.
    if (requestWindowedRole &&
        [transitionRequest respondsToSelector:NSSelectorFromString(@"setSource:")]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            transitionRequest, NSSelectorFromString(@"setSource:"), 0x33);
    }
    SEL performSelector = NSSelectorFromString(
        @"switcherContentController:performTransitionWithRequest:gestureInitiated:");
    if (!transitionRequest || ![coordinator respondsToSelector:performSelector]) {
        MacWSFinishResizeRequest(path, [NSString stringWithFormat:
            @"resize-failed scene=%@ reason=transition-unavailable layout=%@ request=%@",
            sceneIdentifier, resizedLayout ? @"YES" : @"NO",
            transitionRequest ? @"YES" : @"NO"]);
        return;
    }

    // The request was identity-validated above as an exact MacWSHost Scene.
    // Keep any synchronous grid lookup made by SpringBoard's transition
    // builder in the same narrow scope as interactive Host resizing. The
    // counter is main-thread-only and is restored before this function can
    // process another app/layout request.
    NSDictionary *previousPolicy = MacWSActiveDenseGridPolicy;
    MacWSSetStableModelSize(sceneIdentifier, effectiveRequestedSize);
    MacWSActiveDenseGridPolicy = resizePolicy;
    MacWSDenseGridScopeDepth++;
    @try {
        ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
            coordinator, performSelector, contentController,
            transitionRequest, NO);
    } @finally {
        MacWSDenseGridScopeDepth--;
        MacWSActiveDenseGridPolicy = previousPolicy;
    }
    MacWSWindowingLogLine([NSString stringWithFormat:
        @"resize-submitted scene=%@ requested=%.1fx%.1f effective=%.1fx%.1f minimum=%.1fx%.1f fixed=%@x%@ normalized-fullscreen-size=%@ bounds=%@ default=%.1fx%.1f supported=0x%lx policy=%lu windowed-role=%@ scene-updates-only=NO source-role=%ld source-center=%ld target-center=%ld target-environment=%ld source=0x%lx route=SBMainWorkspace layout-source=%@ stage-items=%@",
        sceneIdentifier, width, height, effectiveRequestedSize.width,
        effectiveRequestedSize.height, minimumWidth, minimumHeight,
        fixedWidth ? @"YES" : @"NO",
        fixedHeight ? @"YES" : @"NO",
        normalizedFullscreenSize ? @"YES" : @"NO",
        NSStringFromCGRect(containerBounds),
        defaultWindowSize.width, defaultWindowSize.height,
        (unsigned long)supportedPolicies, (unsigned long)sizingPolicy,
        requestWindowedRole ? @"YES" : @"NO",
        (long)sourceRole,
        (long)sourceCenterConfiguration,
        (long)MacWSMessageInteger(
            resizedLayout, NSSelectorFromString(@"centerConfiguration")),
        (long)MacWSMessageInteger(
            resizedLayout, NSSelectorFromString(@"environment")),
        (unsigned long)(requestWindowedRole ? 0x33 : 0), layoutSource,
        MacWSAppLayoutItemIdentifiers(resizedLayout)]);
    MacWSVerifyResizePostcondition(
        coordinator, contentController, switcherController, expectedStageItems,
        bundleIdentifier, sceneIdentifier,
        effectiveRequestedSize, requestWindowedRole, request, path, attempt,
        0);
}

static void MacWSHandleResizeRequest(
    __unused CFNotificationCenterRef center,
    __unused void *observer,
    __unused CFStringRef name,
    __unused const void *object,
    __unused CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSString *> *names = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:MacWSResizeRequestDirectory error:nil];
        NSMutableDictionary<NSString *, NSDictionary *> *latestByScene =
            [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *pathByScene =
            [NSMutableDictionary dictionary];
        for (NSString *name in names) {
            if (![name hasPrefix:MacWSResizeRequestPrefix] ||
                ![name hasSuffix:@".plist"]) continue;
            NSString *path = [MacWSResizeRequestDirectory
                stringByAppendingPathComponent:name];
            NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:path];
            if (![request isKindOfClass:NSDictionary.class]) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                continue;
            }
            NSString *scene = request[@"scene_identifier"];
            NSString *nonce = request[@"nonce"];
            NSTimeInterval issued = [request[@"issued_at"] doubleValue];
            if (![scene isKindOfClass:NSString.class] || scene.length == 0 ||
                ![nonce isKindOfClass:NSString.class] || nonce.length == 0 ||
                !isfinite(issued)) {
                MacWSFinishResizeRequest(path,
                    [NSString stringWithFormat:
                        @"resize-rejected path=%@ reason=identity-invalid",
                        name]);
                continue;
            }
            if ([request[@"policy_only"] boolValue]) {
                // Metadata has no geometry-queue ownership. Validate/apply
                // it now, before selecting/coalescing geometry winners, and
                // consume only this file. It must not replace a geometry
                // nonce or remove a pending/in-flight resize for this Scene.
                MacWSApplyResizeRequest(request, path, 0);
                continue;
            }
            NSDictionary *current = latestByScene[scene];
            NSTimeInterval currentIssued =
                [current[@"issued_at"] doubleValue];
            if (!current || issued > currentIssued ||
                (issued == currentIssued &&
                 [name compare:pathByScene[scene].lastPathComponent] ==
                    NSOrderedDescending)) {
                latestByScene[scene] = request;
                pathByScene[scene] = path;
            }
        }

        if (!MacWSLatestResizeNonceByScene)
            MacWSLatestResizeNonceByScene = [NSMutableDictionary dictionary];
        for (NSString *scene in latestByScene) {
            MacWSLatestResizeNonceByScene[scene] =
                latestByScene[scene][@"nonce"];
        }

        // Remove every queued predecessor before submitting the winners. An
        // already-running layout lookup remains harmless: its next retry
        // checks the same latest-nonce map and terminates as superseded.
        for (NSString *name in names) {
            if (![name hasPrefix:MacWSResizeRequestPrefix] ||
                ![name hasSuffix:@".plist"]) continue;
            NSString *path = [MacWSResizeRequestDirectory
                stringByAppendingPathComponent:name];
            NSDictionary *request =
                [NSDictionary dictionaryWithContentsOfFile:path];
            if ([request[@"policy_only"] boolValue]) continue;
            NSString *scene = request[@"scene_identifier"];
            NSString *winnerPath = scene ? pathByScene[scene] : nil;
            if (winnerPath && ![winnerPath isEqualToString:path]) {
                MacWSFinishResizeRequest(path, [NSString stringWithFormat:
                    @"resize-superseded scene=%@ path=%@ winner=%@",
                    scene, name, winnerPath.lastPathComponent]);
            }
        }
        for (NSString *scene in latestByScene) {
            NSString *path = pathByScene[scene];
            NSDictionary *request = latestByScene[scene];
            NSString *nonce = request[@"nonce"];
            // AppKit can publish several adjacent sizes during one utility-
            // panel animation. SpringBoard's performTransition call is not an
            // interactive update API, so submitting every intermediate model
            // lets older transitions land after newer ones. Debounce only
            // this AppKit -> Scene direction; the ordinary Scene -> AppKit
            // resize stream remains continuous.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         80 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (![MacWSLatestResizeNonceByScene[scene]
                        isEqualToString:nonce] ||
                    ![[NSFileManager defaultManager]
                        fileExistsAtPath:path] ||
                    [MacWSResizeRequestsInFlight containsObject:path]) return;
                if (!MacWSResizeRequestsInFlight)
                    MacWSResizeRequestsInFlight = [NSMutableSet set];
                [MacWSResizeRequestsInFlight addObject:path];
                MacWSApplyResizeRequest(request, path, 0);
            });
        }
    });
}

static void MacWSHandleInitialSizeRequest(
    __unused CFNotificationCenterRef center,
    __unused void *observer,
    __unused CFStringRef name,
    __unused const void *object,
    __unused CFDictionaryRef userInfo) {
    // The activation hook claims and validates the file synchronously so the
    // request cannot lose a race with FrontBoard.  This notification is only
    // a wake/readiness witness; it performs no layout transaction by itself.
    MacWSWindowingLogLine(@"initial-size notification received route=claim-at-app-layout-construction");
}

static void MacWSWriteDenseGridWitness(const char *axis, NSUInteger original,
                                       NSUInteger expanded, double minimum,
                                       double maximum) {
    if (!MacWSWindowingDiagnosticsEnabled()) return;
    char path[PATH_MAX] = {0};
    snprintf(path, sizeof(path),
             "/tmp/com.macwsguide.dense-grid.%s",
             axis);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    dprintf(fd, "version=3 pid=%d axis=%s fallback-step=10 "
                "exact-proposal=1 original=%lu expanded=%lu "
                "minimum=%.3f maximum=%.3f\n",
            getpid(), axis, (unsigned long)original, (unsigned long)expanded,
            minimum, maximum);
    close(fd);
}

static NSArray<NSNumber *> *MacWSDenseCandidates(NSArray<NSNumber *> *source,
                                                  const char *axis) {
    if (![source isKindOfClass:NSArray.class] || source.count < 2 ||
        access(MacWSDenseGridDisabled, F_OK) == 0) return source;
    double minimum = DBL_MAX;
    double maximum = 0.0;
    NSMutableSet<NSNumber *> *values = [NSMutableSet setWithCapacity:source.count];
    for (id object in source) {
        if (![object isKindOfClass:NSNumber.class]) return source;
        double value = [object doubleValue];
        if (!isfinite(value) || value <= 0.0) return source;
        minimum = fmin(minimum, value);
        maximum = fmax(maximum, value);
        [values addObject:@(value)];
    }
    if (!isfinite(minimum) || !isfinite(maximum) || maximum <= minimum)
        return source;

    static const double step = 10.0;
    static const double nativeWindowFloor = 150.0;
    double first = ceil(nativeWindowFloor / step) * step;
    for (double value = first; value < maximum && values.count < 256;
         value += step) {
        [values addObject:@(value)];
    }
    // Preserve the exact AppKit boundary alongside the dense convenience
    // steps. This is scoped to one validated Host Scene on SpringBoard's main
    // thread, so no other iPadOS application receives these candidates.
    BOOL widthAxis = strstr(axis, "width") != NULL;
    double proposed = widthAxis ? MacWSActiveDenseGridProposal.width
                                : MacWSActiveDenseGridProposal.height;
    if (isfinite(proposed) && proposed >= nativeWindowFloor &&
        proposed <= maximum)
        [values addObject:@(proposed)];
    NSString *minimumKey = widthAxis ? @"minimum_width" : @"minimum_height";
    NSString *maximumKey = widthAxis ? @"maximum_width" : @"maximum_height";
    NSString *targetKey = widthAxis ? @"target_width" : @"target_height";
    for (NSString *key in @[minimumKey, maximumKey, targetKey]) {
        double value = [MacWSActiveDenseGridPolicy[key] doubleValue];
        if (isfinite(value) && value >= nativeWindowFloor && value <= maximum)
            [values addObject:@(value)];
    }
    double policyMaximum = [MacWSActiveDenseGridPolicy[maximumKey] doubleValue];
    if (isfinite(policyMaximum) && policyMaximum >= nativeWindowFloor) {
        for (NSNumber *value in [values allObjects])
            if (value.doubleValue > policyMaximum) [values removeObject:value];
    }
    NSArray<NSNumber *> *ordered = [values.allObjects
        sortedArrayUsingComparator:^NSComparisonResult(NSNumber *lhs,
                                                        NSNumber *rhs) {
            return [lhs compare:rhs];
        }];
    if (ordered.count > source.count)
        MacWSWriteDenseGridWitness(axis, source.count, ordered.count,
                                   nativeWindowFloor, maximum);
    return ordered.count ? ordered : source;
}

// Calculate the collision-free frame for one Host model without ever changing
// its authoritative size. The result is consumed by
// MacWSAppLayoutByAvoidingFloatingDock below to update the immutable
// SBDisplayItemLayoutAttributes normalized center. Returning a different frame
// only from _frameForLayoutRole: is insufficient: runtime logs at
// 1790873129.927 showed that calculator returning y=24 while the full iPadOS
// screenshot still showed SpringBoard presenting the original centered model.
static CGRect MacWSHostFrameAvoidingFloatingDock(
        CGRect frame, CGRect containerBounds, CGFloat floatingDockHeight,
        CGFloat screenEdgePadding, CGFloat screenScale,
        NSString *sceneIdentifier) {
    if (!sceneIdentifier.length || CGRectIsEmpty(frame) ||
        CGRectIsEmpty(containerBounds)) return frame;

    BOOL hasYieldAssertion =
        MacWSDockYieldAssertionByScene[sceneIdentifier] != nil;
    BOOL wantsYield =
        [MacWSDockYieldWantedScenes containsObject:sceneIdentifier];
    BOOL dockVisible = isfinite(floatingDockHeight) &&
        floatingDockHeight > 0.5;
    if (dockVisible) {
        if (!MacWSDockYieldGeometryByScene)
            MacWSDockYieldGeometryByScene = [NSMutableDictionary dictionary];
        MacWSDockYieldGeometryByScene[sceneIdentifier] = @{
            @"height": @(floatingDockHeight),
            @"bounds_width": @(containerBounds.size.width),
            @"bounds_height": @(containerBounds.size.height),
            @"screen_edge_padding": @(screenEdgePadding),
            @"screen_scale": @(screenScale),
        };
    } else if (hasYieldAssertion || wantsYield) {
        NSDictionary *geometry =
            MacWSDockYieldGeometryByScene[sceneIdentifier];
        BOOL sameBounds = geometry &&
            fabs([geometry[@"bounds_width"] doubleValue] -
                 containerBounds.size.width) <= 0.5 &&
            fabs([geometry[@"bounds_height"] doubleValue] -
                 containerBounds.size.height) <= 0.5;
        if (!sameBounds) {
            MacWSReleaseFloatingDockYield(
                sceneIdentifier, @"container-geometry-changed");
            return frame;
        }
        floatingDockHeight = [geometry[@"height"] doubleValue];
    } else {
        return frame;
    }
    if (!isfinite(floatingDockHeight) || floatingDockHeight <= 0.5)
        return frame;

    CGFloat dockTop = CGRectGetMaxY(containerBounds) - floatingDockHeight;
    if (!isfinite(dockTop)) return frame;

    if (MacWSWindowingDiagnosticsEnabled()) {
        static NSMutableDictionary<NSString *, NSString *> *lastGeometry;
        if (!lastGeometry) lastGeometry = [NSMutableDictionary dictionary];
        id controller = MacWSResolveFloatingDockController();
        SEL presentedSelector = NSSelectorFromString(@"isFloatingDockPresented");
        BOOL presented = controller &&
            [controller respondsToSelector:presentedSelector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(controller, presentedSelector);
        NSString *windowGeometry = MacWSFloatingDockWindowGeometry();
        NSString *signature = [NSString stringWithFormat:
            @"%@/%@/%.3f/%@/%@", NSStringFromCGRect(frame),
            NSStringFromCGRect(containerBounds), floatingDockHeight,
            presented ? @"presented" : @"not-presented", windowGeometry];
        if (![lastGeometry[sceneIdentifier] isEqualToString:signature]) {
            lastGeometry[sceneIdentifier] = signature;
            MacWSWindowingWriteDiagnosticLine([NSString stringWithFormat:
                @"dock-window-geometry scene=%@ model-frame=%@ container=%@ "
                 "dock-height=%.3f dock-top=%.3f presented=%@ windows=[%@]",
                sceneIdentifier, NSStringFromCGRect(frame),
                NSStringFromCGRect(containerBounds), floatingDockHeight,
                dockTop, presented ? @"YES" : @"NO", windowGeometry]);
        }
    }

    // Preserve the user's authoritative Scene size. Runtime screenshots from
    // the first candidate proved that shortening only this returned frame did
    // not resize the Scene, while the subsequent upstream model ceiling made
    // the native resize gesture unable to grow. A frame that fits above the
    // Dock can satisfy both invariants by translation alone.
    CGFloat padding = isfinite(screenEdgePadding) &&
        screenEdgePadding > 0.0 ? screenEdgePadding : 0.0;
    CGFloat topBoundary = CGRectGetMinY(containerBounds) + padding;
    // Runtime-confirmed on iPad13,6/20D67 at 1790870982.200: Files receives
    // frame {{106,24.5},{1177,807}} with dockTop=855.5 and the native 24pt
    // edge padding. The former Host rule required that full 24pt even for a
    // slightly taller 824pt frame, so it hid the Dock although 7.5pt of real
    // separation remained. Preserve the full native gap whenever possible,
    // then compress only that gap down to eight physical pixels. Never allow
    // the zero-gap contact that was visibly reported as overlap, and never
    // shrink the user's authoritative frame.
    CGFloat effectiveScale = isfinite(screenScale) && screenScale > 0.0
        ? screenScale : UIScreen.mainScreen.scale;
    if (!isfinite(effectiveScale) || effectiveScale <= 0.0)
        effectiveScale = 2.0;
    CGFloat minimumDockGap = 8.0 / effectiveScale;
    CGFloat availableDockGap =
        dockTop - topBoundary - frame.size.height;
    BOOL canFitWithDock = availableDockGap + 0.5 >= minimumDockGap;
    if (hasYieldAssertion && !canFitWithDock) {
        // While the assertion is active the live Dock height is normally 0.
        // Keep an oversized user's frame untouched until it can coexist. A
        // release may already be in flight from an immediately preceding
        // smaller gesture sample; refresh the desired state so its completion
        // reasserts native yield for this newer oversized sample.
        MacWSRequestFloatingDockYield(sceneIdentifier, frame);
        return frame;
    }
    if (hasYieldAssertion) {
        // The transaction that makes the Dock visible must also carry the
        // translated center. Waiting for a later calculator pass leaves the
        // persistent model at its old center and recreates the overlap.
        MacWSReleaseFloatingDockYield(
            sceneIdentifier, @"window-fits-dock-safe-region");
    }

    CGFloat safeBottom = dockTop - minimumDockGap;
    if (CGRectGetMaxY(frame) <= safeBottom + 0.5) return frame;
    if (canFitWithDock) {
        CGFloat dockGap = MIN(padding, MAX(minimumDockGap,
                                           availableDockGap));
        CGFloat translatedY = dockTop - dockGap - frame.size.height;
        frame.origin.y = translatedY;
    } else {
        // The requested size cannot fit between the native top margin and the
        // visible Dock. Preserve that size and let the real Dock controller
        // yield. The following layout pass receives the system's updated Dock
        // state; no artificial maximum is written into AppKit/Scene policy.
        MacWSRequestFloatingDockYield(sceneIdentifier, frame);
    }
    return frame;
}

// Resolve a Dock-safe center from the last real visible-Dock geometry for
// this exact FBS Scene. This is used by the two authoritative transaction
// constructors: SBItemResizeGestureSwitcherModifier's center argument and
// MacWSApplyResizeRequest's immutable attributes. It never changes size.
static CGPoint MacWSHostCenterAvoidingFloatingDock(
        CGPoint center, CGSize size, NSString *sceneIdentifier) {
    NSDictionary *geometry =
        MacWSDockYieldGeometryByScene[sceneIdentifier];
    if (!sceneIdentifier.length || !geometry ||
        !isfinite(center.x) || !isfinite(center.y) ||
        !isfinite(size.width) || !isfinite(size.height) ||
        size.width <= 0.0 || size.height <= 0.0)
        return center;
    CGRect bounds = CGRectMake(
        0.0, 0.0,
        [geometry[@"bounds_width"] doubleValue],
        [geometry[@"bounds_height"] doubleValue]);
    CGFloat dockHeight = [geometry[@"height"] doubleValue];
    CGFloat screenEdgePadding =
        [geometry[@"screen_edge_padding"] doubleValue];
    CGFloat screenScale = [geometry[@"screen_scale"] doubleValue];
    if (CGRectIsEmpty(bounds) || !isfinite(dockHeight) ||
        dockHeight <= 0.5)
        return center;
    CGRect frame = CGRectMake(
        center.x - size.width * 0.5,
        center.y - size.height * 0.5,
        size.width, size.height);
    CGRect adjusted = MacWSHostFrameAvoidingFloatingDock(
        frame, bounds, dockHeight, screenEdgePadding, screenScale,
        sceneIdentifier);
    return CGPointMake(CGRectGetMidX(adjusted), CGRectGetMidY(adjusted));
}

// Runtime-confirmed on iPad13,6 / 20D67 at 1790873129.927:
// normalizedCenter={0.5,0.5} resolves through -centerInBounds: to
// {694.5,485} in {{0,0},{1389,970}}. Modifying only normalized y to
// 0.44587628865979378 resolves through the same SpringBoard method to
// {694.5,432.5}, the exact center of the desired unchanged 1171x817 frame at
// y=24. Publish that center through Apple's immutable attributes/AppLayout
// model; do not mutate a UIWindow, private ivar, or the user's size policy.
static id MacWSAppLayoutByAvoidingFloatingDock(
        id appLayout, CGRect containerBounds, id chamoisLayoutAttributes,
        CGFloat floatingDockHeight, CGFloat screenScale) {
    if (!appLayout || CGRectIsEmpty(containerBounds) ||
        containerBounds.size.width <= 0.0 ||
        containerBounds.size.height <= 0.0)
        return appLayout;

    NSArray *items = MacWSMessageObject(
        appLayout, NSSelectorFromString(@"allItems"));
    SEL attributesSelector =
        NSSelectorFromString(@"layoutAttributesForItem:");
    SEL normalizedSelector = NSSelectorFromString(@"normalizedCenter");
    SEL centerSelector = NSSelectorFromString(@"centerInBounds:");
    SEL modifyCenterSelector = NSSelectorFromString(
        @"attributesByModifyingNormalizedCenter:");
    SEL modifyLayoutSelector = NSSelectorFromString(
        @"appLayoutByModifyingLayoutAttributes:forItem:");
    CGSize defaultSize = MacWSMessageSize(
        chamoisLayoutAttributes,
        NSSelectorFromString(@"defaultWindowSize"));
    CGFloat screenEdgePadding = MacWSMessageFloat(
        chamoisLayoutAttributes,
        NSSelectorFromString(@"screenEdgePadding"));
    if (![items isKindOfClass:NSArray.class] ||
        ![appLayout respondsToSelector:attributesSelector] ||
        ![appLayout respondsToSelector:modifyLayoutSelector] ||
        CGSizeEqualToSize(defaultSize, CGSizeZero))
        return appLayout;

    id adjustedLayout = appLayout;
    for (id item in items) {
        NSString *bundle = MacWSMessageObject(
            item, NSSelectorFromString(@"bundleIdentifier"));
        NSString *scene = MacWSMessageObject(
            item, NSSelectorFromString(@"uniqueIdentifier"));
        if (![bundle isEqualToString:@"com.macwsguide.host"] ||
            scene.length == 0 || MacWSWorkspaceSinceByScene[scene])
            continue;

        id attributes = ((id (*)(id, SEL, id))objc_msgSend)(
            adjustedLayout, attributesSelector, item);
        if (![attributes respondsToSelector:normalizedSelector] ||
            ![attributes respondsToSelector:centerSelector] ||
            ![attributes respondsToSelector:modifyCenterSelector])
            continue;

        CGSize size = CGSizeZero;
        if (!MacWSResolvedLayoutAttributesSize(
                attributes, containerBounds, defaultSize,
                screenEdgePadding, &size))
            continue;
        CGPoint center = MacWSMessagePointWithRect(
            attributes, centerSelector, containerBounds);
        if (!isfinite(center.x) || !isfinite(center.y)) continue;
        CGRect originalFrame = CGRectMake(
            center.x - size.width * 0.5,
            center.y - size.height * 0.5,
            size.width, size.height);
        CGRect targetFrame = MacWSHostFrameAvoidingFloatingDock(
            originalFrame, containerBounds, floatingDockHeight,
            screenEdgePadding, screenScale, scene);
        if (fabs(targetFrame.origin.x - originalFrame.origin.x) <= 0.25 &&
            fabs(targetFrame.origin.y - originalFrame.origin.y) <= 0.25)
            continue;

        CGPoint normalizedCenter = MacWSMessagePoint(
            attributes, normalizedSelector);
        CGPoint targetCenter = CGPointMake(
            CGRectGetMidX(targetFrame), CGRectGetMidY(targetFrame));
        CGPoint targetNormalizedCenter = CGPointMake(
            normalizedCenter.x +
                (targetCenter.x - center.x) / containerBounds.size.width,
            normalizedCenter.y +
                (targetCenter.y - center.y) / containerBounds.size.height);
        if (!isfinite(targetNormalizedCenter.x) ||
            !isfinite(targetNormalizedCenter.y))
            continue;

        id adjustedAttributes =
            ((id (*)(id, SEL, CGPoint))objc_msgSend)(
                attributes, modifyCenterSelector, targetNormalizedCenter);
        CGPoint resolvedTargetCenter = MacWSMessagePointWithRect(
            adjustedAttributes, centerSelector, containerBounds);
        CGSize resolvedTargetSize = CGSizeZero;
        BOOL sizePreserved = MacWSResolvedLayoutAttributesSize(
            adjustedAttributes, containerBounds, defaultSize,
            screenEdgePadding, &resolvedTargetSize) &&
            fabs(resolvedTargetSize.width - size.width) <= 0.25 &&
            fabs(resolvedTargetSize.height - size.height) <= 0.25;
        BOOL centerResolved =
            fabs(resolvedTargetCenter.x - targetCenter.x) <= 0.25 &&
            fabs(resolvedTargetCenter.y - targetCenter.y) <= 0.25;
        if (!adjustedAttributes || !sizePreserved || !centerResolved) {
            if (MacWSWindowingDiagnosticsEnabled()) {
                static NSMutableDictionary<NSString *, NSString *> *lastRejected;
                if (!lastRejected)
                    lastRejected = [NSMutableDictionary dictionary];
                NSString *signature = [NSString stringWithFormat:
                    @"%@/%@/%@/%@/%@", NSStringFromCGRect(originalFrame),
                    NSStringFromCGRect(targetFrame),
                    NSStringFromCGPoint(resolvedTargetCenter),
                    NSStringFromCGSize(resolvedTargetSize),
                    centerResolved ? @"center" : @"no-center"];
                if (![lastRejected[scene] isEqualToString:signature]) {
                    lastRejected[scene] = signature;
                    MacWSWindowingLogLine([NSString stringWithFormat:
                        @"dock-center-rejected scene=%@ original=%@ target=%@ normalized=%@ resolved-center=%@ resolved-size=%@ size-preserved=%@ center-resolved=%@",
                        scene, NSStringFromCGRect(originalFrame),
                        NSStringFromCGRect(targetFrame),
                        NSStringFromCGPoint(targetNormalizedCenter),
                        NSStringFromCGPoint(resolvedTargetCenter),
                        NSStringFromCGSize(resolvedTargetSize),
                        sizePreserved ? @"YES" : @"NO",
                        centerResolved ? @"YES" : @"NO"]);
                }
            }
            continue;
        }

        id candidateLayout = ((id (*)(id, SEL, id, id))objc_msgSend)(
            adjustedLayout, modifyLayoutSelector, adjustedAttributes, item);
        if (!candidateLayout) continue;
        adjustedLayout = candidateLayout;
        if (MacWSWindowingDiagnosticsEnabled()) {
            static NSMutableDictionary<NSString *, NSString *> *lastAdjusted;
            if (!lastAdjusted)
                lastAdjusted = [NSMutableDictionary dictionary];
            NSString *signature = [NSString stringWithFormat:
                @"%@/%@/%@", NSStringFromCGRect(containerBounds),
                NSStringFromCGRect(originalFrame),
                NSStringFromCGRect(targetFrame)];
            if (![lastAdjusted[scene] isEqualToString:signature]) {
                lastAdjusted[scene] = signature;
                MacWSWindowingLogLine([NSString stringWithFormat:
                    @"dock-center-adjusted scene=%@ dock-height=%.1f container=%@ original=%@ target=%@ normalized=%@ resolved-center=%@ size-preserved=YES route=immutable-app-layout",
                    scene, floatingDockHeight,
                    NSStringFromCGRect(containerBounds),
                    NSStringFromCGRect(originalFrame),
                    NSStringFromCGRect(targetFrame),
                    NSStringFromCGPoint(targetNormalizedCenter),
                    NSStringFromCGPoint(resolvedTargetCenter)]);
            }
        }
    }
    return adjustedLayout;
}

%hook SBHomeGestureToSwitcherSwitcherModifier
- (id)adjustedAppLayoutsForAppLayouts:(id)layouts {
    NSArray *adjusted = %orig(layouts);
    // RE-confirmed on 20D67, SpringBoard UUID 13B37E5E-5290-3E2E-91B9-
    // 4378BD2E8312: init at 0x1c7c60bf8 retains selectedAppLayout in
    // _appLayout (metadata offset 0x88). appLayoutsToCacheSnapshots at
    // 0x1c7c617a8 uses indexOfObject: on that same object, then passes the
    // unchecked result to subarrayWithRange: (0x1c7963418). The fullsize,
    // visible and scroll-position consumers also use this selection.
    // Runtime crash SpringBoard-2026-09-12-161745.ips reaches that exact
    // subarray call while a new Host Scene replaces its Stage Manager group.
    // Repair the selection at the adjusted-model publication boundary, before
    // ANY of those consumers run. Preserve Apple's array, order, range checks
    // and cache work. This is a retained real replacement, not a fake index.
    Ivar selection = class_getInstanceVariable(
        NSClassFromString(@"SBHomeGestureToSwitcherSwitcherModifier"),
        "_appLayout");
    if (selection && strcmp(ivar_getTypeEncoding(selection),
                            "@\"SBAppLayout\"") == 0) {
        id previous = object_getIvar(self, selection);
        id replacement = MacWSSwitcherReplacementSelection(previous, adjusted);
        if (replacement) {
            object_setIvarWithStrongDefault(self, selection, replacement);
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"switcher-selection rebound old=%@ new=%@ index=%lu count=%lu route=adjusted-layout-publication",
                MacWSAppLayoutItemIdentifiers(previous),
                MacWSAppLayoutItemIdentifiers(replacement),
                (unsigned long)[adjusted indexOfObject:replacement],
                (unsigned long)adjusted.count]);
        }
    }
    return adjusted;
}
%end

%hook SBDisplayItemLayoutAttributesCalculator
- (id)_appLayoutByPerformingAutoLayoutIfNeededInAppLayout:(id)appLayout
        containerOrientation:(NSInteger)containerOrientation
     chamoisLayoutAttributes:(id)chamoisLayoutAttributes
          floatingDockHeight:(CGFloat)floatingDockHeight
                 screenScale:(CGFloat)screenScale
                draggingItem:(id)draggingItem
overlappingModelBeforeDragging:(id)overlappingModelBeforeDragging
                      bounds:(CGRect)bounds
          prefersStripHidden:(BOOL)prefersStripHidden
           prefersDockHidden:(BOOL)prefersDockHidden {
    MacWSReleaseDockYieldsOutsideCurrentStage();
    if (MacWSWindowingDiagnosticsEnabled()) {
        NSArray *items = MacWSMessageObject(
            appLayout, NSSelectorFromString(@"allItems"));
        for (id item in items) {
            NSString *bundle = MacWSMessageObject(
                item, NSSelectorFromString(@"bundleIdentifier"));
            NSString *scene = MacWSMessageObject(
                item, NSSelectorFromString(@"uniqueIdentifier"));
            if (![bundle isEqualToString:@"com.macwsguide.host"] ||
                !scene.length || MacWSWorkspaceSinceByScene[scene])
                continue;
            static NSMutableDictionary<NSString *, NSString *> *lastDockPolicy;
            if (!lastDockPolicy)
                lastDockPolicy = [NSMutableDictionary dictionary];
            NSString *signature = [NSString stringWithFormat:
                @"%.1f/%@/%@/%@", floatingDockHeight,
                prefersDockHidden ? @"hidden" : @"visible",
                prefersStripHidden ? @"strip-hidden" : @"strip-visible",
                NSStringFromCGRect(bounds)];
            if (![lastDockPolicy[scene] isEqualToString:signature]) {
                lastDockPolicy[scene] = signature;
                MacWSWindowingWriteDiagnosticLine([NSString stringWithFormat:
                    @"dock-policy-observed scene=%@ dock-height=%.1f bounds=%@ prefers-dock-hidden=%@ prefers-strip-hidden=%@ route=calculator-input",
                    scene, floatingDockHeight, NSStringFromCGRect(bounds),
                    prefersDockHidden ? @"YES" : @"NO",
                    prefersStripHidden ? @"YES" : @"NO"]);
            }
            break;
        }
    }
    // RE-confirmed in the target cache: this method's first grid call
    // (0x1c78b527c) calculates the stage-wide maximum, then its item loop
    // clamps every window against that value (0x1c78b54b8..54d8).
    // A fixed About policy here made that maximum 301x378 for ALL items.
    // Temporarily clear every inherited ownership source. Internal per-item
    // calls enter the lower frame hook below and bind their own identities.
    id previousModifier = MacWSActiveResizeGestureModifier;
    id previousGroupModifier = MacWSGroupResizeGestureModifier;
    NSDictionary *previousPolicy = MacWSActiveDenseGridPolicy;
    CGSize previousProposal = MacWSActiveDenseGridProposal;
    NSUInteger previousDenseDepth = MacWSDenseGridScopeDepth;
    NSUInteger previousItemDepth = MacWSItemLayoutScopeDepth;
    NSUInteger previousInitialDepth = MacWSInitialLayoutScopeDepth;
    NSString *previousScene = MacWSActiveLayoutSceneIdentifier;
    BOOL previousInitialGridObserved = MacWSInitialGridObserved;
    MacWSActiveResizeGestureModifier = nil;
    MacWSGroupResizeGestureModifier = previousModifier ?: previousGroupModifier;
    MacWSActiveDenseGridPolicy = nil;
    MacWSActiveDenseGridProposal = CGSizeZero;
    MacWSDenseGridScopeDepth = 0;
    MacWSItemLayoutScopeDepth = 0;
    MacWSInitialLayoutScopeDepth = 0;
    MacWSActiveLayoutSceneIdentifier = nil;
    MacWSInitialGridObserved = NO;
    MacWSGroupLayoutScopeDepth++;
    id laidOutAppLayout = nil;
    @try {
        laidOutAppLayout = %orig(
            appLayout, containerOrientation, chamoisLayoutAttributes,
            floatingDockHeight, screenScale, draggingItem,
            overlappingModelBeforeDragging, bounds,
            prefersStripHidden, prefersDockHidden);
    } @finally {
        MacWSGroupLayoutScopeDepth--;
        MacWSInitialGridObserved = previousInitialGridObserved;
        MacWSActiveLayoutSceneIdentifier = previousScene;
        MacWSInitialLayoutScopeDepth = previousInitialDepth;
        MacWSItemLayoutScopeDepth = previousItemDepth;
        MacWSDenseGridScopeDepth = previousDenseDepth;
        MacWSActiveDenseGridProposal = previousProposal;
        MacWSActiveDenseGridPolicy = previousPolicy;
        MacWSActiveResizeGestureModifier = previousModifier;
        MacWSGroupResizeGestureModifier = previousGroupModifier;
    }
    return MacWSAppLayoutByAvoidingFloatingDock(
        laidOutAppLayout, bounds, chamoisLayoutAttributes,
        floatingDockHeight, screenScale);
}

- (CGRect)_frameForLayoutRole:(NSInteger)layoutRole
                 inAppLayout:(id)appLayout
             containerBounds:(CGRect)containerBounds
        containerOrientation:(NSInteger)containerOrientation
     chamoisLayoutAttributes:(id)chamoisLayoutAttributes
          floatingDockHeight:(CGFloat)floatingDockHeight
                 screenScale:(CGFloat)screenScale
 isChamoisWindowingUIEnabled:(BOOL)isChamoisWindowingUIEnabled
          prefersStripHidden:(BOOL)prefersStripHidden
           prefersDockHidden:(BOOL)prefersDockHidden
              skipAutoLayout:(BOOL)skipAutoLayout {
    // This argument is SpringBoard's live windowing mode for the display.
    // Publish it independently of the Host item test below: on iPadOS 16.0
    // Split View invokes this calculator with Chamois disabled even though
    // UIKit still reports supportsMultipleScenes=YES.
    MacWSObserveChamoisWindowingState(isChamoisWindowingUIEnabled);
    // RE-confirmed IMP 0x1c78b3e30, exact type encoding in
    // docs/evidence/windowing-stage-wide-limit-policy-leak-20260912.md.
    // Both the public convenience method AND the auto-layout item loop use
    // this selector. The upper windowScene: method misses the internal loop.
    id item = MacWSAppLayoutItemForRole(appLayout, layoutRole);
    NSString *bundle = MacWSMessageObject(
        item, NSSelectorFromString(@"bundleIdentifier"));
    NSString *scene = MacWSMessageObject(
        item, NSSelectorFromString(@"uniqueIdentifier"));
    BOOL host = isChamoisWindowingUIEnabled &&
        [bundle isEqualToString:@"com.macwsguide.host"] && scene.length > 0 &&
        !MacWSWorkspaceSinceByScene[scene];
    id attributes = item && [appLayout respondsToSelector:
        NSSelectorFromString(@"layoutAttributesForItem:")]
        ? ((id (*)(id, SEL, id))objc_msgSend)(
              appLayout, NSSelectorFromString(@"layoutAttributesForItem:"), item)
        : nil;
    MacWSDisplayItemAttributedSize attributedSize =
        MacWSAttributedSizeForAttributes(
            attributes, NSSelectorFromString(@"attributedSize"));
    NSString *initialPath = nil;
    NSDictionary *initialPolicy = host
        ? MacWSClaimInitialSizePolicy(
              item, attributes && MacWSAttributedSizeIsUnspecified(attributedSize),
              &initialPath)
        : nil;
    if (initialPath.length) {
        // Claim consumption precedes recursive item calculation; another new
        // Scene cannot bind the same FIFO activation request on this stack.
        [[NSFileManager defaultManager] removeItemAtPath:initialPath error:nil];
    }

    id previousModifier = MacWSActiveResizeGestureModifier;
    id gestureModifier = previousModifier ?: MacWSGroupResizeGestureModifier;
    id previousGroupModifier = MacWSGroupResizeGestureModifier;
    id selectedItem = MacWSResizeModifierSelectedItem(gestureModifier);
    NSString *selectedScene = MacWSMessageObject(
        selectedItem, NSSelectorFromString(@"uniqueIdentifier"));
    BOOL selectedGestureItem = host &&
        [selectedScene isEqualToString:scene];
    NSDictionary *itemPolicy = nil;
    CGSize modelSize = CGSizeZero;
    BOOL exactModel = NO;
    if (host) {
        if (selectedGestureItem && !initialPolicy) {
            // The selected gesture's live proposal owns this item. Siblings
            // never inherit its minimum/fixed-axis policy.
            itemPolicy = MacWSResizePolicyForModifier(gestureModifier);
        } else if (initialPolicy) {
            itemPolicy = initialPolicy;
            modelSize = CGSizeMake(
                [initialPolicy[@"target_width"] doubleValue],
                [initialPolicy[@"target_height"] doubleValue]);
            exactModel = YES;
        } else {
            exactModel = MacWSStableModelSize(scene, &modelSize);
            if (!exactModel &&
                !MacWSAttributedSizeIsUnspecified(attributedSize)) {
                CGSize defaultSize = MacWSMessageSize(
                    chamoisLayoutAttributes,
                    NSSelectorFromString(@"defaultWindowSize"));
                CGFloat padding = MacWSMessageFloat(
                    chamoisLayoutAttributes,
                    NSSelectorFromString(@"screenEdgePadding"));
                exactModel = MacWSResolvedLayoutAttributesSize(
                    attributes, containerBounds, defaultSize, padding, &modelSize);
                if (exactModel) MacWSSetStableModelSize(scene, modelSize);
            }
            if (exactModel) {
                itemPolicy = @{
                    @"scene_identifier": scene,
                    @"target_width": @(modelSize.width),
                    @"target_height": @(modelSize.height),
                    @"minimum_width": @150.0,
                    @"minimum_height": @150.0,
                    @"fixed_width": @YES,
                    @"fixed_height": @YES,
                };
            }
        }
        if (!itemPolicy) itemPolicy = @{
            @"scene_identifier": scene, @"macws_host": @YES,
        };

    }

    NSDictionary *previousPolicy = MacWSActiveDenseGridPolicy;
    CGSize previousProposal = MacWSActiveDenseGridProposal;
    NSUInteger previousDenseDepth = MacWSDenseGridScopeDepth;
    NSUInteger previousItemDepth = MacWSItemLayoutScopeDepth;
    NSUInteger previousInitialDepth = MacWSInitialLayoutScopeDepth;
    NSString *previousScene = MacWSActiveLayoutSceneIdentifier;
    BOOL previousInitialGridObserved = MacWSInitialGridObserved;
    // Set rather than increment: a stock item inside a Host transaction must
    // have a fully stock scope, including any cached-grid association.
    MacWSActiveResizeGestureModifier = selectedGestureItem ? gestureModifier : nil;
    // Preserve provenance separately while a sibling temporarily clears the
    // active policy. Its auto-layout may recurse back into the selected item.
    MacWSGroupResizeGestureModifier = gestureModifier;
    MacWSActiveDenseGridPolicy = itemPolicy;
    MacWSActiveDenseGridProposal = exactModel ? modelSize : CGSizeZero;
    MacWSDenseGridScopeDepth = host ? 1 : 0;
    MacWSItemLayoutScopeDepth = previousItemDepth + 1;
    MacWSInitialLayoutScopeDepth = initialPolicy ? 1 : 0;
    MacWSActiveLayoutSceneIdentifier = host ? scene : nil;
    MacWSInitialGridObserved = NO;
    CGRect frame = CGRectZero;
    BOOL initialGridObserved = NO;
    @try {
        frame = %orig(layoutRole, appLayout, containerBounds,
                      containerOrientation, chamoisLayoutAttributes,
                      floatingDockHeight, screenScale, isChamoisWindowingUIEnabled,
                      prefersStripHidden, prefersDockHidden, skipAutoLayout);
        initialGridObserved = MacWSInitialGridObserved;
    } @finally {
        MacWSInitialGridObserved = previousInitialGridObserved;
        MacWSActiveLayoutSceneIdentifier = previousScene;
        MacWSInitialLayoutScopeDepth = previousInitialDepth;
        MacWSItemLayoutScopeDepth = previousItemDepth;
        MacWSDenseGridScopeDepth = previousDenseDepth;
        MacWSActiveDenseGridProposal = previousProposal;
        MacWSActiveDenseGridPolicy = previousPolicy;
        MacWSActiveResizeGestureModifier = previousModifier;
        MacWSGroupResizeGestureModifier = previousGroupModifier;
    }
    // Diagnostic witnesses report this calculation, not visual acceptance.
    // Actual Scene display frames and the iPadOS screenshot are checked apart.
    if (host) {
        static NSMutableDictionary<NSString *, NSValue *> *lastFrames;
        if (!lastFrames) lastFrames = [NSMutableDictionary dictionary];
        NSString *key = [NSString stringWithFormat:@"%@/%ld/%d", scene,
                         (long)layoutRole, skipAutoLayout];
        NSValue *previous = lastFrames[key];
        BOOL changed = !previous || !CGRectEqualToRect(previous.CGRectValue, frame);
        if (changed || initialPath.length) {
            lastFrames[key] = [NSValue valueWithCGRect:frame];
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"item-layout-frame scene=%@ role=%ld group-depth=%lu skip-auto=%@ initial=%@ gesture=%@ model=%@ frame=%@ initial-grid=%@",
                scene, (long)layoutRole, (unsigned long)MacWSGroupLayoutScopeDepth,
                skipAutoLayout ? @"YES" : @"NO", initialPolicy ? @"YES" : @"NO",
                selectedGestureItem ? @"YES" : @"NO",
                exactModel ? NSStringFromCGSize(modelSize) : @"live",
                NSStringFromCGRect(frame), initialGridObserved ? @"YES" : @"NO"]);
        }
    }
    return frame;
}
%end

%hook SBSwitcherChamoisLayoutAttributes
- (void)setGridWidths:(NSArray<NSNumber *> *)widths {
    // Never persist MacWS policy into SpringBoard's shared Chamois model.
    %orig(widths);
}
- (void)setGridHeights:(NSArray<NSNumber *> *)heights {
    %orig(heights);
}
- (NSArray<NSNumber *> *)gridWidths {
    NSArray<NSNumber *> *original = %orig;
    return MacWSDenseGridScopeDepth > 0
        ? MacWSDenseCandidates(original, "host-width") : original;
}
- (NSArray<NSNumber *> *)gridHeights {
    NSArray<NSNumber *> *original = %orig;
    return MacWSDenseGridScopeDepth > 0
        ? MacWSDenseCandidates(original, "host-height") : original;
}
%end

%hook SBItemResizeGestureSwitcherModifier
- (id)_responseForGestureUpdateAtGestureEnd:(BOOL)ended {
    // RE-confirmed in SpringBoard 20D67: handleGestureEvent: installs the
    // selected layout/role at 0x1c79cf108/128, compares event.phase with 3 at
    // 0x1c79cf294, then passes that exact boolean here at 0x1c79cf2a0.
    // Observe Apple's lifecycle; do not replace its response or invent an
    // interactive transition. Only the selected Host Scene has a publisher.
    BOOL nativeGesture = MacWSActiveResizeGestureModifier == self;
    if (nativeGesture && !ended) MacWSPublishResizeGestureState(self, YES);
    @try {
        return %orig(ended);
    } @finally {
        if (nativeGesture && ended) MacWSPublishResizeGestureState(self, NO);
    }
}
- (void)dealloc {
    // Also retire a cancelled modifier that never produced the ordinary end.
    MacWSPublishResizeGestureState(self, NO);
    %orig;
}
- (id)_responseForSceneSizeUpdateToSize:(CGSize)size
                                  center:(CGPoint)center
                        sceneUpdatesOnly:(BOOL)sceneUpdatesOnly {
    // RE-confirmed on SpringBoard 20D67 at 0x1c79cfaf4: this is the real
    // per-item resize response that constructs the attributed size, immutable
    // AppLayout and transition request.  Constrain only the exact selected
    // MacWSHost Scene before Apple's original transaction runs.  This covers
    // the pre-handleGestureEvent grid pass which runtime logs showed was the
    // one whose unconstrained result actually reached UIKit.
    NSDictionary *policy = MacWSResizePolicyForModifier(self);
    id selectedItem = MacWSResizeModifierSelectedItem(self);
    NSString *selectedBundle = MacWSMessageObject(
        selectedItem, NSSelectorFromString(@"bundleIdentifier"));
    NSString *selectedScene = MacWSMessageObject(
        selectedItem, NSSelectorFromString(@"uniqueIdentifier"));
    CGSize constrained = size;
    if (policy) {
        CGFloat minimumWidth = [policy[@"minimum_width"] doubleValue];
        CGFloat minimumHeight = [policy[@"minimum_height"] doubleValue];
        CGFloat maximumWidth = [policy[@"maximum_width"] doubleValue];
        CGFloat maximumHeight = [policy[@"maximum_height"] doubleValue];
        constrained.width = [policy[@"fixed_width"] boolValue]
            ? [policy[@"target_width"] doubleValue]
            : MAX(constrained.width, minimumWidth);
        constrained.height = [policy[@"fixed_height"] boolValue]
            ? [policy[@"target_height"] doubleValue]
            : MAX(constrained.height, minimumHeight);
        if (maximumWidth > 0.0)
            constrained.width = MIN(constrained.width, maximumWidth);
        if (maximumHeight > 0.0)
            constrained.height = MIN(constrained.height, maximumHeight);
        if (fabs(constrained.width - size.width) > 0.5 ||
            fabs(constrained.height - size.height) > 0.5) {
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"resize-response constrained scene=%@ proposed=%.1fx%.1f result=%.1fx%.1f fixed=%@x%@",
                policy[@"scene_identifier"], size.width, size.height,
                constrained.width, constrained.height,
                [policy[@"fixed_width"] boolValue] ? @"YES" : @"NO",
                [policy[@"fixed_height"] boolValue] ? @"YES" : @"NO"]);
        }
    }
    // This selector is also invoked by SpringBoard's restore/reflow
    // transitions without a finger being down. Runtime-confirmed immediately
    // after the v43 SpringBoard restart at 1789151974.244-.1977.234: those
    // calls proposed -139x507, 150x446, 798.5x438 and 860x459 for the same
    // restored About Finder Scene. Treating every response as user intent
    // poisoned the Scene's authoritative size. A real resize response is
    // synchronously nested inside our handleGestureEvent: scope; AppKit-led
    // programmatic changes update the same map in MacWSApplyResizeRequest.
    BOOL realGestureResponse = MacWSActiveResizeGestureModifier == self;
    if ([selectedBundle isEqualToString:@"com.macwsguide.host"] &&
        realGestureResponse) {
        // This method is the RE-confirmed transaction constructor for the
        // selected resize item. Its constrained proposal is authoritative,
        // including intermediate values while the finger is moving; the last
        // event naturally leaves the committed size in this per-Scene slot.
        MacWSSetStableModelSize(selectedScene, constrained);
        static CFTimeInterval lastHostResponseWitness;
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - lastHostResponseWitness >= 0.08) {
            lastHostResponseWitness = now;
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"resize-response host scene=%@ proposed=%.1fx%.1f constrained=%.1fx%.1f policy=%@",
                selectedScene ?: @"nil", size.width, size.height,
                constrained.width, constrained.height,
                policy ? @"scene-gesture" : @"identity-only-gesture"]);
        }
    } else if ([selectedBundle isEqualToString:@"com.macwsguide.host"]) {
        static CFTimeInterval lastIgnoredTransitionWitness;
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - lastIgnoredTransitionWitness >= 0.20) {
            lastIgnoredTransitionWitness = now;
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"resize-response ignored scene=%@ proposed=%.1fx%.1f constrained=%.1fx%.1f source=system-transition",
                selectedScene ?: @"nil", size.width, size.height,
                constrained.width, constrained.height]);
        }
    }
    // The real gesture response is immediately followed by a second call
    // from SpringBoard's transition machinery. Runtime-confirmed at
    // 1790913716.052-.086: that follow-up carried the exact committed
    // 1229.2x825.5 size after the gesture scope had ended. The original
    // implementation passed its stock centered point through, undoing the
    // Dock-safe normalized center written by the preceding transaction.
    //
    // RE-confirmed in the exact 20D67 original IMP at live +176..+212:
    // `normalizedPointForPoint:inBounds:` feeds
    // `attributesByModifyingNormalizedCenter:` before the attributed size is
    // replaced at +304..+340. Therefore a matching post-gesture call is also
    // an authoritative center publisher. Admit only a size matching the last
    // real gesture sample; unrelated restore/reflow proposals remain outside
    // this route and cannot acquire MacWS center policy.
    CGSize stableModelSize = CGSizeZero;
    BOOL matchingGestureFollowup = !realGestureResponse &&
        [selectedBundle isEqualToString:@"com.macwsguide.host"] &&
        MacWSStableModelSize(selectedScene, &stableModelSize) &&
        fabs(stableModelSize.width - constrained.width) <= 1.0 &&
        fabs(stableModelSize.height - constrained.height) <= 1.0;
    CGPoint authoritativeCenter = center;
    if ([selectedBundle isEqualToString:@"com.macwsguide.host"] &&
        (realGestureResponse || matchingGestureFollowup)) {
        authoritativeCenter = MacWSHostCenterAvoidingFloatingDock(
            center, constrained, selectedScene);
        if (fabs(authoritativeCenter.x - center.x) > 0.25 ||
            fabs(authoritativeCenter.y - center.y) > 0.25) {
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"dock-center-transaction scene=%@ source=%@ target=%@ size=%@ route=%@",
                selectedScene, NSStringFromCGPoint(center),
                NSStringFromCGPoint(authoritativeCenter),
                NSStringFromCGSize(constrained), realGestureResponse
                    ? @"native-resize-response"
                    : @"matching-system-followup"]);
        }
    }
    id previous = MacWSActiveResizeGestureModifier;
    NSDictionary *previousPolicy = MacWSActiveDenseGridPolicy;
    MacWSActiveResizeGestureModifier = self;
    MacWSActiveDenseGridPolicy = policy;
    @try {
        return %orig(constrained, authoritativeCenter, sceneUpdatesOnly);
    } @finally {
        MacWSActiveDenseGridPolicy = previousPolicy;
        MacWSActiveResizeGestureModifier = previous;
    }
}

- (id)handleGestureEvent:(id)event {
    // Runtime metadata from the target proves this is the owning gesture
    // boundary and that its `_layoutGrid` is per modifier. Keep the owner
    // visible only while Apple's original handler synchronously resolves the
    // proposed size.
    id previous = MacWSActiveResizeGestureModifier;
    NSDictionary *previousPolicy = MacWSActiveDenseGridPolicy;
    BOOL host = MacWSResizeModifierTargetsHost(self);
    NSDictionary *policy = host ? MacWSResizePolicyForModifier(self) : nil;
    id layoutGrid = MacWSResizeModifierLayoutGrid(self);
    // `_layoutGrid` is owned by this modifier (runtime metadata: ivar +248).
    // Associate the exact selected Host Scene with that grid for the complete
    // asynchronous resize transaction, not merely the synchronous callback.
    // A modifier reused for a stock app clears the association before Apple's
    // handler runs, so no dense candidate can leak across applications.
    if (layoutGrid) {
        NSDictionary *association = host
            ? (policy ?: @{@"macws_host": @YES}) : nil;
        objc_setAssociatedObject(
            layoutGrid, &MacWSLayoutGridHostPolicyAssociationKey,
            association, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    MacWSActiveResizeGestureModifier = self;
    MacWSActiveDenseGridPolicy = policy;
    @try {
        return %orig(event);
    } @finally {
        MacWSActiveDenseGridPolicy = previousPolicy;
        MacWSActiveResizeGestureModifier = previous;
    }
}
%end

// RE-confirmed on SpringBoard UUID 13B37E5E-5290-3E2E-91B9-4378BD2E8312:
// _layoutAppLayout:roleMask:completion:'s block at 0x1c77537e4 loads the
// SBFluidSwitcherViewController ivar used for -frameForIndex: at
// 0x1c7753898. Runtime witness 1790922796.520 identifies that exact ivar as
// _rootModifier and its concrete class as SBiPadOSPlatformSwitcherModifier.
// This frame is the global AppLayout frame whose origin feeds the final
// SBReusableSnapshotItemContainer center. Keep the requested size intact and
// translate only an exact Host Scene into the area above the floating Dock.
%hook SBiPadOSPlatformSwitcherModifier
- (CGRect)frameForIndex:(NSUInteger)index {
    CGRect frame = %orig(index);
    NSArray *appLayouts = MacWSMessageObject(
        self, NSSelectorFromString(@"appLayouts"));
    id appLayout = [appLayouts isKindOfClass:NSArray.class] &&
        index < appLayouts.count ? appLayouts[index] : nil;
    NSArray *items = MacWSMessageObject(
        appLayout, NSSelectorFromString(@"allItems"));
    NSString *hostScene = nil;
    for (id item in items) {
        NSString *bundle = MacWSMessageObject(
            item, NSSelectorFromString(@"bundleIdentifier"));
        NSString *scene = MacWSMessageObject(
            item, NSSelectorFromString(@"uniqueIdentifier"));
        if ([bundle isEqualToString:@"com.macwsguide.host"] &&
            scene.length && !MacWSWorkspaceSinceByScene[scene]) {
            hostScene = scene;
            break;
        }
    }
    if (!hostScene.length) return frame;

    CGRect containerBounds = MacWSMessageRect(
        self, NSSelectorFromString(@"containerViewBounds"));
    CGFloat floatingDockHeight = MacWSMessageFloat(
        self, NSSelectorFromString(@"floatingDockHeight"));
    CGFloat screenScale = MacWSMessageFloat(
        self, NSSelectorFromString(@"screenScale"));
    id chamoisLayoutAttributes = MacWSMessageObject(
        self, NSSelectorFromString(@"chamoisLayoutAttributes"));
    CGFloat screenEdgePadding = MacWSMessageFloat(
        chamoisLayoutAttributes,
        NSSelectorFromString(@"screenEdgePadding"));
    CGRect original = frame;
    frame = MacWSHostFrameAvoidingFloatingDock(
        frame, containerBounds, floatingDockHeight,
        screenEdgePadding, screenScale, hostScene);
    if (MacWSWindowingDiagnosticsEnabled()) {
        static NSMutableDictionary<NSString *, NSString *> *lastFrames;
        if (!lastFrames) lastFrames = [NSMutableDictionary dictionary];
        NSString *signature = [NSString stringWithFormat:@"%@/%@/%.3f",
            NSStringFromCGRect(original), NSStringFromCGRect(frame),
            floatingDockHeight];
        if (![lastFrames[hostScene] isEqualToString:signature]) {
            lastFrames[hostScene] = signature;
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"index-frame-provider scene=%@ provider=%@ index=%lu bounds=%@ dock-height=%.1f original=%@ result=%@ size-preserved=%@ route=switcher-global-frame",
                hostScene, NSStringFromClass(object_getClass(self)),
                (unsigned long)index, NSStringFromCGRect(containerBounds),
                floatingDockHeight, NSStringFromCGRect(original),
                NSStringFromCGRect(frame),
                CGSizeEqualToSize(original.size, frame.size)
                    ? @"YES" : @"NO"]);
        }
    }
    return frame;
}
%end

%hook SBDisplayItemLayoutGrid
- (CGSize)nearestGridSizeForProposedSize:(CGSize)proposedSize
                            countOnStage:(NSUInteger)countOnStage
                                inBounds:(CGRect)bounds
                      contentOrientation:(NSInteger)contentOrientation
                   layoutRestrictionInfo:(id)layoutRestrictionInfo
                             screenScale:(CGFloat)screenScale
                chamoisLayoutAttributes:(id)chamoisLayoutAttributes {
    BOOL itemScope = MacWSItemLayoutScopeDepth > 0;
    BOOL stageLimitScope = MacWSGroupLayoutScopeDepth > 0 && !itemScope;
    BOOL scopedHostItem = itemScope && MacWSActiveLayoutSceneIdentifier.length > 0;
    BOOL activeHost = MacWSResizeModifierTargetsHost(
        MacWSActiveResizeGestureModifier);
    NSDictionary *associatedPolicy = objc_getAssociatedObject(
        self, &MacWSLayoutGridHostPolicyAssociationKey);
    BOOL initialScope = scopedHostItem && MacWSInitialLayoutScopeDepth > 0 &&
        MacWSActiveDenseGridPolicy != nil;
    BOOL initialHost = initialScope;
    // Runtime-confirmed by MacWSWindowing.log at 1789111604.455-.478:
    // AppKit's programmatic Get Info resize entered the validated
    // SBMainWorkspace transaction with a 292.6x696.6 target, but this grid
    // method classified its synchronous lookup as `stock-app` and returned
    // the stock 327-point width. MacWSApplyResizeRequest already brackets the
    // exact identity-validated transition with this dense-grid scope; honor
    // that scope here as a third, deliberately short-lived ownership source.
    // Without it, UIKit's stock snap feeds a wider size back into AppKit and
    // creates the repeated 266 -> 298 point Get Info width changes.
    BOOL programmaticHost = !initialScope && MacWSDenseGridScopeDepth > 0 &&
        MacWSActiveDenseGridPolicy != nil;
    // A grid is a reusable calculator, not a Scene. Explicit group/item
    // ownership takes precedence over a gesture association left on it.
    BOOL host = !stageLimitScope && (itemScope ? scopedHostItem :
        (activeHost || associatedPolicy != nil || programmaticHost));
    NSDictionary *policy = itemScope
        ? (scopedHostItem ? MacWSActiveDenseGridPolicy : nil)
        : (stageLimitScope ? nil :
           ((activeHost || programmaticHost)
               ? MacWSActiveDenseGridPolicy : associatedPolicy));
    if (initialHost) MacWSInitialGridObserved = YES;
    NSNumber *lastScope = objc_getAssociatedObject(
        self, &MacWSLayoutGridLastHostScopeAssociationKey);
    BOOL changedScope = lastScope && lastScope.boolValue != host;
    // SBDisplayItemLayoutGrid owns `_gridCache` (runtime-confirmed at +8).
    // A cache created for the Host's dense candidates must never be reused by
    // the next stock app, and a stock cache must not hide Host candidates.
    if (changedScope || (!lastScope && host)) {
        SEL clearSelector = NSSelectorFromString(@"clearCachedGrids");
        if ([(id)self respondsToSelector:clearSelector])
            ((void (*)(id, SEL))objc_msgSend)((id)self, clearSelector);
    }
    if (!lastScope || changedScope) {
        objc_setAssociatedObject(
            self, &MacWSLayoutGridLastHostScopeAssociationKey, @(host),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"dense-grid-scope target=%@ proposed=%.1fx%.1f cache-cleared=%@",
            host ? @"com.macwsguide.host" : @"stock-app",
            proposedSize.width, proposedSize.height,
            (changedScope || host) ? @"YES" : @"NO"]);
    }
    CGSize constrainedSize = proposedSize;
    if (policy) {
        CGFloat minimumWidth = [policy[@"minimum_width"] doubleValue];
        CGFloat minimumHeight = [policy[@"minimum_height"] doubleValue];
        CGFloat maximumWidth = [policy[@"maximum_width"] doubleValue];
        CGFloat maximumHeight = [policy[@"maximum_height"] doubleValue];
        // During initial layout the published geometry is the requested Scene
        // size even when the AppKit window remains resizable afterward. Feed
        // that exact proposal into Apple's ordinary nearest-grid algorithm;
        // the scoped dense candidate set contains the same target, so system
        // validation and quantization remain intact without a corrective
        // post-connection resize.
        if (initialHost || [policy[@"fixed_width"] boolValue])
            constrainedSize.width = [policy[@"target_width"] doubleValue];
        else
            constrainedSize.width = MAX(constrainedSize.width, minimumWidth);
        if (initialHost || [policy[@"fixed_height"] boolValue])
            constrainedSize.height = [policy[@"target_height"] doubleValue];
        else
            constrainedSize.height = MAX(constrainedSize.height, minimumHeight);
        if (maximumWidth > 0.0)
            constrainedSize.width = MIN(constrainedSize.width, maximumWidth);
        if (maximumHeight > 0.0)
            constrainedSize.height = MIN(constrainedSize.height, maximumHeight);
    }
    NSDictionary *previousPolicy = MacWSActiveDenseGridPolicy;
    CGSize previousProposal = MacWSActiveDenseGridProposal;
    NSArray<NSNumber *> *originalWidths = nil;
    NSArray<NSNumber *> *originalHeights = nil;
    NSArray<NSNumber *> *denseWidths = nil;
    NSArray<NSNumber *> *denseHeights = nil;
    if (host) {
        MacWSActiveDenseGridPolicy = policy;
        MacWSActiveDenseGridProposal = constrainedSize;
        // The target build caches candidate arrays inside the attributes
        // object before this method. A scoped getter alone produced expanded
        // witness files but the actual nearest-size computation still read
        // that cached stock array. Temporarily install dense arrays on the
        // exact attributes argument, run Apple's original calculation, then
        // restore both arrays and invalidate the grid cache on the same main-
        // thread stack. No stock application can observe this transaction.
        // A programmatic AppKit->Scene transition can enter this method while
        // MacWSDenseGridScopeDepth is already nonzero. Calling our scoped
        // getters in that state returns the expanded arrays and then the old
        // finally block wrote those arrays back as the supposed originals.
        // Runtime-confirmed at 1789061605.048: even a `stock-app` lookup then
        // reported stock=129x84 instead of 8x4. Read the real stored arrays
        // with the getter scope temporarily disabled, then restore the exact
        // prior nesting depth before running Apple's calculation.
        NSUInteger outerDepth = MacWSDenseGridScopeDepth;
        MacWSDenseGridScopeDepth = 0;
        @try {
            originalWidths = MacWSMessageObject(
                chamoisLayoutAttributes, NSSelectorFromString(@"gridWidths"));
            originalHeights = MacWSMessageObject(
                chamoisLayoutAttributes, NSSelectorFromString(@"gridHeights"));
        } @finally {
            MacWSDenseGridScopeDepth = outerDepth;
        }
        denseWidths = MacWSDenseCandidates(originalWidths, "host-width");
        denseHeights = MacWSDenseCandidates(originalHeights, "host-height");
        SEL setWidths = NSSelectorFromString(@"setGridWidths:");
        SEL setHeights = NSSelectorFromString(@"setGridHeights:");
        if ([chamoisLayoutAttributes respondsToSelector:setWidths] &&
            denseWidths)
            ((void (*)(id, SEL, id))objc_msgSend)(
                chamoisLayoutAttributes, setWidths, denseWidths);
        if ([chamoisLayoutAttributes respondsToSelector:setHeights] &&
            denseHeights)
            ((void (*)(id, SEL, id))objc_msgSend)(
                chamoisLayoutAttributes, setHeights, denseHeights);
        SEL clearSelector = NSSelectorFromString(@"clearCachedGrids");
        if ([(id)self respondsToSelector:clearSelector])
            ((void (*)(id, SEL))objc_msgSend)((id)self, clearSelector);
        MacWSDenseGridScopeDepth++;
    }
    CGSize result = CGSizeZero;
    @try {
        result = %orig(constrainedSize, countOnStage, bounds,
                       contentOrientation, layoutRestrictionInfo,
                       screenScale, chamoisLayoutAttributes);
    } @finally {
        if (host) {
            MacWSDenseGridScopeDepth--;
            SEL setWidths = NSSelectorFromString(@"setGridWidths:");
            SEL setHeights = NSSelectorFromString(@"setGridHeights:");
            if ([chamoisLayoutAttributes respondsToSelector:setWidths] &&
                originalWidths)
                ((void (*)(id, SEL, id))objc_msgSend)(
                    chamoisLayoutAttributes, setWidths, originalWidths);
            if ([chamoisLayoutAttributes respondsToSelector:setHeights] &&
                originalHeights)
                ((void (*)(id, SEL, id))objc_msgSend)(
                    chamoisLayoutAttributes, setHeights, originalHeights);
            SEL clearSelector = NSSelectorFromString(@"clearCachedGrids");
            if ([(id)self respondsToSelector:clearSelector])
                ((void (*)(id, SEL))objc_msgSend)((id)self, clearSelector);
            MacWSActiveDenseGridProposal = previousProposal;
            MacWSActiveDenseGridPolicy = previousPolicy;
        }
    }
    if (stageLimitScope) {
        static CGSize lastStageProposal;
        static CGSize lastStageResult;
        if (!CGSizeEqualToSize(lastStageProposal, proposedSize) ||
            !CGSizeEqualToSize(lastStageResult, result)) {
            lastStageProposal = proposedSize;
            lastStageResult = result;
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"stage-layout-limit proposed=%.1fx%.1f result=%.1fx%.1f item-policy=none count=%lu",
                proposedSize.width, proposedSize.height,
                result.width, result.height, (unsigned long)countOnStage]);
        }
    }
    if (host) {
        static CFTimeInterval lastGridResultWitness;
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - lastGridResultWitness >= 0.10) {
            lastGridResultWitness = now;
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"dense-grid-result grid=%p proposed=%.1fx%.1f constrained=%.1fx%.1f result=%.1fx%.1f candidates=%lux%lu stock=%lux%lu policy=%@",
                self, proposedSize.width, proposedSize.height,
                constrainedSize.width, constrainedSize.height,
                result.width, result.height,
                (unsigned long)denseWidths.count,
                (unsigned long)denseHeights.count,
                (unsigned long)originalWidths.count,
                (unsigned long)originalHeights.count,
                policy[@"scene_identifier"] ?: @"none"]);
        }
    }
    if (policy && (fabs(constrainedSize.width - proposedSize.width) > 0.5 ||
                   fabs(constrainedSize.height - proposedSize.height) > 0.5)) {
        static CFTimeInterval lastPolicyWitness;
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - lastPolicyWitness >= 0.20) {
            lastPolicyWitness = now;
            MacWSWindowingLogLine([NSString stringWithFormat:
                @"resize-policy springback scene=%@ proposed=%.1fx%.1f constrained=%.1fx%.1f result=%.1fx%.1f fixed=%@x%@",
                policy[@"scene_identifier"], proposedSize.width,
                proposedSize.height, constrainedSize.width,
                constrainedSize.height, result.width, result.height,
                [policy[@"fixed_width"] boolValue] ? @"YES" : @"NO",
                [policy[@"fixed_height"] boolValue] ? @"YES" : @"NO"]);
        }
    }
    return result;
}

// Runtime-confirmed on iPad14,5 / iPadOS 16.0 (20A8372) via the diagnostic
// method inventory at 1790262629.176: this release has no
// `nearestGridSizeForProposedSize:countOnStage:...` entry point and no
// `SBSwitcherChamoisSettings _nearestGridSizeForSize:...` leaf. Its real
// SBDisplayItemLayoutGrid entry point is this six-argument variant with type
// encoding `{CGSize=dd}96@0:8{CGSize=dd}16{CGRect={CGPoint=dd}{CGSize=dd}}32q64@72d80@88`.
// Keep the same Host-only ownership, cache invalidation, candidate expansion,
// and exact restoration invariants as the 16.3 path above. If the newer
// countOnStage selector exists, return directly to Apple so a release that
// exposes both entry points cannot run two compatibility transactions.
- (CGSize)nearestGridSizeForProposedSize:(CGSize)proposedSize
                                inBounds:(CGRect)bounds
                      contentOrientation:(NSInteger)contentOrientation
                   layoutRestrictionInfo:(id)layoutRestrictionInfo
                             screenScale:(CGFloat)screenScale
                chamoisLayoutAttributes:(id)chamoisLayoutAttributes {
    SEL countOnStageSelector = NSSelectorFromString(
        @"nearestGridSizeForProposedSize:countOnStage:inBounds:contentOrientation:layoutRestrictionInfo:screenScale:chamoisLayoutAttributes:");
    if (class_getInstanceMethod(object_getClass((id)self),
                                countOnStageSelector))
        return %orig(proposedSize, bounds, contentOrientation,
                     layoutRestrictionInfo, screenScale,
                     chamoisLayoutAttributes);

    BOOL itemScope = MacWSItemLayoutScopeDepth > 0;
    BOOL stageLimitScope = MacWSGroupLayoutScopeDepth > 0 && !itemScope;
    BOOL scopedHostItem = itemScope &&
        MacWSActiveLayoutSceneIdentifier.length > 0;
    BOOL activeHost = MacWSResizeModifierTargetsHost(
        MacWSActiveResizeGestureModifier);
    NSDictionary *associatedPolicy = objc_getAssociatedObject(
        self, &MacWSLayoutGridHostPolicyAssociationKey);
    BOOL initialScope = scopedHostItem && MacWSInitialLayoutScopeDepth > 0 &&
        MacWSActiveDenseGridPolicy != nil;
    BOOL initialHost = initialScope;
    BOOL programmaticHost = !initialScope && MacWSDenseGridScopeDepth > 0 &&
        MacWSActiveDenseGridPolicy != nil;
    BOOL host = !stageLimitScope && (itemScope ? scopedHostItem :
        (activeHost || associatedPolicy != nil || programmaticHost));
    NSDictionary *policy = itemScope
        ? (scopedHostItem ? MacWSActiveDenseGridPolicy : nil)
        : (stageLimitScope ? nil :
           ((activeHost || programmaticHost)
               ? MacWSActiveDenseGridPolicy : associatedPolicy));
    if (initialHost) MacWSInitialGridObserved = YES;

    NSNumber *lastScope = objc_getAssociatedObject(
        self, &MacWSLayoutGridLastHostScopeAssociationKey);
    BOOL changedScope = lastScope && lastScope.boolValue != host;
    if (changedScope || (!lastScope && host)) {
        SEL clearSelector = NSSelectorFromString(@"clearCachedGrids");
        if ([(id)self respondsToSelector:clearSelector])
            ((void (*)(id, SEL))objc_msgSend)((id)self, clearSelector);
    }
    if (!lastScope || changedScope) {
        objc_setAssociatedObject(
            self, &MacWSLayoutGridLastHostScopeAssociationKey, @(host),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"dense-grid-16.0-scope target=%@ proposed=%.1fx%.1f cache-cleared=%@",
            host ? @"com.macwsguide.host" : @"stock-app",
            proposedSize.width, proposedSize.height,
            (changedScope || host) ? @"YES" : @"NO"]);
    }

    CGSize constrainedSize = proposedSize;
    if (policy) {
        CGFloat minimumWidth = [policy[@"minimum_width"] doubleValue];
        CGFloat minimumHeight = [policy[@"minimum_height"] doubleValue];
        CGFloat maximumWidth = [policy[@"maximum_width"] doubleValue];
        CGFloat maximumHeight = [policy[@"maximum_height"] doubleValue];
        if (initialHost || [policy[@"fixed_width"] boolValue])
            constrainedSize.width = [policy[@"target_width"] doubleValue];
        else
            constrainedSize.width = MAX(constrainedSize.width, minimumWidth);
        if (initialHost || [policy[@"fixed_height"] boolValue])
            constrainedSize.height = [policy[@"target_height"] doubleValue];
        else
            constrainedSize.height = MAX(constrainedSize.height, minimumHeight);
        if (maximumWidth > 0.0)
            constrainedSize.width = MIN(constrainedSize.width, maximumWidth);
        if (maximumHeight > 0.0)
            constrainedSize.height = MIN(constrainedSize.height, maximumHeight);
    }

    NSDictionary *previousPolicy = MacWSActiveDenseGridPolicy;
    CGSize previousProposal = MacWSActiveDenseGridProposal;
    NSArray<NSNumber *> *originalWidths = nil;
    NSArray<NSNumber *> *originalHeights = nil;
    NSArray<NSNumber *> *denseWidths = nil;
    NSArray<NSNumber *> *denseHeights = nil;
    if (host) {
        MacWSActiveDenseGridPolicy = policy;
        MacWSActiveDenseGridProposal = constrainedSize;
        NSUInteger outerDepth = MacWSDenseGridScopeDepth;
        MacWSDenseGridScopeDepth = 0;
        @try {
            originalWidths = MacWSMessageObject(
                chamoisLayoutAttributes, NSSelectorFromString(@"gridWidths"));
            originalHeights = MacWSMessageObject(
                chamoisLayoutAttributes, NSSelectorFromString(@"gridHeights"));
        } @finally {
            MacWSDenseGridScopeDepth = outerDepth;
        }
        denseWidths = MacWSDenseCandidates(originalWidths, "host-width-16.0");
        denseHeights = MacWSDenseCandidates(
            originalHeights, "host-height-16.0");
        SEL setWidths = NSSelectorFromString(@"setGridWidths:");
        SEL setHeights = NSSelectorFromString(@"setGridHeights:");
        if ([chamoisLayoutAttributes respondsToSelector:setWidths] &&
            denseWidths)
            ((void (*)(id, SEL, id))objc_msgSend)(
                chamoisLayoutAttributes, setWidths, denseWidths);
        if ([chamoisLayoutAttributes respondsToSelector:setHeights] &&
            denseHeights)
            ((void (*)(id, SEL, id))objc_msgSend)(
                chamoisLayoutAttributes, setHeights, denseHeights);
        SEL clearSelector = NSSelectorFromString(@"clearCachedGrids");
        if ([(id)self respondsToSelector:clearSelector])
            ((void (*)(id, SEL))objc_msgSend)((id)self, clearSelector);
        MacWSDenseGridScopeDepth++;
    }

    CGSize result = CGSizeZero;
    @try {
        result = %orig(constrainedSize, bounds, contentOrientation,
                       layoutRestrictionInfo, screenScale,
                       chamoisLayoutAttributes);
    } @finally {
        if (host) {
            MacWSDenseGridScopeDepth--;
            SEL setWidths = NSSelectorFromString(@"setGridWidths:");
            SEL setHeights = NSSelectorFromString(@"setGridHeights:");
            if ([chamoisLayoutAttributes respondsToSelector:setWidths] &&
                originalWidths)
                ((void (*)(id, SEL, id))objc_msgSend)(
                    chamoisLayoutAttributes, setWidths, originalWidths);
            if ([chamoisLayoutAttributes respondsToSelector:setHeights] &&
                originalHeights)
                ((void (*)(id, SEL, id))objc_msgSend)(
                    chamoisLayoutAttributes, setHeights, originalHeights);
            SEL clearSelector = NSSelectorFromString(@"clearCachedGrids");
            if ([(id)self respondsToSelector:clearSelector])
                ((void (*)(id, SEL))objc_msgSend)((id)self, clearSelector);
            MacWSActiveDenseGridProposal = previousProposal;
            MacWSActiveDenseGridPolicy = previousPolicy;
        }
    }

    if (host) {
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"dense-grid-16.0-result grid=%p proposed=%.1fx%.1f constrained=%.1fx%.1f result=%.1fx%.1f candidates=%lux%lu stock=%lux%lu policy=%@",
            self, proposedSize.width, proposedSize.height,
            constrainedSize.width, constrainedSize.height,
            result.width, result.height,
            (unsigned long)denseWidths.count,
            (unsigned long)denseHeights.count,
            (unsigned long)originalWidths.count,
            (unsigned long)originalHeights.count,
            policy[@"scene_identifier"] ?: @"none"]);
    }
    return result;
}
%end

%hook SBSwitcherChamoisSettings
- (CGSize)_nearestGridSizeForSize:(CGSize)proposedSize
                        gridWidths:(NSArray<NSNumber *> *)gridWidths
                       gridHeights:(NSArray<NSNumber *> *)gridHeights
                            bounds:(CGRect)bounds {
    if ((MacWSGroupLayoutScopeDepth > 0 && MacWSItemLayoutScopeDepth == 0) ||
        (MacWSItemLayoutScopeDepth > 0 && !MacWSActiveLayoutSceneIdentifier.length))
        return %orig(proposedSize, gridWidths, gridHeights, bounds);
    // RE-confirmed via SpringBoard 20D67 at 0x1c7bd311c: this is the leaf
    // Chamois quantizer which iterates the supplied width and height arrays.
    // The wrapper SBDisplayItemLayoutGrid call can return an exact Host size,
    // but the same gesture performs another leaf quantization before UIKit
    // receives its final Scene geometry.  Runtime evidence at
    // 1789135985.534-.5989.589 showed the wrapper returning exact values such
    // as 962x441 and 1044.5x604 while the Host Scene still landed only on the
    // stock 1004/891/665/327 widths.  Supply dense arrays at this leaf for the
    // exact, synchronously selected Host gesture.  Programmatic and initial
    // transactions retain their already identity-validated short-lived
    // scopes; every stock application receives Apple's arrays byte-for-byte.
    BOOL activeHost = MacWSResizeModifierTargetsHost(
        MacWSActiveResizeGestureModifier);
    BOOL initialHost = MacWSInitialLayoutScopeDepth > 0 &&
        MacWSActiveDenseGridPolicy != nil;
    BOOL programmaticHost = MacWSInitialLayoutScopeDepth == 0 &&
        MacWSDenseGridScopeDepth > 0 &&
        MacWSActiveDenseGridPolicy != nil;
    if (!activeHost && !initialHost && !programmaticHost)
        return %orig(proposedSize, gridWidths, gridHeights, bounds);

    CGSize previousProposal = MacWSActiveDenseGridProposal;
    MacWSActiveDenseGridProposal = proposedSize;
    NSArray<NSNumber *> *denseWidths = MacWSDenseCandidates(
        gridWidths, "host-leaf-width");
    NSArray<NSNumber *> *denseHeights = MacWSDenseCandidates(
        gridHeights, "host-leaf-height");
    CGSize result = %orig(proposedSize, denseWidths, denseHeights, bounds);
    MacWSActiveDenseGridProposal = previousProposal;

    static CFTimeInterval lastLeafWitness;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - lastLeafWitness >= 0.10) {
        lastLeafWitness = now;
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"dense-grid-leaf proposed=%.1fx%.1f result=%.1fx%.1f candidates=%lux%lu scope=%@",
            proposedSize.width, proposedSize.height,
            result.width, result.height,
            (unsigned long)denseWidths.count,
            (unsigned long)denseHeights.count,
            activeHost ? @"gesture" :
                (initialHost ? @"initial" : @"programmatic")]);
    }
    return result;
}
%end

static uint8_t MacWSWindowingCapabilities;

static void MacWSPublishWindowingCapabilities(
        CFNotificationCenterRef center, void *observer, CFStringRef name,
        const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    int token = MacWSWindowingStateToken();
    if (token >= 0 && MacWSWindowingCapabilities != 0) {
        notify_set_state(token, MacWSWindowingState(
            (uint32_t)getpid(), MacWSWindowingCapabilities));
        notify_post(MACWS_WINDOWING_STATE_NAME);
    }
}

static void MacWSObserveChamoisWindowingState(BOOL active) {
    uint8_t previous = MacWSWindowingCapabilities;
    MacWSWindowingCapabilities |= MacWSWindowingChamoisKnown;
    if (active)
        MacWSWindowingCapabilities |= MacWSWindowingChamoisActive;
    else
        MacWSWindowingCapabilities &=
            (uint8_t)~MacWSWindowingChamoisActive;
    if (MacWSWindowingCapabilities == previous) return;

    // Mode changes are rare and this line is the runtime witness consumed by
    // deployment validation.  It remains available without enabling the
    // high-volume windowing diagnostic recorder.
    MacWSWindowingWriteDiagnosticLine([NSString stringWithFormat:
        @"chamois-windowing-state known=YES active=%@ source=frame-calculator",
        active ? @"YES" : @"NO"]);
    MacWSPublishWindowingCapabilities(NULL, NULL, NULL, NULL, NULL);
}

static void MacWSInstallRequestObservers(void *context) {
    (void)context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterRef center =
            CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(
            center, NULL, MacWSHandleFullscreenRequest,
            MacWSRequestFullscreenNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(
            center, NULL, MacWSHandleResizeRequest,
            MacWSRequestResizeNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(
            center, NULL, MacWSHandleInitialSizeRequest,
            MacWSRequestInitialSizeNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        Class coordinatorClass = NSClassFromString(
            @"SBMainSwitcherControllerCoordinator");
        SEL initialSelector = NSSelectorFromString(
            @"addCenterRoleAppLayoutForDisplayItem:windowScene:completion:");
        Method initialMethod = coordinatorClass
            ? class_getInstanceMethod(coordinatorClass, initialSelector) : NULL;
        Class chamoisSettingsClass = NSClassFromString(
            @"SBSwitcherChamoisSettings");
        SEL leafGridSelector = NSSelectorFromString(
            @"_nearestGridSizeForSize:gridWidths:gridHeights:bounds:");
        Method leafGridMethod = chamoisSettingsClass
            ? class_getInstanceMethod(chamoisSettingsClass, leafGridSelector)
            : NULL;
        Class layoutGridClass = NSClassFromString(@"SBDisplayItemLayoutGrid");
        SEL countOnStageGridSelector = NSSelectorFromString(
            @"nearestGridSizeForProposedSize:countOnStage:inBounds:contentOrientation:layoutRestrictionInfo:screenScale:chamoisLayoutAttributes:");
        Method countOnStageGridMethod = layoutGridClass
            ? class_getInstanceMethod(
                layoutGridClass, countOnStageGridSelector) : NULL;
        SEL ios16GridSelector = NSSelectorFromString(
            @"nearestGridSizeForProposedSize:inBounds:contentOrientation:layoutRestrictionInfo:screenScale:chamoisLayoutAttributes:");
        Method ios16GridMethod = layoutGridClass
            ? class_getInstanceMethod(layoutGridClass, ios16GridSelector)
            : NULL;
        BOOL ios16GridPath = ios16GridMethod && !countOnStageGridMethod;
        BOOL denseGridPath = leafGridMethod || ios16GridPath;
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"initial-size method-metadata class=%@ selector=%@ encoding=%s leaf-class=%@ leaf-selector=%@ leaf-encoding=%s grid-class=%@ count-selector=%@ count-encoding=%s ios16-selector=%@ ios16-encoding=%s selected=%@",
            coordinatorClass ? @"YES" : @"NO",
            initialMethod ? @"YES" : @"NO",
            initialMethod ? method_getTypeEncoding(initialMethod) : "missing",
            chamoisSettingsClass ? @"YES" : @"NO",
            leafGridMethod ? @"YES" : @"NO",
            leafGridMethod ? method_getTypeEncoding(leafGridMethod) :
                "missing",
            layoutGridClass ? @"YES" : @"NO",
            countOnStageGridMethod ? @"YES" : @"NO",
            countOnStageGridMethod
                ? method_getTypeEncoding(countOnStageGridMethod) : "missing",
            ios16GridMethod ? @"YES" : @"NO",
            ios16GridMethod ? method_getTypeEncoding(ios16GridMethod) :
                "missing",
            leafGridMethod ? @"leaf" :
                (ios16GridPath ? @"ios16-grid" : @"none")]);
        Class transitionRequestClass = NSClassFromString(
            @"SBMutableSwitcherTransitionRequest");
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"initial-size method-inventory transition-instance=[%@] transition-class=[%@] coordinator=[%@]",
            MacWSMethodInventory(transitionRequestClass,
                @[@"app", @"layout", @"activate", @"scene"]),
            MacWSMethodInventory(object_getClass(transitionRequestClass),
                @[@"app", @"layout", @"activate", @"scene"]),
            MacWSMethodInventory(coordinatorClass,
                @[@"center", @"layout", @"transition"])]);
        MacWSWindowingLogLine([NSString stringWithFormat:
            @"initial-size sizing-inventory attributes=[%@] grid=[%@] settings=[%@] app-layout=[%@]",
            MacWSMethodInventory(NSClassFromString(
                @"SBDisplayItemLayoutAttributes"),
                @[@"size", @"center", @"frame", @"grid", @"policy"]),
            MacWSMethodInventory(NSClassFromString(@"SBDisplayItemLayoutGrid"),
                @[@"size", @"grid", @"cache", @"attribute"]),
            MacWSMethodInventory(chamoisSettingsClass,
                @[@"size", @"grid", @"attribute", @"layout"]),
            MacWSMethodInventory(NSClassFromString(@"SBAppLayout"),
                @[@"item", @"role", @"attribute", @"layout"])]);

        // A shared, versioned IPC contract replaces the old .loaded file and
        // implementation-description string matching. Publish only after
        // request observers exist; real geometry remains the success witness.
        MacWSWindowingCapabilities |= MacWSWindowingFullscreen |
            MacWSWindowingResize | MacWSWindowingSceneConstraints;
        if (denseGridPath)
            MacWSWindowingCapabilities |= MacWSWindowingDenseGrid;
        if (initialMethod && denseGridPath)
            MacWSWindowingCapabilities |= MacWSWindowingInitialSize;
        CFNotificationCenterAddObserver(
            center, NULL, MacWSPublishWindowingCapabilities,
            CFSTR(MACWS_WINDOWING_REFRESH_NAME), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        MacWSPublishWindowingCapabilities(NULL, NULL, NULL, NULL, NULL);
    });
}

__attribute__((constructor)) static void MacWSWindowingInitialize(void) {
    // Keep the constructor side-effect minimal and publish readiness only
    // after the observers actually exist.  The original Safe Mode root cause
    // was NOT constructor timing: SpringBoard-2026-08-04-124439.ips reproduced
    // the same CFHash trap from the main queue and its register dump proved the
    // on-device arm64e linker emitted a malformed constant-object class
    // pointer. SpringBoard-2026-08-28-001431.ips proved that -fixup_chains
    // alone still emits plain, unauthenticated __cfstring binds. The packaging
    // invariant now replaces the on-device intermediate with an Apple-ld64
    // cross-build whose __cfstring class references are auth-bind/key=DA.
    dispatch_async_f(dispatch_get_main_queue(), NULL,
                     MacWSInstallRequestObservers);
}
