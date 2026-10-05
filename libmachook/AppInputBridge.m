// Per-application input endpoint for the native iPadOS host.
//
// macwsinputd cannot use CGEventPost across the chroot boundary: the actual
// runtime CGPreflightPostEventAccess result is NO, and CGWindowListCopyWindowInfo
// returns NULL for its launchd session.  Every supported AppKit application
// already loads libmachook, so receive the versioned record inside its target
// process and enqueue an ordinary NSEvent on that process's main thread.

@import Foundation;
@import Darwin;
@import CydiaSubstrate;

#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <math.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <ptrauth.h>
#import <ctype.h>
#import <crt_externs.h>
#import <stdatomic.h>
#import <stdarg.h>
#import <fcntl.h>
#import <stdio.h>
#import <time.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#import <xpc/xpc.h>
#import <notify.h>

#import "macws_control_protocol.h"
#import "macws_dock_expose_notify.h"
#import "macws_host_protocol.h"
#import "macws_power_lifecycle.h"
#import "macws_menu_protocol.h"
#import "macws_stream_protocol.h"
#import "macws_text_input.h"
#import "macws_window_configuration.h"
#import "MacWSCatalystInputPolicy.h"
#import "MacWSInputLatency.h"

// The Theos target uses an iPhoneOS SDK, which omits these macOS declarations
// even though libmachook is injected into Ventura processes and links its
// CoreGraphics at runtime. Keep the public macOS signatures explicit instead
// of weakening the calls to an untyped dlsym boundary.
extern CGError CGAssociateMouseAndMouseCursorPosition(boolean_t connected);
extern CGError CGDisplayHideCursor(uint32_t display);
extern CGError CGDisplayShowCursor(uint32_t display);
extern void CGGetLastMouseDelta(int32_t *deltaX, int32_t *deltaY);

typedef id (*MacWSMsgID)(id, SEL);
typedef id (*MacWSMsgIDID)(id, SEL, id);
typedef id (*MacWSMsgIDInteger)(id, SEL, NSInteger);
typedef CGRect (*MacWSMsgRect)(id, SEL);
typedef CGRect (*MacWSMsgRectRect)(id, SEL, CGRect);
typedef CGRect (*MacWSMsgRectRectID)(id, SEL, CGRect, id);
typedef CGPoint (*MacWSMsgPoint)(id, SEL);
typedef CGPoint (*MacWSMsgPointPoint)(id, SEL, CGPoint);
typedef CGPoint (*MacWSMsgPointPointID)(id, SEL, CGPoint, id);
typedef NSInteger (*MacWSMsgInteger)(id, SEL);
typedef NSInteger (*MacWSMsgIntegerPointInteger)(id, SEL, CGPoint, NSInteger);
typedef NSUInteger (*MacWSMsgUInteger)(id, SEL);
typedef CGSize (*MacWSMsgSize)(id, SEL);
typedef CGSize (*MacWSMsgSizeIDSize)(id, SEL, id, CGSize);
typedef BOOL (*MacWSMsgBool)(id, SEL);
typedef BOOL (*MacWSMsgBoolSEL)(id, SEL, SEL);
typedef BOOL (*MacWSMsgBoolID)(id, SEL, id);
typedef BOOL (*MacWSMsgBoolIDID)(id, SEL, id, id);
typedef BOOL (*MacWSMsgBoolSELIDID)(id, SEL, SEL, id, id);
typedef void (*MacWSMsgVoid)(id, SEL);
typedef void (*MacWSMsgVoidBool)(id, SEL, BOOL);
typedef void (*MacWSMsgVoidID)(id, SEL, id);
typedef void (*MacWSMsgVoidIDID)(id, SEL, id, id);
typedef void (*MacWSMsgVoidIDBool)(id, SEL, id, BOOL);
typedef void (*MacWSMsgVoidRectBoolBool)(id, SEL, CGRect, BOOL, BOOL);
typedef void (*MacWSWorkspaceOpenURLFunction)(id, SEL, id, id, id);
typedef void (*MacWSWorkspaceOpenURLsFunction)(id, SEL, id, id, id, id);
typedef BOOL (*MacWSWorkspaceLegacyOpenURLFunction)(id, SEL, id);
typedef void (*MacWSSeamlessOpenFailureFunction)(id, SEL, id, id, id);
typedef double (*MacWSMsgDouble)(id, SEL);
typedef float (*MacWSMsgFloat)(id, SEL);
typedef id (*MacWSMsgIDPoint)(id, SEL, CGPoint);
typedef id (*MacWSMouseEventFactory)(id, SEL, NSUInteger, CGPoint, NSUInteger,
                                     NSTimeInterval, NSInteger, id, NSInteger,
                                     NSInteger, float);
typedef id (*MacWSKeyEventFactory)(id, SEL, NSUInteger, CGPoint, NSUInteger,
                                   NSTimeInterval, NSInteger, id, id, id,
                                   BOOL, unsigned short);
typedef const void *MacWSCGEventRef;
typedef MacWSCGEventRef (*MacWSCreateCGEvent)(const void *);
typedef MacWSCGEventRef (*MacWSCopyCGEvent)(MacWSCGEventRef);
typedef uint32_t (*MacWSGetCGEventType)(MacWSCGEventRef);
typedef CGPoint (*MacWSGetCGEventLocation)(MacWSCGEventRef);
typedef MacWSCGEventRef (*MacWSCreateKeyboardCGEvent)(
    const void *, unsigned short, bool);
typedef MacWSCGEventRef (*MacWSCreateMouseCGEvent)(
    const void *, uint32_t, CGPoint, uint32_t);
typedef MacWSCGEventRef (*MacWSCreateScrollWheelCGEvent)(
    const void *, uint32_t, uint32_t, ...);
typedef MacWSCGEventRef (*MacWSCreateScrollWheelCGEvent2)(
    const void *, uint32_t, uint32_t, int32_t, int32_t, int32_t);
typedef void (*MacWSSetCGEventFlags)(MacWSCGEventRef, uint64_t);
typedef void (*MacWSSetCGEventLocation)(MacWSCGEventRef, CGPoint);
typedef void (*MacWSSetCGEventTimestamp)(MacWSCGEventRef, uint64_t);
typedef void (*MacWSSetCGEventType)(MacWSCGEventRef, uint32_t);
typedef void (*MacWSSetCGEventUnicode)(MacWSCGEventRef, size_t,
                                      const unichar *);
typedef void (*MacWSSetCGEventIntegerField)(MacWSCGEventRef, uint32_t,
                                            int64_t);
typedef void (*MacWSSetCGEventDoubleField)(MacWSCGEventRef, uint32_t, double);
typedef int64_t (*MacWSGetCGEventIntegerField)(MacWSCGEventRef, uint32_t);
typedef double (*MacWSGetCGEventDoubleField)(MacWSCGEventRef, uint32_t);
typedef void *(*MacWSSLEventRecordPointer)(MacWSCGEventRef);
typedef void (*MacWSPostCGEvent)(uint32_t, MacWSCGEventRef);
// CGRemoteOperation.h declares mouseButtonDown as a fixed boolean_t argument;
// only buttons 2+ are variadic.  This distinction is load-bearing on arm64:
// Darwin passes that fixed argument in w2 while the variadic button states
// begin in the stack argument area.  Declaring every button as variadic left
// w2 unrelated to the requested state and turned Host primary clicks into
// secondary events while leaving the real primary state stuck down.
typedef int32_t (*MacWSPostLegacyMouseEvent)(CGPoint, int32_t, uint32_t,
                                             int32_t, ...);
typedef int32_t (*MacWSPostLegacyScrollEvent)(uint32_t, int32_t, ...);
typedef int32_t (*MacWSPostLegacyKeyboardEvent)(uint16_t, uint16_t, int32_t);
typedef id (*MacWSEventFromCGEvent)(id, SEL, MacWSCGEventRef);
typedef const void *(*MacWSEventRef)(id, SEL);
typedef void (*MacWSPostEvent)(id, SEL, id, BOOL);
typedef void (*MacWSSendEvent)(id, SEL, id);
typedef BOOL (*MacWSUnityDidSendEvent)(id, SEL, id);
typedef uint64_t (*MacWSCGEventSourceFlagsState)(int32_t);
typedef id (*MacWSNextEvent)(id, SEL, NSUInteger, id, id, BOOL);
typedef void (*MacWSHandleApplicationEvent)(id, SEL, id);
typedef void (*MacWSMenuEventLoop)(id, SEL, BOOL, id);
typedef NSUInteger (*MacWSPressedMouseButtons)(id, SEL);
typedef CGPoint (*MacWSMouseLocation)(id, SEL);
typedef int32_t (*MacWSCancelMenuTrackingPrivate)(uint8_t);
typedef int32_t (*MacWSCGWindowLevelForKey)(int32_t);
typedef CFArrayRef (*MacWSCGWindowListCopyWindowInfo)(uint32_t, uint32_t);
typedef void (*MacWSOrderWindow)(id, SEL, NSInteger, NSInteger);
typedef void (*MacWSToggleFullScreen)(id, SEL, id);

static int MacWSAppInputSocket = -1;
static _Atomic int MacWSAppInputInstallState;
static char MacWSAppInputPath[sizeof(((struct sockaddr_un *)0)->sun_path)];
static char MacWSWindowMetricsPath[PATH_MAX];
static NSData *MacWSLastWindowMetricsEntries;
static uint64_t MacWSWindowMetricsGeneration;
static id MacWSWindowGeometryObserverInstance;
static BOOL MacWSWindowMetricsEventPublishPending;
// Window metrics publish the application's live relative-mouse contract on
// the exact key window so Host can follow application intent without a
// bundle-ID allowlist. CGAssociate(false) is the direct contract. Some Unity
// players instead hide the CoreGraphics cursor and continuously consume
// CGGetLastMouseDelta; that paired producer/consumer state is equivalent but
// expires when polling stops. Unity 2022.3 also has a stronger process-local
// contract: -[PlayerWindowView setShowCursor:] is the engine boundary that
// applies Cursor.visible to its real AppKit view. Observe that exact request while
// still calling Unity's original implementation; do not infer game state from
// a bundle identifier, title, or a globally hidden cursor.
static _Atomic bool MacWSRelativePointerRequested;
static _Atomic bool MacWSMouseAssociationRelative;
static _Atomic uint32_t MacWSCursorHideDepth;
static _Atomic uint64_t MacWSLastMouseDeltaMonotonicNS;
static _Atomic bool MacWSMouseDeltaExpiryScheduled;
static _Atomic bool MacWSUnityCursorHidden;
static _Atomic bool MacWSUnityCursorStateKnown;
// The application event loop may keep dispatching AppKit events while no
// longer servicing libdispatch's main queue.  Keep request/publication
// generations separate so that the same event boundary which observes a
// relative-mode transition can synchronously publish it exactly once.
static _Atomic uint64_t MacWSRelativePointerRequestGeneration;
static _Atomic uint64_t MacWSRelativePointerPublishedGeneration;
static MacWSMsgVoidBool MacWSOriginalUnitySetShowCursor;
static MacWSMsgVoidID MacWSOriginalUnityMouseDown;
static MacWSMsgVoidID MacWSOriginalUnityMouseUp;
static MacWSMsgVoidID MacWSOriginalUnityMouseMoved;
static MacWSMsgVoidID MacWSOriginalUnityKeyDown;
static MacWSMsgVoidID MacWSOriginalUnityKeyUp;
static void MacWSReconcileUnityViewAndPublish(id unityView,
                                             const char *boundary);
static char MacWSWindowConfigureAckKey;
static char MacWSWindowScreenConstraintPolicyKey;
static void MacWSPublishWindowMetrics(void);
static void MacWSEnqueueAppInputRecord(MacWSInputRecord record);
extern void MacWSInstallPreviewCoreImageRendererAdapter(void);
static void MacWSNotifyDisplayCatalogChanged(uint8_t reason);
static void MacWSNotifyDisplayGeometryChanged(uint32_t windowID, id window,
                                              CGRect appliedFrame);
static void MacWSInstallWindowGeometryObservers(void);
static void MacWSClearDirectTrackingContextLocked(void);
static const char *MacWSAppInputProgramName(void);
static void MacWSMarkProcessLocalMouseEvent(id event);
static BOOL MacWSIsProcessLocalMouseEvent(id event);
static BOOL MacWSMainBundleUsesFullscreenCanvasPresentation(void);
static void MacWSInstallFullscreenTransitionPrerequisite(void);
static void MacWSLogUnityNGUIInputState(const char *phase);
static BOOL MacWSWindowPresentationIsOnScreen(id window,
                                              BOOL *knownOut);
static id MacWSPresentingWindow(id window, id application);
static char MacWSTransientWindowAssociationKey;
static id MacWSRootPresentingWindow(id window, id application);
static BOOL MacWSRuntimeDiagnosticsEnabled(void);
static BOOL MacWSGamePointerDiagnosticsEnabled(void);
static int MacWSWorkspaceWillSleepToken = -1;
static int MacWSWorkspaceDidWakeToken = -1;

static uint64_t MacWSMonotonicNanoseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) +
        (uint64_t)now.tv_nsec;
}

static BOOL MacWSMouseDeltaIsRecent(uint64_t now) {
    uint64_t last = atomic_load_explicit(
        &MacWSLastMouseDeltaMonotonicNS, memory_order_acquire);
    return now != 0 && last != 0 && now >= last &&
        now - last <= UINT64_C(1000000000);
}

static void MacWSSetRelativePointerRequestedAndPublish(BOOL requested,
                                                       const char *source,
                                                       BOOL publishMetrics) {
    bool previous = atomic_exchange_explicit(
        &MacWSRelativePointerRequested, requested, memory_order_acq_rel);
    if (previous == requested) return;
    atomic_fetch_add_explicit(&MacWSRelativePointerRequestGeneration, 1,
                              memory_order_acq_rel);

    fprintf(stderr,
        "#### APP-INPUT RELATIVE-REQUEST pid=%d requested=%s source=%s "
        "associated=%s hidden-depth=%u\n",
        getpid(), requested ? "YES" : "NO", source ?: "unknown",
        atomic_load_explicit(&MacWSMouseAssociationRelative,
                             memory_order_acquire) ? "YES" : "NO",
        atomic_load_explicit(&MacWSCursorHideDepth,
                             memory_order_acquire));
    fflush(stderr);
    if (publishMetrics) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (atomic_load_explicit(&MacWSAppInputInstallState,
                                     memory_order_acquire) == 2) {
                MacWSPublishWindowMetrics();
            }
        });
    }
}

static void MacWSSetRelativePointerRequested(BOOL requested,
                                             const char *source) {
    MacWSSetRelativePointerRequestedAndPublish(requested, source, YES);
}

static void MacWSRefreshRelativePointerRequested(const char *source) {
    BOOL associated = atomic_load_explicit(
        &MacWSMouseAssociationRelative, memory_order_acquire);
    BOOL unityCursorHidden = atomic_load_explicit(
        &MacWSUnityCursorHidden, memory_order_acquire);
    BOOL hidden = atomic_load_explicit(
        &MacWSCursorHideDepth, memory_order_acquire) != 0;
    BOOL consumingDeltas = hidden &&
        MacWSMouseDeltaIsRecent(MacWSMonotonicNanoseconds());
    MacWSSetRelativePointerRequested(
        associated || unityCursorHidden || consumingDeltas, source);
}

static void MacWSUnitySetShowCursor(id self, SEL selector, BOOL visible) {
    MacWSOriginalUnitySetShowCursor(self, selector, visible);
    atomic_store_explicit(&MacWSUnityCursorStateKnown, true,
                          memory_order_release);
    atomic_store_explicit(&MacWSUnityCursorHidden, !visible,
                          memory_order_release);
    if (MacWSGamePointerDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT RELATIVE-UNITY-CURSOR pid=%d visible=%s "
            "view=%p\n",
            getpid(), visible ? "YES" : "NO", self);
        fflush(stderr);
    }
    MacWSRefreshRelativePointerRequested(
        visible ? "PlayerWindowView.setShowCursor(true)"
                : "PlayerWindowView.setShowCursor(false)");
    MacWSReconcileUnityViewAndPublish(self, "setShowCursor:");
}

static id MacWSFindUnityPlayerView(id view, Class targetClass,
                                  NSUInteger depth, NSUInteger *budget) {
    if (!view || !targetClass || !budget || *budget == 0) return nil;
    (*budget)--;
    if (((MacWSMsgBoolID)objc_msgSend)(
            view, sel_registerName("isKindOfClass:"), (id)targetClass)) {
        return view;
    }
    if (depth == 0 || !((MacWSMsgBoolSEL)objc_msgSend)(
            view, sel_registerName("respondsToSelector:"),
            sel_registerName("subviews"))) return nil;
    id subviews = ((MacWSMsgID)objc_msgSend)(
        view, sel_registerName("subviews"));
    NSUInteger count = subviews ? [subviews count] : 0;
    for (NSUInteger index = 0; index < count && *budget != 0; index++) {
        id candidate = MacWSFindUnityPlayerView(
            [subviews objectAtIndex:index], targetClass, depth - 1, budget);
        if (candidate) return candidate;
    }
    return nil;
}

static id MacWSFindUnityPlayerResponder(id responder, Class targetClass) {
    SEL nextResponder = sel_registerName("nextResponder");
    for (NSUInteger index = 0;
         responder && targetClass && index < 32;
         index++) {
        if (((MacWSMsgBoolID)objc_msgSend)(
                responder, sel_registerName("isKindOfClass:"),
                (id)targetClass)) return responder;
        if (!((MacWSMsgBoolSEL)objc_msgSend)(
                responder, sel_registerName("respondsToSelector:"),
                nextResponder)) break;
        id next = ((MacWSMsgID)objc_msgSend)(responder, nextResponder);
        if (!next || next == responder) break;
        responder = next;
    }
    return nil;
}

// Reconcile the engine's current view state as part of the existing low-rate
// metrics pass. The setShowCursor: hook observes live transitions, while this
// getter closes the startup race where Unity assigned its ivar before the
// injected class was registered and swizzled. Keep the walk bounded and tied
// to the exact key window; an unrelated hidden CoreGraphics cursor is not a
// relative-pointer request.
static void MacWSReconcileUnityCursorState(id keyWindow) {
    Class unityViewClass = objc_getClass("PlayerWindowView");
    if (!unityViewClass) unityViewClass = objc_getClass("UnityView");
    SEL getter = sel_registerName("showCursor");
    Method method = unityViewClass
        ? class_getInstanceMethod(unityViewClass, getter) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    BOOL known = NO;
    BOOL visible = YES;
    id unityView = nil;
    id contentView = nil;
    id firstResponder = nil;
    if (keyWindow && encoding && strcmp(encoding, "B16@0:8") == 0) {
        contentView = ((MacWSMsgID)objc_msgSend)(
            keyWindow, sel_registerName("contentView"));
        NSUInteger budget = 256;
        unityView = MacWSFindUnityPlayerView(
            contentView, unityViewClass, 12, &budget);
        if (!unityView) {
            firstResponder = ((MacWSMsgID)objc_msgSend)(
                keyWindow, sel_registerName("firstResponder"));
            unityView = MacWSFindUnityPlayerResponder(
                firstResponder, unityViewClass);
        }
        if (unityView) {
            visible = ((MacWSMsgBool)objc_msgSend)(unityView, getter);
            known = YES;
        }
    }

    if (!known && unityViewClass && MacWSGamePointerDiagnosticsEnabled()) {
        static _Atomic bool loggedLookupMiss;
        if (!atomic_exchange_explicit(&loggedLookupMiss, true,
                                      memory_order_acq_rel)) {
            id subviews = contentView ? ((MacWSMsgID)objc_msgSend)(
                contentView, sel_registerName("subviews")) : nil;
            NSUInteger subviewCount = subviews ? [subviews count] : 0;
            fprintf(stderr,
                "#### APP-INPUT RELATIVE-UNITY-LOOKUP pid=%d found=NO "
                "window=%s content=%s subviews=%lu first=%s encoding=%s\n",
                getpid(), keyWindow ? object_getClassName(keyWindow) : "nil",
                contentView ? object_getClassName(contentView) : "nil",
                (unsigned long)subviewCount,
                firstResponder ? object_getClassName(firstResponder) : "nil",
                encoding ?: "<null>");
            fflush(stderr);
        }
    }

    bool hidden = known && !visible;
    bool previousKnown = atomic_exchange_explicit(
        &MacWSUnityCursorStateKnown, known, memory_order_acq_rel);
    bool previousHidden = atomic_exchange_explicit(
        &MacWSUnityCursorHidden, hidden, memory_order_acq_rel);
    if (previousKnown == known && previousHidden == hidden) return;
    if (MacWSGamePointerDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT RELATIVE-UNITY-STATE pid=%d known=%s "
            "visible=%s view=%p encoding=%s\n",
            getpid(), known ? "YES" : "NO", visible ? "YES" : "NO",
            unityView, encoding ?: "<null>");
        fflush(stderr);
    }

    BOOL associated = atomic_load_explicit(
        &MacWSMouseAssociationRelative, memory_order_acquire);
    BOOL cursorHidden = atomic_load_explicit(
        &MacWSCursorHideDepth, memory_order_acquire) != 0;
    BOOL consumingDeltas = cursorHidden &&
        MacWSMouseDeltaIsRecent(MacWSMonotonicNanoseconds());
    // This function runs inside MacWSPublishWindowMetrics. Update the flag
    // synchronously so this very generation carries it, but do not enqueue a
    // recursive metrics publication.
    MacWSSetRelativePointerRequestedAndPublish(
        associated || hidden || consumingDeltas,
        known ? "PlayerWindowView.showCursor-state"
              : "PlayerWindowView-not-key-window",
        NO);
}

// Unity 2022.3's custom Cocoa pump may continue invoking its NSView methods
// while libdispatch's main queue is not draining recovery timers.  These are
// real AppKit view callbacks, so reading the view and publishing its owning
// window is safe only on the main thread.  Request and publication generations
// ensure steady mouse motion takes the fast no-op path after one transition.
static void MacWSReconcileUnityViewAndPublish(id unityView,
                                             const char *boundary) {
    if (!unityView) return;
    if (!pthread_main_np()) {
        if (MacWSGamePointerDiagnosticsEnabled()) {
            static _Atomic bool loggedOffMain;
            if (!atomic_exchange_explicit(&loggedOffMain, true,
                                          memory_order_acq_rel)) {
                fprintf(stderr,
                    "#### APP-INPUT RELATIVE-UNITY-EVENT pid=%d "
                    "boundary=%s main=NO ignored=YES\n",
                    getpid(), boundary ?: "unknown");
                fflush(stderr);
            }
        }
        return;
    }
    id window = ((MacWSMsgID)objc_msgSend)(
        unityView, sel_registerName("window"));
    MacWSReconcileUnityCursorState(window);
    uint64_t requested = atomic_load_explicit(
        &MacWSRelativePointerRequestGeneration, memory_order_acquire);
    uint64_t published = atomic_load_explicit(
        &MacWSRelativePointerPublishedGeneration, memory_order_acquire);
    if (MacWSGamePointerDiagnosticsEnabled()) {
        static _Atomic uint64_t events;
        uint64_t event = atomic_fetch_add_explicit(
            &events, 1, memory_order_relaxed) + 1;
        if (event <= 6 || requested != published) {
            fprintf(stderr,
                "#### APP-INPUT RELATIVE-UNITY-EVENT pid=%d event=%llu "
                "boundary=%s main=YES window=%ld generation=%llu/%llu\n",
                getpid(), (unsigned long long)event,
                boundary ?: "unknown",
                window ? (long)((MacWSMsgInteger)objc_msgSend)(
                    window, sel_registerName("windowNumber")) : 0L,
                (unsigned long long)requested,
                (unsigned long long)published);
            fflush(stderr);
        }
    }
    if (requested != published) MacWSPublishWindowMetrics();
}

static void MacWSUnityMouseDown(id self, SEL selector, id event) {
    MacWSOriginalUnityMouseDown(self, selector, event);
    MacWSReconcileUnityViewAndPublish(self, "mouseDown:");
}

static void MacWSUnityMouseUp(id self, SEL selector, id event) {
    MacWSOriginalUnityMouseUp(self, selector, event);
    MacWSReconcileUnityViewAndPublish(self, "mouseUp:");
}

static void MacWSUnityMouseMoved(id self, SEL selector, id event) {
    MacWSOriginalUnityMouseMoved(self, selector, event);
    MacWSReconcileUnityViewAndPublish(self, "mouseMoved:");
}

static void MacWSUnityKeyDown(id self, SEL selector, id event) {
    MacWSOriginalUnityKeyDown(self, selector, event);
    MacWSReconcileUnityViewAndPublish(self, "keyDown:");
}

static void MacWSUnityKeyUp(id self, SEL selector, id event) {
    MacWSOriginalUnityKeyUp(self, selector, event);
    MacWSReconcileUnityViewAndPublish(self, "keyUp:");
}

static BOOL MacWSInstallUnityViewEventHook(Class unityViewClass,
                                          const char *selectorName,
                                          IMP replacement,
                                          MacWSMsgVoidID *originalOut) {
    SEL selector = sel_registerName(selectorName);
    Method method = unityViewClass
        ? class_getInstanceMethod(unityViewClass, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    // RE-confirmed via UnityPlayer 2022.3.62f2 UUID
    // D50F7C77-F422-3DE2-986B-1237215E50F7: each selected PlayerWindowView
    // callback is v24@0:8@16. Unknown ABIs fail closed.
    if (!method || !encoding || strcmp(encoding, "v24@0:8@16") != 0)
        return NO;
    IMP implementation = method_getImplementation(method);
    if (implementation == replacement) return *originalOut != NULL;
    if (*originalOut) return NO;
    *originalOut = (MacWSMsgVoidID)implementation;
    method_setImplementation(method, replacement);
    return YES;
}

static void MacWSInstallUnityRelativePointerContract(void) {
    if (MacWSOriginalUnitySetShowCursor &&
        MacWSOriginalUnityMouseDown && MacWSOriginalUnityMouseUp &&
        MacWSOriginalUnityMouseMoved && MacWSOriginalUnityKeyDown &&
        MacWSOriginalUnityKeyUp) return;
    // RE-confirmed in UnityPlayer 2022.3.62f2 UUID
    // D50F7C77-F422-3DE2-986B-1237215E50F7: the owning class is
    // PlayerWindowView and the IMP is +0xf16550. Keep UnityView as a
    // capability-compatible candidate used by other Unity desktop players;
    // the exact method ABI below remains mandatory for either class.
    Class unityViewClass = objc_getClass("PlayerWindowView");
    if (!unityViewClass) unityViewClass = objc_getClass("UnityView");
    SEL selector = sel_registerName("setShowCursor:");
    Method method = unityViewClass
        ? class_getInstanceMethod(unityViewClass, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    // The exact Unity 2022.3.62f2 method is v20@0:8B16. Fail closed if an
    // unrelated class/version exposes a selector with a different ABI.
    if (!method || !encoding || strcmp(encoding, "v20@0:8B16") != 0) {
        if (MacWSGamePointerDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT RELATIVE-UNITY-HOOK pid=%d installed=NO "
                "encoding=%s\n",
                getpid(), encoding ?: "<null>");
            fflush(stderr);
        }
        return;
    }
    IMP implementation = method_getImplementation(method);
    if (implementation != (IMP)MacWSUnitySetShowCursor &&
        !MacWSOriginalUnitySetShowCursor) {
        MacWSOriginalUnitySetShowCursor = (MacWSMsgVoidBool)implementation;
        method_setImplementation(method, (IMP)MacWSUnitySetShowCursor);
    }
    BOOL mouseDown = MacWSInstallUnityViewEventHook(
        unityViewClass, "mouseDown:", (IMP)MacWSUnityMouseDown,
        &MacWSOriginalUnityMouseDown);
    BOOL mouseUp = MacWSInstallUnityViewEventHook(
        unityViewClass, "mouseUp:", (IMP)MacWSUnityMouseUp,
        &MacWSOriginalUnityMouseUp);
    BOOL mouseMoved = MacWSInstallUnityViewEventHook(
        unityViewClass, "mouseMoved:", (IMP)MacWSUnityMouseMoved,
        &MacWSOriginalUnityMouseMoved);
    BOOL keyDown = MacWSInstallUnityViewEventHook(
        unityViewClass, "keyDown:", (IMP)MacWSUnityKeyDown,
        &MacWSOriginalUnityKeyDown);
    BOOL keyUp = MacWSInstallUnityViewEventHook(
        unityViewClass, "keyUp:", (IMP)MacWSUnityKeyUp,
        &MacWSOriginalUnityKeyUp);
    if (MacWSGamePointerDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT RELATIVE-UNITY-HOOK pid=%d installed=YES "
            "encoding=%s events=%s/%s/%s/%s/%s\n",
            getpid(), encoding,
            mouseDown ? "YES" : "NO", mouseUp ? "YES" : "NO",
            mouseMoved ? "YES" : "NO", keyDown ? "YES" : "NO",
            keyUp ? "YES" : "NO");
        fflush(stderr);
    }
}

static void MacWSScheduleUnityRelativePointerContractInstall(
        unsigned attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (MacWSOriginalUnitySetShowCursor) return;
        MacWSInstallUnityRelativePointerContract();
        if (!MacWSOriginalUnitySetShowCursor && attempt < 39) {
            MacWSScheduleUnityRelativePointerContractInstall(attempt + 1);
        }
    });
}

static void MacWSScheduleMouseDeltaExpiry(void);

static void MacWSCheckMouseDeltaExpiry(void) {
    atomic_store_explicit(&MacWSMouseDeltaExpiryScheduled, false,
                          memory_order_release);
    MacWSRefreshRelativePointerRequested("hidden-delta-expiry");
    BOOL needsAnotherCheck =
        !atomic_load_explicit(&MacWSMouseAssociationRelative,
                              memory_order_acquire) &&
        atomic_load_explicit(&MacWSCursorHideDepth,
                             memory_order_acquire) != 0 &&
        MacWSMouseDeltaIsRecent(MacWSMonotonicNanoseconds());
    if (needsAnotherCheck) MacWSScheduleMouseDeltaExpiry();
}

static void MacWSScheduleMouseDeltaExpiry(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MacWSMouseDeltaExpiryScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        MacWSCheckMouseDeltaExpiry();
    });
}

static CGError MacWSAssociateMouseAndMouseCursorPosition(
        boolean_t connected) {
    // Under DYLD interposition, a call to the replaced symbol from the
    // interposing image reaches the original implementation.  Do not use
    // RTLD_NEXT here: this project runtime-confirmed that pattern can resolve
    // NULL from an inserted image (the exec hooks retain the same contract).
    CGError result = CGAssociateMouseAndMouseCursorPosition(connected);
    if (result != kCGErrorSuccess) return result;

    atomic_store_explicit(&MacWSMouseAssociationRelative, connected == 0,
                          memory_order_release);
    MacWSRefreshRelativePointerRequested(
        connected == 0 ? "CGAssociate(false)" : "CGAssociate(true)");
    return result;
}

static CGError MacWSDisplayHideCursor(uint32_t display) {
    CGError result = CGDisplayHideCursor(display);
    uint32_t depth = atomic_load_explicit(
        &MacWSCursorHideDepth, memory_order_acquire);
    if (result == kCGErrorSuccess) {
        depth = atomic_fetch_add_explicit(
            &MacWSCursorHideDepth, 1, memory_order_acq_rel) + 1;
    }
    if (MacWSGamePointerDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT RELATIVE-CURSOR pid=%d operation=hide "
            "display=%u result=%d hidden-depth=%u\n",
            getpid(), display, result, depth);
        fflush(stderr);
    }
    return result;
}

static CGError MacWSDisplayShowCursor(uint32_t display) {
    CGError result = CGDisplayShowCursor(display);
    uint32_t depth = atomic_load_explicit(
        &MacWSCursorHideDepth, memory_order_acquire);
    if (result == kCGErrorSuccess) {
        while (depth != 0 && !atomic_compare_exchange_weak_explicit(
                   &MacWSCursorHideDepth, &depth, depth - 1,
                   memory_order_acq_rel, memory_order_acquire)) {}
        depth = atomic_load_explicit(
            &MacWSCursorHideDepth, memory_order_acquire);
        if (depth == 0) {
            atomic_store_explicit(&MacWSLastMouseDeltaMonotonicNS, 0,
                                  memory_order_release);
            MacWSRefreshRelativePointerRequested("CGDisplayShowCursor");
        }
    }
    if (MacWSGamePointerDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT RELATIVE-CURSOR pid=%d operation=show "
            "display=%u result=%d hidden-depth=%u\n",
            getpid(), display, result, depth);
        fflush(stderr);
    }
    return result;
}

static void MacWSGetLastMouseDelta(int32_t *deltaX, int32_t *deltaY) {
    CGGetLastMouseDelta(deltaX, deltaY);
    static _Atomic uint64_t calls;
    uint64_t call = atomic_fetch_add_explicit(
        &calls, 1, memory_order_relaxed) + 1;
    uint32_t depth = atomic_load_explicit(
        &MacWSCursorHideDepth, memory_order_acquire);
    if (MacWSGamePointerDiagnosticsEnabled() &&
        (call <= 4 || (call % 600) == 0)) {
        fprintf(stderr,
            "#### APP-INPUT RELATIVE-DELTA-POLL pid=%d call=%llu "
            "hidden-depth=%u delta=(%d,%d)\n",
            getpid(), (unsigned long long)call, depth,
            deltaX ? *deltaX : 0, deltaY ? *deltaY : 0);
        fflush(stderr);
    }
    if (depth == 0) return;
    atomic_store_explicit(&MacWSLastMouseDeltaMonotonicNS,
                          MacWSMonotonicNanoseconds(),
                          memory_order_release);
    MacWSRefreshRelativePointerRequested("hidden-delta-consumer");
    MacWSScheduleMouseDeltaExpiry();
}

// Main-thread-only dynamic scope around one Host ConfigureWindow setter. The
// application maximum, aspect, increments and windowWillResize: response have
// already been applied before this scope begins. It lets the existing
// constrainFrameRect: hook distinguish AppKit's virtual-screen placement cap
// from an application-authored size cap without changing global AppKit policy.
typedef struct {
    id window;
    CGRect applicationConstrainedFrame;
    CGSize screenExtent;
    BOOL unboundedWidth;
    BOOL unboundedHeight;
} MacWSHostConfigureFrameContext;
static __thread MacWSHostConfigureFrameContext
    MacWSCurrentHostConfigureFrameContext;
static __thread uint8_t MacWSLoggedHostConfigureScreenConstraintScopes;

static void MacWSPostWorkspacePowerNotification(BOOL sleeping) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class workspaceClass = objc_getClass("NSWorkspace");
        if (!workspaceClass) return;
        id workspace = ((MacWSMsgID)objc_msgSend)(
            workspaceClass, sel_registerName("sharedWorkspace"));
        id center = workspace ? ((MacWSMsgID)objc_msgSend)(
            workspace, sel_registerName("notificationCenter")) : nil;
        if (!center) return;
        NSString *name = sleeping
            ? @"NSWorkspaceWillSleepNotification"
            : @"NSWorkspaceDidWakeNotification";
        ((MacWSMsgVoidIDID)objc_msgSend)(
            center, sel_registerName("postNotificationName:object:"),
            name, workspace);
    });
}

static void MacWSInstallWorkspacePowerLifecycle(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t sleepResult = notify_register_dispatch(
            MACWS_WORKSPACE_WILL_SLEEP_NOTIFY,
            &MacWSWorkspaceWillSleepToken, dispatch_get_main_queue(),
            ^(int token) {
                (void)token;
                MacWSPostWorkspacePowerNotification(YES);
            });
        uint32_t wakeResult = notify_register_dispatch(
            MACWS_WORKSPACE_DID_WAKE_NOTIFY,
            &MacWSWorkspaceDidWakeToken, dispatch_get_main_queue(),
            ^(int token) {
                (void)token;
                MacWSPostWorkspacePowerNotification(NO);
            });
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                    "#### APP-POWER bridge pid=%d sleep=%u wake=%u\n",
                    getpid(), sleepResult, wakeResult);
        }
    });
}
// Main-thread-only semantic menu snapshot cache. ObjC objects never cross the
// process boundary: Host receives generation-scoped integer IDs, while the
// target process retains the corresponding item and index path solely long
// enough to revalidate a later action against the current NSMainMenu tree.
static NSMutableDictionary *MacWSMenuCaches;
static uint64_t MacWSMenuNextGeneration;
static const char MacWSInputTargetReplyPath[] =
    "/private/tmp/macws_input_target.sock";
static NSInteger MacWSAppInputEventNumber;
static NSMutableArray *MacWSAppInputPending;
static BOOL MacWSAppInputDrainScheduled;
// Populated on the main thread once AppKit has created the real NSApplication
// and published at least one window; immutable thereafter. NSApplication
// documents -postEvent:atStart: as callable from a secondary thread, so this
// context lets exact-window keyboard records enter the real AppKit event queue
// without waiting for a CFRunLoop block that Unity's custom pump may not
// service for hundreds of milliseconds.
static CFTypeRef MacWSAppInputKeyboardApplication;
static Class MacWSAppInputKeyboardEventClass;
typedef struct {
    uint32_t sampleSequence;
    uint16_t keyCode;
    uint16_t eventType;
    double producedAt;
    double postedAt;
} MacWSKeyboardCGSTraceSample;
static pthread_mutex_t MacWSKeyboardCGSTraceLock = PTHREAD_MUTEX_INITIALIZER;
static MacWSKeyboardCGSTraceSample MacWSKeyboardCGSTraceSamples[64];
static size_t MacWSKeyboardCGSTraceSampleCount;
// Serializes the socket thread's enqueue-vs-live-post decision with the main
// thread arming a real AppKit tracking loop. Without this lock an up record can
// decide to enqueue just before live mode starts, then enter the pending array
// just after the main thread checked it and leave NSControlTrackMouse waiting.
static pthread_mutex_t MacWSAppInputRouteLock = PTHREAD_MUTEX_INITIALIZER;
// Main-thread-only. RFB tap-down is held until its matching up arrives. The
// pair can then be delivered with up already in NSApplication's queue before
// sendEvent(down) enters an NSButton/NSControl nested tracking loop.
static CFTypeRef MacWSAppInputDeferredRFBDownEvent;
// Main-thread-only. RFB can deliver motion before mouse-up over several socket
// records. Keep those ordinary NSEvents until the matching release is present,
// then put the complete sequence in NSApplication's real event queue before
// dispatching down. This prevents a control tracker from observing a transient
// empty queue and returning before a later CFRunLoop block posts mouse-up.
static NSMutableArray *MacWSAppInputDeferredRFBMoveEvents;
// Main-thread-only. True while sendEvent(mouseDown) owns an AppKit nested
// tracking loop. In addition to selecting the queue path, this supplies the
// matching global pressed-button state that a hardware CGEvent normally
// updates before AppKit receives mouseDown.
static BOOL MacWSAppInputRFBTrackingActive;
// NSEvent.pressedMouseButtons bit(s) represented by the one atomic gesture
// currently dispatched through AppKit (left=1, right=2).
static NSUInteger MacWSAppInputRFBTrackingButtons;
// CoreDrag does not consume NSEvents appended to NSApplication's queue.  Its
// Ventura source-drag loop installs NSCoreDragCGEventInputProc and then waits
// in CoreDragStartDragging, so only the process's real CGS event stream can
// advance the drag image after Finder has created the NSDraggingSession.
// Publish that exact lifecycle edge to the socket thread; it may then keep the
// already-validated window gesture on CGPostMouseEvent until the physical up.
static _Atomic BOOL MacWSAppInputCoreDragNativeActive;
static _Atomic uint32_t MacWSAppInputCoreDragNativeWindow;
// Process-local mouse NSEvents do not update WindowServer's global pointer or
// button state. Tag only events constructed by this bridge so the
// NSApplication dispatch hook can restore those hardware invariants for the
// complete lifetime of every down/drag/up callback. Keeping the identity on
// the event is important for asynchronous content drags: Finder's mouseDown:
// returns before later leftMouseDragged events are dequeued.
static char MacWSProcessLocalMouseEventAssociationKey;
// NSApplication.windows is not a complete ownership registry: runtime on the
// current VSCode/Electron build captured a live level-101 CGWindow while both
// windows and orderedWindows contained only the document window. Keep weak
// references to real NSWindow instances when AppKit orders them, so routing
// can resolve the exact transient object instead of treating its pixels as an
// outside click on the base window.
static NSHashTable *MacWSOrderedWindowRegistry;
static MacWSOrderWindow MacWSOriginalOrderWindow;
static MacWSMsgRectRectID MacWSOriginalConstrainFrameRect;
static MacWSToggleFullScreen MacWSOriginalToggleFullScreen;
static MacWSPressedMouseButtons MacWSOriginalPressedMouseButtons;
static MacWSMouseLocation MacWSOriginalMouseLocation;
// Main-thread scoped. AppKit's menu-bar tracker ignores the passed NSEvent's
// location while updating its tracked controller and consults this class
// property instead. The transient value remains scoped to that one handler
// call. The persistent value models WindowServer's last cursor position after
// an exact process-local event: those events cannot update the real global
// cursor, but later AppKit/game-engine polling must still observe the last
// delivered position just as it would after a hardware CGEvent.
static BOOL MacWSAppInputMouseLocationActive;
static CGPoint MacWSAppInputMouseLocation;
static BOOL MacWSAppInputPersistentMouseLocationValid;
static CGPoint MacWSAppInputPersistentMouseLocation;
typedef struct {
    BOOL accepting;
    uint32_t contactID;
    uint64_t sceneID;
    NSInteger windowNumber;
    CGRect screenFrame;
    CGPoint windowMinusScreen;
    Class eventClass;
    CFTypeRef application;
} MacWSDirectTrackingContext;
static MacWSDirectTrackingContext MacWSAppInputDirectContext;
// A magnify/rotate responder may enter one of AppKit's synchronous gesture
// tracking loops from inside the initial _reallySendEvent: call.  Keep the
// exact window geometry prepared on the main thread, but do not accept live
// socket records until that native loop actually starts.  This distinction is
// important for Maps and WebKit, whose gesture handlers return immediately
// and must retain the ordinary main-thread dispatch path.
typedef struct {
    BOOL prepared;
    BOOL accepting;
    BOOL terminalQueued;
    uint16_t kind;
    uint32_t contactID;
    uint32_t targetWindowID;
    uint64_t sceneID;
    NSInteger windowNumber;
    CGRect mappingFrame;
    CGRect screenFrame;
    CGPoint windowMinusScreen;
    Class eventClass;
    CFTypeRef application;
    CFTypeRef window;
} MacWSDirectGestureContext;
static MacWSDirectGestureContext MacWSAppInputDirectGestureContext;
// Dock is not an NSApplication. Capture its real DOCKGestures singleton at
// ordinary -init time so the process-local endpoint can pass reconstructed
// trackpad CGEvents into the same handleEvent: pipeline used by hardware.
// The witness does not replace or suppress any Dock behavior.
static _Atomic(uintptr_t) MacWSDockGesturesInstance;
static IMP MacWSOriginalDockGesturesInit;
// Mission Control pointer input is owned by EyeCandy's process-local modal
// router, not Dock's ordinary global CGS event path. Dock __TEXT+0x41980
// confirmed that
// -[ECModalEventController handleEvent:windows:topLayers:windowCount:] takes a
// CF-backed raw CGEventRef and constructs its ECEvent wrapper internally. Its
// real CGS event entry also supplies the exact Spaces Bar WALayerKitWindow and
// top layer. Retain that tuple at the native routing boundary instead of
// searching the heap or reconstructing Dock's private object graph.
static IMP MacWSOriginalDockModalEventRouter;
static void (*MacWSOriginalDockModalAddHandler)(id, SEL, id, BOOL, BOOL);
static void (*MacWSOriginalDockModalRemoveHandler)(id, SEL, id);
static id MacWSDockModalWindow;
static id MacWSDockModalTopLayer;
static MacWSCGEventRef MacWSDockModalTemplateEvent;
static CGPoint MacWSDockModalTemplatePoint;
static BOOL MacWSDockModalTemplatePointValid;
// Published only after the template and its native WALayerKit tuple have been
// replaced together on Dock's main thread. The socket thread uses the revision
// as a completion fence after posting a real global hover at a new point; it
// never reuses a template captured at an older Mission Control card.
static _Atomic uint64_t MacWSDockModalContextRevision;
static int MacWSDockExposeStateToken = -1;
static BOOL MacWSDockExposePublishedActive;
// The physical trackpad path never leaves an unbounded list of stale Changed
// samples on Dock's main queue.  UIKit can produce at 120 Hz while a native
// Mission Control frame is temporarily more expensive; enqueueing one block
// per sample made Dock animate old progress long after the finger moved.
// Preserve every semantic boundary, but keep only the newest Changed record
// behind at most one scheduled main-queue drain.
static pthread_mutex_t MacWSDockGestureLock = PTHREAD_MUTEX_INITIALIZER;
static MacWSInputRecord MacWSDockGestureLatestChanged;
static MacWSInputRecord MacWSDockGestureLastRecord;
static uint64_t MacWSDockGestureSession;
static uint64_t MacWSDockGestureLatestRevision;
static uint64_t MacWSDockGestureDeliveredRevision;
static uint32_t MacWSDockGestureActiveContact;
static uint32_t MacWSDockGestureReceivedChanges;
static uint32_t MacWSDockGestureDeliveredChanges;
static BOOL MacWSDockGestureDrainScheduled;
// Native non-client tracking (title bar, traffic-light controls and resize
// chrome) belongs to WindowServer, not an NSView responder.  Once a verified
// exact-window down enters CGPostMouseEvent, keep its move/up records on that
// same system route so the button cannot be stranded halfway through a drag.
static BOOL MacWSExactSystemPointerActive;
static uint32_t MacWSExactSystemPointerContact;
static uint32_t MacWSExactSystemPointerWindow;
static CGRect MacWSExactSystemPointerMappingFrame;
// Main-thread-only. A physical indirect-pointer click outside an open AppKit
// menu is delivered as separate TouchDown/TouchUp records, unlike the atomic
// Tap used by direct touch and VNC. If the down cancels the native menu
// tracker, consume its matching terminal record as the tracker itself would;
// otherwise that up can leak through to the base window underneath the menu.
static BOOL MacWSPopupDismissPointerActive;
static uint32_t MacWSPopupDismissPointerContact;
static uint64_t MacWSPopupDismissPointerScene;
static NSString *MacWSRuntimeString(const char *utf8);

static BOOL MacWSRuntimeDiagnosticsEnabled(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        // AppInput needs a narrow recorder for hit-window/event routing. Do
        // not require the global runtime switch here: that switch also turns
        // on AGX submit/JIT recorders and changes the responsiveness being
        // measured. The global switch retains its historical umbrella
        // behavior, while this AppInput-only switch leaves rendering alone.
        value = getenv("MACWS_APP_INPUT_DIAGNOSTICS") != NULL ||
            access("/tmp/macws_app_input_diagnostics", F_OK) == 0 ||
            getenv("MACWS_RUNTIME_DIAGNOSTICS") != NULL ||
            access("/tmp/macws_runtime_diagnostics", F_OK) == 0;
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

static BOOL MacWSKeyboardLatencyDiagnosticsEnabled(void) {
    // This narrow, dynamic probe observes only physical keyboard boundaries.
    // It intentionally does not enable the render/JIT/runtime diagnostic
    // umbrella, which would change the game workload being measured.
    return access("/tmp/macws_keyboard_latency_diagnostics", F_OK) == 0;
}

static BOOL MacWSGamePointerDiagnosticsEnabled(void) {
    // This marker is deliberately dynamic and relative-pointer-only.  It can
    // witness one physical camera gesture without enabling AppInput's other
    // event traces or the global AGX/JIT recorders.
    return MacWSRuntimeDiagnosticsEnabled() ||
        access("/tmp/macws_game_pointer_diagnostics", F_OK) == 0;
}

// Called only after AppKit itself has produced the real NSApplication on the
// main thread.  Do not call +sharedApplication from the inserted-dylib install
// path: runtime on the direct 7DTD launch (2026-10-02 crash report) showed
// _RegisterApplication aborting when that message created NSApp before the
// process had joined its GUI launch coalition.
static void MacWSCacheKeyboardContext(id application) {
    if (!application || MacWSAppInputKeyboardApplication) return;
    Class eventClass = objc_getClass("NSEvent");
    if (!eventClass) return;
    pthread_mutex_lock(&MacWSAppInputRouteLock);
    if (!MacWSAppInputKeyboardApplication) {
        MacWSAppInputKeyboardApplication =
            CFRetain((__bridge CFTypeRef)application);
        MacWSAppInputKeyboardEventClass = eventClass;
    }
    pthread_mutex_unlock(&MacWSAppInputRouteLock);
}

static void MacWSKeyboardLatencyTrace(const char *format, ...) {
    if (!MacWSKeyboardLatencyDiagnosticsEnabled() || !format) return;
    char line[512];
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(line, sizeof(line), format, arguments);
    va_end(arguments);
    if (length <= 0) return;
    size_t bytes = (size_t)length;
    if (bytes >= sizeof(line)) bytes = sizeof(line) - 1;
    int fd = open("/tmp/macws_keyboard_latency.trace",
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) return;
    (void)write(fd, line, bytes);
    close(fd);
}

// Diagnostic-only correlation for the asynchronous CGS candidate. A zero
// return from CGPostKeyboardEvent is not an AppKit-delivery witness, so retain
// the original physical sample until this process's real -sendEvent: hook sees
// the matching type/keycode. The bounded FIFO is never consulted when the
// sentinel is absent and stale candidates cannot claim an unrelated key.
static void MacWSRegisterKeyboardCGSTraceSample(MacWSInputRecord record,
                                                uint16_t keyCode,
                                                uint16_t eventType,
                                                double postedAt) {
    if (!MacWSKeyboardLatencyDiagnosticsEnabled()) return;
    MacWSKeyboardCGSTraceSample sample = {
        .sampleSequence = record.sampleSequence,
        .keyCode = keyCode,
        .eventType = eventType,
        .producedAt = record.timestamp,
        .postedAt = postedAt,
    };
    pthread_mutex_lock(&MacWSKeyboardCGSTraceLock);
    if (MacWSKeyboardCGSTraceSampleCount ==
            sizeof(MacWSKeyboardCGSTraceSamples) /
                sizeof(MacWSKeyboardCGSTraceSamples[0])) {
        memmove(&MacWSKeyboardCGSTraceSamples[0],
                &MacWSKeyboardCGSTraceSamples[1],
                sizeof(MacWSKeyboardCGSTraceSamples) -
                    sizeof(MacWSKeyboardCGSTraceSamples[0]));
        MacWSKeyboardCGSTraceSampleCount--;
    }
    MacWSKeyboardCGSTraceSamples[MacWSKeyboardCGSTraceSampleCount++] = sample;
    pthread_mutex_unlock(&MacWSKeyboardCGSTraceLock);
}

static void MacWSCancelKeyboardCGSTraceSample(uint32_t sampleSequence) {
    if (!MacWSKeyboardLatencyDiagnosticsEnabled()) return;
    pthread_mutex_lock(&MacWSKeyboardCGSTraceLock);
    for (size_t index = 0; index < MacWSKeyboardCGSTraceSampleCount; index++) {
        if (MacWSKeyboardCGSTraceSamples[index].sampleSequence !=
                sampleSequence)
            continue;
        memmove(&MacWSKeyboardCGSTraceSamples[index],
                &MacWSKeyboardCGSTraceSamples[index + 1],
                (MacWSKeyboardCGSTraceSampleCount - index - 1) *
                    sizeof(MacWSKeyboardCGSTraceSamples[0]));
        MacWSKeyboardCGSTraceSampleCount--;
        break;
    }
    pthread_mutex_unlock(&MacWSKeyboardCGSTraceLock);
}

static BOOL MacWSConsumeKeyboardCGSTraceSample(
        uint16_t eventType, uint16_t keyCode, double now,
        MacWSKeyboardCGSTraceSample *sampleOut) {
    if (!sampleOut || !MacWSKeyboardLatencyDiagnosticsEnabled()) return NO;
    BOOL found = NO;
    pthread_mutex_lock(&MacWSKeyboardCGSTraceLock);
    for (size_t index = 0; index < MacWSKeyboardCGSTraceSampleCount;) {
        MacWSKeyboardCGSTraceSample sample =
            MacWSKeyboardCGSTraceSamples[index];
        BOOL stale = sample.postedAt <= 0.0 || now < sample.postedAt ||
            now - sample.postedAt > 2.0;
        BOOL matches = !stale && sample.eventType == eventType &&
            sample.keyCode == keyCode;
        if (!stale && !matches) {
            index++;
            continue;
        }
        memmove(&MacWSKeyboardCGSTraceSamples[index],
                &MacWSKeyboardCGSTraceSamples[index + 1],
                (MacWSKeyboardCGSTraceSampleCount - index - 1) *
                    sizeof(MacWSKeyboardCGSTraceSamples[0]));
        MacWSKeyboardCGSTraceSampleCount--;
        if (matches) {
            *sampleOut = sample;
            found = YES;
            break;
        }
    }
    pthread_mutex_unlock(&MacWSKeyboardCGSTraceLock);
    return found;
}

// Game input backends sample key state from AppKit's event queue on their game
// tick.  Runtime evidence from Stray's first-run brightness screen is exact:
// direct -[NSApplication sendEvent:] delivered Return to the real FCocoaWindow
// in 4.6 ms and switched the displayed input glyph, but the Accept action never
// observed a down state.  Unity 2022.3.62f2 has the same event-pump boundary:
// RE-confirmed in the shipped arm64 UnityPlayer.dylib, -[PlayerWindowView
// keyDown:] calls -[PlayerAppDelegate DidSendEvent:], and the runtime Player.log
// showed direct Return down/up reaching PlayerWindowView back-to-back without
// advancing 7 Days To Die's selected action.  Queueing the same ordinary
// NSEvent lets each application's normal event pump establish that state
// before a later key-up; no selector, action, or validation result is forged.
static BOOL MacWSMainBundleUsesQueuedGameInput(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
        // Never message an Objective-C constant string emitted by this
        // injected arm64e image.  Runtime LLDB on Terminal pid 61544 stopped
        // the first key-down in -[__NSCFString isEqualToString:] with a PAC
        // failure and this literal in x2.  Construct the comparison object
        // through the target process's realized NSString class, like every
        // other bundle-identity check in this bridge.
        value = [identifier isEqualToString:
                    MacWSRuntimeString("com.annapurnainteractive.Stray")] ||
            [identifier isEqualToString:
                MacWSRuntimeString("com.The-Fun-Pimps.7-Days-To-Die")];
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

static BOOL MacWSMainBundleIsSevenDaysToDie(void) {
    static _Atomic int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_acquire);
    if (value < 0) {
        NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
        value = [identifier isEqualToString:
            MacWSRuntimeString("com.The-Fun-Pimps.7-Days-To-Die")];
        atomic_store_explicit(&cached, value, memory_order_release);
    }
    return value != 0;
}

static void MacWSTrackOrderedWindow(id window) {
    if (!window || !MacWSOrderedWindowRegistry) return;
    [MacWSOrderedWindowRegistry addObject:window];
}

static void MacWSAppInputOrderWindow(id self, SEL selector,
                                     NSInteger place,
                                     NSInteger relativeTo) {
    MacWSOriginalOrderWindow(self, selector, place, relativeTo);
    MacWSTrackOrderedWindow(self);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
            self, sel_registerName("windowNumber"));
        NSInteger level = ((MacWSMsgInteger)objc_msgSend)(
            self, sel_registerName("level"));
        if (level > 0) {
            CGRect frame = ((MacWSMsgRect)objc_msgSend)(
                self, sel_registerName("frame"));
            fprintf(stderr,
                "#### APP-INPUT WINDOW-REGISTRY pid=%d number=%ld class=%s "
                "place=%ld relative=%ld level=%ld frame=(%.1f,%.1f %.1fx%.1f)\n",
                getpid(), (long)number, object_getClassName(self),
                (long)place, (long)relativeTo, (long)level,
                frame.origin.x, frame.origin.y,
                frame.size.width, frame.size.height);
            fflush(stderr);
        }
    }
}

// A window-mode Scene captures one level-zero AppKit window plus its related
// transient windows. AppKit normally constrains a menu/panel to the physical
// NSScreen, which can still place part of that transient outside its Scene's
// base-window capture. Apply the same containment at NSWindow's real frame
// constraint boundary: the original implementation keeps ownership, sizing
// and screen policy, then this adapter translates only the accepted origin so
// a related transient remains inside its presenting window.
static CGRect MacWSAppInputConstrainFrameRect(id self, SEL selector,
                                               CGRect requested, id screen) {
    CGRect constrained = MacWSOriginalConstrainFrameRect
        ? MacWSOriginalConstrainFrameRect(self, selector, requested, screen)
        : requested;
    MacWSHostConfigureFrameContext context =
        MacWSCurrentHostConfigureFrameContext;
    BOOL configureTransaction = context.window == self;
    CGRect applicationConstrainedFrame = context.applicationConstrainedFrame;
    CGSize screenExtent = context.screenExtent;
    BOOL unboundedWidth = context.unboundedWidth;
    BOOL unboundedHeight = context.unboundedHeight;
    if (!configureTransaction) {
        NSNumber *policyNumber = objc_getAssociatedObject(
            self, &MacWSWindowScreenConstraintPolicyKey);
        uint8_t policy = policyNumber
            ? (uint8_t)[policyNumber unsignedCharValue]
            : MacWSWindowScreenConstraintPolicyNone;
        if (policy != MacWSWindowScreenConstraintPolicyNone) {
            id effectiveScreen = screen ?: ((MacWSMsgID)objc_msgSend)(
                self, sel_registerName("screen"));
            CGRect screenFrame = effectiveScreen
                ? ((MacWSMsgRect)objc_msgSend)(
                    effectiveScreen, sel_registerName("frame"))
                : CGRectZero;
            applicationConstrainedFrame = requested;
            screenExtent = screenFrame.size;
            unboundedWidth =
                (policy & MacWSWindowScreenConstraintPolicyUnboundedWidth) != 0;
            unboundedHeight =
                (policy & MacWSWindowScreenConstraintPolicyUnboundedHeight) != 0;
        }
    }
    BOOL sceneOwnedConstraint = configureTransaction ||
        unboundedWidth || unboundedHeight;
    if (sceneOwnedConstraint) {
        CGRect screenConstrained = constrained;
        BOOL restoreWidth = MacWSWindowAxisScreenConstraintShouldBeRestored(
            applicationConstrainedFrame.size.width,
            constrained.size.width, screenExtent.width,
            unboundedWidth);
        BOOL restoreHeight = MacWSWindowAxisScreenConstraintShouldBeRestored(
            applicationConstrainedFrame.size.height,
            constrained.size.height, screenExtent.height,
            unboundedHeight);
        constrained.origin.x = MacWSWindowAxisValueAfterScreenConstraint(
            applicationConstrainedFrame.origin.x,
            constrained.origin.x, restoreWidth);
        constrained.size.width = MacWSWindowAxisValueAfterScreenConstraint(
            applicationConstrainedFrame.size.width,
            constrained.size.width, restoreWidth);
        constrained.origin.y = MacWSWindowAxisValueAfterScreenConstraint(
            applicationConstrainedFrame.origin.y,
            constrained.origin.y, restoreHeight);
        constrained.size.height = MacWSWindowAxisValueAfterScreenConstraint(
            applicationConstrainedFrame.size.height,
            constrained.size.height, restoreHeight);
        BOOL restoredScreenConstraint =
            fabs(screenConstrained.origin.x - constrained.origin.x) > 0.25 ||
            fabs(screenConstrained.origin.y - constrained.origin.y) > 0.25 ||
            fabs(screenConstrained.size.width - constrained.size.width) > 0.25 ||
            fabs(screenConstrained.size.height - constrained.size.height) > 0.25;
        uint8_t scope = configureTransaction ? 1u : 2u;
        if (restoredScreenConstraint &&
            ((MacWSLoggedHostConfigureScreenConstraintScopes & scope) == 0 ||
             MacWSRuntimeDiagnosticsEnabled())) {
            fprintf(stderr,
                "#### APP-INPUT CONFIGURE-SCREEN-CONSTRAINT pid=%d "
                "scope=%s "
                "window=%ld requested=(%.1f,%.1f %.1fx%.1f) "
                "screen=(%.1f,%.1f %.1fx%.1f) "
                "restored=(%.1f,%.1f %.1fx%.1f) unbounded=%s x %s\n",
                getpid(),
                configureTransaction ? "transaction" : "scene-owned",
                (long)((MacWSMsgInteger)objc_msgSend)(
                    self, sel_registerName("windowNumber")),
                applicationConstrainedFrame.origin.x,
                applicationConstrainedFrame.origin.y,
                applicationConstrainedFrame.size.width,
                applicationConstrainedFrame.size.height,
                screenConstrained.origin.x, screenConstrained.origin.y,
                screenConstrained.size.width, screenConstrained.size.height,
                constrained.origin.x, constrained.origin.y,
                constrained.size.width, constrained.size.height,
                unboundedWidth ? "YES" : "NO",
                unboundedHeight ? "YES" : "NO");
            fflush(stderr);
            MacWSLoggedHostConfigureScreenConstraintScopes |= scope;
        }
    }
    Class applicationClass = objc_getClass("NSApplication");
    id application = applicationClass &&
        class_respondsToSelector(object_getClass(applicationClass),
                                 sel_registerName("sharedApplication"))
        ? ((MacWSMsgID)objc_msgSend)(
              (id)applicationClass, sel_registerName("sharedApplication"))
        : nil;
    if (!application) return constrained;

    id presenter = MacWSPresentingWindow(self, application);
    NSInteger level = ((MacWSMsgInteger)objc_msgSend)(
        self, sel_registerName("level"));
    if (!presenter && level > 0) {
        presenter = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("keyWindow"));
        if (!presenter) presenter = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainWindow"));
    }
    if (!presenter || presenter == self ||
        !((MacWSMsgBool)objc_msgSend)(
            presenter, sel_registerName("isVisible"))) return constrained;

    CGRect presenterFrame = ((MacWSMsgRect)objc_msgSend)(
        presenter, sel_registerName("frame"));
    if (!isfinite(constrained.origin.x) ||
        !isfinite(constrained.origin.y) ||
        !isfinite(constrained.size.width) ||
        !isfinite(constrained.size.height) ||
        !isfinite(presenterFrame.origin.x) ||
        !isfinite(presenterFrame.origin.y) ||
        !isfinite(presenterFrame.size.width) ||
        !isfinite(presenterFrame.size.height) ||
        constrained.size.width <= 0.0 || constrained.size.height <= 0.0 ||
        presenterFrame.size.width <= 0.0 ||
        presenterFrame.size.height <= 0.0) return constrained;

    CGRect contained = constrained;
    CGFloat maximumX = CGRectGetMaxX(presenterFrame) - contained.size.width;
    CGFloat maximumY = CGRectGetMaxY(presenterFrame) - contained.size.height;
    contained.origin.x = contained.size.width <= presenterFrame.size.width
        ? fmin(fmax(contained.origin.x, CGRectGetMinX(presenterFrame)),
               maximumX)
        : CGRectGetMinX(presenterFrame);
    contained.origin.y = contained.size.height <= presenterFrame.size.height
        ? fmin(fmax(contained.origin.y, CGRectGetMinY(presenterFrame)),
               maximumY)
        : CGRectGetMinY(presenterFrame);
    BOOL adjusted = fabs(contained.origin.x - constrained.origin.x) > 0.25 ||
        fabs(contained.origin.y - constrained.origin.y) > 0.25;
    if (adjusted && MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT TRANSIENT-CONSTRAIN pid=%d window=%ld "
            "presenter=%ld level=%ld requested=(%.1f,%.1f %.1fx%.1f) "
            "screen-result=(%.1f,%.1f %.1fx%.1f) "
            "scene-result=(%.1f,%.1f %.1fx%.1f)\n",
            getpid(),
            (long)((MacWSMsgInteger)objc_msgSend)(
                self, sel_registerName("windowNumber")),
            (long)((MacWSMsgInteger)objc_msgSend)(
                presenter, sel_registerName("windowNumber")),
            (long)level,
            requested.origin.x, requested.origin.y,
            requested.size.width, requested.size.height,
            constrained.origin.x, constrained.origin.y,
            constrained.size.width, constrained.size.height,
            contained.origin.x, contained.origin.y,
            contained.size.width, contained.size.height);
        fflush(stderr);
    }
    return contained;
}

static void MacWSInstallTransientFrameConstraint(void) {
    if (MacWSOriginalConstrainFrameRect) return;
    Class windowClass = objc_getClass("NSWindow");
    SEL selector = sel_registerName("constrainFrameRect:toScreen:");
    Method method = windowClass
        ? class_getInstanceMethod(windowClass, selector) : NULL;
    if (!method) return;
    IMP implementation = method_getImplementation(method);
    if (implementation == (IMP)MacWSAppInputConstrainFrameRect) return;
    MacWSOriginalConstrainFrameRect =
        (MacWSMsgRectRectID)implementation;
    method_setImplementation(method,
                             (IMP)MacWSAppInputConstrainFrameRect);
}

static void MacWSInstallOrderedWindowRegistry(void) {
    if (!MacWSOrderedWindowRegistry) {
        Class hashTableClass = objc_getClass("NSHashTable");
        if (hashTableClass) {
            MacWSOrderedWindowRegistry = [((id (*)(id, SEL))objc_msgSend)(
                (id)hashTableClass,
                sel_registerName("weakObjectsHashTable")) retain];
        }
    }
    Class windowClass = objc_getClass("NSWindow");
    SEL selector = sel_registerName("orderWindow:relativeTo:");
    Method method = windowClass
        ? class_getInstanceMethod(windowClass, selector) : NULL;
    if (!method || MacWSOriginalOrderWindow) return;
    IMP implementation = method_getImplementation(method);
    if (implementation == (IMP)MacWSAppInputOrderWindow) return;
    MacWSOriginalOrderWindow = (MacWSOrderWindow)implementation;
    method_setImplementation(method, (IMP)MacWSAppInputOrderWindow);
    // This runs from libmachook's initializer, before AppKit has registered
    // the process. Do not call +[NSApplication sharedApplication] here:
    // runtime on Electron PID 72595 showed that doing so aborts in
    // _RegisterApplication. Existing document windows remain discoverable
    // through the request-time application.windows scan; this registry is
    // specifically for later transient windows crossing orderWindow:.
}

// UE4's native fullscreen state machine assumes the NSWindow is already
// ordered before -toggleFullScreen: begins.  That prerequisite normally comes
// from LaunchServices activating the application.  Steam's chroot fallback is
// a direct posix_spawn because NSWorkspace returns NSCocoaErrorDomain/259, so
// no open-application event orders the first FCocoaWindow.  Runtime evidence
// from Stray PID 69345 captured the resulting invariant failure without any
// input: the only window-metrics entry was invisible 10x28 window 554, while
// 2016/2016 game-thread samples were in
// FMacWindow::WaitForFullScreenTransition and the live non-fragile ivars were
// WindowMode=2, TargetWindowMode=1.  The exact Stray binary shows that only
// -windowDidEnterFullScreen: copies TargetWindowMode into WindowMode.
//
// Fulfil the missing AppKit prerequisite at the real transition boundary.
// This does not forge a fullscreen notification or a UE mode field: AppKit's
// original -toggleFullScreen: still owns the transition and its delegate
// callbacks remain the sole authority that advances UE's state machine.
static void MacWSAppInputToggleFullScreen(id self, SEL selector, id sender) {
    BOOL visibleBefore = ((MacWSMsgBool)objc_msgSend)(
        self, sel_registerName("isVisible"));
    if (MacWSMainBundleUsesFullscreenCanvasPresentation() &&
        !visibleBefore) {
        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
            self, sel_registerName("windowNumber"));
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(
            self, sel_registerName("frame"));
        ((MacWSMsgVoidID)objc_msgSend)(
            self, sel_registerName("makeKeyAndOrderFront:"), nil);
        BOOL visibleAfter = ((MacWSMsgBool)objc_msgSend)(
            self, sel_registerName("isVisible"));
        fprintf(stderr,
            "#### STRAY-FULLSCREEN prerequisite=ordered-window "
            "pid=%d window=%ld class=%s visible=%s->%s "
            "frame=(%.1f,%.1f %.1fx%.1f)\n",
            getpid(), (long)number, object_getClassName(self),
            visibleBefore ? "YES" : "NO",
            visibleAfter ? "YES" : "NO",
            frame.origin.x, frame.origin.y,
            frame.size.width, frame.size.height);
        fflush(stderr);
    }
    MacWSOriginalToggleFullScreen(self, selector, sender);
}

static void MacWSInstallFullscreenTransitionPrerequisite(void) {
    if (!MacWSMainBundleUsesFullscreenCanvasPresentation() ||
        MacWSOriginalToggleFullScreen) return;
    Class windowClass = objc_getClass("NSWindow");
    SEL selector = sel_registerName("toggleFullScreen:");
    Method method = windowClass
        ? class_getInstanceMethod(windowClass, selector) : NULL;
    if (!method) return;
    IMP implementation = method_getImplementation(method);
    if (implementation == (IMP)MacWSAppInputToggleFullScreen) return;
    MacWSOriginalToggleFullScreen =
        (MacWSToggleFullScreen)implementation;
    method_setImplementation(
        method, (IMP)MacWSAppInputToggleFullScreen);
}

// Objective-C constant-string objects emitted into this injected arm64e dylib
// carry the dylib's build-time authenticated isa representation.  The target
// macOS shared cache uses a different arm64e signing context on iOS, so
// messaging one of those literals can fault in objc_msgSend before the method
// body runs.  Runtime-confirmed by
// Terminal-2026-07-31-122017.ips: MacWSMenuAppendString received the @""
// returned by MacWSMenuShortcutForItem and objc_msgSend authenticated its isa
// as 0x00200001fc9b05e8.  Construct the few bridge-owned strings through the
// realized runtime class instead; AppKit-owned NSString instances remain
// untouched.
static NSString *MacWSRuntimeString(const char *utf8) {
    Class stringClass = objc_getClass("NSString");
    if (!stringClass || !utf8) return nil;
    return ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)stringClass, sel_registerName("stringWithUTF8String:"), utf8);
}

static int MacWSFilteredFprintf(FILE *stream, const char *format, ...)
    __attribute__((format(printf, 2, 3)));
static int MacWSFilteredFprintf(FILE *stream, const char *format, ...) {
    if (stream == stderr && !MacWSRuntimeDiagnosticsEnabled()) return 0;
    va_list args;
    va_start(args, format);
    int result = vfprintf(stream, format, args);
    va_end(args);
    return result;
}
#define fprintf MacWSFilteredFprintf

typedef struct {
    NSInteger windowNumber;
    CGRect screenFrame;
    CGPoint windowMinusScreen;
    Class eventClass;
    CFTypeRef application;
    BOOL menuSurface;
} MacWSDirectTrackingSnapshot;
typedef struct {
    NSInteger windowNumber;
    CGRect mappingFrame;
    CGRect screenFrame;
    CGPoint windowMinusScreen;
    Class eventClass;
    CFTypeRef application;
    CFTypeRef window;
} MacWSDirectGestureSnapshot;
// The target probe runs on the application main thread immediately before a
// native VNC button-down.  Cache the selected application's ordinary AppKit
// event-queue geometry there so the socket thread can post mouseMoved while a
// synchronous NSCarbonMenuImpl tracker owns the main thread.  The Carbon
// tracker in this macOS build calls _NSHLTBMenuEventProc, which in turn blocks
// in NSApplication's _nextEventMatching...; posting a separate Carbon EventRef
// targets the wrong queue.
static MacWSDirectTrackingSnapshot MacWSAppInputMenuContext;
static BOOL MacWSAppInputMenuContextValid;
// Main-thread-only.  Retain the window selected by mouse-down until the
// matching up/cancel.  Runtime evidence showed a title-bar down can close the
// front Terminal window synchronously; re-hit-testing the up then targeted the
// newly exposed window (23 -> 6), splitting one gesture across two windows.
static CFTypeRef MacWSAppInputGestureWindow;
// Exact Host gestures are already routed against the DisplayStream layer
// graph before they enter this process.  Retain both the requested base
// window (the coordinate-space anchor) and the one real transient/base window
// selected at gesture begin.  Changed samples can then preserve AppKit's
// normal gesture ownership without repeating +[NSWindow
// windowNumberAtPoint:belowWindowWithWindowNumber:], a synchronous SkyLight
// round trip, at touch-display cadence.
static CFTypeRef MacWSAppInputGestureBaseWindow;
static uint32_t MacWSAppInputGestureBaseWindowNumber;
// Process-local CG scroll events never pass through WindowServer's hardware
// event queue, which normally owns NSWindow's latched scroll target. Keep the
// corresponding AppKit session balanced across the finger -> momentum split.
// Main-thread only.
static CFTypeRef MacWSAppInputScrollSessionWindow;
static uint64_t MacWSAppInputScrollSessionGeneration;
// Main-thread-only diagnostic witness for whether the real hit NSControl
// changed state after AppKit dispatch. It is observational: no setter/action
// is called by the bridge.
static CFTypeRef MacWSAppInputGestureHitView;
static double MacWSAppInputGestureHitValueBefore;
static BOOL MacWSAppInputGestureHitHasValue;
static MacWSSendEvent MacWSOriginalApplicationSendEvent;
static MacWSUnityDidSendEvent MacWSOriginalUnityDidSendEvent;
static MacWSCGEventSourceFlagsState
    MacWSOriginalCGEventSourceFlagsState;
static const struct mach_header_64 *MacWSSevenDaysUnityImage;
static __thread uint64_t MacWSAppInputDispatchModifierFlags;
static __thread unsigned MacWSAppInputDispatchModifierDepth;
static _Atomic uint64_t MacWSUnityMouseDiagnosticUntilMicros;
static _Atomic uint64_t MacWSUnityMouseDiagnosticSequence;
static MacWSHandleApplicationEvent MacWSOriginalHandleActivatedEvent;
// A tagged second Host tap is posted through CGPostMouseEvent so Finder keeps
// its real WindowServer target/activation state. That legacy API cannot encode
// click count, so retain the exact expected native down/up long enough for the
// NSApplication boundary below to restore kCGMouseEventClickState on those
// events and those events only.
typedef struct {
    NSInteger windowNumber;
    CGPoint screenPoint;
    double expiresAt;
    uint8_t pendingTypes;
} MacWSPendingSystemDoubleClick;
static MacWSPendingSystemDoubleClick MacWSSystemDoubleClick;
static pthread_mutex_t MacWSSystemDoubleClickLock = PTHREAD_MUTEX_INITIALIZER;
typedef struct {
    Class ownerClass;
    MacWSMenuEventLoop original;
} MacWSMenuEventLoopHook;
static MacWSMenuEventLoopHook MacWSMenuEventLoopHooks[32];
static size_t MacWSMenuEventLoopHookCount;
// Socket-thread key records are ordered. When Escape closes an active menu
// through AppKit's semantic cancellation path, consume its matching key-up so
// it cannot leak into the content window after the asynchronous close lands.
static _Atomic BOOL MacWSAppInputConsumeEscapeUp;
// True from immediately before an atomic secondary down enters
// NSApplication.sendEvent until the contextual-menu/rightMouseDown call
// returns. The socket thread uses this lifecycle witness to cancel the real
// HIToolbox tracker even if a main-thread target probe cannot publish the
// transient NSMenuWindowManagerWindow while that tracker is nested.
static _Atomic BOOL MacWSAppInputSynchronousTrackingActive;
// Main-thread-only observational witness. The wrapped AppKit method owns the
// real nested menu event loop for the complete lifetime of this pointer.
// AppInput uses it only to put mouse-moved NSEvents into NSApplication's real
// queue; AppKit remains responsible for hit-testing, highlighting and action.
static id MacWSAppInputTrackingMenuPresentation;
// Main-thread-only.  This is the real AppKit/CGS activation event delivered
// for the latest native click, retained so a missing Workspace lifecycle
// callback can be completed with the exact event AppKit generated.
static CFTypeRef MacWSLastSystemActivationEvent;
static double MacWSLastSystemActivationEventTime;
static _Atomic uint64_t MacWSApplicationDisplaySettleSerial;
static uint32_t MacWSApplicationDisplaySettleMilliseconds;

typedef struct {
    uint32_t highLongOfPSN;
    uint32_t lowLongOfPSN;
} MacWSProcessSerialNumber;

typedef int32_t (*MacWSGetFrontUIProcess)(MacWSProcessSerialNumber *);
typedef int32_t (*MacWSSameProcess)(const MacWSProcessSerialNumber *,
                                    const MacWSProcessSerialNumber *,
                                    uint8_t *);
typedef const void *(*MacWSGetCurrentApplicationASN)(void);
typedef int32_t (*MacWSSetFrontApplication)(int32_t, const void *,
                                            CFDictionaryRef);
typedef int32_t (*MacWSSetApplicationInformationItem)(
    int32_t, const void *, CFStringRef, CFTypeRef, CFDictionaryRef *);
typedef int32_t (*MacWSSLPSGetProcess)(MacWSProcessSerialNumber *);
typedef int32_t (*MacWSSLPSGetKeyFocusProcess)(
    MacWSProcessSerialNumber *, uint8_t *);
typedef int32_t (*MacWSSLPSSetFrontProcessWithOptions)(
    const MacWSProcessSerialNumber *, uint32_t, uint64_t);
typedef int32_t (*MacWSSLPSStealKeyFocus)(void *, uint32_t);
typedef void *(*MacWSHIApplicationGetAppObject)(void);
typedef void (*MacWSHIApplicationFrontUILost)(void *);
typedef void (*MacWSSetMenuBarObscured)(uint8_t);
typedef void (*MacWSRecalcBar)(uint8_t);
static void *MacWSResolveHIToolboxLocal(uintptr_t imageOffset,
                                        const uint8_t *expectedPrologue,
                                        size_t expectedPrologueSize);

typedef struct {
    int32_t getStatus;
    int32_t sameStatus;
    MacWSProcessSerialNumber front;
    BOOL ownsFrontUIProcess;
} MacWSFrontUISnapshot;

// RE-confirmed on-device against macOS 13.4:
// +[NSMenuUtils isCurrentProcessMenuBarOwner] calls _GetFrontUIProcess and
// SameProcess against the special current-process PSN {0, 2}.  Mirror that
// read-only test so target selection observes the same ownership invariant as
// AppKit's global menu and transient-presentation code.
static MacWSFrontUISnapshot MacWSCaptureFrontUISnapshot(void) {
    static MacWSGetFrontUIProcess getFrontUIProcess;
    static MacWSSameProcess sameProcess;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getFrontUIProcess = (MacWSGetFrontUIProcess)dlsym(
            RTLD_DEFAULT, "_GetFrontUIProcess");
        sameProcess = (MacWSSameProcess)dlsym(RTLD_DEFAULT, "SameProcess");
    });
    MacWSFrontUISnapshot snapshot = {
        .getStatus = INT32_MIN,
        .sameStatus = INT32_MIN,
    };
    if (!getFrontUIProcess || !sameProcess) return snapshot;
    snapshot.getStatus = getFrontUIProcess(&snapshot.front);
    if (snapshot.getStatus != 0) return snapshot;
    const MacWSProcessSerialNumber current = {0, 2};
    uint8_t same = 0;
    snapshot.sameStatus = sameProcess(&snapshot.front, &current, &same);
    snapshot.ownsFrontUIProcess = snapshot.sameStatus == 0 && same != 0;
    return snapshot;
}

// SkyLight front/key focus, LaunchServices front application, and
// LaunchServices menu-bar ownership are three separate transactions in this
// macOS build.  On-device RE proves _LSSetFrontApplication sends message 0x38e
// and only changes LSSession::frontApplication.  Menu ownership is an
// application property, not a session-meta property: the five-argument
// _LSSetApplicationInformationItem(-2, ASN, _kLSMenuBarOwningASNKey, ASN,
// NULL) sends command 0x1fe.  Its launchservicesd handler resolves the target
// application and the key callback reaches
// LSSession::SetMenuBarOwningApplication, which locks the session shared page,
// writes MenuBarOwnerASNLow, and increments its seed.  The superficially
// successful _LSSetMetaApplicationInformationItem command 0xd2 instead logs
// this key as unrecognized and performs no owner mutation.  Run the upstream
// transactions only after the broker has observed a real cross-process native
// click whose normal activation transaction did not converge.
static BOOL MacWSRepairFrontUIApplication(id application, const char *phase) {
    BOOL diagnostics = MacWSRuntimeDiagnosticsEnabled();
    MacWSFrontUISnapshot before = diagnostics
        ? MacWSCaptureFrontUISnapshot() : (MacWSFrontUISnapshot){0};
    MacWSProcessSerialNumber currentProcess = {0};
    MacWSProcessSerialNumber keyFocusBefore = {0};
    MacWSProcessSerialNumber keyFocusAfter = {0};
    uint8_t keyFocusBeforeValid = 0;
    uint8_t keyFocusAfterValid = 0;
    int32_t currentProcessStatus = INT32_MIN;
    int32_t skyLightSetStatus = INT32_MIN;
    int32_t stealKeyFocusStatus = INT32_MIN;
    int32_t keyFocusBeforeStatus = INT32_MIN;
    int32_t keyFocusAfterStatus = INT32_MIN;
    uint32_t targetWindowNumber = 0;
    int32_t setStatus = INT32_MIN;
    int32_t menuOwnerSetStatus = INT32_MIN;
    const void *asn = NULL;
    static MacWSGetCurrentApplicationASN getCurrentApplicationASN;
    static MacWSSetFrontApplication setFrontApplication;
    static MacWSSetApplicationInformationItem
        setApplicationInformationItem;
    static const CFStringRef *menuBarOwningASNKeyAddress;
    static MacWSSLPSGetProcess getCurrentProcess;
    static MacWSSLPSGetKeyFocusProcess getKeyFocusProcess;
    static MacWSSLPSSetFrontProcessWithOptions
        setFrontProcessWithOptions;
    static MacWSSLPSStealKeyFocus stealKeyFocus;
    static MacWSSetMenuBarObscured setMenuBarObscured;
    static MacWSRecalcBar recalcBar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getCurrentApplicationASN =
            (MacWSGetCurrentApplicationASN)dlsym(
                RTLD_DEFAULT, "_LSGetCurrentApplicationASN");
        setFrontApplication = (MacWSSetFrontApplication)dlsym(
            RTLD_DEFAULT, "_LSSetFrontApplication");
        setApplicationInformationItem =
            (MacWSSetApplicationInformationItem)dlsym(
                RTLD_DEFAULT, "_LSSetApplicationInformationItem");
        menuBarOwningASNKeyAddress = (const CFStringRef *)dlsym(
            RTLD_DEFAULT, "_kLSMenuBarOwningASNKey");
        getCurrentProcess = (MacWSSLPSGetProcess)dlsym(
            RTLD_DEFAULT, "SLPSGetCurrentProcess");
        getKeyFocusProcess = (MacWSSLPSGetKeyFocusProcess)dlsym(
            RTLD_DEFAULT, "SLPSGetKeyFocusProcess");
        setFrontProcessWithOptions =
            (MacWSSLPSSetFrontProcessWithOptions)dlsym(
                RTLD_DEFAULT, "SLPSSetFrontProcessWithOptions");
        stealKeyFocus = (MacWSSLPSStealKeyFocus)dlsym(
            RTLD_DEFAULT, "SLPSStealKeyFocus");
        setMenuBarObscured = (MacWSSetMenuBarObscured)dlsym(
            RTLD_DEFAULT, "SetMenuBarObscured");
        if (!setMenuBarObscured) {
            static const uint8_t prologue[16] = {
                0x7f, 0x23, 0x03, 0xd5, 0xff, 0xc3, 0x00, 0xd1,
                0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9,
            };
            setMenuBarObscured = (MacWSSetMenuBarObscured)
                MacWSResolveHIToolboxLocal(
                    0x467f4, prologue, sizeof(prologue));
        }
        // RE-confirmed against this HIToolbox UUID: SetRootMenu calls
        // RecalcBarIfRoot, but skips that entire transaction when the target
        // process already installed the same gRootMenu before it became the
        // session menu-bar owner. Resolve the exact downstream RecalcBar(1)
        // used by RecalcBarIfRoot+0x84 so the owner handoff can recompute and
        // invalidate the target process's real root menu.
        static const uint8_t recalcBarPrologue[12] = {
            0x7f, 0x23, 0x03, 0xd5, 0xfd, 0x7b, 0xbf, 0xa9,
            0xfd, 0x03, 0x00, 0x91,
        };
        recalcBar = (MacWSRecalcBar)MacWSResolveHIToolboxLocal(
            0x11878, recalcBarPrologue, sizeof(recalcBarPrologue));
    });
    if (diagnostics && getKeyFocusProcess) {
        keyFocusBeforeStatus = getKeyFocusProcess(
            &keyFocusBefore, &keyFocusBeforeValid);
    }
    if (getCurrentProcess) {
        currentProcessStatus = getCurrentProcess(&currentProcess);
    }
    id keyWindow = application ? ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("keyWindow")) : nil;
    if (!keyWindow && application) {
        keyWindow = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainWindow"));
    }
    if (!keyWindow && application) {
        id orderedWindows = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("orderedWindows"));
        NSUInteger count = [orderedWindows count];
        for (NSUInteger index = 0; index < count; index++) {
            id candidate = [orderedWindows objectAtIndex:index];
            if (((MacWSMsgBool)objc_msgSend)(
                    candidate, sel_registerName("isVisible"))) {
                keyWindow = candidate;
                break;
            }
        }
    }
    if (keyWindow) {
        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
            keyWindow, sel_registerName("windowNumber"));
        if (number > 0 && number <= UINT32_MAX)
            targetWindowNumber = (uint32_t)number;
    }
    if (currentProcessStatus == 0 && setFrontProcessWithOptions) {
        // RE-confirmed in SkyLight 13.4: option 0x100 is allWindows and
        // 0x200 is causedByUser.  The public HIServices path discards both
        // before calling SLPSSetFrontProcess(window=0, options=0).  This
        // broker control exists only after a real native RFB mouse-down, so
        // preserve that actual user cause and the exact AppKit key window in
        // the server-side front-process transaction.
        skyLightSetStatus = setFrontProcessWithOptions(
            &currentProcess, targetWindowNumber, 0x300);
    }
    if (skyLightSetStatus == 0 && stealKeyFocus) {
        // Runtime-confirmed before this call was added: the explicit front
        // transaction returned 0 while SLPSGetKeyFocusProcess still named
        // GlassDemo (PSN 0x9009) from inside Terminal (PSN 0x8008).  This
        // official SkyLight operation asks the caller's primary connection to
        // become key focus; it does not forge an isKey/isActive result.
        stealKeyFocusStatus = stealKeyFocus(NULL, 0);
    }
    asn = getCurrentApplicationASN
        ? getCurrentApplicationASN() : NULL;
    if (asn && setFrontApplication) {
        // -2 is the current LaunchServices session.  It is the same session
        // selector used by _GetFrontUIProcess's _LSCopyFrontUIApplication
        // call in this exact binary.  Send the transaction for every broker-
        // coordinated activation: runtime showed that SameProcess can report
        // the caller-equivalent PSN before the visible global menu has moved,
        // so it is a postcondition witness but not a safe reason to omit the
        // upstream LaunchServices write.
        setStatus = setFrontApplication(-2, asn, NULL);
    }
    if (asn && setApplicationInformationItem &&
        menuBarOwningASNKeyAddress && *menuBarOwningASNKeyAddress) {
        // Target the current application's real information record.  The
        // fifth argument requests the prior dictionary when non-NULL; the
        // bridge does not need it.  Do not write the client shared page: its
        // mapping is read-only and an on-device unchanged-value write was
        // runtime-confirmed to raise SIGBUS.
        menuOwnerSetStatus = setApplicationInformationItem(
            -2, asn, *menuBarOwningASNKeyAddress, (CFTypeRef)asn, NULL);
    }
    id mainMenu = nil;
    id menuImplementation = nil;
    const char *installedMainMenuBar = "NO";
    SEL mainMenuSelector = sel_registerName("mainMenu");
    SEL menuImplementationSelector = sel_registerName("_menuImpl");
    SEL setAsMainMenuBarSelector = sel_registerName("setAsMainMenuBar");
    SEL setAsMainCarbonMenuBarSelector =
        sel_registerName("setAsMainCarbonMenuBar");
    if (application && ((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            mainMenuSelector)) {
        mainMenu = ((MacWSMsgID)objc_msgSend)(
            application, mainMenuSelector);
    }
    if (mainMenu && ((MacWSMsgBoolSEL)objc_msgSend)(
            mainMenu, sel_registerName("respondsToSelector:"),
            menuImplementationSelector)) {
        menuImplementation = ((MacWSMsgID)objc_msgSend)(
            mainMenu, menuImplementationSelector);
    }
    if (menuImplementation && ((MacWSMsgBoolSEL)objc_msgSend)(
            menuImplementation, sel_registerName("respondsToSelector:"),
            setAsMainMenuBarSelector)) {
        // RE-confirmed in this AppKit build: NSMenu's NSMainMenu path ends by
        // sending setAsMainMenuBar to its existing _menuImpl.  Re-send that
        // real installation step after the missing cross-process activation
        // transaction; do not replace the menu, forge ownership, or override
        // any AppKit predicate.
        ((MacWSMsgVoid)objc_msgSend)(
            menuImplementation, setAsMainMenuBarSelector);
        installedMainMenuBar = "APPKIT";
    } else if (menuImplementation && ((MacWSMsgBoolSEL)objc_msgSend)(
            menuImplementation, sel_registerName("respondsToSelector:"),
            setAsMainCarbonMenuBarSelector)) {
        // The compatibility menu implementation takes the sibling branch in
        // the same NSMenu::_setMenuName(NSMainMenu) function.  Terminal 13.4
        // runtime-confirmed its _menuImpl exposes this selector rather than
        // setAsMainMenuBar.
        ((MacWSMsgVoid)objc_msgSend)(
            menuImplementation, setAsMainCarbonMenuBarSelector);
        installedMainMenuBar = "CARBON";
    }
    const char *recalculatedMainMenuBar = "NOT-CARBON";
    if (strcmp(installedMainMenuBar, "CARBON") == 0) {
        if (recalcBar) {
            recalcBar(1);
            recalculatedMainMenuBar = "CALLED";
        } else {
            recalculatedMainMenuBar = "UNAVAILABLE";
        }
    }
    const char *unobscuredMenuBar = "UNAVAILABLE";
    if (setMenuBarObscured) {
        // RE-confirmed ordering in HIToolbox 13.4:
        // HIApplication::HandleActivated(active=true) executes
        // EndNonActiveMenuBar followed by SetMenuBarObscured(false), while
        // FrontUILost executes SetMenuBarObscured(true).  The native target
        // activation arrives before the broker can drain the old process's
        // asynchronous deactivation.  Re-assert the real final activation
        // step after installing this target's actual menu implementation.
        setMenuBarObscured(0);
        unobscuredMenuBar = "CALLED";
    }
    if (diagnostics && getKeyFocusProcess) {
        keyFocusAfterStatus = getKeyFocusProcess(
            &keyFocusAfter, &keyFocusAfterValid);
    }
    MacWSFrontUISnapshot after = MacWSCaptureFrontUISnapshot();
    if (diagnostics) {
        fprintf(stderr,
        "#### APP-INPUT FRONT-UI pid=%d phase=%s "
        "before=%s get=%d same=%d psn=%#x-%#x "
        "current=%d:%#x-%#x sky-set=%d steal-key=%d window=%u "
        "key-before=%d:%d:%#x-%#x key-after=%d:%d:%#x-%#x "
        "asn=%p ls-set=%d ls-menu-owner=%d menu=%p impl=%p "
        "install=%s recalc=%s unobscure=%s "
        "after=%s get=%d same=%d psn=%#x-%#x\n",
        getpid(), phase ? phase : "(null)",
        before.ownsFrontUIProcess ? "OWNED" : "OTHER",
        before.getStatus, before.sameStatus,
        before.front.highLongOfPSN, before.front.lowLongOfPSN,
        currentProcessStatus, currentProcess.highLongOfPSN,
        currentProcess.lowLongOfPSN, skyLightSetStatus,
        stealKeyFocusStatus,
        targetWindowNumber,
        keyFocusBeforeStatus, keyFocusBeforeValid,
        keyFocusBefore.highLongOfPSN, keyFocusBefore.lowLongOfPSN,
        keyFocusAfterStatus, keyFocusAfterValid,
        keyFocusAfter.highLongOfPSN, keyFocusAfter.lowLongOfPSN,
        asn, setStatus, menuOwnerSetStatus, mainMenu, menuImplementation,
        installedMainMenuBar, recalculatedMainMenuBar, unobscuredMenuBar,
        after.ownsFrontUIProcess ? "OWNED" : "OTHER",
        after.getStatus, after.sameStatus,
            after.front.highLongOfPSN, after.front.lowLongOfPSN);
        fflush(stderr);
    }
    return after.ownsFrontUIProcess;
}

static double MacWSAppInputMonotonicSeconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static void MacWSSetLastSystemActivationEvent(id event) {
    CFTypeRef replacement = event
        ? CFRetain((__bridge CFTypeRef)event) : NULL;
    CFTypeRef previous = MacWSLastSystemActivationEvent;
    MacWSLastSystemActivationEvent = replacement;
    MacWSLastSystemActivationEventTime = event
        ? MacWSAppInputMonotonicSeconds() : 0.0;
    if (previous) CFRelease(previous);
}

static void MacWSAppInputHandleActivatedEvent(id self, SEL command, id event) {
    MacWSSetLastSystemActivationEvent(event);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        NSInteger windowNumber = event ? ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("windowNumber")) : 0;
        NSInteger data1 = event ? ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("data1")) : 0;
        NSInteger data2 = event ? ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("data2")) : 0;
        fprintf(stderr,
            "#### APP-INPUT SYSTEM-ACTIVATE-EVENT pid=%d window=%ld "
            "data1=%ld data2=%ld retained=%s\n",
            getpid(), (long)windowNumber, (long)data1, (long)data2,
            event ? "YES" : "NO");
        fflush(stderr);
    }
    if (MacWSOriginalHandleActivatedEvent)
        MacWSOriginalHandleActivatedEvent(self, command, event);
}

// Narrow usability scaffold at a runtime-confirmed Terminal race.  With fast
// commands, the pty model can advance after Return's delayed AppKit redraw has
// already been consumed, leaving the result one transaction behind.  LLDB also
// proved that Terminal normally calls -[NSView setNeedsDisplayInRect:] from an
// NSFireDelayedPerform callback, and output deliberately delayed by two seconds
// renders without this callback.  Therefore this is NOT a replacement display
// clock and must not be installed globally: only an application whose launch
// environment explicitly sets MACWS_APP_DISPLAY_SETTLE_MS gets one debounced
// post-Return invalidation.  Ordinary character key-ups must not enter this
// path: forcing TTView to invalidate and synchronously flushing CATransaction
// while the user types makes the complete terminal contents flash.  A 250-ms
// displayIfNeeded-only A/B observed
// viewsNeedDisplay=NO and did not recover the fast-output race; the forced
// responder invalidation is intentionally labelled a scaffold, not a root fix.
static void MacWSScheduleApplicationDisplaySettle(void) {
    uint64_t serial = atomic_fetch_add_explicit(
        &MacWSApplicationDisplaySettleSerial, 1,
        memory_order_acq_rel) + 1;
    uint64_t delayNanoseconds =
        (uint64_t)MacWSApplicationDisplaySettleMilliseconds * NSEC_PER_MSEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNanoseconds),
                   dispatch_get_main_queue(), ^{
        if (atomic_load_explicit(&MacWSApplicationDisplaySettleSerial,
                                 memory_order_acquire) != serial) return;
        Class applicationClass = objc_getClass("NSApplication");
        id application = applicationClass ? ((MacWSMsgID)objc_msgSend)(
            applicationClass, sel_registerName("sharedApplication")) : nil;
        id window = application ? ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("keyWindow")) : nil;
        id responder = window ? ((MacWSMsgID)objc_msgSend)(
            window, sel_registerName("firstResponder")) : nil;
        SEL setNeedsDisplay = sel_registerName("setNeedsDisplay:");
        BOOL canInvalidate = responder && ((MacWSMsgBoolSEL)objc_msgSend)(
            responder, sel_registerName("respondsToSelector:"),
            setNeedsDisplay);
        BOOL diagnostics = MacWSRuntimeDiagnosticsEnabled();
        BOOL hasString = diagnostics && responder &&
            ((MacWSMsgBoolSEL)objc_msgSend)(
                responder, sel_registerName("respondsToSelector:"),
                sel_registerName("string"));
        id string = hasString ? ((MacWSMsgID)objc_msgSend)(
            responder, sel_registerName("string")) : nil;
        NSUInteger stringLength = string ? ((MacWSMsgUInteger)objc_msgSend)(
            string, sel_registerName("length")) : 0;
        BOOL neededBefore = diagnostics && window &&
            ((MacWSMsgBool)objc_msgSend)(
                window, sel_registerName("viewsNeedDisplay"));
        double started = diagnostics
            ? MacWSAppInputMonotonicSeconds() : 0.0;
        if (canInvalidate) ((MacWSMsgVoidBool)objc_msgSend)(
            responder, setNeedsDisplay, YES);
        if (window) ((void (*)(id, SEL))objc_msgSend)(
            window, sel_registerName("displayIfNeeded"));
        Class transactionClass = objc_getClass("CATransaction");
        SEL flushSelector = sel_registerName("flush");
        if (transactionClass && class_respondsToSelector(
                object_getClass(transactionClass), flushSelector)) {
            ((void (*)(id, SEL))objc_msgSend)(
                transactionClass, flushSelector);
        }
        if (diagnostics) {
            BOOL neededAfter = window && ((MacWSMsgBool)objc_msgSend)(
                window, sel_registerName("viewsNeedDisplay"));
            static _Atomic uint64_t settleCount;
            uint64_t count = atomic_fetch_add_explicit(
                &settleCount, 1, memory_order_relaxed) + 1;
            if (count <= 24) {
            fprintf(stderr,
                "#### APP-INPUT DISPLAY-SETTLE pid=%d serial=%llu "
                "window=%ld responder=%s string-length=%lu "
                "forced=%s needed-before=%s needed-after=%s "
                "delay=%ums elapsed=%.3fms at=%.6f\n",
                getpid(), (unsigned long long)serial,
                window ? (long)((MacWSMsgInteger)objc_msgSend)(
                    window, sel_registerName("windowNumber")) : -1L,
                responder ? object_getClassName(responder) : "(null)",
                (unsigned long)stringLength,
                canInvalidate ? "YES" : "NO",
                neededBefore ? "YES" : "NO",
                neededAfter ? "YES" : "NO",
                MacWSApplicationDisplaySettleMilliseconds,
                (MacWSAppInputMonotonicSeconds() - started) * 1000.0,
                started);
            fflush(stderr);
            }
        }
    });
}

static void MacWSArmSystemDoubleClick(NSInteger windowNumber,
                                     CGPoint screenPoint) {
    pthread_mutex_lock(&MacWSSystemDoubleClickLock);
    MacWSSystemDoubleClick.windowNumber = windowNumber;
    MacWSSystemDoubleClick.screenPoint = screenPoint;
    MacWSSystemDoubleClick.expiresAt =
        MacWSAppInputMonotonicSeconds() + 1.0;
    MacWSSystemDoubleClick.pendingTypes = 0x3; // native left down + up
    pthread_mutex_unlock(&MacWSSystemDoubleClickLock);
}

static void MacWSCancelSystemDoubleClick(void) {
    pthread_mutex_lock(&MacWSSystemDoubleClickLock);
    memset(&MacWSSystemDoubleClick, 0, sizeof(MacWSSystemDoubleClick));
    pthread_mutex_unlock(&MacWSSystemDoubleClickLock);
}

// Restore clickCount=2 on the actual NSEvent produced by WindowServer, rather
// than fabricating a process-local replacement from the Host record. The
// pending tuple is armed only after the caller proves that the Host-selected
// content window is also WindowServer's global hit. Match its native window,
// type, point and a bounded lifetime before touching the event. This preserves
// every opaque source/connection/activation field that Finder's open action
// receives on hardware input.
static id MacWSRestorePendingSystemDoubleClick(id event, NSUInteger type,
                                                BOOL *matchedEvent) {
    if (matchedEvent) *matchedEvent = NO;
    if (!event || (type != 1 && type != 2)) return event;
    NSInteger windowNumber = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("windowNumber"));
    id window = ((MacWSMsgID)objc_msgSend)(
        event, sel_registerName("window"));
    CGPoint localPoint = ((MacWSMsgPoint)objc_msgSend)(
        event, sel_registerName("locationInWindow"));
    CGPoint screenPoint = window
        ? ((MacWSMsgPointPoint)objc_msgSend)(
            window, sel_registerName("convertPointToScreen:"), localPoint)
        : (CGPoint){NAN, NAN};
    uint8_t typeBit = type == 1 ? 0x1 : 0x2;
    BOOL matched = NO;
    double now = MacWSAppInputMonotonicSeconds();

    pthread_mutex_lock(&MacWSSystemDoubleClickLock);
    if (MacWSSystemDoubleClick.pendingTypes != 0 &&
        now <= MacWSSystemDoubleClick.expiresAt &&
        (MacWSSystemDoubleClick.pendingTypes & typeBit) != 0 &&
        MacWSSystemDoubleClick.windowNumber == windowNumber &&
        isfinite(screenPoint.x) && isfinite(screenPoint.y) &&
        fabs(screenPoint.x - MacWSSystemDoubleClick.screenPoint.x) <= 2.0 &&
        fabs(screenPoint.y - MacWSSystemDoubleClick.screenPoint.y) <= 2.0) {
        matched = YES;
        MacWSSystemDoubleClick.pendingTypes &= ~typeBit;
        if (MacWSSystemDoubleClick.pendingTypes == 0)
            memset(&MacWSSystemDoubleClick, 0,
                   sizeof(MacWSSystemDoubleClick));
    } else if (MacWSSystemDoubleClick.pendingTypes != 0 &&
               now > MacWSSystemDoubleClick.expiresAt) {
        memset(&MacWSSystemDoubleClick, 0,
               sizeof(MacWSSystemDoubleClick));
    }
    pthread_mutex_unlock(&MacWSSystemDoubleClickLock);
    if (!matched) return event;
    if (matchedEvent) *matchedEvent = YES;

    NSInteger before = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("clickCount"));
    static MacWSSetCGEventIntegerField setInteger;
    static MacWSCopyCGEvent copyEvent;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
        copyEvent = (MacWSCopyCGEvent)dlsym(
            RTLD_DEFAULT, "CGEventCreateCopy");
    });
    SEL cgEventSelector = sel_registerName("CGEvent");
    MacWSCGEventRef nativeEvent = setInteger &&
        ((MacWSMsgBoolSEL)objc_msgSend)(
            event, sel_registerName("respondsToSelector:"), cgEventSelector)
        ? ((MacWSEventRef)objc_msgSend)(event, cgEventSelector) : NULL;
    if (nativeEvent) setInteger(
        nativeEvent, 1 /* kCGMouseEventClickState */, 2);
    NSInteger after = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("clickCount"));
    id replacement = event;
    const char *route = after == 2 ? "native-record" : "failed";

    // Some NSEvent subclasses cache the click count during initialization.
    // If their public getter did not observe the in-place record edit, wrap a
    // copy of that *same native event* and require window, location, type and
    // click count to round-trip before using it. Failure leaves the original
    // event untouched rather than forcing Finder behavior.
    if (after != 2 && nativeEvent && copyEvent) {
        MacWSCGEventRef copy = copyEvent(nativeEvent);
        if (copy) {
            setInteger(copy, 1 /* kCGMouseEventClickState */, 2);
            Class eventClass = objc_getClass("NSEvent");
            SEL factory = sel_registerName("eventWithCGEvent:");
            id candidate = eventClass && class_respondsToSelector(
                    object_getClass(eventClass), factory)
                ? ((MacWSEventFromCGEvent)objc_msgSend)(
                    (id)eventClass, factory, copy) : nil;
            CFRelease(copy);
            if (candidate) {
                NSInteger candidateWindow = ((MacWSMsgInteger)objc_msgSend)(
                    candidate, sel_registerName("windowNumber"));
                NSUInteger candidateType = ((MacWSMsgUInteger)objc_msgSend)(
                    candidate, sel_registerName("type"));
                NSInteger candidateClicks = ((MacWSMsgInteger)objc_msgSend)(
                    candidate, sel_registerName("clickCount"));
                CGPoint candidatePoint = ((MacWSMsgPoint)objc_msgSend)(
                    candidate, sel_registerName("locationInWindow"));
                if (candidateWindow == windowNumber &&
                    candidateType == type && candidateClicks == 2 &&
                    fabs(candidatePoint.x - localPoint.x) <= 2.0 &&
                    fabs(candidatePoint.y - localPoint.y) <= 2.0) {
                    replacement = candidate;
                    after = candidateClicks;
                    route = "native-copy-rewrap";
                }
            }
        }
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT DOUBLE-RESTORE pid=%d window=%ld type=%lu "
            "local=(%.2f,%.2f) screen=(%.2f,%.2f) clicks=%ld->%ld "
            "route=%s\n",
            getpid(), (long)windowNumber, (unsigned long)type,
            localPoint.x, localPoint.y, screenPoint.x, screenPoint.y,
            (long)before, (long)after, route);
        fflush(stderr);
    }
    return replacement;
}

// Diagnostic-only witness at the exact Unity 2022.3.62f2 event boundary.
// The shipped arm64 UnityPlayer.dylib's -[PlayerWindowView mouseDown:] at
// 0xf166b8 calls -[PlayerAppDelegate DidSendEvent:] before falling back to
// AppKit. Record the real return value here; never replace it or alter the
// event. This distinguishes an AppKit delivery failure from a rejection in
// Unity's own event adapter without turning the adapter into an always-YES
// symptom bypass.
static BOOL MacWSUnityDidSendEventDiagnostic(id self, SEL command, id event) {
    BOOL accepted = MacWSOriginalUnityDidSendEvent
        ? MacWSOriginalUnityDidSendEvent(self, command, event) : NO;
    NSUInteger type = event ? ((MacWSMsgUInteger)objc_msgSend)(
        event, sel_registerName("type")) : 0;
    NSInteger windowNumber = event ? ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("windowNumber")) : 0;
    CGPoint local = event ? ((MacWSMsgPoint)objc_msgSend)(
        event, sel_registerName("locationInWindow")) : CGPointZero;
    uint32_t currentWord = 0;
    uint32_t downWord = 0;
    uint32_t upWord = 0;
    float managerX = NAN;
    float managerY = NAN;
    BOOL managerRead = NO;
    // Exact diagnostic for the shipped UnityPlayer 2022.3.62f2 arm64 image
    // (SHA-256 89ddca014c60f0a909e23fe87664f0c5ac70fe1889621a533c252cc8b6985e56).
    // RE-confirmed: +0x462344 calls the global-manager lookup for index 1;
    // +0x60/+0x80/+0xa0 are current/down/up bit-vector pointers and mouse
    // button zero is key 0x143 (word 10, bit 3). +0xc8 is the sampled x/y.
    // This block only reads those fields after Unity's real method returns.
    Dl_info unityInfo = {0};
    if (MacWSOriginalUnityDidSendEvent &&
        dladdr((void *)MacWSOriginalUnityDidSendEvent, &unityInfo) &&
        unityInfo.dli_fbase && unityInfo.dli_fname &&
        strstr(unityInfo.dli_fname, "/UnityPlayer.dylib")) {
        typedef void *(*MacWSUnityInputManagerGetter)(void);
        MacWSUnityInputManagerGetter getter =
            (MacWSUnityInputManagerGetter)((uintptr_t)unityInfo.dli_fbase +
                                           0x462344u);
        uint8_t *manager = (uint8_t *)getter();
        if (manager) {
            uint32_t *current = *(uint32_t **)(manager + 0x60);
            uint32_t *down = *(uint32_t **)(manager + 0x80);
            uint32_t *up = *(uint32_t **)(manager + 0xa0);
            if (current && down && up) {
                currentWord = current[10];
                downWord = down[10];
                upWord = up[10];
                memcpy(&managerX, manager + 0xc8, sizeof(managerX));
                memcpy(&managerY, manager + 0xcc, sizeof(managerY));
                managerRead = YES;
            }
        }
    }
    fprintf(stderr,
        "#### APP-INPUT UNITY-DID-SEND pid=%d type=%lu window=%ld "
        "local=(%.2f,%.2f) result=%s manager=%s "
        "button0(current/down/up)=%u/%u/%u mouse=(%.2f,%.2f)\n",
        getpid(), (unsigned long)type, (long)windowNumber,
        local.x, local.y, accepted ? "YES" : "NO",
        managerRead ? "READ" : "UNAVAILABLE",
        !!(currentWord & 8u), !!(downWord & 8u), !!(upWord & 8u),
        managerX, managerY);
    fflush(stderr);
    if (type >= 1 && type <= 7) {
        MacWSLogUnityNGUIInputState("did-send");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MacWSLogUnityNGUIInputState("post-frame");
        });
    }
    return accepted;
}

// Read-only managed witness for the NGUI input fork used by 7DTD.  NGUI.dll
// UICamera::ProcessEvents (SHA-256
// 414c386911bf52e8b246ec89d4fb0c5ff41b9e5c1c59069b617f193a60947f37)
// is RE-confirmed to execute ProcessTouches exclusively when instance field
// useTouch is true; ProcessMouse is reached only from the false branch.  The
// Unity InputManager witness above proves the native mouse bits are populated,
// so record the live branch selector and hit target before changing policy.
// All Mono calls below are getters/field reads and remain diagnostic-only.
static void MacWSLogUnityNGUIInputState(const char *phase) {
    typedef void *(*MonoGetRootDomain)(void);
    typedef void *(*MonoThreadAttach)(void *);
    typedef void *(*MonoAssemblyNameNew)(const char *);
    typedef void (*MonoAssemblyNameFree)(void *);
    typedef void *(*MonoAssemblyLoaded)(void *);
    typedef void *(*MonoAssemblyGetImage)(void *);
    typedef void *(*MonoClassFromName)(void *, const char *, const char *);
    typedef void *(*MonoClassGetMethodFromName)(void *, const char *, int);
    typedef void *(*MonoClassGetFieldFromName)(void *, const char *);
    typedef void *(*MonoRuntimeInvoke)(void *, void *, void **, void **);
    typedef void (*MonoFieldGetValue)(void *, void *, void *);
    typedef void *(*MonoClassVTable)(void *, void *);
    typedef void (*MonoFieldStaticGetValue)(void *, void *, void *);
    typedef void *(*MonoObjectUnbox)(void *);
    typedef void *(*MonoObjectToString)(void *, void **);
    typedef char *(*MonoStringToUTF8)(void *);
    typedef void (*MonoFree)(void *);

    static struct {
        MonoGetRootDomain getRootDomain;
        MonoThreadAttach threadAttach;
        MonoAssemblyNameNew assemblyNameNew;
        MonoAssemblyNameFree assemblyNameFree;
        MonoAssemblyLoaded assemblyLoaded;
        MonoAssemblyGetImage assemblyGetImage;
        MonoClassFromName classFromName;
        MonoClassGetMethodFromName classGetMethodFromName;
        MonoClassGetFieldFromName classGetFieldFromName;
        MonoRuntimeInvoke runtimeInvoke;
        MonoFieldGetValue fieldGetValue;
        MonoClassVTable classVTable;
        MonoFieldStaticGetValue fieldStaticGetValue;
        MonoObjectUnbox objectUnbox;
        MonoObjectToString objectToString;
        MonoStringToUTF8 stringToUTF8;
        MonoFree monoFree;
    } api;
    static dispatch_once_t apiOnce;
    dispatch_once(&apiOnce, ^{
#define MACWS_MONO_RESOLVE(field, symbol) \
        api.field = (typeof(api.field))dlsym(RTLD_DEFAULT, symbol)
        MACWS_MONO_RESOLVE(getRootDomain, "mono_get_root_domain");
        MACWS_MONO_RESOLVE(threadAttach, "mono_thread_attach");
        MACWS_MONO_RESOLVE(assemblyNameNew, "mono_assembly_name_new");
        MACWS_MONO_RESOLVE(assemblyNameFree, "mono_assembly_name_free");
        MACWS_MONO_RESOLVE(assemblyLoaded, "mono_assembly_loaded");
        MACWS_MONO_RESOLVE(assemblyGetImage, "mono_assembly_get_image");
        MACWS_MONO_RESOLVE(classFromName, "mono_class_from_name");
        MACWS_MONO_RESOLVE(classGetMethodFromName,
                           "mono_class_get_method_from_name");
        MACWS_MONO_RESOLVE(classGetFieldFromName,
                           "mono_class_get_field_from_name");
        MACWS_MONO_RESOLVE(runtimeInvoke, "mono_runtime_invoke");
        MACWS_MONO_RESOLVE(fieldGetValue, "mono_field_get_value");
        MACWS_MONO_RESOLVE(classVTable, "mono_class_vtable");
        MACWS_MONO_RESOLVE(fieldStaticGetValue,
                           "mono_field_static_get_value");
        MACWS_MONO_RESOLVE(objectUnbox, "mono_object_unbox");
        MACWS_MONO_RESOLVE(objectToString, "mono_object_to_string");
        MACWS_MONO_RESOLVE(stringToUTF8, "mono_string_to_utf8");
        MACWS_MONO_RESOLVE(monoFree, "mono_free");
#undef MACWS_MONO_RESOLVE
    });
    if (!api.getRootDomain || !api.threadAttach || !api.assemblyNameNew ||
        !api.assemblyNameFree || !api.assemblyLoaded ||
        !api.assemblyGetImage || !api.classFromName ||
        !api.classGetMethodFromName || !api.classGetFieldFromName ||
        !api.runtimeInvoke || !api.fieldGetValue || !api.classVTable ||
        !api.fieldStaticGetValue || !api.objectUnbox) {
        fprintf(stderr,
            "#### APP-INPUT UNITY-NGUI phase=%s state=MONO-API-UNAVAILABLE\n",
            phase ? phase : "unknown");
        fflush(stderr);
        return;
    }

    void *domain = api.getRootDomain();
    if (!domain) return;
    (void)api.threadAttach(domain);
    void *assemblyName = api.assemblyNameNew("NGUI");
    void *assembly = assemblyName ? api.assemblyLoaded(assemblyName) : NULL;
    if (assemblyName) api.assemblyNameFree(assemblyName);
    void *image = assembly ? api.assemblyGetImage(assembly) : NULL;
    void *klass = image ? api.classFromName(image, "", "UICamera") : NULL;
    void *getFirst = klass
        ? api.classGetMethodFromName(klass, "get_first", 0) : NULL;
    void *exception = NULL;
    void *camera = getFirst
        ? api.runtimeInvoke(getFirst, NULL, NULL, &exception) : NULL;
    uint8_t useTouch = 0;
    uint8_t useMouse = 0;
    uint8_t useKeyboard = 0;
    if (camera && !exception) {
        void *field = api.classGetFieldFromName(klass, "useTouch");
        if (field) api.fieldGetValue(camera, field, &useTouch);
        field = api.classGetFieldFromName(klass, "useMouse");
        if (field) api.fieldGetValue(camera, field, &useMouse);
        field = api.classGetFieldFromName(klass, "useKeyboard");
        if (field) api.fieldGetValue(camera, field, &useKeyboard);
    }

    int32_t touchCount = -1;
    int32_t currentScheme = -1;
    void *getTouchCount = klass
        ? api.classGetMethodFromName(klass, "get_touchCount", 0) : NULL;
    exception = NULL;
    void *boxed = getTouchCount
        ? api.runtimeInvoke(getTouchCount, NULL, NULL, &exception) : NULL;
    if (boxed && !exception)
        memcpy(&touchCount, api.objectUnbox(boxed), sizeof(touchCount));
    void *getCurrentScheme = klass
        ? api.classGetMethodFromName(klass, "get_currentScheme", 0) : NULL;
    exception = NULL;
    boxed = getCurrentScheme
        ? api.runtimeInvoke(getCurrentScheme, NULL, NULL, &exception) : NULL;
    if (boxed && !exception)
        memcpy(&currentScheme, api.objectUnbox(boxed), sizeof(currentScheme));

    void *hover = NULL;
    void *vtable = klass ? api.classVTable(domain, klass) : NULL;
    void *hoverField = klass
        ? api.classGetFieldFromName(klass, "mHover") : NULL;
    if (vtable && hoverField)
        api.fieldStaticGetValue(vtable, hoverField, &hover);
    char *hoverText = NULL;
    if (hover && api.objectToString && api.stringToUTF8) {
        exception = NULL;
        void *description = api.objectToString(hover, &exception);
        if (description && !exception) hoverText = api.stringToUTF8(description);
    }
    fprintf(stderr,
        "#### APP-INPUT UNITY-NGUI phase=%s camera=%p "
        "useTouch=%u useMouse=%u useKeyboard=%u touchCount=%d "
        "scheme=%d hover=%p hoverName=%s\n",
        phase ? phase : "unknown", camera,
        useTouch, useMouse, useKeyboard, touchCount, currentScheme,
        hover, hoverText ? hoverText : "<nil>");
    fflush(stderr);

    // The loading overlay can remain visibly frozen even after the server
    // reports PlayerSpawnedInWorld. Read the exact state that
    // PlayerMoveController.updateRespawn drives: LocalPlayerUI.primaryUI ->
    // GUIWindowManager.IsWindowOpen(XUiC_LoadingScreen.ID). Also record the
    // underlying GUIWindow.isShowing and Unity Camera.enabled values. These
    // are getter/field witnesses only; no managed action or visibility value
    // is changed by this diagnostic.
    void *gameName = api.assemblyNameNew("Assembly-CSharp");
    void *gameAssembly = gameName ? api.assemblyLoaded(gameName) : NULL;
    if (gameName) api.assemblyNameFree(gameName);
    void *gameImage = gameAssembly
        ? api.assemblyGetImage(gameAssembly) : NULL;
    void *localPlayerClass = gameImage
        ? api.classFromName(gameImage, "", "LocalPlayerUI") : NULL;
    void *getPrimary = localPlayerClass
        ? api.classGetMethodFromName(
            localPlayerClass, "get_primaryUI", 0) : NULL;
    exception = NULL;
    void *primaryUI = getPrimary
        ? api.runtimeInvoke(getPrimary, NULL, NULL, &exception) : NULL;
    void *getWindowManager = localPlayerClass
        ? api.classGetMethodFromName(
            localPlayerClass, "get_windowManager", 0) : NULL;
    exception = NULL;
    void *windowManager = primaryUI && getWindowManager
        ? api.runtimeInvoke(
            getWindowManager, primaryUI, NULL, &exception) : NULL;
    void *loadingClass = gameImage
        ? api.classFromName(gameImage, "", "XUiC_LoadingScreen") : NULL;
    void *loadingVTable = loadingClass
        ? api.classVTable(domain, loadingClass) : NULL;
    void *loadingIDField = loadingClass
        ? api.classGetFieldFromName(loadingClass, "ID") : NULL;
    void *loadingID = NULL;
    if (loadingVTable && loadingIDField)
        api.fieldStaticGetValue(loadingVTable, loadingIDField, &loadingID);
    char *loadingIDText = loadingID && api.stringToUTF8
        ? api.stringToUTF8(loadingID) : NULL;
    void *windowManagerClass = gameImage
        ? api.classFromName(gameImage, "", "GUIWindowManager") : NULL;
    void *isWindowOpen = windowManagerClass
        ? api.classGetMethodFromName(
            windowManagerClass, "IsWindowOpen", 1) : NULL;
    void *loadingWindow = NULL;
    uint8_t loadingOpen = 0;
    if (windowManager && loadingID && isWindowOpen) {
        void *arguments[] = { loadingID };
        exception = NULL;
        boxed = api.runtimeInvoke(
            isWindowOpen, windowManager, arguments, &exception);
        if (boxed && !exception)
            memcpy(&loadingOpen, api.objectUnbox(boxed),
                   sizeof(loadingOpen));
        void *getWindow = api.classGetMethodFromName(
            windowManagerClass, "GetWindow", 1);
        exception = NULL;
        loadingWindow = getWindow
            ? api.runtimeInvoke(
                getWindow, windowManager, arguments, &exception) : NULL;
    }
    uint8_t loadingShowing = 0;
    void *guiWindowClass = gameImage
        ? api.classFromName(gameImage, "", "GUIWindow") : NULL;
    void *isShowingField = guiWindowClass
        ? api.classGetFieldFromName(guiWindowClass, "isShowing") : NULL;
    if (loadingWindow && isShowingField)
        api.fieldGetValue(loadingWindow, isShowingField, &loadingShowing);

    void *getCamera = localPlayerClass
        ? api.classGetMethodFromName(localPlayerClass, "get_camera", 0) : NULL;
    exception = NULL;
    void *playerCamera = primaryUI && getCamera
        ? api.runtimeInvoke(getCamera, primaryUI, NULL, &exception) : NULL;
    uint8_t cameraEnabled = 0;
    BOOL cameraEnabledRead = NO;
    void *coreName = api.assemblyNameNew("UnityEngine.CoreModule");
    void *coreAssembly = coreName ? api.assemblyLoaded(coreName) : NULL;
    if (coreName) api.assemblyNameFree(coreName);
    void *coreImage = coreAssembly
        ? api.assemblyGetImage(coreAssembly) : NULL;
    void *behaviourClass = coreImage
        ? api.classFromName(coreImage, "UnityEngine", "Behaviour") : NULL;
    void *getEnabled = behaviourClass
        ? api.classGetMethodFromName(behaviourClass, "get_enabled", 0) : NULL;
    if (playerCamera && getEnabled) {
        exception = NULL;
        boxed = api.runtimeInvoke(
            getEnabled, playerCamera, NULL, &exception);
        if (boxed && !exception) {
            memcpy(&cameraEnabled, api.objectUnbox(boxed),
                   sizeof(cameraEnabled));
            cameraEnabledRead = YES;
        }
    }
    fprintf(stderr,
        "#### APP-INPUT 7DTD-WORLD-STATE phase=%s primary=%p "
        "windowManager=%p loadingID=%s loadingWindow=%p "
        "open=%u showing=%u camera=%p enabled=%s\n",
        phase ? phase : "unknown", primaryUI, windowManager,
        loadingIDText ? loadingIDText : "<nil>", loadingWindow,
        loadingOpen, loadingShowing, playerCamera,
        cameraEnabledRead ? (cameraEnabled ? "YES" : "NO") : "UNREADABLE");
    fflush(stderr);
    if (loadingIDText && api.monoFree) api.monoFree(loadingIDText);
    if (hoverText && api.monoFree) api.monoFree(hoverText);
}

// Unity 2022.3.62f2 asks CGEventSourceFlagsState(1) while dispatching every
// AppKit event. That is normally equivalent to the modifierFlags carried by
// the NSEvent currently being dispatched. It is not equivalent in this
// launchd-created chroot session: a 7DTD sample captured all 2782/2782 main-
// thread samples in
//
//   UnityPlayer+0xf1de30 -> SLEventSourceFlagsState
//     -> CGSEventSourceForID -> CGSEventSourceShutdown -> mutex_lock
//
// RE-confirmed in the exact Ventura 13.4 SkyLight image: the failed source-ID
// lookup owns the event-source cache mutex when it calls Shutdown, which tries
// to acquire the same mutex again. Use the already-authoritative modifier
// flags from the real NSEvent only at the one RE-confirmed Unity call site.
// This does not invent a key state or suppress Unity's event handler; every
// other caller and every call outside the active AppKit dispatch reaches the
// original CoreGraphics implementation unchanged.
static uint64_t MacWSSevenDaysCGEventSourceFlagsState(int32_t stateID) {
    void *signedReturnAddress = __builtin_return_address(0);
    void *returnAddress = ptrauth_strip(signedReturnAddress,
                                        ptrauth_key_return_address);
    if (stateID == 1 && MacWSAppInputDispatchModifierDepth != 0 &&
        MacWSSevenDaysUnityImage &&
        (uintptr_t)returnAddress ==
            (uintptr_t)MacWSSevenDaysUnityImage + 0xf1de34u) {
        return MacWSAppInputDispatchModifierFlags;
    }
    return MacWSOriginalCGEventSourceFlagsState
        ? MacWSOriginalCGEventSourceFlagsState(stateID) : 0;
}

static BOOL MacWSMachHeaderHasUUID(const struct mach_header_64 *header,
                                   const uint8_t expected[16]) {
    if (!header || header->magic != MH_MAGIC_64) return NO;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(*header);
    const uint8_t *end = cursor + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (cursor + sizeof(struct load_command) > end) return NO;
        const struct load_command *command =
            (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            cursor + command->cmdsize > end) return NO;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            return memcmp(uuid->uuid, expected, 16) == 0;
        }
        cursor += command->cmdsize;
    }
    return NO;
}

static void MacWSInstallSevenDaysModifierStateCompatibility(void) {
    static _Atomic int installState;
    if (atomic_load_explicit(&installState, memory_order_acquire) == 2 ||
        !MacWSMainBundleIsSevenDaysToDie()) return;

    // Exact shipped arm64 UnityPlayer.dylib:
    // SHA-256 89ddca014c60f0a909e23fe87664f0c5ac70fe1889621a533c252cc8b6985e56
    // UUID D50F7C77-F422-3DE2-986B-1237215E50F7. The byte witness includes
    // the complete predicate and the BL whose return address is +0xf1de34.
    static const uint8_t expectedUUID[16] = {
        0xd5, 0x0f, 0x7c, 0x77, 0xf4, 0x22, 0x3d, 0xe2,
        0x98, 0x6b, 0x12, 0x37, 0x21, 0x5e, 0x50, 0xf7,
    };
    static const uint8_t expectedCallSite[] = {
        0xf4, 0x4f, 0xbe, 0xa9, 0xfd, 0x7b, 0x01, 0xa9,
        0xfd, 0x43, 0x00, 0x91, 0xf3, 0x03, 0x00, 0xaa,
        0xf4, 0x0f, 0x84, 0x52, 0x1f, 0x00, 0x14, 0x6a,
        0x61, 0x02, 0x00, 0x54, 0x20, 0x00, 0x80, 0x52,
        0x00, 0xf2, 0x1a, 0x94, 0x13, 0x00, 0x13, 0x2a,
    };

    const struct mach_header_64 *unityImage = NULL;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name || !strstr(name, "/UnityPlayer.dylib")) continue;
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(index);
        if (!MacWSMachHeaderHasUUID(header, expectedUUID) ||
            memcmp((const uint8_t *)header + 0xf1de10u,
                   expectedCallSite, sizeof(expectedCallSite)) != 0) {
            fprintf(stderr,
                "#### APP-INPUT 7DTD-MODIFIER-COMPAT unsupported-image "
                "path=%s\n", name);
            fflush(stderr);
            atomic_store_explicit(&installState, 3, memory_order_release);
            return;
        }
        unityImage = header;
        break;
    }
    if (!unityImage) return;

    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &installState, &expected, 1,
            memory_order_acq_rel, memory_order_acquire)) return;
    void *target = dlsym(RTLD_DEFAULT, "CGEventSourceFlagsState");
    if (!target) {
        atomic_store_explicit(&installState, 3, memory_order_release);
        return;
    }
    MSHookFunction(target, (void *)MacWSSevenDaysCGEventSourceFlagsState,
                   (void **)&MacWSOriginalCGEventSourceFlagsState);
    if (!MacWSOriginalCGEventSourceFlagsState) {
        atomic_store_explicit(&installState, 3, memory_order_release);
        return;
    }
    MacWSSevenDaysUnityImage = unityImage;
    atomic_store_explicit(&installState, 2, memory_order_release);
    fprintf(stderr,
        "#### APP-INPUT 7DTD-MODIFIER-COMPAT installed pid=%d "
        "unity=%p caller=0xf1de34 state=1 route=current-NSEvent\n",
        getpid(), unityImage);
    fflush(stderr);
}

static void MacWSInstallUnityDidSendEventDiagnostic(void) {
    static BOOL installed;
    if (installed || !MacWSRuntimeDiagnosticsEnabled() ||
        !MacWSMainBundleIsSevenDaysToDie()) return;
    Class delegateClass = objc_getClass("PlayerAppDelegate");
    Method method = delegateClass ? class_getInstanceMethod(
        delegateClass, sel_registerName("DidSendEvent:")) : NULL;
    if (!method) return;
    IMP implementation = method_getImplementation(method);
    if (implementation != (IMP)MacWSUnityDidSendEventDiagnostic) {
        MacWSOriginalUnityDidSendEvent =
            (MacWSUnityDidSendEvent)implementation;
        method_setImplementation(
            method, (IMP)MacWSUnityDidSendEventDiagnostic);
    }
    installed = YES;
    fprintf(stderr,
        "#### APP-INPUT UNITY-DID-SEND-INSTALL pid=%d class=%s\n",
        getpid(), class_getName(delegateClass));
    fflush(stderr);
}

// Boundary between CoreGraphics' event queue and the target AppKit main
// thread. Besides timing witnesses, this restores the double-click field on
// the exact native down/up pair matched above; every unrelated event passes
// through byte-for-byte unchanged.
static void MacWSAppInputApplicationSendEvent(id self, SEL command, id event) {
    MacWSInstallSevenDaysModifierStateCompatibility();
    MacWSInstallUnityDidSendEventDiagnostic();
    NSUInteger type = event ? ((MacWSMsgUInteger)objc_msgSend)(
        event, sel_registerName("type")) : 0;
    if ((type == 10 || type == 11) &&
        MacWSKeyboardLatencyDiagnosticsEnabled()) {
        double now = MacWSInputUptimeSeconds();
        double eventProducedAt = ((MacWSMsgDouble)objc_msgSend)(
            event, sel_registerName("timestamp"));
        NSInteger keyCode = ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("keyCode"));
        MacWSKeyboardCGSTraceSample correlated = {0};
        BOOL hasCorrelatedSample = keyCode >= 0 && keyCode <= UINT16_MAX &&
            MacWSConsumeKeyboardCGSTraceSample(
                (uint16_t)type, (uint16_t)keyCode, now, &correlated);
        double producedAt = hasCorrelatedSample
            ? correlated.producedAt : eventProducedAt;
        double postToApp = hasCorrelatedSample && correlated.postedAt > 0.0 &&
            now >= correlated.postedAt
            ? (now - correlated.postedAt) * 1000.0 : -1.0;
        fprintf(stderr,
            "#### APP-INPUT KEYBOARD-LATENCY stage=app-dispatch pid=%d "
            "sample=%u kind=%s keycode=%ld producer-to-app=%.3fms "
            "post-to-app=%.3fms event=%.6f app=%.6f route=%s\n",
            getpid(), hasCorrelatedSample ? correlated.sampleSequence : 0,
            type == 10 ? "down" : "up", (long)keyCode,
            producedAt > 0.0 && now >= producedAt
                ? (now - producedAt) * 1000.0 : -1.0,
            postToApp, eventProducedAt, now,
            hasCorrelatedSample ? "cgs-correlated" : "uncorrelated");
        fflush(stderr);
        MacWSKeyboardLatencyTrace(
            "stage=app-dispatch pid=%d sample=%u kind=%s keycode=%ld "
            "producer-to-app=%.3fms post-to-app=%.3fms event=%.6f "
            "app=%.6f route=%s\n",
            getpid(), hasCorrelatedSample ? correlated.sampleSequence : 0,
            type == 10 ? "down" : "up", (long)keyCode,
            producedAt > 0.0 && now >= producedAt
                ? (now - producedAt) * 1000.0 : -1.0,
            postToApp, eventProducedAt, now,
            hasCorrelatedSample ? "cgs-correlated" : "uncorrelated");
    }
    if (type == 1 && MacWSRuntimeDiagnosticsEnabled() &&
        MacWSMainBundleIsSevenDaysToDie()) {
        uint64_t untilMicros = (uint64_t)(
            (MacWSAppInputMonotonicSeconds() + 1.0) * 1000000.0);
        atomic_store_explicit(&MacWSUnityMouseDiagnosticSequence, 0,
                              memory_order_release);
        atomic_store_explicit(&MacWSUnityMouseDiagnosticUntilMicros,
                              untilMicros, memory_order_release);
    }
    BOOL processLocalMouseEvent = event && type >= 1 && type <= 7 &&
        MacWSIsProcessLocalMouseEvent(event);
    // leftMouseDragged/rightMouseDragged already encode which hardware button
    // must be held.  Ventura's AppKit queue preserves that NSEvent type but,
    // in this launchd-created chroot session, its global button mask remains
    // zero after a process-local mouseDown handler returns.  Restore the
    // invariant for the duration of the dragged-event dispatch itself; a real
    // hardware drag already has the same bit and is therefore unchanged.
    BOOL draggedMouseEvent = type == 6 || type == 7;
    // Finder's file drag image and AppKit's movable utility panels are
    // separate SkyLight windows. They can move without posting an
    // NSWindowDidMove notification through the public notification center.
    // Runtime-confirmed with display diagnostics on 2026-09-10: Finder
    // dispatched 44 consecutive type=6 events, while displayd received no
    // workspace-geometry-burst during the same interval. Remember the native
    // drag lifecycle on AppKit's event boundary so the first consumed drag
    // discovers its real CGWindow and later samples read its authoritative
    // presentation rectangle. This does not synthesize window geometry.
    static BOOL leftDragPresentationAnnounced;
    static BOOL rightDragPresentationAnnounced;
    if (type == 1) leftDragPresentationAnnounced = NO;
    if (type == 3) rightDragPresentationAnnounced = NO;
    BOOL firstPresentedDrag =
        (type == 6 && !leftDragPresentationAnnounced) ||
        (type == 7 && !rightDragPresentationAnnounced);
    if (type == 6) leftDragPresentationAnnounced = YES;
    if (type == 7) rightDragPresentationAnnounced = YES;
    BOOL completedPresentedDrag =
        (type == 2 && leftDragPresentationAnnounced) ||
        (type == 4 && rightDragPresentationAnnounced);
    BOOL matchedSystemDoubleClick = NO;
    event = MacWSRestorePendingSystemDoubleClick(
        event, type, &matchedSystemDoubleClick);
    MacWSSystemInputLatencyMarker systemLatencyMarker = {0};
    double systemLatencyMainStart = 0.0;
    if (type == 1 || type == 3) {
        NSInteger eventWindow = ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("windowNumber"));
        if (eventWindow > 0 && eventWindow <= UINT32_MAX &&
            MacWSConsumeSystemInputLatencyMarker(
                (uint32_t)eventWindow, &systemLatencyMarker)) {
            systemLatencyMainStart = MacWSInputUptimeSeconds();
        }
    }
    // A process-local NSEvent does not update WindowServer's global button
    // mask.  The synthetic-gesture bridge therefore owns that mask while the
    // event is dispatched, but it must still make the same transition as a
    // hardware stream.  Runtime-confirmed in VSCode's real
    // NSMenuWindowManagerWindow: the routed mouseUp reached the correct menu
    // container at local=(88,160), while +[NSEvent pressedMouseButtons]
    // remained 0x1.  AppKit consequently kept the item in its pressed
    // tracking state and neither selected nor dismissed it.  Reflect the
    // individual event before AppKit observes it; restore the outer tracker
    // state after sendEvent: returns so a mouseDown that entered a nested
    // tracker still sees the button held for that tracker's lifetime.
    NSUInteger savedSyntheticButtons = MacWSAppInputRFBTrackingButtons;
    BOOL savedSyntheticActive = MacWSAppInputRFBTrackingActive;
    // The atomic legacy poster queues up before this process can leave the
    // AppInput callback and dispatch down on its main thread. WindowServer's
    // global button mask is therefore already clear here (runtime Finder
    // witness: native second mouseDown clicks=2, pressed=0). Scope the existing
    // state bridge to the exactly matched second-click pair so Finder sees the
    // hardware invariant pressed=1 while dispatching down and pressed=0 while
    // dispatching up. A nested tracker can consume the already-queued up; the
    // reentrant save/restore below preserves the outer down state correctly.
    if (matchedSystemDoubleClick || processLocalMouseEvent ||
        draggedMouseEvent)
        MacWSAppInputRFBTrackingActive = YES;
    BOOL transitionedSyntheticButtons = MacWSAppInputRFBTrackingActive;
    if (transitionedSyntheticButtons) {
        if (type == 1 || type == 6)
            MacWSAppInputRFBTrackingButtons |= 1u;
        else if (type == 2) MacWSAppInputRFBTrackingButtons &= ~1u;
        else if (type == 3 || type == 7)
            MacWSAppInputRFBTrackingButtons |= 2u;
        else if (type == 4) MacWSAppInputRFBTrackingButtons &= ~2u;
    }
    uint64_t serial = 0;
    double started = 0.0;
    uint64_t mouseSerial = 0;
    double mouseStarted = 0.0;
    BOOL logMouseReturn = NO;
    id keyWindow = nil;
    id responder = nil;
    if ((type == 10 || type == 11) &&
        MacWSRuntimeDiagnosticsEnabled()) { // NSEventTypeKeyDown / KeyUp
        static _Atomic uint64_t keyEvents;
        serial = atomic_fetch_add_explicit(
            &keyEvents, 1, memory_order_relaxed) + 1;
        started = MacWSAppInputMonotonicSeconds();
        keyWindow = ((MacWSMsgID)objc_msgSend)(
            self, sel_registerName("keyWindow"));
        responder = keyWindow ? ((MacWSMsgID)objc_msgSend)(
            keyWindow, sel_registerName("firstResponder")) : nil;
        if (serial <= 48) {
            NSInteger keyCode = ((MacWSMsgInteger)objc_msgSend)(
                event, sel_registerName("keyCode"));
            id characters = ((MacWSMsgID)objc_msgSend)(
                event, sel_registerName("characters"));
            const char *utf8 = characters
                ? ((const char *(*)(id, SEL))objc_msgSend)(
                    characters, sel_registerName("UTF8String")) : NULL;
            fprintf(stderr,
                "#### APP-INPUT KEY-EVENT pid=%d serial=%llu type=%lu "
                "keycode=%ld chars=%s active=%s window=%ld responder=%s "
                "at=%.6f\n",
                getpid(), (unsigned long long)serial, (unsigned long)type,
                (long)keyCode, utf8 ?: "(null)",
                ((MacWSMsgBool)objc_msgSend)(
                    self, sel_registerName("isActive")) ? "YES" : "NO",
                keyWindow ? (long)((MacWSMsgInteger)objc_msgSend)(
                    keyWindow, sel_registerName("windowNumber")) : -1L,
                responder ? object_getClassName(responder) : "(null)",
                started);
            fflush(stderr);
        }
    } else if (type >= 1 && type <= 7 &&
               MacWSRuntimeDiagnosticsEnabled()) {
        // Observational boundary witness for the native-VNC A/B.  These are
        // the ordinary AppKit mouse event types (left/right down/up, moved,
        // left/right dragged).  Logging their real window/location/button
        // state proves whether CGPostMouseEvent delivered a coherent stream;
        // this hook never creates, changes, or suppresses an event.
        static _Atomic uint64_t mouseEvents;
        mouseSerial = atomic_fetch_add_explicit(
            &mouseEvents, 1, memory_order_relaxed) + 1;
        mouseStarted = MacWSAppInputMonotonicSeconds();
        logMouseReturn = mouseSerial <= 128 || (mouseSerial % 600) == 0;
        if (logMouseReturn) {
            NSInteger windowNumber = ((MacWSMsgInteger)objc_msgSend)(
                event, sel_registerName("windowNumber"));
            NSInteger clickCount = ((MacWSMsgInteger)objc_msgSend)(
                event, sel_registerName("clickCount"));
            CGPoint location = ((MacWSMsgPoint)objc_msgSend)(
                event, sel_registerName("locationInWindow"));
            Class eventClass = object_getClass(event);
            NSUInteger pressed = eventClass
                ? ((MacWSPressedMouseButtons)objc_msgSend)(
                    (id)eventClass, sel_registerName("pressedMouseButtons"))
                : 0;
            fprintf(stderr,
                "#### APP-INPUT MOUSE-EVENT pid=%d serial=%llu type=%lu "
                "window=%ld clicks=%ld local=(%.2f,%.2f) pressed=%#lx "
                "at=%.6f\n",
                getpid(), (unsigned long long)mouseSerial,
                (unsigned long)type, (long)windowNumber,
                (long)clickCount,
                location.x, location.y, (unsigned long)pressed,
                mouseStarted);
            fflush(stderr);
        }
    }
    // Runtime-confirmed on a freshly launchd-started Terminal in coexist mode:
    // native CGPostMouseEvent delivered left down/up to the real window
    // (window=48), yet NSApplication.isActive stayed NO and target probes kept
    // returning Hit-only flags=0x1.  The title controls remained inactive and
    // the global menu bar had no owner.  Normal AppKit activates the receiving
    // application before dispatching a primary click; restore that lifecycle
    // transition through the public API only after a real window-targeted
    // native down has arrived in this process.
    if (type == 1) {
        NSInteger eventWindow = ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("windowNumber"));
        BOOL active = ((MacWSMsgBool)objc_msgSend)(
            self, sel_registerName("isActive"));
        SEL activateSelector = sel_registerName("activateIgnoringOtherApps:");
        if (eventWindow > 0 && !active &&
            ((MacWSMsgBoolSEL)objc_msgSend)(
                self, sel_registerName("respondsToSelector:"),
                activateSelector)) {
            ((MacWSMsgVoidBool)objc_msgSend)(
                self, activateSelector, YES);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT SYSTEM-ACTIVATE pid=%d window=%ld "
                    "active-before=NO active-after=%s\n",
                    getpid(), (long)eventWindow,
                    ((MacWSMsgBool)objc_msgSend)(
                        self, sel_registerName("isActive")) ? "YES" : "NO");
                fflush(stderr);
            }
        }
    }
    // Commit the location carried by every mouse NSEvent that AppKit actually
    // dispatches. Hardware WindowServer input ordinarily makes
    // +[NSEvent mouseLocation] agree before this boundary, while both of our
    // permitted synthetic routes can leave that global state stale. Runtime-
    // confirmed in 7DTD PID 79009: a Host CG mouse-down arrived at local
    // (57,193), then Unity's next +mouseLocation poll still returned the prior
    // control's screen point (613,346.5). Deriving this value from the received
    // event also lets a later real mouse event replace the synthetic position;
    // it does not pin a bridge-only coordinate indefinitely.
    CGPoint deliveredMouseLocation = {0.0, 0.0};
    BOOL hasDeliveredMouseLocation = NO;
    if (type >= 1 && type <= 7 && event) {
        id deliveredWindow = ((MacWSMsgID)objc_msgSend)(
            event, sel_registerName("window"));
        CGPoint deliveredLocal = ((MacWSMsgPoint)objc_msgSend)(
            event, sel_registerName("locationInWindow"));
        deliveredMouseLocation = deliveredWindow
            ? ((MacWSMsgPointPoint)objc_msgSend)(
                deliveredWindow, sel_registerName("convertPointToScreen:"),
                deliveredLocal)
            : deliveredLocal;
        if (isfinite(deliveredMouseLocation.x) &&
            isfinite(deliveredMouseLocation.y)) {
            MacWSAppInputPersistentMouseLocation = deliveredMouseLocation;
            MacWSAppInputPersistentMouseLocationValid = YES;
            hasDeliveredMouseLocation = YES;
        }
    }

    // A permitted hardware CGEvent also updates the pressed-button mask.
    // Our process-local route restores that invariant above, but AppKit's
    // synchronous title/toolbar trackers additionally consult the class-level
    // pointer property while the callback is still active. Keep a transient
    // value for that interval; the committed value above serves later polls.
    BOOL bridgeMouseLocation = type >= 1 && type <= 7 &&
        MacWSAppInputRFBTrackingActive;
    BOOL previousMouseLocationActive = MacWSAppInputMouseLocationActive;
    CGPoint previousMouseLocation = MacWSAppInputMouseLocation;
    CGPoint bridgedMouseLocation = {0.0, 0.0};
    CGPoint originalMouseLocation = {0.0, 0.0};
    BOOL hasBridgedMouseLocation = NO;
    if (bridgeMouseLocation && hasDeliveredMouseLocation) {
        {
            bridgedMouseLocation = deliveredMouseLocation;
            Class eventClass = object_getClass(event);
            originalMouseLocation = MacWSOriginalMouseLocation && eventClass
                ? MacWSOriginalMouseLocation(
                    (id)eventClass, sel_registerName("mouseLocation"))
                : (CGPoint){0.0, 0.0};
            MacWSAppInputMouseLocation = bridgedMouseLocation;
            MacWSAppInputMouseLocationActive = YES;
            hasBridgedMouseLocation = YES;
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT MOUSE-LOCATION pid=%d type=%lu "
                    "original=(%.2f,%.2f) event=(%.2f,%.2f)\n",
                    getpid(), (unsigned long)type,
                    originalMouseLocation.x, originalMouseLocation.y,
                    bridgedMouseLocation.x, bridgedMouseLocation.y);
                fflush(stderr);
            }
        }
    }
    uint64_t previousDispatchModifierFlags =
        MacWSAppInputDispatchModifierFlags;
    unsigned previousDispatchModifierDepth =
        MacWSAppInputDispatchModifierDepth;
    if (event && MacWSMainBundleIsSevenDaysToDie()) {
        MacWSAppInputDispatchModifierFlags =
            ((MacWSMsgUInteger)objc_msgSend)(
                event, sel_registerName("modifierFlags"));
        MacWSAppInputDispatchModifierDepth =
            previousDispatchModifierDepth + 1;
    }
    if (MacWSOriginalApplicationSendEvent)
        MacWSOriginalApplicationSendEvent(self, command, event);
    // Unity's custom AppKit loop continues to enter -[NSApplication
    // sendEvent:] even when its main dispatch queue stops running recovery
    // timers. Re-read the exact PlayerWindowView cursor property after the
    // real event has been handled: the click/key which enters or leaves an
    // in-world camera can change Cursor.visible during that dispatch.  A
    // generation mismatch causes one synchronous metrics publication; steady
    // mouse motion does not enumerate windows or write a sidecar per event.
    id relativeEventWindow = event ? ((MacWSMsgID)objc_msgSend)(
        event, sel_registerName("window")) : nil;
    if (!relativeEventWindow) {
        relativeEventWindow = ((MacWSMsgID)objc_msgSend)(
            self, sel_registerName("keyWindow"));
    }
    MacWSReconcileUnityCursorState(relativeEventWindow);
    uint64_t relativeRequestGeneration = atomic_load_explicit(
        &MacWSRelativePointerRequestGeneration, memory_order_acquire);
    uint64_t relativePublishedGeneration = atomic_load_explicit(
        &MacWSRelativePointerPublishedGeneration, memory_order_acquire);
    if (relativeRequestGeneration != relativePublishedGeneration)
        MacWSPublishWindowMetrics();
    MacWSAppInputDispatchModifierFlags = previousDispatchModifierFlags;
    MacWSAppInputDispatchModifierDepth = previousDispatchModifierDepth;
    if (systemLatencyMainStart > 0.0) {
        double dispatchEnd = MacWSInputUptimeSeconds();
        MacWSInputRecord latencyRecord = {
            .kind = systemLatencyMarker.kind,
            .sampleSequence = systemLatencyMarker.sampleSequence,
        };
        MacWSAppendOneShotInputLatency(
            latencyRecord,
            fmax(0.0, (systemLatencyMainStart -
                       systemLatencyMarker.producerTimestamp) * 1.0e6),
            fmax(0.0, (systemLatencyMarker.posterReceiptTimestamp -
                       systemLatencyMarker.producerTimestamp) * 1.0e6),
            fmax(0.0, (systemLatencyMainStart -
                       systemLatencyMarker.posterReceiptTimestamp) * 1.0e6),
            fmax(0.0, (dispatchEnd - systemLatencyMainStart) * 1.0e6));
    }
    if (hasBridgedMouseLocation) {
        MacWSAppInputMouseLocation = previousMouseLocation;
        MacWSAppInputMouseLocationActive = previousMouseLocationActive;
    }
    if (draggedMouseEvent) {
        if (firstPresentedDrag)
            MacWSNotifyDisplayCatalogChanged('d');
        MacWSNotifyDisplayCatalogChanged('g');
    } else if (completedPresentedDrag) {
        // The semantic completion edge performs the conservative two-sample
        // retirement used by menus and other transient AppKit windows.
        MacWSNotifyDisplayCatalogChanged('t');
    }
    if (type == 2) leftDragPresentationAnnounced = NO;
    if (type == 4) rightDragPresentationAnnounced = NO;
    if (transitionedSyntheticButtons)
        MacWSAppInputRFBTrackingButtons = savedSyntheticButtons;
    if (matchedSystemDoubleClick || processLocalMouseEvent ||
        draggedMouseEvent)
        MacWSAppInputRFBTrackingActive = savedSyntheticActive;
    if (logMouseReturn) {
        double finished = MacWSAppInputMonotonicSeconds();
        Class eventClass = object_getClass(event);
        NSUInteger pressed = eventClass
            ? ((MacWSPressedMouseButtons)objc_msgSend)(
                (id)eventClass, sel_registerName("pressedMouseButtons"))
            : 0;
        fprintf(stderr,
            "#### APP-INPUT MOUSE-RETURN pid=%d serial=%llu type=%lu "
            "pressed=%#lx elapsed=%.3fms at=%.6f\n",
            getpid(), (unsigned long long)mouseSerial,
            (unsigned long)type, (unsigned long)pressed,
            (finished - mouseStarted) * 1000.0, finished);
        fflush(stderr);
    }
    if (type == 11 && MacWSApplicationDisplaySettleMilliseconds != 0 &&
        event && ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("keyCode")) == 36) {
        // macOS virtual keycode 36 is Return.  This is the only transition
        // whose fast pty-output race the bounded settle was introduced for;
        // typed characters already produce their own native TTView commits.
        MacWSScheduleApplicationDisplaySettle();
    }
    if (serial != 0 && serial <= 48) {
        double finished = MacWSAppInputMonotonicSeconds();
        BOOL hasString = responder && ((MacWSMsgBoolSEL)objc_msgSend)(
            responder, sel_registerName("respondsToSelector:"),
            sel_registerName("string"));
        id string = hasString ? ((MacWSMsgID)objc_msgSend)(
            responder, sel_registerName("string")) : nil;
        NSUInteger length = string ? ((MacWSMsgUInteger)objc_msgSend)(
            string, sel_registerName("length")) : 0;
        fprintf(stderr,
            "#### APP-INPUT KEY-RETURN pid=%d serial=%llu elapsed=%.3fms "
            "active=%s responder=%s has-string=%s length=%lu\n",
            getpid(), (unsigned long long)serial,
            (finished - started) * 1000.0,
            ((MacWSMsgBool)objc_msgSend)(
                self, sel_registerName("isActive")) ? "YES" : "NO",
            responder ? object_getClassName(responder) : "(null)",
            hasString ? "YES" : "NO", (unsigned long)length);
        fflush(stderr);
    }
}

static void MacWSInstallApplicationKeyWitness(void) {
    const char *settleValue = getenv("MACWS_APP_DISPLAY_SETTLE_MS");
    if (settleValue && *settleValue) {
        char *settleEnd = NULL;
        errno = 0;
        unsigned long settleMilliseconds = strtoul(
            settleValue, &settleEnd, 10);
        if (errno != 0 || settleEnd == settleValue || *settleEnd != '\0' ||
            settleMilliseconds < 16 || settleMilliseconds > 2000) {
            fprintf(stderr,
                "#### APP-INPUT DISPLAY-SETTLE disabled invalid "
                "MACWS_APP_DISPLAY_SETTLE_MS='%s' (valid=16..2000)\n",
                settleValue);
            fflush(stderr);
        } else {
            MacWSApplicationDisplaySettleMilliseconds =
                (uint32_t)settleMilliseconds;
        }
    }
    // This constructor runs while dyld is still executing initializers.
    // NSClassFromString builds an NSString and entered Foundation before its
    // ObjC initialization was complete on arm64e (runtime crash witness:
    // Terminal-2026-07-28-021535.ips, NSClassFromString+52). The ObjC runtime
    // lookup takes a plain C string and is already used by the bridge's event
    // path for these AppKit classes.
    Class applicationClass = objc_getClass("NSApplication");
    Method method = applicationClass ? class_getInstanceMethod(
        applicationClass, sel_registerName("sendEvent:")) : NULL;
    if (method) {
        IMP implementation = method_getImplementation(method);
        if (implementation != (IMP)MacWSAppInputApplicationSendEvent) {
            MacWSOriginalApplicationSendEvent = (MacWSSendEvent)implementation;
            method_setImplementation(method,
                (IMP)MacWSAppInputApplicationSendEvent);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT KEY-WITNESS installed "
                    "-[NSApplication sendEvent:] display-settle=%ums "
                    "(diagnostic scaffold)\n",
                    MacWSApplicationDisplaySettleMilliseconds);
                fflush(stderr);
            }
        }
    }
    Method activationMethod = applicationClass ? class_getInstanceMethod(
        applicationClass,
        sel_registerName("_handleActivatedEvent:")) : NULL;
    if (activationMethod) {
        IMP implementation = method_getImplementation(activationMethod);
        if (implementation != (IMP)MacWSAppInputHandleActivatedEvent) {
            MacWSOriginalHandleActivatedEvent =
                (MacWSHandleApplicationEvent)implementation;
            method_setImplementation(activationMethod,
                (IMP)MacWSAppInputHandleActivatedEvent);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT ACTIVATION-WITNESS installed "
                    "-[NSApplication _handleActivatedEvent:]\n");
                fflush(stderr);
            }
        }
    }
}

// Electron injects libmachook before AppKit has necessarily realized
// NSApplication.  The constructor's immediate lookup can therefore miss the
// observational sendEvent witness even though the same process later creates
// native menus. Retry only on the main queue, with a finite five-second
// window; the bridge's socket/event delivery does not depend on this witness.
static void MacWSScheduleApplicationKeyWitnessInstall(unsigned attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        MacWSInstallApplicationKeyWitness();
        if ((!MacWSOriginalApplicationSendEvent ||
             !MacWSOriginalHandleActivatedEvent) && attempt < 19)
            MacWSScheduleApplicationKeyWitnessInstall(attempt + 1);
    });
}

static void MacWSSetAppInputGestureWindow(id window) {
    CFTypeRef replacement = window
        ? CFRetain((__bridge CFTypeRef)window) : NULL;
    CFTypeRef previous = MacWSAppInputGestureWindow;
    MacWSAppInputGestureWindow = replacement;
    if (previous) CFRelease(previous);
    if (!window) {
        CFTypeRef previousBase = MacWSAppInputGestureBaseWindow;
        MacWSAppInputGestureBaseWindow = NULL;
        MacWSAppInputGestureBaseWindowNumber = 0;
        if (previousBase) CFRelease(previousBase);
    }
}

static void MacWSSetAppInputGestureRoute(id baseWindow, id targetWindow,
                                         uint32_t baseWindowNumber) {
    CFTypeRef replacementBase = baseWindow
        ? CFRetain((__bridge CFTypeRef)baseWindow) : NULL;
    CFTypeRef previousBase = MacWSAppInputGestureBaseWindow;
    MacWSAppInputGestureBaseWindow = replacementBase;
    MacWSAppInputGestureBaseWindowNumber = replacementBase
        ? baseWindowNumber : 0;
    if (previousBase) CFRelease(previousBase);
    MacWSSetAppInputGestureWindow(targetWindow);
}

static void MacWSEndAppInputScrollSession(void) {
    id window = (__bridge id)MacWSAppInputScrollSessionWindow;
    MacWSAppInputScrollSessionGeneration++;
    if (window) {
        SEL didEnd = sel_registerName("_didEndViewScrolling");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"), didEnd)) {
            ((MacWSMsgVoid)objc_msgSend)(window, didEnd);
        }
    }
    CFTypeRef previous = MacWSAppInputScrollSessionWindow;
    MacWSAppInputScrollSessionWindow = NULL;
    if (previous) CFRelease(previous);
}

static void MacWSBeginAppInputScrollSession(id window) {
    if ((__bridge id)MacWSAppInputScrollSessionWindow != window)
        MacWSEndAppInputScrollSession();
    if (!MacWSAppInputScrollSessionWindow) {
        MacWSAppInputScrollSessionWindow = window
            ? CFRetain((__bridge CFTypeRef)window) : NULL;
        SEL willBegin = sel_registerName("_willBeginViewScrolling");
        if (window && ((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"), willBegin)) {
            ((MacWSMsgVoid)objc_msgSend)(window, willBegin);
        }
    }
    MacWSAppInputScrollSessionGeneration++;
}

static void MacWSScheduleAppInputScrollSessionTimeout(id window) {
    uint64_t generation = MacWSAppInputScrollSessionGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (MacWSAppInputScrollSessionGeneration == generation &&
            (__bridge id)MacWSAppInputScrollSessionWindow == window) {
            MacWSEndAppInputScrollSession();
        }
    });
}

static void MacWSSetAppInputGestureHitView(id view) {
    CFTypeRef replacement = view
        ? CFRetain((__bridge CFTypeRef)view) : NULL;
    CFTypeRef previous = MacWSAppInputGestureHitView;
    MacWSAppInputGestureHitView = replacement;
    MacWSAppInputGestureHitHasValue = view &&
        [view respondsToSelector:sel_registerName("doubleValue")];
    MacWSAppInputGestureHitValueBefore = MacWSAppInputGestureHitHasValue
        ? ((MacWSMsgDouble)objc_msgSend)(view, sel_registerName("doubleValue"))
        : 0.0;
    if (previous) CFRelease(previous);
}

static void MacWSLogAppInputGestureHitResult(const char *phase,
                                             uint32_t gesture) {
    if (!MacWSRuntimeDiagnosticsEnabled() &&
        gesture != MACWS_INPUT_CONTACT_DIAGNOSTIC) return;
    id view = (__bridge id)MacWSAppInputGestureHitView;
    if (!view) return;
    BOOL enabled = ![view respondsToSelector:sel_registerName("isEnabled")] ||
        ((MacWSMsgBool)objc_msgSend)(view, sel_registerName("isEnabled"));
    double after = MacWSAppInputGestureHitHasValue
        ? ((MacWSMsgDouble)objc_msgSend)(view, sel_registerName("doubleValue"))
        : 0.0;
    fprintf(stderr,
        "#### APP-INPUT CONTROL-RESULT pid=%d gesture=%u phase=%s "
        "view=%s enabled=%s has-value=%s before=%.6f after=%.6f\n",
        getpid(), gesture, phase, object_getClassName(view),
        enabled ? "YES" : "NO",
        MacWSAppInputGestureHitHasValue ? "YES" : "NO",
        MacWSAppInputGestureHitValueBefore, after);
    fflush(stderr);
    MacWSSetAppInputGestureHitView(nil);
}

static void MacWSSetDeferredRFBDownEvent(id event) {
    CFTypeRef replacement = event
        ? CFRetain((__bridge CFTypeRef)event) : NULL;
    CFTypeRef previous = MacWSAppInputDeferredRFBDownEvent;
    MacWSAppInputDeferredRFBDownEvent = replacement;
    if (previous) CFRelease(previous);
}

static void MacWSClearDeferredRFBMoveEvents(void) {
    [MacWSAppInputDeferredRFBMoveEvents removeAllObjects];
}

static NSInteger MacWSNextAppInputEventNumber(void) {
    return __sync_add_and_fetch(&MacWSAppInputEventNumber, 1);
}

static void MacWSMarkProcessLocalMouseEvent(id event) {
    if (!event) return;
    objc_setAssociatedObject(
        event, &MacWSProcessLocalMouseEventAssociationKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SEL cgEventSelector = sel_registerName("CGEvent");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            event, sel_registerName("respondsToSelector:"),
            cgEventSelector)) return;
    MacWSCGEventRef cgEvent = ((MacWSEventRef)objc_msgSend)(
        event, cgEventSelector);
    if (!cgEvent) return;
    static MacWSSetCGEventIntegerField setInteger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
    });
    if (setInteger) {
        setInteger(cgEvent, 42 /* kCGEventSourceUserData */,
                   INT64_C(0x4d57534c4f43414c)); // "MWSLOCAL"
    }
}

static BOOL MacWSIsProcessLocalMouseEvent(id event) {
    if (!event) return NO;
    if (objc_getAssociatedObject(
            event, &MacWSProcessLocalMouseEventAssociationKey) != nil)
        return YES;
    SEL cgEventSelector = sel_registerName("CGEvent");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            event, sel_registerName("respondsToSelector:"),
            cgEventSelector)) return NO;
    MacWSCGEventRef cgEvent = ((MacWSEventRef)objc_msgSend)(
        event, cgEventSelector);
    if (!cgEvent) return NO;
    static MacWSGetCGEventIntegerField getInteger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        getInteger = (MacWSGetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventGetIntegerValueField");
    });
    return getInteger &&
        getInteger(cgEvent, 42 /* kCGEventSourceUserData */) ==
            INT64_C(0x4d57534c4f43414c);
}

// MacWSAppInputRouteLock must be held by the caller.
static void MacWSClearDirectTrackingContextLocked(void) {
    MacWSAppInputDirectContext.accepting = NO;
    if (MacWSAppInputDirectContext.application) {
        CFRelease(MacWSAppInputDirectContext.application);
        MacWSAppInputDirectContext.application = NULL;
    }
    MacWSAppInputDirectContext.contactID = 0;
    MacWSAppInputDirectContext.sceneID = 0;
    MacWSAppInputDirectContext.windowNumber = 0;
    MacWSAppInputDirectContext.screenFrame = (CGRect){0};
    MacWSAppInputDirectContext.windowMinusScreen = (CGPoint){0};
    MacWSAppInputDirectContext.eventClass = Nil;
}

// MacWSAppInputRouteLock must be held by the caller.
static void MacWSArmDirectTrackingContextLocked(id application,
                                                Class eventClass,
                                                uint64_t sceneID,
                                                uint32_t contactID,
                                                NSInteger windowNumber,
                                                CGRect screenFrame,
                                                CGPoint screenPoint,
                                                CGPoint windowPoint) {
    MacWSClearDirectTrackingContextLocked();
    MacWSAppInputDirectContext.accepting = YES;
    MacWSAppInputDirectContext.contactID = contactID;
    MacWSAppInputDirectContext.sceneID = sceneID;
    MacWSAppInputDirectContext.windowNumber = windowNumber;
    MacWSAppInputDirectContext.screenFrame = screenFrame;
    MacWSAppInputDirectContext.windowMinusScreen = (CGPoint){
        windowPoint.x - screenPoint.x,
        windowPoint.y - screenPoint.y,
    };
    MacWSAppInputDirectContext.eventClass = eventClass;
    MacWSAppInputDirectContext.application = application
        ? CFRetain((__bridge CFTypeRef)application) : NULL;
}

// MacWSAppInputRouteLock must be held by the caller.
static void MacWSClearDirectGestureContextLocked(void) {
    if (MacWSAppInputDirectGestureContext.application) {
        CFRelease(MacWSAppInputDirectGestureContext.application);
        MacWSAppInputDirectGestureContext.application = NULL;
    }
    if (MacWSAppInputDirectGestureContext.window) {
        CFRelease(MacWSAppInputDirectGestureContext.window);
        MacWSAppInputDirectGestureContext.window = NULL;
    }
    MacWSAppInputDirectGestureContext.prepared = NO;
    MacWSAppInputDirectGestureContext.accepting = NO;
    MacWSAppInputDirectGestureContext.terminalQueued = NO;
    MacWSAppInputDirectGestureContext.kind = 0;
    MacWSAppInputDirectGestureContext.contactID = 0;
    MacWSAppInputDirectGestureContext.targetWindowID = 0;
    MacWSAppInputDirectGestureContext.sceneID = 0;
    MacWSAppInputDirectGestureContext.windowNumber = 0;
    MacWSAppInputDirectGestureContext.mappingFrame = (CGRect){0};
    MacWSAppInputDirectGestureContext.screenFrame = (CGRect){0};
    MacWSAppInputDirectGestureContext.windowMinusScreen = (CGPoint){0};
    MacWSAppInputDirectGestureContext.eventClass = Nil;
}

// Prepare only the immutable route.  The NSEvent tracking-loop hook below
// changes accepting to YES at the actual AppKit lifecycle boundary.
// MacWSAppInputRouteLock must be held by the caller.
static void MacWSPrepareDirectGestureContextLocked(
        id application, Class eventClass, MacWSInputRecord record,
        id window, NSInteger windowNumber, CGRect mappingFrame,
        CGRect screenFrame,
        CGPoint screenPoint, CGPoint windowPoint) {
    MacWSClearDirectGestureContextLocked();
    MacWSAppInputDirectGestureContext.prepared = YES;
    MacWSAppInputDirectGestureContext.kind = record.kind;
    MacWSAppInputDirectGestureContext.contactID = record.contactID;
    MacWSAppInputDirectGestureContext.targetWindowID =
        MacWSInputWindowIDForScene(record.sceneID);
    MacWSAppInputDirectGestureContext.sceneID = record.sceneID;
    MacWSAppInputDirectGestureContext.windowNumber = windowNumber;
    MacWSAppInputDirectGestureContext.mappingFrame = mappingFrame;
    MacWSAppInputDirectGestureContext.screenFrame = screenFrame;
    MacWSAppInputDirectGestureContext.windowMinusScreen = (CGPoint){
        windowPoint.x - screenPoint.x,
        windowPoint.y - screenPoint.y,
    };
    MacWSAppInputDirectGestureContext.eventClass = eventClass;
    MacWSAppInputDirectGestureContext.application = application
        ? CFRetain((__bridge CFTypeRef)application) : NULL;
    MacWSAppInputDirectGestureContext.window = window
        ? CFRetain((__bridge CFTypeRef)window) : NULL;
}

// MacWSAppInputRouteLock must be held by the caller.
static void MacWSClearMenuContextLocked(void) {
    if (MacWSAppInputMenuContext.application) {
        CFRelease(MacWSAppInputMenuContext.application);
        MacWSAppInputMenuContext.application = NULL;
    }
    MacWSAppInputMenuContext.windowNumber = 0;
    MacWSAppInputMenuContext.screenFrame = (CGRect){0};
    MacWSAppInputMenuContext.windowMinusScreen = (CGPoint){0};
    MacWSAppInputMenuContext.eventClass = Nil;
    MacWSAppInputMenuContext.menuSurface = NO;
    MacWSAppInputMenuContextValid = NO;
}

// MacWSAppInputRouteLock must be held by the caller.  A system-menu probe can
// legitimately have no application NSWindow, so windowNumber=0 and screen
// coordinates are retained as an ordinary AppKit event target.
static void MacWSCacheMenuContextLocked(id application, Class eventClass,
                                        NSInteger windowNumber,
                                        CGRect screenFrame,
                                        CGPoint screenPoint,
                                        CGPoint windowPoint,
                                        BOOL menuSurface) {
    MacWSClearMenuContextLocked();
    if (!application || !eventClass || screenFrame.size.width <= 0.0 ||
        screenFrame.size.height <= 0.0) return;
    MacWSAppInputMenuContext.windowNumber = windowNumber;
    MacWSAppInputMenuContext.screenFrame = screenFrame;
    MacWSAppInputMenuContext.windowMinusScreen = (CGPoint){
        windowPoint.x - screenPoint.x,
        windowPoint.y - screenPoint.y,
    };
    MacWSAppInputMenuContext.eventClass = eventClass;
    MacWSAppInputMenuContext.application =
        CFRetain((__bridge CFTypeRef)application);
    MacWSAppInputMenuContext.menuSurface = menuSurface;
    MacWSAppInputMenuContextValid = YES;
}

// MacWSAppInputRouteLock must be held by the caller.
static BOOL MacWSPrepareDirectMenuPostLocked(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot *snapshot) {
    BOOL isMenuMotion = record.kind == MacWSInputKindMenuHover ||
                        record.kind == MacWSInputKindHover;
    // The right-button system route enters Carbon's menu loop from the real
    // WindowServer event after MacWSPostLegacySystemPointerEvent has already
    // returned, so MacWSAppInputSynchronousTrackingActive is intentionally
    // false even though the application main thread is now blocked inside
    // TrackMenuCommon. Runtime-confirmed on iPad13,6 on 2026-08-13: Terminal's
    // native context menu remained visible but a Host hover over Copy produced
    // no highlight because the record was queued to that blocked main thread.
    // A target probe made before the right click already cached the exact
    // application screen transform. Allow every button-free hover to use that
    // snapshot on the socket thread; the post below is a native global motion
    // event, so WindowServer remains the final hit-test authority.
    if (!isMenuMotion ||
        !MacWSAppInputMenuContextValid ||
        !MacWSAppInputMenuContext.application ||
        !MacWSAppInputMenuContext.eventClass) return NO;
    *snapshot = MacWSAppInputMenuContext;
    snapshot->application = CFRetain(MacWSAppInputMenuContext.application);
    return YES;
}

// A contextual menu owns the application main thread synchronously inside
// HIToolbox TrackMenuCommon. A later Host tap therefore cannot be constructed
// by the ordinary main-run-loop drain: that drain is exactly what the tracker
// is blocking. Use the application/window geometry captured immediately
// before rightMouseDown entered the tracker and put the ordinary NSEvent pair
// into the queue that _NSHLTBMenuEventProc is already consuming.
// MacWSAppInputRouteLock must be held by the caller.
static BOOL MacWSPrepareDirectMenuTapPostLocked(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot *snapshot) {
    if (record.kind != MacWSInputKindTap ||
        !atomic_load_explicit(&MacWSAppInputSynchronousTrackingActive,
                              memory_order_acquire) ||
        !MacWSAppInputMenuContextValid ||
        !MacWSAppInputMenuContext.application ||
        !MacWSAppInputMenuContext.eventClass) return NO;
    *snapshot = MacWSAppInputMenuContext;
    snapshot->application = CFRetain(MacWSAppInputMenuContext.application);
    return YES;
}

// Target probes cache the selected process and its application object before
// the native down can enter a synchronous menu loop. Keyboard records use the
// same authoritative application context but do not depend on pointer
// geometry or a menu window number.
static BOOL MacWSPrepareDirectKeyPostLocked(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot *snapshot) {
    if ((record.kind != MacWSInputKindKeyDown &&
         record.kind != MacWSInputKindKeyUp)) return NO;
    if (atomic_load_explicit(&MacWSAppInputSynchronousTrackingActive,
                             memory_order_acquire) &&
        MacWSAppInputMenuContextValid &&
        MacWSAppInputMenuContext.application &&
        MacWSAppInputMenuContext.eventClass) {
        *snapshot = MacWSAppInputMenuContext;
        snapshot->application = CFRetain(MacWSAppInputMenuContext.application);
        return YES;
    }
    uint32_t windowNumber = MacWSInputWindowIDForScene(record.sceneID);
    if (windowNumber == 0 || !MacWSAppInputKeyboardApplication ||
        !MacWSAppInputKeyboardEventClass) return NO;
    *snapshot = (MacWSDirectTrackingSnapshot){
        .application = CFRetain(MacWSAppInputKeyboardApplication),
        .eventClass = MacWSAppInputKeyboardEventClass,
        .windowNumber = (NSInteger)windowNumber,
    };
    return YES;
}

static NSUInteger MacWSAppInputPressedMouseButtons(id self, SEL command) {
    NSUInteger originalButtons = MacWSOriginalPressedMouseButtons
        ? MacWSOriginalPressedMouseButtons(self, command) : 0;
    NSUInteger buttons = originalButtons;
    // RE-confirmed in the macOS 13.4 AppKit actually loaded on the device:
    // NSControlTrackMouse+668 calls +[NSEvent pressedMouseButtons], and
    // +672..720 immediately invokes _controlStopTracking when bit 0 is clear,
    // before it constructs _NSMouseTracker/trackEvent:usingHandler:. Our
    // per-process NSEvent transport has no CGEvent to update that global bit,
    // so reflect the left-button state only for the synchronous synthetic
    // gesture. All unrelated callers receive the real AppKit result unchanged.
    if (MacWSAppInputRFBTrackingActive)
        buttons |= MacWSAppInputRFBTrackingButtons;
    uint64_t nowMicros = (uint64_t)(
        MacWSAppInputMonotonicSeconds() * 1000000.0);
    if (MacWSRuntimeDiagnosticsEnabled() &&
        MacWSMainBundleIsSevenDaysToDie() &&
        nowMicros <= atomic_load_explicit(
            &MacWSUnityMouseDiagnosticUntilMicros, memory_order_acquire)) {
        uint64_t sequence = atomic_fetch_add_explicit(
            &MacWSUnityMouseDiagnosticSequence, 1, memory_order_relaxed) + 1;
        void *caller = __builtin_return_address(0);
        Dl_info info = {0};
        dladdr(caller, &info);
        fprintf(stderr,
            "#### APP-INPUT UNITY-POLL-BUTTONS pid=%d sequence=%llu "
            "original=%#lx bridged=%#lx active=%s caller=%s+%#lx\n",
            getpid(), (unsigned long long)sequence,
            (unsigned long)originalButtons,
            (unsigned long)buttons,
            MacWSAppInputRFBTrackingActive ? "YES" : "NO",
            info.dli_fname ?: "(unknown)",
            info.dli_fbase
                ? (unsigned long)((uintptr_t)caller -
                                  (uintptr_t)info.dli_fbase) : 0UL);
        fflush(stderr);
    }
    return buttons;
}

static CGPoint MacWSAppInputCurrentMouseLocation(id self, SEL command) {
    CGPoint point = MacWSAppInputMouseLocationActive
        ? MacWSAppInputMouseLocation
        : MacWSAppInputPersistentMouseLocationValid
        ? MacWSAppInputPersistentMouseLocation
        : MacWSOriginalMouseLocation
        ? MacWSOriginalMouseLocation(self, command) : (CGPoint){0.0, 0.0};
    uint64_t nowMicros = (uint64_t)(
        MacWSAppInputMonotonicSeconds() * 1000000.0);
    if (MacWSRuntimeDiagnosticsEnabled() &&
        MacWSMainBundleIsSevenDaysToDie() &&
        nowMicros <= atomic_load_explicit(
            &MacWSUnityMouseDiagnosticUntilMicros, memory_order_acquire)) {
        uint64_t sequence = atomic_fetch_add_explicit(
            &MacWSUnityMouseDiagnosticSequence, 1, memory_order_relaxed) + 1;
        void *caller = __builtin_return_address(0);
        Dl_info info = {0};
        dladdr(caller, &info);
        fprintf(stderr,
            "#### APP-INPUT UNITY-POLL-LOCATION pid=%d sequence=%llu "
            "point=(%.2f,%.2f) route=%s caller=%s+%#lx\n",
            getpid(), (unsigned long long)sequence, point.x, point.y,
            MacWSAppInputMouseLocationActive ? "transient" :
                (MacWSAppInputPersistentMouseLocationValid
                    ? "persistent" : "windowserver"),
            info.dli_fname ?: "(unknown)",
            info.dli_fbase
                ? (unsigned long)((uintptr_t)caller -
                                  (uintptr_t)info.dli_fbase) : 0UL);
        // Diagnostic-only call-chain witness. The public class method enters
        // this replacement through AppKit's forwarding veneer, so level zero
        // alone names AppKit rather than the concrete Unity polling site.
        // Record a bounded prefix for the first few samples; no return value
        // or application state is changed.
        static BOOL loggedPersistentStack;
        BOOL logStack = sequence <= 3 ||
            (!MacWSAppInputMouseLocationActive &&
             MacWSAppInputPersistentMouseLocationValid &&
             !loggedPersistentStack);
        if (logStack) {
            if (!MacWSAppInputMouseLocationActive &&
                MacWSAppInputPersistentMouseLocationValid)
                loggedPersistentStack = YES;
            void *frames[12] = {0};
            int frameCount = backtrace(frames, 12);
            fprintf(stderr,
                "#### APP-INPUT UNITY-POLL-STACK pid=%d sequence=%llu frames=",
                getpid(), (unsigned long long)sequence);
            for (int index = 0; index < frameCount; index++) {
                Dl_info frameInfo = {0};
                dladdr(frames[index], &frameInfo);
                fprintf(stderr, "%s%s+%#lx", index ? "," : "",
                    frameInfo.dli_fname ?: "(unknown)",
                    frameInfo.dli_fbase
                        ? (unsigned long)((uintptr_t)frames[index] -
                                          (uintptr_t)frameInfo.dli_fbase)
                        : 0UL);
            }
            fputc('\n', stderr);
        }
        fflush(stderr);
    }
    return point;
}

// Process-local NSEvents cannot update WindowServer's global cursor state.
// Keep +[NSEvent mouseLocation] and pressedMouseButtons coherent during one
// direct synthetic dispatch, matching the synchronous state invariants of a
// hardware CGEvent. The last position is retained separately by the routing
// path below so later asynchronous polling sees the same cursor location.
// This is required even for button-free mouseMoved:
// NSTabBar uses the class-level mouse location to enter its hover state and
// reveal the standard close button before the following click.
static void MacWSSendMouseEventWithStateBridge(id application, id event,
                                                NSUInteger buttons) {
    if (!application || !event) return;
    BOOL previousActive = MacWSAppInputRFBTrackingActive;
    NSUInteger previousButtons = MacWSAppInputRFBTrackingButtons;
    MacWSAppInputRFBTrackingActive = YES;
    MacWSAppInputRFBTrackingButtons = buttons;
    ((MacWSSendEvent)objc_msgSend)(application,
        sel_registerName("sendEvent:"), event);
    MacWSAppInputRFBTrackingButtons = previousButtons;
    MacWSAppInputRFBTrackingActive = previousActive;
}

static void MacWSLogNSEventFactorySelectors(Class eventClass) {
    if (!eventClass || !MacWSRuntimeDiagnosticsEnabled()) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsigned int count = 0;
        Method *methods = class_copyMethodList(object_getClass(eventClass),
                                                &count);
        fprintf(stderr,
            "#### APP-INPUT NSEVENT-FACTORIES class=%s methods=%u\n",
            class_getName(eventClass), count);
        for (unsigned int index = 0; index < count; index++) {
            SEL selector = method_getName(methods[index]);
            const char *name = selector ? sel_getName(selector) : NULL;
            if (!name || (!strstr(name, "Event") &&
                          !strstr(name, "event") &&
                          !strstr(name, "Mouse") &&
                          !strstr(name, "mouse") &&
                          !strstr(name, "Window") &&
                          !strstr(name, "window"))) continue;
            fprintf(stderr,
                "#### APP-INPUT NSEVENT-FACTORY selector=%s types=%s\n",
                name, method_getTypeEncoding(methods[index]) ?: "(null)");
        }
        free(methods);
        fflush(stderr);
    });
}

static MacWSWorkspaceOpenURLFunction MacWSOriginalWorkspaceOpenURL;
static MacWSWorkspaceOpenURLsFunction MacWSOriginalWorkspaceOpenURLs;
static MacWSWorkspaceLegacyOpenURLFunction
    MacWSOriginalWorkspaceLegacyOpenURL;
static MacWSSeamlessOpenFailureFunction MacWSOriginalSeamlessOpenFailure;

extern xpc_connection_t MacWSRawXPCConnectionCreateMachService(
    const char *, dispatch_queue_t, uint64_t)
    __asm("_xpc_connection_create_mach_service");

static BOOL MacWSIsRoutableWebURL(id value) {
    if (![value isKindOfClass:[NSURL class]]) return NO;
    NSURLComponents *components = [NSURLComponents
        componentsWithURL:(NSURL *)value resolvingAgainstBaseURL:NO];
    NSString *scheme = components.scheme.lowercaseString;
    return components.host.length != 0 && components.user.length == 0 &&
        components.password.length == 0 &&
        ([scheme isEqualToString:@"http"] ||
         [scheme isEqualToString:@"https"]);
}

static BOOL MacWSRequestHostOpenWebURL(NSURL *url, pid_t *targetPIDOut,
                                       NSString **messageOut) {
    if (!MacWSIsRoutableWebURL(url)) return NO;
    xpc_connection_t connection = MacWSRawXPCConnectionCreateMachService(
        MACWS_CONTROL_SERVICE,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), 0);
    if (!connection) return NO;
    xpc_connection_set_event_handler(connection,
        ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_OP,
                              MACWS_CONTROL_OP_OPEN_WEB_URL);
    xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_WEB_URL,
                              url.absoluteString.UTF8String);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
        connection, request);
    BOOL accepted = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
        xpc_dictionary_get_bool(reply, "ok");
    const char *message = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY
        ? xpc_dictionary_get_string(reply, "message") : NULL;
    pid_t targetPID = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY
        ? (pid_t)xpc_dictionary_get_int64(reply, "launched_app_pid") : 0;
    if (targetPIDOut) *targetPIDOut = accepted ? targetPID : 0;
    if (messageOut) *messageOut = message
        ? [NSString stringWithUTF8String:message] : nil;
    if (!accepted || MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT WEB-URL-ROUTE caller=%d target=%d result=%s "
            "message=%s\n",
            getpid(), targetPID,
            accepted ? "simple-browser-accepted" : "failed",
            message ?: "");
        fflush(stderr);
    }
    if (reply) xpc_release(reply);
    xpc_release(request);
    xpc_connection_cancel(connection);
    xpc_release(connection);
    return accepted;
}

static void MacWSDispatchHostOpenWebURL(NSURL *url, id completion) {
    NSURL *urlCopy = [[url copy] autorelease];
    id completionCopy = completion ? [[completion copy] autorelease] : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            pid_t targetPID = 0;
            NSString *message = nil;
            BOOL accepted = MacWSRequestHostOpenWebURL(
                urlCopy, &targetPID, &message);
            if (!completionCopy) return;
            id runningApplication = nil;
            if (accepted && targetPID > 1) {
                id runningClass = (id)objc_getClass("NSRunningApplication");
                SEL withPID = sel_registerName(
                    "runningApplicationWithProcessIdentifier:");
                if (runningClass && [runningClass respondsToSelector:withPID])
                    runningApplication = ((id (*)(id, SEL, pid_t))objc_msgSend)(
                        runningClass, withPID, targetPID);
            }
            NSError *error = accepted ? nil : [NSError
                errorWithDomain:@"com.macwsguide.WebURLRouter"
                           code:-1
                       userInfo:@{NSLocalizedDescriptionKey:
                           message ?: @"VS Code 没有接收网页链接"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                ((void (^)(id, NSError *))completionCopy)(
                    runningApplication, error);
            });
        }
    });
}

static BOOL MacWSWorkspaceLegacyOpenURLRedirect(id workspace, SEL command,
                                                id url) {
    if (!MacWSIsRoutableWebURL(url)) {
        return MacWSOriginalWorkspaceLegacyOpenURL
            ? MacWSOriginalWorkspaceLegacyOpenURL(workspace, command, url)
            : NO;
    }
    // NSWorkspace's legacy API is synchronous, but a cold VS Code launch is
    // not. Acceptance here means the validated transaction was queued onto
    // hostd; its extension-level acknowledgement is recorded asynchronously.
    MacWSDispatchHostOpenWebURL((NSURL *)url, nil);
    return YES;
}

static void MacWSWorkspaceOpenURLRedirect(id workspace, SEL command, id url,
                                          id configuration, id completion) {
    if (!MacWSIsRoutableWebURL(url)) {
        if (MacWSOriginalWorkspaceOpenURL)
            MacWSOriginalWorkspaceOpenURL(
                workspace, command, url, configuration, completion);
        return;
    }
    MacWSDispatchHostOpenWebURL((NSURL *)url, completion);
}

static BOOL MacWSArrayContainsOnlyRoutableWebURLs(id values) {
    if (![values isKindOfClass:[NSArray class]] || [values count] == 0)
        return NO;
    for (id value in values) {
        if (!MacWSIsRoutableWebURL(value)) return NO;
    }
    return YES;
}

static void MacWSWorkspaceOpenURLsRedirect(id workspace, SEL command, id urls,
                                           id applicationURL,
                                           id configuration, id completion) {
    // A non-nil applicationURL is an explicit caller choice rather than a
    // default web-handler request. Preserve that choice, plus every mixed or
    // non-web batch, through NSWorkspace unchanged.
    if (applicationURL || !MacWSArrayContainsOnlyRoutableWebURLs(urls)) {
        if (MacWSOriginalWorkspaceOpenURLs)
            MacWSOriginalWorkspaceOpenURLs(workspace, command, urls,
                                            applicationURL, configuration,
                                            completion);
        return;
    }
    NSArray *urlsCopy = [[urls copy] autorelease];
    id completionCopy = completion ? [[completion copy] autorelease] : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            BOOL accepted = YES;
            pid_t targetPID = 0;
            NSString *message = nil;
            for (NSURL *url in urlsCopy) {
                if (!MacWSRequestHostOpenWebURL(
                        url, &targetPID, &message)) {
                    accepted = NO;
                    break;
                }
            }
            if (!completionCopy) return;
            id runningApplication = nil;
            if (accepted && targetPID > 1) {
                id runningClass = (id)objc_getClass("NSRunningApplication");
                SEL withPID = sel_registerName(
                    "runningApplicationWithProcessIdentifier:");
                if (runningClass && [runningClass respondsToSelector:withPID])
                    runningApplication = ((id (*)(id, SEL, pid_t))objc_msgSend)(
                        runningClass, withPID, targetPID);
            }
            NSError *error = accepted ? nil : [NSError
                errorWithDomain:@"com.macwsguide.WebURLRouter"
                           code:-1
                       userInfo:@{NSLocalizedDescriptionKey:
                           message ?: @"VS Code 没有接收全部网页链接"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                ((void (^)(id, NSError *))completionCopy)(
                    runningApplication, error);
            });
        }
    });
}

static NSURL *MacWSFinderOpenItemURL(id item) {
    static const char *const selectors[] = {
        "fileURL", "previewItemURL", "URL", "url",
    };
    for (NSUInteger index = 0;
         index < sizeof(selectors) / sizeof(selectors[0]); index++) {
        SEL selector = sel_registerName(selectors[index]);
        if (![item respondsToSelector:selector]) continue;
        id value = ((MacWSMsgID)objc_msgSend)(item, selector);
        if (![value isKindOfClass:[NSURL class]]) continue;
        NSURL *pathURL = [(NSURL *)value filePathURL];
        if (pathURL.isFileURL && pathURL.path.length != 0) return pathURL;
    }
    return nil;
}

static NSDictionary<NSString *, NSArray<NSString *> *> *
MacWSFinderDocumentGroups(id items, id error) {
    NSInteger errorCode = [error code];
    // Runtime-confirmed on the device's Finder (2026-09-07): the same
    // QLSeamlessOpener delegate boundary reports Code=5 when LaunchServices
    // cannot start the foreign macOS application through RunningBoard, and
    // Code=-600 (procNotFound) when the target is already running but has no
    // eligible LaunchServices AppleEvent endpoint.  Both failures occur only
    // after Finder has resolved the document and its default application.
    // Preserve every other QL failure for Finder's original handler.
    BOOL launchTransportFailed = errorCode == 5 || errorCode == -600;
    if (![[error domain] isEqualToString:
            MacWSRuntimeString("QLSeamlessOpenerDomain")] ||
        !launchTransportFailed ||
        ![items respondsToSelector:sel_registerName("objectEnumerator")]) {
        return nil;
    }
    id workspaceClass = (id)objc_getClass("NSWorkspace");
    id workspace = workspaceClass && [workspaceClass respondsToSelector:
        sel_registerName("sharedWorkspace")]
        ? ((MacWSMsgID)objc_msgSend)(workspaceClass,
                                    sel_registerName("sharedWorkspace")) : nil;
    SEL resolver = sel_registerName("URLForApplicationToOpenURL:");
    if (!workspace || ![workspace respondsToSelector:resolver]) return nil;

    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *groups =
        [NSMutableDictionary dictionary];
    for (id item in items) {
        NSURL *documentURL = MacWSFinderOpenItemURL(item);
        NSString *documentPath = documentURL.path.stringByStandardizingPath;
        if (!documentPath.length || !documentPath.isAbsolutePath) continue;
        NSURL *applicationURL = ((MacWSMsgIDID)objc_msgSend)(
            workspace, resolver, documentURL);
        applicationURL = [applicationURL filePathURL];
        NSString *applicationPath =
            applicationURL.path.stringByStandardizingPath;
        if (!applicationPath.length || !applicationPath.isAbsolutePath)
            continue;
        NSMutableArray<NSString *> *paths = groups[applicationPath];
        if (!paths) {
            paths = [NSMutableArray array];
            groups[applicationPath] = paths;
        }
        [paths addObject:documentPath];
    }
    if (groups.count == 0) return nil;
    NSMutableDictionary *immutableGroups = [NSMutableDictionary dictionary];
    for (NSString *applicationPath in groups)
        immutableGroups[applicationPath] = [NSArray arrayWithArray:
            groups[applicationPath]];
    return immutableGroups;
}

static BOOL MacWSRequestHostOpenDocuments(NSString *applicationPath,
                                          NSArray<NSString *> *paths) {
    if (!applicationPath.length || paths.count == 0) return NO;
    xpc_connection_t connection = MacWSRawXPCConnectionCreateMachService(
        MACWS_CONTROL_SERVICE,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), 0);
    if (!connection) return NO;
    xpc_connection_set_event_handler(connection,
        ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_OP,
                              MACWS_CONTROL_OP_OPEN_DOCUMENTS);
    xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_APP_PATH,
                              applicationPath.fileSystemRepresentation);
    xpc_object_t documents = xpc_array_create(NULL, 0);
    for (NSString *path in paths)
        xpc_array_set_string(documents, XPC_ARRAY_APPEND,
                             path.fileSystemRepresentation);
    xpc_dictionary_set_value(request, MACWS_CONTROL_KEY_DOCUMENT_PATHS,
                             documents);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
        connection, request);
    BOOL accepted = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
        xpc_dictionary_get_bool(reply, "ok");
    const char *message = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY
        ? xpc_dictionary_get_string(reply, "message") : NULL;
    int64_t targetPID = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY
        ? xpc_dictionary_get_int64(reply, "launched_app_pid") : 0;
    fprintf(stderr,
        "#### APP-INPUT FINDER-OPEN-ROUTE app=%s documents=%lu "
        "target=%lld result=%s message=%s\n",
        applicationPath.fileSystemRepresentation,
        (unsigned long)paths.count, (long long)targetPID,
        accepted ? "appkit-accepted" : "failed", message ?: "");
    fflush(stderr);
    if (reply) xpc_release(reply);
    xpc_release(documents);
    xpc_release(request);
    xpc_connection_cancel(connection);
    xpc_release(connection);
    return accepted;
}

static void MacWSSeamlessOpenFailureWitness(id delegate, SEL command,
                                            id opener, id items, id error) {
    NSDictionary<NSString *, NSArray<NSString *> *> *groups =
        MacWSFinderDocumentGroups(items, error);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "#### APP-INPUT SEAMLESS-OPEN-FAIL selector=%s opener=%s "
                "items=%s error=%s recoverable=%s\n",
                sel_getName(command),
                [[opener description] UTF8String] ?: "(nil)",
                [[items description] UTF8String] ?: "(nil)",
                [[error description] UTF8String] ?: "(nil)",
                groups.count ? "YES" : "NO");
        for (id item in items) {
            fprintf(stderr,
                    "#### APP-INPUT SEAMLESS-OPEN-ITEM class=%s value=%s",
                    object_getClassName(item) ?: "(nil)",
                    [[item description] UTF8String] ?: "(nil)");
            static const char *const selectors[] = {
                "URL", "url", "fileURL", "previewItemURL", "node",
            };
            for (NSUInteger index = 0;
                 index < sizeof(selectors) / sizeof(selectors[0]); index++) {
                SEL selector = sel_registerName(selectors[index]);
                if (![item respondsToSelector:selector]) continue;
                id value = ((MacWSMsgID)objc_msgSend)(item, selector);
                fprintf(stderr, " %s=%s", selectors[index],
                        [[value description] UTF8String] ?: "(nil)");
            }
            fprintf(stderr, "\n");
        }
        fflush(stderr);
    }
    MacWSOriginalSeamlessOpenFailure(
        delegate, command, opener, items, error);
    if (groups.count != 0) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                       ^{
            @autoreleasepool {
                for (NSString *applicationPath in groups)
                    (void)MacWSRequestHostOpenDocuments(
                        applicationPath, groups[applicationPath]);
            }
        });
    }
}

// Finder's stock QLSeamlessOpener remains the first owner of double-click and
// Open menu actions. Runtime logs on 2026-09-07 show that it resolves the
// correct application and then calls this exact delegate method with
// QLSeamlessOpenerDomain Code=5 after RunningBoard rejects the foreign macOS
// launch, or Code=-600 when an already-running target has no eligible
// LaunchServices AppleEvent endpoint. Preserve the original failure callback,
// then complete only those typed failures through hostd and the target's
// normal AppKit open-event path.
// The typed HTTP(S) redirect below is production behavior for every AppKit
// application. Finder's explicit-app document bridge and the multi-URL
// NSWorkspace witness remain independently scoped.
static void MacWSInstallWorkspaceOpenWitness(void) {
    BOOL finder = strcmp(MacWSAppInputProgramName(), "Finder") == 0;
    id workspaceClass = (id)objc_getClass("NSWorkspace");
    id sharedWorkspace = workspaceClass &&
        [workspaceClass respondsToSelector:sel_registerName("sharedWorkspace")]
        ? ((MacWSMsgID)objc_msgSend)(workspaceClass,
                                    sel_registerName("sharedWorkspace")) : nil;
    Class implementationClass = sharedWorkspace
        ? object_getClass(sharedWorkspace) : (Class)workspaceClass;
    if (!implementationClass) return;

    if (finder) {
        Class seamlessDelegate = objc_getClass("TSeamlessOpenerDelegate");
        SEL seamlessFailure = sel_registerName(
            "seamlessOpener:failedToOpenItems:withError:");
        Method seamlessFailureMethod = seamlessDelegate
            ? class_getInstanceMethod(seamlessDelegate, seamlessFailure) : NULL;
        if (seamlessFailureMethod && !MacWSOriginalSeamlessOpenFailure) {
            MacWSOriginalSeamlessOpenFailure =
                (MacWSSeamlessOpenFailureFunction)
                method_getImplementation(seamlessFailureMethod);
            method_setImplementation(seamlessFailureMethod,
                                     (IMP)MacWSSeamlessOpenFailureWitness);
            if (MacWSRuntimeDiagnosticsEnabled())
                fprintf(stderr,
                        "#### APP-INPUT WORKSPACE-WITNESS selector=%s "
                        "types=%s\n",
                        sel_getName(seamlessFailure),
                        method_getTypeEncoding(seamlessFailureMethod) ?:
                            "(null)");
        }
    }

    SEL legacyOpenURL = sel_registerName("openURL:");
    Method legacyOpenURLMethod = class_getInstanceMethod(
        implementationClass, legacyOpenURL);
    const char *legacyTypes = legacyOpenURLMethod
        ? method_getTypeEncoding(legacyOpenURLMethod) : NULL;
    if (legacyOpenURLMethod && legacyTypes &&
        (legacyTypes[0] == 'B' || legacyTypes[0] == 'c') &&
        !MacWSOriginalWorkspaceLegacyOpenURL) {
        MacWSOriginalWorkspaceLegacyOpenURL =
            (MacWSWorkspaceLegacyOpenURLFunction)
            method_getImplementation(legacyOpenURLMethod);
        method_setImplementation(legacyOpenURLMethod,
                                 (IMP)MacWSWorkspaceLegacyOpenURLRedirect);
        if (MacWSRuntimeDiagnosticsEnabled())
            fprintf(stderr,
                    "#### APP-INPUT WORKSPACE-WEB-ROUTE selector=%s "
                    "types=%s\n", sel_getName(legacyOpenURL), legacyTypes);
    }

    SEL openURL = sel_registerName(
        "openURL:configuration:completionHandler:");
    Method openURLMethod = class_getInstanceMethod(implementationClass,
                                                    openURL);
    if (openURLMethod && !MacWSOriginalWorkspaceOpenURL) {
        MacWSOriginalWorkspaceOpenURL = (MacWSWorkspaceOpenURLFunction)
            method_getImplementation(openURLMethod);
        method_setImplementation(openURLMethod,
                                 (IMP)MacWSWorkspaceOpenURLRedirect);
        if (MacWSRuntimeDiagnosticsEnabled())
            fprintf(stderr,
                    "#### APP-INPUT WORKSPACE-WEB-ROUTE selector=%s "
                    "types=%s\n", sel_getName(openURL),
                    method_getTypeEncoding(openURLMethod) ?: "(null)");
    }

    SEL openURLs = sel_registerName(
        "openURLs:withApplicationAtURL:configuration:completionHandler:");
    Method openURLsMethod = class_getInstanceMethod(implementationClass,
                                                     openURLs);
    if (openURLsMethod && !MacWSOriginalWorkspaceOpenURLs) {
        MacWSOriginalWorkspaceOpenURLs = (MacWSWorkspaceOpenURLsFunction)
        method_getImplementation(openURLsMethod);
        method_setImplementation(openURLsMethod,
                                 (IMP)MacWSWorkspaceOpenURLsRedirect);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                    "#### APP-INPUT WORKSPACE-WEB-ROUTE selector=%s "
                    "types=%s\n", sel_getName(openURLs),
                    method_getTypeEncoding(openURLsMethod) ?: "(null)");
        }
    }
    if (MacWSRuntimeDiagnosticsEnabled()) fflush(stderr);
}

static void MacWSInstallPressedMouseButtonsBridge(Class eventClass) {
    MacWSLogNSEventFactorySelectors(eventClass);
    SEL selector = sel_registerName("pressedMouseButtons");
    Method method = class_getClassMethod(eventClass, selector);
    if (!MacWSOriginalPressedMouseButtons && !method) {
        fprintf(stderr,
            "#### APP-INPUT STATE-BRIDGE unavailable: +[NSEvent pressedMouseButtons]\n");
        fflush(stderr);
    } else if (!MacWSOriginalPressedMouseButtons) {
        IMP implementation = method_getImplementation(method);
        if (implementation != (IMP)MacWSAppInputPressedMouseButtons) {
            MacWSOriginalPressedMouseButtons =
                (MacWSPressedMouseButtons)implementation;
            method_setImplementation(method,
                (IMP)MacWSAppInputPressedMouseButtons);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT STATE-BRIDGE installed "
                    "+[NSEvent pressedMouseButtons]\n");
                fflush(stderr);
            }
        }
    }

    SEL locationSelector = sel_registerName("mouseLocation");
    Method locationMethod = class_getClassMethod(eventClass,
                                                  locationSelector);
    if (!MacWSOriginalMouseLocation && locationMethod) {
        IMP implementation = method_getImplementation(locationMethod);
        if (implementation != (IMP)MacWSAppInputCurrentMouseLocation) {
            MacWSOriginalMouseLocation = (MacWSMouseLocation)implementation;
            method_setImplementation(locationMethod,
                (IMP)MacWSAppInputCurrentMouseLocation);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT STATE-BRIDGE installed "
                    "+[NSEvent mouseLocation]\n");
                fflush(stderr);
            }
        }
    }
}

// getprogname() is initialized independently of injected-image constructors
// and can still be empty during the earliest dylib initializer. Resolve the
// actual executable basename from dyld first so special CGS owners such as
// Dock do not miss their one process-local endpoint merely because constructor
// ordering changed after a rebuild.
static const char *MacWSAppInputProgramName(void) {
    static char executablePath[4096];
    static const char *basename;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint32_t capacity = (uint32_t)sizeof(executablePath);
        if (_NSGetExecutablePath(executablePath, &capacity) == 0) {
            char *separator = strrchr(executablePath, '/');
            basename = separator ? separator + 1 : executablePath;
        }
        if (!basename || basename[0] == '\0') basename = getprogname();
    });
    return basename;
}

static BOOL MacWSAppInputIsTopLevelSteamBrowser(void) {
    const char *program = MacWSAppInputProgramName();
    if (!program || strcmp(program, "Steam Helper") != 0) return NO;
    int *argumentCount = _NSGetArgc();
    char ***argumentVector = _NSGetArgv();
    int count = argumentCount ? *argumentCount : 0;
    char **arguments = argumentVector ? *argumentVector : NULL;
    for (int index = 1; arguments && index < count; index++) {
        if (arguments[index] && !strncmp(arguments[index], "--type=", 7))
            return NO;
    }
    return YES;
}

static BOOL MacWSAppInputSupportedProcess(void) {
    const char *program = MacWSAppInputProgramName();
    // Dock is not an NSApplication process.  It owns a native CGS event port
    // and drains it with CGEventCreateNextEvent (RE-confirmed in the Ventura
    // 13.4 Dock binary at __TEXT+0x1dca8), so it needs a process-local socket
    // endpoint of its own.  The socket handler feeds CoreGraphics from this
    // already-CGS-connected process; it never enters the AppKit dispatcher.
    if (program && strcmp(program, "Dock") == 0) return YES;
    // libmachook itself maps AppKit in some command-line tools. The presence
    // of NSApplication in the process is therefore not evidence that the
    // executable owns a GUI lifecycle (vim is a runtime-confirmed example).
    // A regular AppKit app's executable lives inside its bundle; excluding
    // loose CLI binaries also avoids the forty delayed install retries.
    char executablePath[PATH_MAX] = {0};
    uint32_t executableCapacity = (uint32_t)sizeof(executablePath);
    if (_NSGetExecutablePath(executablePath, &executableCapacity) != 0 ||
        !strstr(executablePath, ".app/Contents/MacOS/")) return NO;
    // A finite application-name allowlist cannot cover Finder panels, menu
    // extras, newly installed GUI applications, or future Electron shells.
    // Install in every real AppKit application.  Chromium helpers are kept
    // out because they can load AppKit without owning a window/run loop; a
    // non-replying helper would unnecessarily consume the target-probe
    // deadline.  Processes that do not load NSApplication are not endpoints.
    if (!program || !objc_getClass("NSApplication")) return NO;
    // UIKitSystem is infrastructure, not a user-facing AppKit application.
    // Runtime-confirmed by UIKitSystem-2026-08-07-040707.ips: our periodic
    // MacWSPublishWindowMetrics entered +[NSApplication sharedApplication]
    // inside UIKitSystem, initialized Dock registration there, and the same
    // process then crashed while its FrontBoard repository was being built.
    // It must provide Catalyst/FrontBoard services without an AppInput socket,
    // an NSApplication instance, or a synthetic window-catalog publisher.
    if (strcmp(program, "UIKitSystem") == 0) return NO;
    // Steam's visible Store/Library NSWindows belong to the one top-level
    // CEF browser process named "Steam Helper".  Its renderer, GPU, network,
    // storage and Crashpad descendants use the same executable name but all
    // carry a Chromium --type= role.  Treat only the role-less AppKit owner as
    // an input endpoint; otherwise macPad can display its real window yet has
    // no process-local socket with which to activate or click it.
    BOOL topLevelSteamBrowser = MacWSAppInputIsTopLevelSteamBrowser();
    if ((strstr(program, "Helper") && !topLevelSteamBrowser) ||
        strstr(program, "Renderer") ||
        strstr(program, "GPU") || strcmp(program, "WindowServer") == 0 ||
        strstr(program, "OSXvnc") || strcmp(program, "launchservicesd") == 0 ||
        strcmp(program, "macwsdisplayd") == 0 ||
        strcmp(program, "macwsinteropd") == 0)
        return NO;
    return YES;
}

static BOOL MacWSAppInputIsDockEndpoint(void) {
    const char *program = MacWSAppInputProgramName();
    return program && strcmp(program, "Dock") == 0;
}

static void MacWSPublishDockExposeState(BOOL active) {
    if (!MacWSAppInputIsDockEndpoint()) return;
    if (MacWSDockExposeStateToken < 0) {
        int candidate = -1;
        if (notify_register_check(MACWS_DOCK_EXPOSE_STATE_NAME,
                                  &candidate) != NOTIFY_STATUS_OK) return;
        MacWSDockExposeStateToken = candidate;
        // A fresh Dock must overwrite a stale state left by an older process,
        // even if its first observed modal handler is inactive.
        MacWSDockExposePublishedActive = !active;
    }
    if (MacWSDockExposePublishedActive == active) return;
    uint32_t status = notify_set_state(MacWSDockExposeStateToken,
        MacWSDockExposeState((uint32_t)getpid(), active));
    if (status == NOTIFY_STATUS_OK)
        status = notify_post(MACWS_DOCK_EXPOSE_STATE_NAME);
    if (status == NOTIFY_STATUS_OK) {
        MacWSDockExposePublishedActive = active;
    } else if (status == NOTIFY_STATUS_INVALID_TOKEN ||
               status == NOTIFY_STATUS_SERVER_NOT_FOUND) {
        notify_cancel(MacWSDockExposeStateToken);
        MacWSDockExposeStateToken = -1;
    }
}

static void MacWSPublishDockCurrentModalHandler(id controller) {
    id handler = [controller respondsToSelector:
        sel_registerName("currentHandler")]
        ? ((id (*)(id, SEL))objc_msgSend)(
            controller, sel_registerName("currentHandler")) : nil;
    Class exposeClass = objc_getClass("_TtC4Dock21ExposeEventController");
    MacWSPublishDockExposeState(handler && exposeClass &&
        [handler isKindOfClass:exposeClass]);
}

static void MacWSDockModalAddHandlerWitness(
        id self, SEL selector, id handler, BOOL externalEventSource,
        BOOL usingMouseHysteresis) {
    MacWSOriginalDockModalAddHandler(self, selector, handler,
                                    externalEventSource,
                                    usingMouseHysteresis);
    // RE-confirmed via the installed Ventura 13.4 Dock arm64e method list:
    // addHandler:externalEventSource:usingMouseHysteresis: is
    // v32@0:8@16B24B28. Publish only the controller's resulting real owner;
    // the argument can be queued beneath an existing modal handler.
    MacWSPublishDockCurrentModalHandler(self);
}

static void MacWSDockModalRemoveHandlerWitness(
        id self, SEL selector, id handler) {
    MacWSOriginalDockModalRemoveHandler(self, selector, handler);
    // RE-confirmed selector ABI v24@0:8@16. This edge clears Expose ownership
    // immediately, even when no further native pointer event reaches Dock.
    MacWSPublishDockCurrentModalHandler(self);
}

static id MacWSDockGesturesInitWitness(id self, SEL selector) {
    id result = MacWSOriginalDockGesturesInit
        ? ((id (*)(id, SEL))MacWSOriginalDockGesturesInit)(self, selector)
        : nil;
    if (result) atomic_store_explicit(
        &MacWSDockGesturesInstance, (uintptr_t)result,
        memory_order_release);
    return result;
}

static BOOL (*MacWSDockFileActionOriginal)(id, SEL, uint32_t, BOOL);

static BOOL MacWSSendDockActivation(pid_t targetPID) {
    if (targetPID <= 1) return NO;
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    int length = snprintf(path, sizeof(path),
                          "/private/tmp/macws_app_input.%d.sock", targetPID);
    if (length <= 0 || (size_t)length >= sizeof(path)) return NO;
    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socketFD < 0) return NO;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, (size_t)length + 1);
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MacWSInputWireVersionForKind(MacWSInputKindActivateTarget),
        .kind = MacWSInputKindActivateTarget,
        .timestamp = CFAbsoluteTimeGetCurrent(),
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = targetPID,
        .source = MacWSInputSourceUnknown,
    };
    ssize_t sent = sendto(socketFD, &record, sizeof(record), MSG_DONTWAIT,
                          (const struct sockaddr *)&address,
                          sizeof(address));
    close(socketFD);
    return sent == (ssize_t)sizeof(record);
}

static BOOL MacWSDockFileActionWitness(id self, SEL selector,
                                       uint32_t action, BOOL keyboard) {
    BOOL result = MacWSDockFileActionOriginal(
        self, selector, action, keyboard);
    // Runtime-confirmed on the iPad: tapping the Excel and Word running-app
    // icons invokes DOCKFileTile doAction:fromKeyboard: with action 0x100100,
    // and that method returns NO without bringing either app forward. Both
    // tiles contain a live _psn that GetProcessPID resolves to the correct
    // application. Let Dock try its normal route first; only complete this
    // failed running-app activation through the existing AppKit input bridge.
    if (result || action != 0x100100u) return result;
    Ivar psnIvar = class_getInstanceVariable(object_getClass(self), "_psn");
    if (!psnIvar || ivar_getOffset(psnIvar) < 0) return result;
    uint32_t psn[2] = {0};
    memcpy(psn, (const char *)self + ivar_getOffset(psnIvar), sizeof(psn));
    pid_t targetPID = -1;
    typedef OSStatus (*GetProcessPIDFunction)(const void *, pid_t *);
    static GetProcessPIDFunction getProcessPID;
    static dispatch_once_t resolveOnce;
    dispatch_once(&resolveOnce, ^{
        getProcessPID = (GetProcessPIDFunction)dlsym(
            RTLD_DEFAULT, "GetProcessPID");
    });
    if (!getProcessPID || getProcessPID(psn, &targetPID) != noErr ||
        targetPID <= 1) return result;
    BOOL activated = MacWSSendDockActivation(targetPID);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr, "#### APP-INPUT DOCK-ACTIVATE action=0x%x "
                "target=%d sent=%s\n", action, targetPID,
                activated ? "YES" : "NO");
        fflush(stderr);
    }
    return activated ? YES : result;
}

static void MacWSClearDockModalContext(void) {
    MacWSPublishDockExposeState(NO);
    [MacWSDockModalWindow release];
    [MacWSDockModalTopLayer release];
    MacWSDockModalWindow = nil;
    MacWSDockModalTopLayer = nil;
    if (MacWSDockModalTemplateEvent)
        CFRelease(MacWSDockModalTemplateEvent);
    MacWSDockModalTemplateEvent = NULL;
    MacWSDockModalTemplatePoint = CGPointZero;
    MacWSDockModalTemplatePointValid = NO;
    atomic_fetch_add_explicit(&MacWSDockModalContextRevision, 1,
                              memory_order_release);
}

static void MacWSDockModalEventRouterWitness(
        id self, SEL selector, id event, const id *windows,
        const id *topLayers, NSUInteger windowCount) {
    id currentHandler = [self respondsToSelector:
        sel_registerName("currentHandler")]
        ? ((id (*)(id, SEL))objc_msgSend)(
            self, sel_registerName("currentHandler")) : nil;
    Class exposeClass = objc_getClass("_TtC4Dock21ExposeEventController");
    BOOL exposeActive = currentHandler && exposeClass &&
        [currentHandler isKindOfClass:exposeClass];
    MacWSPublishDockExposeState(exposeActive);
    if (windowCount > 0 && windows && topLayers && windows[0] &&
        topLayers[0] && exposeActive) {
        static MacWSCopyCGEvent copyEvent;
        static MacWSGetCGEventType getEventType;
        static MacWSGetCGEventLocation getEventLocation;
        static dispatch_once_t copyOnce;
        dispatch_once(&copyOnce, ^{
            copyEvent = (MacWSCopyCGEvent)dlsym(
                RTLD_DEFAULT, "CGEventCreateCopy");
            getEventType = (MacWSGetCGEventType)dlsym(
                RTLD_DEFAULT, "CGEventGetType");
            getEventLocation = (MacWSGetCGEventLocation)dlsym(
                RTLD_DEFAULT, "CGEventGetLocation");
        });
        if (MacWSDockModalWindow != windows[0]) {
            [windows[0] retain];
            [MacWSDockModalWindow release];
            MacWSDockModalWindow = windows[0];
        }
        if (MacWSDockModalTopLayer != topLayers[0]) {
            [topLayers[0] retain];
            [MacWSDockModalTopLayer release];
            MacWSDockModalTopLayer = topLayers[0];
        }
        MacWSCGEventRef sourceEvent =
            (MacWSCGEventRef)(uintptr_t)event;
        uint32_t eventType = getEventType && sourceEvent
            ? getEventType(sourceEvent) : UINT32_MAX;
        // The template is used only to reconstruct a mouse event at the same
        // native modal hit. DOCKGestures also drives private type-29 gesture
        // events through adjacent EyeCandy state while Mission Control is
        // animating. Copying and retaining each 120-Hz gesture event adds work
        // to Dock's main thread and cannot improve pointer routing. Preserve
        // only the real mouse family (down/up/move/drag = 1...6).
        MacWSCGEventRef copied = copyEvent && eventType >= 1 && eventType <= 6
            ? copyEvent(sourceEvent) : NULL;
        if (copied) {
            if (MacWSDockModalTemplateEvent)
                CFRelease(MacWSDockModalTemplateEvent);
            MacWSDockModalTemplateEvent = copied;
            MacWSDockModalTemplatePoint = getEventLocation
                ? getEventLocation(copied) : CGPointZero;
            MacWSDockModalTemplatePointValid = getEventLocation != NULL;
            atomic_fetch_add_explicit(&MacWSDockModalContextRevision, 1,
                                      memory_order_release);
        }
    } else if (!exposeActive) {
        MacWSClearDockModalContext();
    }
    if (MacWSOriginalDockModalEventRouter)
        ((void (*)(id, SEL, id, const id *, const id *, NSUInteger))
            MacWSOriginalDockModalEventRouter)(
                self, selector, event, windows, topLayers, windowCount);
}

static BOOL MacWSInstallDockModalEventWitness(void) {
    Class modalClass = objc_getClass("ECModalEventController");
    if (!modalClass) return NO;
    SEL addSelector = sel_registerName(
        "addHandler:externalEventSource:usingMouseHysteresis:");
    Method addMethod = class_getInstanceMethod(modalClass, addSelector);
    const char *addTypes = addMethod
        ? method_getTypeEncoding(addMethod) : NULL;
    if (addTypes && strcmp(addTypes, "v32@0:8@16B24B28") == 0 &&
        !MacWSOriginalDockModalAddHandler) {
        IMP current = method_getImplementation(addMethod);
        if (current != (IMP)MacWSDockModalAddHandlerWitness) {
            MacWSOriginalDockModalAddHandler =
                (void (*)(id, SEL, id, BOOL, BOOL))current;
            method_setImplementation(addMethod,
                (IMP)MacWSDockModalAddHandlerWitness);
        }
    }
    SEL removeSelector = sel_registerName("removeHandler:");
    Method removeMethod = class_getInstanceMethod(modalClass, removeSelector);
    const char *removeTypes = removeMethod
        ? method_getTypeEncoding(removeMethod) : NULL;
    if (removeTypes && strcmp(removeTypes, "v24@0:8@16") == 0 &&
        !MacWSOriginalDockModalRemoveHandler) {
        IMP current = method_getImplementation(removeMethod);
        if (current != (IMP)MacWSDockModalRemoveHandlerWitness) {
            MacWSOriginalDockModalRemoveHandler =
                (void (*)(id, SEL, id))current;
            method_setImplementation(removeMethod,
                (IMP)MacWSDockModalRemoveHandlerWitness);
        }
    }
    SEL routeSelector = sel_registerName(
        "handleEvent:windows:topLayers:windowCount:");
    Method routeMethod = class_getInstanceMethod(modalClass, routeSelector);
    if (!routeMethod) return NO;
    IMP current = method_getImplementation(routeMethod);
    if (current != (IMP)MacWSDockModalEventRouterWitness) {
        MacWSOriginalDockModalEventRouter = current;
        method_setImplementation(
            routeMethod, (IMP)MacWSDockModalEventRouterWitness);
    }
    return YES;
}

// Dock constructs its process-wide DOCKGestures object during application
// startup.  An inserted-dylib constructor normally installs the -init witness
// first, but that order is not an invariant: relaunching only Dock inside an
// already-running Aqua session can initialize the singleton before AppKit has
// returned to our finite install retry.  Do not allocate a second gesture
// controller.  Recover the exact strong object that Dock's own -init stores.
//
// RE-confirmed in the target Ventura 13.4 arm64e Dock binary: the epilogue of
// -[DOCKGestures init] at __TEXT+0x9314 materializes its strong global with
//     adrp x0, <slot>; add x0, x0, <offset>; mov x1, x19;
//     bl _objc_storeStrong
// Runtime LLDB on Dock pid 16180 (2026-08-13) read that derived slot at
// 0x100507ac8 as 0x14cf27970 after a late hook install.  Decode the guarded
// instruction relationship instead of baking either address or the ASLR
// slide into production.
static id MacWSExistingDockGesturesInstanceFromInitIMP(
        IMP implementation, Class gesturesClass) {
#if defined(__arm64__) || defined(__aarch64__)
    if (!implementation || !gesturesClass) return nil;
    const uint32_t *instructions = (const uint32_t *)ptrauth_strip(
        (void *)implementation, ptrauth_key_function_pointer);
    if (!instructions) return nil;
    // The real target method is 0x184 bytes.  Keep the scan finite and require
    // the complete compiler-emitted objc_storeStrong argument sequence so an
    // unrelated ADRP/ADD pair can never become an object slot.
    for (NSUInteger index = 0; index + 3 < 0x200 / sizeof(uint32_t);
         index++) {
        uint32_t adrp = instructions[index];
        uint32_t add = instructions[index + 1];
        uint32_t moveObject = instructions[index + 2];
        uint32_t call = instructions[index + 3];
        BOOL adrpX0 = (adrp & UINT32_C(0x9f00001f)) ==
            UINT32_C(0x90000000);
        BOOL addX0X0 = (add & UINT32_C(0xff8003ff)) ==
            UINT32_C(0x91000000);
        if (!adrpX0 || !addX0X0 ||
            moveObject != UINT32_C(0xaa1303e1) ||
            (call & UINT32_C(0xfc000000)) != UINT32_C(0x94000000))
            continue;

        int64_t pageDelta = (int64_t)(((adrp >> 5) & 0x7ffffu) << 2 |
                                      ((adrp >> 29) & 0x3u));
        // Sign-extend the 21-bit ADRP immediate before its page shift.
        if (pageDelta & (INT64_C(1) << 20))
            pageDelta -= INT64_C(1) << 21;
        uintptr_t instructionPC = (uintptr_t)&instructions[index];
        uintptr_t page = instructionPC & ~(uintptr_t)0xfff;
        uintptr_t slot = (uintptr_t)((intptr_t)page + pageDelta * 4096);
        uintptr_t immediate = (add >> 10) & 0xfffu;
        if (add & (UINT32_C(1) << 22)) immediate <<= 12;
        slot += immediate;
        if ((slot & (sizeof(uintptr_t) - 1)) != 0) continue;

        uintptr_t rawObject = __atomic_load_n(
            (const uintptr_t *)slot, __ATOMIC_ACQUIRE);
        id candidate = (id)rawObject;
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT DOCK-GESTURES scan pid=%d init=%p "
                "slot=%p candidate=%p class=%p expected=%p\n",
                getpid(), implementation, (void *)slot, candidate,
                candidate ? object_getClass(candidate) : Nil, gesturesClass);
            fflush(stderr);
        }
        if (candidate && object_getClass(candidate) == gesturesClass) {
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT DOCK-GESTURES recovered pid=%d "
                    "instance=%p slot=%p source=init-strong-global\n",
                    getpid(), candidate, (void *)slot);
                fflush(stderr);
            }
            return candidate;
        }
    }
#else
    (void)implementation;
    (void)gesturesClass;
#endif
    return nil;
}

static BOOL MacWSInstallDockGesturesWitness(void) {
    Class gesturesClass = objc_getClass("DOCKGestures");
    if (!gesturesClass) return NO;
    Method method = class_getInstanceMethod(gesturesClass,
                                             sel_registerName("init"));
    if (!method) return NO;
    IMP current = method_getImplementation(method);
    if (current != (IMP)MacWSDockGesturesInitWitness) {
        MacWSOriginalDockGesturesInit = current;
        method_setImplementation(method, (IMP)MacWSDockGesturesInitWitness);
    }
    Class fileTile = objc_getClass("DOCKFileTile");
    SEL actionSelector = sel_registerName("doAction:fromKeyboard:");
    Method fileAction = fileTile
        ? class_getInstanceMethod(fileTile, actionSelector) : NULL;
    const char *fileTypes = fileAction
        ? method_getTypeEncoding(fileAction) : NULL;
    if (fileAction && fileTypes &&
        strcmp(fileTypes, "B24@0:8I16B20") == 0 &&
        !MacWSDockFileActionOriginal) {
        IMP original = method_getImplementation(fileAction);
        if (original != (IMP)MacWSDockFileActionWitness) {
            MacWSDockFileActionOriginal =
                (BOOL (*)(id, SEL, uint32_t, BOOL))original;
            if (!class_addMethod(fileTile, actionSelector,
                    (IMP)MacWSDockFileActionWitness, fileTypes)) {
                method_setImplementation(fileAction,
                    (IMP)MacWSDockFileActionWitness);
            }
        }
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT DOCK-GESTURES install pid=%d current=%p "
            "original=%p captured=%p\n",
            getpid(), current, MacWSOriginalDockGesturesInit,
            (void *)atomic_load_explicit(&MacWSDockGesturesInstance,
                                         memory_order_acquire));
        fflush(stderr);
    }
    if (atomic_load_explicit(&MacWSDockGesturesInstance,
                             memory_order_acquire) == 0) {
        id existing = MacWSExistingDockGesturesInstanceFromInitIMP(
            MacWSOriginalDockGesturesInit, gesturesClass);
        if (existing) atomic_store_explicit(
            &MacWSDockGesturesInstance, (uintptr_t)existing,
            memory_order_release);
    }
    // EyeCandy classes can be realized after the inserted-dylib constructor.
    // The system-gesture Begin path retries before Dock opens Mission Control.
    (void)MacWSInstallDockModalEventWitness();
    return YES;
}

static id MacWSCurrentDockGesturesInstance(void) {
    id gestures = (id)atomic_load_explicit(
        &MacWSDockGesturesInstance, memory_order_acquire);
    if (gestures || !MacWSAppInputIsDockEndpoint()) return gestures;
    Class gesturesClass = objc_getClass("DOCKGestures");
    gestures = MacWSExistingDockGesturesInstanceFromInitIMP(
        MacWSOriginalDockGesturesInit, gesturesClass);
    if (gestures) atomic_store_explicit(
        &MacWSDockGesturesInstance, (uintptr_t)gestures,
        memory_order_release);
    return gestures;
}

static BOOL MacWSPointInRect(CGPoint point, CGRect rect) {
    return point.x >= rect.origin.x && point.y >= rect.origin.y &&
           point.x < rect.origin.x + rect.size.width &&
           point.y < rect.origin.y + rect.size.height;
}

static NSUInteger MacWSNSEventType(MacWSInputKind kind) {
    switch (kind) {
        case MacWSInputKindTouchDown: return 1;  // NSEventTypeLeftMouseDown
        case MacWSInputKindTouchMove: return 6;  // NSEventTypeLeftMouseDragged
        case MacWSInputKindTouchUp:
        case MacWSInputKindTouchCancel: return 2; // NSEventTypeLeftMouseUp
        case MacWSInputKindHover: return 5;       // NSEventTypeMouseMoved
        case MacWSInputKindMenuHover: return 5;   // menu-owned mouseMoved
        case MacWSInputKindTap: return 1;         // atomic left down + up
        case MacWSInputKindSecondaryTap: return 3; // atomic right down + up
        case MacWSInputKindTargetProbe:
        case MacWSInputKindActivateTarget:
        case MacWSInputKindDeactivateApplication:
        case MacWSInputKindKeyDown:
        case MacWSInputKindKeyUp:
        case MacWSInputKindScroll:
        case MacWSInputKindMagnify:
        case MacWSInputKindRotate:
        case MacWSInputKindPerformPaste:
        case MacWSInputKindOpenDocuments:
        case MacWSInputKindPerformQuit:
        case MacWSInputKindRelativePointer:
        case MacWSInputKindConfigureWindow:
        case MacWSInputKindCloseWindow:
        case MacWSInputKindCreateInitialWindow:
        case MacWSInputKindReopenApplication:
        case MacWSInputKindDesktopCommand:
        case MacWSInputKindSystemGesture:
            return 0; // control-plane only; handled before event construction
    }
    return 0;
}

// A stationary Host/VNC click has to satisfy two different, legitimate AppKit
// consumers.  NSControl/NSMenu can enter a nested tracker while handling down,
// so up must already be in NSApplication's queue.  Electron content controls,
// on the other hand, return from down without starting that tracker and this
// launchd-created application session does not necessarily pump the queued up
// afterwards.  Runtime evidence from VSCode PID 41954 showed the latter case:
// sendEvent(type=1) returned in 0.261 ms and no sendEvent(type=2) followed.
//
// Query the real AppKit queue for the exact prequeued up after down returns. If
// a nested tracker consumed it, the nonblocking query returns nil. Otherwise,
// remove and dispatch that same NSEvent immediately. eventNumber is unique in
// this process and prevents an unrelated release from being stolen. This keeps
// one coherent down/up pair for both consumers without app-specific actions or
// timing heuristics.
static void MacWSCompletePrequeuedAtomicUp(id application, id expectedEvent,
                                           NSUInteger upType) {
    if (!application || !expectedEvent || upType >= sizeof(NSUInteger) * 8)
        return;
    SEL nextSelector = sel_registerName(
        "nextEventMatchingMask:untilDate:inMode:dequeue:");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            nextSelector)) return;

    Class dateClass = objc_getClass("NSDate");
    Class runLoopClass = objc_getClass("NSRunLoop");
    id deadline = dateClass ? ((MacWSMsgID)objc_msgSend)(
        (id)dateClass, sel_registerName("distantPast")) : nil;
    id runLoop = runLoopClass ? ((MacWSMsgID)objc_msgSend)(
        (id)runLoopClass, sel_registerName("currentRunLoop")) : nil;
    id mode = runLoop ? ((MacWSMsgID)objc_msgSend)(
        runLoop, sel_registerName("currentMode")) : nil;
    if (!mode) {
        id *defaultMode = (id *)dlsym(RTLD_DEFAULT, "NSDefaultRunLoopMode");
        if (defaultMode) mode = *defaultMode;
    }
    if (!mode) mode = MacWSRuntimeString("kCFRunLoopDefaultMode");
    if (!deadline || !mode) return;

    id queuedEvent = ((MacWSNextEvent)objc_msgSend)(
        application, nextSelector, ((NSUInteger)1 << upType), deadline, mode,
        YES);
    if (!queuedEvent) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT ATOMIC-UP pid=%d type=%lu route=tracker-consumed\n",
                getpid(), (unsigned long)upType);
            fflush(stderr);
        }
        return;
    }

    NSInteger expectedNumber = ((MacWSMsgInteger)objc_msgSend)(
        expectedEvent, sel_registerName("eventNumber"));
    NSInteger queuedNumber = ((MacWSMsgInteger)objc_msgSend)(
        queuedEvent, sel_registerName("eventNumber"));
    if (queuedNumber != expectedNumber) {
        // The exact event was already consumed and an older same-button release
        // was the next match. Preserve that unrelated event at the queue head.
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), queuedEvent, YES);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT ATOMIC-UP pid=%d type=%lu "
                "route=unrelated-preserved expected=%ld actual=%ld\n",
                getpid(), (unsigned long)upType, (long)expectedNumber,
                (long)queuedNumber);
            fflush(stderr);
        }
        return;
    }

    ((MacWSSendEvent)objc_msgSend)(application,
        sel_registerName("sendEvent:"), queuedEvent);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT ATOMIC-UP pid=%d type=%lu "
            "route=queue-drain event=%ld\n",
            getpid(), (unsigned long)upType, (long)queuedNumber);
        fflush(stderr);
    }
}

// RE-confirmed against the macOS 13.4 AppKit binary loaded in VSCode on
// 2026-07-29. -[NSMenuPresentationInstance _doMenuEventLoop:inMode:] calls
// -[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:] at +0x13c,
// then passes that dequeued NSEvent to -handleEvent: at +0x250.  It does not
// route menu-tracking events through -[NSApplication sendEvent:].  Therefore
// an AppInput hover must enter NSApplication's real queue while a menu owns
// the nested tracker; synchronously calling sendEvent: cannot reach it.
static void MacWSMenuEventLoopWitness(id self, SEL command, BOOL track,
                                      id mode) {
    id previous = MacWSAppInputTrackingMenuPresentation;
    MacWSAppInputTrackingMenuPresentation = self;
    // This is the authoritative AppKit nested-event-loop boundary. Electron
    // can schedule a native menu after the originating leftMouseDown has
    // already returned, so button-specific prediction cannot cover it. Keep
    // the socket-side direct queue route active for the exact lifetime of
    // _doMenuEventLoop: itself; the cached transform still comes from the
    // real preceding target-window click.
    BOOL previousSynchronousTracking = atomic_exchange_explicit(
        &MacWSAppInputSynchronousTrackingActive, YES,
        memory_order_acq_rel);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-BEGIN pid=%d presentation=%s\n",
                getpid(), object_getClassName(self));
        fflush(stderr);
    }
    MacWSMenuEventLoop original = NULL;
    for (Class candidate = object_getClass(self); candidate && !original;
         candidate = class_getSuperclass(candidate)) {
        for (size_t index = 0; index < MacWSMenuEventLoopHookCount;
             index++) {
            if (MacWSMenuEventLoopHooks[index].ownerClass == candidate) {
                original = MacWSMenuEventLoopHooks[index].original;
                break;
            }
        }
    }
    if (original) original(self, command, track, mode);
    else {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-DROP pid=%d reason=no-original "
                "presentation=%s\n",
                getpid(), object_getClassName(self));
        fflush(stderr);
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-END pid=%d presentation=%s\n",
                getpid(), object_getClassName(self));
        fflush(stderr);
    }
    MacWSAppInputTrackingMenuPresentation = previous;
    atomic_store_explicit(&MacWSAppInputSynchronousTrackingActive,
                          previousSynchronousTracking,
                          memory_order_release);
}

static void MacWSInstallMenuEventLoopWitness(void) {
    SEL selector = sel_registerName("_doMenuEventLoop:inMode:");
    Class baseClass = objc_getClass("NSMenuPresentationInstance");
    if (!baseClass) {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-WITNESS unavailable "
                "base=NO\n");
        fflush(stderr);
        return;
    }

    // Hook the implementation on AppKit's presentation base class. Subclasses
    // inherit this method, so walking every registered Objective-C class is
    // unnecessary. More importantly, objc_getClassList() realizes Swift-backed
    // classes while an inserted dylib constructor is still running. Runtime-
    // confirmed with Office 16.91 Word on 2026-08-10: that global realization
    // entered OfficeArt's singleton metadata accessor before its image was
    // initialized and crashed at address 0. Targeting the RE-confirmed AppKit
    // owner keeps the menu event-loop invariant without touching unrelated app
    // classes.
    Method directMethod = class_getInstanceMethod(baseClass, selector);
    const char *types = directMethod
        ? method_getTypeEncoding(directMethod) : NULL;
    // Runtime-confirmed on macOS 13.4 as v28@0:8B16@20: void return,
    // BOOL, object. Keep this a load-bearing witness rather than installing a
    // guessed calling convention on another AppKit build.
    if (!directMethod || !types || strcmp(types, "v28@0:8B16@20") != 0) {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-WITNESS skip class=%s types=%s\n",
                class_getName(baseClass), types ?: "nil");
        fflush(stderr);
        return;
    }
    IMP implementation = method_getImplementation(directMethod);
    if (implementation != (IMP)MacWSMenuEventLoopWitness &&
        MacWSMenuEventLoopHookCount < 32) {
        MacWSMenuEventLoopHooks[MacWSMenuEventLoopHookCount++] =
            (MacWSMenuEventLoopHook){
                .ownerClass = baseClass,
                .original = (MacWSMenuEventLoop)implementation,
            };
        method_setImplementation(directMethod,
                                 (IMP)MacWSMenuEventLoopWitness);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                    "#### APP-INPUT MENU-TRACK-WITNESS hook class=%s types=%s\n",
                    class_getName(baseClass), types);
            fflush(stderr);
        }
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "#### APP-INPUT MENU-TRACK-WITNESS installed hooks=%zu\n",
                MacWSMenuEventLoopHookCount);
        fflush(stderr);
    }
}

static id MacWSActiveMenuPresentationInstance(void) {
    if (MacWSAppInputTrackingMenuPresentation)
        return MacWSAppInputTrackingMenuPresentation;

    Class menuPresentationClass =
        objc_getClass("NSMenuPresentationInstance");
    SEL activeSelector =
        sel_registerName("activeMenuPresentationInstance");
    if (menuPresentationClass && class_respondsToSelector(
            object_getClass(menuPresentationClass), activeSelector)) {
        id active = ((MacWSMsgID)objc_msgSend)(
            (id)menuPresentationClass, activeSelector);
        if (active) return active;
    }

    // macOS 13's menu bar uses a long-lived presentation subclass. Runtime
    // evidence on VSCode showed a visible File menu while the base class's
    // weak activeMenuPresentationInstance and NSApp.orderedWindows were both
    // empty of menu state. AppKit exposes the actual active bar through this
    // class method; require its own tracking flag so ordinary content hover
    // keeps the synchronous non-menu route.
    Class menuBarClass = objc_getClass("NSMenuBarPresentationInstance");
    SEL getActiveBar = sel_registerName("_getActiveMenuBar");
    if (!menuBarClass || !class_respondsToSelector(
            object_getClass(menuBarClass), getActiveBar)) return nil;
    id activeBar = ((MacWSMsgID)objc_msgSend)(
        (id)menuBarClass, getActiveBar);
    SEL handlingSelector = sel_registerName("isActivelyHandlingEvents");
    if (!activeBar || !((MacWSMsgBoolSEL)objc_msgSend)(
            activeBar, sel_registerName("respondsToSelector:"),
            handlingSelector)) return nil;
    return ((MacWSMsgBool)objc_msgSend)(activeBar, handlingSelector)
        ? activeBar : nil;
}

static id MacWSMenuBarPresentationInstance(void) {
    Class menuBarClass = objc_getClass("NSMenuBarPresentationInstance");
    SEL getActiveBar = sel_registerName("_getActiveMenuBar");
    if (!menuBarClass || !class_respondsToSelector(
            object_getClass(menuBarClass), getActiveBar)) return nil;
    return ((MacWSMsgID)objc_msgSend)((id)menuBarClass, getActiveBar);
}

static void MacWSOrderOutObservedMenuWindow(id application,
                                             NSInteger windowNumber) {
    if (!application || windowNumber <= 0) return;
    CFTypeRef retainedApplication = CFRetain((__bridge CFTypeRef)application);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            id app = (__bridge id)retainedApplication;
            (void)app;
            Class managerClass = objc_getClass("NSMenuWindowManager");
            SEL managerForWindow = sel_registerName("managerForWindowID:");
            id manager = managerClass && class_respondsToSelector(
                    object_getClass(managerClass), managerForWindow)
                ? ((MacWSMsgIDInteger)objc_msgSend)(
                    (id)managerClass, managerForWindow, windowNumber)
                : nil;
            SEL orderOut = sel_registerName("orderOut");
            BOOL canOrderOut = manager &&
                ((MacWSMsgBoolSEL)objc_msgSend)(
                    manager, sel_registerName("respondsToSelector:"),
                    orderOut);
            if (canOrderOut)
                ((MacWSMsgVoid)objc_msgSend)(manager, orderOut);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT KEY-MENU-UPDATE pid=%d "
                    "window=%ld manager=%s route=%s\n",
                    getpid(), (long)windowNumber,
                    manager ? object_getClassName(manager) : "nil",
                    canOrderOut ? "native-manager-order-out" : "no-manager");
                fflush(stderr);
            }
            CFRelease(retainedApplication);
        });
}

// RE-confirmed against macOS 13.4 HIToolbox on 2026-07-29:
// _CancelMenuTracking(immediate) supplies dismissal reason 8 and tail-calls
// _CancelMenuTracking2. That function reads HIToolbox's active tracking
// session, obtains its actual root MenuRef, and calls CancelMenuTracking.
// CancelMenuTracking marks the session cancelled and invokes QuitEventLoop,
// which is the native termination path for TrackMenuCommon. Schedule it on
// the main CFRunLoop because the API is explicitly not thread-safe and the
// AppInput Escape record normally arrives on the per-app socket thread.
static BOOL MacWSCancelCarbonMenuTrackingForEscape(id application,
                                                    NSInteger windowNumber) {
    static MacWSCancelMenuTrackingPrivate cancelMenuTracking;
    static dispatch_once_t cancelOnce;
    dispatch_once(&cancelOnce, ^{
        cancelMenuTracking = (MacWSCancelMenuTrackingPrivate)dlsym(
            RTLD_DEFAULT, "_CancelMenuTracking");
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT CARBON-MENU-CANCEL resolve=%p\n",
                (void *)cancelMenuTracking);
            fflush(stderr);
        }
    });
    if (!cancelMenuTracking) return NO;

    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    if (!mainRunLoop) return NO;
    CFRetain(mainRunLoop);
    CFTypeRef retainedApplication = application
        ? CFRetain((__bridge CFTypeRef)application) : NULL;
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, ^{
        int32_t status = cancelMenuTracking(1);
        id app = retainedApplication ? (__bridge id)retainedApplication : nil;
        MacWSOrderOutObservedMenuWindow(app, windowNumber);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT CARBON-MENU-CANCEL pid=%d window=%ld "
                "immediate=YES status=%d route=hitoolbox-active-tracker\n",
                getpid(), (long)windowNumber, status);
            fflush(stderr);
        }
        if (retainedApplication) CFRelease(retainedApplication);
        CFRelease(mainRunLoop);
    });
    CFRunLoopWakeUp(mainRunLoop);
    return YES;
}

// RE-confirmed against macOS 13.4 AppKit on 2026-07-29:
// -[NSMenuPresentationInstance _closeRootImplAnimated:] does not mutate menu
// state on its caller's thread. It retains self weakly, uses
// CFRunLoopPerformBlock on CFRunLoopGetMain, wakes the main loop when needed,
// and its block loads the root impl at presentation+0x8 and sends
// dismissAnimated:. This is AppKit's own cross-thread handoff into the full
// dismissal lifecycle (end notification, background-event cleanup, monitor
// teardown and timer invalidation), not a forced visibility/state setter.
static BOOL MacWSCancelActiveMenuForEscape(id application,
                                            NSInteger windowNumber,
                                            BOOL menuSurface) {
    // Context menus are tracked synchronously by NSCarbonMenuImpl. Hiding the
    // NSMenuWindowManager surface alone leaves rightMouseDown blocked inside
    // HIToolbox TrackMenuCommon, so subsequent clicks never reach AppKit.
    // Prefer HIToolbox's own active-session cancellation whenever the target
    // probe observed an exact NSMenuWindowManagerWindow.
    BOOL secondaryTracker = atomic_load_explicit(
        &MacWSAppInputSynchronousTrackingActive, memory_order_acquire);
    if ((menuSurface || secondaryTracker) &&
        MacWSCancelCarbonMenuTrackingForEscape(
            application, menuSurface ? windowNumber : 0)) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT KEY-MENU-CANCEL pid=%d window=%ld "
                "source=%s route=hitoolbox-active-tracker\n",
                getpid(), (long)windowNumber,
                menuSurface ? "menu-window" : "secondary-tracker");
            fflush(stderr);
        }
        return YES;
    }

    id presentation = MacWSActiveMenuPresentationInstance();
    const char *source = "active";
    // Runtime target probes can still see the owned NS*Menu*Window while this
    // chroot's Carbon tracker leaves isActivelyHandlingEvents false. In that
    // state +activeMenuPresentationInstance is nil, but the long-lived menu
    // bar presentation is the owner of the visible root submenu. Restrict
    // this fallback to an AppKit menu-class window observed on the main thread;
    // ordinary document/panel key events never take it.
    if (!presentation && menuSurface) {
        presentation = MacWSMenuBarPresentationInstance();
        source = "menu-window";
    }
    if (!presentation) return NO;
    SEL closeRoot = sel_registerName("_closeRootImplAnimated:");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            presentation, sel_registerName("respondsToSelector:"),
            closeRoot)) return NO;
    // Runtime-confirmed on the coexist AGX stack: animated=YES ends the menu
    // tracker (Terminal CPU drops from ~69% to idle) but the fade never
    // publishes its terminal frame; the old menu pixels remain until a later
    // click. AppKit ships cancelTrackingWithoutAnimation, whose macOS 13.4
    // implementation passes NO to the same cancellation family. Use that
    // native no-animation semantic for this VNC Escape route.
    ((MacWSMsgVoidBool)objc_msgSend)(presentation, closeRoot, NO);
    // Runtime-confirmed on the coexist AGX/VNC stack on 2026-07-29: the
    // semantic close above ends tracking but does not publish replacement
    // pixels for the ordered menu surface.  A/B runs with animated close,
    // no-animation close, and updateWindows all left the old pixels visible;
    // resolving the exact NSMenuWindowManager for the observed menu window
    // and invoking its native -orderOut closed the menu in 0.300 s and the
    // complete system-menu regression passed 5/5. RE-confirmed in macOS 13.4
    // AppKit, +managerForWindowID: enumerates live managers and matches their
    // real windowID, while -orderOut sends orderOut: to that manager's retained
    // window. Ordinary application windows can never enter this route.
    MacWSOrderOutObservedMenuWindow(application, windowNumber);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT KEY-MENU-CANCEL pid=%d presentation=%s "
            "window=%ld source=%s route=close-root-impl-no-animation\n",
            getpid(), object_getClassName(presentation), (long)windowNumber,
            source);
        fflush(stderr);
    }
    return YES;
}

static BOOL MacWSInputRecordIsValid(const MacWSInputRecord *record) {
    if (record->magic != MACWS_INPUT_MAGIC ||
        !MacWSInputVersionSupportsKind(record->version, record->kind) ||
        record->targetPID != getpid() ||
        record->frameWidth == 0 || record->frameHeight == 0 ||
        record->source > MacWSInputSourceMax ||
        !isfinite(record->x) || !isfinite(record->y) ||
        !isfinite(record->altitude) || !isfinite(record->azimuth) ||
        !isfinite(record->tiltX) || !isfinite(record->tiltY) ||
        record->tiltX < -1.0f || record->tiltX > 1.0f ||
        record->tiltY < -1.0f || record->tiltY > 1.0f) return NO;
    if (record->kind == MacWSInputKindConfigureWindow) {
        return MacWSInputWindowIDForScene(record->sceneID) != 0 &&
            record->x >= 64.0f && record->y >= 64.0f &&
            record->x <= MACWS_STREAM_MAX_DIMENSION &&
            record->y <= MACWS_STREAM_MAX_DIMENSION &&
            isfinite(record->pressure) &&
            record->pressure >= 0.5f && record->pressure <= 4.0f;
    }
    if (record->kind == MacWSInputKindCloseWindow) {
        return MacWSInputWindowIDForScene(record->sceneID) != 0;
    }
    if (record->kind == MacWSInputKindCreateInitialWindow) return YES;
    if (record->kind == MacWSInputKindReopenApplication) return YES;
    if (record->kind == MacWSInputKindOpenDocuments)
        return record->sceneID != 0;
    if (record->kind == MacWSInputKindPerformQuit) return YES;
    if (record->kind == MacWSInputKindRelativePointer) {
        return MacWSInputWindowIDForScene(record->sceneID) != 0 &&
            (record->source == MacWSInputSourceIndirectPointer ||
             record->source == MacWSInputSourceFinger) &&
            (record->flags & MacWSInputFlagGlobalSystemSurface) == 0 &&
            isfinite(record->pressure) && isfinite(record->altitude) &&
            fabsf(record->pressure) <= 4096.0f &&
            fabsf(record->altitude) <= 4096.0f &&
            record->x >= 0.0f && record->y >= 0.0f &&
            record->x < record->frameWidth &&
            record->y < record->frameHeight;
    }
    if (record->kind == MacWSInputKindDesktopCommand) {
        return record->contactID >= MacWSDesktopCommandSpaceLeft &&
            record->contactID <= MacWSDesktopCommandSpaceRight;
    }
    if (record->kind == MacWSInputKindScroll) {
        float horizontal = 0.0f;
        memcpy(&horizontal, &record->contactID, sizeof(horizontal));
        if (!isfinite(record->pressure) || !isfinite(horizontal) ||
            fabsf(record->pressure) > 16384.0f ||
            fabsf(horizontal) > 16384.0f) return NO;
    }
    if (record->kind == MacWSInputKindMagnify ||
        record->kind == MacWSInputKindRotate) {
        uint16_t phase = record->flags &
            (MacWSInputFlagGestureBegan | MacWSInputFlagGestureChanged |
             MacWSInputFlagGestureEnded | MacWSInputFlagGestureCancelled);
        float limit = record->kind == MacWSInputKindRotate ? 720.0f : 4.0f;
        if (!isfinite(record->pressure) || fabsf(record->pressure) > limit ||
            (phase != MacWSInputFlagGestureBegan &&
             phase != MacWSInputFlagGestureChanged &&
             phase != MacWSInputFlagGestureEnded &&
             phase != MacWSInputFlagGestureCancelled)) return NO;
    }
    if (record->kind == MacWSInputKindSystemGesture) {
        uint16_t phase = record->flags &
            (MacWSInputFlagGestureBegan | MacWSInputFlagGestureChanged |
             MacWSInputFlagGestureEnded | MacWSInputFlagGestureCancelled);
        if (!MacWSAppInputIsDockEndpoint() ||
            (record->flags & MacWSInputFlagGlobalSystemSurface) == 0 ||
            (record->buttons != MacWSSystemGestureAxisHorizontal &&
             record->buttons != MacWSSystemGestureAxisVertical) ||
            record->contactID == 0 || !isfinite(record->pressure) ||
            fabsf(record->pressure) > 2.0f ||
            fabsf(record->altitude) > 12.0f ||
            (phase != MacWSInputFlagGestureBegan &&
             phase != MacWSInputFlagGestureChanged &&
             phase != MacWSInputFlagGestureEnded &&
             phase != MacWSInputFlagGestureCancelled)) return NO;
    }
    return
        record->kind >= MacWSInputKindTouchDown &&
        record->kind <= MacWSInputKindPerformQuit &&
        record->x >= 0.0f && record->y >= 0.0f &&
        record->x < record->frameWidth &&
        record->y < record->frameHeight;
}

// Build the wheel event inside the selected AppKit process.  The central
// broker's CGEventPostToPid path is unavailable in this launchd session
// (runtime CGPreflightPostEventAccess=NO), which made two-finger scroll appear
// to be accepted while no target application received it.  A real
// CGEventCreateScrollWheelEvent still provides AppKit's native precise-delta
// fields; wrapping it as NSEvent and putting it on this application's own
// queue avoids the denied cross-process post without inventing a control
// action or changing the target window's state directly.
static id MacWSCreateAppScrollEvent(Class eventClass,
                                    MacWSInputRecord record,
                                    id window,
                                    CGPoint windowPoint,
                                    CGRect screenFrame,
                                    NSInteger windowNumber,
                                    BOOL encodeGesturePhases) {
    static MacWSCreateScrollWheelCGEvent createScroll;
    static MacWSCreateScrollWheelCGEvent2 createScroll2;
    static MacWSSetCGEventLocation setLocation;
    static MacWSSetCGEventFlags setFlags;
    static MacWSSetCGEventTimestamp setTimestamp;
    static MacWSSetCGEventIntegerField setInteger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createScroll = (MacWSCreateScrollWheelCGEvent)dlsym(
            RTLD_DEFAULT, "CGEventCreateScrollWheelEvent");
        createScroll2 = (MacWSCreateScrollWheelCGEvent2)dlsym(
            RTLD_DEFAULT, "CGEventCreateScrollWheelEvent2");
        setLocation = (MacWSSetCGEventLocation)dlsym(
            RTLD_DEFAULT, "CGEventSetLocation");
        setFlags = (MacWSSetCGEventFlags)dlsym(
            RTLD_DEFAULT, "CGEventSetFlags");
        setTimestamp = (MacWSSetCGEventTimestamp)dlsym(
            RTLD_DEFAULT, "CGEventSetTimestamp");
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
    });
    SEL eventWithCGEvent = sel_registerName("eventWithCGEvent:");
    if (!eventClass || (!createScroll2 && !createScroll) ||
        !class_respondsToSelector(object_getClass(eventClass),
                                  eventWithCGEvent)) return nil;

    float horizontalFloat = 0.0f;
    memcpy(&horizontalFloat, &record.contactID, sizeof(horizontalFloat));
    int32_t vertical = (int32_t)lrintf(record.pressure);
    int32_t horizontal = (int32_t)lrintf(horizontalFloat);
    // The fixed-arity API avoids a cross-image variadic ABI mismatch observed
    // here: the old call produced {deltaX=wheel1, deltaY=wheelCount} instead of
    // {deltaX=wheel2, deltaY=wheel1}. macOS has exported Event2 since 10.13;
    // keep the variadic form only as an older-runtime fallback.
    MacWSCGEventRef cgEvent = createScroll2
        ? createScroll2(NULL, 0 /* kCGScrollEventUnitPixel */, 2,
                        vertical, horizontal, 0)
        : createScroll(NULL, 0 /* kCGScrollEventUnitPixel */, 2,
                       vertical, horizontal);
    if (!cgEvent) return nil;
    if (setTimestamp && record.timestamp > 0.0)
        setTimestamp(cgEvent, (uint64_t)llround(record.timestamp * 1.0e9));
    // eventWithCGEvent: cannot associate a target NSWindow in this chroot even
    // after fields 91/92 are set (runtime windowNumber=0).  NSWindow's public
    // sendEvent: path therefore consumes the event below.  Encode the intended
    // window-local point in the CG wrapper so its locationInWindow is already
    // correct for that target instead of retaining a screen-space offset.
    CGPoint cgWindowPoint = {
        windowPoint.x,
        screenFrame.origin.y + screenFrame.size.height - windowPoint.y,
    };
    if (setLocation) setLocation(cgEvent, cgWindowPoint);
    if (setFlags) setFlags(cgEvent,
        MacWSInputModifiersForScene(record.sceneID));
    if (setInteger) {
        // CGEvent's private scroll fields consume CGScrollPhase, not
        // NSEventPhase.  The encodings diverge after Began:
        //   CGScrollPhase    Began/Changed/Ended/Cancelled = 1/2/4/8
        //   NSEventPhase     Began/Changed/Ended/Cancelled = 1/4/8/16
        // Runtime InputLab evidence on Ventura 13.4 was exact: writing the
        // old 1/4/8/16 sequence produced NSEvent phases 1/8/16, so every
        // Changed sample terminated the gesture and the final End became a
        // cancellation.  Encode the producer's semantic phase in the field's
        // actual ABI and let AppKit perform its normal CG -> NSEvent mapping.
        uint64_t scrollPhase = 0;
        uint64_t momentumPhase = 0;
        if (record.flags & MacWSInputFlagScrollBegan) {
            scrollPhase = 1;
            momentumPhase = 1; // kCGMomentumScrollPhaseBegin
        } else if (record.flags & MacWSInputFlagScrollChanged) {
            scrollPhase = 2;
            momentumPhase = 2; // kCGMomentumScrollPhaseContinue
        } else if (record.flags & (MacWSInputFlagScrollEnded |
                                   MacWSInputFlagScrollCancelled)) {
            scrollPhase = (record.flags & MacWSInputFlagScrollEnded) ? 4 : 8;
            momentumPhase = 3; // kCGMomentumScrollPhaseEnd
        }
        setInteger(cgEvent, 88 /* kCGScrollWheelEventIsContinuous */, 1);
        if (!encodeGesturePhases) {
            // Runtime-confirmed via
            // Finder-2026-09-08-113319.ips: a process-local phased event
            // enters NSScrollingBehaviorConcurrentVBL, whose
            // __NSScrollingConcurrentVBLMonitorGetWorkIntervalHandle block
            // aborts in this chroot before the collection view can scroll.
            // A covered native AppKit window cannot use the global system
            // route, so retain pixel deltas but present them as ordinary
            // continuous wheel samples. The Host still supplies the complete
            // finger and momentum delta stream; only AppKit's unavailable
            // concurrent-VBL session is omitted.
            setInteger(cgEvent, 99 /* kCGScrollWheelEventScrollPhase */, 0);
            setInteger(cgEvent, 123 /* ...MomentumPhase */, 0);
        } else if (record.flags & MacWSInputFlagScrollMomentum) {
            setInteger(cgEvent, 99 /* kCGScrollWheelEventScrollPhase */, 0);
            setInteger(cgEvent, 123 /* ...MomentumPhase */, momentumPhase);
        } else {
            setInteger(cgEvent, 99 /* kCGScrollWheelEventScrollPhase */,
                       scrollPhase);
            setInteger(cgEvent, 123 /* ...MomentumPhase */, 0);
        }
        if (windowNumber > 0) {
            setInteger(cgEvent, 91 /* kCGMouseEventWindowUnderMousePointer */,
                       windowNumber);
            setInteger(cgEvent,
                       92 /* ...WindowUnderMousePointerThatCanHandleThisEvent */,
                       windowNumber);
        }
    }
    id event = ((MacWSEventFromCGEvent)objc_msgSend)(
        (id)eventClass, eventWithCGEvent, cgEvent);
    CFRelease(cgEvent);
    if (!event) return nil;
    // Like the gesture family below, eventWithCGEvent: does not import fields
    // 91/92 into NSEvent's target-window state in this launchd/chroot session.
    // The public NSWindow dispatcher can geometrically recover an ordinary
    // finger scroll, but its inner momentum path requires the queue-associated
    // window that a hardware event normally carries. Resolve the named Ventura
    // ivars, fill that missing queue state, and reject the event unless both
    // public getters round-trip exactly; no responder or action is selected
    // here.
    Ivar windowIvar = class_getInstanceVariable(eventClass, "_window");
    Ivar windowNumberIvar = class_getInstanceVariable(
        eventClass, "_windowNumber");
    ptrdiff_t windowNumberOffset = windowNumberIvar
        ? ivar_getOffset(windowNumberIvar) : -1;
    size_t instanceSize = class_getInstanceSize(eventClass);
    const char *windowType = windowIvar
        ? ivar_getTypeEncoding(windowIvar) : NULL;
    const char *windowNumberType = windowNumberIvar
        ? ivar_getTypeEncoding(windowNumberIvar) : NULL;
    if (!window || windowNumber <= 0 || !windowIvar || !windowNumberIvar ||
        !windowType || windowType[0] != '@' || !windowNumberType ||
        windowNumberType[0] != 'q' || instanceSize < sizeof(NSInteger) ||
        windowNumberOffset < 0 ||
        (size_t)windowNumberOffset > instanceSize - sizeof(NSInteger))
        return nil;
    object_setIvar(event, windowIvar, window);
    memcpy((uint8_t *)(void *)event + windowNumberOffset,
           &windowNumber, sizeof(windowNumber));
    if (((MacWSMsgID)objc_msgSend)(event, sel_registerName("window")) !=
            window ||
        ((MacWSMsgInteger)objc_msgSend)(
            event, sel_registerName("windowNumber")) != windowNumber)
        return nil;
    return event;
}

// Construct the exact Ventura gesture event consumed by AppKit. Runtime and
// RE evidence for macOS 13.4:
//   * -[NSEvent _initWithCGEvent:eventRef:] maps CG type 29 field 110 values
//     61/8/62 to BeginGesture/Magnify/EndGesture and reads magnification from
//     field 113.
//   * SLEventRecordSetDoubleValue +104 accepts type 29; its field-113 jump
//     table stores float(amount) at SLSEventRecord+0xa4.
//   * The public CGEventSetDoubleValueField exported into this mixed runtime
//     silently leaves field 113 unchanged, while SLEventRecordPointer is
//     exported and returns the real 0xf8-byte record.
// This is target-private ABI encoding, not a check bypass: the resulting
// NSEvent is validated for both type and magnification before NSWindow sees it.
static id MacWSCreateAppGestureEvent(Class eventClass,
                                     MacWSInputRecord record,
                                     id window,
                                     CGPoint screenPoint,
                                     CGPoint windowPoint,
                                     CGRect screenFrame,
                                     NSInteger windowNumber) {
    static MacWSCreateCGEvent createEvent;
    static MacWSSetCGEventType setType;
    static MacWSSetCGEventLocation setLocation;
    static MacWSSetCGEventFlags setFlags;
    static MacWSSetCGEventTimestamp setTimestamp;
    static MacWSSetCGEventIntegerField setInteger;
    static MacWSSLEventRecordPointer recordPointer;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createEvent = (MacWSCreateCGEvent)dlsym(RTLD_DEFAULT,
                                                "CGEventCreate");
        setType = (MacWSSetCGEventType)dlsym(RTLD_DEFAULT,
                                             "CGEventSetType");
        setLocation = (MacWSSetCGEventLocation)dlsym(
            RTLD_DEFAULT, "CGEventSetLocation");
        setFlags = (MacWSSetCGEventFlags)dlsym(
            RTLD_DEFAULT, "CGEventSetFlags");
        setTimestamp = (MacWSSetCGEventTimestamp)dlsym(
            RTLD_DEFAULT, "CGEventSetTimestamp");
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
        recordPointer = (MacWSSLEventRecordPointer)dlsym(
            RTLD_DEFAULT, "SLEventRecordPointer");
    });
    SEL eventWithCGEvent = sel_registerName("eventWithCGEvent:");
    if (!eventClass || !createEvent || !setType || !setInteger ||
        !recordPointer ||
        !class_respondsToSelector(object_getClass(eventClass),
                                  eventWithCGEvent)) return nil;

    const uint32_t cgGestureType = 29;
    const uint32_t gestureKindField = 110;
    const uint32_t gestureIdentityField = 117;
    const uint32_t gesturePhaseField = 132;
    const uint32_t appKitWindowNumberField = 51;
    uint16_t phaseFlags = record.flags &
        (MacWSInputFlagGestureBegan | MacWSInputFlagGestureChanged |
         MacWSInputFlagGestureEnded | MacWSInputFlagGestureCancelled);
    // SLSEventRecord field 132 stores CGGesturePhase (1/2/4/8), not the
    // numerically different NSEventPhase (1/4/8/16). NSEvent's initializer
    // performs that conversion when it wraps the record.
    uint64_t phase = phaseFlags == MacWSInputFlagGestureBegan ? 1 :
        phaseFlags == MacWSInputFlagGestureChanged ? 2 :
        phaseFlags == MacWSInputFlagGestureEnded ? 4 : 8;
    // AppKit's default `NSEventSuppressBeginEndGesture` is true. RE of
    // -[NSWindow _reallySendEvent:isDelayedEvent:] therefore shows type 19/20
    // returning before responder selection, while the type-30 magnify handler
    // uses phase==Began to establish its latched responder and consumes later
    // Changed/Ended samples from that same event family. Keep type 30 for the
    // complete lifecycle; phase, not a separate event type, is the state
    // machine used by native magnification.
    // The checked-in IOKit IOHIDEventTypes.h defines Rotation=5 and Zoom=8.
    // Rotation's scalar is only admitted after the actual Ventura NSEvent
    // wrapper below round-trips it as type 18 and -rotation; a mismatched
    // private layout therefore fails closed instead of reaching NSWindow.
    BOOL rotation = record.kind == MacWSInputKindRotate;
    int64_t gestureKind = rotation ? 5 : 8;

    MacWSCGEventRef cgEvent = createEvent(NULL);
    if (!cgEvent) return nil;
    setType(cgEvent, cgGestureType);
    setInteger(cgEvent, gestureKindField, gestureKind);
    setInteger(cgEvent, gestureIdentityField,
               record.contactID ? record.contactID :
                   (rotation ? 0x524f5441u : 0x50494e43u));
    setInteger(cgEvent, gesturePhaseField, (int64_t)phase);
    if (windowNumber > 0) {
        // RE-confirmed via Ventura AppKit's
        // -[NSEvent _initWithCGEvent:eventRef:] at +0x88: field 0x33 is
        // passed to -[NSApplication windowWithWindowNumber:]. When it names
        // a real window, +0x130 calls through that window's _cgsWindow to
        // convert the global CG location into the local coordinates stored at
        // NSEvent+0x8. Fields 91/92 alone are not consulted by this path in
        // the mixed runtime and left the screen origin in locationInWindow.
        setInteger(cgEvent, appKitWindowNumberField, windowNumber);
        setInteger(cgEvent, 91, windowNumber);
        setInteger(cgEvent, 92, windowNumber);
    }
    if (setTimestamp && record.timestamp > 0.0)
        setTimestamp(cgEvent, (uint64_t)llround(record.timestamp * 1.0e9));
    // CGEventSetLocation consumes global Quartz coordinates. RE-confirmed via
    // Ventura AppKit's _routeRotateEvent: phase Began reads locationInWindow
    // and passes it to the window border view's hitTest:. Runtime LLDB before
    // the target-window field above was restored observed (512,244.5) and a
    // nil hit; after it was restored, AppKit's initializer performed its own
    // global-to-window conversion. Supply the already-resolved global point
    // and validate the resulting local point below.
    CGPoint cgScreenPoint = {
        screenPoint.x,
        screenFrame.origin.y + screenFrame.size.height - screenPoint.y,
    };
    if (setLocation) setLocation(cgEvent, cgScreenPoint);
    if (setFlags) setFlags(cgEvent,
        MacWSInputModifiersForScene(record.sceneID));

    void *eventRecord = recordPointer(cgEvent);
    uint32_t encodedType = 0;
    if (eventRecord) memcpy(&encodedType, (uint8_t *)eventRecord + 0x8,
                            sizeof(encodedType));
    if (!eventRecord || encodedType != cgGestureType) {
        CFRelease(cgEvent);
        return nil;
    }
    float encodedAmount = phaseFlags == MacWSInputFlagGestureChanged
        ? record.pressure : 0.0f;
    memcpy((uint8_t *)eventRecord + 0xa4, &encodedAmount,
           sizeof(encodedAmount));

    id event = ((MacWSEventFromCGEvent)objc_msgSend)(
        (id)eventClass, eventWithCGEvent, cgEvent);
    CFRelease(cgEvent);
    if (!event) return nil;
    NSUInteger eventType = ((MacWSMsgUInteger)objc_msgSend)(
        event, sel_registerName("type"));
    NSUInteger expectedType = rotation ? 18 : 30;
    if (eventType != expectedType) return nil;
    // NSEvent's public ABI is deliberately asymmetric here: magnification is
    // CGFloat (double on arm64), while rotation is float. Runtime-confirmed on
    // the installed Ventura AppKit: -rotation returned the encoded 2.0 bits in
    // s0 (0x40000000); reading d0 produced 5.3049894774131808e-315 and made
    // every non-zero Changed event fail this equivalence check.
    double observed = rotation
        ? (double)((MacWSMsgFloat)objc_msgSend)(
              event, sel_registerName("rotation"))
        : ((MacWSMsgDouble)objc_msgSend)(
              event, sel_registerName("magnification"));
    if (!isfinite(observed) || fabs(observed - encodedAmount) > 0.0005)
        return nil;
    // `eventWithCGEvent:` in this macOS-on-iOS runtime does not import CG
    // fields 91/92 into NSEvent's window association. Runtime InputLab
    // evidence was exact: every otherwise-valid gesture had windowNumber=0,
    // so NSApplication.sendEvent: could not select a responder. Objective-C
    // runtime inspection of the actual Ventura 13.4 NSEvent found `_window`
    // at +0x20 and `_windowNumber` at +0x28. Resolve the named ivars instead
    // of baking those offsets, fill the same state AppKit's event queue would,
    // and validate through public getters before allowing dispatch.
    Ivar windowIvar = class_getInstanceVariable(eventClass, "_window");
    Ivar windowNumberIvar = class_getInstanceVariable(
        eventClass, "_windowNumber");
    ptrdiff_t windowNumberOffset = windowNumberIvar
        ? ivar_getOffset(windowNumberIvar) : -1;
    size_t instanceSize = class_getInstanceSize(eventClass);
    const char *windowType = windowIvar
        ? ivar_getTypeEncoding(windowIvar) : NULL;
    const char *windowNumberType = windowNumberIvar
        ? ivar_getTypeEncoding(windowNumberIvar) : NULL;
    if (!window || windowNumber <= 0 || !windowIvar ||
        !windowNumberIvar || !windowType || windowType[0] != '@' ||
        !windowNumberType || windowNumberType[0] != 'q' ||
        instanceSize < sizeof(NSInteger) || windowNumberOffset < 0 ||
        (size_t)windowNumberOffset > instanceSize - sizeof(NSInteger))
        return nil;
    object_setIvar(event, windowIvar, window);
    memcpy((uint8_t *)(void *)event + windowNumberOffset,
           &windowNumber, sizeof(windowNumber));
    id observedWindow = ((MacWSMsgID)objc_msgSend)(
        event, sel_registerName("window"));
    NSInteger observedWindowNumber = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("windowNumber"));
    CGPoint observedPoint = ((MacWSMsgPoint)objc_msgSend)(
        event, sel_registerName("locationInWindow"));
    BOOL routeEquivalent = observedWindow == window &&
        observedWindowNumber == windowNumber &&
        isfinite(observedPoint.x) && isfinite(observedPoint.y) &&
        fabs(observedPoint.x - windowPoint.x) <= 2.0 &&
        fabs(observedPoint.y - windowPoint.y) <= 2.0;
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT GESTURE-ROUTE pid=%d window=%ld->%ld "
            "local=(%.2f,%.2f)->(%.2f,%.2f) equivalent=%s\n",
            getpid(), (long)windowNumber, (long)observedWindowNumber,
            windowPoint.x, windowPoint.y, observedPoint.x, observedPoint.y,
            routeEquivalent ? "YES" : "NO");
        fflush(stderr);
    }
    if (!routeEquivalent) return nil;
    return event;
}

// Diagnostic probe: build an ordinary CoreGraphics mouse record inside the
// selected process, attach target-window fields, then wrap it as an NSEvent.
// Runtime InputLab evidence on 2026-07-31 shows macOS 13.4 in this chroot
// discards those fields (windowNumber=0 and screen-space location), so the
// strict equivalence check deliberately rejects it and production does not
// pay this probe's cost. No cross-process/global event post occurs.
static id MacWSCreateAppMouseEvent(Class eventClass,
                                   MacWSInputRecord record,
                                   NSUInteger eventType,
                                   CGPoint screenPoint,
                                   CGPoint expectedWindowPoint,
                                   CGRect screenFrame,
                                   NSInteger windowNumber) {
    static MacWSCreateMouseCGEvent createMouse;
    static MacWSSetCGEventFlags setFlags;
    static MacWSSetCGEventIntegerField setInteger;
    static MacWSSetCGEventDoubleField setDouble;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createMouse = (MacWSCreateMouseCGEvent)dlsym(
            RTLD_DEFAULT, "CGEventCreateMouseEvent");
        setFlags = (MacWSSetCGEventFlags)dlsym(
            RTLD_DEFAULT, "CGEventSetFlags");
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
        setDouble = (MacWSSetCGEventDoubleField)dlsym(
            RTLD_DEFAULT, "CGEventSetDoubleValueField");
    });
    SEL eventWithCGEvent = sel_registerName("eventWithCGEvent:");
    if (!eventClass || !createMouse || !setInteger ||
        !class_respondsToSelector(object_getClass(eventClass),
                                  eventWithCGEvent)) return nil;

    BOOL secondary = eventType == 3 || eventType == 4 || eventType == 7;
    CGPoint cgPoint = {
        screenPoint.x,
        screenFrame.origin.y + screenFrame.size.height - screenPoint.y,
    };
    MacWSCGEventRef cgEvent = createMouse(
        NULL, (uint32_t)eventType, cgPoint, secondary ? 1u : 0u);
    if (!cgEvent) return nil;
    if (setFlags) setFlags(cgEvent,
        MacWSInputModifiersForScene(record.sceneID));
    setInteger(cgEvent, 1 /* kCGMouseEventClickState */,
               (record.flags & MacWSInputFlagDoubleClick) ? 2 : 1);
    setInteger(cgEvent, 3 /* kCGMouseEventButtonNumber */,
               secondary ? 1 : 0);
    if (windowNumber > 0) {
        setInteger(cgEvent, 91 /* kCGMouseEventWindowUnderMousePointer */,
                   windowNumber);
        setInteger(cgEvent,
                   92 /* ...WindowUnderMousePointerThatCanHandleThisEvent */,
                   windowNumber);
    }
    if (setDouble && (eventType == 1 || eventType == 3 ||
                      eventType == 6 || eventType == 7)) {
        setDouble(cgEvent, 2 /* kCGMouseEventPressure */,
                  record.pressure > 0.0f ? record.pressure : 1.0f);
    }
    id event = ((MacWSEventFromCGEvent)objc_msgSend)(
        (id)eventClass, eventWithCGEvent, cgEvent);
    CFRelease(cgEvent);
    if (!event) return nil;
    NSInteger actualWindow = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("windowNumber"));
    CGPoint actualPoint = ((MacWSMsgPoint)objc_msgSend)(
        event, sel_registerName("locationInWindow"));
    BOOL equivalent = actualWindow == windowNumber &&
        fabs(actualPoint.x - expectedWindowPoint.x) <= 2.0 &&
        fabs(actualPoint.y - expectedWindowPoint.y) <= 2.0;
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT CG-MOUSE pid=%d type=%lu window=%ld->%ld "
            "local=(%.2f,%.2f)->(%.2f,%.2f) equivalent=%s\n",
            getpid(), (unsigned long)eventType, (long)windowNumber,
            (long)actualWindow, expectedWindowPoint.x,
            expectedWindowPoint.y, actualPoint.x, actualPoint.y,
            equivalent ? "YES" : "NO");
        fflush(stderr);
    }
    return equivalent ? event : nil;
}

// Build the pointer-locked mouseMoved event from the raw GameController
// counts supplied by the iOS Host.  Field 51 is the Ventura AppKit target
// window field (RE-confirmed in -[NSEvent _initWithCGEvent:eventRef:]); fields
// 4/5 are CoreGraphics' signed mouse delta fields.  The resulting public
// NSEvent getters and named target ivars are validated before dispatch, so an
// unknown AppKit layout fails closed instead of degrading into an absolute or
// global cursor event.
static id MacWSCreateAppRelativePointerEvent(Class eventClass,
                                             MacWSInputRecord record,
                                             id window,
                                             CGPoint screenPoint,
                                             CGPoint windowPoint,
                                             CGRect screenFrame,
                                             NSInteger windowNumber) {
    static MacWSCreateMouseCGEvent createMouse;
    static MacWSSetCGEventFlags setFlags;
    static MacWSSetCGEventTimestamp setTimestamp;
    static MacWSSetCGEventIntegerField setInteger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createMouse = (MacWSCreateMouseCGEvent)dlsym(
            RTLD_DEFAULT, "CGEventCreateMouseEvent");
        setFlags = (MacWSSetCGEventFlags)dlsym(
            RTLD_DEFAULT, "CGEventSetFlags");
        setTimestamp = (MacWSSetCGEventTimestamp)dlsym(
            RTLD_DEFAULT, "CGEventSetTimestamp");
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
    });
    SEL eventWithCGEvent = sel_registerName("eventWithCGEvent:");
    if (!eventClass || !window || windowNumber <= 0 || !createMouse ||
        !setInteger || !class_respondsToSelector(
            object_getClass(eventClass), eventWithCGEvent)) return nil;

    CGPoint cgPoint = {
        screenPoint.x,
        screenFrame.origin.y + screenFrame.size.height - screenPoint.y,
    };
    MacWSCGEventRef cgEvent = createMouse(
        NULL, 5 /* kCGEventMouseMoved */, cgPoint, 0);
    if (!cgEvent) return nil;
    setInteger(cgEvent, 4 /* kCGMouseEventDeltaX */,
               (int64_t)llround(record.pressure));
    setInteger(cgEvent, 5 /* kCGMouseEventDeltaY */,
               (int64_t)llround(record.altitude));
    setInteger(cgEvent, 51 /* AppKit window number */, windowNumber);
    setInteger(cgEvent, 91 /* kCGMouseEventWindowUnderMousePointer */,
               windowNumber);
    setInteger(cgEvent,
               92 /* ...WindowUnderMousePointerThatCanHandleThisEvent */,
               windowNumber);
    if (setFlags) setFlags(cgEvent,
        MacWSInputModifiersForScene(record.sceneID));
    if (setTimestamp && record.timestamp > 0.0)
        setTimestamp(cgEvent, (uint64_t)llround(record.timestamp * 1.0e9));
    id event = ((MacWSEventFromCGEvent)objc_msgSend)(
        (id)eventClass, eventWithCGEvent, cgEvent);
    CFRelease(cgEvent);
    if (!event) return nil;

    Ivar windowIvar = class_getInstanceVariable(eventClass, "_window");
    Ivar windowNumberIvar = class_getInstanceVariable(
        eventClass, "_windowNumber");
    ptrdiff_t windowNumberOffset = windowNumberIvar
        ? ivar_getOffset(windowNumberIvar) : -1;
    size_t instanceSize = class_getInstanceSize(eventClass);
    const char *windowType = windowIvar
        ? ivar_getTypeEncoding(windowIvar) : NULL;
    const char *windowNumberType = windowNumberIvar
        ? ivar_getTypeEncoding(windowNumberIvar) : NULL;
    if (!windowIvar || !windowNumberIvar || !windowType ||
        windowType[0] != '@' || !windowNumberType ||
        windowNumberType[0] != 'q' || instanceSize < sizeof(NSInteger) ||
        windowNumberOffset < 0 ||
        (size_t)windowNumberOffset > instanceSize - sizeof(NSInteger))
        return nil;
    object_setIvar(event, windowIvar, window);
    memcpy((uint8_t *)(void *)event + windowNumberOffset,
           &windowNumber, sizeof(windowNumber));

    id observedWindow = ((MacWSMsgID)objc_msgSend)(
        event, sel_registerName("window"));
    NSInteger observedWindowNumber = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("windowNumber"));
    CGPoint observedPoint = ((MacWSMsgPoint)objc_msgSend)(
        event, sel_registerName("locationInWindow"));
    double observedDX = ((MacWSMsgDouble)objc_msgSend)(
        event, sel_registerName("deltaX"));
    double observedDY = ((MacWSMsgDouble)objc_msgSend)(
        event, sel_registerName("deltaY"));
    BOOL equivalent = observedWindow == window &&
        observedWindowNumber == windowNumber &&
        isfinite(observedPoint.x) && isfinite(observedPoint.y) &&
        fabs(observedPoint.x - windowPoint.x) <= 2.0 &&
        fabs(observedPoint.y - windowPoint.y) <= 2.0 &&
        isfinite(observedDX) && isfinite(observedDY) &&
        fabs(observedDX - record.pressure) <= 0.5 &&
        fabs(observedDY - record.altitude) <= 0.5;
    if (MacWSGamePointerDiagnosticsEnabled()) {
        static _Atomic uint64_t relativeEvents;
        uint64_t sequence = atomic_fetch_add_explicit(
            &relativeEvents, 1, memory_order_relaxed) + 1;
        if (sequence <= 4 || (sequence % 240) == 0) {
            fprintf(stderr,
                "#### APP-INPUT RELATIVE-CREATE pid=%d event=%llu "
                "window=%ld->%ld delta=(%.0f,%.0f)->(%.0f,%.0f) "
                "local=(%.2f,%.2f)->(%.2f,%.2f) equivalent=%s\n",
                getpid(), (unsigned long long)sequence,
                (long)windowNumber, (long)observedWindowNumber,
                record.pressure, record.altitude, observedDX, observedDY,
                windowPoint.x, windowPoint.y, observedPoint.x,
                observedPoint.y, equivalent ? "YES" : "NO");
            fflush(stderr);
        }
    }
    return equivalent ? event : nil;
}

// System pointer owner for the native Host. A process-local NSEvent reaches
// ordinary NSViews but never enters HIToolbox's Carbon menu chain. Runtime A/B
// in VSCode proved the complete boundary:
//   * CGEventPost and NSApplication.sendEvent: both left the real level-101
//     NSMenuWindowManagerWindow open;
//   * CGPostMouseEvent from that AppKit/CGS-connected process returned 0/0,
//     selected the same menu point, and removed the transient window;
//   * the exact installed OSXvnc implementation calls this same API at
//     __TEXT+0x9f24.
// Keep one owner for every Host pointer transition and let WindowServer/AppKit
// perform ordinary hit testing, tracking, dragging, popup dismissal and Carbon
// menu dispatch. AppInput remains the control plane for target selection and
// the missing activation lifecycle; it no longer fabricates component-local
// mouse events when this proven system route is available.
static MacWSPostLegacyMouseEvent MacWSLegacySystemMousePoster(void) {
    static MacWSPostLegacyMouseEvent postMouse;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        postMouse = (MacWSPostLegacyMouseEvent)dlsym(
            RTLD_DEFAULT, "CGPostMouseEvent");
        if (!postMouse) {
            void *coreGraphics = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                RTLD_LAZY | RTLD_LOCAL);
            if (coreGraphics) postMouse = (MacWSPostLegacyMouseEvent)dlsym(
                coreGraphics, "CGPostMouseEvent");
        }
    });
    return postMouse;
}

// Catalyst and Electron own process-local scrolling implementations and accept
// the precise pixel NSEvent built below. Native AppKit must use its connected
// WindowServer route when possible: Finder-2026-09-08-113319.ips records the
// alternative phased local event entering NSScrollingBehaviorConcurrentVBL
// and aborting while creating its unavailable work-interval handle. SwiftUI
// has an additional compatibility requirement: a System Settings runtime A/B
// reached NSWindow.sendEvent: without moving the hosted content, whereas the
// WindowServer route moved it.
static BOOL MacWSClassUsesSwiftUI(Class cls, const char **matchedClass,
                                  const char **matchedImage) {
    for (unsigned depth = 0; cls && depth < 32;
         cls = class_getSuperclass(cls), depth++) {
        const char *name = class_getName(cls);
        const char *image = class_getImageName(cls);
        BOOL swiftUI =
            (image && strstr(image, "/SwiftUI.framework/") != NULL) ||
            (name && (strstr(name, "NSHostingView") != NULL ||
                      strstr(name, "SwiftUI") != NULL));
        if (!swiftUI) continue;
        if (matchedClass) *matchedClass = name;
        if (matchedImage) *matchedImage = image;
        return YES;
    }
    return NO;
}

static BOOL MacWSWindowPointRequiresSystemScroll(id window,
                                                  CGPoint windowPoint,
                                                  BOOL diagnostic,
                                                  BOOL *usesSwiftUIOut) {
    if (usesSwiftUIOut) *usesSwiftUIOut = NO;
    if (!window) return NO;
    id contentView = ((MacWSMsgID)objc_msgSend)(
        window, sel_registerName("contentView"));
    id hitView = nil;
    if (contentView && ((MacWSMsgBoolSEL)objc_msgSend)(
            contentView, sel_registerName("respondsToSelector:"),
            sel_registerName("hitTest:"))) {
        CGPoint contentPoint = ((MacWSMsgPointPointID)objc_msgSend)(
            contentView, sel_registerName("convertPoint:fromView:"),
            windowPoint, nil);
        hitView = ((MacWSMsgIDPoint)objc_msgSend)(
            contentView, sel_registerName("hitTest:"), contentPoint);
    }

    const char *matchedClass = NULL;
    const char *matchedImage = NULL;
    id view = hitView ?: contentView;
    Class nativeViewClass = objc_getClass("NSView");
    BOOL hasNativeAppKitTarget = view && nativeViewClass &&
        ((MacWSMsgBoolID)objc_msgSend)(
            view, sel_registerName("isKindOfClass:"),
            (id)nativeViewClass);
    unsigned viewsScanned = 0;
    BOOL usesSwiftUI = NO;
    while (view && viewsScanned < 64) {
        viewsScanned++;
        if (MacWSClassUsesSwiftUI(object_getClass(view), &matchedClass,
                                  &matchedImage)) {
            usesSwiftUI = YES;
            break;
        }
        SEL superviewSelector = sel_registerName("superview");
        if (!((MacWSMsgBoolSEL)objc_msgSend)(
                view, sel_registerName("respondsToSelector:"),
                superviewSelector)) break;
        view = ((MacWSMsgID)objc_msgSend)(view, superviewSelector);
    }
    if (usesSwiftUIOut) *usesSwiftUIOut = usesSwiftUI;
    if (diagnostic || MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT SCROLL-CAPABILITY pid=%d window=%ld "
            "window-class=%s hit-class=%s route=%s matched-class=%s "
            "matched-image=%s boundary=%s ancestry-scanned=%u\n",
            getpid(),
            (long)((MacWSMsgInteger)objc_msgSend)(
                window, sel_registerName("windowNumber")),
            object_getClassName(window),
            hitView ? object_getClassName(hitView) : "none",
            hasNativeAppKitTarget
                ? "CGPostScrollWheelEvent"
                : "NSWindow.sendEvent-discrete-fallback",
            matchedClass ?: "none", matchedImage ?: "none",
            usesSwiftUI ? "SwiftUI" : "AppKit", viewsScanned);
        fflush(stderr);
    }
    return hasNativeAppKitTarget;
}

static BOOL MacWSWindowPointUsesProcessLocalPreciseScroll(
        id window, CGPoint windowPoint) {
    if (MacWSCatalystWindowUsesProcessLocalInputAtPoint(
            window, windowPoint)) return YES;
    Class electronWindowClass = objc_getClass("ElectronNSWindow");
    return window && electronWindowClass &&
        ((MacWSMsgBoolID)objc_msgSend)(
            window, sel_registerName("isKindOfClass:"),
            (id)electronWindowClass);
}

static BOOL MacWSWindowUsesElectronPreciseScroll(id window) {
    Class electronWindowClass = objc_getClass("ElectronNSWindow");
    return window && electronWindowClass &&
        ((MacWSMsgBoolID)objc_msgSend)(
            window, sel_registerName("isKindOfClass:"),
            (id)electronWindowClass);
}

// CGEventPost of a pixel-unit event is the ideal route and is exactly what the
// installed OSXvnc binary uses. Runtime on VSCode PID 64433 nevertheless
// proved that Electron's target process can construct/post that event while
// Chromium receives zero wheel events (its event-post preflight is denied).
// The older CGPostScrollWheelEvent still reaches WindowServer from this same
// CGS-connected process, but Apple's CGRemoteOperation.h defines its arguments
// as small integral *wheel movement* rather than pixels. Convert the Host's
// 120-Hz logical-point stream into those units with a per-gesture residual.
//
// The distinction is also RE-confirmed in OSXvnc's handleMouseButtons: at
// docs/evidence/vnc-usability-stability-20260729/
// osxvnc-handle-mouse-arm64-disasm.txt: its default wheel step is w22=10 and
// its generated CGEvent is explicitly kCGScrollEventUnitPixel. That value
// cannot be copied into CGPostScrollWheelEvent, whose unit is instead measured
// at the application boundary below.
static BOOL MacWSPostSystemScrollEvent(
        MacWSInputRecord record, CGPoint screenPoint, CGRect screenFrame,
        id window, CGPoint windowPoint, NSInteger windowNumber,
        NSInteger globalWindowNumber) {
    // Electron's renderer consumes the ordinary process-local precise NSEvent
    // path below. Runtime CDP on VSCode PID 65571 measured the remote wheel
    // fallback at 240 CSS px for six 10-point samples (4x the finger travel),
    // while the window-local event preserves unit=pixel and native phases.
    // Select by framework capability/class, not bundle ID, so every Electron
    // application receives the same coherent input contract. All ordinary
    // AppKit windows use the real WindowServer wheel route when the global hit
    // test identifies this exact window. Runtime on Activity Monitor pid
    // 60424 proved that its process-local NSWindow.sendEvent: accepted every
    // phase at the correct point while the NSTableView did not move. The same
    // CGPostScrollWheelEvent route already restored System Settings' SwiftUI
    // scroll boundary, and the exact global-window equality below prevents it
    // from escaping into a covered or stale scene.
    // Mac Catalyst's real client-area owner is the process-local UINS view
    // hierarchy, just like Electron's renderer. Sending that content through
    // CGPostScrollWheelEvent quantizes 40 logical pixels into one legacy wheel
    // unit; Weather consequently moved much less than the same gesture in
    // VSCode. The existing generic Catalyst policy identifies only the client
    // area, so title bars and every native AppKit window retain the proven
    // WindowServer route while Catalyst receives the precise pixel NSEvent.
    if (MacWSWindowPointUsesProcessLocalPreciseScroll(
            window, windowPoint)) return NO;
    if (!window) return NO;
    static MacWSPostLegacyScrollEvent postScroll;
    static dispatch_once_t onceToken;
    static NSInteger activeWindowNumber;
    static double horizontalPixelResidual;
    static double verticalPixelResidual;
    static NSInteger capabilityWindowNumber;
    static BOOL capabilityUsesSystemRoute;
    static BOOL capabilityUsesSwiftUIBoundary;
    dispatch_once(&onceToken, ^{
        postScroll = (MacWSPostLegacyScrollEvent)dlsym(
            RTLD_DEFAULT, "CGPostScrollWheelEvent");
        if (!postScroll) {
            void *coreGraphics = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                RTLD_LAZY | RTLD_LOCAL);
            if (coreGraphics) postScroll =
                (MacWSPostLegacyScrollEvent)dlsym(
                    coreGraphics, "CGPostScrollWheelEvent");
        }
    });
    if (!postScroll || record.source == MacWSInputSourceVNC ||
        windowNumber <= 0) return NO;
    BOOL began = (record.flags & MacWSInputFlagScrollBegan) != 0;
    BOOL terminal = (record.flags & (MacWSInputFlagScrollEnded |
                                      MacWSInputFlagScrollCancelled)) != 0;
    if (began || capabilityWindowNumber != windowNumber) {
        capabilityWindowNumber = windowNumber;
        capabilityUsesSystemRoute = MacWSWindowPointRequiresSystemScroll(
            window, windowPoint,
            record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC,
            &capabilityUsesSwiftUIBoundary);
    }
    if (!capabilityUsesSystemRoute) {
        if (terminal) capabilityWindowNumber = 0;
        return NO;
    }
    if (began) {
        activeWindowNumber = 0;
        horizontalPixelResidual = 0.0;
        verticalPixelResidual = 0.0;
        if (globalWindowNumber != windowNumber) return NO;
        activeWindowNumber = windowNumber;
        MacWSPostLegacyMouseEvent postMouse = MacWSLegacySystemMousePoster();
        if (postMouse) {
            CGPoint quartzPoint = {
                screenPoint.x,
                screenFrame.origin.y + screenFrame.size.height - screenPoint.y,
            };
            // Button-free pointer motion synchronizes WindowServer's wheel
            // hit point without exposing its independently hidden cursor.
            (void)postMouse(quartzPoint, true, 3, false, false, false);
        }
    }
    if (activeWindowNumber != windowNumber) return NO;

    float horizontalFloat = 0.0f;
    memcpy(&horizontalFloat, &record.contactID, sizeof(horizontalFloat));
    // This variadic legacy API reports line-like units, and the receiving
    // framework chooses their pixel extent. Runtime screen A/B on the exact
    // Ventura build measured one unit as roughly 7-10 visible pixels in
    // Finder's TIconCollectionView, while System Settings' SwiftUI sidebar
    // retains the separately measured 40-logical-pixel unit. Keeping those
    // framework calibrations distinct restores roughly 1:1 finger travel in
    // native AppKit without making the SwiftUI sidebar jump several rows per
    // sample. Catalyst/Electron never enter this quantized route.
    const double pixelsPerWheelUnit = capabilityUsesSwiftUIBoundary
        ? 40.0 : 10.0;
    horizontalPixelResidual += horizontalFloat;
    verticalPixelResidual += record.pressure;
    int32_t horizontal = (int32_t)trunc(
        horizontalPixelResidual / pixelsPerWheelUnit);
    int32_t vertical = (int32_t)trunc(
        verticalPixelResidual / pixelsPerWheelUnit);
    // The API contract warns that large values have application-dependent
    // results. Bound one 120-Hz delivery to its documented normal range and
    // retain the unconsumed distance for the next sample.
    horizontal = MAX(-10, MIN(10, horizontal));
    vertical = MAX(-10, MIN(10, vertical));
    horizontalPixelResidual -= horizontal * pixelsPerWheelUnit;
    verticalPixelResidual -= vertical * pixelsPerWheelUnit;
    int32_t result = 0;
    if (vertical != 0 || horizontal != 0) {
        result = horizontal != 0
            ? postScroll(2, vertical, horizontal)
            : postScroll(1, vertical);
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT SYSTEM-SCROLL pid=%d window=%ld "
            "pixel=(%.3f,%.3f) wheel=(%d,%d) residual=(%.3f,%.3f) "
            "phase=%#x unit-pixels=%.1f boundary=%s result=%d "
            "route=CGPostScrollWheelEvent\n",
            getpid(), (long)windowNumber, horizontalFloat, record.pressure,
            horizontal, vertical, horizontalPixelResidual,
            verticalPixelResidual, record.flags, pixelsPerWheelUnit,
            capabilityUsesSwiftUIBoundary ? "SwiftUI" : "AppKit", result);
        fflush(stderr);
    }
    if (terminal) {
        activeWindowNumber = 0;
        capabilityWindowNumber = 0;
        capabilityUsesSwiftUIBoundary = NO;
        horizontalPixelResidual = 0.0;
        verticalPixelResidual = 0.0;
    }
    return result == 0;
}

static BOOL MacWSPostDesktopCommand(MacWSDesktopCommand command) {
    static MacWSPostLegacyKeyboardEvent postKeyboard;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        postKeyboard = (MacWSPostLegacyKeyboardEvent)dlsym(
            RTLD_DEFAULT, "CGPostKeyboardEvent");
        if (!postKeyboard) {
            void *coreGraphics = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                RTLD_LAZY | RTLD_LOCAL);
            if (coreGraphics) postKeyboard =
                (MacWSPostLegacyKeyboardEvent)dlsym(
                    coreGraphics, "CGPostKeyboardEvent");
        }
    });
    if (!postKeyboard) return NO;
    uint16_t arrow = 0;
    switch (command) {
        case MacWSDesktopCommandMissionControl: arrow = 126; break;
        case MacWSDesktopCommandApplicationWindows: arrow = 125; break;
        case MacWSDesktopCommandSpaceLeft: arrow = 123; break;
        case MacWSDesktopCommandSpaceRight: arrow = 124; break;
        default: return NO;
    }
    // These are the standard symbolic-hotkey equivalents of a MacBook
    // three-finger gesture: Control+Up/Down/Left/Right. CGPostKeyboardEvent is
    // used from the already-CGS-connected AppKit process for the same reason as
    // the proven CGPostMouseEvent path above.
    int32_t controlDown = postKeyboard(0, 59, true);
    int32_t arrowDown = postKeyboard(0, arrow, true);
    int32_t arrowUp = postKeyboard(0, arrow, false);
    int32_t controlUp = postKeyboard(0, 59, false);
    BOOL posted = controlDown == 0 && arrowDown == 0 &&
        arrowUp == 0 && controlUp == 0;
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT DESKTOP-COMMAND pid=%d command=%u key=%u "
            "result=%d/%d/%d/%d\n",
            getpid(), command, arrow, controlDown, arrowDown,
            arrowUp, controlUp);
        fflush(stderr);
    }
    return posted;
}

static BOOL MacWSPostLegacySystemPointerEvent(
        MacWSInputRecord record, CGPoint screenPoint, CGRect screenFrame,
        CGRect inputMappingFrame, NSInteger windowNumber,
        BOOL allowExactSystemStart) {
    // VNC already owns its complete native system stream in OSXvnc. Routing a
    // second copy through the selected application would duplicate buttons.
    if (record.source == MacWSInputSourceVNC) return NO;
    // A v4 Host record with an encoded window came from the exact
    // DisplayStream layer that Host visibly composited. CGPostMouseEvent has
    // no PID/window parameter: it throws that identity away and asks
    // WindowServer to hit-test its independent global scene graph again.
    // Runtime-confirmed on 2026-08-05: Host selected Maps PID 47265/window 44
    // at the visible Continue button, then this global repost opened
    // Terminal's Inspector instead. Preserve exact records for the ordinary
    // per-window AppKit dispatcher below; retain this system route only for
    // zero-window fallback pixels such as uncatalogued system surfaces.
    uint32_t exactWindow = MacWSInputWindowIDForScene(record.sceneID);
    BOOL exactContinuation = exactWindow != 0 &&
        MacWSExactSystemPointerActive &&
        MacWSExactSystemPointerContact == record.contactID &&
        MacWSExactSystemPointerWindow == exactWindow;
    if (exactWindow != 0 && !allowExactSystemStart && !exactContinuation)
        return NO;
    MacWSPostLegacyMouseEvent postMouse = MacWSLegacySystemMousePoster();
    if (!postMouse) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT SYSTEM-POINTER unavailable post=%p\n",
                postMouse);
            fflush(stderr);
        }
        return NO;
    }

    static BOOL leftDown;
    static BOOL rightDown;
    BOOL atomicTap = NO;
    BOOL secondary = NO;
    switch ((MacWSInputKind)record.kind) {
        case MacWSInputKindTouchDown:
            leftDown = YES;
            break;
        case MacWSInputKindTouchMove:
        case MacWSInputKindHover:
        case MacWSInputKindMenuHover:
            break;
        case MacWSInputKindTouchUp:
        case MacWSInputKindTouchCancel:
            leftDown = NO;
            rightDown = NO;
            break;
        case MacWSInputKindTap:
            atomicTap = YES;
            break;
        case MacWSInputKindSecondaryTap:
            atomicTap = YES;
            secondary = YES;
            break;
        default:
            return NO;
    }
    CGPoint quartzPoint = {
        screenPoint.x,
        screenFrame.origin.y + screenFrame.size.height - screenPoint.y,
    };
    int32_t firstResult = 0;
    int32_t secondResult = 0;
    BOOL latencyMarker = atomicTap &&
        MacWSWriteSystemInputLatencyMarker(record,
            exactWindow != 0 ? exactWindow : (uint32_t)windowNumber);
    if (atomicTap) {
        // Runtime-confirmed in Dock on 2026-08-06: setting only the third
        // slot produces event type 0x19 (OtherMouseDown), while the second
        // slot is the secondary/right button.  Keep the
        // full three-button state explicit so the release is also a recovery
        // boundary for a gesture interrupted by Scene suspension.
        // Native menu trackers consult WindowServer's global mouse location
        // when choosing both the highlighted row background and its text
        // appearance. The event coordinate alone is not sufficient: setting
        // updateMouseCursorPosition=false produced mismatched hover colours
        // in NSMenu/Chromium popup windows. Keep the real global pointer state
        // coherent here; WindowServer's cursor sprite is hidden independently
        // at the completed-composite boundary.
        firstResult = postMouse(quartzPoint, true, 3,
            secondary ? false : true, secondary ? true : false, false);
        // CGPostMouseEvent preserves call order and button transitions are
        // not coalesced. The former 8-ms hold added almost one complete iPad
        // Pro display interval before the receiving NSApplication observed
        // the click (runtime A/B: Terminal system-queue p95 14.43 ms). Keep a
        // small 2-ms separation for trackers that sample pressedMouseButtons,
        // while avoiding an artificial frame of input latency.
        usleep(2000);
        secondResult = postMouse(quartzPoint, true, 3,
            false, false, false);
    } else {
        // An interoperability probe creates a real Finder source-drag solely
        // to populate NSDragPboard. A button release is a DROP, not a cancel:
        // converting TouchCancel to mouse-up alone commits the probe's short
        // displacement. Cancel through CoreDrag's native Escape input before
        // releasing the button. Only the exact probe contact owns this pair;
        // ordinary one-finger drags, taps and physical keyboard input are not
        // changed. The release still runs even if posting Escape fails, so no
        // mouse button can be left held by a failed transport.
        if (exactContinuation && record.kind == MacWSInputKindTouchCancel &&
            record.source == MacWSInputSourceInteropDragProbe) {
            static MacWSPostLegacyKeyboardEvent postCancelKey;
            static dispatch_once_t cancelKeyOnce;
            dispatch_once(&cancelKeyOnce, ^{
                postCancelKey = (MacWSPostLegacyKeyboardEvent)dlsym(
                    RTLD_DEFAULT, "CGPostKeyboardEvent");
            });
            int32_t cancelDown = postCancelKey
                ? postCancelKey(27, 53, true) : -1;
            int32_t cancelUp = postCancelKey
                ? postCancelKey(27, 53, false) : -1;
            fprintf(stderr, "#### APP-INPUT INTEROP-CANCEL pid=%d "
                "window=%u contact=%u escape=%d/%d before-mouse-up=YES\n",
                getpid(), exactWindow, record.contactID, cancelDown, cancelUp);
            fflush(stderr);
        }
        firstResult = postMouse(quartzPoint, true, 3,
            leftDown, rightDown, false);
    }
    BOOL posted = firstResult == 0 && secondResult == 0;
    if (!posted && latencyMarker)
        MacWSRemoveSystemInputLatencyMarker(
            exactWindow != 0 ? exactWindow : (uint32_t)windowNumber);
    if (posted && exactWindow != 0 && allowExactSystemStart &&
        record.kind == MacWSInputKindTouchDown) {
        MacWSExactSystemPointerActive = YES;
        MacWSExactSystemPointerContact = record.contactID;
        MacWSExactSystemPointerWindow = exactWindow;
        MacWSExactSystemPointerMappingFrame = inputMappingFrame;
    }
    if (exactContinuation &&
        (record.kind == MacWSInputKindTouchUp ||
         record.kind == MacWSInputKindTouchCancel)) {
        MacWSExactSystemPointerActive = NO;
        MacWSExactSystemPointerContact = 0;
        MacWSExactSystemPointerWindow = 0;
        MacWSExactSystemPointerMappingFrame = (CGRect){0};
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT SYSTEM-POINTER pid=%d window=%ld kind=%u "
            "buttons=%u/%u appkit=(%.2f,%.2f) quartz=(%.2f,%.2f) "
            "exact-start=%s exact-continuation=%s result=%d/%d\n",
            getpid(), (long)windowNumber, record.kind,
            leftDown ? 1u : 0u, rightDown ? 1u : 0u,
            screenPoint.x, screenPoint.y, quartzPoint.x, quartzPoint.y,
            allowExactSystemStart ? "YES" : "NO",
            exactContinuation ? "YES" : "NO",
            firstResult, secondResult);
        fflush(stderr);
    }
    return posted;
}

// Reconstruct the exact Ventura 13.4 event consumed by Dock's native fluid
// gesture controller. RE-confirmed in the actual Dock arm64e image:
//   -[DOCKGestures handleEvent:] at __TEXT+0x8d1b0 accepts CGEvent field 110
//   == 23, uses field 132 bits 1/2/4/8 as Begin/Change/End/Cancel, and creates
//   DOCKGestureEvent for fluidGestureStart/Progress/End.
//   -[DOCKGestureEvent initWithEvent:display:gesture:] at __TEXT+0x47798
//   reads signed progress from field 124, velocity from field 129, direction
//   from field 115, and reversal from field 136.
//   Dock's helper at __TEXT+0x8d508 reads navigation axis from field 123 and
//   derives left/right/up/down from signed progress. Host therefore transports
//   one continuous axis/progress stream instead of deciding a semantic action.
static MacWSCGEventRef MacWSCreateDockSystemGestureEvent(
        MacWSInputRecord record) {
    static MacWSCreateCGEvent createEvent;
    static MacWSSetCGEventType setType;
    static MacWSSetCGEventTimestamp setTimestamp;
    static MacWSSetCGEventIntegerField setInteger;
    static MacWSSetCGEventDoubleField setDouble;
    static MacWSGetCGEventIntegerField getInteger;
    static MacWSGetCGEventDoubleField getDouble;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createEvent = (MacWSCreateCGEvent)dlsym(RTLD_DEFAULT,
                                                "CGEventCreate");
        setType = (MacWSSetCGEventType)dlsym(RTLD_DEFAULT,
                                             "CGEventSetType");
        setTimestamp = (MacWSSetCGEventTimestamp)dlsym(
            RTLD_DEFAULT, "CGEventSetTimestamp");
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
        setDouble = (MacWSSetCGEventDoubleField)dlsym(
            RTLD_DEFAULT, "CGEventSetDoubleValueField");
        getInteger = (MacWSGetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventGetIntegerValueField");
        getDouble = (MacWSGetCGEventDoubleField)dlsym(
            RTLD_DEFAULT, "CGEventGetDoubleValueField");
    });
    if (!createEvent || !setType || !setInteger || !setDouble ||
        !getInteger || !getDouble) return NULL;

    uint16_t phaseFlags = record.flags &
        (MacWSInputFlagGestureBegan | MacWSInputFlagGestureChanged |
         MacWSInputFlagGestureEnded | MacWSInputFlagGestureCancelled);
    int64_t phase = phaseFlags == MacWSInputFlagGestureBegan ? 1 :
        phaseFlags == MacWSInputFlagGestureChanged ? 2 :
        phaseFlags == MacWSInputFlagGestureEnded ? 4 : 8;
    int64_t direction = 0;
    if (record.buttons == MacWSSystemGestureAxisHorizontal)
        direction = record.pressure >= 0.0f ? 4 : 8;
    else if (record.buttons == MacWSSystemGestureAxisVertical)
        direction = record.pressure >= 0.0f ? 1 : 2;

    MacWSCGEventRef event = createEvent(NULL);
    if (!event) return NULL;
    setType(event, 29);       // private CG gesture event family
    setInteger(event, 110, 23); // Dock navigation gesture
    setInteger(event, 115, direction);
    // Do not write field 117. Runtime readback on Ventura 13.4 proves that
    // CGEventSetIntegerValueField maps 117 onto the same backing slot as 115:
    // writing a contact ID there overwrites Dock's direction.  Dock's target
    // handleEvent:/DOCKGestureEvent path does not read 117; contact identity
    // remains a transport invariant used by Host and the broker only.
    setInteger(event, 123, record.buttons);
    setDouble(event, 124, record.pressure);
    setDouble(event, 129, record.altitude);
    setInteger(event, 132, phase);
    setInteger(event, 136, 1); // physical direction is not reversed
    if (setTimestamp && record.timestamp > 0.0)
        setTimestamp(event, (uint64_t)llround(record.timestamp * 1.0e9));

    BOOL equivalent = getInteger(event, 110) == 23 &&
        getInteger(event, 115) == direction &&
        getInteger(event, 123) == record.buttons &&
        getInteger(event, 132) == phase && getInteger(event, 136) == 1 &&
        fabs(getDouble(event, 124) - record.pressure) <= 0.0005 &&
        fabs(getDouble(event, 129) - record.altitude) <= 0.0005;
    if (!equivalent) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT DOCK-GESTURE-CREATE-FAIL pid=%d "
                "axis=%u phase=%lld progress=%.6f->%.6f "
                "velocity=%.6f->%.6f fields="
                "110:%lld 115:%lld 123:%lld 132:%lld 136:%lld\n",
                getpid(), record.buttons, (long long)phase,
                record.pressure, getDouble(event, 124), record.altitude,
                getDouble(event, 129),
                (long long)getInteger(event, 110),
                (long long)getInteger(event, 115),
                (long long)getInteger(event, 123),
                (long long)getInteger(event, 132),
                (long long)getInteger(event, 136));
            fflush(stderr);
        }
        CFRelease(event);
        return NULL;
    }
    return event;
}

static BOOL MacWSDeliverDockSystemGesture(MacWSInputRecord record) {
    MacWSCGEventRef event = MacWSCreateDockSystemGestureEvent(record);
    if (!event) return NO;
    id gestures = MacWSCurrentDockGesturesInstance();
    SEL handleEvent = sel_registerName("handleEvent:");
    if (!gestures || !((MacWSMsgBoolSEL)objc_msgSend)(
            gestures, sel_registerName("respondsToSelector:"), handleEvent)) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT DOCK-GESTURE-DROP pid=%d "
                "reason=native-controller-unavailable\n", getpid());
            fflush(stderr);
        }
        CFRelease(event);
        return NO;
    }
    // This helper runs on Dock's main queue, matching the hardware event
    // source.  The socket thread never runs Mission Control state itself.
    ((MacWSMsgVoidID)objc_msgSend)(gestures, handleEvent, (id)event);
    CFRelease(event);
    // Dock's fluid controllers move compositor windows directly, so their
    // progress does not pass through the NSWindow geometry hooks that usually
    // wake displayd.  Notify displayd only after the native handler consumed
    // the sample; it temporarily samples the authoritative CGWindow geometry
    // at display cadence and keeps Host's independent IOSurface layers in the
    // same continuous animation.  This is an invalidation edge, not a second
    // gesture implementation.
    MacWSNotifyDisplayCatalogChanged('a');
    if (MacWSRuntimeDiagnosticsEnabled() &&
        (record.flags & MacWSInputFlagGestureChanged) == 0) {
        fprintf(stderr,
            "#### APP-INPUT DOCK-GESTURE pid=%d axis=%u phase=%#x "
            "progress=%.6f velocity=%.6f route=DOCKGestures.handleEvent\n",
            getpid(), record.buttons, record.flags, record.pressure,
            record.altitude);
        fflush(stderr);
    }
    return YES;
}

static void MacWSDrainDockGestureChanges(uint64_t session) {
    MacWSInputRecord record = {0};
    BOOL haveRecord = NO;
    pthread_mutex_lock(&MacWSDockGestureLock);
    if (session != MacWSDockGestureSession) {
        pthread_mutex_unlock(&MacWSDockGestureLock);
        return;
    }
    if (session == MacWSDockGestureSession &&
        MacWSDockGestureActiveContact != 0 &&
        MacWSDockGestureLatestRevision >
            MacWSDockGestureDeliveredRevision) {
        record = MacWSDockGestureLatestChanged;
        MacWSDockGestureDeliveredRevision =
            MacWSDockGestureLatestRevision;
        MacWSDockGestureDeliveredChanges++;
        haveRecord = YES;
    } else {
        MacWSDockGestureDrainScheduled = NO;
    }
    pthread_mutex_unlock(&MacWSDockGestureLock);

    if (haveRecord) (void)MacWSDeliverDockSystemGesture(record);

    BOOL scheduleNext = NO;
    pthread_mutex_lock(&MacWSDockGestureLock);
    if (session == MacWSDockGestureSession &&
        MacWSDockGestureActiveContact != 0 &&
        MacWSDockGestureLatestRevision >
            MacWSDockGestureDeliveredRevision) {
        // Yield to the rest of Dock's main queue between native progress
        // updates. The next block observes the newest producer record, not a
        // historical sample from an ever-growing queue.
        scheduleNext = YES;
    } else if (session == MacWSDockGestureSession) {
        MacWSDockGestureDrainScheduled = NO;
    }
    pthread_mutex_unlock(&MacWSDockGestureLock);
    if (scheduleNext) dispatch_async(dispatch_get_main_queue(), ^{
        MacWSDrainDockGestureChanges(session);
    });
}

static BOOL MacWSPostDockSystemGesture(MacWSInputRecord record) {
    id gestures = MacWSCurrentDockGesturesInstance();
    SEL handleEvent = sel_registerName("handleEvent:");
    if (!gestures || !((MacWSMsgBoolSEL)objc_msgSend)(
            gestures, sel_registerName("respondsToSelector:"),
            handleEvent)) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT DOCK-GESTURE-DROP pid=%d "
                "reason=instance-unavailable instance=%p\n",
                getpid(), gestures);
            fflush(stderr);
        }
        return NO;
    }

    uint16_t phase = record.flags &
        (MacWSInputFlagGestureBegan | MacWSInputFlagGestureChanged |
         MacWSInputFlagGestureEnded | MacWSInputFlagGestureCancelled);
    if (phase == MacWSInputFlagGestureBegan) {
        // Install exactly once at the ownership boundary, before Begin asks
        // Dock to construct the Spaces Bar. Calling ObjC method discovery for
        // every 120-Hz Changed sample is unnecessary; a Swift class that was
        // unrealized at dylib startup is guaranteed to be present by Begin.
        (void)MacWSInstallDockModalEventWitness();
        MacWSInputRecord orphanCancellation = {0};
        BOOL haveOrphanCancellation = NO;
        pthread_mutex_lock(&MacWSDockGestureLock);
        if (MacWSDockGestureActiveContact != 0 &&
            MacWSDockGestureLastRecord.contactID ==
                MacWSDockGestureActiveContact) {
            // A new hardware Begin is an authoritative ownership boundary.
            // If a Scene suspension or transport loss prevented the previous
            // recognizer's terminal record from arriving, close that exact
            // native Dock phase before starting another one.  Silently
            // replacing ActiveContact leaves DOCKGestures._currentHandler
            // owned by the abandoned session and makes later directions
            // intermittently unresponsive.
            orphanCancellation = MacWSDockGestureLastRecord;
            orphanCancellation.flags &= ~(MacWSInputFlagGestureBegan |
                MacWSInputFlagGestureChanged |
                MacWSInputFlagGestureEnded |
                MacWSInputFlagGestureCancelled);
            orphanCancellation.flags |= MacWSInputFlagGestureCancelled;
            haveOrphanCancellation = YES;
        }
        uint64_t session = ++MacWSDockGestureSession;
        if (session == 0) session = ++MacWSDockGestureSession;
        MacWSDockGestureActiveContact = record.contactID;
        MacWSDockGestureLastRecord = record;
        MacWSDockGestureLatestRevision = 0;
        MacWSDockGestureDeliveredRevision = 0;
        MacWSDockGestureReceivedChanges = 0;
        MacWSDockGestureDeliveredChanges = 0;
        MacWSDockGestureDrainScheduled = NO;
        pthread_mutex_unlock(&MacWSDockGestureLock);
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)session;
            if (haveOrphanCancellation)
                (void)MacWSDeliverDockSystemGesture(orphanCancellation);
            (void)MacWSDeliverDockSystemGesture(record);
        });
        return YES;
    }

    if (phase == MacWSInputFlagGestureChanged) {
        BOOL scheduleDrain = NO;
        uint64_t session = 0;
        pthread_mutex_lock(&MacWSDockGestureLock);
        if (MacWSDockGestureActiveContact != record.contactID) {
            pthread_mutex_unlock(&MacWSDockGestureLock);
            return NO;
        }
        MacWSDockGestureLatestChanged = record;
        MacWSDockGestureLastRecord = record;
        MacWSDockGestureLatestRevision++;
        MacWSDockGestureReceivedChanges++;
        session = MacWSDockGestureSession;
        if (!MacWSDockGestureDrainScheduled) {
            MacWSDockGestureDrainScheduled = YES;
            scheduleDrain = YES;
        }
        pthread_mutex_unlock(&MacWSDockGestureLock);
        if (scheduleDrain) dispatch_async(dispatch_get_main_queue(), ^{
            MacWSDrainDockGestureChanges(session);
        });
        return YES;
    }

    MacWSInputRecord finalChanged = {0};
    BOOL haveFinalChanged = NO;
    uint32_t receivedChanges = 0;
    uint32_t deliveredChanges = 0;
    pthread_mutex_lock(&MacWSDockGestureLock);
    if (MacWSDockGestureActiveContact != record.contactID) {
        pthread_mutex_unlock(&MacWSDockGestureLock);
        return NO;
    }
    if (MacWSDockGestureLatestRevision >
        MacWSDockGestureDeliveredRevision) {
        finalChanged = MacWSDockGestureLatestChanged;
        MacWSDockGestureDeliveredRevision =
            MacWSDockGestureLatestRevision;
        MacWSDockGestureDeliveredChanges++;
        haveFinalChanged = YES;
    }
    receivedChanges = MacWSDockGestureReceivedChanges;
    deliveredChanges = MacWSDockGestureDeliveredChanges;
    MacWSDockGestureLastRecord = record;
    MacWSDockGestureActiveContact = 0;
    MacWSDockGestureDrainScheduled = NO;
    pthread_mutex_unlock(&MacWSDockGestureLock);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (haveFinalChanged)
            (void)MacWSDeliverDockSystemGesture(finalChanged);
        (void)MacWSDeliverDockSystemGesture(record);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT DOCK-GESTURE-COALESCE pid=%d "
                "received=%u delivered=%u coalesced=%u\n",
                getpid(), receivedChanges, deliveredChanges,
                receivedChanges >= deliveredChanges
                    ? receivedChanges - deliveredChanges : 0);
            fflush(stderr);
        }
    });
    return YES;
}

// Route a real pointer event through the active Mission Control modal owner.
// Global CGEventPost/CGPostMouseEvent reaches Dock's normal CGS connection but
// cannot supply the Spaces Bar's WALayerKitWindow/top-layer pair. The native
// ECModalEventController route takes those exact live objects and therefore
// preserves Dock's own hit testing, actions and animation state.
static BOOL MacWSPostDockModalPointerEvent(MacWSInputRecord record,
                                           CGPoint expectedQuartzPoint,
                                           BOOL *activeOut) {
    if (activeOut) *activeOut = NO;
    switch ((MacWSInputKind)record.kind) {
        case MacWSInputKindTouchDown:
        case MacWSInputKindTouchMove:
        case MacWSInputKindTouchUp:
        case MacWSInputKindTouchCancel:
        case MacWSInputKindHover:
        case MacWSInputKindMenuHover:
        case MacWSInputKindTap:
        case MacWSInputKindSecondaryTap:
            break;
        default:
            return NO;
    }

    static MacWSCopyCGEvent copyEvent;
    static MacWSSetCGEventType setType;
    static MacWSSetCGEventIntegerField setInteger;
    static MacWSSetCGEventTimestamp setTimestamp;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        copyEvent = (MacWSCopyCGEvent)dlsym(
            RTLD_DEFAULT, "CGEventCreateCopy");
        setType = (MacWSSetCGEventType)dlsym(
            RTLD_DEFAULT, "CGEventSetType");
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
        setTimestamp = (MacWSSetCGEventTimestamp)dlsym(
            RTLD_DEFAULT, "CGEventSetTimestamp");
    });
    if (!copyEvent || !setType || !setInteger) return NO;

    __block BOOL routed = NO;
    dispatch_block_t routeBlock = ^{
        Class modalClass = objc_getClass("ECModalEventController");
        SEL sharedSelector = sel_registerName("sharedController");
        SEL currentHandlerSelector = sel_registerName("currentHandler");
        SEL routeSelector = sel_registerName(
            "handleEvent:windows:topLayers:windowCount:");
        if (!modalClass ||
            ![modalClass respondsToSelector:sharedSelector]) return;
        id modalController = ((id (*)(id, SEL))objc_msgSend)(
            modalClass, sharedSelector);
        if (!modalController ||
            ![modalController respondsToSelector:currentHandlerSelector] ||
            ![modalController respondsToSelector:routeSelector]) return;
        id currentHandler = ((id (*)(id, SEL))objc_msgSend)(
            modalController, currentHandlerSelector);
        Class exposeClass = objc_getClass(
            "_TtC4Dock21ExposeEventController");
        if (!currentHandler || !exposeClass ||
            ![currentHandler isKindOfClass:exposeClass]) return;
        if (activeOut) *activeOut = YES;
        id hitWindow = MacWSDockModalWindow;
        id topLayer = MacWSDockModalTopLayer;
        MacWSCGEventRef templateEvent = MacWSDockModalTemplateEvent;
        // Mission Control's window cards are presentation-layer transforms,
        // so the captured WALayerKit tuple is valid only at the native event
        // point which produced it. Code-path-confirmed in this adapter: the old
        // modal replay returned success without moving WindowServer first, so
        // the witness could never replace a template captured at another card.
        // Require the live tuple and its CGEvent point to describe the current
        // Host point. If not, the caller posts one real button-free WindowServer
        // event and retries after the witness publishes a newer revision. The
        // reported click/hover regression remains the runtime validation target.
        if (!hitWindow || !topLayer || !templateEvent ||
            !MacWSDockModalTemplatePointValid ||
            hypot(MacWSDockModalTemplatePoint.x - expectedQuartzPoint.x,
                  MacWSDockModalTemplatePoint.y - expectedQuartzPoint.y) >
                1.5) return;

        uint32_t firstType = 0;
        uint32_t secondType = 0;
        uint32_t button = 0;
        switch ((MacWSInputKind)record.kind) {
            case MacWSInputKindTouchDown: firstType = 1; break;
            case MacWSInputKindTouchMove: firstType = 6; break;
            case MacWSInputKindTouchUp:
            case MacWSInputKindTouchCancel: firstType = 2; break;
            case MacWSInputKindHover:
            case MacWSInputKindMenuHover: firstType = 5; break;
            case MacWSInputKindTap:
                firstType = 1; secondType = 2; break;
            case MacWSInputKindSecondaryTap:
                firstType = 3; secondType = 4; button = 1; break;
            default: break;
        }
        if (firstType == 0) return;

        MacWSCGEventRef events[2] = {
            copyEvent(templateEvent),
            secondType ? copyEvent(templateEvent) : NULL,
        };
        if (!events[0] || (secondType && !events[1])) {
            if (events[0]) CFRelease(events[0]);
            if (events[1]) CFRelease(events[1]);
            return;
        }
        NSUInteger eventCount = secondType ? 2 : 1;
        for (NSUInteger index = 0; index < eventCount; index++) {
            MacWSCGEventRef event = events[index];
            setType(event, index == 0 ? firstType : secondType);
            setInteger(event, 1 /* click state */,
                (record.flags & MacWSInputFlagDoubleClick) ? 2 : 1);
            setInteger(event, 3 /* button number */, button);
            if (setTimestamp && record.timestamp > 0.0)
                setTimestamp(event,
                    (uint64_t)llround(record.timestamp * 1.0e9));
        }

        id windows[1] = {hitWindow};
        id topLayers[1] = {topLayer};
        for (NSUInteger index = 0; index < eventCount; index++)
            ((void (*)(id, SEL, id, const id *, const id *, NSUInteger))
                objc_msgSend)(modalController, routeSelector,
                    (id)(uintptr_t)events[index], windows, topLayers, 1);
        for (NSUInteger index = 0; index < eventCount; index++)
            CFRelease(events[index]);
        routed = YES;
    };
    if ([NSThread isMainThread]) routeBlock();
    else dispatch_sync(dispatch_get_main_queue(), routeBlock);
    if (routed) MacWSNotifyDisplayCatalogChanged('m');
    return routed;
}

// The central broker runs outside a normal WindowServer application session:
// runtime CGPreflightPostEventAccess is NO.  OSXvnc's working mouse path calls
// CGPostMouseEvent at __TEXT+0x9f24 from a CGS-connected process; the
// process-local Dock experiment instead reached tile hit/release and
// doAction:fromKeyboard: but did not launch the tile.  Reuse the same proven
// system pointer owner already used for AppKit popup dismissal, now from
// Dock's real CGS process.  WindowServer and Dock retain all hit testing,
// launch and context-menu semantics.
static BOOL MacWSPostDockSystemInput(MacWSInputRecord record) {
    if ((record.flags & MacWSInputFlagGlobalSystemSurface) == 0 ||
        record.frameWidth == 0 || record.frameHeight == 0)
        return NO;
    if (record.kind == MacWSInputKindSystemGesture)
        return MacWSPostDockSystemGesture(record);
    switch ((MacWSInputKind)record.kind) {
        case MacWSInputKindTouchDown:
        case MacWSInputKindTouchMove:
        case MacWSInputKindTouchUp:
        case MacWSInputKindTouchCancel:
        case MacWSInputKindHover:
        case MacWSInputKindMenuHover:
        case MacWSInputKindTap:
        case MacWSInputKindSecondaryTap:
            break;
        default:
            return NO;
    }

    typedef uint32_t (*MacWSMainDisplayID)(void);
    typedef CGRect (*MacWSDisplayBounds)(uint32_t);
    static MacWSMainDisplayID mainDisplayID;
    static MacWSDisplayBounds displayBounds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mainDisplayID = (MacWSMainDisplayID)dlsym(
            RTLD_DEFAULT, "CGMainDisplayID");
        displayBounds = (MacWSDisplayBounds)dlsym(
            RTLD_DEFAULT, "CGDisplayBounds");
    });
    if (!mainDisplayID || !displayBounds) return NO;
    CGRect frame = displayBounds(mainDisplayID());
    if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
        !isfinite(frame.size.width) || !isfinite(frame.size.height) ||
        frame.size.width <= 0.0 || frame.size.height <= 0.0)
        return NO;
    CGFloat normalizedX = record.x / (CGFloat)record.frameWidth;
    CGFloat normalizedY = record.y / (CGFloat)record.frameHeight;
    CGPoint appKitPoint = {
        frame.origin.x + normalizedX * frame.size.width,
        frame.origin.y + (1.0 - normalizedY) * frame.size.height,
    };
    CGPoint quartzPoint = {
        appKitPoint.x,
        frame.origin.y + frame.size.height - appKitPoint.y,
    };
    uint32_t windowNumber = MacWSInputWindowIDForScene(record.sceneID);
    // Fullscreen Host records intentionally encode window zero so Dock remains
    // a neutral CGS event poster and WindowServer performs the final hit test.
    // For a diagnostic atomic click only, ask the same WindowServer scene for
    // the window currently under the post point and use that identity solely
    // to correlate the receiving NSApplication.sendEvent: boundary. The
    // actual pointer record stays window-zero and its routing is unchanged.
    uint32_t latencyWindowNumber = windowNumber;
    if (latencyWindowNumber == 0 &&
        (record.flags & MacWSInputFlagLatencyDiagnostic) &&
        (record.kind == MacWSInputKindTap ||
         record.kind == MacWSInputKindSecondaryTap)) {
        Class nativeWindowClass = objc_getClass("NSWindow");
        SEL globalHitSelector = sel_registerName(
            "windowNumberAtPoint:belowWindowWithWindowNumber:");
        if (nativeWindowClass && class_respondsToSelector(
                object_getClass(nativeWindowClass), globalHitSelector)) {
            NSInteger hit = ((MacWSMsgIntegerPointInteger)objc_msgSend)(
                (id)nativeWindowClass, globalHitSelector, appKitPoint, 0);
            if (hit > 0 && hit <= UINT32_MAX)
                latencyWindowNumber = (uint32_t)hit;
        }
    }
    BOOL latencyMarker = MacWSWriteSystemInputLatencyMarker(
        record, latencyWindowNumber);

    BOOL nativePointerTransaction =
        record.kind == MacWSInputKindTouchDown ||
        record.kind == MacWSInputKindTouchMove ||
        record.kind == MacWSInputKindTouchUp ||
        record.kind == MacWSInputKindTouchCancel ||
        record.kind == MacWSInputKindHover ||
        record.kind == MacWSInputKindMenuHover;
    if (nativePointerTransaction) {
        // Do not replay Dock's last modal event for pointer motion. A physical
        // Magic Keyboard mouse first moves WindowServer's global cursor; Dock's
        // normal ECModalEventController entry then resolves the current card
        // and records its exact WALayerKit tuple in the witness above. Replaying
        // the prior tuple here was self-sealing: it returned success, suppressed
        // this native move, and left hover permanently on the old card.
        //
        // The same invariant applies to a sustained button transaction.
        // Runtime A/B on iPad13,6 (2026-09-08) delivered an identical
        // down/drag/up through the direct modal replay and through OSXvnc's
        // CGPostMouseEvent path. The former only selected the Mission Control
        // card; the latter visibly moved Steam from Desktop 1 to Desktop 2.
        // Keep the complete transaction on the proven WindowServer route so
        // Dock receives its ordinary capture and cross-Space drag lifecycle.
        BOOL posted = MacWSPostLegacySystemPointerEvent(
            record, appKitPoint, frame, frame, windowNumber, YES);
        if (!posted && latencyMarker)
            MacWSRemoveSystemInputLatencyMarker(latencyWindowNumber);
        return posted;
    }

    BOOL modalActive = NO;
    BOOL modalPosted = MacWSPostDockModalPointerEvent(
        record, quartzPoint, &modalActive);
    if (!modalPosted && modalActive && ![NSThread isMainThread] &&
        record.kind != MacWSInputKindHover &&
        record.kind != MacWSInputKindMenuHover) {
        // The first finger tap after opening Mission Control may precede any
        // pointer motion, so the native router has not yet published its
        // window/layer tuple. Send one button-free event through the existing
        // CGS owner, wait less than one 60-Hz frame on the socket thread (Dock's
        // main queue remains free), then retry the original record. The router
        // witness captures WindowServer's authoritative hit context; no
        // coordinate-specific object lookup or private-state fabrication is
        // involved.
        uint64_t contextRevision = atomic_load_explicit(
            &MacWSDockModalContextRevision, memory_order_acquire);
        MacWSInputRecord hover = record;
        hover.kind = MacWSInputKindHover;
        (void)MacWSPostLegacySystemPointerEvent(
            hover, appKitPoint, frame, frame, windowNumber, YES);
        // Wait only until Dock's native router publishes the event context
        // produced by that move, with the former sub-frame 12 ms sleep as a
        // hard ceiling. This removes fixed click latency on fast frames and
        // never blocks Dock's main queue (this path is socket-thread-only).
        for (unsigned attempt = 0; attempt < 24; attempt++) {
            if (atomic_load_explicit(&MacWSDockModalContextRevision,
                                     memory_order_acquire) !=
                contextRevision) break;
            usleep(500);
        }
        modalPosted = MacWSPostDockModalPointerEvent(
            record, quartzPoint, &modalActive);
    }
    BOOL posted = modalPosted || MacWSPostLegacySystemPointerEvent(
        record, appKitPoint, frame, frame, windowNumber, YES);
    // Mission Control consumes the click inside Dock's modal controller; no
    // target NSApplication mouseDown follows. Its latency is measured by the
    // Host's per-kind input-to-visible ring, so remove the AppKit-only marker.
    if (modalPosted && latencyMarker)
        MacWSRemoveSystemInputLatencyMarker(latencyWindowNumber);
    if (!posted && latencyMarker)
        MacWSRemoveSystemInputLatencyMarker(latencyWindowNumber);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT DOCK-SYSTEM pid=%d window=%u kind=%u "
            "pixel=(%.2f,%.2f)/%ux%u logical=(%.2f,%.2f) "
            "quartz=(%.2f,%.2f) route=%s posted=%s\n",
            getpid(), windowNumber, record.kind, record.x, record.y,
            record.frameWidth, record.frameHeight,
            appKitPoint.x, appKitPoint.y, quartzPoint.x, quartzPoint.y,
            modalPosted ? "mission-control-modal" : "system-mouse",
            posted ? "YES" : "NO");
        fflush(stderr);
    }
    return posted;
}

// UIKit has already classified this physical sequence as a double tap.  A
// second synthetic CGPostMouseEvent pair is not equivalent to AppKit's native
// title-bar transaction in this chroot: runtime A/B on 2026-08-06 showed the
// same Terminal title point and same window identity, but the Host pair could
// terminate the last window while OSXvnc's hardware-style pair zoomed it.
// Enter NSWindow's standard desktop zoom action only for the non-content
// title-bar band of the exact globally-frontmost NSWindow.  Do not press the
// green standardWindowButton here: on Ventura that control enters a separate
// full-screen Space, which is not the title-bar double-click contract and is
// not equivalent to -[NSWindow zoom:].  Delegate validation, zoom constraints
// and animation all stay owned by AppKit; application content and the traffic
// lights keep receiving ordinary double clicks.
static BOOL MacWSPerformNativeTitlebarDoubleClick(
        MacWSInputRecord record, id window, CGPoint windowPoint,
        NSInteger globalWindowNumber) {
    if (record.kind != MacWSInputKindTap ||
        (record.flags & MacWSInputFlagDoubleClick) == 0 || !window)
        return NO;
    NSInteger windowNumber = ((MacWSMsgInteger)objc_msgSend)(
        window, sel_registerName("windowNumber"));
    if (windowNumber <= 0 || globalWindowNumber != windowNumber) return NO;

    CGRect frame = ((MacWSMsgRect)objc_msgSend)(
        window, sel_registerName("frame"));
    SEL contentLayoutSelector = sel_registerName("contentLayoutRect");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            window, sel_registerName("respondsToSelector:"),
            contentLayoutSelector)) return NO;
    CGRect contentLayout = ((MacWSMsgRect)objc_msgSend)(
        window, contentLayoutSelector);
    CGRect localBounds = {{0.0, 0.0}, frame.size};
    CGFloat titlebarFloor = contentLayout.origin.y +
        contentLayout.size.height;
    BOOL pointInsideWindow = windowPoint.x >= localBounds.origin.x &&
        windowPoint.y >= localBounds.origin.y &&
        windowPoint.x <= localBounds.origin.x + localBounds.size.width &&
        windowPoint.y <= localBounds.origin.y + localBounds.size.height;
    if (!pointInsideWindow ||
        !isfinite(titlebarFloor) ||
        localBounds.origin.y + localBounds.size.height - titlebarFloor < 1.0 ||
        windowPoint.y < titlebarFloor) return NO;

    // A double tap on a traffic light is still a traffic-light gesture.  The
    // first tap may already have performed its native action; never reinterpret
    // the second one as a title-bar zoom.
    for (NSInteger buttonKind = 0; buttonKind <= 2; buttonKind++) {
        id button = ((MacWSMsgIDInteger)objc_msgSend)(
            window, sel_registerName("standardWindowButton:"), buttonKind);
        id superview = button ? ((MacWSMsgID)objc_msgSend)(
            button, sel_registerName("superview")) : nil;
        if (!button || !superview) continue;
        CGRect buttonFrame = ((MacWSMsgRect)objc_msgSend)(
            button, sel_registerName("frame"));
        CGRect buttonInWindow = ((MacWSMsgRectRectID)objc_msgSend)(
            superview, sel_registerName("convertRect:toView:"),
            buttonFrame, nil);
        BOOL insideButton =
            windowPoint.x >= buttonInWindow.origin.x &&
            windowPoint.y >= buttonInWindow.origin.y &&
            windowPoint.x <= buttonInWindow.origin.x +
                buttonInWindow.size.width &&
            windowPoint.y <= buttonInWindow.origin.y +
                buttonInWindow.size.height;
        if (insideButton) return NO;
    }

    SEL zoomSelector = sel_registerName("zoom:");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            window, sel_registerName("respondsToSelector:"),
            zoomSelector)) return NO;

    CGRect before = frame;
    ((MacWSMsgVoidID)objc_msgSend)(window, zoomSelector, nil);
    CGRect after = ((MacWSMsgRect)objc_msgSend)(
        window, sel_registerName("frame"));
    MacWSPublishWindowMetrics();
    MacWSNotifyDisplayCatalogChanged('z');
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT TITLEBAR-DOUBLE pid=%d window=%ld "
            "local=(%.2f,%.2f) layout-max-y=%.2f "
            "before=(%.1f,%.1f %.1fx%.1f) after=(%.1f,%.1f %.1fx%.1f) "
            "route=nswindow-zoom\n",
            getpid(), (long)windowNumber, windowPoint.x, windowPoint.y,
            titlebarFloor, before.origin.x, before.origin.y,
            before.size.width, before.size.height, after.origin.x,
            after.origin.y, after.size.width, after.size.height);
        fflush(stderr);
    }
    return YES;
}

// Preserve Apple Pencil identity and geometry on the same mouse NSEvent that
// AppKit already uses for hit testing and control tracking. CoreGraphics
// documents mouse subtype 1 as tablet-point and fields 15..24 as tablet
// position/buttons/pressure/tilt/rotation/device ID. This avoids fabricating a
// second event that could reorder against the click while giving drawing apps
// real NSEvent tablet metadata. Runtime-confirmed with Amadine on 2026-08-12:
// a pressure/tilt Pencil down-move-up sequence created a visible Rectangle and
// a second Path layer, whereas the former hover-only sequence did not drag.
static void MacWSApplyTabletMetadata(id event, MacWSInputRecord record) {
    if (!event || record.source != MacWSInputSourcePencil) return;
    SEL cgEventSelector = sel_registerName("CGEvent");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            event, sel_registerName("respondsToSelector:"), cgEventSelector))
        return;
    MacWSCGEventRef cgEvent = ((MacWSEventRef)objc_msgSend)(
        event, cgEventSelector);
    if (!cgEvent) return;

    static MacWSSetCGEventIntegerField setInteger;
    static MacWSSetCGEventDoubleField setDouble;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        setInteger = (MacWSSetCGEventIntegerField)dlsym(
            RTLD_DEFAULT, "CGEventSetIntegerValueField");
        setDouble = (MacWSSetCGEventDoubleField)dlsym(
            RTLD_DEFAULT, "CGEventSetDoubleValueField");
    });
    if (!setInteger || !setDouble) return;

    BOOL touching = record.kind == MacWSInputKindTouchDown ||
                    record.kind == MacWSInputKindTouchMove ||
                    record.kind == MacWSInputKindTap;
    setInteger(cgEvent, 7 /* kCGMouseEventSubtype */, 1);
    setInteger(cgEvent, 15 /* kCGTabletEventPointX */,
               (int64_t)llround(record.x));
    setInteger(cgEvent, 16 /* kCGTabletEventPointY */,
               (int64_t)llround(record.y));
    setInteger(cgEvent, 17 /* kCGTabletEventPointZ */, 0);
    setInteger(cgEvent, 18 /* kCGTabletEventPointButtons */, touching ? 1 : 0);
    setDouble(cgEvent, 19 /* kCGTabletEventPointPressure */,
              fmax(0.0, fmin(1.0, record.pressure)));
    setDouble(cgEvent, 20 /* kCGTabletEventTiltX */, record.tiltX);
    setDouble(cgEvent, 21 /* kCGTabletEventTiltY */, record.tiltY);
    setDouble(cgEvent, 22 /* kCGTabletEventRotation */, 0.0);
    setDouble(cgEvent, 23 /* kCGTabletEventTangentialPressure */, 0.0);
    setInteger(cgEvent, 24 /* kCGTabletEventDeviceID */,
               record.contactID ? record.contactID : 1);
}

static BOOL MacWSRFBKeySymIsModifier(uint32_t keySym) {
    // XK_Shift_L through XK_Hyper_R, including Caps/Shift lock.
    return keySym >= 0xffe1u && keySym <= 0xffeeu;
}

static uint32_t MacWSFunctionCharacterForRFBKeySym(uint32_t keySym) {
    switch (keySym) {
        case 0xff50: return 0xf729; // Home
        case 0xff51: return 0xf702; // Left
        case 0xff52: return 0xf700; // Up
        case 0xff53: return 0xf703; // Right
        case 0xff54: return 0xf701; // Down
        case 0xff55: return 0xf72c; // Page Up
        case 0xff56: return 0xf72d; // Page Down
        case 0xff57: return 0xf72b; // End
        case 0xff58: return 0xf72a; // Begin
        case 0xff61: return 0xf72e; // Print Screen
        case 0xff63: return 0xf727; // Insert
        case 0xff67: return 0xf735; // Menu
        case 0xff6a: return 0xf746; // Help
        case 0xffff: return 0xf728; // Forward Delete
        default: break;
    }
    if (keySym >= 0xffbeu && keySym <= 0xffe0u)
        return 0xf704u + (keySym - 0xffbeu); // F1 ... F35
    return 0;
}

static NSString *MacWSStringForUnicodeScalar(uint32_t scalar) {
    if (scalar > 0x10ffffu ||
        (scalar >= 0xd800u && scalar <= 0xdfffu))
        return MacWSRuntimeString("");
    unichar characters[2] = {0};
    NSUInteger length = 1;
    if (scalar <= 0xffffu) {
        characters[0] = (unichar)scalar;
    } else {
        scalar -= 0x10000u;
        characters[0] = (unichar)(0xd800u + (scalar >> 10));
        characters[1] = (unichar)(0xdc00u + (scalar & 0x3ffu));
        length = 2;
    }
    return [NSString stringWithCharacters:characters length:length];
}

static NSString *MacWSCharactersForRFBKeySym(uint32_t keySym,
                                              BOOL ignoringModifiers) {
    if (MacWSRFBKeySymIsModifier(keySym)) return MacWSRuntimeString("");
    uint32_t scalar = 0;
    switch (keySym) {
        case 0xff08: scalar = 0x7f; break; // Backspace on macOS
        case 0xff09:
        case 0xfe20: scalar = '\t'; break;
        case 0xff0a: scalar = '\n'; break;
        case 0xff0d:
        case 0xff8d: scalar = '\r'; break;
        case 0xff1b: scalar = 0x1b; break;
        case 0xff80: scalar = ' '; break; // keypad space
        case 0xffaa: scalar = '*'; break;
        case 0xffab: scalar = '+'; break;
        case 0xffad: scalar = '-'; break;
        case 0xffae: scalar = '.'; break;
        case 0xffaf: scalar = '/'; break;
        case 0xffbd: scalar = '='; break;
        default:
            if (keySym >= 0xffb0u && keySym <= 0xffb9u)
                scalar = '0' + (keySym - 0xffb0u);
            else if (keySym >= 0x20u && keySym <= 0xffu)
                scalar = keySym;
            else if ((keySym & 0xff000000u) == 0x01000000u)
                scalar = keySym & 0x00ffffffu;
            else
                scalar = MacWSFunctionCharacterForRFBKeySym(keySym);
            break;
    }
    if (ignoringModifiers) {
        if (scalar >= 'A' && scalar <= 'Z') scalar += 'a' - 'A';
        else {
            static const char shifted[] = "~!@#$%^&*()_+{}|:\"<>?";
            static const char base[] =    "`1234567890-=[]\\;',./";
            const char *match = scalar <= 0x7f
                ? strchr(shifted, (int)scalar) : NULL;
            if (match) scalar = (uint32_t)base[match - shifted];
        }
    }
    return scalar ? MacWSStringForUnicodeScalar(scalar)
                  : MacWSRuntimeString("");
}

static NSString *MacWSCharactersApplyingCapsLock(NSString *characters,
                                                  NSUInteger modifiers) {
    if ((modifiers & 0x10000u) == 0 || characters.length != 1)
        return characters;
    unichar character = [characters characterAtIndex:0];
    if (!((character >= 'a' && character <= 'z') ||
          (character >= 'A' && character <= 'Z'))) return characters;
    BOOL shift = (modifiers & 0x20000u) != 0;
    unichar transformed = shift
        ? (unichar)tolower((int)character)
        : (unichar)toupper((int)character);
    return [NSString stringWithCharacters:&transformed length:1];
}

static NSString *MacWSCharactersApplyingControl(NSString *characters,
                                                 NSUInteger modifiers) {
    // UIKeyCommand reports the physical printable input plus its modifier,
    // whereas an AppKit NSEvent's `characters` carries the corresponding
    // terminal control scalar and `charactersIgnoringModifiers` retains the
    // printable key. Preserve that distinction for the UIKeyCommand fallback
    // as well as the on-screen modifier row. UIPresses that already supplied
    // a control scalar pass through unchanged.
    if ((modifiers & (1u << 18)) == 0 || characters.length != 1)
        return characters;
    unichar scalar = [characters characterAtIndex:0];
    if (scalar < 0x20 || scalar == 0x7f) return characters;
    if (scalar >= 'a' && scalar <= 'z') scalar -= 'a' - 'A';
    if (scalar == '?') scalar = 0x7f;
    else if (scalar == ' ') scalar = 0;
    else if (scalar >= '@' && scalar <= '_') scalar &= 0x1f;
    else return characters;
    return [NSString stringWithCharacters:&scalar length:1];
}

// RE-confirmed via the installed arm64 OSXvnc-server: its
// sendKeyEvent:down:modifiers: creates a CGEvent, posts it at vncTapLocation,
// then polls CGEventSourceFlagsState every 10 ms for as long as 250 ms.
// Runtime evidence on this coexist stack showed 18 such RFB events consuming
// about 2.1 seconds while the front Terminal received zero NSEvents. Preserve
// OSXvnc's upstream keysym -> keycode/modifier state machine, but put its
// translated result into the selected application's real NSApplication queue.
static BOOL MacWSPostKeyRecord(MacWSInputRecord record, id application,
                               Class eventClass, NSInteger windowNumber,
                               BOOL fromSocketThread, BOOL menuSurface) {
    if (!application || !eventClass ||
        (record.kind != MacWSInputKindKeyDown &&
         record.kind != MacWSInputKindKeyUp) ||
        !isfinite(record.pressure) || record.pressure < 0.0f ||
        record.pressure > UINT16_MAX) return NO;
    uint32_t roundedKeyCode = (uint32_t)llround(record.pressure);
    if (fabs((double)record.pressure - roundedKeyCode) > 0.01) return NO;
    uint32_t keySym = record.contactID;

    // Unity 2022.3.62f2 keeps rendering while its Cocoa pump drains ordinary
    // -postEvent:atStart: records only about once per second.  Runtime on the
    // iPad14,5 7DTD pid 13428 measured AppInput socket/queue arrival below
    // 1.2 ms, followed by 234-997 ms before -[NSApplication sendEvent:].  A
    // THEORY under live acceptance: issuing the legacy CoreGraphics post from
    // this already-CGS-connected process may wake the event source that
    // Unity's nextEvent path waits on. A zero return is not delivery proof;
    // only a prompt matching -[NSApplication sendEvent:] witness plus visible
    // movement can accept the route. Fall back to the ordinary NSEvent queue
    // on any nonzero status. This is deliberately limited to the exact 7DTD
    // hardware route; software text, Terminal shortcuts and every other
    // AppKit application are unchanged.
    if (fromSocketThread &&
        record.source == MacWSInputSourceHardwareKeyboard &&
        MacWSMainBundleIsSevenDaysToDie()) {
        static MacWSPostLegacyKeyboardEvent postKeyboard;
        static dispatch_once_t postKeyboardOnce;
        dispatch_once(&postKeyboardOnce, ^{
            postKeyboard = (MacWSPostLegacyKeyboardEvent)dlsym(
                RTLD_DEFAULT, "CGPostKeyboardEvent");
        });
        // `contactID` uses X11 keysyms for non-printable keys; those values
        // are not CGCharCode values. Physical keyCode is authoritative, so
        // supply a character only for the single-byte printable range and
        // leave Shift/arrows/function keys at zero like the proven desktop
        // command route.
        uint16_t character = keySym <= 0xffu ? (uint16_t)keySym : 0;
        uint16_t eventType = record.kind == MacWSInputKindKeyDown ? 10 : 11;
        double postedAt = MacWSInputUptimeSeconds();
        BOOL traceSample = MacWSKeyboardLatencyDiagnosticsEnabled() &&
            (record.flags & MacWSInputFlagLatencyDiagnostic);
        if (traceSample)
            MacWSRegisterKeyboardCGSTraceSample(
                record, (uint16_t)roundedKeyCode, eventType, postedAt);
        int32_t status = postKeyboard
            ? postKeyboard(character, (uint16_t)roundedKeyCode,
                           record.kind == MacWSInputKindKeyDown)
            : -1;
        if (status != 0 && traceSample)
            MacWSCancelKeyboardCGSTraceSample(record.sampleSequence);
        if (MacWSKeyboardLatencyDiagnosticsEnabled() &&
            (record.flags & MacWSInputFlagLatencyDiagnostic)) {
            double now = MacWSInputUptimeSeconds();
            MacWSKeyboardLatencyTrace(
                "stage=app-cgs-post pid=%d sample=%u kind=%u keycode=%u "
                "producer-to-post=%.3fms status=%d\n",
                getpid(), record.sampleSequence, record.kind, roundedKeyCode,
                record.timestamp > 0.0 && now >= record.timestamp
                    ? (now - record.timestamp) * 1000.0 : -1.0,
                status);
        }
        if (status == 0) return YES;
    }
    if (keySym == 0xff1bu) {
        if (record.kind == MacWSInputKindKeyUp &&
            atomic_exchange_explicit(&MacWSAppInputConsumeEscapeUp, NO,
                                     memory_order_acq_rel)) {
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT KEY-MENU-CANCEL pid=%d route=consume-key-up\n",
                    getpid());
                fflush(stderr);
            }
            return YES;
        }
        if (record.kind == MacWSInputKindKeyDown &&
            MacWSCancelActiveMenuForEscape(application, windowNumber,
                                           fromSocketThread && menuSurface)) {
            atomic_store_explicit(&MacWSAppInputConsumeEscapeUp, YES,
                                  memory_order_release);
            // The key-down snapshot remains valid for the asynchronous
            // manager order-out above, but it must not identify this already
            // closed surface as the target of a later unrelated Escape.
            pthread_mutex_lock(&MacWSAppInputRouteLock);
            if (MacWSAppInputMenuContextValid &&
                MacWSAppInputMenuContext.application ==
                    (__bridge CFTypeRef)application &&
                MacWSAppInputMenuContext.windowNumber == windowNumber &&
                MacWSAppInputMenuContext.menuSurface) {
                MacWSAppInputMenuContext.menuSurface = NO;
                MacWSAppInputMenuContext.windowNumber = 0;
            }
            pthread_mutex_unlock(&MacWSAppInputRouteLock);
            return YES;
        }
    }
    NSUInteger modifiers = (NSUInteger)
        MacWSInputModifiersForScene(record.sceneID);
    // Runtime-confirmed on Terminal pid 92892 with the same keyCode=8,
    // keysym='c', Control flag, target window and 80-ms down/up interval:
    // without kCGEventFlagMaskNonCoalesced (0x100), `/bin/sleep 60` remained
    // alive; adding only 0x100 produced ^C and terminated that exact child.
    // OSXvnc already sets this bit on every physical key. UIKit's Host path
    // must provide the same hardware-event contract so AppKit/Terminal does
    // not coalesce a synthetic modifier chord away.
    modifiers |= 0x100u;
    NSString *characters = MacWSCharactersApplyingControl(
        MacWSCharactersApplyingCapsLock(
            MacWSCharactersForRFBKeySym(keySym, NO), modifiers),
        modifiers);
    NSString *charactersIgnoring =
        MacWSCharactersForRFBKeySym(keySym, YES);
    NSUInteger eventType = record.kind == MacWSInputKindKeyDown ? 10 : 11;
    id event = nil;
    const char *eventRoute = "FACTORY";
    static MacWSCreateKeyboardCGEvent createKeyboardCGEvent;
    static MacWSSetCGEventFlags setCGEventFlags;
    static MacWSSetCGEventTimestamp setCGEventTimestamp;
    static MacWSSetCGEventUnicode setCGEventUnicode;
    static dispatch_once_t cgEventOnce;
    dispatch_once(&cgEventOnce, ^{
        createKeyboardCGEvent = (MacWSCreateKeyboardCGEvent)dlsym(
            RTLD_DEFAULT, "CGEventCreateKeyboardEvent");
        setCGEventFlags = (MacWSSetCGEventFlags)dlsym(
            RTLD_DEFAULT, "CGEventSetFlags");
        setCGEventTimestamp = (MacWSSetCGEventTimestamp)dlsym(
            RTLD_DEFAULT, "CGEventSetTimestamp");
        setCGEventUnicode = (MacWSSetCGEventUnicode)dlsym(
            RTLD_DEFAULT, "CGEventKeyboardSetUnicodeString");
    });
    SEL eventWithCGEvent = sel_registerName("eventWithCGEvent:");
    // Runtime-confirmed with LLDB at _NSHLTBMenuEventProc+0x134: a long-lived
    // session had an unbounded stream of NSEventTypeKeyDown records (type 10),
    // and x21 == 1 proved the tracker was dequeuing rather than peeking them.
    // The exact originating key is not yet proven.  Keep the CG-backed route
    // required by ordinary text, but do not attach Escape menu-control events
    // to a CG keyboard source.  The clean factory-event A/B delivered exactly
    // one down/up pair and left Terminal at 0% CPU after menu cancellation.
    // Runtime-confirmed on 2026-09-09 with Terminal's TTView: a synthetic
    // CG-backed Command-V arrived through -[NSApplication sendEvent:] with
    // type=10, keyCode=9 and modifierFlags=0x100000, yet the responder's
    // backing string remained length 209 and no paste occurred.  Command
    // shortcuts are AppKit key equivalents, so construct those records with
    // +keyEventWithType:... below: unlike a process-local CGEvent it carries
    // the exact target NSWindow number into AppKit's key-equivalent routing.
    // Ordinary typing retains the established CG-backed path.
    BOOL commandKeyEquivalent = (modifiers & 0x100000u) != 0;
    BOOL controlModified = (modifiers & 0x40000u) != 0;
    BOOL exactSoftwareUnicode =
        record.source == MacWSInputSourceSoftwareKeyboard &&
        MacWSKeySymIsEncodedUnicode(keySym);
    BOOL canWrapCGEvent = keySym != 0xff1bu && !commandKeyEquivalent &&
        !exactSoftwareUnicode &&
        createKeyboardCGEvent && setCGEventFlags &&
        class_respondsToSelector(object_getClass(eventClass),
                                 eventWithCGEvent);
    if (canWrapCGEvent) {
        MacWSCGEventRef cgEvent = createKeyboardCGEvent(
            NULL, (unsigned short)roundedKeyCode,
            record.kind == MacWSInputKindKeyDown);
        if (cgEvent) {
            setCGEventFlags(cgEvent, modifiers);
            if (setCGEventTimestamp && record.timestamp > 0.0)
                setCGEventTimestamp(cgEvent,
                    (uint64_t)llround(record.timestamp * 1.0e9));
            NSUInteger characterCount = [characters length];
            // Runtime-confirmed with Terminal pids 87221 and 91825: forcing
            // ETX into a Control-C CGEvent, and replacing that CGEvent with a
            // factory NSEvent, both left the real `/bin/sleep` child alive.
            // A hardware Control event carries the physical keycode + flag;
            // CoreGraphics/AppKit derives its control scalar. Do not override
            // that translation with an injected Unicode payload. Ordinary
            // printable input keeps the established explicit Unicode route.
            if (!controlModified && setCGEventUnicode && characterCount > 0 &&
                characterCount <= 8) {
                unichar unicode[8] = {0};
                [characters getCharacters:unicode
                                    range:NSMakeRange(0, characterCount)];
                setCGEventUnicode(cgEvent, characterCount, unicode);
            }
            event = ((MacWSEventFromCGEvent)objc_msgSend)(
                (id)eventClass, eventWithCGEvent, cgEvent);
            CFRelease(cgEvent);
            if (event) eventRoute = "CG-WRAP";
        }
    }
    if (!event) {
        event = ((MacWSKeyEventFactory)objc_msgSend)(
            (id)eventClass,
            sel_registerName("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
            eventType, (CGPoint){0.0, 0.0}, modifiers, record.timestamp,
            windowNumber, nil, characters, charactersIgnoring, NO,
            (unsigned short)roundedKeyCode);
    }
    if (!event) return NO;
    if (fromSocketThread) {
        // Escape-down must be visible to the active nested NSMenu loop even
        // when Chromium has older unrelated events queued. Its matching up is
        // appended, so the pair cannot reverse. Ordinary typing remains FIFO.
        BOOL atStart = record.kind == MacWSInputKindKeyDown &&
                       keySym == 0xff1bu;
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, atStart);
    } else {
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), event);
    }
    if (MacWSKeyboardLatencyDiagnosticsEnabled() &&
        (record.flags & MacWSInputFlagLatencyDiagnostic)) {
        double now = MacWSInputUptimeSeconds();
        MacWSKeyboardLatencyTrace(
            "stage=app-queue pid=%d sample=%u kind=%u keycode=%u "
            "producer-to-queue=%.3fms delivery=%s\n",
            getpid(), record.sampleSequence, record.kind, roundedKeyCode,
            record.timestamp > 0.0 && now >= record.timestamp
                ? (now - record.timestamp) * 1000.0 : -1.0,
            fromSocketThread ? "post-event" : "send-event");
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        const void *eventRef = ((MacWSMsgBoolSEL)objc_msgSend)(
                event, sel_registerName("respondsToSelector:"),
                sel_registerName("_eventRef"))
            ? ((MacWSEventRef)objc_msgSend)(
                event, sel_registerName("_eventRef")) : NULL;
        fprintf(stderr,
            "#### APP-INPUT KEY-POST pid=%d kind=%u keycode=%u keysym=%#x "
            "modifiers=%#lx window=%ld route=%s delivery=%s event-ref=%p "
            "chars-length=%lu\n",
            getpid(), record.kind, roundedKeyCode, keySym,
            (unsigned long)modifiers, (long)windowNumber,
            fromSocketThread ? "QUEUE" : "MAIN-SEND",
            eventRoute, eventRef,
            (unsigned long)[characters length]);
        fflush(stderr);
    }
    return YES;
}

// The route lock closes the only dangerous transition: a socket record either
// enters MacWSAppInputPending before the main thread arms live tracking (and is
// visible to its fallback check), or snapshots the armed context and is posted
// directly. It cannot fall between those two states.
static BOOL MacWSPrepareDirectTrackingPostLocked(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot *snapshot) {
    BOOL isTrackingRecord = record.kind == MacWSInputKindTouchMove ||
        record.kind == MacWSInputKindTouchUp ||
        record.kind == MacWSInputKindTouchCancel;
    // The context is armed only after this endpoint accepted the matching
    // down. Window-Scene pointer drags need the same socket-thread posting as
    // RFB: AppKit's synchronous control tracker owns the main thread until it
    // receives move/up from NSApplication's event queue.
    if (!isTrackingRecord ||
        !MacWSAppInputDirectContext.accepting ||
        MacWSAppInputDirectContext.contactID != record.contactID ||
        MacWSAppInputDirectContext.sceneID != record.sceneID ||
        !MacWSAppInputDirectContext.application ||
        !MacWSAppInputDirectContext.eventClass) {
        return NO;
    }
    snapshot->windowNumber = MacWSAppInputDirectContext.windowNumber;
    snapshot->screenFrame = MacWSAppInputDirectContext.screenFrame;
    snapshot->windowMinusScreen =
        MacWSAppInputDirectContext.windowMinusScreen;
    snapshot->eventClass = MacWSAppInputDirectContext.eventClass;
    snapshot->application =
        CFRetain(MacWSAppInputDirectContext.application);
    if (record.kind == MacWSInputKindTouchUp ||
        record.kind == MacWSInputKindTouchCancel) {
        // The release is now owned by AppKit's event queue. Do not allow a
        // later hover or duplicate transition to enter the same tracker.
        MacWSAppInputDirectContext.accepting = NO;
    }
    return YES;
}

static void MacWSRetireDirectTrackingContextForTerminalRecord(
        MacWSInputRecord record, NSInteger windowNumber) {
    if (record.kind != MacWSInputKindTouchUp &&
        record.kind != MacWSInputKindTouchCancel) return;
    pthread_mutex_lock(&MacWSAppInputRouteLock);
    // MacWSPrepareDirectTrackingPostLocked snapshots the retained application
    // before marking this exact route non-accepting. Retire it only after the
    // terminal record has been posted, and only if another gesture has not
    // replaced the context in the meantime.
    if (!MacWSAppInputDirectContext.accepting &&
        MacWSAppInputDirectContext.contactID == record.contactID &&
        MacWSAppInputDirectContext.sceneID == record.sceneID &&
        MacWSAppInputDirectContext.windowNumber == windowNumber) {
        MacWSClearDirectTrackingContextLocked();
    }
    pthread_mutex_unlock(&MacWSAppInputRouteLock);
}

// MacWSAppInputRouteLock must be held by the caller.
static BOOL MacWSDirectGestureRecordMatchesContextLocked(
        MacWSInputRecord record) {
    uint16_t phase = record.flags &
        (MacWSInputFlagGestureBegan | MacWSInputFlagGestureChanged |
         MacWSInputFlagGestureEnded | MacWSInputFlagGestureCancelled);
    BOOL continuation = phase == MacWSInputFlagGestureChanged ||
        phase == MacWSInputFlagGestureEnded ||
        phase == MacWSInputFlagGestureCancelled;
    if (!continuation ||
        record.kind != MacWSAppInputDirectGestureContext.kind ||
        record.contactID != MacWSAppInputDirectGestureContext.contactID)
        return NO;
    uint32_t recordWindowID = MacWSInputWindowIDForScene(record.sceneID);
    if (MacWSAppInputDirectGestureContext.targetWindowID != 0)
        return recordWindowID ==
            MacWSAppInputDirectGestureContext.targetWindowID;
    return record.sceneID == MacWSAppInputDirectGestureContext.sceneID;
}

// MacWSAppInputRouteLock must be held by the caller.
static BOOL MacWSPrepareDirectGesturePostLocked(
        MacWSInputRecord record, MacWSDirectGestureSnapshot *snapshot) {
    if (!MacWSAppInputDirectGestureContext.prepared ||
        !MacWSAppInputDirectGestureContext.accepting ||
        !MacWSAppInputDirectGestureContext.application ||
        !MacWSAppInputDirectGestureContext.window ||
        !MacWSAppInputDirectGestureContext.eventClass ||
        !MacWSDirectGestureRecordMatchesContextLocked(record)) {
        return NO;
    }
    snapshot->windowNumber =
        MacWSAppInputDirectGestureContext.windowNumber;
    snapshot->mappingFrame =
        MacWSAppInputDirectGestureContext.mappingFrame;
    snapshot->screenFrame = MacWSAppInputDirectGestureContext.screenFrame;
    snapshot->windowMinusScreen =
        MacWSAppInputDirectGestureContext.windowMinusScreen;
    snapshot->eventClass = MacWSAppInputDirectGestureContext.eventClass;
    snapshot->application =
        CFRetain(MacWSAppInputDirectGestureContext.application);
    snapshot->window = CFRetain(MacWSAppInputDirectGestureContext.window);
    if (record.flags & (MacWSInputFlagGestureEnded |
                        MacWSInputFlagGestureCancelled)) {
        MacWSAppInputDirectGestureContext.accepting = NO;
        MacWSAppInputDirectGestureContext.terminalQueued = YES;
    }
    return YES;
}

static BOOL MacWSPostDirectGestureRecord(
        MacWSInputRecord record, MacWSDirectGestureSnapshot snapshot) {
    BOOL posted = NO;
    @autoreleasepool {
        CGFloat normalizedX = record.x / (CGFloat)record.frameWidth;
        CGFloat normalizedY = record.y / (CGFloat)record.frameHeight;
        CGPoint screenPoint = {
            snapshot.mappingFrame.origin.x +
                normalizedX * snapshot.mappingFrame.size.width,
            snapshot.mappingFrame.origin.y +
                (1.0 - normalizedY) * snapshot.mappingFrame.size.height,
        };
        CGPoint windowPoint = {
            screenPoint.x + snapshot.windowMinusScreen.x,
            screenPoint.y + snapshot.windowMinusScreen.y,
        };
        id event = MacWSCreateAppGestureEvent(
            snapshot.eventClass, record, (__bridge id)snapshot.window,
            screenPoint, windowPoint, snapshot.screenFrame,
            snapshot.windowNumber);
        if (event) {
            // A native enter*TrackingLoop helper is already blocked in
            // -nextEventMatchingMask:. Append continuation phases in their
            // socket arrival order so that helper, rather than another nested
            // _reallySendEvent: call, owns accumulation and termination.
            ((MacWSPostEvent)objc_msgSend)(
                (__bridge id)snapshot.application,
                sel_registerName("postEvent:atStart:"), event, NO);
            posted = YES;
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT GESTURE-LIVE-POST pid=%d kind=%u "
                    "gesture=%u window=%ld phase=%#x amount=%.6f\n",
                    getpid(), record.kind, record.contactID,
                    (long)snapshot.windowNumber, record.flags,
                    record.pressure);
                fflush(stderr);
            }
        } else {
            fprintf(stderr,
                "#### APP-INPUT GESTURE-LIVE-DROP pid=%d kind=%u "
                "gesture=%u reason=event-create\n",
                getpid(), record.kind, record.contactID);
            fflush(stderr);
        }
    }
    if (snapshot.window) CFRelease(snapshot.window);
    if (snapshot.application) CFRelease(snapshot.application);
    return posted;
}

// Move only the continuation records for the gesture whose native tracker is
// about to start.  A simultaneous rotation remains in the bridge FIFO until
// the magnification tracker returns (and vice versa), preventing one tracker
// from recursively starting the other while preserving each lifecycle.
// MacWSAppInputRouteLock must be held by the caller.
static NSUInteger MacWSPostPendingDirectGestureRecordsLocked(void) {
    NSUInteger posted = 0;
    @synchronized(MacWSAppInputPending) {
        for (NSUInteger index = 0;
             index < [MacWSAppInputPending count] &&
             MacWSAppInputDirectGestureContext.accepting;) {
            NSData *data = [MacWSAppInputPending objectAtIndex:index];
            MacWSInputRecord record = {0};
            if ([data length] != sizeof(record)) {
                index++;
                continue;
            }
            [data getBytes:&record length:sizeof(record)];
            if (!MacWSDirectGestureRecordMatchesContextLocked(record)) {
                index++;
                continue;
            }
            MacWSDirectGestureSnapshot snapshot = {0};
            if (!MacWSPrepareDirectGesturePostLocked(record, &snapshot)) {
                index++;
                continue;
            }
            [MacWSAppInputPending removeObjectAtIndex:index];
            if (MacWSPostDirectGestureRecord(record, snapshot)) posted++;
        }
    }
    return posted;
}

typedef void (*MacWSEnterGestureTrackingLoop)(
    id, SEL, id, id, id, id, id);
static MacWSEnterGestureTrackingLoop
    MacWSOriginalEnterMagnificationTrackingLoop;
static MacWSEnterGestureTrackingLoop MacWSOriginalEnterRotationTrackingLoop;

static void MacWSEnterDirectGestureTrackingLoop(
        uint16_t kind, MacWSEnterGestureTrackingLoop original,
        id eventClass, SEL selector, id firstEvent, id window,
        id resetBlock, id accumulatorBlock, id displayBlock) {
    BOOL ownsPreparedRoute = NO;
    NSUInteger queued = 0;
    pthread_mutex_lock(&MacWSAppInputRouteLock);
    id preparedWindow =
        (__bridge id)MacWSAppInputDirectGestureContext.window;
    id eventWindow = firstEvent && ((MacWSMsgBoolSEL)objc_msgSend)(
            firstEvent, sel_registerName("respondsToSelector:"),
            sel_registerName("window"))
        ? ((MacWSMsgID)objc_msgSend)(firstEvent, sel_registerName("window"))
        : nil;
    if (MacWSAppInputDirectGestureContext.prepared &&
        !MacWSAppInputDirectGestureContext.accepting &&
        MacWSAppInputDirectGestureContext.kind == kind &&
        preparedWindow &&
        (window == preparedWindow || eventWindow == preparedWindow)) {
        ownsPreparedRoute = YES;
        MacWSAppInputDirectGestureContext.accepting = YES;
        queued = MacWSPostPendingDirectGestureRecordsLocked();
    }
    pthread_mutex_unlock(&MacWSAppInputRouteLock);

    if (ownsPreparedRoute && MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT GESTURE-TRACKING-ENTER pid=%d kind=%u "
            "window=%ld queued=%lu selector=%s\n",
            getpid(), kind,
            (long)MacWSAppInputDirectGestureContext.windowNumber,
            (unsigned long)queued, sel_getName(selector));
        fflush(stderr);
    }

    original(eventClass, selector, firstEvent, window, resetBlock,
             accumulatorBlock, displayBlock);

    if (ownsPreparedRoute) {
        BOOL terminalQueued = NO;
        NSInteger windowNumber = 0;
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        // The main thread is serialized, but verify ownership before clearing
        // so an unexpected nested native gesture cannot tear down a newer
        // prepared route.
        if (MacWSAppInputDirectGestureContext.prepared &&
            MacWSAppInputDirectGestureContext.kind == kind &&
            (__bridge id)MacWSAppInputDirectGestureContext.window ==
                preparedWindow) {
            terminalQueued =
                MacWSAppInputDirectGestureContext.terminalQueued;
            windowNumber =
                MacWSAppInputDirectGestureContext.windowNumber;
            MacWSClearDirectGestureContextLocked();
        }
        pthread_mutex_unlock(&MacWSAppInputRouteLock);
        if (terminalQueued) MacWSSetAppInputGestureWindow(nil);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT GESTURE-TRACKING-RETURN pid=%d kind=%u "
                "window=%ld terminal=%s selector=%s\n",
                getpid(), kind, (long)windowNumber,
                terminalQueued ? "YES" : "NO", sel_getName(selector));
            fflush(stderr);
        }
    }
}

static void MacWSEnterMagnificationTrackingLoop(
        id eventClass, SEL selector, id firstEvent, id window,
        id resetBlock, id accumulatorBlock, id displayBlock) {
    MacWSEnterDirectGestureTrackingLoop(
        MacWSInputKindMagnify,
        MacWSOriginalEnterMagnificationTrackingLoop,
        eventClass, selector, firstEvent, window, resetBlock,
        accumulatorBlock, displayBlock);
}

static void MacWSEnterRotationTrackingLoop(
        id eventClass, SEL selector, id firstEvent, id window,
        id resetBlock, id accumulatorBlock, id displayBlock) {
    MacWSEnterDirectGestureTrackingLoop(
        MacWSInputKindRotate, MacWSOriginalEnterRotationTrackingLoop,
        eventClass, selector, firstEvent, window, resetBlock,
        accumulatorBlock, displayBlock);
}

static void MacWSInstallNativeGestureTrackingHooks(void) {
    Class eventClass = objc_getClass("NSEvent");
    if (!eventClass) return;
    struct {
        const char *name;
        IMP replacement;
        MacWSEnterGestureTrackingLoop *original;
    } hooks[] = {
        {
            "enterMagnificationTrackingLoopWithFirstEvent:forWindow:"
            "resetBlock:accumulatorBlock:displayBlock:",
            (IMP)MacWSEnterMagnificationTrackingLoop,
            &MacWSOriginalEnterMagnificationTrackingLoop,
        },
        {
            "enterRotationTrackingLoopWithFirstEvent:forWindow:"
            "resetBlock:accumulatorBlock:displayBlock:",
            (IMP)MacWSEnterRotationTrackingLoop,
            &MacWSOriginalEnterRotationTrackingLoop,
        },
    };
    for (NSUInteger index = 0;
         index < sizeof(hooks) / sizeof(hooks[0]); index++) {
        SEL selector = sel_registerName(hooks[index].name);
        Method method = class_getClassMethod(eventClass, selector);
        if (!method) continue;
        IMP current = method_getImplementation(method);
        if (current == hooks[index].replacement) continue;
        if (*hooks[index].original) continue;
        *hooks[index].original =
            (MacWSEnterGestureTrackingLoop)current;
        method_setImplementation(method, hooks[index].replacement);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT GESTURE-TRACKING-HOOK pid=%d selector=%s\n",
                getpid(), hooks[index].name);
            fflush(stderr);
        }
    }
}

static void MacWSPostDirectTrackingRecord(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot snapshot) {
    @autoreleasepool {
        CGFloat normalizedX = record.x / (CGFloat)record.frameWidth;
        CGFloat normalizedY = record.y / (CGFloat)record.frameHeight;
        CGPoint screenPoint = {
            snapshot.screenFrame.origin.x +
                normalizedX * snapshot.screenFrame.size.width,
            snapshot.screenFrame.origin.y +
                (1.0 - normalizedY) * snapshot.screenFrame.size.height,
        };
        CGPoint windowPoint = {
            screenPoint.x + snapshot.windowMinusScreen.x,
            screenPoint.y + snapshot.windowMinusScreen.y,
        };
        BOOL coreDragNative =
            (record.kind == MacWSInputKindTouchMove ||
             record.kind == MacWSInputKindTouchUp ||
             record.kind == MacWSInputKindTouchCancel) &&
            atomic_load_explicit(&MacWSAppInputCoreDragNativeActive,
                                 memory_order_acquire) &&
            atomic_load_explicit(&MacWSAppInputCoreDragNativeWindow,
                                 memory_order_acquire) ==
                (uint32_t)snapshot.windowNumber;
        if (coreDragNative) {
            MacWSPostLegacyMouseEvent postMouse =
                MacWSLegacySystemMousePoster();
            CGPoint quartzPoint = {
                screenPoint.x,
                snapshot.screenFrame.origin.y +
                    snapshot.screenFrame.size.height - screenPoint.y,
            };
            BOOL leftDown = record.kind == MacWSInputKindTouchMove;
            int32_t result = postMouse
                ? postMouse(quartzPoint, true, 3,
                            leftDown, false, false)
                : -1;
            if (MacWSRuntimeDiagnosticsEnabled()) {
                static _Atomic uint64_t coreDragPosts;
                uint64_t post = atomic_fetch_add_explicit(
                    &coreDragPosts, 1, memory_order_relaxed) + 1;
                if (post <= 16 || (post % 120) == 0 || !leftDown) {
                    fprintf(stderr,
                        "#### APP-INPUT CORE-DRAG-NATIVE pid=%d post=%llu "
                        "kind=%u gesture=%u window=%ld quartz=(%.2f,%.2f) "
                        "left=%s result=%d\n",
                        getpid(), (unsigned long long)post, record.kind,
                        record.contactID, (long)snapshot.windowNumber,
                        quartzPoint.x, quartzPoint.y,
                        leftDown ? "YES" : "NO", result);
                    fflush(stderr);
                }
            }
            if (result == 0) {
                MacWSRetireDirectTrackingContextForTerminalRecord(
                    record, snapshot.windowNumber);
                if (snapshot.application)
                    CFRelease(snapshot.application);
                return;
            }
        }
        if (record.kind == MacWSInputKindHover ||
            record.kind == MacWSInputKindMenuHover) {
            // A process-local mouseMoved carries a location but does not move
            // WindowServer's authoritative global pointer. NSMenu and Chromium
            // popup trackers use that global state to coordinate both their
            // selection background and selected-text appearance. Post one
            // genuine, button-free system motion from this already-CGS-bound
            // application process. This socket thread remains runnable while
            // the app main thread is synchronously inside TrackMenuCommon.
            MacWSPostLegacyMouseEvent postMouse =
                MacWSLegacySystemMousePoster();
            CGPoint quartzPoint = {
                screenPoint.x,
                snapshot.screenFrame.origin.y +
                    snapshot.screenFrame.size.height - screenPoint.y,
            };
            int32_t result = postMouse
                ? postMouse(quartzPoint, true, 3, false, false, false)
                : -1;
            if (result == 0) {
                if (MacWSRuntimeDiagnosticsEnabled()) {
                    static _Atomic uint64_t nativeHoverPosts;
                    uint64_t post = atomic_fetch_add_explicit(
                        &nativeHoverPosts, 1, memory_order_relaxed) + 1;
                    if (post <= 24 || (post % 600) == 0) {
                        fprintf(stderr,
                            "#### APP-INPUT NATIVE-HOVER pid=%d event=%llu "
                            "kind=%u quartz=(%.2f,%.2f)\n",
                            getpid(), (unsigned long long)post, record.kind,
                            quartzPoint.x, quartzPoint.y);
                        fflush(stderr);
                    }
                }
                if (snapshot.application) CFRelease(snapshot.application);
                return;
            }
        }
        float pressure = record.kind == MacWSInputKindTouchMove
            ? (record.source == MacWSInputSourcePencil
                ? fmaxf(0.0f, fminf(1.0f, record.pressure)) : 1.0f)
            : 0.0f;
        id event = ((MacWSMouseEventFactory)objc_msgSend)(
            (id)snapshot.eventClass,
            sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
            MacWSNSEventType((MacWSInputKind)record.kind), windowPoint, 0,
            record.timestamp, snapshot.windowNumber, nil,
            MacWSNextAppInputEventNumber(), 1, pressure);
        if (event) {
            MacWSMarkProcessLocalMouseEvent(event);
            MacWSApplyTabletMetadata(event, record);
            // Apple documents that events posted from subthreads enter the
            // main-thread event queue.  A Carbon system menu consumes that
            // queue from _NSHLTBMenuEventProc while Electron can continue to
            // append unrelated application events behind the tracker.  A
            // menu hover is a replaceable current-position sample, so put it
            // at the queue head; otherwise it can remain behind Chromium's
            // traffic until after the menu closes.  Gesture move/up records
            // keep FIFO tail ordering because their chronology is semantic.
            BOOL atStart = record.kind == MacWSInputKindMenuHover ||
                (record.kind == MacWSInputKindHover &&
                 atomic_load_explicit(&MacWSAppInputSynchronousTrackingActive,
                                      memory_order_acquire));
            ((MacWSPostEvent)objc_msgSend)(
                (__bridge id)snapshot.application,
                sel_registerName("postEvent:atStart:"), event, atStart);
            // MenuHover is a 60/120-Hz stream just like a live drag.  The old
            // condition treated every menu sample as a transition and forced
            // one synchronous stderr write from this socket thread per event,
            // in addition to the RX log below.  Sample continuous traffic;
            // keep every semantic button/key transition fully logged.
            if (MacWSRuntimeDiagnosticsEnabled()) {
                BOOL continuous = record.kind == MacWSInputKindTouchMove ||
                                  record.kind == MacWSInputKindMenuHover;
                static _Atomic uint64_t continuousPostLogs;
                uint64_t continuousPost = continuous
                    ? atomic_fetch_add_explicit(&continuousPostLogs, 1,
                                                memory_order_relaxed) + 1
                    : 0;
                if (!continuous || continuousPost <= 12 ||
                    (continuousPost % 600) == 0) {
                fprintf(stderr,
                    "#### APP-INPUT LIVE-POST pid=%d kind=%u gesture=%u "
                    "window=%ld screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                    getpid(), record.kind, record.contactID,
                    (long)snapshot.windowNumber, screenPoint.x, screenPoint.y,
                    windowPoint.x, windowPoint.y);
                fflush(stderr);
                }
            }
        } else {
            fprintf(stderr,
                "#### APP-INPUT LIVE-DROP pid=%d kind=%u gesture=%u "
                "reason=event-create\n",
                getpid(), record.kind, record.contactID);
            fflush(stderr);
        }
    }
    MacWSRetireDirectTrackingContextForTerminalRecord(
        record, snapshot.windowNumber);
    if (snapshot.application) CFRelease(snapshot.application);
}

static void MacWSPostDirectMenuTapRecord(
        MacWSInputRecord record, MacWSDirectTrackingSnapshot snapshot) {
    @autoreleasepool {
        CGFloat normalizedX = record.x / (CGFloat)record.frameWidth;
        CGFloat normalizedY = record.y / (CGFloat)record.frameHeight;
        CGPoint screenPoint = {
            snapshot.screenFrame.origin.x +
                normalizedX * snapshot.screenFrame.size.width,
            snapshot.screenFrame.origin.y +
                (1.0 - normalizedY) * snapshot.screenFrame.size.height,
        };
        CGPoint windowPoint = {
            screenPoint.x + snapshot.windowMinusScreen.x,
            screenPoint.y + snapshot.windowMinusScreen.y,
        };
        id downEvent = ((MacWSMouseEventFactory)objc_msgSend)(
            (id)snapshot.eventClass,
            sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
            1 /* NSEventTypeLeftMouseDown */, windowPoint, 0,
            record.timestamp, snapshot.windowNumber, nil,
            MacWSNextAppInputEventNumber(), 1, 1.0f);
        id upEvent = ((MacWSMouseEventFactory)objc_msgSend)(
            (id)snapshot.eventClass,
            sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
            2 /* NSEventTypeLeftMouseUp */, windowPoint, 0,
            record.timestamp + 0.001, snapshot.windowNumber, nil,
            MacWSNextAppInputEventNumber(), 1, 0.0f);
        if (downEvent && upEvent) {
            MacWSMarkProcessLocalMouseEvent(downEvent);
            MacWSMarkProcessLocalMouseEvent(upEvent);
            MacWSApplyTabletMetadata(downEvent, record);
            MacWSInputRecord upRecord = record;
            upRecord.kind = MacWSInputKindTouchUp;
            upRecord.pressure = 0.0f;
            MacWSApplyTabletMetadata(upEvent, upRecord);
            // atStart is a stack. Push up first so the tracker dequeues the
            // complete gesture in down -> up order.
            id application = (__bridge id)snapshot.application;
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), upEvent, YES);
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), downEvent, YES);
            MacWSNotifyDisplayCatalogChanged('t');
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT MENU-TAP-QUEUE pid=%d gesture=%u "
                    "window=%ld screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                    getpid(), record.contactID, (long)snapshot.windowNumber,
                    screenPoint.x, screenPoint.y,
                    windowPoint.x, windowPoint.y);
                fflush(stderr);
            }
        } else {
            fprintf(stderr,
                "#### APP-INPUT LIVE-DROP pid=%d kind=%u gesture=%u "
                "reason=menu-tap-event-create\n",
                getpid(), record.kind, record.contactID);
            fflush(stderr);
        }
    }
    if (snapshot.application) CFRelease(snapshot.application);
}

// The caller holds MacWSAppInputRouteLock, so a socket record cannot pass its
// direct-post decision while this scan is in progress.  Buffered tracking is
// shared by the untargeted RFB canvas and exact native Window Scenes.  Match
// the complete gesture identity here: restricting this scan to RFB's sentinel
// scene made a fast Window-Scene move/up backlog invisible, so the first move
// entered a synchronous AppKit tracker while its already-enqueued release was
// stranded behind that tracker on the main run loop.
static BOOL MacWSHasPendingTrackingRecordLocked(uint64_t sceneID,
                                                 uint32_t contactID) {
    @synchronized(MacWSAppInputPending) {
        for (NSData *data in MacWSAppInputPending) {
            if ([data length] != sizeof(MacWSInputRecord)) continue;
            MacWSInputRecord pending = {0};
            [data getBytes:&pending length:sizeof(pending)];
            if (pending.sceneID == sceneID &&
                pending.contactID == contactID &&
                (pending.kind == MacWSInputKindTouchMove ||
                 pending.kind == MacWSInputKindTouchUp ||
                 pending.kind == MacWSInputKindTouchCancel)) {
                return YES;
            }
        }
    }
    return NO;
}

static id MacWSWindowForScreenPoint(id application, CGPoint screenPoint) {
    SEL frameSelector = sel_registerName("frame");
    id keyWindow = ((MacWSMsgID)objc_msgSend)(application,
        sel_registerName("keyWindow"));
    Class windowClass = objc_getClass("NSWindow");
    SEL globalHitSelector = sel_registerName(
        "windowNumberAtPoint:belowWindowWithWindowNumber:");
    NSInteger globalWindowNumber = 0;
    if (windowClass && class_respondsToSelector(
            object_getClass(windowClass), globalHitSelector)) {
        globalWindowNumber = ((MacWSMsgIntegerPointInteger)objc_msgSend)(
            (id)windowClass, globalHitSelector, screenPoint, 0);
    }
    SEL applicationWindowSelector =
        sel_registerName("windowWithWindowNumber:");
    if (globalWindowNumber > 0 && ((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            applicationWindowSelector)) {
        id globalWindow = ((MacWSMsgIDInteger)objc_msgSend)(
            application, applicationWindowSelector, globalWindowNumber);
        if (!globalWindow) {
            for (id candidate in [MacWSOrderedWindowRegistry allObjects]) {
                NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
                    candidate, sel_registerName("windowNumber"));
                if (number == globalWindowNumber) {
                    globalWindow = candidate;
                    break;
                }
            }
        }
        if (globalWindow) {
            static unsigned transientWindowLogs;
            if (MacWSRuntimeDiagnosticsEnabled() &&
                transientWindowLogs++ < 24) {
                CGRect frame = ((MacWSMsgRect)objc_msgSend)(
                    globalWindow, frameSelector);
                fprintf(stderr,
                    "#### APP-INPUT GLOBAL-WINDOW pid=%d number=%ld "
                    "class=%s frame=(%.1f,%.1f %.1fx%.1f)\n",
                    getpid(), (long)globalWindowNumber,
                    object_getClassName(globalWindow),
                    frame.origin.x, frame.origin.y,
                    frame.size.width, frame.size.height);
                fflush(stderr);
            }
            return globalWindow;
        }
    }
    // orderedWindows is front-to-back. A restored Terminal session can have
    // several overlapping windows while keyWindow still names a covered one.
    // Runtime LLDB evidence for a click on the visible front close button:
    // choosing keyWindow produced local x=116 and dispatched to
    // NSTitlebarView, whereas the visible front window starts at x~=174 and
    // the button is at local x~=29. Hit-test stacking order before using the
    // key/main window as an off-point fallback.
    id windows = ((MacWSMsgID)objc_msgSend)(application,
        sel_registerName("orderedWindows"));
    NSUInteger count = [windows count];
    for (NSUInteger i = 0; i < count; i++) {
        id window = [windows objectAtIndex:i];
        BOOL visible = ((MacWSMsgBool)objc_msgSend)(window,
            sel_registerName("isVisible"));
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(window, frameSelector);
        if (visible && MacWSPointInRect(screenPoint, frame)) return window;
    }
    id trackedHit = nil;
    NSInteger trackedLevel = NSIntegerMin;
    for (id candidate in [MacWSOrderedWindowRegistry allObjects]) {
        BOOL visible = ((MacWSMsgBool)objc_msgSend)(
            candidate, sel_registerName("isVisible"));
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(
            candidate, frameSelector);
        NSInteger level = ((MacWSMsgInteger)objc_msgSend)(
            candidate, sel_registerName("level"));
        if (visible && MacWSPointInRect(screenPoint, frame) &&
            (!trackedHit || level > trackedLevel)) {
            trackedHit = candidate;
            trackedLevel = level;
        }
    }
    if (trackedHit) return trackedHit;
    return keyWindow ?: ((MacWSMsgID)objc_msgSend)(application,
        sel_registerName("mainWindow"));
}

static id MacWSWindowWithNumber(id application, uint32_t windowNumber) {
    if (!application || windowNumber == 0) return nil;
    SEL selector = sel_registerName("windowWithWindowNumber:");
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"), selector)) {
        id window = ((MacWSMsgIDInteger)objc_msgSend)(
            application, selector, (NSInteger)windowNumber);
        if (window) return window;
    }
    id windows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("windows"));
    for (id window in windows) {
        NSInteger candidate = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("windowNumber"));
        if (candidate == (NSInteger)windowNumber) return window;
    }
    for (id window in [MacWSOrderedWindowRegistry allObjects]) {
        NSInteger candidate = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("windowNumber"));
        if (candidate == (NSInteger)windowNumber) return window;
    }
    return nil;
}

static BOOL MacWSWindowPresentationIsOnScreen(id window, BOOL *knownOut) {
    if (knownOut) *knownOut = NO;
    if (!window) return NO;
    NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
        window, sel_registerName("windowNumber"));
    if (number <= 0 || (uint64_t)number > UINT32_MAX) return NO;

    static MacWSCGWindowListCopyWindowInfo copyWindowInfo;
    static id windowNumberKey;
    static id windowOnScreenKey;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *coreGraphics = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY | RTLD_LOCAL);
        if (!coreGraphics) return;
        copyWindowInfo = (MacWSCGWindowListCopyWindowInfo)dlsym(
            coreGraphics, "CGWindowListCopyWindowInfo");
        CFStringRef *numberSymbol = (CFStringRef *)dlsym(
            coreGraphics, "kCGWindowNumber");
        CFStringRef *onScreenSymbol = (CFStringRef *)dlsym(
            coreGraphics, "kCGWindowIsOnscreen");
        if (numberSymbol) windowNumberKey = [(id)*numberSymbol retain];
        if (onScreenSymbol) windowOnScreenKey = [(id)*onScreenSymbol retain];
    });
    if (!copyWindowInfo || !windowNumberKey || !windowOnScreenKey) return NO;

    // `kCGWindowListOptionAll` and `kCGNullWindowID` are both zero.  The
    // target application shares WindowServer's login session, unlike the
    // isolated macwsinputd launchd session, so this is the authoritative
    // presentation state for the existing AppKit window number.
    CFArrayRef copied = copyWindowInfo(0, 0);
    if (!copied) return NO;
    BOOL found = NO;
    BOOL onScreen = NO;
    for (NSDictionary *description in (NSArray *)copied) {
        if ([description[windowNumberKey] integerValue] != number) continue;
        found = YES;
        onScreen = [description[windowOnScreenKey] boolValue];
        break;
    }
    CFRelease(copied);
    if (knownOut) *knownOut = found;
    return onScreen;
}

// Return the frontmost real popup-menu-level window that is visible but does
// not contain this click. CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey) is
// the public source of the level value; no application/class name participates
// in popup discovery. Runtime-confirmed in VSCode: its Views popup is level 101
// and a later AppKit menu is an NSMenuWindowManagerWindow at the same level.
static id MacWSOutsidePopupWindow(id application, id baseWindow,
                                  CGPoint screenPoint) {
    static MacWSCGWindowLevelForKey levelForKey;
    static NSInteger popupLevel;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        levelForKey = (MacWSCGWindowLevelForKey)dlsym(
            RTLD_DEFAULT, "CGWindowLevelForKey");
        if (!levelForKey) {
            // libmachook itself deliberately has no CoreGraphics link. Under
            // the chroot's dyld shared cache, an AppKit dependency is not
            // guaranteed to place every re-export in RTLD_DEFAULT even though
            // the framework is loaded. Resolve from the framework handle just
            // as native callers linked against CoreGraphics do.
            void *coreGraphics = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                RTLD_LAZY | RTLD_LOCAL);
            if (coreGraphics) {
                levelForKey = (MacWSCGWindowLevelForKey)dlsym(
                    coreGraphics, "CGWindowLevelForKey");
            }
        }
        // CGWindowLevelKey is zero-based and the popup-menu key is 11.
        // Runtime probe against this macOS 13.4 CoreGraphics returned
        // key 10 -> 8 (modal), key 11 -> 101 (popup), key 12 -> 500
        // (dragging).  Using 12 here silently searched for drag images and
        // therefore missed every real NSMenuWindowManagerWindow.
        popupLevel = levelForKey
            ? levelForKey(11 /* kCGPopUpMenuWindowLevelKey */) : NSIntegerMax;
    });
    if (!application || !baseWindow || popupLevel == NSIntegerMax) return nil;
    id orderedWindows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("orderedWindows"));
    id applicationWindows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("windows"));
    // NSApplication's orderedWindows intentionally omits some transient menu
    // windows. Runtime evidence in VSCode showed a live layer-101 window in
    // CGWindowList and windowWithWindowNumber:, while orderedWindows.count was
    // exactly one (the document). NSApplication.windows owns those auxiliary
    // objects, so scan the stable union without guessing an application or
    // private window class.
    NSMutableOrderedSet *windowSet = [NSMutableOrderedSet orderedSet];
    if (orderedWindows) [windowSet addObjectsFromArray:orderedWindows];
    if (applicationWindows) [windowSet addObjectsFromArray:applicationWindows];
    NSArray *trackedWindows = [MacWSOrderedWindowRegistry allObjects];
    if (trackedWindows) [windowSet addObjectsFromArray:trackedWindows];
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT POPUP-SCAN pid=%d api=%p level=%ld ordered=%lu "
            "all=%lu tracked=%lu unique=%lu point=(%.1f,%.1f)\n",
            getpid(), levelForKey, (long)popupLevel,
            (unsigned long)[orderedWindows count],
            (unsigned long)[applicationWindows count],
            (unsigned long)[trackedWindows count],
            (unsigned long)[windowSet count], screenPoint.x, screenPoint.y);
    }
    for (id candidate in windowSet) {
        if (candidate == baseWindow || !((MacWSMsgBool)objc_msgSend)(
                candidate, sel_registerName("isVisible"))) continue;
        NSInteger level = ((MacWSMsgInteger)objc_msgSend)(
            candidate, sel_registerName("level"));
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(
            candidate, sel_registerName("frame"));
        if (MacWSRuntimeDiagnosticsEnabled() && level > 0) {
            fprintf(stderr,
                "#### APP-INPUT POPUP-CANDIDATE pid=%d number=%ld class=%s "
                "level=%ld frame=(%.1f,%.1f %.1fx%.1f)\n",
                getpid(),
                (long)((MacWSMsgInteger)objc_msgSend)(
                    candidate, sel_registerName("windowNumber")),
                object_getClassName(candidate), (long)level,
                frame.origin.x, frame.origin.y,
                frame.size.width, frame.size.height);
        }
        if (level == popupLevel && !MacWSPointInRect(screenPoint, frame))
            return candidate;
    }
    return nil;
}

static void MacWSRequiredContentSizeLimits(id window, CGSize *minimum,
                                            CGSize *maximum) {
    id content = ((MacWSMsgID)objc_msgSend)(window,
        sel_registerName("contentView"));
    NSArray *constraints = content ? ((MacWSMsgID)objc_msgSend)(content,
        sel_registerName("constraints")) : nil;
    // RE-confirmed in the device's Finder: setContentView at 0x100457548
    // activates root contentView.width >= natural minimum and width <= 400
    // (0x100457658), without updating NSWindow.maxSize. Read that actual
    // NSLayoutConstraint contract, not its observed frame or a class constant.
    // Do not attempt to infer general cross-view/soft Auto Layout equations.
    for (id constraint in constraints) {
        if (!((MacWSMsgBool)objc_msgSend)(constraint,
                sel_registerName("isActive")) ||
            ((MacWSMsgFloat)objc_msgSend)(constraint,
                sel_registerName("priority")) < 1000.0f ||
            ((MacWSMsgID)objc_msgSend)(constraint,
                sel_registerName("firstItem")) != content ||
            ((MacWSMsgID)objc_msgSend)(constraint,
                sel_registerName("secondItem")) != nil) continue;
        NSInteger attribute = ((MacWSMsgInteger)objc_msgSend)(constraint,
            sel_registerName("firstAttribute"));
        if (attribute != 7 && attribute != 8) continue; // Width/Height.
        double constant = ((MacWSMsgDouble)objc_msgSend)(constraint,
            sel_registerName("constant"));
        if (!isfinite(constant) || constant < 0.0 ||
            constant > MACWS_STREAM_MAX_DIMENSION) continue;
        NSInteger relation = ((MacWSMsgInteger)objc_msgSend)(constraint,
            sel_registerName("relation"));
        CGFloat *lower = attribute == 7 ? &minimum->width : &minimum->height;
        CGFloat *upper = attribute == 7 ? &maximum->width : &maximum->height;
        if (relation >= 0) *lower = fmax(*lower, constant);
        if (relation <= 0) *upper = fmin(*upper, constant);
    }
}

static CGSize MacWSEffectiveMinimumFrameSize(id window, CGRect frame,
                                              BOOL *resizableOut,
                                              CGSize *maximumOut) {
    NSUInteger styleMask = ((MacWSMsgUInteger)objc_msgSend)(
        window, sel_registerName("styleMask"));
    BOOL resizable = (styleMask & (1u << 3)) != 0;

    // Finder's Get Info inspector changes style from 0x7 to 0xf after it is
    // ordered, but its public minSize/maxSize remain 0x28/16384x16384. The
    // exact runtime witness in Finder.host.log (window class TInfoWindow,
    // generations 8-11) therefore cannot express its intended interaction:
    // the current content chooses height while the user may change width.
    // Read the actual width anchors below and publish the live frame height
    // as a content-driven fixed axis. Expanding General
    // or More Info changes the real frame and naturally publishes a new fixed
    // height; no title/localization heuristic or frame transform is involved.
    Class infoWindowClass = objc_getClass("TInfoWindow");
    BOOL contentDrivenHeight = infoWindowClass &&
        ((MacWSMsgBoolID)objc_msgSend)(
            window, sel_registerName("isKindOfClass:"), infoWindowClass);
    if (contentDrivenHeight) resizable = YES;
    if (resizableOut) *resizableOut = resizable;
    if (!resizable) {
        if (maximumOut) *maximumOut = frame.size;
        return frame.size;
    }

    CGSize frameMinimum = {0};
    CGSize contentMinimum = {0};
    CGSize contentMaximum = {
        MACWS_STREAM_MAX_DIMENSION, MACWS_STREAM_MAX_DIMENSION,
    };
    SEL minSizeSelector = sel_registerName("minSize");
    SEL contentMinSelector = sel_registerName("contentMinSize");
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), minSizeSelector))
        frameMinimum = ((MacWSMsgSize)objc_msgSend)(window,
                                                      minSizeSelector);
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), contentMinSelector))
        contentMinimum = ((MacWSMsgSize)objc_msgSend)(window,
                                                       contentMinSelector);
    SEL contentMaxSelector = sel_registerName("contentMaxSize");
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), contentMaxSelector)) {
        CGSize value = ((MacWSMsgSize)objc_msgSend)(window, contentMaxSelector);
        if (isfinite(value.width) && value.width > 0.0)
            contentMaximum.width = fmin(contentMaximum.width, value.width);
        if (isfinite(value.height) && value.height > 0.0)
            contentMaximum.height = fmin(contentMaximum.height, value.height);
    }
    MacWSRequiredContentSizeLimits(window, &contentMinimum, &contentMaximum);
    CGRect contentRect = frame;
    SEL contentRectSelector = sel_registerName("contentRectForFrameRect:");
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"),
            contentRectSelector)) {
        contentRect = ((MacWSMsgRectRect)objc_msgSend)(
            window, contentRectSelector, frame);
    }
    CGFloat width = fmax(frameMinimum.width,
        contentMinimum.width + fmax(0.0,
            frame.size.width - contentRect.size.width));
    CGFloat height = fmax(frameMinimum.height,
        contentMinimum.height + fmax(0.0,
            frame.size.height - contentRect.size.height));
    if (!isfinite(width) || width < 0.0 ||
        width > MACWS_STREAM_MAX_DIMENSION) width = 0.0;
    if (!isfinite(height) || height < 0.0 ||
        height > MACWS_STREAM_MAX_DIMENSION) height = 0.0;
    CGSize minimum = {width, height};
    CGSize maximum = {
        fmin(MACWS_STREAM_MAX_DIMENSION, contentMaximum.width +
             fmax(0.0, frame.size.width - contentRect.size.width)),
        fmin(MACWS_STREAM_MAX_DIMENSION, contentMaximum.height +
             fmax(0.0, frame.size.height - contentRect.size.height)),
    };
    SEL maxSizeSelector = sel_registerName("maxSize");
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), maxSizeSelector)) {
        CGSize value = ((MacWSMsgSize)objc_msgSend)(window, maxSizeSelector);
        if (isfinite(value.width) && value.width > 0.0)
            maximum.width = fmin(value.width, maximum.width);
        if (isfinite(value.height) && value.height > 0.0)
            maximum.height = fmin(value.height, maximum.height);
    }
    // RE-confirmed in the actual macOS 13.4 AppKit, 0x184110e00/e08:
    // this native query solves the whole window's Auto Layout min/max, then
    // intersects minSize/maxSize. Its wrapper explicitly passes
    // changingOnlySlightly=NO; using the nearby YES path would instead bound
    // the answer around the current frame (0x184110f8c), not a global limit.
    // Root-only constant constraints above cannot represent Finder's nested
    // split-view minimum. Runtime 1789179434: CGWindow 290 was 445 wide while
    // the earlier configure ACK claimed 409 and the published minimum was 0.
    SEL nativeLimits = sel_registerName("_getConstrainedWindowMinSize:maxSize:");
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), nativeLimits)) {
        CGSize nativeMinimum = {NAN, NAN}, nativeMaximum = {NAN, NAN};
        ((void (*)(id, SEL, CGSize *, CGSize *))objc_msgSend)(
            window, nativeLimits, &nativeMinimum, &nativeMaximum);
        if (isfinite(nativeMinimum.width) && nativeMinimum.width >= 0.0 &&
            nativeMinimum.width <= MACWS_STREAM_MAX_DIMENSION)
            minimum.width = fmax(minimum.width, nativeMinimum.width);
        if (isfinite(nativeMinimum.height) && nativeMinimum.height >= 0.0 &&
            nativeMinimum.height <= MACWS_STREAM_MAX_DIMENSION)
            minimum.height = fmax(minimum.height, nativeMinimum.height);
        if (isfinite(nativeMaximum.width) && nativeMaximum.width > 0.0)
            maximum.width = fmin(maximum.width, nativeMaximum.width);
        if (isfinite(nativeMaximum.height) && nativeMaximum.height > 0.0)
            maximum.height = fmin(maximum.height, nativeMaximum.height);
        // The witness is only a log deduplicator. Do not allocate/compare
        // NSData or modify associated objects at every production metrics poll.
        // The real native limit query and all constraint math stay above.
        if (MacWSRuntimeDiagnosticsEnabled()) {
            static char nativeLimitsWitnessKey;
            CGSize witness[2] = {minimum, maximum};
            NSData *previous = objc_getAssociatedObject(window, &nativeLimitsWitnessKey);
            NSData *current = [NSData dataWithBytes:witness length:sizeof(witness)];
            if (![previous isEqualToData:current]) {
                objc_setAssociatedObject(window, &nativeLimitsWitnessKey, current,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                fprintf(stderr, "#### APP-INPUT NATIVE-CONSTRAINT-LIMITS pid=%d window=%ld "
                    "minimum=%.1fx%.1f maximum=%.1fx%.1f source=appkit-layout-engine\n",
                    getpid(), (long)((MacWSMsgInteger)objc_msgSend)(window,
                        sel_registerName("windowNumber")), minimum.width, minimum.height,
                    maximum.width, maximum.height);
            }
        }
    }
    if (contentDrivenHeight) {
        // Disclosures own height; native width anchors own width. Before
        // anchors exist, leave that width unknown rather than caching an
        // observed frame as a minimum.
        minimum.height = maximum.height = frame.size.height;
    }
    maximum.width = fmax(maximum.width, minimum.width);
    maximum.height = fmax(maximum.height, minimum.height);
    if (maximumOut) *maximumOut = maximum;
    return minimum;
}

// Apply the same public NSWindow constraints that participate in an ordinary
// user resize before committing a Host-requested Scene geometry.  A style-mask
// Resizable bit is only the coarse capability: Settings uses dimensional
// limits, and Steam's short-lived sign-in/loading windows publish sizes that
// do not share the iPad Scene's aspect ratio.  setFrame: is a programmatic
// setter and does not provide the interactive windowWillResize:toSize:
// delegate boundary on our behalf, so preserve that application policy here.
static CGSize MacWSConstrainedWindowFrameSize(id window, CGRect frame,
                                               CGSize proposed,
                                               CGSize minimum,
                                               CGSize *maximumOut,
                                               CGSize *aspectOut,
                                               CGSize *incrementsOut) {
    CGSize maximum = CGSizeZero;
    (void)MacWSEffectiveMinimumFrameSize(window, frame, NULL, &maximum);
    CGSize aspect = CGSizeZero;
    CGSize increments = CGSizeZero;
    SEL aspectSelector = sel_registerName("aspectRatio");
    SEL incrementsSelector = sel_registerName("resizeIncrements");
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), aspectSelector)) {
        CGSize value = ((MacWSMsgSize)objc_msgSend)(window, aspectSelector);
        if (isfinite(value.width) && isfinite(value.height) &&
            value.width > 0.0 && value.height > 0.0)
            aspect = value;
    }
    if (((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), incrementsSelector)) {
        CGSize value = ((MacWSMsgSize)objc_msgSend)(window,
                                                     incrementsSelector);
        if (isfinite(value.width) && value.width > 1.0)
            increments.width = value.width;
        if (isfinite(value.height) && value.height > 1.0)
            increments.height = value.height;
    }

    maximum.width = fmax(maximum.width, minimum.width);
    maximum.height = fmax(maximum.height, minimum.height);
    proposed.width = fmin(fmax(proposed.width, minimum.width), maximum.width);
    proposed.height = fmin(fmax(proposed.height, minimum.height), maximum.height);
    if (aspect.width > 0.0 && aspect.height > 0.0) {
        CGFloat ratio = aspect.width / aspect.height;
        CGFloat fittedWidth = proposed.height * ratio;
        CGFloat fittedHeight = proposed.width / ratio;
        if (fittedWidth <= proposed.width)
            proposed.width = fittedWidth;
        else
            proposed.height = fittedHeight;
        if (proposed.width < minimum.width) {
            proposed.width = minimum.width;
            proposed.height = proposed.width / ratio;
        }
        if (proposed.height < minimum.height) {
            proposed.height = minimum.height;
            proposed.width = proposed.height * ratio;
        }
        proposed.width = fmin(proposed.width, maximum.width);
        proposed.height = fmin(proposed.height, maximum.height);
    }
    if (increments.width > 0.0) {
        proposed.width = minimum.width + round(
            (proposed.width - minimum.width) / increments.width) *
                increments.width;
    }
    if (increments.height > 0.0) {
        proposed.height = minimum.height + round(
            (proposed.height - minimum.height) / increments.height) *
                increments.height;
    }
    proposed.width = fmin(fmax(proposed.width, minimum.width), maximum.width);
    proposed.height = fmin(fmax(proposed.height, minimum.height), maximum.height);

    id delegate = ((MacWSMsgID)objc_msgSend)(window,
        sel_registerName("delegate"));
    SEL willResize = sel_registerName("windowWillResize:toSize:");
    if (delegate && ((MacWSMsgBoolSEL)objc_msgSend)(delegate,
            sel_registerName("respondsToSelector:"), willResize)) {
        CGSize delegated = ((MacWSMsgSizeIDSize)objc_msgSend)(
            delegate, willResize, window, proposed);
        if (isfinite(delegated.width) && isfinite(delegated.height) &&
            delegated.width > 0.0 && delegated.height > 0.0)
            proposed = delegated;
    }
    proposed.width = fmin(fmax(proposed.width, minimum.width), maximum.width);
    proposed.height = fmin(fmax(proposed.height, minimum.height), maximum.height);
    if (!isfinite(proposed.width) || proposed.width <= 0.0)
        proposed.width = frame.size.width;
    if (!isfinite(proposed.height) || proposed.height <= 0.0)
        proposed.height = frame.size.height;
    if (maximumOut) *maximumOut = maximum;
    if (aspectOut) *aspectOut = aspect;
    if (incrementsOut) *incrementsOut = increments;
    return proposed;
}

// Complete the real AppKit lifecycle when CGS deactivation succeeded but the
// chroot never delivered its corresponding Workspace event.  On-device LLDB
// disassembly of macOS 13.4 proves this handler does not read x2/the event
// argument; it performs the complete notification, active-bit, key/main, and
// window refresh transaction that is otherwise missing here.
static BOOL MacWSDeliverMissingDeactivateEvent(id application) {
    if (!application || !((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"))) return NO;
    SEL handlerSelector = sel_registerName("_handleDeactivateEvent:");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            handlerSelector)) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(
        application, handlerSelector, nil);
    return YES;
}

// RE-confirmed on-device against HIToolbox 13.4:
// HIApplication::HandleActivated(event, active=false, ...) calls
// IsCurrentProcessMenuBarOwner before deciding between BeginNonActiveMenuBar
// and FrontUILost.  Runtime target replies from Terminal and GlassDemo show
// that both processes simultaneously see their own PSN as the menu-bar owner,
// so the old application takes the former branch even after the broker has
// selected and activated a different process.  FrontUILost is the complete
// upstream false-owner branch: SetMenuBarObscured(1),
// _DeactivateWindowGroups, font-cache
// reset, and EndNonActiveMenuBar.  Execute that real idempotent lifecycle only
// for the non-target applications selected by the system-wide broker.
// HIApplicationGetCurrent/GetApplication returns the HIObject wrapper;
// GetAppObject is the RE-confirmed accessor that loads wrapper+0x10 and returns
// the internal C++ object required as FrontUILost's this pointer.
static void *MacWSResolveHIToolboxLocal(uintptr_t imageOffset,
                                        const uint8_t *expectedPrologue,
                                        size_t expectedPrologueSize) {
    // These routines are present in LLDB's local-symbol view but absent from
    // HIToolbox's export trie.  Use the exact macOS 13.4 image only after both
    // its LC_UUID and the RE-captured function prologue match.  Any other
    // build stays unsupported instead of jumping through an unverified offset.
    static const uint8_t expectedUUID[16] = {
        0xd8, 0x00, 0x27, 0x8b, 0x4e, 0x6c, 0x30, 0x32,
        0xb5, 0x6f, 0x02, 0x7a, 0x93, 0x8a, 0x51, 0xd6,
    };
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name || !strstr(name, "/HIToolbox.framework/")) continue;
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64) return NULL;
        const struct load_command *command =
            (const struct load_command *)((const uint8_t *)header +
                                           sizeof(*header));
        BOOL uuidMatches = NO;
        for (uint32_t item = 0; item < header->ncmds; item++) {
            if (command->cmdsize < sizeof(*command)) return NULL;
            if (command->cmd == LC_UUID &&
                command->cmdsize >= sizeof(struct uuid_command)) {
                const struct uuid_command *uuid =
                    (const struct uuid_command *)command;
                uuidMatches = memcmp(uuid->uuid, expectedUUID,
                                     sizeof(expectedUUID)) == 0;
                break;
            }
            command = (const struct load_command *)(
                (const uint8_t *)command + command->cmdsize);
        }
        if (!uuidMatches) return NULL;
        const uint8_t *candidate =
            (const uint8_t *)header + imageOffset;
        if (memcmp(candidate, expectedPrologue,
                   expectedPrologueSize) != 0) return NULL;
        return ptrauth_sign_unauthenticated(
            (void *)candidate, ptrauth_key_function_pointer, 0);
    }
    return NULL;
}

static BOOL MacWSCompleteFrontUILostLifecycle(void) {
    static MacWSHIApplicationGetAppObject getAppObject;
    static MacWSHIApplicationFrontUILost frontUILost;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getAppObject = (MacWSHIApplicationGetAppObject)dlsym(
            RTLD_DEFAULT, "_ZN13HIApplication12GetAppObjectEv");
        frontUILost = (MacWSHIApplicationFrontUILost)dlsym(
            RTLD_DEFAULT, "_ZN13HIApplication11FrontUILostEv");
        static const uint8_t getAppObjectPrologue[16] = {
            0x7f, 0x23, 0x03, 0xd5, 0xfd, 0x7b, 0xbf, 0xa9,
            0xfd, 0x03, 0x00, 0x91, 0xef, 0xa7, 0xfe, 0x97,
        };
        static const uint8_t frontUILostPrologue[16] = {
            0x7f, 0x23, 0x03, 0xd5, 0xf4, 0x4f, 0xbe, 0xa9,
            0xfd, 0x7b, 0x01, 0xa9, 0xfd, 0x43, 0x00, 0x91,
        };
        if (!getAppObject) {
            getAppObject = (MacWSHIApplicationGetAppObject)
                MacWSResolveHIToolboxLocal(
                    0x59778, getAppObjectPrologue,
                    sizeof(getAppObjectPrologue));
        }
        if (!frontUILost) {
            frontUILost = (MacWSHIApplicationFrontUILost)
                MacWSResolveHIToolboxLocal(
                    0x4d608, frontUILostPrologue,
                    sizeof(frontUILostPrologue));
        }
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT FRONT-UI-LOST-RESOLVE pid=%d "
                "get-app-object=%p front-ui-lost=%p\n",
                getpid(), getAppObject, frontUILost);
            fflush(stderr);
        }
    });
    if (!getAppObject || !frontUILost) return NO;
    void *application = getAppObject();
    if (!application) return NO;
    frontUILost(application);
    return YES;
}

// AppKit has two main-menu implementations in this build.  The modern
// NSMenuBarImpl clear method is intentionally a no-op, while the compatibility
// NSCarbonMenuImpl clearAsMainCarbonMenuBar tail-calls
// _menuLostMainMenuStatus.  On-device disassembly proves that routine clears
// its main-menu bit, removes linked shortcut menus, and destroys the old
// principal MenuRef.  This is the real counterpart to the target's
// setAsMainCarbonMenuBar -> SetRootMenu transaction.
static const char *MacWSClearMainMenuBar(id application) {
    if (!application) return "NO-APPLICATION";
    id mainMenu = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("mainMenu"));
    if (!mainMenu) return "NO-MENU";
    id implementation = ((MacWSMsgID)objc_msgSend)(
        mainMenu, sel_registerName("_menuImpl"));
    if (!implementation) return "NO-IMPLEMENTATION";
    SEL clearMenuBar = sel_registerName("clearAsMainMenuBar");
    SEL clearCarbonMenuBar =
        sel_registerName("clearAsMainCarbonMenuBar");
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            implementation, sel_registerName("respondsToSelector:"),
            clearMenuBar)) {
        ((MacWSMsgVoid)objc_msgSend)(implementation, clearMenuBar);
        return "APPKIT";
    }
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            implementation, sel_registerName("respondsToSelector:"),
            clearCarbonMenuBar)) {
        ((MacWSMsgVoid)objc_msgSend)(
            implementation, clearCarbonMenuBar);
        return "CARBON";
    }
    return "UNAVAILABLE";
}

// RE-confirmed with the project LLDB helper against the exact macOS 13.4
// AppKit image: -_handleActivatedEvent: consumes windowNumber at +376, data1
// at +628, and data2 at +488/+1188.  Its windowNumber==0 branch is deliberate:
// both Terminal and Electron received a real startup activation event with
// window=0/data2=64, and the method proceeds through WillBecomeActive, sets
// NSApplication's active bit at +924/+928, then posts DidBecomeActive.  Do not
// fabricate that object.  The witness above retains the exact system event
// AppKit received in this process.  A recent window-bound event must still
// resolve to one of this application's windows.  The windowless system event
// is accepted only with the runtime-observed data2=64 signature and only from
// this user-triggered ActivateTarget recovery path after isActive stayed false.
static BOOL MacWSDeliverMissingActivateEvent(id application) {
    if (!application || !MacWSOriginalHandleActivatedEvent ||
        !MacWSLastSystemActivationEvent ||
        ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"))) return NO;
    double age = MacWSAppInputMonotonicSeconds() -
        MacWSLastSystemActivationEventTime;
    if (age < 0.0) return NO;
    id event = (__bridge id)MacWSLastSystemActivationEvent;
    NSInteger eventWindowNumber = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("windowNumber"));
    NSInteger eventData1 = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("data1"));
    NSInteger eventData2 = ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("data2"));
    // _handleDeactivateEvent: intentionally clears keyWindow/mainWindow, so
    // keyWindow cannot validate the retained event here.  Match AppKit's own
    // _handleActivatedEvent:+396 validation instead: the event's window
    // number must still resolve inside this NSApplication.
    BOOL windowBoundEvent = eventWindowNumber > 0;
    id eventWindow = windowBoundEvent
        ? ((MacWSMsgIDInteger)objc_msgSend)(
            application, sel_registerName("windowWithWindowNumber:"),
            eventWindowNumber) : nil;
    BOOL recentOwnedWindowEvent = windowBoundEvent && eventWindow && age <= 1.5;
    BOOL authenticWindowlessSystemEvent =
        eventWindowNumber == 0 && eventData2 == 64;
    if (!recentOwnedWindowEvent && !authenticWindowlessSystemEvent) {
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT SYSTEM-ACTIVATE-REPLAY-REJECT pid=%d "
                "age=%.3f window=%ld owned=%s data1=%ld data2=%ld\n",
                getpid(), age, (long)eventWindowNumber,
                eventWindow ? "YES" : "NO", (long)eventData1,
                (long)eventData2);
            fflush(stderr);
        }
        return NO;
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT SYSTEM-ACTIVATE-REPLAY pid=%d age=%.3f "
            "window=%ld data1=%ld data2=%ld provenance=%s\n",
            getpid(), age, (long)eventWindowNumber, (long)eventData1,
            (long)eventData2, recentOwnedWindowEvent
                ? "RECENT-OWNED-WINDOW" : "AUTHENTIC-WINDOWLESS-SYSTEM");
        fflush(stderr);
    }
    CFRetain((__bridge CFTypeRef)event);
    MacWSOriginalHandleActivatedEvent(
        application, sel_registerName("_handleActivatedEvent:"), event);
    CFRelease((__bridge CFTypeRef)event);
    return ((MacWSMsgBool)objc_msgSend)(
        application, sel_registerName("isActive"));
}

// Resolve a current native menu item by its actual key equivalent instead of
// assuming an application-private selector. The concrete target and action
// belong to the running application and may change with responder state.
static id MacWSFindEnabledCommandMenuItem(id menu, NSString *wantedKey,
                                          NSUInteger depth) {
    if (!menu || !wantedKey.length || depth >= MACWS_MENU_MAX_DEPTH) return nil;
    SEL updateSelector = sel_registerName("update");
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            menu, sel_registerName("respondsToSelector:"), updateSelector))
        ((MacWSMsgVoid)objc_msgSend)(menu, updateSelector);
    id items = ((MacWSMsgID)objc_msgSend)(
        menu, sel_registerName("itemArray"));
    if (![items isKindOfClass:objc_getClass("NSArray")]) return nil;
    for (id item in items) {
        id submenu = ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("submenu"));
        id nested = MacWSFindEnabledCommandMenuItem(
            submenu, wantedKey, depth + 1);
        if (nested) return nested;
        id key = ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("keyEquivalent"));
        if (![key isKindOfClass:objc_getClass("NSString")] ||
            [key caseInsensitiveCompare:wantedKey] != NSOrderedSame)
            continue;
        NSUInteger modifiers = ((MacWSMsgUInteger)objc_msgSend)(
            item, sel_registerName("keyEquivalentModifierMask"));
        const NSUInteger relevant = (1u << 17) | (1u << 18) |
                                    (1u << 19) | (1u << 20);
        if ((modifiers & relevant) != (1u << 20) ||
            ((MacWSMsgBool)objc_msgSend)(item,
                sel_registerName("isHidden")) ||
            !((MacWSMsgBool)objc_msgSend)(item,
                sel_registerName("isEnabled")) ||
            !((SEL (*)(id, SEL))objc_msgSend)(item,
                sel_registerName("action")))
            continue;
        return item;
    }
    return nil;
}

// AppKit defines Command-N as the standard new-window/new-document action.
static id MacWSFindInitialWindowMenuItem(id menu, NSUInteger depth) {
    return MacWSFindEnabledCommandMenuItem(
        menu, MacWSRuntimeString("n"), depth);
}

static id MacWSFindEnabledMenuItemWithTitle(id menu, NSString *wantedTitle,
                                            NSUInteger depth) {
    if (!menu || !wantedTitle.length || depth >= MACWS_MENU_MAX_DEPTH)
        return nil;
    SEL updateSelector = sel_registerName("update");
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            menu, sel_registerName("respondsToSelector:"), updateSelector))
        ((MacWSMsgVoid)objc_msgSend)(menu, updateSelector);
    id items = ((MacWSMsgID)objc_msgSend)(
        menu, sel_registerName("itemArray"));
    if (![items isKindOfClass:objc_getClass("NSArray")]) return nil;
    for (id item in items) {
        id title = ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("title"));
        if ([title isKindOfClass:objc_getClass("NSString")] &&
            [title localizedCaseInsensitiveCompare:wantedTitle] ==
                NSOrderedSame &&
            !((MacWSMsgBool)objc_msgSend)(item,
                sel_registerName("isHidden")) &&
            ((MacWSMsgBool)objc_msgSend)(item,
                sel_registerName("isEnabled")) &&
            ((SEL (*)(id, SEL))objc_msgSend)(item,
                sel_registerName("action")))
            return item;
        id nested = MacWSFindEnabledMenuItemWithTitle(
            ((MacWSMsgID)objc_msgSend)(item, sel_registerName("submenu")),
            wantedTitle, depth + 1);
        if (nested) return nested;
    }
    return nil;
}

static id MacWSMainBundleIdentifier(void) {
    Class bundleClass = objc_getClass("NSBundle");
    id bundle = bundleClass ? ((MacWSMsgID)objc_msgSend)(
        (id)bundleClass, sel_registerName("mainBundle")) : nil;
    return bundle ? ((MacWSMsgID)objc_msgSend)(
        bundle, sel_registerName("bundleIdentifier")) : nil;
}

static BOOL MacWSMainBundleIsFinder(void) {
    id identifier = MacWSMainBundleIdentifier();
    return [identifier isEqualToString:
        MacWSRuntimeString("com.apple.finder")];
}

static BOOL MacWSMainBundleUsesSpatialCanvasTouch(void) {
    id identifier = MacWSMainBundleIdentifier();
    // macOS Maps implements pan as a primary-button tracking sequence and
    // zoom as scroll/magnify. Runtime-confirmed symptom on the target iPad:
    // MacWS's document-wide one-finger Scroll route zoomed the map instead of
    // moving it. Publish an application-content capability at the owning
    // AppKit process rather than guessing from a title, window position or
    // map control hit point. Future spatial canvases can join this identity
    // table without changing the transport or gesture state machine.
    return [identifier isEqualToString:
        MacWSRuntimeString("com.apple.Maps")];
}

static BOOL MacWSMainBundleUsesFullscreenCanvasPresentation(void) {
    id identifier = MacWSMainBundleIdentifier();
    // Runtime-confirmed from the installed Stray.app Info.plist on the target
    // iPad: CFBundleIdentifier=com.annapurnainteractive.Stray.  The game's
    // lower-resolution FCocoaWindow remains a real WindowServer layer rather
    // than resizing the 2388x1668 desktop.  Publish that application-level
    // presentation capability here so Host can fit the exact catalog window
    // without guessing from a localized title or a transient rectangle.
    // Runtime-confirmed on the iPad14,5 7DTD deployment: the prepared native
    // Unity 2022.3.62f2 process publishes a focused 1366x1024 game window with
    // bundle identifier com.The-Fun-Pimps.7-Days-To-Die and sends its real
    // CAMetalDrawable IOSurfaces through the same direct-drawable transport.
    // Without this capability its catalog flags were 0x49 (Focused, Visible,
    // Resizable) while the off-screen Steam Helper was 0x20f, so fullscreen
    // Host selected the helper and kept rendering the 2732x2048 desktop
    // capture instead of the game's 1366x1024 drawable.
    return [identifier isEqualToString:
                MacWSRuntimeString("com.annapurnainteractive.Stray")] ||
        [identifier isEqualToString:
                MacWSRuntimeString("com.The-Fun-Pimps.7-Days-To-Die")];
}

static NSSet *MacWSVisibleWindowNumberSnapshot(id application) {
    NSMutableSet *numbers = [NSMutableSet set];
    id windows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("windows"));
    if (![windows isKindOfClass:objc_getClass("NSArray")]) return numbers;
    for (id window in windows) {
        if (!((MacWSMsgBool)objc_msgSend)(
                window, sel_registerName("isVisible"))) continue;
        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("windowNumber"));
        if (number > 0) [numbers addObject:@(number)];
    }
    return numbers;
}

static id MacWSNewVisibleWindowSince(id application, NSSet *previousNumbers) {
    id windows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("windows"));
    if (![windows isKindOfClass:objc_getClass("NSArray")]) return nil;
    for (id window in windows) {
        if (!((MacWSMsgBool)objc_msgSend)(
                window, sel_registerName("isVisible"))) continue;
        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("windowNumber"));
        if (number > 0 && ![previousNumbers containsObject:@(number)])
            return window;
    }
    return nil;
}

static void MacWSCompleteFinderInitialWindow(id application,
                                              NSSet *previousNumbers,
                                              unsigned attempt) {
    id newWindow = MacWSNewVisibleWindowSince(application, previousNumbers);
    if (!newWindow && attempt < 80) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSCompleteFinderInitialWindow(
                application, previousNumbers, attempt + 1);
        });
        return;
    }
    if (newWindow) {
        id keyWindow = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("keyWindow"));
        if (keyWindow != newWindow &&
            ((MacWSMsgBool)objc_msgSend)(
                newWindow, sel_registerName("canBecomeKeyWindow")))
            ((MacWSMsgVoid)objc_msgSend)(
                newWindow, sel_registerName("makeKeyWindow"));
        id currentMenu = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainMenu"));
        id homeItem = MacWSFindEnabledMenuItemWithTitle(
            currentMenu, MacWSRuntimeString("Home"), 0);
        SEL homeAction = homeItem
            ? ((SEL (*)(id, SEL))objc_msgSend)(
                homeItem, sel_registerName("action")) : NULL;
        id homeTarget = homeItem
            ? ((MacWSMsgID)objc_msgSend)(
                homeItem, sel_registerName("target")) : nil;
        BOOL openedHome = homeAction &&
            ((MacWSMsgBoolSELIDID)objc_msgSend)(
                application, sel_registerName("sendAction:to:from:"),
                homeAction, homeTarget, homeItem);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT FINDER-HOME pid=%d attempt=%u window=%ld "
                "item=%s action=%s performed=%s\n",
                getpid(), attempt,
                (long)((MacWSMsgInteger)objc_msgSend)(
                    newWindow, sel_registerName("windowNumber")),
                homeItem ? "Home" : "nil",
                homeAction ? sel_getName(homeAction) : "nil",
                openedHome ? "YES" : "NO");
            fflush(stderr);
        }
    } else if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT FINDER-HOME pid=%d result=no-new-window "
            "attempts=%u\n", getpid(), attempt);
        fflush(stderr);
    }
    MacWSPublishWindowMetrics();
    MacWSNotifyDisplayCatalogChanged('n');
}

static void MacWSOpenDocumentPaths(MacWSInputRecord record,
                                   char *sidecar, size_t sidecarSize,
                                   char *ack, size_t ackSize) {
    snprintf(sidecar, sidecarSize, "%s.%d.%016llx.plist",
             MACWS_OPEN_DOCUMENT_SIDECAR_PREFIX, getpid(),
             (unsigned long long)record.sceneID);
    snprintf(ack, ackSize, "%s_ack.%d.%016llx.bin",
             MACWS_OPEN_DOCUMENT_SIDECAR_PREFIX, getpid(),
             (unsigned long long)record.sceneID);
}

static NSArray<NSString *> *MacWSCopyValidatedOpenDocumentPaths(
        MacWSInputRecord record) {
    char sidecar[PATH_MAX] = {0};
    char ack[PATH_MAX] = {0};
    MacWSOpenDocumentPaths(record, sidecar, sizeof(sidecar), ack,
                           sizeof(ack));
    struct stat status = {0};
    if (lstat(sidecar, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_nlink != 1 || status.st_uid != geteuid() ||
        (status.st_mode & 077) != 0 || status.st_size <= 0 ||
        status.st_size > 1024 * 1024) {
        fprintf(stderr,
            "#### APP-INPUT OPEN-DOCUMENTS pid=%d nonce=%016llx "
            "result=invalid-sidecar errno=%d mode=%#o size=%lld\n",
            getpid(), (unsigned long long)record.sceneID, errno,
            status.st_mode, (long long)status.st_size);
        fflush(stderr);
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:
        MacWSRuntimeString(sidecar)];
    (void)unlink(sidecar);
    if (!data) return nil;
    NSError *error = nil;
    id payload = [NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListImmutable
                      format:NULL
                       error:&error];
    if (![payload isKindOfClass:objc_getClass("NSDictionary")]) {
        fprintf(stderr,
            "#### APP-INPUT OPEN-DOCUMENTS pid=%d nonce=%016llx "
            "result=invalid-payload error=%s\n",
            getpid(), (unsigned long long)record.sceneID,
            error.localizedDescription.UTF8String ?: "none");
        fflush(stderr);
        return nil;
    }
    id version = [payload objectForKey:MacWSRuntimeString("version")];
    id nonce = [payload objectForKey:MacWSRuntimeString("nonce")];
    id targetPID = [payload objectForKey:MacWSRuntimeString("target_pid")];
    id candidatePaths = [payload objectForKey:MacWSRuntimeString("paths")];
    if ([version unsignedIntegerValue] != 1 ||
        [nonce unsignedLongLongValue] != record.sceneID ||
        [targetPID intValue] != getpid() ||
        ![candidatePaths isKindOfClass:objc_getClass("NSArray")]) {
        fprintf(stderr,
            "#### APP-INPUT OPEN-DOCUMENTS pid=%d nonce=%016llx "
            "result=invalid-payload error=%s\n",
            getpid(), (unsigned long long)record.sceneID,
            error.localizedDescription.UTF8String ?: "none");
        fflush(stderr);
        return nil;
    }
    NSArray *candidates = candidatePaths;
    if (candidates.count == 0 || candidates.count > 128) return nil;
    NSMutableArray<NSString *> *paths =
        [NSMutableArray arrayWithCapacity:candidates.count];
    for (id candidate in candidates) {
        if (![candidate isKindOfClass:objc_getClass("NSString")]) return nil;
        NSString *path = [(NSString *)candidate stringByStandardizingPath];
        struct stat fileStatus = {0};
        if (!path.isAbsolutePath ||
            stat(path.fileSystemRepresentation, &fileStatus) != 0 ||
            !S_ISREG(fileStatus.st_mode)) return nil;
        [paths addObject:path];
    }
    return [paths copy];
}

static BOOL MacWSWriteOpenDocumentAck(MacWSInputRecord record,
                                      uint32_t acceptedCount) {
    char sidecar[PATH_MAX] = {0};
    char ack[PATH_MAX] = {0};
    MacWSOpenDocumentPaths(record, sidecar, sizeof(sidecar), ack,
                           sizeof(ack));
    char temporary[PATH_MAX] = {0};
    int length = snprintf(temporary, sizeof(temporary), "%s.new.%d", ack,
                          getpid());
    if (length <= 0 || (size_t)length >= sizeof(temporary)) return NO;
    (void)unlink(temporary);
    int descriptor = open(temporary,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) return NO;
    MacWSOpenDocumentAck value = {
        .magic = MACWS_OPEN_DOCUMENT_ACK_MAGIC,
        .version = MACWS_OPEN_DOCUMENT_ACK_VERSION,
        .size = sizeof(MacWSOpenDocumentAck),
        .nonce = record.sceneID,
        .targetPID = getpid(),
        .acceptedCount = acceptedCount,
    };
    const uint8_t *cursor = (const uint8_t *)&value;
    size_t remaining = sizeof(value);
    BOOL written = YES;
    while (remaining != 0) {
        ssize_t count = write(descriptor, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            written = NO;
            break;
        }
        cursor += (size_t)count;
        remaining -= (size_t)count;
    }
    if (written && fsync(descriptor) != 0) written = NO;
    if (close(descriptor) != 0) written = NO;
    if (written && rename(temporary, ack) != 0) written = NO;
    if (!written) (void)unlink(temporary);
    return written;
}

static void MacWSHandleOpenDocuments(MacWSInputRecord record,
                                     id application) {
    NSArray<NSString *> *paths = MacWSCopyValidatedOpenDocumentPaths(record);
    if (paths.count == 0) return;
    NSMutableArray<NSURL *> *urls =
        [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) {
        NSURL *url = [NSURL fileURLWithPath:path];
        if (url) [urls addObject:url];
    }

    if (MacWSRuntimeDiagnosticsEnabled()) {
        id delegate = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("delegate"));
        fprintf(stderr,
            "#### APP-INPUT OPEN-DOCUMENT-DELEGATE pid=%d class=%s\n",
            getpid(), delegate ? object_getClassName(delegate) : "(nil)");
        static const char *const delegateSelectors[] = {
            "application:openURLs:",
            "application:openFiles:",
            "application:openFile:",
            "application:openFileWithoutUI:",
            "application:openTempFile:",
        };
        for (NSUInteger index = 0;
             index < sizeof(delegateSelectors) /
                 sizeof(delegateSelectors[0]); index++) {
            SEL candidate = sel_registerName(delegateSelectors[index]);
            Method method = delegate
                ? class_getInstanceMethod(object_getClass(delegate),
                                          candidate) : NULL;
            fprintf(stderr,
                "#### APP-INPUT OPEN-DOCUMENT-DELEGATE selector=%s "
                "implemented=%s types=%s imp=%p\n",
                delegateSelectors[index], method ? "YES" : "NO",
                method ? method_getTypeEncoding(method) : "(null)",
                method ? method_getImplementation(method) : NULL);
        }
        fflush(stderr);
    }

    // hostd has already decoded and independently validated the paths that
    // LaunchServices would normally carry in its AppleEvent. Deliver them to
    // the target's real NSApplicationDelegate document-open boundary. This is
    // important for Electron: runtime introspection on the actual VS Code
    // process (2026-09-07) found that ElectronApplicationDelegate implements
    // only -application:openFile: (B32@0:8@16@24). Calling AppKit's private
    // _handleAEOpenDocumentsForURLs: returned noErr without invoking that
    // delegate and left the Welcome page unchanged.
    id delegate = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("delegate"));
    SEL openURLs = sel_registerName("application:openURLs:");
    SEL openFiles = sel_registerName("application:openFiles:");
    SEL openFile = sel_registerName("application:openFile:");
    const char *handlerName = "unavailable";
    BOOL supported = urls.count == paths.count;
    BOOL accepted = NO;
    int status = INT_MIN;
    if (supported && delegate && [delegate respondsToSelector:openURLs]) {
        ((MacWSMsgVoidIDID)objc_msgSend)(
            delegate, openURLs, application, urls);
        handlerName = "delegate.application:openURLs:";
        accepted = YES;
        status = 0;
    } else if (supported && delegate &&
               [delegate respondsToSelector:openFiles]) {
        ((MacWSMsgVoidIDID)objc_msgSend)(
            delegate, openFiles, application, paths);
        handlerName = "delegate.application:openFiles:";
        accepted = YES;
        status = 0;
    } else if (supported && delegate &&
               [delegate respondsToSelector:openFile]) {
        accepted = YES;
        for (NSString *path in paths) {
            if (!((MacWSMsgBoolIDID)objc_msgSend)(
                    delegate, openFile, application, path))
                accepted = NO;
        }
        handlerName = "delegate.application:openFile:";
        status = accepted ? 0 : -1;
    } else {
        // Runtime-enumerated from the actual Ventura 13.4 AppKit image on the
        // device (2026-09-07): this method has type s24@0:8@16 and is the
        // post-AppleEvent URL entry used by document-based applications.
        SEL handleOpen = sel_registerName(
            "_handleAEOpenDocumentsForURLs:");
        supported = supported &&
            [application respondsToSelector:handleOpen];
        int16_t appKitStatus = supported
            ? ((int16_t (*)(id, SEL, id))objc_msgSend)(
                application, handleOpen, urls)
            : INT16_MIN;
        handlerName = supported
            ? "_handleAEOpenDocumentsForURLs:" : "unavailable";
        status = appKitStatus;
        accepted = supported && appKitStatus == 0;
    }
    BOOL activationRequested = NO;
    if (accepted) {
        // The original Finder LaunchServices transaction is an activating
        // document open.  Our typed bridge already preserves the target's
        // real NSApplicationDelegate boundary, but previously omitted that
        // second half of the transaction.  Runtime witness on 2026-09-07:
        // Preview pid 39009 accepted the PDF and renamed its live window 277,
        // while Host received no frontmost-catalog transition and its iPadOS
        // Scene stayed behind Maps.  Ask the target's real NSApplication to
        // activate only after its delegate accepted the document; AppKit and
        // WindowServer still decide which existing/new document window orders
        // front, and no window is synthesized here.
        SEL activate = sel_registerName("activateIgnoringOtherApps:");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                application, sel_registerName("respondsToSelector:"),
                activate)) {
            ((MacWSMsgVoidBool)objc_msgSend)(
                application, activate, YES);
            activationRequested = YES;
        }
    }
    BOOL acknowledged = accepted && MacWSWriteOpenDocumentAck(
        record, (uint32_t)urls.count);
    fprintf(stderr,
        "#### APP-INPUT OPEN-DOCUMENTS pid=%d nonce=%016llx count=%lu "
        "urls=%lu handler=%s status=%d activation=%s ack=%s\n",
        getpid(), (unsigned long long)record.sceneID,
        (unsigned long)paths.count, (unsigned long)urls.count,
        handlerName, status, activationRequested ? "requested" : "none",
        acknowledged ? "written" : "failed");
    fflush(stderr);
    if (accepted) {
        for (NSNumber *delay in @[@250, @1000]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         delay.longLongValue * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSPublishWindowMetrics();
                MacWSNotifyDisplayCatalogChanged('o');
            });
        }
    }
    [paths release];
}

static void MacWSHandlePerformQuit(id application) {
    // PerformQuit is already the semantic replacement for a menu/Dock quit
    // command which could not cross the chroot AppleEvent boundary.  Do not
    // enter AppKit's private _handleAEQuit without a current AppleEvent:
    // runtime-confirmed with Maps on iPad13,6, that path returned without
    // terminating even though the record reached this process.  The public
    // NSApplication action is the normal cooperative lifecycle entry and
    // still preserves delegate/document save and cancellation decisions.
    // It is also the same route proven by the last-window close fallback.
    SEL terminate = sel_registerName("terminate:");
    BOOL supported = application && ((MacWSMsgBoolSEL)objc_msgSend)(
        application, sel_registerName("respondsToSelector:"), terminate);
    // Remember only a transient which existed before the quit request. Maps'
    // first-run What's New panel is application-modal; Ventura's public
    // terminate: waits for that panel indefinitely in this chroot, so both
    // menu-bar and Dock quit appear to do nothing. Never select a primary
    // document window or a save panel created by the termination attempt.
    // performClose: remains delegate-vetoable, and we retry quit only after
    // AppKit confirms that exact auxiliary window is no longer visible.
    SEL modalWindowSelector = sel_registerName("modalWindow");
    id auxiliaryWindow = application && ((MacWSMsgBoolSEL)objc_msgSend)(
        application, sel_registerName("respondsToSelector:"),
        modalWindowSelector)
        ? ((MacWSMsgID)objc_msgSend)(application, modalWindowSelector) : nil;
    if (auxiliaryWindow && !((MacWSMsgBool)objc_msgSend)(
            auxiliaryWindow, sel_registerName("isVisible")))
        auxiliaryWindow = nil;
    id keyWindow = application ? ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("keyWindow")) : nil;
    NSArray *windows = application ? ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("windows")) : nil;
    for (id candidate in (auxiliaryWindow ? @[] : windows)) {
        BOOL visible = ((MacWSMsgBool)objc_msgSend)(
            candidate, sel_registerName("isVisible"));
        NSNumber *publishedTransient = objc_getAssociatedObject(
            candidate, &MacWSTransientWindowAssociationKey);
        if (!visible ||
            (!publishedTransient.boolValue &&
             !MacWSPresentingWindow(candidate, application)))
            continue;
        auxiliaryWindow = candidate;
        if (candidate == keyWindow) break;
    }
    // Close a preexisting application-modal panel before entering terminate:.
    // Calling terminate: first can enter a nested loop which services neither
    // this endpoint nor main-queue recovery work. The two public AppKit
    // actions in this order are runtime-proven with Maps; either delegate may
    // still veto, and a primary/document window is never touched.
    if (supported && auxiliaryWindow) {
        SEL performClose = sel_registerName("performClose:");
        BOOL canClose = ((MacWSMsgBoolSEL)objc_msgSend)(
            auxiliaryWindow, sel_registerName("respondsToSelector:"),
            performClose);
        if (!canClose) return;
        ((MacWSMsgVoidID)objc_msgSend)(
            auxiliaryWindow, performClose, nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     150 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            BOOL closeCommitted = !((MacWSMsgBool)objc_msgSend)(
                auxiliaryWindow, sel_registerName("isVisible"));
            fprintf(stderr,
                "#### APP-INPUT PERFORM-QUIT-AUXILIARY pid=%d "
                "class=%s close-committed=%s retry=%s\n",
                getpid(), object_getClassName(auxiliaryWindow),
                closeCommitted ? "YES" : "NO",
                closeCommitted ? "YES" : "NO");
            fflush(stderr);
            if (closeCommitted)
                ((MacWSMsgVoidID)objc_msgSend)(
                    application, terminate, nil);
        });
        return;
    }
    fprintf(stderr,
        "#### APP-INPUT PERFORM-QUIT pid=%d "
        "route=NSApplication.terminate supported=%s\n",
        getpid(), supported ? "YES" : "NO");
    fflush(stderr);
    if (supported)
        ((MacWSMsgVoidID)objc_msgSend)(application, terminate, nil);
}

static void MacWSPostInputOnMainThread(MacWSInputRecord record) {
    double latencyMainStart =
        (record.flags & MacWSInputFlagLatencyDiagnostic)
            ? MacWSInputUptimeSeconds() : 0.0;
    if ((record.flags & MacWSInputFlagLatencyDiagnostic) &&
        MacWSRuntimeDiagnosticsEnabled() &&
        MacWSMainBundleIsSevenDaysToDie()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSLogUnityNGUIInputState("host-state-probe");
        });
    }
    BOOL logEvent = (MacWSRuntimeDiagnosticsEnabled() ||
                     record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC) &&
        record.kind != MacWSInputKindTouchMove &&
        record.kind != MacWSInputKindHover &&
        record.kind != MacWSInputKindMenuHover &&
        record.kind != MacWSInputKindRelativePointer;
    if (logEvent) {
        fprintf(stderr,
                "#### APP-INPUT MAIN pid=%d kind=%u target=%d thread-main=%s\n",
                getpid(), record.kind, record.targetPID,
                pthread_main_np() ? "YES" : "NO");
        fflush(stderr);
    }
    Class applicationClass = objc_getClass("NSApplication");
    if (!applicationClass) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=NSApplication-unavailable\n",
                getpid());
        return;
    }
    id application = ((MacWSMsgID)objc_msgSend)((id)applicationClass,
        sel_registerName("sharedApplication"));
    if (!application) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=no-application\n",
                getpid());
        return;
    }
    MacWSCacheKeyboardContext(application);
    // Quit is application-scoped and remains valid for a hidden/windowless
    // target. Do not make it depend on NSScreen publication or install any
    // pointer hooks before entering AppKit's real termination lifecycle.
    if (record.kind == MacWSInputKindPerformQuit) {
        MacWSHandlePerformQuit(application);
        return;
    }

    // UIKit emits a hardware-pointer primary click as a stateful pair. The
    // down may have been consumed below solely to close a synchronous native
    // menu. Balance that exact contact without clicking the newly exposed
    // base view; a different new down retires a stale pair defensively.
    if (MacWSPopupDismissPointerActive) {
        BOOL matchingTerminal =
            record.source == MacWSInputSourceIndirectPointer &&
            record.contactID == MacWSPopupDismissPointerContact &&
            record.sceneID == MacWSPopupDismissPointerScene &&
            (record.kind == MacWSInputKindTouchUp ||
             record.kind == MacWSInputKindTouchCancel);
        if (matchingTerminal) {
            MacWSPopupDismissPointerActive = NO;
            MacWSPopupDismissPointerContact = 0;
            MacWSPopupDismissPointerScene = 0;
            MacWSSetAppInputGestureWindow(nil);
            MacWSClearDeferredRFBMoveEvents();
            return;
        }
        if (record.kind == MacWSInputKindTouchDown) {
            MacWSPopupDismissPointerActive = NO;
            MacWSPopupDismissPointerContact = 0;
            MacWSPopupDismissPointerScene = 0;
        }
    }

    Class screenClass = objc_getClass("NSScreen");
    Class eventClass = objc_getClass("NSEvent");
    if (!screenClass || !eventClass) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=AppKit-classes-unavailable\n",
                getpid());
        return;
    }
    MacWSInstallPressedMouseButtonsBridge(eventClass);
    // Geometry observation is input-facing state. Install it lazily on the
    // already-running AppKit main thread instead of during application launch;
    // Catalyst Maps has not completed its native scene/window transaction at
    // constructor time, and eagerly touching NSWindow notification machinery
    // can perturb that upstream lifecycle before any window exists.
    MacWSInstallWindowGeometryObservers();
    id screen = ((MacWSMsgID)objc_msgSend)((id)screenClass,
        sel_registerName("mainScreen"));
    if (!screen || record.frameWidth == 0 ||
        record.frameHeight == 0) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=no-application-or-screen\n",
                getpid());
        return;
    }

    if (record.kind == MacWSInputKindTap &&
        MacWSMainBundleIsSevenDaysToDie()) {
        // Runtime-confirmed on iPad14,5 with the arm64 Unity 2022.3.62f2
        // player: the generic atomic-Tap shortcut reaches NGUI's exact hover
        // target but does not advance PLAY GAME, while the existing ordinary
        // TouchDown/TouchUp gesture state machine advances that same button.
        // Expand only this game's high-level stationary Tap into those two
        // real NSEvent transitions.  Runtime A/B also established that a
        // 50-ms split advances PLAY GAME while a same-turn pair does not.
        // Put both phases through the ordinary socket-input FIFO so they take
        // the exact buffered AppKit tracker route as separate Host down/up
        // records; no NGUI action or hit-test result is forged.
        MacWSInputRecord downRecord = record;
        downRecord.kind = MacWSInputKindTouchDown;
        if (downRecord.pressure <= 0.0f) downRecord.pressure = 1.0f;
        MacWSInputRecord upRecord = record;
        upRecord.kind = MacWSInputKindTouchUp;
        upRecord.pressure = 0.0f;
        MacWSEnqueueAppInputRecord(downRecord);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     50 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSEnqueueAppInputRecord(upRecord);
        });
        return;
    }

    if (record.kind == MacWSInputKindOpenDocuments) {
        MacWSHandleOpenDocuments(record, application);
        return;
    }

    if (record.kind == MacWSInputKindDeactivateApplication) {
        BOOL before = ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"));
        SEL deactivateSelector = sel_registerName("deactivate");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                application, sel_registerName("respondsToSelector:"),
                deactivateSelector)) {
            ((MacWSMsgVoid)objc_msgSend)(application, deactivateSelector);
        }
        BOOL afterPublicDeactivate = ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"));
        BOOL repairedMissingEvent = NO;
        if (afterPublicDeactivate) {
            // RE-confirmed via macOS 13.4 AppKit on-device LLDB:
            // -deactivate calls _NXEndKeyAndMain, then only asks
            // CGSDeactivateCurrContext when _NXIsActiveApp is true.  In this
            // chroot no Workspace deactivate event returns, so the
            // application active bit remains set.  The actual downstream
            // -_handleDeactivateEvent: implementation does not read its event
            // argument; it posts WillResign/DidResign notifications, clears
            // the active bit, ends key/main state, and refreshes windows.
            // Deliver that missing lifecycle event only after the public
            // transaction demonstrably failed.  This is not an isActive hook
            // or a constant-return bypass.
            repairedMissingEvent =
                MacWSDeliverMissingDeactivateEvent(application);
        }
        BOOL completedFrontUILost =
            MacWSCompleteFrontUILostLifecycle();
        const char *clearedMainMenuBar =
            MacWSClearMainMenuBar(application);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT SYSTEM-DEACTIVATE pid=%d active=%s->%s->%s "
                "missing-event=%s front-ui-lost=%s clear-menu=%s\n",
                getpid(), before ? "YES" : "NO",
                afterPublicDeactivate ? "YES" : "NO",
                ((MacWSMsgBool)objc_msgSend)(
                    application, sel_registerName("isActive")) ? "YES" : "NO",
                repairedMissingEvent ? "DELIVERED" : "NO",
                completedFrontUILost ? "COMPLETED" : "UNAVAILABLE",
                clearedMainMenuBar);
            fflush(stderr);
        }
        return;
    }
    if (record.kind == MacWSInputKindActivateTarget) {
        BOOL before = ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"));
        uint32_t requestedWindowNumber =
            MacWSInputWindowIDForScene(record.sceneID);
        id requestedWindow = requestedWindowNumber
            ? MacWSWindowWithNumber(application, requestedWindowNumber) : nil;
        MacWSFrontUISnapshot frontBefore = MacWSCaptureFrontUISnapshot();
        BOOL frontOwnershipKnown = frontBefore.getStatus == 0 &&
            frontBefore.sameStatus == 0;
        BOOL rebuiltStaleActiveLifecycle = NO;
        if (before && requestedWindow && frontOwnershipKnown &&
            !frontBefore.ownsFrontUIProcess) {
            // Runtime-confirmed on iPad13,6 on 2026-08-13: reusing Terminal
            // PID 737 produced a score-7 (visible/on-screen but not focused)
            // catalog entry, Host emitted ActivateTarget, and the retained UI
            // screenshot still showed VS Code. AppKit's process-local
            // isActive bit was stale while _GetFrontUIProcess named another
            // owner, so activateIgnoringOtherApps: took its already-active
            // fast path and never performed a new front-process transaction.
            //
            // Complete the missing normal AppKit lifecycle before the user-
            // requested activation. This is conditional on the authoritative
            // cross-process owner mismatch; an application that really owns
            // the front remains untouched, preserving live menu/tracker state.
            SEL deactivateSelector = sel_registerName("deactivate");
            if (((MacWSMsgBoolSEL)objc_msgSend)(
                    application, sel_registerName("respondsToSelector:"),
                    deactivateSelector)) {
                ((MacWSMsgVoid)objc_msgSend)(application,
                                             deactivateSelector);
            }
            if (((MacWSMsgBool)objc_msgSend)(
                    application, sel_registerName("isActive"))) {
                rebuiltStaleActiveLifecycle =
                    MacWSDeliverMissingDeactivateEvent(application);
            }
            if (!((MacWSMsgBool)objc_msgSend)(
                    application, sel_registerName("isActive"))) {
                (void)MacWSCompleteFrontUILostLifecycle();
                (void)MacWSClearMainMenuBar(application);
                rebuiltStaleActiveLifecycle = YES;
            }
            before = ((MacWSMsgBool)objc_msgSend)(
                application, sel_registerName("isActive"));
        }
        BOOL keyedRequestedWindow = NO;
        if (requestedWindow) {
            BOOL visible = ((MacWSMsgBool)objc_msgSend)(
                requestedWindow, sel_registerName("isVisible"));
            BOOL canBecomeKey = ((MacWSMsgBool)objc_msgSend)(
                requestedWindow, sel_registerName("canBecomeKeyWindow"));
            id currentKeyWindow = ((MacWSMsgID)objc_msgSend)(
                application, sel_registerName("keyWindow"));
            if (visible && canBecomeKey && currentKeyWindow != requestedWindow &&
                ((MacWSMsgBoolSEL)objc_msgSend)(requestedWindow,
                    sel_registerName("respondsToSelector:"),
                    sel_registerName("makeKeyWindow"))) {
                // ActivateTarget is explicit user intent from one exact Host
                // Scene.  Select that already-visible AppKit window through
                // the normal key-window transaction, without ordering it or
                // re-entering NSWindowStackController's tab-order path.
                ((MacWSMsgVoid)objc_msgSend)(
                    requestedWindow, sel_registerName("makeKeyWindow"));
                keyedRequestedWindow = ((MacWSMsgID)objc_msgSend)(
                    application, sel_registerName("keyWindow")) ==
                    requestedWindow;
            } else {
                keyedRequestedWindow = currentKeyWindow == requestedWindow;
            }
        }
        BOOL systemMenuPreflight = record.frameHeight > 0 &&
            record.y >= 0.0f &&
            record.y <= (float)record.frameHeight * 0.04f;
        BOOL preflightOwner = NO;
        if (before && systemMenuPreflight) {
            // macwsinputd sends this control before OSXvnc posts the real
            // native menu-bar down.  The app may already be active/front yet
            // its long-lived NSMenuBarPresentationInstance still reflects the
            // root menu installed before the LS menu-owner handoff.  Run the
            // real owner + Carbon SetRootMenu/RecalcBar transaction now so the
            // native down enters a current tracker.  This creates no NSEvent.
            preflightOwner = MacWSRepairFrontUIApplication(
                application, "system-menu-preflight");
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT SYSTEM-MENU-PREFLIGHT pid=%d active=YES "
                    "front-owner=%s native-down=pending\n",
                    getpid(), preflightOwner ? "YES" : "NO");
                fflush(stderr);
            }
        }
        SEL activateSelector = sel_registerName("activateIgnoringOtherApps:");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                application, sel_registerName("respondsToSelector:"),
                activateSelector)) {
            // OSXvnc now sends this control immediately before its native
            // down.  Preserve an already-active target: deactivating and
            // rebuilding it hid its just-installed menu while the chroot was
            // missing the matching second Carbon activation event.
            uint64_t coordinationDelay = before
                ? 20 * NSEC_PER_MSEC : 0;
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, coordinationDelay),
                dispatch_get_main_queue(), ^{
                    if (!((MacWSMsgBool)objc_msgSend)(
                            application, sel_registerName("isActive"))) {
                        ((MacWSMsgVoidBool)objc_msgSend)(
                            application, activateSelector, YES);
                    }
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW,
                                      80 * NSEC_PER_MSEC),
                        dispatch_get_main_queue(), ^{
                            BOOL missingActivationDelivered = NO;
                            if (!((MacWSMsgBool)objc_msgSend)(
                                    application,
                                    sel_registerName("isActive"))) {
                                missingActivationDelivered =
                                    MacWSDeliverMissingActivateEvent(
                                        application);
                            }
                            if (!((MacWSMsgBool)objc_msgSend)(
                                    application,
                                    sel_registerName("isActive"))) {
                                ((MacWSMsgVoidBool)objc_msgSend)(
                                    application, activateSelector, YES);
                            }
                            BOOL ownsFrontUIProcess =
                                MacWSRepairFrontUIApplication(
                                    application, before
                                        ? "native-active" : "direct");
                            if (MacWSRuntimeDiagnosticsEnabled()) {
                                fprintf(stderr,
                                    "#### APP-INPUT SYSTEM-ACTIVATE-SETTLED "
                                    "pid=%d active=%s lifecycle-rebuilt=%s "
                                    "missing-event=%s front-owner=%s\n",
                                    getpid(),
                                    ((MacWSMsgBool)objc_msgSend)(
                                        application,
                                        sel_registerName("isActive"))
                                        ? "YES" : "NO",
                                    "NO",
                                    missingActivationDelivered
                                        ? "DELIVERED" : "NO",
                                    ownsFrontUIProcess ? "YES" : "NO");
                                fflush(stderr);
                            }
                        });
                });
        }
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT SYSTEM-ACTIVATE-CONTROL pid=%d active=%s "
                "coordination=%s requested-window=%u keyed=%s "
                "front-known=%s front-owned=%s stale-lifecycle=%s\n",
                getpid(), before ? "YES" : "NO",
                before ? "PRESERVE-NATIVE" : "DIRECT",
                requestedWindowNumber,
                keyedRequestedWindow ? "YES" : "NO",
                frontOwnershipKnown ? "YES" : "NO",
                frontBefore.ownsFrontUIProcess ? "YES" : "NO",
                rebuiltStaleActiveLifecycle ? "REBUILT" : "NO");
            fflush(stderr);
        }
        return;
    }

    if (record.kind == MacWSInputKindCreateInitialWindow) {
        BOOL finder = MacWSMainBundleIsFinder();
        NSSet *visibleWindowsBefore = finder
            ? MacWSVisibleWindowNumberSnapshot(application) : nil;
        id mainMenu = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainMenu"));
        id item = MacWSFindInitialWindowMenuItem(mainMenu, 0);
        SEL action = item ? ((SEL (*)(id, SEL))objc_msgSend)(
            item, sel_registerName("action")) : NULL;
        id target = item ? ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("target")) : nil;
        BOOL performed = action && ((MacWSMsgBoolSELIDID)objc_msgSend)(
            application, sel_registerName("sendAction:to:from:"),
            action, target, item);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            id title = item ? ((MacWSMsgID)objc_msgSend)(
                item, sel_registerName("title")) : nil;
            fprintf(stderr,
                "#### APP-INPUT CREATE-INITIAL-WINDOW pid=%d item=%s "
                "action=%s target=%s performed=%s\n",
                getpid(), [title UTF8String] ?: "nil",
                action ? sel_getName(action) : "nil",
                target ? object_getClassName(target) : "nil",
                performed ? "YES" : "NO");
            fflush(stderr);
        }
        if (performed) {
            if (finder) {
                // Runtime-confirmed on the target rootfs: Finder's real
                // Command-N window stayed in Recents/Loading indefinitely
                // because that view depends on an unavailable metadata query
                // service. Wait for that new browser window to become real,
                // then perform its enabled native Go > Home target/action.
                // This neither synthesizes files nor replaces the browser.
                MacWSCompleteFinderInitialWindow(
                    application, visibleWindowsBefore, 0);
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              100 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                MacWSPublishWindowMetrics();
                MacWSNotifyDisplayCatalogChanged('n');
                });
            }
        }
        return;
    }

    if (record.kind == MacWSInputKindReopenApplication) {
        NSArray *windows = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("windows"));
        BOOL hasVisibleWindows = NO;
        for (id window in windows) {
            BOOL logicalVisible = ((MacWSMsgBool)objc_msgSend)(
                window, sel_registerName("isVisible"));
            BOOL presentationKnown = NO;
            BOOL presentationOnScreen = MacWSWindowPresentationIsOnScreen(
                window, &presentationKnown);
            BOOL visible = logicalVisible &&
                (!presentationKnown || presentationOnScreen);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                BOOL canBecomeKey = ((MacWSMsgBool)objc_msgSend)(
                    window, sel_registerName("canBecomeKeyWindow"));
                NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
                    window, sel_registerName("windowNumber"));
                id title = ((MacWSMsgID)objc_msgSend)(
                    window, sel_registerName("title"));
                fprintf(stderr,
                    "#### APP-INPUT REOPEN-INSPECT pid=%d class=%s "
                    "number=%ld logical-visible=%s presentation-known=%s "
                    "onscreen=%s can-key=%s title=%s\n",
                    getpid(), object_getClassName(window), (long)number,
                    logicalVisible ? "YES" : "NO",
                    presentationKnown ? "YES" : "NO",
                    presentationOnScreen ? "YES" : "NO",
                    canBecomeKey ? "YES" : "NO",
                    title ? [title UTF8String] : "nil");
                fflush(stderr);
            }
            if (visible) {
                hasVisibleWindows = YES;
                break;
            }
        }
        // RE-confirmed against the running macOS 13.4 AppKit image:
        // -[NSApplication _handleAEReopen:] is at image offset 0x197064.
        // Its implementation retains the AppleEvent argument, executes the
        // complete reopen decision/window-restoration chain, and then runs
        // the ordinary activation tail. Calling only the public delegate
        // question is not equivalent: runtime System Settings returned NO
        // and its real 715x625 scene stayed ordered out. Recreate the standard
        // kCoreEventClass/kAEReopenApplication descriptor inside the target
        // and enter AppKit at the point where the missing cross-process
        // AppleEvent endpoint would have delivered it.
        Class descriptorClass = objc_getClass("NSAppleEventDescriptor");
        SEL eventFactory = sel_registerName(
            "appleEventWithEventClass:eventID:targetDescriptor:returnID:"
            "transactionID:");
        id event = descriptorClass && ((MacWSMsgBoolSEL)objc_msgSend)(
            (id)descriptorClass, sel_registerName("respondsToSelector:"),
            eventFactory)
            ? ((id (*)(id, SEL, uint32_t, uint32_t, id, int16_t, int32_t))
                objc_msgSend)((id)descriptorClass, eventFactory,
                    0x61657674u, // 'aevt' / kCoreEventClass
                    0x72617070u, // 'rapp' / kAEReopenApplication
                    nil, -1, 0)
            : nil;
        SEL handleReopen = sel_registerName("_handleAEReopen:");
        BOOL supported = event && ((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            handleReopen);
        if (supported)
            ((MacWSMsgVoidID)objc_msgSend)(application, handleReopen, event);
        if (MacWSRuntimeDiagnosticsEnabled() || !supported) {
            fprintf(stderr,
                "#### APP-INPUT REOPEN pid=%d route=AppKit-AE supported=%s "
                "visible-before=%s event=%s\n",
                getpid(),
                supported ? "YES" : "NO",
                hasVisibleWindows ? "YES" : "NO",
                event ? "YES" : "NO");
            fflush(stderr);
        }
        if (supported) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          150 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                BOOL visibleAfterReopen = NO;
                id currentWindows = ((MacWSMsgID)objc_msgSend)(
                    application, sel_registerName("windows"));
                for (id window in currentWindows) {
                    if (((MacWSMsgBool)objc_msgSend)(
                            window, sel_registerName("isVisible"))) {
                        visibleAfterReopen = YES;
                        break;
                    }
                }
                BOOL openedUntitled = NO;
                SEL openUntitled = sel_registerName("_doOpenUntitled");
                if (!visibleAfterReopen && ((MacWSMsgBoolSEL)objc_msgSend)(
                        application, sel_registerName("respondsToSelector:"),
                        openUntitled)) {
                    // RE-confirmed in the same AppKit image at offset
                    // 0x1b3b98: this is NSApplication's own standard
                    // untitled/open-primary-window transaction. It preserves
                    // app delegate/document/SwiftUI routing; it does not
                    // allocate or force-order an NSWindow in the bridge.
                    openedUntitled = ((MacWSMsgBool)objc_msgSend)(
                        application, openUntitled);
                }
                if (MacWSRuntimeDiagnosticsEnabled() ||
                    (!visibleAfterReopen && !openedUntitled)) {
                    fprintf(stderr,
                        "#### APP-INPUT REOPEN-COMPLETE pid=%d "
                        "visible-after-ae=%s do-open-untitled=%s\n",
                        getpid(), visibleAfterReopen ? "YES" : "NO",
                        openedUntitled ? "YES" : "NO");
                    fflush(stderr);
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              250 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    BOOL visibleAfterLifecycle = NO;
                    id orderCandidate = nil;
                    NSInteger orderCandidateRank = 0;
                    id keyWindow = ((MacWSMsgID)objc_msgSend)(
                        application, sel_registerName("keyWindow"));
                    id mainWindow = ((MacWSMsgID)objc_msgSend)(
                        application, sel_registerName("mainWindow"));
                    id reopenedWindows = ((MacWSMsgID)objc_msgSend)(
                        application, sel_registerName("windows"));
                    for (id window in reopenedWindows) {
                        BOOL logicalVisible = ((MacWSMsgBool)objc_msgSend)(
                            window, sel_registerName("isVisible"));
                        BOOL presentationKnown = NO;
                        BOOL presentationOnScreen =
                            MacWSWindowPresentationIsOnScreen(
                                window, &presentationKnown);
                        BOOL visible = logicalVisible &&
                            (!presentationKnown || presentationOnScreen);
                        if (visible) visibleAfterLifecycle = YES;
                        BOOL canBecomeKey = ((MacWSMsgBool)objc_msgSend)(
                            window, sel_registerName("canBecomeKeyWindow"));
                        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
                            window, sel_registerName("windowNumber"));
                        NSInteger level = ((MacWSMsgInteger)objc_msgSend)(
                            window, sel_registerName("level"));
                        NSInteger rank = window == keyWindow ? 3 :
                            (window == mainWindow ? 2 : (level == 0 ? 1 : 0));
                        if (canBecomeKey && number > 0 &&
                            rank > orderCandidateRank) {
                            orderCandidate = window;
                            orderCandidateRank = rank;
                        }
                    }
                    BOOL orderedExisting = NO;
                    if (orderCandidate) {
                        SEL orderFront = sel_registerName(
                            "makeKeyAndOrderFront:");
                        if (((MacWSMsgBoolSEL)objc_msgSend)(
                                orderCandidate,
                                sel_registerName("respondsToSelector:"),
                                orderFront)) {
                            // Runtime-confirmed on 2026-09-03: activating Maps
                            // changed the global menu owner to Maps while an
                            // Activity Monitor window remained above its real
                            // window. Logical visibility is therefore not the
                            // reopen postcondition. Use the app's existing
                            // key/main level-zero window and AppKit's ordinary
                            // ordering method; never synthesize a window or
                            // bypass WindowServer/SkyLight validation.
                            ((MacWSMsgVoidID)objc_msgSend)(
                                orderCandidate, orderFront, nil);
                            SEL activate = sel_registerName(
                                "activateIgnoringOtherApps:");
                            if (((MacWSMsgBoolSEL)objc_msgSend)(
                                    application,
                                    sel_registerName("respondsToSelector:"),
                                    activate))
                                ((MacWSMsgVoidBool)objc_msgSend)(
                                    application, activate, YES);
                            BOOL presentationKnownAfter = NO;
                            BOOL presentationOnScreenAfter =
                                MacWSWindowPresentationIsOnScreen(
                                    orderCandidate, &presentationKnownAfter);
                            orderedExisting = presentationKnownAfter
                                ? presentationOnScreenAfter
                                : ((MacWSMsgBool)objc_msgSend)(
                                      orderCandidate,
                                      sel_registerName("isVisible"));
                        }
                    }
                    if (MacWSRuntimeDiagnosticsEnabled() || !orderedExisting) {
                        fprintf(stderr,
                            "#### APP-INPUT REOPEN-WINDOW pid=%d "
                            "visible-before-order=%s candidate=%s rank=%ld "
                            "ordered-existing=%s\n",
                            getpid(),
                            visibleAfterLifecycle ? "YES" : "NO",
                            orderCandidate
                                ? object_getClassName(orderCandidate) : "nil",
                            (long)orderCandidateRank,
                            orderedExisting ? "YES" : "NO");
                        fflush(stderr);
                    }
                    // This reopen request is also the launcher's liveness
                    // handshake.  Force one new metrics generation even when
                    // the window set is byte-for-byte unchanged; otherwise a
                    // stale Visible record can make a windowless/hung process
                    // look successfully reopened forever.
                    unlink(MacWSWindowMetricsPath);
                    MacWSPublishWindowMetrics();
                    MacWSNotifyDisplayCatalogChanged('r');
                });
            });
        }
        return;
    }

    if (record.kind == MacWSInputKindCloseWindow) {
        uint32_t windowNumber = MacWSInputWindowIDForScene(record.sceneID);
        id window = MacWSWindowWithNumber(application, windowNumber);
        SEL performClose = sel_registerName("performClose:");
        if (window && ((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"),
                performClose)) {
            ((void (*)(id, SEL, id))objc_msgSend)(window, performClose, nil);
            // performClose: can run delegate validation synchronously, while
            // the final NSApplication.windows mutation lands on the next main
            // loop turn. Publish the committed catalog after that turn so
            // every Host Scene observes the close without a polling delay.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          150 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSPublishWindowMetrics();
                MacWSNotifyDisplayCatalogChanged('c');

                // Closing an iPad Scene is an explicit application-window
                // lifecycle transaction, not merely a request to hide pixels.
                // Runtime-confirmed before this fix with Terminal: the final
                // NSWindow disappeared, but its process and Dock running dot
                // remained indefinitely; a Dock activation then produced only
                // the menu bar because there was no window to order forward.
                // Terminate cooperatively only after AppKit proves the exact
                // requested window accepted performClose: and no other visible
                // level-zero application window remains.  A delegate-vetoed
                // close or another document window therefore cannot lose data
                // or terminate the application behind another iPad Scene.
                id closedWindow = MacWSWindowWithNumber(
                    application, windowNumber);
                BOOL closeCommitted = !closedWindow ||
                    !((MacWSMsgBool)objc_msgSend)(
                        closedWindow, sel_registerName("isVisible"));
                NSUInteger visiblePrimaryWindows = 0;
                NSArray *applicationWindows = ((MacWSMsgID)objc_msgSend)(
                    application, sel_registerName("windows"));
                for (id candidate in applicationWindows) {
                    BOOL visible = ((MacWSMsgBool)objc_msgSend)(
                        candidate, sel_registerName("isVisible"));
                    NSInteger level = ((MacWSMsgInteger)objc_msgSend)(
                        candidate, sel_registerName("level"));
                    NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
                        candidate, sel_registerName("windowNumber"));
                    if (visible && level == 0 && number > 0)
                        visiblePrimaryWindows++;
                }
                if (closeCommitted && visiblePrimaryWindows == 0) {
                    SEL terminate = sel_registerName("terminate:");
                    if (((MacWSMsgBoolSEL)objc_msgSend)(
                            application,
                            sel_registerName("respondsToSelector:"),
                            terminate)) {
                        if (MacWSRuntimeDiagnosticsEnabled()) {
                            fprintf(stderr,
                                "#### APP-INPUT CLOSE-WINDOW-LAST pid=%d "
                                "window=%u route=NSApplication.terminate\n",
                                getpid(), windowNumber);
                            fflush(stderr);
                        }
                        ((MacWSMsgVoidID)objc_msgSend)(
                            application, terminate, nil);
                    }
                } else if (MacWSRuntimeDiagnosticsEnabled()) {
                    fprintf(stderr,
                        "#### APP-INPUT CLOSE-WINDOW-KEEP pid=%d window=%u "
                        "committed=%s visible-primary=%lu\n",
                        getpid(), windowNumber,
                        closeCommitted ? "YES" : "NO",
                        (unsigned long)visiblePrimaryWindows);
                    fflush(stderr);
                }
            });
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT CLOSE-WINDOW pid=%d window=%u\n",
                    getpid(), windowNumber);
                fflush(stderr);
            }
        }
        return;
    }

    if (record.kind == MacWSInputKindConfigureWindow) {
        uint32_t windowNumber =
            MacWSInputWindowIDForScene(record.sceneID);
        id window = MacWSWindowWithNumber(application, windowNumber);
        if (!window) {
            fprintf(stderr,
                "#### APP-INPUT CONFIGURE-DROP pid=%d reason=no-window "
                "window=%u\n", getpid(), windowNumber);
            fflush(stderr);
            return;
        }
        CGRect oldFrame = ((MacWSMsgRect)objc_msgSend)(
            window, sel_registerName("frame"));
        BOOL resizable = NO;
        CGSize applicationMaximum = CGSizeZero;
        CGSize minimum = MacWSEffectiveMinimumFrameSize(
            window, oldFrame, &resizable, &applicationMaximum);
        BOOL unboundedWidth = MacWSWindowAxisMaximumIsUnbounded(
            applicationMaximum.width, MACWS_STREAM_MAX_DIMENSION);
        BOOL unboundedHeight = MacWSWindowAxisMaximumIsUnbounded(
            applicationMaximum.height, MACWS_STREAM_MAX_DIMENSION);
        BOOL anchorTopLeft =
            (record.flags & MacWSInputFlagConfigureAnchorTopLeft) != 0;
        BOOL anchorTopRight =
            (record.flags & MacWSInputFlagConfigureAnchorTopRight) != 0;
        uint8_t screenConstraintPolicy = MacWSWindowScreenConstraintPolicy(
            anchorTopLeft || anchorTopRight,
            unboundedWidth, unboundedHeight);
        objc_setAssociatedObject(window,
            &MacWSWindowScreenConstraintPolicyKey,
            screenConstraintPolicy == MacWSWindowScreenConstraintPolicyNone
                ? nil : [NSNumber numberWithUnsignedChar:screenConstraintPolicy],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id windowScreen = ((MacWSMsgID)objc_msgSend)(
            window, sel_registerName("screen"));
        CGRect targetScreen = ((MacWSMsgRect)objc_msgSend)(
            windowScreen ?: screen, sel_registerName("frame"));
        CGSize hostRequested = resizable ? (CGSize){
            fmax(record.x, minimum.width), fmax(record.y, minimum.height),
        } : oldFrame.size;
        if ((anchorTopLeft || anchorTopRight) &&
            targetScreen.size.width > 0.0 && targetScreen.size.height > 0.0) {
            // An iPad Scene can be wider than the virtual macOS display (Stage
            // Manager is one concrete case). Preserve an application's real
            // maximum, but do not mistake NSScreen for that maximum when the
            // application published the transport's unbounded sentinel.
            hostRequested.width = MacWSWindowAxisRequestRespectingScreen(
                hostRequested.width, targetScreen.size.width,
                applicationMaximum.width, MACWS_STREAM_MAX_DIMENSION);
            hostRequested.height = MacWSWindowAxisRequestRespectingScreen(
                hostRequested.height, targetScreen.size.height,
                applicationMaximum.height, MACWS_STREAM_MAX_DIMENSION);
        }
        CGSize maximum = oldFrame.size;
        CGSize aspect = CGSizeZero;
        CGSize increments = CGSizeZero;
        CGSize requested = resizable
            ? MacWSConstrainedWindowFrameSize(
                window, oldFrame, hostRequested, minimum, &maximum, &aspect,
                &increments)
            : oldFrame.size;
        CGRect newFrame = oldFrame;
        newFrame.size = requested;
        if (anchorTopLeft || anchorTopRight) {
            newFrame.origin.x = anchorTopRight
                ? MacWSWindowTrailingAnchorOrigin(
                    targetScreen.origin.x, targetScreen.size.width,
                    requested.width, unboundedWidth)
                : targetScreen.origin.x;
            newFrame.origin.y = targetScreen.origin.y +
                targetScreen.size.height - requested.height;
        } else {
            newFrame.origin.y += oldFrame.size.height - requested.height;
        }
        SEL setter = sel_registerName("setFrame:display:animate:");
        if (!((MacWSMsgBoolSEL)objc_msgSend)(window,
                sel_registerName("respondsToSelector:"), setter)) return;
        MacWSHostConfigureFrameContext previousConfigureContext =
            MacWSCurrentHostConfigureFrameContext;
        MacWSCurrentHostConfigureFrameContext =
            (MacWSHostConfigureFrameContext){
                .window = window,
                .applicationConstrainedFrame = newFrame,
                .screenExtent = targetScreen.size,
                .unboundedWidth = (anchorTopLeft || anchorTopRight) &&
                    unboundedWidth,
                .unboundedHeight = (anchorTopLeft || anchorTopRight) &&
                    unboundedHeight,
            };
        ((MacWSMsgVoidRectBoolBool)objc_msgSend)(
            window, setter, newFrame, YES, NO);
        MacWSCurrentHostConfigureFrameContext = previousConfigureContext;
        // Complete AppKit's pending layout before recording accepted geometry.
        // RE-confirmed layoutIfNeeded at 0x184112454: updateConstraintsIfNeeded,
        // performPendingChangeNotifications, _changeWindowFrameFromConstraints
        // (via its block), then _layoutViewTree. Merely returning from setFrame
        // does not include the constraint-engine frame change in this ACK.
        SEL layoutIfNeeded = sel_registerName("layoutIfNeeded");
        if (((MacWSMsgBoolSEL)objc_msgSend)(window,
                sel_registerName("respondsToSelector:"), layoutIfNeeded))
            ((MacWSMsgVoid)objc_msgSend)(window, layoutIfNeeded);
        CGRect appliedFrame = ((MacWSMsgRect)objc_msgSend)(
            window, sel_registerName("frame"));
        BOOL applicationConstrained =
            fabs(appliedFrame.size.width - record.x) > 0.75 ||
            fabs(appliedFrame.size.height - record.y) > 0.75;
        // A result describes this transaction, not the window's global
        // minimum. One response cannot distinguish a global minimum from
        // quantization or another proposal-dependent application policy.
        // The exact ACK below returns the accepted size to Host; never cache
        // it as a permanent minimum for subsequent independent requests.
        if ((anchorTopLeft || anchorTopRight) && applicationConstrained) {
            // Anchor against the size AppKit actually accepted. Previously
            // Finder retained a 445-point frame but was positioned as though
            // it were 400 points wide, placing 45 points beyond the desktop.
            CGRect correctedFrame = appliedFrame;
            correctedFrame.origin.x = anchorTopRight
                ? MacWSWindowTrailingAnchorOrigin(
                    targetScreen.origin.x, targetScreen.size.width,
                    appliedFrame.size.width, unboundedWidth)
                : targetScreen.origin.x;
            correctedFrame.origin.y = targetScreen.origin.y +
                targetScreen.size.height - appliedFrame.size.height;
            if (fabs(correctedFrame.origin.x - appliedFrame.origin.x) > 0.25 ||
                fabs(correctedFrame.origin.y - appliedFrame.origin.y) > 0.25) {
                ((MacWSMsgVoidRectBoolBool)objc_msgSend)(
                    window, setter, correctedFrame, YES, NO);
                if (((MacWSMsgBoolSEL)objc_msgSend)(window,
                        sel_registerName("respondsToSelector:"), layoutIfNeeded))
                    ((MacWSMsgVoid)objc_msgSend)(window, layoutIfNeeded);
                appliedFrame = ((MacWSMsgRect)objc_msgSend)(
                    window, sel_registerName("frame"));
            }
        }
        BOOL geometryChanged =
            fabs(appliedFrame.origin.x - oldFrame.origin.x) > 0.25 ||
            fabs(appliedFrame.origin.y - oldFrame.origin.y) > 0.25 ||
            fabs(appliedFrame.size.width - oldFrame.size.width) > 0.25 ||
            fabs(appliedFrame.size.height - oldFrame.size.height) > 0.25;
        applicationConstrained =
            fabs(appliedFrame.size.width - record.x) > 0.75 ||
            fabs(appliedFrame.size.height - record.y) > 0.75;
        // Commit an acknowledgement only after this exact input transaction
        // has run setFrame and any anchor correction. Catalog/surface changes
        // alone do not identify which of several queued resizes completed.
        MacWSWindowConfigureAck configureAck = {0};
        // Legacy probes may omit a timestamp. They can still configure the
        // window, but cannot create an identifiable ACK (or invalidate the
        // independent size-limit record with a partially filled zero token).
        if (isfinite(record.timestamp) && record.timestamp > 0.0) {
            configureAck = (MacWSWindowConfigureAck){
                .timestamp = record.timestamp,
                .sequence = record.sampleSequence,
                .requestedWidth = record.x,
                .requestedHeight = record.y,
                .appliedWidth = (float)appliedFrame.size.width,
                .appliedHeight = (float)appliedFrame.size.height,
            };
        }
        objc_setAssociatedObject(window, &MacWSWindowConfigureAckKey,
            [NSData dataWithBytes:&configureAck length:sizeof(configureAck)],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The setter, pending layout and anchor correction have now completed.
        // Publish that committed size instead of making Host
        // wait for the 500-ms recovery timer or issue a blind catalog poll.
        MacWSPublishWindowMetrics();
        if (geometryChanged) {
            MacWSNotifyDisplayGeometryChanged(
                windowNumber, window, appliedFrame);
        }
        if (applicationConstrained) {
            // A fixed or max-sized AppKit window has no new IOSurface
            // geometry to publish. Still emit one catalog edge so Host can
            // observe the unchanged real frame as the application's resize
            // result and fit the native Scene back to it.
            MacWSNotifyDisplayCatalogChanged('s');
        }
        if (MacWSRuntimeDiagnosticsEnabled() || applicationConstrained) {
            fprintf(stderr,
                "#### APP-INPUT CONFIGURE pid=%d window=%u "
                "old=%.1fx%.1f host=%.1fx%.1f constrained=%.1fx%.1f "
                "minimum=%.1fx%.1f maximum=%.1fx%.1f "
                "aspect=%.1fx%.1f increments=%.1fx%.1f "
                "applied=(%.1f,%.1f %.1fx%.1f) changed=%s "
                "application-constrained=%s density=%.2f anchor=%s\n",
                getpid(), windowNumber,
                oldFrame.size.width, oldFrame.size.height,
                record.x, record.y, requested.width, requested.height,
                minimum.width, minimum.height,
                maximum.width, maximum.height,
                aspect.width, aspect.height,
                increments.width, increments.height,
                appliedFrame.origin.x, appliedFrame.origin.y,
                appliedFrame.size.width, appliedFrame.size.height,
                geometryChanged ? "YES" : "NO",
                applicationConstrained ? "YES" : "NO", record.pressure,
                anchorTopRight ? "top-right" :
                    (anchorTopLeft ? "top-left" : "preserve"));
            fflush(stderr);
        }
        return;
    }

    if (record.kind == MacWSInputKindDesktopCommand) {
        (void)MacWSPostDesktopCommand((MacWSDesktopCommand)record.contactID);
        return;
    }

    if (record.kind == MacWSInputKindPerformPaste) {
        uint32_t requestedWindowNumber =
            MacWSInputWindowIDForScene(record.sceneID);
        id requestedWindow = requestedWindowNumber
            ? MacWSWindowWithNumber(application, requestedWindowNumber) : nil;
        if (requestedWindowNumber && !requestedWindow) {
            fprintf(stderr,
                "#### APP-INPUT PASTE pid=%d window=%u item=nil "
                "action=nil performed=NO reason=target-window-closed\n",
                getpid(), requestedWindowNumber);
            fflush(stderr);
            return;
        }
        if (requestedWindow && ((MacWSMsgBool)objc_msgSend)(
                requestedWindow, sel_registerName("canBecomeKeyWindow"))) {
            ((MacWSMsgVoid)objc_msgSend)(
                requestedWindow, sel_registerName("makeKeyWindow"));
        }
        id mainMenu = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainMenu"));
        id item = MacWSFindEnabledCommandMenuItem(
            mainMenu, MacWSRuntimeString("v"), 0);
        SEL action = item ? ((SEL (*)(id, SEL))objc_msgSend)(
            item, sel_registerName("action")) : NULL;
        id target = item ? ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("target")) : nil;
        BOOL performed = action && ((MacWSMsgBoolSELIDID)objc_msgSend)(
            application, sel_registerName("sendAction:to:from:"),
            action, target, item);
        fprintf(stderr,
            "#### APP-INPUT PASTE pid=%d window=%u item=%s action=%s "
            "target=%s performed=%s\n",
            getpid(), requestedWindowNumber,
            item ? "Command-V" : "nil",
            action ? sel_getName(action) : "nil",
            target ? object_getClassName(target) : "nil",
            performed ? "YES" : "NO");
        fflush(stderr);
        return;
    }

    if (record.kind == MacWSInputKindKeyDown ||
        record.kind == MacWSInputKindKeyUp) {
        uint32_t requestedWindowNumber =
            MacWSInputWindowIDForScene(record.sceneID);
        id keyWindow = requestedWindowNumber
            ? MacWSWindowWithNumber(application, requestedWindowNumber)
            : ((MacWSMsgID)objc_msgSend)(
                application, sel_registerName("keyWindow"));
        if (requestedWindowNumber && !keyWindow) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=target-window-closed "
                "window=%u kind=%u\n",
                getpid(), requestedWindowNumber, record.kind);
            fflush(stderr);
            return;
        }
        if (!keyWindow) keyWindow = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainWindow"));
        BOOL exactSoftwareKey =
            record.source == MacWSInputSourceSoftwareKeyboard;
        if (exactSoftwareKey && keyWindow) {
            id currentKeyWindow = ((MacWSMsgID)objc_msgSend)(
                application, sel_registerName("keyWindow"));
            if (currentKeyWindow != keyWindow &&
                ((MacWSMsgBool)objc_msgSend)(
                    keyWindow, sel_registerName("canBecomeKeyWindow"))) {
                ((MacWSMsgVoid)objc_msgSend)(
                    keyWindow, sel_registerName("makeKeyWindow"));
            }
            if (MacWSRuntimeDiagnosticsEnabled() &&
                record.kind == MacWSInputKindKeyDown) {
                id firstResponder = ((MacWSMsgID)objc_msgSend)(
                    keyWindow, sel_registerName("firstResponder"));
                fprintf(stderr,
                    "#### APP-INPUT TEXT-FOCUS pid=%d window=%u "
                    "first-responder=%s keysym=%#x modifiers=%#x\n",
                    getpid(), requestedWindowNumber,
                    firstResponder ? object_getClassName(firstResponder) : "nil",
                    record.contactID,
                    MacWSInputModifiersForScene(record.sceneID));
                fflush(stderr);
            }
        }
        NSInteger keyWindowNumber = keyWindow
            ? ((MacWSMsgInteger)objc_msgSend)(
                keyWindow, sel_registerName("windowNumber")) : 0;
        BOOL queueForGameTick = MacWSMainBundleUsesQueuedGameInput();
        if (!MacWSPostKeyRecord(record, application, eventClass,
                                keyWindowNumber, queueForGameTick, NO)) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=key-event-create "
                "kind=%u keycode=%.3f keysym=%#x\n",
                getpid(), record.kind, record.pressure, record.contactID);
            fflush(stderr);
        }
        return;
    }

    CGFloat normalizedX = record.x / (CGFloat)record.frameWidth;
    CGFloat normalizedY = record.y / (CGFloat)record.frameHeight;
    CGRect screenFrame = ((MacWSMsgRect)objc_msgSend)(screen,
        sel_registerName("frame"));
    // The socket-side live tracker receives the producer's original x/y and
    // frameWidth/frameHeight.  Preserve the exact affine region that maps
    // those top-left pixels into AppKit screen points.  For a zero-window
    // desktop record this is NSScreen.frame; exact DisplayStream records
    // replace it below with their base window's Retina mapping.
    CGRect inputMappingFrame = screenFrame;
    uint32_t requestedWindowNumber =
        MacWSInputWindowIDForScene(record.sceneID);
    BOOL globalSystemSurface = requestedWindowNumber != 0 &&
        (record.flags & MacWSInputFlagGlobalSystemSurface) != 0;
    if (globalSystemSurface) {
        // Fullscreen Dock/WindowServer layers can be interactive without an
        // NSApplication endpoint of their own. Host preserves complete-desktop
        // coordinates and selects this already-CGS-connected application only
        // as the legacy system-event poster. Re-query WindowServer here: the
        // encoded composited layer and its independent global hit must agree
        // before any button transition is allowed. This is the same exact-ID
        // invariant that prevents a stale Maps layer from clicking Terminal.
        CGPoint globalPoint = {
            screenFrame.origin.x + normalizedX * screenFrame.size.width,
            screenFrame.origin.y +
                (1.0 - normalizedY) * screenFrame.size.height,
        };
        NSInteger globalWindowNumber = 0;
        Class nativeWindowClass = objc_getClass("NSWindow");
        SEL globalHitSelector = sel_registerName(
            "windowNumberAtPoint:belowWindowWithWindowNumber:");
        if (nativeWindowClass && class_respondsToSelector(
                object_getClass(nativeWindowClass), globalHitSelector)) {
            globalWindowNumber = ((MacWSMsgIntegerPointInteger)objc_msgSend)(
                (id)nativeWindowClass, globalHitSelector, globalPoint, 0);
        }
        BOOL exactContinuation = MacWSExactSystemPointerActive &&
            MacWSExactSystemPointerContact == record.contactID &&
            MacWSExactSystemPointerWindow == requestedWindowNumber;
        BOOL exactGlobalHit =
            globalWindowNumber == (NSInteger)requestedWindowNumber;
        if (!exactContinuation && !exactGlobalHit) {
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT GLOBAL-SURFACE-DROP pid=%d requested=%u "
                    "global=%ld kind=%u point=(%.2f,%.2f)\n",
                    getpid(), requestedWindowNumber,
                    (long)globalWindowNumber, record.kind,
                    globalPoint.x, globalPoint.y);
                fflush(stderr);
            }
            return;
        }
        if (MacWSPostLegacySystemPointerEvent(
                record, globalPoint, screenFrame, screenFrame,
                requestedWindowNumber, exactGlobalHit)) {
            // Existing streams publish pointer/Dock visual damage directly;
            // a move or hover does not change the native window catalog. The
            // old unconditional notification forced a full transient-layer
            // reconciliation for every Dock hover sample and visibly
            // flickered that surface. Reconcile only at boundaries that can
            // open, close, order, or dismiss a native window/menu.
            BOOL mayChangeCatalog =
                record.kind == MacWSInputKindTouchDown ||
                record.kind == MacWSInputKindTouchUp ||
                record.kind == MacWSInputKindTouchCancel ||
                record.kind == MacWSInputKindTap ||
                record.kind == MacWSInputKindSecondaryTap;
            if (mayChangeCatalog) MacWSNotifyDisplayCatalogChanged('t');
            if (record.kind == MacWSInputKindTouchUp ||
                record.kind == MacWSInputKindTouchCancel ||
                record.kind == MacWSInputKindTap ||
                record.kind == MacWSInputKindSecondaryTap) {
                MacWSSetAppInputGestureWindow(nil);
                MacWSClearDeferredRFBMoveEvents();
            }
            return;
        }
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT GLOBAL-SURFACE-DROP pid=%d requested=%u "
                "reason=unsupported-kind kind=%u\n",
                getpid(), requestedWindowNumber, record.kind);
            fflush(stderr);
        }
        return;
    }
    id window = nil;
    id requestedBaseWindow = nil;
    id outsidePopupWindow = nil;
    BOOL routedToTransientWindow = NO;
    BOOL exactGestureContinuation =
        (record.kind == MacWSInputKindTouchMove ||
         record.kind == MacWSInputKindTouchUp ||
         record.kind == MacWSInputKindTouchCancel ||
         (record.kind == MacWSInputKindScroll &&
          !(record.flags & MacWSInputFlagScrollBegan)) ||
         (record.kind == MacWSInputKindMagnify &&
          !(record.flags & MacWSInputFlagGestureBegan)) ||
         (record.kind == MacWSInputKindRotate &&
          !(record.flags & MacWSInputFlagGestureBegan)));
    BOOL reusedGestureRoute = requestedWindowNumber != 0 &&
        exactGestureContinuation && MacWSAppInputGestureBaseWindow &&
        MacWSAppInputGestureWindow &&
        MacWSAppInputGestureBaseWindowNumber == requestedWindowNumber;
    CGPoint screenPoint = {0};
    if (requestedWindowNumber != 0) {
        requestedBaseWindow = reusedGestureRoute
            ? (__bridge id)MacWSAppInputGestureBaseWindow
            : MacWSWindowWithNumber(application, requestedWindowNumber);
        window = reusedGestureRoute
            ? (__bridge id)MacWSAppInputGestureWindow
            : requestedBaseWindow;
        if (!requestedBaseWindow || !window) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=target-window-closed "
                "window=%u kind=%u\n",
                getpid(), requestedWindowNumber, record.kind);
            fflush(stderr);
            return;
        }
        // Window DisplayStream coordinates are top-left backing pixels. Map
        // them through the producer's real backing scale, not by normalizing
        // them into NSWindow.frame. Runtime-confirmed in VSCode PID 53270:
        // DisplayStream remained 2388 px / 1194 pt after Electron restored the
        // base NSWindow to 1004 pt; the old normalization compressed every
        // input coordinate and made the popup's x=1004..1169 pt region
        // unreachable even though Host correctly composited those pixels.
        // The base window stays top-left anchored, so its current maxY and
        // origin remain the stable screen-space origin during live resizing.
        CGRect windowFrame = ((MacWSMsgRect)objc_msgSend)(
            requestedBaseWindow, sel_registerName("frame"));
        CGFloat backingScale = 0.0;
        SEL backingScaleSelector = sel_registerName("backingScaleFactor");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                requestedBaseWindow, sel_registerName("respondsToSelector:"),
                backingScaleSelector)) {
            backingScale = ((MacWSMsgDouble)objc_msgSend)(
                requestedBaseWindow, backingScaleSelector);
        }
        if (!isfinite(backingScale) || backingScale < 0.5 ||
            backingScale > 8.0) {
            id windowScreen = ((MacWSMsgID)objc_msgSend)(
                requestedBaseWindow, sel_registerName("screen"));
            if (windowScreen && ((MacWSMsgBoolSEL)objc_msgSend)(
                    windowScreen, sel_registerName("respondsToSelector:"),
                    backingScaleSelector)) {
                backingScale = ((MacWSMsgDouble)objc_msgSend)(
                    windowScreen, backingScaleSelector);
            }
        }
        if (!isfinite(backingScale) || backingScale < 0.5 ||
            backingScale > 8.0) {
            // This fallback is equivalent to the prior mapping only when the
            // stream and NSWindow are already the same size. It avoids inventing
            // a Retina factor on a screen that does not report one.
            backingScale = record.frameWidth > 0
                ? record.frameWidth / fmax(windowFrame.size.width, 1.0) : 1.0;
        }
        BOOL exactSystemContinuation =
            MacWSExactSystemPointerActive &&
            MacWSExactSystemPointerContact == record.contactID &&
            MacWSExactSystemPointerWindow == requestedWindowNumber;
        if (record.source == MacWSInputSourceVNC) {
            // OSXvnc publishes x/y against its complete advertised Retina
            // framebuffer. macwsinputd resolves the live target and adds its
            // exact window ID, but it deliberately leaves that producer
            // geometry unchanged. Runtime-confirmed on iPad14,5 with 7DTD
            // window 649: RFB (848,1006)/2732x2048 is AppKit screen
            // (424,521), local (61,195); treating the same record as a
            // window-local DisplayStream sample produced local (424,-115),
            // so Unity never armed the visible Play control. Preserve the
            // broker's exact window identity while mapping this one producer
            // through the desktop affine it actually declared.
            inputMappingFrame = screenFrame;
            screenPoint = (CGPoint){
                screenFrame.origin.x +
                    normalizedX * screenFrame.size.width,
                screenFrame.origin.y +
                    (1.0 - normalizedY) * screenFrame.size.height,
            };
        } else if (exactSystemContinuation &&
            MacWSExactSystemPointerMappingFrame.size.width > 0.0 &&
            MacWSExactSystemPointerMappingFrame.size.height > 0.0) {
            // WindowServer updates NSWindow.frame during a native drag. Using
            // that moving origin to map the next producer-local sample feeds
            // the already-applied displacement back into the pointer and
            // amplifies motion on every event. Keep the down-time affine map
            // immutable through up, exactly as the AppKit tracker snapshot.
            inputMappingFrame = MacWSExactSystemPointerMappingFrame;
            screenPoint = (CGPoint){
                inputMappingFrame.origin.x +
                    normalizedX * inputMappingFrame.size.width,
                inputMappingFrame.origin.y +
                    (1.0 - normalizedY) * inputMappingFrame.size.height,
            };
        } else {
            CGFloat mappedWidth = record.frameWidth / backingScale;
            CGFloat mappedHeight = record.frameHeight / backingScale;
            inputMappingFrame = (CGRect){
                .origin = {
                    windowFrame.origin.x,
                    windowFrame.origin.y + windowFrame.size.height - mappedHeight,
                },
                .size = {mappedWidth, mappedHeight},
            };
            screenPoint = (CGPoint){
                windowFrame.origin.x + record.x / backingScale,
                windowFrame.origin.y + windowFrame.size.height -
                    record.y / backingScale,
            };
        }

        // A menu, sheet, tooltip, popover, or application-modal alert is a
        // real NSWindow owned by the same application. Exact-window streaming
        // still uses the base window as its coordinate space, but AppKit must
        // receive the event in whichever of its own stacked windows is under
        // the mapped screen point. Ventura application-modal NSAlertPanel
        // windows are level 0, exactly like their presenter, so level alone is
        // not an ownership test. Accept a same-level hit only when AppKit's
        // real sheetParent / parentWindow / modalWindow relation resolves it
        // back to this Scene's requested base window. This preserves Scene
        // isolation between unrelated same-process document windows.
        if (!reusedGestureRoute &&
            record.kind != MacWSInputKindRelativePointer) {
            id hitWindow = MacWSWindowForScreenPoint(application, screenPoint);
            if (hitWindow && hitWindow != requestedBaseWindow) {
                NSInteger baseLevel = ((MacWSMsgInteger)objc_msgSend)(
                    requestedBaseWindow, sel_registerName("level"));
                NSInteger hitLevel = ((MacWSMsgInteger)objc_msgSend)(
                    hitWindow, sel_registerName("level"));
                BOOL hitVisible = ((MacWSMsgBool)objc_msgSend)(
                    hitWindow, sel_registerName("isVisible"));
                id hitRoot = MacWSRootPresentingWindow(
                    hitWindow, application);
                BOOL presentedByRequestedBase =
                    hitRoot == requestedBaseWindow;
                if (hitVisible &&
                    (hitLevel > baseLevel || presentedByRequestedBase)) {
                    window = hitWindow;
                    routedToTransientWindow = YES;
                }
            }
        } else {
            routedToTransientWindow = window != requestedBaseWindow;
        }
        BOOL indirectPrimaryDown =
            record.kind == MacWSInputKindTouchDown &&
            record.source == MacWSInputSourceIndirectPointer;
        if (!routedToTransientWindow &&
            (record.kind == MacWSInputKindTap ||
             record.kind == MacWSInputKindSecondaryTap ||
             indirectPrimaryDown)) {
            outsidePopupWindow = MacWSOutsidePopupWindow(
                application, requestedBaseWindow, screenPoint);
        }
    } else {
        screenPoint = (CGPoint){
            screenFrame.origin.x + normalizedX * screenFrame.size.width,
            screenFrame.origin.y +
                (1.0 - normalizedY) * screenFrame.size.height,
        };
    }
    if (!window && record.kind != MacWSInputKindTouchDown &&
        record.kind != MacWSInputKindHover &&
        record.kind != MacWSInputKindMenuHover &&
        record.kind != MacWSInputKindTap &&
        record.kind != MacWSInputKindSecondaryTap &&
        MacWSAppInputGestureWindow) {
        window = (__bridge id)MacWSAppInputGestureWindow;
    } else if (!window) {
        window = MacWSWindowForScreenPoint(application, screenPoint);
    }
    if (!window) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=no-window screen=(%.2f,%.2f)\n",
                getpid(), screenPoint.x, screenPoint.y);
        return;
    }
    BOOL indirectPopupDismissDown = outsidePopupWindow &&
        record.kind == MacWSInputKindTouchDown &&
        record.source == MacWSInputSourceIndirectPointer;
    if (outsidePopupWindow &&
        ((record.kind == MacWSInputKindTap &&
          !MacWSLegacySystemMousePoster()) || indirectPopupDismissDown)) {
        NSInteger popupWindowNumber = ((MacWSMsgInteger)objc_msgSend)(
            outsidePopupWindow, sel_registerName("windowNumber"));
        Class menuWindowClass = objc_getClass("NSMenuWindowManagerWindow");
        BOOL appKitMenu = menuWindowClass && ((MacWSMsgBoolID)objc_msgSend)(
            outsidePopupWindow, sel_registerName("isKindOfClass:"),
            (id)menuWindowClass);
        BOOL dismissed = NO;
        const char *route = "escape-pair";
        if (appKitMenu) {
            dismissed = MacWSCancelActiveMenuForEscape(
                application, popupWindowNumber, YES);
            route = "appkit-menu-cancel";
        } else {
            // Chromium/Electron's Views popup has no NSMenuPresentationInstance
            // and no nested AppKit tracker. Its own responder lifecycle closes
            // on an ordinary Escape pair. Deliver that semantic on the same
            // application main thread; never orderOut: the foreign window or
            // mutate Chromium state behind its delegate.
            MacWSInputRecord escape = record;
            escape.sceneID = MacWSInputSceneForWindow(
                requestedWindowNumber, 0);
            escape.kind = MacWSInputKindKeyDown;
            escape.pressure = 53.0f;
            escape.contactID = 0xff1bu;
            escape.source = record.source == MacWSInputSourceUnknown
                ? MacWSInputSourceFinger : record.source;
            BOOL down = MacWSPostKeyRecord(
                escape, application, eventClass,
                (NSInteger)requestedWindowNumber, NO, NO);
            escape.kind = MacWSInputKindKeyUp;
            escape.timestamp += 0.001;
            BOOL up = MacWSPostKeyRecord(
                escape, application, eventClass,
                (NSInteger)requestedWindowNumber, NO, NO);
            dismissed = down && up;
        }
        if (dismissed) {
            if (indirectPopupDismissDown) {
                MacWSPopupDismissPointerActive = YES;
                MacWSPopupDismissPointerContact = record.contactID;
                MacWSPopupDismissPointerScene = record.sceneID;
            }
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT POPUP-OUTSIDE pid=%d base=%u popup=%ld "
                    "class=%s route=%s\n",
                    getpid(), requestedWindowNumber, (long)popupWindowNumber,
                    object_getClassName(outsidePopupWindow), route);
                fflush(stderr);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          40 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                MacWSNotifyDisplayCatalogChanged('t');
            });
            MacWSSetAppInputGestureWindow(nil);
            MacWSClearDeferredRFBMoveEvents();
            return;
        }
    }
    BOOL beginsContinuousGesture =
        record.kind == MacWSInputKindTouchDown ||
        (record.kind == MacWSInputKindScroll &&
         (record.flags & MacWSInputFlagScrollBegan)) ||
        (record.kind == MacWSInputKindMagnify &&
         (record.flags & MacWSInputFlagGestureBegan)) ||
        (record.kind == MacWSInputKindRotate &&
         (record.flags & MacWSInputFlagGestureBegan));
    if (requestedBaseWindow && beginsContinuousGesture) {
        MacWSSetAppInputGestureRoute(requestedBaseWindow, window,
                                     requestedWindowNumber);
    } else if (record.kind == MacWSInputKindTouchDown ||
               record.kind == MacWSInputKindTap ||
               record.kind == MacWSInputKindSecondaryTap) {
        MacWSSetAppInputGestureWindow(window);
    }
    if (!routedToTransientWindow &&
        (record.kind == MacWSInputKindTouchDown ||
        record.kind == MacWSInputKindTap ||
        record.kind == MacWSInputKindSecondaryTap)) {
        id oldKeyWindow = ((MacWSMsgID)objc_msgSend)(application,
            sel_registerName("keyWindow"));
        BOOL wasActive = ((MacWSMsgBool)objc_msgSend)(application,
            sel_registerName("isActive"));
        if (window != oldKeyWindow && ((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"),
                sel_registerName("makeKeyWindow"))) {
            ((MacWSMsgVoid)objc_msgSend)(window,
                sel_registerName("makeKeyWindow"));
        }
        if (!wasActive && ((MacWSMsgBoolSEL)objc_msgSend)(
                application, sel_registerName("respondsToSelector:"),
                sel_registerName("activateIgnoringOtherApps:"))) {
            ((MacWSMsgVoidBool)objc_msgSend)(application,
                sel_registerName("activateIgnoringOtherApps:"), YES);
        }
        BOOL isActive = ((MacWSMsgBool)objc_msgSend)(application,
            sel_registerName("isActive"));
        BOOL missingActivationDelivered = NO;
        MacWSFrontUISnapshot frontSnapshot =
            MacWSCaptureFrontUISnapshot();
        BOOL ownsFrontUIProcess = frontSnapshot.ownsFrontUIProcess;
        BOOL activationRepaired = NO;
        if (record.source != MacWSInputSourceVNC &&
            (!isActive || !ownsFrontUIProcess)) {
            // A Host Scene names one exact existing AppKit window, so this is
            // the same real user-activation boundary as OSXvnc's pre-down
            // control transaction. Complete the upstream AppKit/SkyLight/LS
            // lifecycle before posting the authoritative system down. Without
            // this ordering a freshly launched VSCode consumed the first tap
            // only as activation and opened its toolbar menu on the second.
            // The helpers execute real framework handlers/transactions and
            // verify their postconditions; no isActive/front predicate is
            // overridden.
            if (!isActive) {
                missingActivationDelivered =
                    MacWSDeliverMissingActivateEvent(application);
                isActive = ((MacWSMsgBool)objc_msgSend)(
                    application, sel_registerName("isActive"));
            }
            ownsFrontUIProcess = MacWSRepairFrontUIApplication(
                application, "host-system-pointer");
            activationRepaired = ownsFrontUIProcess;
            if (!isActive && ((MacWSMsgBoolSEL)objc_msgSend)(
                    application, sel_registerName("respondsToSelector:"),
                    sel_registerName("activateIgnoringOtherApps:"))) {
                ((MacWSMsgVoidBool)objc_msgSend)(application,
                    sel_registerName("activateIgnoringOtherApps:"), YES);
                if (!((MacWSMsgBool)objc_msgSend)(
                        application, sel_registerName("isActive"))) {
                    missingActivationDelivered =
                        MacWSDeliverMissingActivateEvent(application) ||
                        missingActivationDelivered;
                }
                isActive = ((MacWSMsgBool)objc_msgSend)(
                    application, sel_registerName("isActive"));
            }
        }
        id keyWindow = ((MacWSMsgID)objc_msgSend)(application,
            sel_registerName("keyWindow"));
        static unsigned focusLogs;
        if (MacWSRuntimeDiagnosticsEnabled() && focusLogs++ < 12) {
            fprintf(stderr,
                "#### APP-INPUT FOCUS pid=%d gesture=%u active=%s->%s "
                "key=%ld->%ld selected=%ld front=%s repaired=%s "
                "missing-event=%s\n",
                getpid(), record.contactID,
                wasActive ? "YES" : "NO", isActive ? "YES" : "NO",
                oldKeyWindow ? (long)((MacWSMsgInteger)objc_msgSend)(
                    oldKeyWindow, sel_registerName("windowNumber")) : -1L,
                keyWindow ? (long)((MacWSMsgInteger)objc_msgSend)(
                    keyWindow, sel_registerName("windowNumber")) : -1L,
                (long)((MacWSMsgInteger)objc_msgSend)(window,
                    sel_registerName("windowNumber")),
                ownsFrontUIProcess ? "OWNED" : "OTHER",
                activationRepaired ? "YES" : "NO",
                missingActivationDelivered ? "YES" : "NO");
            fflush(stderr);
        }
    }
    NSInteger windowNumber = ((MacWSMsgInteger)objc_msgSend)(window,
        sel_registerName("windowNumber"));
    id keyWindowBeforeEvent = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("keyWindow"));
    NSInteger keyWindowNumberBeforeEvent = keyWindowBeforeEvent
        ? ((MacWSMsgInteger)objc_msgSend)(keyWindowBeforeEvent,
            sel_registerName("windowNumber")) : 0;
    CGPoint windowPoint = ((MacWSMsgPointPoint)objc_msgSend)(window,
        sel_registerName("convertPointFromScreen:"), screenPoint);
    if (record.kind == MacWSInputKindRelativePointer) {
        // Pointer lock keeps the public cursor anchored while only dx/dy
        // advances the game's camera. Preserve that anchor for Unity's
        // separately polled +[NSEvent mouseLocation], then deliver the real
        // mouseMoved NSEvent synchronously on the application's main thread.
        MacWSAppInputPersistentMouseLocation = screenPoint;
        MacWSAppInputPersistentMouseLocationValid = YES;
        id relativeEvent = MacWSCreateAppRelativePointerEvent(
            eventClass, record, window, screenPoint, windowPoint,
            screenFrame, windowNumber);
        if (!relativeEvent) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=relative-event-create "
                "window=%ld delta=(%.0f,%.0f)\n",
                getpid(), (long)windowNumber,
                record.pressure, record.altitude);
            fflush(stderr);
            return;
        }
        MacWSMarkProcessLocalMouseEvent(relativeEvent);
        MacWSSendMouseEventWithStateBridge(application, relativeEvent, 0);
        if (MacWSGamePointerDiagnosticsEnabled()) {
            static _Atomic uint64_t relativeDispatches;
            uint64_t sequence = atomic_fetch_add_explicit(
                &relativeDispatches, 1, memory_order_relaxed) + 1;
            if (sequence <= 4 || (sequence % 240) == 0) {
                fprintf(stderr,
                    "#### APP-INPUT RELATIVE-DISPATCH pid=%d event=%llu "
                    "window=%ld delta=(%.0f,%.0f) local=(%.2f,%.2f)\n",
                    getpid(), (unsigned long long)sequence,
                    (long)windowNumber, record.pressure, record.altitude,
                    windowPoint.x, windowPoint.y);
                fflush(stderr);
            }
        }
        return;
    }
    // RE/runtime-confirmed on this Ventura AppKit build: a process-local
    // down/up pair reaches NSMenuWindowManagerMenuItemsContainerView but does
    // not enter the menu presentation dispatch, while CGPostMouseEvent from
    // the same AppKit/CGS-connected process selects the item and removes the
    // level-101 menu.  Preserve exact per-window routing everywhere else;
    // allow the system route only after the resolved real target itself is an
    // on-screen NSMenuWindowManagerWindow, which is globally frontmost by its
    // popup-menu level and therefore cannot reproduce the Maps/base-window
    // z-order misroute that disabled the blanket exact route.
    Class systemMenuWindowClass = objc_getClass("NSMenuWindowManagerWindow");
    BOOL exactSystemMenu = requestedWindowNumber != 0 &&
        systemMenuWindowClass && ((MacWSMsgBoolID)objc_msgSend)(
            window, sel_registerName("isKindOfClass:"),
            (id)systemMenuWindowClass);
    BOOL exactPointerStart = record.kind == MacWSInputKindTouchDown ||
        record.kind == MacWSInputKindTap ||
        record.kind == MacWSInputKindSecondaryTap;
    BOOL processLocalPreciseScroll = record.kind == MacWSInputKindScroll &&
        MacWSWindowPointUsesProcessLocalPreciseScroll(window, windowPoint);
    BOOL beginsSystemScroll = record.kind == MacWSInputKindScroll &&
        (record.flags & MacWSInputFlagScrollBegan) != 0 &&
        !processLocalPreciseScroll &&
        record.source != MacWSInputSourceVNC;
    // A title bar or other native frame region is intentionally outside the
    // content view. Process-local NSApplication.sendEvent: reaches neither
    // WindowServer's move/resize tracker nor its traffic-light tracking path;
    // runtime diagnostics in VSCode showed an immediate sendEvent return and
    // no geometry change even though all move/up records arrived. Only enter
    // the proven CGPostMouseEvent route when WindowServer independently says
    // this exact requested window is globally under the same point. That
    // postcondition prevents the earlier Maps-behind-Terminal misroute.
    NSInteger globalWindowNumber = 0;
    Class nativeWindowClass = objc_getClass("NSWindow");
    SEL globalHitSelector = sel_registerName(
        "windowNumberAtPoint:belowWindowWithWindowNumber:");
    // The synchronous AppKit global hit test crosses into WindowServer. It is
    // an ownership proof for a new system pointer stream and for the first
    // native CGPostScrollWheelEvent, but no consumer below reads it for an
    // Electron/Catalyst precise scroll or for later phases of an already
    // admitted native scroll. Runtime sample of VSCode pid 23141 on
    // 2026-10-01 found 664/2087 main-thread samples blocked in
    // SLSCopyWindowRoutingRecordsForScreenLocation while processing only 29
    // coalesced scroll records; _latchViewForScrollEvent: and sendEvent: each
    // accounted for one sample. Preserve the exact-window invariant at the
    // transaction boundary without repeating that synchronous IPC at 120 Hz.
    BOOL needsGlobalWindowHit = exactPointerStart || beginsSystemScroll;
    if (needsGlobalWindowHit && nativeWindowClass && class_respondsToSelector(
            object_getClass(nativeWindowClass), globalHitSelector)) {
        globalWindowNumber = ((MacWSMsgIntegerPointInteger)objc_msgSend)(
            (id)nativeWindowClass, globalHitSelector, screenPoint, 0);
    }
    if (MacWSPerformNativeTitlebarDoubleClick(
            record, window, windowPoint, globalWindowNumber)) {
        MacWSSetAppInputGestureWindow(nil);
        MacWSClearDeferredRFBMoveEvents();
        return;
    }
    BOOL catalystContentInput =
        MacWSCatalystWindowUsesProcessLocalInputAtPoint(window, windowPoint);
    id exactContentView = ((MacWSMsgID)objc_msgSend)(
        window, sel_registerName("contentView"));
    CGPoint exactContentPoint = exactContentView
        ? ((MacWSMsgPointPointID)objc_msgSend)(
            exactContentView, sel_registerName("convertPoint:fromView:"),
            windowPoint, nil)
        : (CGPoint){0.0, 0.0};
    CGRect exactContentBounds = exactContentView
        ? ((MacWSMsgRect)objc_msgSend)(
            exactContentView, sel_registerName("bounds"))
        : (CGRect){{0.0, 0.0}, {0.0, 0.0}};
    BOOL continuousContentStart =
        record.kind == MacWSInputKindTouchDown && exactContentView &&
        CGRectContainsPoint(exactContentBounds, exactContentPoint);
    BOOL interopDragProbe =
        record.source == MacWSInputSourceInteropDragProbe;
    // CGPostMouseEvent has no window parameter, so the visible Host layer and
    // WindowServer's independent global hit must agree before the system route
    // is allowed. This equality is the missing invariant: it keeps Maps-behind-
    // Terminal on the exact process-local route, while restoring native popup
    // dismissal, Dock tracking, atomic content controls, traffic lights and
    // title-bar move/zoom whenever the requested surface truly is frontmost.
    // A physical content TouchDown is different: it can synchronously enter
    // AppKit's NSDragging tracker and therefore must retain the exact process-
    // local window identity. Runtime-confirmed with Finder window 115 on
    // 2026-09-09: the former blanket global route received the complete move
    // sequence but never began the user's file drag, while the selected file
    // and target-folder hit points were correct. The short interoperability
    // probe has the opposite contract: Finder.host.log on 2026-09-11 shows its
    // process-local Down/Move/Cancel returning before NSCoreDragManager begins,
    // leaving the drag pasteboard empty. Route only that explicitly tagged
    // synthetic transaction through Finder's native CGS input stream, which
    // is the route under which this pasteboard probe previously succeeded.
    BOOL exactGlobalSystemStart = requestedWindowNumber != 0 &&
        exactPointerStart && globalWindowNumber == windowNumber &&
        !catalystContentInput &&
        (!continuousContentStart || interopDragProbe);
    if (continuousContentStart &&
        (MacWSRuntimeDiagnosticsEnabled() ||
         record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC)) {
        fprintf(stderr,
            "#### APP-INPUT CONTENT-DRAG-ROUTE pid=%d gesture=%u "
            "window=%ld local=(%.2f,%.2f) content=(%.2f,%.2f) "
            "route=%s\n",
            getpid(), record.contactID, (long)windowNumber,
            windowPoint.x, windowPoint.y,
            exactContentPoint.x, exactContentPoint.y,
            interopDragProbe && exactGlobalSystemStart
                ? "native-system-interop-probe"
                : "process-local-tracker");
        fflush(stderr);
    }
    // A tagged second tap must retain AppKit's clickCount=2 semantic. The
    // legacy CGPostMouseEvent route accepts only button states, so arm a narrow
    // native-event repair before posting its ordinary down/up pair. The
    // NSApplication boundary matches the resulting WindowServer events and
    // restores only their click-state field. This is limited to the content
    // view of the exact globally-frontmost Host-selected window; title bars,
    // traffic lights, menus and covered or stale surfaces keep their
    // established routes.
    BOOL nativeContentDoubleClick = NO;
    CGPoint nativeContentPoint = {0.0, 0.0};
    CGRect nativeContentBounds = {{0.0, 0.0}, {0.0, 0.0}};
    if (record.kind == MacWSInputKindTap &&
        (record.flags & MacWSInputFlagDoubleClick) != 0 && window) {
        id contentView = ((MacWSMsgID)objc_msgSend)(
            window, sel_registerName("contentView"));
        if (contentView) {
            nativeContentPoint = ((MacWSMsgPointPointID)objc_msgSend)(
                contentView, sel_registerName("convertPoint:fromView:"),
                windowPoint, nil);
            nativeContentBounds = ((MacWSMsgRect)objc_msgSend)(
                contentView, sel_registerName("bounds"));
            nativeContentDoubleClick = requestedWindowNumber != 0 &&
                globalWindowNumber == windowNumber &&
                CGRectContainsPoint(nativeContentBounds,
                                    nativeContentPoint);
        }
        if (MacWSRuntimeDiagnosticsEnabled() ||
            record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC) {
            fprintf(stderr,
                "#### APP-INPUT DOUBLE-CANDIDATE pid=%d window=%ld "
                "flags=%#x local=(%.2f,%.2f) content=(%.2f,%.2f) "
                "bounds=(%.2f,%.2f %.2fx%.2f) inside=%s\n",
                getpid(), (long)windowNumber, record.flags,
                windowPoint.x, windowPoint.y,
                nativeContentPoint.x, nativeContentPoint.y,
                nativeContentBounds.origin.x,
                nativeContentBounds.origin.y,
                nativeContentBounds.size.width,
                nativeContentBounds.size.height,
                nativeContentDoubleClick ? "YES" : "NO");
            fflush(stderr);
        }
    }
    if (nativeContentDoubleClick) {
        MacWSArmSystemDoubleClick(windowNumber, screenPoint);
        if (MacWSPostLegacySystemPointerEvent(
                record, screenPoint, screenFrame, inputMappingFrame,
                windowNumber, YES)) {
            if (MacWSRuntimeDiagnosticsEnabled() ||
                record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC) {
                fprintf(stderr,
                    "#### APP-INPUT DOUBLE-ROUTE pid=%d window=%ld "
                    "flags=%#x local=(%.2f,%.2f) "
                    "route=native-system-with-click-restore\n",
                    getpid(), (long)windowNumber, record.flags,
                    windowPoint.x, windowPoint.y);
                fflush(stderr);
            }
            MacWSNotifyDisplayCatalogChanged('t');
            MacWSSetAppInputGestureWindow(nil);
            MacWSClearDeferredRFBMoveEvents();
            return;
        }
        MacWSCancelSystemDoubleClick();
        // Do not post the same partially-failed native transition twice. The
        // exact process-local path below remains a bounded fallback if the
        // legacy system API itself is unavailable.
        exactGlobalSystemStart = NO;
    }
    if (MacWSPostLegacySystemPointerEvent(
            record, screenPoint, screenFrame, inputMappingFrame, windowNumber,
            exactSystemMenu || exactGlobalSystemStart)) {
        MacWSNotifyDisplayCatalogChanged('t');
        if (record.kind == MacWSInputKindTouchUp ||
            record.kind == MacWSInputKindTouchCancel ||
            record.kind == MacWSInputKindTap ||
            record.kind == MacWSInputKindSecondaryTap ||
            (record.kind == MacWSInputKindScroll &&
             (record.flags & (MacWSInputFlagScrollEnded |
                              MacWSInputFlagScrollCancelled))) ||
            (record.kind == MacWSInputKindMagnify &&
             (record.flags & (MacWSInputFlagGestureEnded |
                              MacWSInputFlagGestureCancelled))) ||
            (record.kind == MacWSInputKindRotate &&
             (record.flags & (MacWSInputFlagGestureEnded |
                              MacWSInputFlagGestureCancelled))))
            MacWSSetAppInputGestureWindow(nil);
        MacWSClearDeferredRFBMoveEvents();
        return;
    }
    if (record.kind == MacWSInputKindScroll &&
        MacWSPostSystemScrollEvent(
            record, screenPoint, screenFrame, window, windowPoint, windowNumber,
            globalWindowNumber)) {
        if (record.flags & (MacWSInputFlagScrollEnded |
                            MacWSInputFlagScrollCancelled))
            MacWSSetAppInputGestureWindow(nil);
        return;
    }
    if (record.kind == MacWSInputKindScroll) {
        if (record.source == MacWSInputSourceFinger &&
            MacWSWindowUsesElectronPreciseScroll(window) &&
            (record.flags & MacWSInputFlagScrollChanged)) {
            // The process-local Electron route is pixel-precise (runtime CDP
            // evidence above), but Chromium applies less content travel than
            // UIKit's direct-manipulation curve for the same physical swipe.
            // Keep phase/timestamps intact and apply the requested modest
            // Safari-like calibration only to Electron pixel deltas.
            static const float kMacWSElectronDirectScrollGain = 1.10f;
            float horizontal = 0.0f;
            memcpy(&horizontal, &record.contactID, sizeof(horizontal));
            record.pressure *= kMacWSElectronDirectScrollGain;
            horizontal *= kMacWSElectronDirectScrollGain;
            memcpy(&record.contactID, &horizontal, sizeof(horizontal));
        }
        id scrollEvent = MacWSCreateAppScrollEvent(
            eventClass, record, window, windowPoint, screenFrame,
            windowNumber, processLocalPreciseScroll);
        if (!scrollEvent) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=scroll-event-create "
                "window=%ld\n", getpid(), (long)windowNumber);
            return;
        }
        NSInteger eventWindow = ((MacWSMsgInteger)objc_msgSend)(
            scrollEvent, sel_registerName("windowNumber"));
        CGPoint eventPoint = ((MacWSMsgPoint)objc_msgSend)(
            scrollEvent, sel_registerName("locationInWindow"));
        // AppKit's application queue discards the wrapped scroll event because
        // eventWithCGEvent: leaves windowNumber=0 on this launchd session.
        // The broker already selected the exact native NSWindow on its main
        // thread and MacWSCreateAppScrollEvent round-tripped that identity
        // through NSEvent. Recover the ordinary content responder chosen
        // after AppKit's queue has associated a window. Runtime-confirmed with
        // System Settings window 538: public -sendEvent: accepted every phase
        // and logged the correct local point/delta but never moved its SwiftUI
        // sidebar. The generic hit/responder path retains AppKit hit testing
        // and invokes
        // no application-specific view or action.
        if (processLocalPreciseScroll &&
            (record.flags & (MacWSInputFlagScrollBegan |
                             MacWSInputFlagScrollChanged))) {
            // Runtime enumeration of the actual Ventura NSWindow exposes the
            // window-level scroll-session primitive with ABI v24@0:8@16.
            // InputLab proved process-local -sendEvent: never invokes it: all
            // finger phases reached scrollWheel:, but the following native
            // momentum sequence stopped at the window boundary. Establish the
            // same generic view latch that AppKit's hardware-event queue owns;
            // later phases remain ordinary event dispatch and no application
            // view/action is named here.
            SEL latchScrollTarget = sel_registerName(
                "_latchViewForScrollEvent:");
            if (record.flags & MacWSInputFlagScrollBegan)
                MacWSBeginAppInputScrollSession(window);
            if (((MacWSMsgBoolSEL)objc_msgSend)(
                    window, sel_registerName("respondsToSelector:"),
                    latchScrollTarget)) {
                ((MacWSMsgVoidID)objc_msgSend)(
                    window, latchScrollTarget, scrollEvent);
            }
        }
        // Covered/per-window scenes cannot safely use the global
        // WindowServer scroll route above. Keep their conservative AppKit
        // fallback at the window boundary. Do not call a hit-tested private
        // NSView directly: SwiftUI and Catalyst own responder state that is
        // established by NSWindow before scrollWheel: is delivered.
        ((MacWSSendEvent)objc_msgSend)(
            window, sel_registerName("sendEvent:"), scrollEvent);
        MacWSRecordInputLatency(record, latencyMainStart,
                                MacWSInputUptimeSeconds());
        BOOL scrollTerminal = (record.flags &
            (MacWSInputFlagScrollEnded |
             MacWSInputFlagScrollCancelled)) != 0;
        if (processLocalPreciseScroll && scrollTerminal) {
            if (record.flags & MacWSInputFlagScrollMomentum) {
                MacWSEndAppInputScrollSession();
            } else if (record.flags & MacWSInputFlagScrollWillMomentum) {
                // A producer failure must not leak AppKit's view-scrolling
                // state forever. A real momentum Began advances the generation
                // within one display interval and cancels this bounded guard.
                MacWSScheduleAppInputScrollSessionTimeout(window);
            } else {
                MacWSEndAppInputScrollSession();
            }
        }
        if (record.flags & (MacWSInputFlagScrollEnded |
                            MacWSInputFlagScrollCancelled))
            MacWSSetAppInputGestureWindow(nil);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT SCROLL-DISPATCH pid=%d target-window=%ld "
                "event-window=%ld local=(%.2f,%.2f) delta=(%.2f,%.2f) "
                "route=%s\n",
                getpid(), (long)windowNumber, (long)eventWindow,
                eventPoint.x, eventPoint.y,
                ((double (*)(id, SEL))objc_msgSend)(
                    scrollEvent, sel_registerName("scrollingDeltaX")),
                ((double (*)(id, SEL))objc_msgSend)(
                    scrollEvent, sel_registerName("scrollingDeltaY")),
                processLocalPreciseScroll
                    ? "NSWindow.sendEvent-precise"
                    : "NSWindow.sendEvent-discrete-fallback");
            fflush(stderr);
        }
        return;
    }
    if (record.kind == MacWSInputKindMagnify ||
        record.kind == MacWSInputKindRotate) {
        BOOL rotation = record.kind == MacWSInputKindRotate;
        id gestureEvent = MacWSCreateAppGestureEvent(
            eventClass, record, window, screenPoint, windowPoint, screenFrame,
            windowNumber);
        if (!gestureEvent) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=%s-event-create "
                "window=%ld phase=%#x amount=%.6f\n",
                getpid(), rotation ? "rotate" : "magnify",
                (long)windowNumber, record.flags,
                record.pressure);
            return;
        }
        // Ventura's public NSWindow.sendEvent: and NSApplication.sendEvent:
        // both accepted the reconstructed event but stopped before the
        // responder chain in runtime InputLab A/B tests. Runtime enumeration
        // of the actual NSWindow exposed `_reallySendEvent:isDelayedEvent:`
        // (v28@0:8@16B24), the ordinary inner dispatcher used after AppKit's
        // queue has already associated a concrete window. Our broker has done
        // that association above, so enter this generic window dispatcher;
        // no view action or application-specific selector is invoked.
        SEL reallySendEvent = sel_registerName(
            "_reallySendEvent:isDelayedEvent:");
        if (!((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"),
                reallySendEvent)) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=gesture-dispatcher "
                "window=%ld\n", getpid(), (long)windowNumber);
            return;
        }
        BOOL gestureBegan = (record.flags &
            MacWSInputFlagGestureBegan) != 0;
        if (gestureBegan) {
            // RE-confirmed via the installed Ventura Preview arm64e binary:
            // -[PVIKImageView2 magnifyWithEvent:] +0x164 and
            // -rotateWithEvent: +0x1e8 call the corresponding NSEvent
            // enter*TrackingLoopWithFirstEvent: class methods. Runtime sample
            // /tmp/preview-focus-input.sample captured four recursively nested
            // MacWSPostInputOnMainThread -> _reallySendEvent frames while
            // those helpers waited for continuation events. Prepare the exact
            // route now; the class-method hook enables it only if the target
            // responder actually enters that native synchronous tracker.
            MacWSInstallNativeGestureTrackingHooks();
            pthread_mutex_lock(&MacWSAppInputRouteLock);
            MacWSPrepareDirectGestureContextLocked(
                application, eventClass, record, window, windowNumber,
                inputMappingFrame, screenFrame, screenPoint, windowPoint);
            pthread_mutex_unlock(&MacWSAppInputRouteLock);
        }
        ((MacWSMsgVoidIDBool)objc_msgSend)(
            window, reallySendEvent, gestureEvent, NO);
        if (gestureBegan) {
            // An asynchronous responder (Maps/WebKit) never entered the
            // hooked NSEvent tracker, so its prepared route is still present.
            // Remove it without changing that application's normal delivery
            // of later Changed/Ended records. A synchronous tracker clears
            // the same context in its return wrapper after consuming Ended.
            pthread_mutex_lock(&MacWSAppInputRouteLock);
            if (MacWSAppInputDirectGestureContext.prepared &&
                MacWSAppInputDirectGestureContext.kind == record.kind &&
                MacWSAppInputDirectGestureContext.contactID ==
                    record.contactID &&
                (__bridge id)MacWSAppInputDirectGestureContext.window ==
                    window) {
                MacWSClearDirectGestureContextLocked();
            }
            pthread_mutex_unlock(&MacWSAppInputRouteLock);
        }
        MacWSRecordInputLatency(record, latencyMainStart,
                                MacWSInputUptimeSeconds());
        if (record.flags & (MacWSInputFlagGestureEnded |
                            MacWSInputFlagGestureCancelled))
            MacWSSetAppInputGestureWindow(nil);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT %s-DISPATCH pid=%d target-window=%ld "
                "event-window=%ld type=%lu phase=%#x amount=%.6f "
                "route=NSWindow._reallySendEvent\n",
                rotation ? "ROTATE" : "MAGNIFY", getpid(),
                (long)windowNumber,
                (long)((MacWSMsgInteger)objc_msgSend)(
                    gestureEvent, sel_registerName("windowNumber")),
                (unsigned long)((MacWSMsgUInteger)objc_msgSend)(
                    gestureEvent, sel_registerName("type")),
                record.flags, record.pressure);
            fflush(stderr);
        }
        return;
    }
    if ((MacWSRuntimeDiagnosticsEnabled() ||
         record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC) &&
        (record.kind == MacWSInputKindTouchDown ||
         record.kind == MacWSInputKindTap)) {
        id contentView = ((MacWSMsgID)objc_msgSend)(window,
            sel_registerName("contentView"));
        id frameView = contentView ? ((MacWSMsgID)objc_msgSend)(
            contentView, sel_registerName("superview")) : nil;
        CGPoint contentPoint = contentView
            ? ((MacWSMsgPointPointID)objc_msgSend)(contentView,
                sel_registerName("convertPoint:fromView:"), windowPoint,
                nil) : (CGPoint){0.0, 0.0};
        CGPoint framePoint = frameView
            ? ((MacWSMsgPointPointID)objc_msgSend)(frameView,
                sel_registerName("convertPoint:fromView:"), windowPoint,
                nil) : (CGPoint){0.0, 0.0};
        id hitView = contentView
            ? ((MacWSMsgIDPoint)objc_msgSend)(contentView,
                sel_registerName("hitTest:"), contentPoint) : nil;
        id frameHitView = frameView
            ? ((MacWSMsgIDPoint)objc_msgSend)(frameView,
                sel_registerName("hitTest:"), framePoint) : nil;
        MacWSSetAppInputGestureHitView(hitView);
        static unsigned hitLogs;
        if (hitLogs++ < 12) {
            fprintf(stderr,
                "#### APP-INPUT HIT pid=%d gesture=%u kind=%u window=%ld "
                "screen=(%.2f,%.2f) local=(%.2f,%.2f) content=(%.2f,%.2f) "
                "view=%s frame-view=%s\n",
                getpid(), record.contactID, record.kind, (long)windowNumber,
                screenPoint.x, screenPoint.y, windowPoint.x, windowPoint.y,
                contentPoint.x, contentPoint.y,
                hitView ? object_getClassName(hitView) : "nil",
                frameHitView ? object_getClassName(frameHitView) : "nil");
            fflush(stderr);
        }
    }
    if (MacWSRuntimeDiagnosticsEnabled() &&
        record.kind == MacWSInputKindTouchDown) {
        static unsigned geometryLogs;
        if (geometryLogs++ < 3) {
            id ordered = ((MacWSMsgID)objc_msgSend)(application,
                sel_registerName("orderedWindows"));
            NSUInteger orderedCount = [ordered count];
            for (NSUInteger index = 0; index < orderedCount && index < 12;
                 index++) {
                id candidate = [ordered objectAtIndex:index];
                CGRect candidateFrame = ((MacWSMsgRect)objc_msgSend)(candidate,
                    sel_registerName("frame"));
                NSInteger candidateNumber = ((MacWSMsgInteger)objc_msgSend)(candidate,
                    sel_registerName("windowNumber"));
                BOOL visible = ((MacWSMsgBool)objc_msgSend)(candidate,
                    sel_registerName("isVisible"));
                BOOL key = candidate == ((MacWSMsgID)objc_msgSend)(application,
                    sel_registerName("keyWindow"));
                fprintf(stderr,
                    "#### APP-INPUT WINDOW index=%lu number=%ld visible=%s "
                    "key=%s frame=(%.1f,%.1f %.1fx%.1f) selected=%s\n",
                    (unsigned long)index, (long)candidateNumber,
                    visible ? "YES" : "NO", key ? "YES" : "NO",
                    candidateFrame.origin.x, candidateFrame.origin.y,
                    candidateFrame.size.width, candidateFrame.size.height,
                    candidate == window ? "YES" : "NO");
            }
            id closeButton = ((MacWSMsgIDInteger)objc_msgSend)(window,
                sel_registerName("standardWindowButton:"), 0);
            id buttonSuperview = closeButton
                ? ((MacWSMsgID)objc_msgSend)(closeButton,
                    sel_registerName("superview")) : nil;
            if (closeButton && buttonSuperview) {
                CGRect buttonFrame = ((MacWSMsgRect)objc_msgSend)(closeButton,
                    sel_registerName("frame"));
                CGRect inWindow = ((MacWSMsgRectRectID)objc_msgSend)(buttonSuperview,
                    sel_registerName("convertRect:toView:"), buttonFrame, nil);
                CGRect inScreen = ((MacWSMsgRectRect)objc_msgSend)(window,
                    sel_registerName("convertRectToScreen:"), inWindow);
                fprintf(stderr,
                    "#### APP-INPUT CLOSE window=%ld screen=(%.1f,%.1f %.1fx%.1f)\n",
                    (long)windowNumber, inScreen.origin.x, inScreen.origin.y,
                    inScreen.size.width, inScreen.size.height);
            }
            fflush(stderr);
        }
    }
    // A real CGEvent commits its screen position to WindowServer before
    // NSApplication dispatch and that value remains visible to later
    // +[NSEvent mouseLocation] calls. This exact-window fallback is
    // process-local, so persist the already-resolved screen point here after
    // all native CGEvent routes above declined the record. RE-confirmed in
    // UnityPlayer 2022.3.62f2 arm64: 0xf1dd34 calls 0xf2ab24 once per input
    // tick, 0xf2abac invokes +[NSEvent mouseLocation], and stores the result at
    // InputManager+0xc8; -[PlayerAppDelegate DidSendEvent:] then reads that
    // same field at 0xf1a864 when constructing the queued mouse event. A
    // dispatch-only override therefore left every click paired with the old
    // absolute position even though its NSEvent.locationInWindow was correct.
    MacWSAppInputPersistentMouseLocation = screenPoint;
    MacWSAppInputPersistentMouseLocationValid = YES;
    NSUInteger eventType = MacWSNSEventType((MacWSInputKind)record.kind);
    NSInteger clickCount = (record.flags & MacWSInputFlagDoubleClick) ? 2 : 1;
    BOOL pressed = record.kind == MacWSInputKindTouchDown ||
                   record.kind == MacWSInputKindTap ||
                   record.kind == MacWSInputKindTouchMove;
    float pressure = pressed
        ? (record.source == MacWSInputSourcePencil
            ? fmaxf(0.0f, fminf(1.0f, record.pressure))
            : (record.pressure > 0.0f ? record.pressure : 1.0f))
        : 0.0f;
    id event = MacWSRuntimeDiagnosticsEnabled()
        ? MacWSCreateAppMouseEvent(eventClass, record, eventType,
            screenPoint, windowPoint, screenFrame, windowNumber)
        : nil;
    if (!event) {
        event = ((MacWSMouseEventFactory)objc_msgSend)((id)eventClass,
            sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
            eventType, windowPoint, 0, record.timestamp, windowNumber, nil,
            MacWSNextAppInputEventNumber(), clickCount, pressure);
    }
    if (!event) {
        fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=event-create window=%ld\n",
                getpid(), (long)windowNumber);
        if (record.kind == MacWSInputKindTouchUp ||
            record.kind == MacWSInputKindTouchCancel) {
            MacWSSetAppInputGestureWindow(nil);
        }
        return;
    }
    MacWSMarkProcessLocalMouseEvent(event);
    MacWSApplyTabletMetadata(event, record);
    BOOL isRFB = record.sceneID == 0x564e430000000001ull;
    BOOL usesBufferedTracking = isRFB || requestedWindowNumber != 0;
    if (record.kind == MacWSInputKindTap ||
        record.kind == MacWSInputKindSecondaryTap) {
        // Both VNC and the native Host express a stationary click as one
        // record. Construct the matching pair in the target process, queue up
        // first, then let AppKit's real synchronous control/menu tracker
        // consume it while dispatching down. Splitting this pair across two
        // datagrams previously allowed a nested tracker to starve the up.
        BOOL secondary = record.kind == MacWSInputKindSecondaryTap;
        NSUInteger upType = secondary ? 4 /* rightMouseUp */
                                      : 2 /* leftMouseUp */;
        MacWSInputRecord upRecord = record;
        upRecord.kind = MacWSInputKindTouchUp;
        upRecord.pressure = 0.0f;
        id upEvent = MacWSRuntimeDiagnosticsEnabled()
            ? MacWSCreateAppMouseEvent(eventClass, upRecord, upType,
                screenPoint, windowPoint, screenFrame, windowNumber)
            : nil;
        if (!upEvent) {
            upEvent = ((MacWSMouseEventFactory)objc_msgSend)((id)eventClass,
                sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
                upType, windowPoint, 0,
                record.timestamp + 0.001, windowNumber, nil,
                MacWSNextAppInputEventNumber(), clickCount, 0.0f);
        }
        if (!upEvent) {
            fprintf(stderr,
                "#### APP-INPUT DROP pid=%d reason=tap-up-create window=%ld gesture=%u\n",
                getpid(), (long)windowNumber, record.contactID);
            MacWSSetAppInputGestureWindow(nil);
            return;
        }
        MacWSMarkProcessLocalMouseEvent(upEvent);
        upRecord.kind = MacWSInputKindTouchUp;
        MacWSApplyTabletMetadata(upEvent, upRecord);
        id activeMenuPresentation = MacWSActiveMenuPresentationInstance();
        if (!secondary && !activeMenuPresentation &&
            requestedWindowNumber != 0) {
            // A direct UIKit tap has no preceding pointer-motion packet, while
            // AppKit and Electron legitimately use mouseMoved/tracking-area
            // state to reveal and arm controls (Terminal's tab close button is
            // one concrete example). Apply the same complete semantic after
            // routing to a real higher-level transient NSWindow instead of
            // silently omitting hover only because the final window differs
            // from the base. activeMenuPresentation remains the authoritative
            // exclusion for an already-running native AppKit menu tracker.
            MacWSInputRecord hoverRecord = record;
            hoverRecord.kind = MacWSInputKindHover;
            hoverRecord.pressure = 0.0f;
            id hoverEvent = MacWSRuntimeDiagnosticsEnabled()
                ? MacWSCreateAppMouseEvent(eventClass, hoverRecord,
                    5 /* mouseMoved */, screenPoint, windowPoint,
                    screenFrame, windowNumber)
                : nil;
            if (!hoverEvent) {
                hoverEvent = ((MacWSMouseEventFactory)objc_msgSend)(
                    (id)eventClass,
                    sel_registerName("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
                    5, windowPoint, 0, record.timestamp, windowNumber, nil,
                    MacWSNextAppInputEventNumber(), 0, 0.0f);
            }
            if (hoverEvent) {
                MacWSMarkProcessLocalMouseEvent(hoverEvent);
                MacWSSendMouseEventWithStateBridge(
                    application, hoverEvent, 0);
            }
        }
        if (activeMenuPresentation && routedToTransientWindow) {
            // NSMenuPresentationInstance owns a nested nextEvent loop and does
            // not receive mouse input through NSApplication.sendEvent:. Put a
            // complete down/up pair in its real queue in chronological order.
            // AppKit remains responsible for hit testing and invoking the
            // selected item's action.
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), upEvent, YES);
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), event, YES);
            MacWSNotifyDisplayCatalogChanged('t');
            MacWSSetAppInputGestureWindow(nil);
            MacWSClearDeferredRFBMoveEvents();
            return;
        }
        // Either mouse button can synchronously enter AppKit/Carbon tracking:
        // a primary click can open an Electron toolbar menu just as a
        // secondary click opens a context menu. Cache the exact source/window
        // transform before sendEvent: and expose the synchronous interval to
        // the socket thread. If sendEvent: returns normally this interval is
        // only a few microseconds; if it enters TrackMenuCommon, later taps go
        // straight into the event queue that the nested tracker consumes.
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        MacWSCacheMenuContextLocked(
            application, eventClass, windowNumber, inputMappingFrame,
            screenPoint, windowPoint, NO);
        pthread_mutex_unlock(&MacWSAppInputRouteLock);
        MacWSAppInputRFBTrackingActive = YES;
        MacWSAppInputRFBTrackingButtons = secondary ? 2u : 1u;
        atomic_store_explicit(&MacWSAppInputSynchronousTrackingActive, YES,
                              memory_order_release);
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), upEvent, YES);
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), event);
        MacWSCompletePrequeuedAtomicUp(application, upEvent, upType);
        atomic_store_explicit(&MacWSAppInputSynchronousTrackingActive, NO,
                              memory_order_release);
        MacWSAppInputRFBTrackingActive = NO;
        MacWSAppInputRFBTrackingButtons = 0;
        MacWSRecordInputLatency(record, latencyMainStart,
                                MacWSInputUptimeSeconds());
        if (MacWSRuntimeDiagnosticsEnabled() ||
            record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC) {
            fprintf(stderr,
                "#### APP-INPUT TAP-COMPLETE pid=%d button=%s gesture=%u window=%ld "
                "clicks=%ld flags=%#x screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                getpid(), secondary ? "secondary" : "primary",
                record.contactID, (long)windowNumber,
                (long)clickCount, record.flags,
                screenPoint.x, screenPoint.y, windowPoint.x, windowPoint.y);
            fflush(stderr);
        }
        MacWSLogAppInputGestureHitResult("tap", record.contactID);
        id keyWindowAfterEvent = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("keyWindow"));
        NSInteger keyWindowNumberAfterEvent = keyWindowAfterEvent
            ? ((MacWSMsgInteger)objc_msgSend)(keyWindowAfterEvent,
                sel_registerName("windowNumber")) : 0;
        if (keyWindowNumberAfterEvent != keyWindowNumberBeforeEvent)
            MacWSNotifyDisplayCatalogChanged('k');
        // Any atomic click can create or dismiss a separate AppKit/Electron
        // popover window while the key window remains unchanged. Runtime on
        // VSCode's Simple Browser showed the outside click completed in the
        // base NSWindow, but Host kept compositing the closed transient's last
        // IOSurface because this edge was previously emitted only for right
        // clicks. Reconcile after every semantic click; displayd still reads
        // the real on-screen CGWindow catalog and owns attach/detach policy.
        MacWSNotifyDisplayCatalogChanged('t');
        MacWSSetAppInputGestureWindow(nil);
        MacWSClearDeferredRFBMoveEvents();
        return;
    }
    if (usesBufferedTracking && record.kind == MacWSInputKindTouchDown) {
        // Do not enter control tracking until the complete tap is available.
        // The chroot application has no ordinary login-session event pump;
        // runtime evidence showed two postEvent: calls remain unconsumed.
        MacWSClearDeferredRFBMoveEvents();
        MacWSSetDeferredRFBDownEvent(event);
        if (logEvent) {
            fprintf(stderr,
                "#### APP-INPUT DEFER pid=%d kind=%u window=%ld\n",
                getpid(), record.kind, (long)windowNumber);
            fflush(stderr);
        }
        return;
    }
    if (usesBufferedTracking && MacWSAppInputRFBTrackingActive) {
        // This block is running re-entrantly inside sendEvent(mouseDown)'s
        // tracking loop. Queue the real event at the head; the tracker consumes
        // it before requesting the next one. In particular, up releases the
        // synchronous outer dispatch instead of starting another sendEvent.
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, YES);
    } else if (usesBufferedTracking && record.kind == MacWSInputKindTouchMove &&
               MacWSAppInputDeferredRFBDownEvent) {
        // Start the real AppKit tracker as soon as the gesture crosses VNC's
        // drag slop. While sendEvent(mouseDown) owns the main thread, the
        // socket thread posts subsequent ordinary NSEvents directly into the
        // application queue. NSApplication explicitly supports subthread
        // postEvent:atStart: and wakes the main event queue.
        //
        // A fast gesture may already have records in MacWSAppInputPending. Do
        // not start live mode in that case: its pre-scheduled CFRunLoop block
        // is not guaranteed to execute inside every NSControl tracking loop.
        // The route lock makes this test race-free against socket enqueue.
        BOOL useBufferedFallback = NO;
        id downEvent = nil;
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        MacWSArmDirectTrackingContextLocked(application, eventClass,
            record.sceneID, record.contactID, windowNumber, inputMappingFrame,
            screenPoint, windowPoint);
        useBufferedFallback = MacWSHasPendingTrackingRecordLocked(
            record.sceneID, record.contactID);
        if (useBufferedFallback) {
            MacWSClearDirectTrackingContextLocked();
        } else {
            downEvent = [(__bridge id)MacWSAppInputDeferredRFBDownEvent retain];
            MacWSSetDeferredRFBDownEvent(nil);
            MacWSAppInputRFBTrackingActive = YES;
            MacWSAppInputRFBTrackingButtons = 1u;
            // Seed the queue before dispatching down. Future socket records
            // append at the tail, preserving move...up arrival order.
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), event, YES);
        }
        pthread_mutex_unlock(&MacWSAppInputRouteLock);

        if (useBufferedFallback) {
            // Keep only the newest position. The macOS 13.4 _NSMouseTracker
            // explicitly enables event coalescing; runtime LLDB evidence
            // showed a prefilled four-move burst invokes continueTracking:
            // once at a middle sample, while one latest move lands exactly at
            // release.
            [MacWSAppInputDeferredRFBMoveEvents removeAllObjects];
            [MacWSAppInputDeferredRFBMoveEvents addObject:event];
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT LIVE-FALLBACK pid=%d gesture=%u "
                    "reason=pending-record\n",
                    getpid(), record.contactID);
                fflush(stderr);
            }
        } else {
            ((MacWSSendEvent)objc_msgSend)(application,
                sel_registerName("sendEvent:"), downEvent);
            pthread_mutex_lock(&MacWSAppInputRouteLock);
            // An NSControl tracker normally returns only after the socket
            // route posts its matching Up. Finder's TTrackingImageView is
            // different: runtime-confirmed in Finder.host.log at
            // 1789130632 that sendEvent(mouseDown) returned first and the
            // already-queued initial move entered _dragUntilMouseUp: on the
            // next AppKit turn. Preserve an accepting exact gesture context
            // across that boundary so the CoreDrag bridge can hand subsequent
            // move/up records to its real CGS input callback. A synchronously
            // completed/cancelled tracker is already non-accepting and is
            // retired here as before.
            MacWSAppInputRFBTrackingActive = NO;
            MacWSAppInputRFBTrackingButtons = 0;
            BOOL awaitingAsynchronousTracker =
                MacWSAppInputDirectContext.accepting &&
                MacWSAppInputDirectContext.contactID == record.contactID &&
                MacWSAppInputDirectContext.sceneID == record.sceneID &&
                MacWSAppInputDirectContext.windowNumber == windowNumber;
            if (!awaitingAsynchronousTracker)
                MacWSClearDirectTrackingContextLocked();
            pthread_mutex_unlock(&MacWSAppInputRouteLock);
            if (MacWSRuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "#### APP-INPUT LIVE-DISPATCH-RETURN pid=%d gesture=%u "
                    "window=%ld first-move=(%.2f,%.2f) "
                    "awaiting-async-tracker=%s\n",
                    getpid(), record.contactID, (long)windowNumber,
                    screenPoint.x, screenPoint.y,
                    awaitingAsynchronousTracker ? "YES" : "NO");
                fflush(stderr);
            }
            MacWSLogAppInputGestureHitResult("live-drag", record.contactID);
            [downEvent release];
            MacWSSetAppInputGestureWindow(nil);
            MacWSClearDeferredRFBMoveEvents();
            return;
        }
    } else if (usesBufferedTracking &&
        (record.kind == MacWSInputKindTouchUp ||
         record.kind == MacWSInputKindTouchCancel) &&
        MacWSAppInputDeferredRFBDownEvent) {
        id downEvent = [(__bridge id)MacWSAppInputDeferredRFBDownEvent retain];
        MacWSSetDeferredRFBDownEvent(nil);
        NSArray *moves = [MacWSAppInputDeferredRFBMoveEvents copy];
        MacWSClearDeferredRFBMoveEvents();
        // Build the real queue head in move[0]..move[n-1],up order. Runtime
        // LLDB breakpoints on NSSliderCell showed that posting moves forward
        // and then up with atStart:YES reached startTrackingAt: and
        // stopTracking: but never continueTracking: -- every insertion is a
        // push, so up became the first matching event. Appending at the tail
        // also produced no continueTracking: call in this launchd-created
        // session. Push up first, then moves in reverse order, leaving the
        // complete gesture at the head in chronological order. No
        // target/action/value setter is used.
        MacWSAppInputRFBTrackingActive = YES;
        MacWSAppInputRFBTrackingButtons = 1u;
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, YES);
        for (NSUInteger index = [moves count]; index > 0; index--) {
            id moveEvent = [moves objectAtIndex:index - 1];
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), moveEvent, YES);
        }
        ((MacWSSendEvent)objc_msgSend)(application,
            sel_registerName("sendEvent:"), downEvent);
        MacWSAppInputRFBTrackingActive = NO;
        MacWSAppInputRFBTrackingButtons = 0;
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr,
                "#### APP-INPUT GESTURE-DISPATCH-RETURN pid=%d gesture=%u "
                "window=%ld moves=%lu release=(%.2f,%.2f)\n",
                getpid(), record.contactID, (long)windowNumber,
                (unsigned long)[moves count], screenPoint.x, screenPoint.y);
            fflush(stderr);
        }
        MacWSLogAppInputGestureHitResult("drag", record.contactID);
        [moves release];
        [downEvent release];
    } else if ((isRFB || requestedWindowNumber != 0) &&
               (record.kind == MacWSInputKindHover ||
                record.kind == MacWSInputKindMenuHover)) {
        id menuPresentation = MacWSActiveMenuPresentationInstance();
        if (menuPresentation) {
            // The active menu's nested nextEvent loop is the queue consumer.
            // Keep normal event ordering and let AppKit's own handleEvent:
            // perform hit-testing, submenu switching, and highlighting.
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), event, NO);
            static _Atomic uint64_t menuHoverPosts;
            uint64_t post = MacWSRuntimeDiagnosticsEnabled()
                ? atomic_fetch_add_explicit(
                    &menuHoverPosts, 1, memory_order_relaxed) + 1 : 0;
            if (post != 0 && (post <= 48 || (post % 600) == 0)) {
                fprintf(stderr,
                    "#### APP-INPUT MENU-QUEUE pid=%d event=%llu "
                    "window=%ld local=(%.2f,%.2f) presentation=%s\n",
                    getpid(), (unsigned long long)post,
                    (long)windowNumber, windowPoint.x, windowPoint.y,
                    object_getClassName(menuPresentation));
                fflush(stderr);
            }
        } else {
            // RE-confirmed in macOS 13.4 AppKit:
            // NSMenuBarPresentationInstance::_mouseMovedEventHandler: first
            // invokes _updateTrackedControllerForMenuBar. It forwards to the
            // ordinary NSMenuPresentationInstance handler only when that
            // update found a tracker (or its own active flag is already set),
            // and otherwise returns false. This is the system's own routing
            // decision, not a forced highlight/action.
            id menuBarPresentation = MacWSMenuBarPresentationInstance();
            SEL menuBarMove =
                sel_registerName("_mouseMovedEventHandler:");
            BOOL menuBarHandled = menuBarPresentation &&
                ((MacWSMsgBoolSEL)objc_msgSend)(
                    menuBarPresentation,
                    sel_registerName("respondsToSelector:"), menuBarMove);
            if (menuBarHandled) {
                BOOL previousLocationActive =
                    MacWSAppInputMouseLocationActive;
                CGPoint previousLocation = MacWSAppInputMouseLocation;
                MacWSAppInputMouseLocation = screenPoint;
                MacWSAppInputMouseLocationActive = YES;
                menuBarHandled = ((MacWSMsgBoolID)objc_msgSend)(
                    menuBarPresentation, menuBarMove, event);
                MacWSAppInputMouseLocation = previousLocation;
                MacWSAppInputMouseLocationActive = previousLocationActive;
            }
            if (menuBarHandled) {
                static _Atomic uint64_t menuBarHovers;
                uint64_t handled = MacWSRuntimeDiagnosticsEnabled()
                    ? atomic_fetch_add_explicit(
                        &menuBarHovers, 1, memory_order_relaxed) + 1 : 0;
                if (handled != 0 &&
                    (handled <= 48 || (handled % 600) == 0)) {
                    fprintf(stderr,
                        "#### APP-INPUT MENU-BAR-HANDLED pid=%d event=%llu "
                        "window=%ld local=(%.2f,%.2f) presentation=%s\n",
                        getpid(), (unsigned long long)handled,
                        (long)windowNumber, windowPoint.x, windowPoint.y,
                        object_getClassName(menuBarPresentation));
                    fflush(stderr);
                }
            } else {
                MacWSSendMouseEventWithStateBridge(application, event, 0);
            }
        }
    } else {
        // Native-host gestures, hover, and RFB drags keep ordinary queue
        // semantics. Flush a deferred tap-down before the first drag record.
        if (usesBufferedTracking && MacWSAppInputDeferredRFBDownEvent) {
            id downEvent = (__bridge id)MacWSAppInputDeferredRFBDownEvent;
            ((MacWSPostEvent)objc_msgSend)(application,
                sel_registerName("postEvent:atStart:"), downEvent, NO);
            MacWSSetDeferredRFBDownEvent(nil);
        }
        ((MacWSPostEvent)objc_msgSend)(application,
            sel_registerName("postEvent:atStart:"), event, NO);
    }
    if (logEvent) {
        fprintf(stderr,
                "#### APP-INPUT POST pid=%d kind=%u window=%ld screen=(%.2f,%.2f) local=(%.2f,%.2f)\n",
                getpid(), record.kind, (long)windowNumber,
                screenPoint.x, screenPoint.y, windowPoint.x, windowPoint.y);
        fflush(stderr);
    }
    if (record.kind == MacWSInputKindTouchUp ||
        record.kind == MacWSInputKindTouchCancel) {
        MacWSSetAppInputGestureWindow(nil);
        MacWSSetAppInputGestureHitView(nil);
    }
}

// CFRunLoopPerformBlock does not promise ordering between separately queued
// blocks. Runtime VNC evidence on 2026-07-26 showed the datagram thread receive
// down(1) then up(3), while AppKit executed the two blocks as up(3) then
// down(1). Keep one scheduled drain and an explicit FIFO so a gesture's event
// order is invariant even in nested AppKit tracking run loops.
static void MacWSDrainOneAppInputOnMainThread(void);

static void MacWSScheduleAppInputDrain(void) {
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    if (!mainRunLoop) return;

    // Some applications (runtime-confirmed with steam_osx PID 46986 on
    // 2026-08-21) drive AppKit through a nested
    // -[NSApplication _nextEventMatchingEventMask:untilDate:inMode:dequeue:]
    // loop. A block queued only in kCFRunLoopCommonModes is not guaranteed to
    // be serviced by that application's current, private mode. Queue the same
    // FIFO token in the mode that is actually active as well. Both copies
    // share this main-thread-only guard, so exactly one record is consumed.
    CFStringRef activeMode = CFRunLoopCopyCurrentMode(mainRunLoop);
    __block BOOL consumed = NO;
    void (^drainOnce)(void) = ^{
        if (consumed) return;
        consumed = YES;
        MacWSDrainOneAppInputOnMainThread();
    };
    if (activeMode) {
        CFRunLoopPerformBlock(mainRunLoop, activeMode, drainOnce);
    }
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, drainOnce);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        char modeName[192] = "(none)";
        if (activeMode) {
            CFStringGetCString(activeMode, modeName, sizeof(modeName),
                               kCFStringEncodingUTF8);
        }
        fprintf(stderr,
            "#### APP-INPUT SCHEDULE pid=%d active-mode=%s route=current+common\n",
            getpid(), modeName);
        fflush(stderr);
    }
    if (activeMode) CFRelease(activeMode);
    CFRunLoopWakeUp(mainRunLoop);
}

static void MacWSDrainOneAppInputOnMainThread(void) {
    NSMutableArray<NSData *> *batch = [NSMutableArray arrayWithCapacity:16];
    BOOL scheduleNext = NO;
    BOOL pauseForGestureBegan = NO;
    @synchronized(MacWSAppInputPending) {
        if ([MacWSAppInputPending count] != 0) {
            NSData *first = [MacWSAppInputPending objectAtIndex:0];
            [batch addObject:first];
            [MacWSAppInputPending removeObjectAtIndex:0];
            MacWSInputRecord firstRecord = {0};
            if ([first length] == sizeof(firstRecord))
                [first getBytes:&firstRecord length:sizeof(firstRecord)];
            pauseForGestureBegan =
                (firstRecord.kind == MacWSInputKindMagnify ||
                 firstRecord.kind == MacWSInputKindRotate) &&
                (firstRecord.flags & MacWSInputFlagGestureBegan) != 0;
            BOOL plainKeyBatch =
                (firstRecord.kind == MacWSInputKindKeyDown ||
                 firstRecord.kind == MacWSInputKindKeyUp) &&
                (MacWSInputModifiersForScene(firstRecord.sceneID) &
                    ((1u << 18) | (1u << 19) | (1u << 20))) == 0;
            // A fast text burst previously required one distinct
            // CFRunLoopPerformBlock turn per key-down and key-up. Sublime's
            // main loop can legitimately spend several milliseconds between
            // those turns, so later glyphs arrived in visible clumps. Drain a
            // bounded run of ordinary text-key records in the same main-loop
            // turn while preserving their exact FIFO order. Command/control
            // shortcuts and every pointer/tracking transition keep the
            // existing one-record scheduling semantics.
            while (plainKeyBatch && batch.count < 32 &&
                   [MacWSAppInputPending count] != 0) {
                NSData *candidate = [MacWSAppInputPending objectAtIndex:0];
                MacWSInputRecord candidateRecord = {0};
                if ([candidate length] != sizeof(candidateRecord)) break;
                [candidate getBytes:&candidateRecord
                              length:sizeof(candidateRecord)];
                BOOL candidatePlainKey =
                    (candidateRecord.kind == MacWSInputKindKeyDown ||
                     candidateRecord.kind == MacWSInputKindKeyUp) &&
                    (MacWSInputModifiersForScene(candidateRecord.sceneID) &
                        ((1u << 18) | (1u << 19) | (1u << 20))) == 0;
                if (!candidatePlainKey) break;
                [batch addObject:candidate];
                [MacWSAppInputPending removeObjectAtIndex:0];
            }
            if ([MacWSAppInputPending count] != 0 &&
                !pauseForGestureBegan) {
                // Keep the scheduled token and enqueue the next block before
                // dispatching this event. sendEvent(mouseDown) can enter a
                // nested button-tracking run loop; that loop must be able to
                // execute the already-ordered mouseUp block to let the first
                // sendEvent return.
                scheduleNext = YES;
            } else if (!pauseForGestureBegan) {
                MacWSAppInputDrainScheduled = NO;
            }
        } else {
            MacWSAppInputDrainScheduled = NO;
        }
    }
    if (scheduleNext) MacWSScheduleAppInputDrain();
    for (NSData *data in batch) {
        if ([data length] != sizeof(MacWSInputRecord)) continue;
        MacWSInputRecord record = {0};
        [data getBytes:&record length:sizeof(record)];
        @autoreleasepool {
            MacWSPostInputOnMainThread(record);
        }
    }
    if (pauseForGestureBegan) {
        BOOL resumeDrain = NO;
        @synchronized(MacWSAppInputPending) {
            // This drain token was deliberately not replaced before dispatch:
            // a native enter*TrackingLoop must receive continuation phases
            // from NSApplication's queue, not from a recursively executed
            // CFRunLoop block. Once the initial handler (and any nested native
            // tracker) returns, resume the ordinary FIFO for other gestures.
            if ([MacWSAppInputPending count] != 0) {
                MacWSAppInputDrainScheduled = YES;
                resumeDrain = YES;
            } else {
                MacWSAppInputDrainScheduled = NO;
            }
        }
        if (resumeDrain) MacWSScheduleAppInputDrain();
    }
}

static void MacWSEnqueueAppInputRecord(MacWSInputRecord record) {
    BOOL scheduleDrain = NO;
    NSData *data = [[NSData alloc] initWithBytes:&record length:sizeof(record)];
    @synchronized(MacWSAppInputPending) {
        BOOL continuous = record.kind == MacWSInputKindTouchMove ||
                          record.kind == MacWSInputKindHover ||
                          record.kind == MacWSInputKindMenuHover ||
                          record.kind == MacWSInputKindScroll ||
                          record.kind == MacWSInputKindRelativePointer ||
                          record.kind == MacWSInputKindConfigureWindow;
        BOOL replaced = NO;
        NSUInteger pendingCount = [MacWSAppInputPending count];
        if (continuous && pendingCount != 0) {
            NSData *lastData = [MacWSAppInputPending objectAtIndex:pendingCount - 1];
            if ([lastData length] == sizeof(MacWSInputRecord)) {
                MacWSInputRecord last = {0};
                [lastData getBytes:&last length:sizeof(last)];
                if (last.kind == record.kind &&
                    last.sceneID == record.sceneID &&
                    (record.kind == MacWSInputKindScroll ||
                     last.contactID == record.contactID) &&
                    (record.kind != MacWSInputKindScroll ||
                     last.flags == record.flags) &&
                    last.targetPID == record.targetPID) {
                    if (record.kind == MacWSInputKindRelativePointer) {
                        record.pressure = fmaxf(-4096.0f,
                            fminf(4096.0f,
                                last.pressure + record.pressure));
                        record.altitude = fmaxf(-4096.0f,
                            fminf(4096.0f,
                                last.altitude + record.altitude));
                        [data release];
                        data = [[NSData alloc] initWithBytes:&record
                                                     length:sizeof(record)];
                    } else if (record.kind == MacWSInputKindScroll) {
                        float previousHorizontal = 0.0f;
                        float incomingHorizontal = 0.0f;
                        memcpy(&previousHorizontal, &last.contactID,
                               sizeof(previousHorizontal));
                        memcpy(&incomingHorizontal, &record.contactID,
                               sizeof(incomingHorizontal));
                        record.pressure = fmaxf(-16384.0f,
                            fminf(16384.0f,
                                last.pressure + record.pressure));
                        incomingHorizontal = fmaxf(-16384.0f,
                            fminf(16384.0f,
                                previousHorizontal + incomingHorizontal));
                        memcpy(&record.contactID, &incomingHorizontal,
                               sizeof(record.contactID));
                        [data release];
                        data = [[NSData alloc] initWithBytes:&record
                                                     length:sizeof(record)];
                    }
                    [MacWSAppInputPending replaceObjectAtIndex:pendingCount - 1
                                                    withObject:data];
                    replaced = YES;
                }
            }
        }
        if (!replaced) {
            // Never discard a button transition. If a stalled main thread has
            // accumulated motion, evict its oldest continuous sample first so
            // a release/tap can always enter the bounded queue.
            // Magnify Changed records deliberately remain discrete: AppKit's
            // magnification is a ratio delta, and folding several UIKit
            // samples into one large delta made Maps visibly jump in scale.
            while ([MacWSAppInputPending count] >= 128) {
                NSUInteger removable = NSNotFound;
                for (NSUInteger index = 0;
                     index < [MacWSAppInputPending count]; index++) {
                    NSData *candidateData =
                        [MacWSAppInputPending objectAtIndex:index];
                    if ([candidateData length] != sizeof(MacWSInputRecord)) continue;
                    MacWSInputRecord candidate = {0};
                    [candidateData getBytes:&candidate length:sizeof(candidate)];
                    if (candidate.kind == MacWSInputKindTouchMove ||
                        candidate.kind == MacWSInputKindHover ||
                        candidate.kind == MacWSInputKindMenuHover ||
                        candidate.kind == MacWSInputKindScroll ||
                        candidate.kind == MacWSInputKindRelativePointer ||
                        candidate.kind == MacWSInputKindMagnify ||
                        candidate.kind == MacWSInputKindRotate ||
                        candidate.kind == MacWSInputKindConfigureWindow) {
                        removable = index;
                        break;
                    }
                }
                if (removable == NSNotFound) break;
                [MacWSAppInputPending removeObjectAtIndex:removable];
            }
            if (!continuous || [MacWSAppInputPending count] < 128)
                [MacWSAppInputPending addObject:data];
        }
        if (!MacWSAppInputDrainScheduled) {
            MacWSAppInputDrainScheduled = YES;
            scheduleDrain = YES;
        }
    }
    [data release];
    if (scheduleDrain) MacWSScheduleAppInputDrain();
}

// macwsinputd's launchd session has no CoreGraphics window list.  A target
// probe performs only a read-only AppKit hit test in each application; the
// broker sends the real input record to exactly one selected PID afterward.
// +[NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:] applies the
// WindowServer's front-to-back mouse-down rules and may return a window owned
// by another application.  Comparing that number with the process-local
// orderedWindows candidate prevents overlapping apps that both incorrectly
// report isActive=YES in the chroot from both claiming the same point.
// Keeping this on the main thread is required because orderedWindows and
// keyWindow are AppKit state, not socket-thread APIs.
static void MacWSReplyToTargetProbeOnMainThread(
        MacWSInputTargetProbe probe) {
    MacWSInputTargetReply reply = {
        .magic = MACWS_TARGET_REPLY_MAGIC,
        .version = MACWS_TARGET_VERSION,
        .size = sizeof(MacWSInputTargetReply),
        .nonce = probe.nonce,
        .pid = getpid(),
    };
    Class applicationClass = objc_getClass("NSApplication");
    Class screenClass = objc_getClass("NSScreen");
    Class windowClass = objc_getClass("NSWindow");
    id application = applicationClass
        ? ((MacWSMsgID)objc_msgSend)((id)applicationClass,
                                    sel_registerName("sharedApplication"))
        : nil;
    id screen = screenClass
        ? ((MacWSMsgID)objc_msgSend)((id)screenClass,
                                    sel_registerName("mainScreen"))
        : nil;
    id hitWindow = nil;
    CGRect hitWindowFrame = {{0.0, 0.0}, {0.0, 0.0}};
    NSInteger globalWindowNumber = 0;
    BOOL menuSurface = NO;
    id keyWindow = application
        ? ((MacWSMsgID)objc_msgSend)(application,
                                    sel_registerName("keyWindow"))
        : nil;
    if (application && screen && probe.frameWidth != 0 &&
        probe.frameHeight != 0) {
        CGRect screenFrame = ((MacWSMsgRect)objc_msgSend)(
            screen, sel_registerName("frame"));
        CGPoint screenPoint = {
            screenFrame.origin.x +
                (probe.x / (CGFloat)probe.frameWidth) *
                    screenFrame.size.width,
            screenFrame.origin.y +
                (1.0 - probe.y / (CGFloat)probe.frameHeight) *
                    screenFrame.size.height,
        };
        SEL globalHitSelector = sel_registerName(
            "windowNumberAtPoint:belowWindowWithWindowNumber:");
        if (windowClass && class_respondsToSelector(
                object_getClass(windowClass), globalHitSelector)) {
            globalWindowNumber = ((MacWSMsgIntegerPointInteger)objc_msgSend)(
                (id)windowClass, globalHitSelector, screenPoint, 0);
        }
        SEL applicationWindowSelector =
            sel_registerName("windowWithWindowNumber:");
        if (globalWindowNumber > 0 && ((MacWSMsgBoolSEL)objc_msgSend)(
                application, sel_registerName("respondsToSelector:"),
                applicationWindowSelector)) {
            hitWindow = ((MacWSMsgIDInteger)objc_msgSend)(
                application, applicationWindowSelector,
                globalWindowNumber);
            if (hitWindow) {
                hitWindowFrame = ((MacWSMsgRect)objc_msgSend)(
                    hitWindow, sel_registerName("frame"));
            }
        }
        id windows = ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("orderedWindows"));
        NSUInteger count = [windows count];
        for (NSUInteger index = 0; !hitWindow && index < count; index++) {
            id candidate = [windows objectAtIndex:index];
            BOOL visible = ((MacWSMsgBool)objc_msgSend)(
                candidate, sel_registerName("isVisible"));
            CGRect frame = ((MacWSMsgRect)objc_msgSend)(
                candidate, sel_registerName("frame"));
            if (visible && MacWSPointInRect(screenPoint, frame)) {
                hitWindow = candidate;
                hitWindowFrame = frame;
                break;
            }
        }
        NSInteger contextWindowNumber = hitWindow
            ? ((MacWSMsgInteger)objc_msgSend)(
                hitWindow, sel_registerName("windowNumber")) : 0;
        CGPoint contextWindowPoint = hitWindow
            ? ((MacWSMsgPointPoint)objc_msgSend)(
                hitWindow, sel_registerName("convertPointFromScreen:"),
                screenPoint) : screenPoint;
        Class eventClass = objc_getClass("NSEvent");
        // Runtime probes identify both the menu-bar root menu and Terminal's
        // contextual menu as NSMenuWindowManagerWindow. Use AppKit's exact
        // class relationship instead of a broad class-name substring so an
        // unrelated panel with "Menu" in its private class name cannot acquire
        // the privileged Escape/dismiss route.
        Class menuWindowClass = objc_getClass("NSMenuWindowManagerWindow");
        menuSurface = hitWindow && menuWindowClass &&
            ((MacWSMsgBoolID)objc_msgSend)(
                hitWindow, sel_registerName("isKindOfClass:"),
                (id)menuWindowClass);
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        MacWSCacheMenuContextLocked(application, eventClass,
            contextWindowNumber, screenFrame, screenPoint,
            contextWindowPoint, menuSurface);
        pthread_mutex_unlock(&MacWSAppInputRouteLock);
    }
    if (hitWindow) {
        NSInteger localWindowNumber = ((MacWSMsgInteger)objc_msgSend)(
            hitWindow, sel_registerName("windowNumber"));
        reply.windowNumber = (int32_t)localWindowNumber;
        // A nonpositive global result means the API was unavailable or the
        // WindowServer found no hittable window; retain the old local test as
        // a compatibility fallback.  A positive result is authoritative.
        if (globalWindowNumber <= 0 ||
            localWindowNumber == globalWindowNumber) {
            reply.flags |= MacWSInputTargetHit;
            if (hitWindow == keyWindow)
                reply.flags |= MacWSInputTargetKeyWindow;
        }
    }
    if (application && ((MacWSMsgBool)objc_msgSend)(
            application, sel_registerName("isActive"))) {
        reply.flags |= MacWSInputTargetApplicationActive;
    }
    if (application &&
        MacWSCaptureFrontUISnapshot().ownsFrontUIProcess) {
        reply.flags |= MacWSInputTargetFrontUIProcess;
    }

    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    ssize_t sent = -1;
    int savedError = 0;
    if (socketFD >= 0) {
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, MacWSInputTargetReplyPath,
                sizeof(address.sun_path));
        sent = sendto(socketFD, &reply, sizeof(reply), MSG_DONTWAIT,
                      (const struct sockaddr *)&address, sizeof(address));
        if (sent != (ssize_t)sizeof(reply)) savedError = errno;
        close(socketFD);
    } else {
        savedError = errno;
    }
    static unsigned probeLogs;
    if (MacWSRuntimeDiagnosticsEnabled() && probeLogs++ < 24) {
        fprintf(stderr,
                "#### APP-INPUT TARGET-REPLY pid=%d nonce=%llu "
                "window=%d global=%ld flags=%#x "
                "class=%s menu-surface=%s frame=(%.1f,%.1f %.1fx%.1f) "
                "sent=%zd errno=%d\n",
                getpid(), (unsigned long long)probe.nonce,
                reply.windowNumber, (long)globalWindowNumber, reply.flags,
                hitWindow ? object_getClassName(hitWindow) : "nil",
                menuSurface ? "YES" : "NO",
                hitWindowFrame.origin.x, hitWindowFrame.origin.y,
                hitWindowFrame.size.width, hitWindowFrame.size.height, sent,
                sent == (ssize_t)sizeof(reply) ? 0 : savedError);
        fflush(stderr);
    }
}

static void MacWSScheduleTargetProbeReply(MacWSInputTargetProbe probe) {
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, ^{
        @autoreleasepool {
            MacWSReplyToTargetProbeOnMainThread(probe);
        }
    });
    CFRunLoopWakeUp(mainRunLoop);
}

static MacWSMenuResponseHeader MacWSMenuResponseHeaderMake(
    const MacWSMenuRequest *request, MacWSMenuStatus status,
    uint64_t generation) {
    return (MacWSMenuResponseHeader){
        .magic = MACWS_MENU_MAGIC,
        .version = MACWS_MENU_VERSION,
        .size = sizeof(MacWSMenuResponseHeader),
        .status = status,
        .nonce = request->nonce,
        .ownerPID = getpid(),
        .windowID = request->windowID,
        .generation = generation ? generation : 1,
        .totalBytes = sizeof(MacWSMenuResponseHeader),
    };
}

static void MacWSMenuAppendString(NSMutableData *strings, NSString *value,
                                  uint32_t *offsetOut,
                                  uint32_t *lengthOut) {
    if (offsetOut) *offsetOut = (uint32_t)strings.length;
    if (lengthOut) *lengthOut = 0;
    if (![value isKindOfClass:[NSString class]] || value.length == 0 ||
        strings.length >= MACWS_MENU_MAX_STRING_BYTES) return;

    NSString *bounded = value;
    NSData *encoded = [bounded dataUsingEncoding:NSUTF8StringEncoding];
    while (encoded.length > MACWS_MENU_MAX_ITEM_STRING_BYTES &&
           bounded.length > 0) {
        NSRange last = [bounded rangeOfComposedCharacterSequenceAtIndex:
            bounded.length - 1];
        bounded = [bounded substringToIndex:last.location];
        encoded = [bounded dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSUInteger available = MACWS_MENU_MAX_STRING_BYTES - strings.length;
    if (!encoded || encoded.length > available || encoded.length > UINT32_MAX)
        return;
    if (offsetOut) *offsetOut = (uint32_t)strings.length;
    if (lengthOut) *lengthOut = (uint32_t)encoded.length;
    [strings appendData:encoded];
}

static NSString *MacWSMenuShortcutForItem(id item) {
    id key = ((MacWSMsgID)objc_msgSend)(
        item, sel_registerName("keyEquivalent"));
    if (![key isKindOfClass:objc_getClass("NSString")] || [key length] == 0)
        return MacWSRuntimeString("");
    NSUInteger modifiers = ((MacWSMsgUInteger)objc_msgSend)(
        item, sel_registerName("keyEquivalentModifierMask"));
    NSMutableString *shortcut = [NSMutableString string];
    if (modifiers & (1u << 18))
        [shortcut appendString:MacWSRuntimeString("⌃")];
    if (modifiers & (1u << 19))
        [shortcut appendString:MacWSRuntimeString("⌥")];
    if (modifiers & (1u << 17))
        [shortcut appendString:MacWSRuntimeString("⇧")];
    if (modifiers & (1u << 20))
        [shortcut appendString:MacWSRuntimeString("⌘")];
    [shortcut appendString:[key uppercaseString]];
    return shortcut;
}

static BOOL MacWSMenuItemIsStandardApplicationQuit(
        id item, NSUInteger depth, NSString *title, NSString *shortcut,
        BOOL separator, BOOL hidden, id submenu, id customView) {
    if (!item || depth != 1 || separator || hidden || submenu || customView ||
        ![title isKindOfClass:objc_getClass("NSString")] ||
        ![shortcut isEqualToString:MacWSRuntimeString("⌘Q")]) return NO;
    // Most AppKit applications use terminate:. Catalyst Maps publishes the
    // standard item disabled, and its synthesized item may omit the action;
    // retain the exact Ventura English title as the second canonical witness.
    // Depth one + Command-Q prevents an arbitrary document-menu shortcut from
    // acquiring process-lifecycle semantics.
    SEL action = ((SEL (*)(id, SEL))objc_msgSend)(
        item, sel_registerName("action"));
    return (action && strcmp(sel_getName(action), "terminate:") == 0) ||
        [title hasPrefix:MacWSRuntimeString("Quit ")];
}

static BOOL MacWSMenuAppendTree(id menu, uint64_t parentItemID,
                                NSUInteger depth, NSArray *parentPath,
                                NSMutableData *nodes, NSMutableData *strings,
                                NSMutableArray *items,
                                NSMutableArray *paths) {
    if (!menu || depth >= MACWS_MENU_MAX_DEPTH) return YES;
    SEL updateSelector = sel_registerName("update");
    if (((MacWSMsgBoolSEL)objc_msgSend)(
            menu, sel_registerName("respondsToSelector:"), updateSelector))
        ((MacWSMsgVoid)objc_msgSend)(menu, updateSelector);
    id itemArray = ((MacWSMsgID)objc_msgSend)(
        menu, sel_registerName("itemArray"));
    if (![itemArray isKindOfClass:objc_getClass("NSArray")]) return NO;

    NSUInteger count = [itemArray count];
    for (NSUInteger index = 0; index < count; index++) {
        if (nodes.length / sizeof(MacWSMenuNode) >= MACWS_MENU_MAX_NODES)
            return YES;
        id item = [itemArray objectAtIndex:index];
        if (!item) continue;
        uint64_t itemID = nodes.length / sizeof(MacWSMenuNode) + 1;
        NSMutableArray *path = [NSMutableArray arrayWithArray:
            parentPath ?: [NSArray array]];
        [path addObject:@(index)];
        [items addObject:item];
        [paths addObject:path];

        BOOL separator = ((MacWSMsgBool)objc_msgSend)(
            item, sel_registerName("isSeparatorItem"));
        BOOL enabled = ((MacWSMsgBool)objc_msgSend)(
            item, sel_registerName("isEnabled"));
        BOOL hidden = ((MacWSMsgBool)objc_msgSend)(
            item, sel_registerName("isHidden"));
        BOOL alternate = ((MacWSMsgBool)objc_msgSend)(
            item, sel_registerName("isAlternate"));
        id submenu = ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("submenu"));
        id customView = ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("view"));
        NSInteger state = ((MacWSMsgInteger)objc_msgSend)(
            item, sel_registerName("state"));
        NSString *title = ((MacWSMsgID)objc_msgSend)(
            item, sel_registerName("title"));
        // AppKit's placeholder first root can remain literally
        // "Application" in NSApplication.mainMenu even though the native
        // macOS menu bar presents the bundle's CFBundleName.  The target's
        // Word window showed exactly that split (macPad: Application,
        // WindowServer: Word), and Word's Info.plist declares
        // CFBundleName=Word.  Mirror the real displayed title in the
        // serialized menu without replacing or mutating the NSMenuItem;
        // its identity and index path remain valid for action dispatch.
        if (depth == 0 && index == 0 && submenu &&
            [title isEqualToString:MacWSRuntimeString("Application")]) {
            id bundle = ((MacWSMsgID)objc_msgSend)(
                (id)objc_getClass("NSBundle"),
                sel_registerName("mainBundle"));
            id bundleName = bundle ? ((MacWSMsgIDID)objc_msgSend)(
                bundle, sel_registerName("objectForInfoDictionaryKey:"),
                MacWSRuntimeString("CFBundleName")) : nil;
            if ([bundleName isKindOfClass:objc_getClass("NSString")] &&
                [bundleName length] > 0)
                title = bundleName;
        }
        NSString *shortcut = MacWSMenuShortcutForItem(item);
        BOOL bridgedQuit = MacWSMenuItemIsStandardApplicationQuit(
            item, depth, title, shortcut, separator, hidden, submenu,
            customView);
        MacWSMenuNode node = {
            .itemID = itemID,
            .parentItemID = parentItemID,
            .siblingIndex = (uint32_t)index,
            .flags = (separator ? MacWSMenuNodeSeparator : 0) |
                (enabled ? MacWSMenuNodeEnabled : 0) |
                (hidden ? MacWSMenuNodeHidden : 0) |
                (submenu ? MacWSMenuNodeHasSubmenu : 0) |
                (state == 1 ? MacWSMenuNodeChecked : 0) |
                (state == -1 ? MacWSMenuNodeMixed : 0) |
                (alternate ? MacWSMenuNodeAlternate : 0) |
                (customView ? MacWSMenuNodeRequiresWorkspace : 0) |
                (bridgedQuit ? MacWSMenuNodeBridgedQuit : 0),
            .state = (int32_t)state,
        };
        uint32_t titleOffset = 0;
        uint32_t titleLength = 0;
        uint32_t shortcutOffset = 0;
        uint32_t shortcutLength = 0;
        MacWSMenuAppendString(strings, title, &titleOffset, &titleLength);
        MacWSMenuAppendString(strings, shortcut,
                              &shortcutOffset, &shortcutLength);
        node.titleOffset = titleOffset;
        node.titleLength = titleLength;
        node.shortcutOffset = shortcutOffset;
        node.shortcutLength = shortcutLength;
        [nodes appendBytes:&node length:sizeof(node)];
        if (submenu && !MacWSMenuAppendTree(submenu, itemID, depth + 1,
                                            path, nodes, strings,
                                            items, paths)) return NO;
    }
    return YES;
}

static id MacWSMenuItemAtPath(id mainMenu, NSArray *path) {
    id menu = mainMenu;
    id item = nil;
    for (NSNumber *component in path) {
        SEL updateSelector = sel_registerName("update");
        if (((MacWSMsgBoolSEL)objc_msgSend)(
                menu, sel_registerName("respondsToSelector:"),
                updateSelector))
            ((MacWSMsgVoid)objc_msgSend)(menu, updateSelector);
        id array = ((MacWSMsgID)objc_msgSend)(
            menu, sel_registerName("itemArray"));
        NSUInteger index = component.unsignedIntegerValue;
        if (![array isKindOfClass:objc_getClass("NSArray")] ||
            index >= [array count])
            return nil;
        item = [array objectAtIndex:index];
        menu = ((MacWSMsgID)objc_msgSend)(item, sel_registerName("submenu"));
    }
    return item;
}

static NSData *MacWSMenuSnapshotOnMainThread(
    const MacWSMenuRequest *request) {
    uint64_t generation = ++MacWSMenuNextGeneration;
    if (generation == 0) generation = ++MacWSMenuNextGeneration;
    MacWSMenuResponseHeader header = MacWSMenuResponseHeaderMake(
        request, MacWSMenuStatusTargetUnavailable, generation);
    Class applicationClass = objc_getClass("NSApplication");
    id application = applicationClass ? ((MacWSMsgID)objc_msgSend)(
        applicationClass, sel_registerName("sharedApplication")) : nil;
    id window = application
        ? MacWSWindowWithNumber(application, request->windowID) : nil;
    id mainMenu = application ? ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("mainMenu")) : nil;
    if (!window || !mainMenu) return [NSData dataWithBytes:&header
                                                    length:sizeof(header)];

    id appearance = ((MacWSMsgID)objc_msgSend)(
        window, sel_registerName("effectiveAppearance"));
    if (appearance) {
        NSArray *candidates = [NSArray arrayWithObjects:
            MacWSRuntimeString("NSAppearanceNameAqua"),
            MacWSRuntimeString("NSAppearanceNameDarkAqua"), nil];
        id match = ((MacWSMsgIDID)objc_msgSend)(appearance,
            sel_registerName("bestMatchFromAppearancesWithNames:"),
            candidates);
        if ([match isEqual:MacWSRuntimeString("NSAppearanceNameDarkAqua")])
            header.appearance = MacWSMenuAppearanceDark;
        else if ([match isEqual:MacWSRuntimeString("NSAppearanceNameAqua")])
            header.appearance = MacWSMenuAppearanceLight;
    }

    // A snapshot is a read-only query.  In particular, never order or key the
    // requested window here: NSWindowStackController can be in the middle of
    // committing a Terminal tab-group transition while displayd asks for a
    // menu refresh.  Runtime evidence from Terminal showed this former
    // makeKeyAndOrderFront: call re-entering
    // _doTabbedWindowOrderInWithWasVisible: and terminating on the AppKit
    // "expected no items" invariant.  Explicit Host interaction activates
    // the represented window before an action; passive refreshes must not
    // mutate the application's window graph.
    NSMutableData *nodes = [NSMutableData data];
    NSMutableData *strings = [NSMutableData data];
    NSMutableArray *items = [NSMutableArray array];
    NSMutableArray *paths = [NSMutableArray array];
    BOOL built = MacWSMenuAppendTree(mainMenu, 0, 0, [NSArray array],
                                     nodes, strings,
                                     items, paths);
    NSUInteger total = sizeof(header) + nodes.length + strings.length;
    if (!built || items.count == 0 || total > MACWS_MENU_MAX_TOTAL_BYTES) {
        header.status = MacWSMenuStatusInternalError;
        return [NSData dataWithBytes:&header length:sizeof(header)];
    }

    if (!MacWSMenuCaches) MacWSMenuCaches = [NSMutableDictionary new];
    NSArray *itemsCopy = [items copy];
    NSArray *pathsCopy = [paths copy];
    NSDictionary *cache = [NSDictionary dictionaryWithObjectsAndKeys:
        itemsCopy, MacWSRuntimeString("items"),
        pathsCopy, MacWSRuntimeString("paths"),
        @(request->windowID), MacWSRuntimeString("window"), nil];
    [itemsCopy release];
    [pathsCopy release];
    MacWSMenuCaches[@(generation)] = cache;
    if (MacWSMenuCaches.count > 8) {
        NSArray *ordered = [MacWSMenuCaches.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
        [MacWSMenuCaches removeObjectForKey:ordered.firstObject];
    }

    header.status = MacWSMenuStatusOK;
    header.nodeCount = (uint32_t)items.count;
    header.stringBytes = (uint32_t)strings.length;
    header.totalBytes = (uint32_t)total;
    NSMutableData *response = [NSMutableData dataWithBytes:&header
                                                     length:sizeof(header)];
    [response appendData:nodes];
    [response appendData:strings];
    return response;
}

static NSData *MacWSMenuActionOnMainThread(
    const MacWSMenuRequest *request, BOOL perform) {
    MacWSMenuStatus status = MacWSMenuStatusStaleGeneration;
    NSDictionary *cache = MacWSMenuCaches[@(request->generation)];
    NSArray *cachedItems = [cache objectForKey:MacWSRuntimeString("items")];
    NSArray *cachedPaths = [cache objectForKey:MacWSRuntimeString("paths")];
    if ([[cache objectForKey:MacWSRuntimeString("window")] unsignedIntValue] ==
            request->windowID &&
        request->itemID > 0 &&
        request->itemID <= cachedItems.count) {
        Class applicationClass = objc_getClass("NSApplication");
        id application = applicationClass ? ((MacWSMsgID)objc_msgSend)(
            applicationClass, sel_registerName("sharedApplication")) : nil;
        id window = application ? MacWSWindowWithNumber(
            application, request->windowID) : nil;
        id mainMenu = application ? ((MacWSMsgID)objc_msgSend)(
            application, sel_registerName("mainMenu")) : nil;
        id cached = [cachedItems objectAtIndex:request->itemID - 1];
        NSArray *path = [cachedPaths objectAtIndex:request->itemID - 1];
        id current = mainMenu ? MacWSMenuItemAtPath(mainMenu, path) : nil;
        if (!window || !current || current != cached) {
            status = MacWSMenuStatusTargetUnavailable;
        } else if (((MacWSMsgBool)objc_msgSend)(
                       current, sel_registerName("isHidden")) ||
                   !((MacWSMsgBool)objc_msgSend)(
                       current, sel_registerName("isEnabled"))) {
            status = MacWSMenuStatusDisabled;
        } else if (((MacWSMsgID)objc_msgSend)(
                       current, sel_registerName("submenu")) ||
                   ((MacWSMsgID)objc_msgSend)(
                       current, sel_registerName("view"))) {
            status = MacWSMenuStatusUnsupported;
        } else {
            SEL action = ((SEL (*)(id, SEL))objc_msgSend)(
                current, sel_registerName("action"));
            if (!action) {
                status = MacWSMenuStatusUnsupported;
            } else if (!perform) {
                // The socket thread sends this acknowledgement before asking
                // the main queue to execute the already validated action. A
                // terminating action such as Quit can therefore destroy the
                // process without also destroying its only success reply.
                status = MacWSMenuStatusOK;
            } else {
                // Action execution is also deliberately free of window-order
                // mutations.  The Host emits ActivateTarget as the explicit
                // user intent before arriving here.  Reordering from inside
                // a menu transaction can re-enter AppKit's tab controller,
                // which is the exact failure the snapshot path used to cause.
                MacWSInstallWorkspaceOpenWitness();
                id target = ((MacWSMsgID)objc_msgSend)(
                    current, sel_registerName("target"));
                status = ((MacWSMsgBoolSELIDID)objc_msgSend)(application,
                    sel_registerName("sendAction:to:from:"), action, target,
                    current) ? MacWSMenuStatusOK
                             : MacWSMenuStatusUnsupported;
            }
        }
    }
    MacWSMenuResponseHeader header = MacWSMenuResponseHeaderMake(
        request, status, request->generation);
    return [NSData dataWithBytes:&header length:sizeof(header)];
}

static void MacWSHandleMenuRequest(const MacWSMenuRequest *request,
                                   const struct sockaddr_un *replyAddress,
                                   socklen_t replyAddressLength) {
    if (!replyAddress || replyAddressLength == 0 ||
        request->ownerPID != getpid()) return;
    __block NSData *response = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSData *generated = request->operation == MacWSMenuOperationSnapshot
                ? MacWSMenuSnapshotOnMainThread(request)
                : MacWSMenuActionOnMainThread(request, NO);
            response = [generated retain];
        }
    });
    if (!response) return;

    MacWSMenuResponseHeader replyHeader = *(const MacWSMenuResponseHeader *)
        response.bytes;
    if (request->operation == MacWSMenuOperationSnapshot &&
        replyHeader.status == MacWSMenuStatusOK) {
        NSString *path = [NSString stringWithFormat:MacWSRuntimeString(
            "/private/tmp/macws_menu_snapshot.%d.%016llx.bin"), getpid(),
            (unsigned long long)request->nonce];
        NSError *error = nil;
        if (![response writeToFile:path options:NSDataWritingAtomic
                             error:&error]) {
            replyHeader.status = MacWSMenuStatusInternalError;
        } else {
            chmod(path.fileSystemRepresentation, 0600);
        }
        // The datagram is an acknowledgement; the bounded snapshot lives in
        // the atomic sidecar and is consumed/unlinked by macwsdisplayd.
        replyHeader.nodeCount = 0;
        replyHeader.stringBytes = 0;
        replyHeader.totalBytes = sizeof(replyHeader);
    }
    // The Host and diagnostic clients run outside the chroot and bind their
    // reply socket through /var/mnt/rootfs/private/tmp. recvfrom preserves
    // that literal pathname, but the application resolves a sendto pathname
    // inside the chroot where the same inode is /private/tmp/.... Runtime
    // witness: Terminal produced APP-MENU status=1 and the complete sidecar,
    // while the client timed out and the source socket remained untouched.
    // Translate only this exact mount prefix before replying; do not weaken
    // the request's PID/window validation or synthesize an acknowledgement.
    struct sockaddr_un replyTarget = *replyAddress;
    socklen_t replyTargetLength = replyAddressLength;
    static const char rootMountPrefix[] = "/var/mnt/rootfs";
    size_t rootMountLength = sizeof(rootMountPrefix) - 1;
    size_t sourcePathLength = strnlen(replyTarget.sun_path,
        sizeof(replyTarget.sun_path));
    if (sourcePathLength > rootMountLength &&
        memcmp(replyTarget.sun_path, rootMountPrefix,
               rootMountLength) == 0 &&
        replyTarget.sun_path[rootMountLength] == '/') {
        size_t translatedLength = sourcePathLength - rootMountLength;
        memmove(replyTarget.sun_path,
                replyTarget.sun_path + rootMountLength,
                translatedLength + 1);
        replyTargetLength = (socklen_t)(
            offsetof(struct sockaddr_un, sun_path) + translatedLength + 1);
    }
    ssize_t replyBytes = sendto(
        MacWSAppInputSocket, &replyHeader, sizeof(replyHeader), 0,
        (const struct sockaddr *)&replyTarget, replyTargetLength);
    if (replyBytes != sizeof(replyHeader)) {
        fprintf(stderr,
            "#### APP-MENU REPLY-FAIL pid=%d op=%u path=%s errno=%d\n",
            getpid(), request->operation, replyTarget.sun_path, errno);
        fflush(stderr);
    }
    if (request->operation == MacWSMenuOperationAction &&
        replyHeader.status == MacWSMenuStatusOK) {
        MacWSMenuRequest accepted = *request;
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                NSData *result = MacWSMenuActionOnMainThread(&accepted, YES);
                if (MacWSRuntimeDiagnosticsEnabled()) {
                    const MacWSMenuResponseHeader *header = result.bytes;
                    fprintf(stderr,
                        "#### APP-MENU ACTION-DISPATCH pid=%d window=%u "
                        "generation=%llu item=%llu status=%u\n",
                        getpid(), accepted.windowID,
                        (unsigned long long)accepted.generation,
                        (unsigned long long)accepted.itemID,
                        header ? header->status : 0);
                    fflush(stderr);
                }
            }
        });
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-MENU op=%u pid=%d window=%u generation=%llu "
            "status=%u nodes=%u\n",
            request->operation, getpid(), request->windowID,
            (unsigned long long)replyHeader.generation, replyHeader.status,
            ((const MacWSMenuResponseHeader *)response.bytes)->nodeCount);
        fflush(stderr);
    }
    [response release];
}

static void *MacWSAppInputThread(void *unused) {
    (void)unused;
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr, "#### APP-INPUT THREAD pid=%d socket=%d\n",
                getpid(), MacWSAppInputSocket);
        fflush(stderr);
    }
    while (MacWSAppInputSocket >= 0) {
        union {
            MacWSInputRecord record;
            MacWSInputTargetProbe probe;
            MacWSMenuRequest menu;
        } message = {0};
        struct sockaddr_un sourceAddress = {0};
        socklen_t sourceAddressLength = sizeof(sourceAddress);
        ssize_t count = recvfrom(MacWSAppInputSocket, &message,
                                 sizeof(message), 0,
                                 (struct sockaddr *)&sourceAddress,
                                 &sourceAddressLength);
        if (count < 0) {
            if (errno == EINTR) continue;
            break;
        }
        // Dock deliberately has no AppKit objects. Its only accepted payload
        // is a broker-revalidated system-surface input record; probes and menu
        // requests remain owned by the ordinary AppKit endpoints.
        if (MacWSAppInputIsDockEndpoint()) {
            MacWSInputRecord record = message.record;
            BOOL valid = count == sizeof(record) &&
                MacWSInputRecordIsValid(&record);
            BOOL posted = valid && MacWSPostDockSystemInput(record);
            if ((MacWSRuntimeDiagnosticsEnabled() ||
                 record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC) &&
                record.kind != MacWSInputKindTouchMove &&
                record.kind != MacWSInputKindHover &&
                record.kind != MacWSInputKindMenuHover &&
                (record.kind != MacWSInputKindSystemGesture ||
                 (record.flags & MacWSInputFlagGestureChanged) == 0)) {
                fprintf(stderr,
                    "#### APP-INPUT DOCK-RX pid=%d bytes=%zd kind=%u "
                    "target=%d flags=%#x valid=%s posted=%s\n",
                    getpid(), count, record.kind, record.targetPID,
                    record.flags, valid ? "YES" : "NO",
                    posted ? "YES" : "NO");
                fflush(stderr);
            }
            continue;
        }
        if (count == sizeof(MacWSInputTargetProbe) &&
            message.probe.magic == MACWS_TARGET_PROBE_MAGIC &&
            message.probe.version == MACWS_TARGET_VERSION &&
            message.probe.size == sizeof(MacWSInputTargetProbe) &&
            isfinite(message.probe.x) && isfinite(message.probe.y) &&
            message.probe.frameWidth != 0 &&
            message.probe.frameHeight != 0) {
            MacWSScheduleTargetProbeReply(message.probe);
            continue;
        }
        if (count == sizeof(MacWSMenuRequest) &&
            MacWSMenuRequestIsValid(&message.menu, sizeof(message.menu))) {
            MacWSHandleMenuRequest(&message.menu, &sourceAddress,
                                   sourceAddressLength);
            continue;
        }
        MacWSInputRecord record = message.record;
        if (MacWSRuntimeDiagnosticsEnabled() &&
            record.kind != MacWSInputKindTouchMove &&
            record.kind != MacWSInputKindHover &&
            record.kind != MacWSInputKindMenuHover &&
            record.kind != MacWSInputKindRelativePointer) {
            fprintf(stderr,
                    "#### APP-INPUT RX pid=%d bytes=%zd kind=%u target=%d "
                    "flags=%#x contact=%u\n",
                    getpid(), count, record.kind, record.targetPID,
                    record.flags, record.contactID);
            fflush(stderr);
        }
        if (count != sizeof(record) || !MacWSInputRecordIsValid(&record)) {
            fprintf(stderr,
                    "#### APP-INPUT REJECT pid=%d bytes=%zd magic=%#x version=%u target=%d\n",
                    getpid(), count, record.magic, record.version,
                    record.targetPID);
            fflush(stderr);
            continue;
        }
        if (MacWSKeyboardLatencyDiagnosticsEnabled() &&
            (record.flags & MacWSInputFlagLatencyDiagnostic) &&
            (record.kind == MacWSInputKindKeyDown ||
             record.kind == MacWSInputKindKeyUp)) {
            double now = MacWSInputUptimeSeconds();
            MacWSKeyboardLatencyTrace(
                "stage=app-socket pid=%d sample=%u kind=%u keycode=%u "
                "producer-to-socket=%.3fms\n",
                getpid(), record.sampleSequence, record.kind,
                (unsigned)llround(record.pressure),
                record.timestamp > 0.0 && now >= record.timestamp
                    ? (now - record.timestamp) * 1000.0 : -1.0);
        }
        if (record.flags & MacWSInputFlagLatencyDiagnostic) {
            double transportUS = fmax(
                0.0, (MacWSInputUptimeSeconds() - record.timestamp) * 1.0e6);
            record.reserved = (uint32_t)fmin(transportUS, UINT32_MAX);
        }
        // A semantic quit can arrive while an application is inside an
        // application-modal panel loop. Runtime evidence from Maps' first-run
        // What's New panel showed that a CFRunLoopPerformBlock token queued in
        // the background thread's snapshot of the main-loop mode remained
        // pending indefinitely: RX completed, but the unconditional
        // PERFORM-QUIT main-thread witness never appeared. libdispatch's main
        // queue is serviced by AppKit in that nested loop (and is already the
        // proven route for accepted menu actions), so deliver this one
        // application-scoped control command there directly. Do not also put
        // it in the input FIFO; pointer/key ordering is irrelevant once the
        // user has requested application termination, and duplicate delivery
        // could run termination delegates twice.
        if (record.kind == MacWSInputKindPerformQuit) {
            CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
            __block BOOL delivered = NO;
            void (^deliverOnce)(void) = ^{
                if (delivered) return;
                delivered = YES;
                @autoreleasepool {
                    MacWSPostInputOnMainThread(record);
                }
            };
            dispatch_async(dispatch_get_main_queue(), deliverOnce);
            // NSApplication's application-modal and native event-tracking
            // loops are deliberately not members of the default/common mode
            // sets on every macOS release. Register the same guarded block in
            // those documented AppKit modes. Every copy executes on the main
            // thread and shares delivered, so at most one lifecycle request
            // reaches the application even if several modes subsequently run.
            if (mainRunLoop) {
                CFStringRef activeMode =
                    CFRunLoopCopyCurrentMode(mainRunLoop);
                if (activeMode)
                    CFRunLoopPerformBlock(
                        mainRunLoop, activeMode, deliverOnce);
                CFRunLoopPerformBlock(
                    mainRunLoop, kCFRunLoopDefaultMode, deliverOnce);
                CFRunLoopPerformBlock(
                    mainRunLoop, kCFRunLoopCommonModes, deliverOnce);
                CFRunLoopPerformBlock(
                    mainRunLoop, CFSTR("NSModalPanelRunLoopMode"),
                    deliverOnce);
                CFRunLoopPerformBlock(
                    mainRunLoop, CFSTR("NSEventTrackingRunLoopMode"),
                    deliverOnce);
                if (activeMode) CFRelease(activeMode);
                CFRunLoopWakeUp(mainRunLoop);
            }
            continue;
        }
        // During a real NSControl tracking loop the main thread is synchronous
        // inside sendEvent(mouseDown), and that private tracker does not run
        // our CFRunLoop common-mode drain. NSApplication documents subthread
        // postEvent:atStart: as feeding the main event queue, so route live
        // move/up records there. The route lock makes this mutually exclusive
        // with the ordinary pending queue at the live-mode boundary.
        MacWSDirectTrackingSnapshot snapshot = {0};
        MacWSDirectGestureSnapshot gestureSnapshot = {0};
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        BOOL keyRecord = record.kind == MacWSInputKindKeyDown ||
                         record.kind == MacWSInputKindKeyUp;
        BOOL directMenuTap = MacWSPrepareDirectMenuTapPostLocked(
            record, &snapshot);
        BOOL directGesture = MacWSPrepareDirectGesturePostLocked(
            record, &gestureSnapshot);
        BOOL postedDirectly = directMenuTap || directGesture || (keyRecord
            ? MacWSPrepareDirectKeyPostLocked(record, &snapshot)
            : ((record.kind == MacWSInputKindMenuHover ||
                record.kind == MacWSInputKindHover)
                ? MacWSPrepareDirectMenuPostLocked(record, &snapshot)
                : MacWSPrepareDirectTrackingPostLocked(record, &snapshot)));
        if (!postedDirectly) MacWSEnqueueAppInputRecord(record);
        pthread_mutex_unlock(&MacWSAppInputRouteLock);
        if (directMenuTap) {
            MacWSPostDirectMenuTapRecord(record, snapshot);
        } else if (directGesture) {
            MacWSPostDirectGestureRecord(record, gestureSnapshot);
        } else if (postedDirectly && keyRecord) {
            BOOL posted = MacWSPostKeyRecord(
                record, (__bridge id)snapshot.application,
                snapshot.eventClass, snapshot.windowNumber, YES,
                snapshot.menuSurface);
            if (!posted) {
                fprintf(stderr,
                    "#### APP-INPUT KEY-DROP pid=%d kind=%u "
                    "keycode=%.3f keysym=%#x reason=event-create\n",
                    getpid(), record.kind, record.pressure, record.contactID);
                fflush(stderr);
            }
            if (snapshot.application) CFRelease(snapshot.application);
        } else if (postedDirectly) {
            MacWSPostDirectTrackingRecord(record, snapshot);
        }
    }
    return NULL;
}

// Runs on the application main thread. This reports the real AppKit
// constraints; macwsdisplayd must not invent a product-wide minimum width.
static char MacWSLogicalWindowGroupAssociationKey;

// AppKit sheets and application-modal panels are separate level-0 CGWindows
// on Ventura.  Treating every level-0 window as a user document made Maps'
// 482x600 What's New panel win over its 1024x768 map window and gave that
// panel its own iPadOS Scene.  Resolve the real presenting window first so
// the catalog can expose one logical window and displayd can composite the
// child as an IOSurface overlay.
static id MacWSPresentingWindow(id window, id application) {
    if (!window) return nil;
    const SEL parentSelectors[] = {
        sel_registerName("sheetParent"),
        sel_registerName("parentWindow"),
    };
    for (NSUInteger index = 0;
         index < sizeof(parentSelectors) / sizeof(parentSelectors[0]);
         index++) {
        SEL selector = parentSelectors[index];
        if (!((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"), selector))
            continue;
        id parent = ((MacWSMsgID)objc_msgSend)(window, selector);
        if (parent && parent != window) return parent;
    }
    SEL modalSelector = sel_registerName("modalWindow");
    SEL mainSelector = sel_registerName("mainWindow");
    if (application &&
        ((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            modalSelector) &&
        ((MacWSMsgID)objc_msgSend)(application, modalSelector) == window &&
        ((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            mainSelector)) {
        id mainWindow = ((MacWSMsgID)objc_msgSend)(application, mainSelector);
        if (mainWindow && mainWindow != window) return mainWindow;
    }
    // AppKit utility/inspector panels are not always attached with
    // parentWindow (Finder's Get Info window is a common example), but they
    // are still auxiliary UI of the application's main document. Preserve
    // that public AppKit classification so the panel is composited inside the
    // presenting MacPad Scene instead of becoming a separately scaled iOS
    // window.
    Class panelClass = objc_getClass("NSPanel");
    BOOL panel = panelClass && ((MacWSMsgBoolID)objc_msgSend)(
        window, sel_registerName("isKindOfClass:"), (id)panelClass);
    SEL excludedSelector = sel_registerName("isExcludedFromWindowsMenu");
    BOOL excluded = ((MacWSMsgBoolSEL)objc_msgSend)(
            window, sel_registerName("respondsToSelector:"), excludedSelector)
        ? ((MacWSMsgBool)objc_msgSend)(window, excludedSelector) : NO;
    if ((panel || excluded) && application &&
        ((MacWSMsgBoolSEL)objc_msgSend)(
            application, sel_registerName("respondsToSelector:"),
            mainSelector)) {
        id mainWindow = ((MacWSMsgID)objc_msgSend)(application, mainSelector);
        if (mainWindow && mainWindow != window) return mainWindow;
    }
    return nil;
}

static id MacWSRootPresentingWindow(id window, id application) {
    id current = window;
    for (NSUInteger depth = 0; depth < 16; depth++) {
        id parent = MacWSPresentingWindow(current, application);
        if (!parent || parent == current) break;
        current = parent;
    }
    return current;
}

static uint32_t MacWSLogicalWindowGroupID(id window, id application) {
    window = MacWSRootPresentingWindow(window, application);
    NSInteger ownNumber = ((MacWSMsgInteger)objc_msgSend)(
        window, sel_registerName("windowNumber"));
    if (ownNumber <= 0 || (uint64_t)ownNumber > UINT32_MAX) return 0;
    uint32_t groupID = (uint32_t)ownNumber;

    // Do not use NSWindow.tabGroup as a query. Runtime-confirmed on Ventura
    // 13.4 with 7DTD's UnityWindow: the public getter enters
    // -[NSWindow _tabGroup], creates an NSWindowStackController, then blocks
    // synchronously in IconServices while constructing its tab-bar item. The
    // metrics publisher must observe AppKit, never mutate it.  The private
    // getter below returns the already-installed controller (nil for a plain
    // window); its `windows` collection is the same membership needed for a
    // stable logical identity.
    SEL stackControllerSelector = sel_registerName("_windowStackController");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            window, sel_registerName("respondsToSelector:"),
            stackControllerSelector)) return groupID;
    id stackController = ((MacWSMsgID)objc_msgSend)(
        window, stackControllerSelector);
    if (!stackController) return groupID;
    SEL windowsSelector = sel_registerName("windows");
    if (!((MacWSMsgBoolSEL)objc_msgSend)(
            stackController, sel_registerName("respondsToSelector:"),
            windowsSelector)) return groupID;
    id groupWindows = ((MacWSMsgID)objc_msgSend)(
        stackController, windowsSelector);
    NSUInteger groupCount = [groupWindows count];

    // NSWindow.windowNumber is the capture identity, not the user's window
    // identity: selecting an AppKit tab changes the on-screen window number.
    // Retain one process-local integer on the real NSWindowTabGroup object so
    // it survives selection and closing the member that originally had the
    // smallest number.  Member associations carry the identity across a
    // native merge that replaces the tab-group object.
    id token = objc_getAssociatedObject(
        stackController, &MacWSLogicalWindowGroupAssociationKey);
    if (!token) {
        for (NSUInteger index = 0; index < groupCount && !token; index++) {
            token = objc_getAssociatedObject(
                [groupWindows objectAtIndex:index],
                &MacWSLogicalWindowGroupAssociationKey);
        }
    }
    // Closing the penultimate tab leaves a one-window NSWindowTabGroup. Keep
    // its established identity so a Scene following the closed member can
    // still resolve the survivor. A window that has never belonged to a tab
    // group has no token and continues to use its real window number.
    if (groupCount <= 1) {
        if (token) {
            uint32_t established = (uint32_t)((MacWSMsgUInteger)objc_msgSend)(
                token, sel_registerName("unsignedIntValue"));
            if (established != 0) return established;
        }
        return groupID;
    }
    for (NSUInteger index = 0; index < groupCount; index++) {
        id member = [groupWindows objectAtIndex:index];
        NSInteger memberNumber = ((MacWSMsgInteger)objc_msgSend)(
            member, sel_registerName("windowNumber"));
        if (memberNumber > 0 && (uint64_t)memberNumber <= UINT32_MAX &&
            (uint32_t)memberNumber < groupID)
            groupID = (uint32_t)memberNumber;
    }
    if (!token) {
        Class numberClass = objc_getClass("NSNumber");
        token = numberClass ? ((id (*)(id, SEL, unsigned int))objc_msgSend)(
            (id)numberClass, sel_registerName("numberWithUnsignedInt:"),
            groupID) : nil;
    } else {
        groupID = (uint32_t)((MacWSMsgUInteger)objc_msgSend)(
            token, sel_registerName("unsignedIntValue"));
    }
    if (token && groupID != 0) {
        objc_setAssociatedObject(stackController,
            &MacWSLogicalWindowGroupAssociationKey, token,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSUInteger index = 0; index < groupCount; index++) {
            objc_setAssociatedObject([groupWindows objectAtIndex:index],
                &MacWSLogicalWindowGroupAssociationKey, token,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return groupID;
}

static void MacWSSendDisplayInvalidation(const void *bytes, size_t size) {
    static int socketFD = -1;
    static struct sockaddr_un target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (socketFD >= 0) {
            int flags = fcntl(socketFD, F_GETFL, 0);
            if (flags >= 0) (void)fcntl(socketFD, F_SETFL,
                                        flags | O_NONBLOCK);
        }
        target.sun_family = AF_UNIX;
        strlcpy(target.sun_path, MACWS_STREAM_INVALIDATE_SOCKET_PATH,
                sizeof(target.sun_path));
    });
    if (socketFD < 0 || !bytes || size == 0) return;
    // A datagram is one atomic invalidation edge. The descriptor remains
    // valid across displayd restarts because sendto resolves the pathname for
    // every message; sharing it also removes socket/open/close work from
    // Dock's 60/120-Hz native gesture handler on its main thread.
    (void)sendto(socketFD, bytes, size, MSG_DONTWAIT,
                 (const struct sockaddr *)&target, sizeof(target));
}

static void MacWSNotifyDisplayCatalogChanged(uint8_t reason) {
    MacWSSendDisplayInvalidation(&reason, sizeof(reason));
}

static void MacWSNotifyDisplayGeometryChanged(uint32_t windowID, id window,
                                              CGRect appliedFrame) {
    if (windowID == 0 || !window || appliedFrame.size.width <= 0.0 ||
        appliedFrame.size.height <= 0.0) return;
    CGFloat scale = ((MacWSMsgDouble)objc_msgSend)(
        window, sel_registerName("backingScaleFactor"));
    if (!isfinite(scale) || scale <= 0.0 || scale > 8.0) return;
    uint64_t pixelWidth = (uint64_t)llround(appliedFrame.size.width * scale);
    uint64_t pixelHeight = (uint64_t)llround(appliedFrame.size.height * scale);
    if (pixelWidth == 0 || pixelHeight == 0 ||
        pixelWidth > MACWS_STREAM_MAX_DIMENSION ||
        pixelHeight > MACWS_STREAM_MAX_DIMENSION) return;
    MacWSGeometryInvalidation record = {
        .magic = MACWS_GEOMETRY_INVALIDATION_MAGIC,
        .version = MACWS_GEOMETRY_INVALIDATION_VERSION,
        .size = sizeof(record),
        .windowID = windowID,
        .pixelWidth = (uint32_t)pixelWidth,
        .pixelHeight = (uint32_t)pixelHeight,
    };
    MacWSSendDisplayInvalidation(&record, sizeof(record));
}

// Do not use NSNotificationCenter's block observer API from this injected
// arm64e image.  LLDB runtime evidence on 2026-08-06 captured CFRelease trying
// to authenticate the isa at libmachook's __block_literal_global.368 while
// dispatching NSWindow frame-change notifications.  The literal's cross-image
// block isa had an incompatible PAC discriminator, so a perfectly ordinary
// window zoom terminated the application in _CFXNotificationDisposalListRelease.
// A selector observer has the identical notification semantics while its
// lifetime and dispatch use a normal Objective-C instance/method pair. Build
// that tiny class through the runtime as well: introducing new static ObjC
// class metadata from this injected cross-platform arm64e image is itself not
// safe before libobjc has registered the image's class list.
static void MacWSWindowGeometryObserverCallback(id observer, SEL command,
                                                id notification) {
    (void)observer;
    (void)command;
    id window = ((MacWSMsgID)objc_msgSend)(
        notification, sel_registerName("object"));
    if (!window) return;
    NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
        window, sel_registerName("windowNumber"));
    if (number <= 0 || (uint64_t)number > UINT32_MAX) return;
    CGRect frame = ((MacWSMsgRect)objc_msgSend)(
        window, sel_registerName("frame"));
    MacWSNotifyDisplayGeometryChanged((uint32_t)number, window, frame);
    // Window geometry and its min/max policy are one AppKit transaction, but
    // the display side reads those values from the metrics sidecar. The old
    // notification route invalidated only pixels and left that sidecar stale
    // until the 500-ms recovery timer. Coalesce native update/resize bursts
    // on the AppKit main queue, then publish the current frame and axis policy
    // together; MacWSPublishWindowMetrics already suppresses unchanged files.
    if (!MacWSWindowMetricsEventPublishPending) {
        MacWSWindowMetricsEventPublishPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     50 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSWindowMetricsEventPublishPending = NO;
            MacWSPublishWindowMetrics();
        });
    }
}

// Observation must not introduce selectors absent on AppKit's private window
// classes. Runtime-confirmed in Preview PID 17619: its stock NSPopoverFrame
// appears in NSApplication.windows but does not implement resizeIncrements.
// The production constraint query already checks that capability; the extra
// diagnostic query did not, and aborted an otherwise functioning popover.
// NaN here means "not exposed" in a diagnostic line, never a resize policy.
static CGSize MacWSOptionalDiagnosticWindowSize(id window, SEL selector) {
    if (window && ((MacWSMsgBoolSEL)objc_msgSend)(window,
            sel_registerName("respondsToSelector:"), selector))
        return ((MacWSMsgSize)objc_msgSend)(window, selector);
    return (CGSize){NAN, NAN};
}

static void MacWSPublishWindowMetrics(void) {
    Class applicationClass = objc_getClass("NSApplication");
    if (!applicationClass || !MacWSWindowMetricsPath[0]) return;
    id application = ((MacWSMsgID)objc_msgSend)(
        (id)applicationClass, sel_registerName("sharedApplication"));
    if (!application) return;
    MacWSCacheKeyboardContext(application);
    id windows = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("windows"));
    id keyWindow = ((MacWSMsgID)objc_msgSend)(
        application, sel_registerName("keyWindow"));
    MacWSReconcileUnityCursorState(keyWindow);
    BOOL spatialCanvas = MacWSMainBundleUsesSpatialCanvasTouch();
    BOOL fullscreenCanvas =
        MacWSMainBundleUsesFullscreenCanvasPresentation();
    uint64_t relativeRequestGeneration = 0;
    uint64_t relativeGenerationAfterRead = 0;
    BOOL relativePointerRequested = NO;
    do {
        relativeRequestGeneration = atomic_load_explicit(
            &MacWSRelativePointerRequestGeneration, memory_order_acquire);
        relativePointerRequested = atomic_load_explicit(
            &MacWSRelativePointerRequested, memory_order_acquire);
        relativeGenerationAfterRead = atomic_load_explicit(
            &MacWSRelativePointerRequestGeneration, memory_order_acquire);
    } while (relativeRequestGeneration != relativeGenerationAfterRead);
    BOOL relativeContractRepresented = !relativePointerRequested;
    NSMutableData *entries = [NSMutableData data];
    NSMutableArray<NSString *> *diagnosticEntries =
        MacWSRuntimeDiagnosticsEnabled() ? [NSMutableArray array] : nil;
    NSUInteger count = [windows count];
    for (NSUInteger index = 0;
         index < count && entries.length / sizeof(MacWSWindowMetricsEntry) <
             MACWS_STREAM_MAX_WINDOWS;
         index++) {
        id window = [windows objectAtIndex:index];
        NSInteger number = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("windowNumber"));
        if (number <= 0 || (uint64_t)number > UINT32_MAX) continue;
        CGRect frame = ((MacWSMsgRect)objc_msgSend)(
            window, sel_registerName("frame"));
        if (!isfinite(frame.size.width) || !isfinite(frame.size.height) ||
            frame.size.width <= 0.0 || frame.size.height <= 0.0) continue;

        BOOL resizable = NO;
        CGSize maximum = frame.size;
        CGSize minimum = MacWSEffectiveMinimumFrameSize(
            window, frame, &resizable, &maximum);
        BOOL orderedVisible = ((MacWSMsgBool)objc_msgSend)(
            window, sel_registerName("isVisible"));
        NSInteger windowLevel = ((MacWSMsgInteger)objc_msgSend)(
            window, sel_registerName("level"));
        // `Visible` is the cross-process contract for a window that may own
        // an iPad Scene, not merely AppKit's ordered-in bit. Runtime evidence
        // for Terminal's Low Disk Space alert was exact: metrics advertised
        // window 138 as Visible while displayd observed the same CGWindow at
        // level 8 and correctly attached it as window 137's transient layer.
        // Publish only ordinary level-0 windows here; panels/alerts continue
        // through displayd's transient stream and cannot satisfy launcher
        // readiness or create their own Scene.
        BOOL visible = orderedVisible && windowLevel == 0;
        if (relativePointerRequested && window == keyWindow)
            relativeContractRepresented = YES;
        id presentingWindow = MacWSPresentingWindow(window, application);
        BOOL transient = presentingWindow != nil;
        // Retain the exact object-level classification used by the published
        // catalog. During an application-modal loop AppKit can temporarily
        // change mainWindow/modalWindow before a semantic quit is drained;
        // recomputing then made Maps' already-published transient look like a
        // primary window and entered terminate:'s non-returning modal path.
        // Associations die with the NSWindow and are refreshed on every
        // metrics generation, so no PID/title/geometry guess is involved.
        objc_setAssociatedObject(
            window, &MacWSTransientWindowAssociationKey,
            transient ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL hasShadowSelector = sel_registerName("hasShadow");
        BOOL hasShadow = visible &&
            ((MacWSMsgBoolSEL)objc_msgSend)(
                window, sel_registerName("respondsToSelector:"),
                hasShadowSelector) &&
            ((MacWSMsgBool)objc_msgSend)(window, hasShadowSelector);
        MacWSWindowMetricsEntry entry = {
            .windowID = (uint32_t)number,
            .flags = (resizable ? MacWSStreamWindowResizable : 0) |
                (maximum.width <= minimum.width + 0.75
                    ? MacWSStreamWindowFixedWidth : 0) |
                (maximum.height <= minimum.height + 0.75
                    ? MacWSStreamWindowFixedHeight : 0) |
                (visible ? MacWSStreamWindowVisible : 0) |
                (transient ? MacWSStreamWindowTransient : 0) |
                (window == keyWindow ? MacWSStreamWindowFocused : 0) |
                (hasShadow ? MacWSStreamWindowHasShadow : 0) |
                (spatialCanvas ? MacWSStreamWindowSpatialCanvas : 0) |
                (fullscreenCanvas ?
                    MacWSStreamWindowFullscreenCanvas : 0) |
                (relativePointerRequested && window == keyWindow
                    ? MacWSStreamWindowRelativePointerRequested : 0),
            .logicalGroupID = MacWSLogicalWindowGroupID(window, application),
            .minimumLogicalWidth = (float)minimum.width,
            .minimumLogicalHeight = (float)minimum.height,
            .maximumLogicalWidth = (float)maximum.width,
            .maximumLogicalHeight = (float)maximum.height,
        };
        NSData *ackData = objc_getAssociatedObject(
            window, &MacWSWindowConfigureAckKey);
        if (ackData.length == sizeof(entry.configureAck))
            memcpy(&entry.configureAck, ackData.bytes, sizeof(entry.configureAck));
        [entries appendBytes:&entry length:sizeof(entry)];
        if (diagnosticEntries) {
            id title = ((MacWSMsgID)objc_msgSend)(
                window, sel_registerName("title"));
            NSUInteger styleMask = ((MacWSMsgUInteger)objc_msgSend)(
                window, sel_registerName("styleMask"));
            CGSize apiMinimum = MacWSOptionalDiagnosticWindowSize(
                window, sel_registerName("minSize"));
            CGSize apiMaximum = MacWSOptionalDiagnosticWindowSize(
                window, sel_registerName("maxSize"));
            CGSize apiContentMinimum = MacWSOptionalDiagnosticWindowSize(
                window, sel_registerName("contentMinSize"));
            CGSize apiContentMaximum = MacWSOptionalDiagnosticWindowSize(
                window, sel_registerName("contentMaxSize"));
            CGSize requiredMinimum = CGSizeZero;
            CGSize requiredMaximum = {MACWS_STREAM_MAX_DIMENSION,
                                       MACWS_STREAM_MAX_DIMENSION};
            MacWSRequiredContentSizeLimits(window, &requiredMinimum,
                                           &requiredMaximum);
            CGSize apiIncrements = MacWSOptionalDiagnosticWindowSize(
                window, sel_registerName("resizeIncrements"));
            [diagnosticEntries addObject:[NSString stringWithFormat:
                @"id=%ld class=%s title=%@ style=%#lx frame=%.1fx%.1f min=%.1fx%.1f max=%.1fx%.1f resizable=%@ fixed=%@x%@ level=%ld visible=%@ transient=%@ api-min=%.1fx%.1f api-max=%.1fx%.1f content-min=%.1fx%.1f content-max=%.1fx%.1f required-min=%.1fx%.1f required-max=%.1fx%.1f increments=%.1fx%.1f",
                (long)number, object_getClassName(window), title ?: @"",
                (unsigned long)styleMask, frame.size.width, frame.size.height,
                minimum.width, minimum.height, maximum.width, maximum.height,
                resizable ? @"YES" : @"NO",
                maximum.width <= minimum.width + 0.75 ? @"YES" : @"NO",
                maximum.height <= minimum.height + 0.75 ? @"YES" : @"NO",
                (long)windowLevel, visible ? @"YES" : @"NO",
                transient ? @"YES" : @"NO",
                apiMinimum.width, apiMinimum.height,
                apiMaximum.width, apiMaximum.height,
                apiContentMinimum.width, apiContentMinimum.height,
                apiContentMaximum.width, apiContentMaximum.height,
                requiredMinimum.width, requiredMinimum.height,
                requiredMaximum.width, requiredMaximum.height,
                apiIncrements.width, apiIncrements.height]];
        }
    }
    NSString *path = [NSString stringWithUTF8String:MacWSWindowMetricsPath];
    BOOL entriesChanged = !MacWSLastWindowMetricsEntries ||
        ![MacWSLastWindowMetricsEntries isEqualToData:entries];
    // Recover the publication if a consumer or cleanup pass removed the
    // sidecar while the AppKit window set remained unchanged.  The old early
    // return made that loss permanent for the lifetime of the application.
    if (!entriesChanged &&
        [NSFileManager.defaultManager fileExistsAtPath:path]) {
        if (relativeContractRepresented &&
            atomic_load_explicit(&MacWSRelativePointerRequestGeneration,
                                 memory_order_acquire) ==
                relativeRequestGeneration) {
            atomic_store_explicit(
                &MacWSRelativePointerPublishedGeneration,
                relativeRequestGeneration, memory_order_release);
        }
        return;
    }
    if (entriesChanged) {
        [MacWSLastWindowMetricsEntries release];
        MacWSLastWindowMetricsEntries = [entries copy];
        if (diagnosticEntries.count) {
            fprintf(stderr,
                "#### APP-INPUT WINDOW-METRICS pid=%d generation=%llu %s\n",
                getpid(),
                (unsigned long long)(MacWSWindowMetricsGeneration + 1),
                [[diagnosticEntries componentsJoinedByString:@" | "]
                    UTF8String]);
            fflush(stderr);
        }
    }
    MacWSWindowMetricsHeader header = {
        .magic = MACWS_WINDOW_METRICS_MAGIC,
        .version = MACWS_WINDOW_METRICS_VERSION,
        .size = sizeof(MacWSWindowMetricsHeader),
        .entrySize = sizeof(MacWSWindowMetricsEntry),
        .entryCount = (uint32_t)(entries.length /
                                 sizeof(MacWSWindowMetricsEntry)),
        .generation = ++MacWSWindowMetricsGeneration,
    };
    NSMutableData *file = [NSMutableData dataWithBytes:&header
                                                 length:sizeof(header)];
    [file appendData:entries];
    NSError *error = nil;
    BOOL written = [file writeToFile:path
                             options:NSDataWritingAtomic error:&error];
    if (!written && MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr, "#### APP-INPUT METRICS-WRITE pid=%d error=%s\n",
                getpid(), error.localizedDescription.UTF8String ?: "unknown");
        fflush(stderr);
    }
    if (written && entriesChanged)
        MacWSNotifyDisplayCatalogChanged('m');
    if (written && relativeContractRepresented &&
        atomic_load_explicit(&MacWSRelativePointerRequestGeneration,
                             memory_order_acquire) ==
            relativeRequestGeneration) {
        atomic_store_explicit(&MacWSRelativePointerPublishedGeneration,
                              relativeRequestGeneration,
                              memory_order_release);
    }
}

static void MacWSScheduleWindowMetricsPublish(void) {
    static _Atomic bool initialPublishScheduled = false;
    BOOL initial = !atomic_exchange_explicit(
        &initialPublishScheduled, true, memory_order_acq_rel);
    uint64_t delay = initial ? 500 * NSEC_PER_MSEC : 5 * NSEC_PER_SEC;
    // Window move/resize/update notifications publish committed changes in
    // 50 ms. This timer is only a recovery witness for a lost sidecar or a
    // framework-created window that emitted no observable notification.
    // Runtime fs_usage on iPad13,6 confirmed that the old recovery path
    // scanned and stat'ed every process's metrics sidecar every 500 ms while
    // the desktop was unchanged. Preserve one fast bootstrap pass, then keep
    // that bounded fallback scan off the idle desktop hot path. A separate
    // A/B showed Finder's SharedFileList resolver has its own 500-ms source,
    // so this change deliberately makes no claim to fix that unrelated loop.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool { MacWSPublishWindowMetrics(); }
        MacWSScheduleWindowMetricsPublish();
    });
}

static void MacWSInstallWindowGeometryObservers(void) {
    if (MacWSWindowGeometryObserverInstance) return;
    static const char observerClassName[] =
        "MacWSRuntimeWindowGeometryObserver";
    Class observerClass = objc_getClass(observerClassName);
    if (!observerClass) {
        Class baseClass = objc_getClass("NSObject");
        observerClass = baseClass
            ? objc_allocateClassPair(baseClass, observerClassName, 0) : Nil;
        if (!observerClass) return;
        SEL callbackSelector =
            sel_registerName("macws_windowGeometryChanged:");
        if (!class_addMethod(observerClass, callbackSelector,
                             (IMP)MacWSWindowGeometryObserverCallback,
                             "v@:@")) {
            objc_disposeClassPair(observerClass);
            return;
        }
        objc_registerClassPair(observerClass);
    }
    MacWSWindowGeometryObserverInstance = ((MacWSMsgID)objc_msgSend)(
        (id)observerClass, sel_registerName("new"));
    if (!MacWSWindowGeometryObserverInstance) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    // The target's on-device arm64e lld can leave newly-added ObjC constant
    // container/string pointers with an incompatible PAC discriminator. The
    // Maps crash report at AppInputBridge.m:5977 showed objc_msgSend(retain)
    // faulting inside __NSArrayI_new on exactly this observer-name array.
    // Construct ordinary runtime NSString objects from immutable C bytes;
    // the notification API and resulting semantics are unchanged.
    static const char *const names[] = {
        "NSWindowDidMoveNotification",
        "NSWindowDidResizeNotification",
        "NSWindowDidEndLiveResizeNotification",
        // Content-driven panels (Finder Get Info is the concrete case) can
        // change min/max constraints without changing their current frame.
        // DidUpdate is the public AppKit edge for that committed window state;
        // the callback above coalesces it to at most one metrics query per
        // 50-ms interval and writes only when the sidecar bytes changed.
        "NSWindowDidUpdateNotification",
    };
    for (NSUInteger index = 0;
         index < sizeof(names) / sizeof(names[0]); index++) {
        NSString *name = [NSString stringWithUTF8String:names[index]];
        if (!name) continue;
        [center addObserver:MacWSWindowGeometryObserverInstance
                   selector:@selector(macws_windowGeometryChanged:)
                       name:name
                     object:nil];
    }
}

typedef void (*MacWSCoreDragUntilMouseUpFunction)(id, SEL, id, BOOL *);
static MacWSCoreDragUntilMouseUpFunction
    MacWSOriginalCoreDragUntilMouseUp;

// RE-confirmed via the live macOS 13.4 AppKit image on iPad13,6:
// -[NSCoreDragManager _dragUntilMouseUp:accepted:] installs
// NSCoreDragCGEventInputProc and enters CoreDragStartDragging. That callback
// wraps the WindowServer CGEvent and forwards source motion through
// NSCoreDragProcessSourceDrag; it never reads continuation NSEvents from
// NSApplication's queue. Window mode must therefore switch only the already-
// accepted exact-window gesture to its CGS route for this native CoreDrag
// interval. Fullscreen never creates a process-local down and cannot enter
// this branch.
static void MacWSCoreDragUntilMouseUpBridge(id self, SEL command,
                                            id event, BOOL *accepted) {
    BOOL ownsNativeRoute = NO;
    NSInteger eventWindow = event ? ((MacWSMsgInteger)objc_msgSend)(
        event, sel_registerName("windowNumber")) : 0;
    BOOL processLocalEvent = MacWSIsProcessLocalMouseEvent(event);
    BOOL hasSystemPoster = MacWSLegacySystemMousePoster() != NULL;
    BOOL contextAccepting = NO;
    NSInteger contextWindow = 0;
    uint32_t contextContact = 0;
    uint64_t contextScene = 0;
    pthread_mutex_lock(&MacWSAppInputRouteLock);
    contextAccepting = MacWSAppInputDirectContext.accepting;
    contextWindow = MacWSAppInputDirectContext.windowNumber;
    contextContact = MacWSAppInputDirectContext.contactID;
    contextScene = MacWSAppInputDirectContext.sceneID;
    ownsNativeRoute = eventWindow > 0 && eventWindow <= UINT32_MAX &&
        processLocalEvent && hasSystemPoster && contextAccepting &&
        contextWindow == eventWindow;
    pthread_mutex_unlock(&MacWSAppInputRouteLock);
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT CORE-DRAG-ENTER pid=%d event-window=%ld "
            "process-local=%s poster=%s context-accepting=%s "
            "context-window=%ld gesture=%u scene=%#llx owns-native=%s\n",
            getpid(), (long)eventWindow,
            processLocalEvent ? "YES" : "NO",
            hasSystemPoster ? "YES" : "NO",
            contextAccepting ? "YES" : "NO", (long)contextWindow,
            contextContact, (unsigned long long)contextScene,
            ownsNativeRoute ? "YES" : "NO");
        fflush(stderr);
    }
    if (ownsNativeRoute) {
        atomic_store_explicit(&MacWSAppInputCoreDragNativeWindow,
                              (uint32_t)eventWindow,
                              memory_order_relaxed);
        atomic_store_explicit(&MacWSAppInputCoreDragNativeActive, YES,
                              memory_order_release);
    }
    double started = MacWSRuntimeDiagnosticsEnabled()
        ? MacWSAppInputMonotonicSeconds() : 0.0;
    if (MacWSOriginalCoreDragUntilMouseUp)
        MacWSOriginalCoreDragUntilMouseUp(self, command, event, accepted);
    if (ownsNativeRoute) {
        atomic_store_explicit(&MacWSAppInputCoreDragNativeActive, NO,
                              memory_order_release);
        atomic_store_explicit(&MacWSAppInputCoreDragNativeWindow, 0,
                              memory_order_relaxed);
        pthread_mutex_lock(&MacWSAppInputRouteLock);
        if (MacWSAppInputDirectContext.contactID == contextContact &&
            MacWSAppInputDirectContext.sceneID == contextScene &&
            MacWSAppInputDirectContext.windowNumber == contextWindow)
            MacWSClearDirectTrackingContextLocked();
        pthread_mutex_unlock(&MacWSAppInputRouteLock);
    }
    if (ownsNativeRoute && MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT CORE-DRAG-SESSION pid=%d window=%ld "
            "accepted=%s elapsed=%.3fms route=exact-window-cgs\n",
            getpid(), (long)eventWindow,
            accepted && *accepted ? "YES" : "NO",
            (MacWSAppInputMonotonicSeconds() - started) * 1000.0);
        fflush(stderr);
    }
}

static void MacWSInstallCoreDragNativeBridge(void) {
    Class coreClass = objc_getClass("NSCoreDragManager");
    SEL untilSelector = sel_registerName("_dragUntilMouseUp:accepted:");
    Method untilMethod = coreClass
        ? class_getInstanceMethod(coreClass, untilSelector) : NULL;
    if (untilMethod && !MacWSOriginalCoreDragUntilMouseUp) {
        MacWSOriginalCoreDragUntilMouseUp =
            (MacWSCoreDragUntilMouseUpFunction)
                method_getImplementation(untilMethod);
        method_setImplementation(untilMethod,
            (IMP)MacWSCoreDragUntilMouseUpBridge);
    }
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
            "#### APP-INPUT CORE-DRAG-BRIDGE installed=%s\n",
            MacWSOriginalCoreDragUntilMouseUp ? "YES" : "NO");
        fflush(stderr);
    }
}

static void MacWSInstallAppInputBridgeNow(void) {
    if (!MacWSAppInputSupportedProcess()) return;
    if (MacWSRuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "#### APP-INPUT PROCESS-IDENTITY pid=%d program=%s "
                "preview-adapter=%p\n",
                getpid(), MacWSAppInputProgramName(),
                MacWSInstallPreviewCoreImageRendererAdapter);
        fflush(stderr);
    }
    MacWSInstallPreviewCoreImageRendererAdapter();
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &MacWSAppInputInstallState, &expected, 1,
            memory_order_acq_rel, memory_order_acquire)) return;
    BOOL dockEndpoint = MacWSAppInputIsDockEndpoint();
    if (dockEndpoint && !MacWSInstallDockGesturesWitness()) {
        // Dock's main executable can finish Objective-C registration after an
        // inserted dylib constructor. Keep the endpoint alive; the finite
        // install retry below will call this again before user interaction.
        atomic_store_explicit(&MacWSAppInputInstallState, 0,
                              memory_order_release);
        return;
    }
    if (dockEndpoint) MacWSPublishDockExposeState(NO);
    if (!dockEndpoint) {
        MacWSInstallUnityRelativePointerContract();
        if (!MacWSOriginalUnitySetShowCursor)
            MacWSScheduleUnityRelativePointerContractInstall(0);
        MacWSInstallWorkspacePowerLifecycle();
        MacWSInstallWorkspaceOpenWitness();
        MacWSInstallApplicationKeyWitness();
        MacWSInstallMenuEventLoopWitness();
        MacWSInstallCoreDragNativeBridge();
        MacWSInstallOrderedWindowRegistry();
        MacWSInstallTransientFrameConstraint();
        MacWSInstallFullscreenTransitionPrerequisite();
        if (!MacWSOriginalApplicationSendEvent ||
            !MacWSOriginalHandleActivatedEvent)
            MacWSScheduleApplicationKeyWitnessInstall(0);
        MacWSAppInputPending = [NSMutableArray new];
        MacWSAppInputDeferredRFBMoveEvents = [NSMutableArray new];
    }
    snprintf(MacWSAppInputPath, sizeof(MacWSAppInputPath),
             "/private/tmp/macws_app_input.%d.sock", getpid());
    snprintf(MacWSWindowMetricsPath, sizeof(MacWSWindowMetricsPath),
             "/private/tmp/macws_window_metrics.%d.bin", getpid());
    unlink(MacWSWindowMetricsPath);
    MacWSAppInputSocket = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (MacWSAppInputSocket < 0) {
        atomic_store_explicit(&MacWSAppInputInstallState, 0,
                              memory_order_release);
        return;
    }
    int inputReceiveBuffer = 512 * 1024;
    (void)setsockopt(MacWSAppInputSocket, SOL_SOCKET, SO_RCVBUF,
                     &inputReceiveBuffer, sizeof(inputReceiveBuffer));
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, MacWSAppInputPath, sizeof(address.sun_path));
    unlink(MacWSAppInputPath);
    if (bind(MacWSAppInputSocket, (const struct sockaddr *)&address,
             sizeof(address)) != 0) {
        close(MacWSAppInputSocket);
        MacWSAppInputSocket = -1;
        atomic_store_explicit(&MacWSAppInputInstallState, 0,
                              memory_order_release);
        return;
    }
    chmod(MacWSAppInputPath, 0600);
    pthread_t thread;
    if (pthread_create(&thread, NULL, MacWSAppInputThread, NULL) == 0) {
        pthread_detach(thread);
        if (!dockEndpoint) MacWSScheduleWindowMetricsPublish();
        atomic_store_explicit(&MacWSAppInputInstallState, 2,
                              memory_order_release);
        if (MacWSRuntimeDiagnosticsEnabled()) {
            fprintf(stderr, "#### APP-INPUT READY pid=%d socket=%s abi=%u-%u record=%zu\n",
                    getpid(), MacWSAppInputPath,
                    MACWS_INPUT_LEGACY_VERSION, MACWS_INPUT_VERSION,
                    sizeof(MacWSInputRecord));
            fflush(stderr);
        }
    } else {
        close(MacWSAppInputSocket);
        MacWSAppInputSocket = -1;
        unlink(MacWSAppInputPath);
        atomic_store_explicit(&MacWSAppInputInstallState, 0,
                              memory_order_release);
    }
}

// DYLD_INSERT_LIBRARIES constructors can precede AppKit's Objective-C class
// realization.  Runtime-confirmed with Terminal pid 67547 on 2026-07-31: the
// process displayed a real window, but the one-shot constructor observed no
// NSApplication and never created either its app-input socket or window
// metrics sidecar. Retry only after returning to the application's main queue;
// the finite ten-second window prevents a command-line process that merely
// maps AppKit from retaining a timer forever. Installation remains conditional
// on the real NSApplication class and never fabricates an AppKit endpoint.
static void MacWSScheduleAppInputBridgeInstall(unsigned attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (atomic_load_explicit(&MacWSAppInputInstallState,
                                 memory_order_acquire) == 2) return;
        MacWSInstallAppInputBridgeNow();
        if (atomic_load_explicit(&MacWSAppInputInstallState,
                                 memory_order_acquire) != 2 &&
            attempt < 39) {
            MacWSScheduleAppInputBridgeInstall(attempt + 1);
        }
    });
}

__attribute__((constructor)) static void MacWSInstallAppInputBridge(void) {
    const char *utility_process = getenv("MACWS_UTILITY_PROCESS");
    if (utility_process && strcmp(utility_process, "1") == 0) return;
    const char *shell_env = getenv("VSCODE_RESOLVING_ENVIRONMENT");
    if (shell_env && strcmp(shell_env, "1") == 0) return;
    MacWSInstallAppInputBridgeNow();
    if (atomic_load_explicit(&MacWSAppInputInstallState,
                             memory_order_acquire) != 2) {
        MacWSScheduleAppInputBridgeInstall(0);
    }
}

__attribute__((destructor)) static void MacWSRemoveAppInputBridge(void) {
    pthread_mutex_lock(&MacWSAppInputRouteLock);
    atomic_store_explicit(&MacWSAppInputCoreDragNativeActive, NO,
                          memory_order_release);
    atomic_store_explicit(&MacWSAppInputCoreDragNativeWindow, 0,
                          memory_order_relaxed);
    MacWSAppInputRFBTrackingActive = NO;
    MacWSAppInputRFBTrackingButtons = 0;
    atomic_store_explicit(&MacWSAppInputSynchronousTrackingActive, NO,
                          memory_order_release);
    MacWSClearDirectTrackingContextLocked();
    MacWSClearDirectGestureContextLocked();
    pthread_mutex_unlock(&MacWSAppInputRouteLock);
    MacWSSetDeferredRFBDownEvent(nil);
    MacWSClearDeferredRFBMoveEvents();
    MacWSSetAppInputGestureWindow(nil);
    MacWSSetAppInputGestureHitView(nil);
    MacWSSetLastSystemActivationEvent(nil);
    if (MacWSAppInputIsDockEndpoint()) {
        MacWSClearDockModalContext();
        if (MacWSDockExposeStateToken >= 0) {
            notify_cancel(MacWSDockExposeStateToken);
            MacWSDockExposeStateToken = -1;
        }
    }
    if (MacWSAppInputSocket >= 0) close(MacWSAppInputSocket);
    if (MacWSAppInputPath[0]) unlink(MacWSAppInputPath);
    if (MacWSWindowMetricsPath[0]) unlink(MacWSWindowMetricsPath);
    if (MacWSWorkspaceWillSleepToken >= 0) {
        notify_cancel(MacWSWorkspaceWillSleepToken);
        MacWSWorkspaceWillSleepToken = -1;
    }
    if (MacWSWorkspaceDidWakeToken >= 0) {
        notify_cancel(MacWSWorkspaceDidWakeToken);
        MacWSWorkspaceDidWakeToken = -1;
    }
    [MacWSLastWindowMetricsEntries release];
    MacWSLastWindowMetricsEntries = nil;
    [MacWSMenuCaches release];
    MacWSMenuCaches = nil;
    [MacWSOrderedWindowRegistry release];
    MacWSOrderedWindowRegistry = nil;
}

#define MACWS_APP_INPUT_INTERPOSE(_replacement, _replacee)                  \
    __attribute__((used)) static struct {                                   \
        const void *replacement;                                            \
        const void *replacee;                                               \
    } _macws_app_input_interpose_##_replacee                                \
        __attribute__((section("__DATA,__interpose"))) = {                  \
            (const void *)(uintptr_t)&_replacement,                         \
            (const void *)(uintptr_t)&_replacee                             \
        }

MACWS_APP_INPUT_INTERPOSE(MacWSAssociateMouseAndMouseCursorPosition,
                          CGAssociateMouseAndMouseCursorPosition);
MACWS_APP_INPUT_INTERPOSE(MacWSDisplayHideCursor, CGDisplayHideCursor);
MACWS_APP_INPUT_INTERPOSE(MacWSDisplayShowCursor, CGDisplayShowCursor);
MACWS_APP_INPUT_INTERPOSE(MacWSGetLastMouseDelta, CGGetLastMouseDelta);
