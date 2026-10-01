// Keep this target independent of Theos's legacy vendor IOKit headers.
// Importing the modern CoreGraphics module and those headers together creates
// conflicting IOPhysicalRange definitions, so the small stable C ABI used by
// this daemon is declared here and still linked against CoreGraphics.

#include <errno.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include "macws_host_protocol.h"

typedef uint32_t CGDirectDisplayID;
typedef uint32_t CGEventType;
typedef uint32_t CGMouseButton;
typedef uint32_t CGEventTapLocation;
typedef uint32_t CGEventField;
typedef uint32_t CGWindowID;
typedef uint32_t CGWindowListOption;
typedef int32_t CGWindowLevel;
typedef int32_t CGWindowLevelKey;
typedef const void *CGEventRef;
typedef uint32_t SLSConnectionID;

// Carbon Process Manager's public ABI.  Keep the declarations local so this
// small broker does not have to import the legacy ApplicationServices headers
// alongside CoreGraphics' modern definitions.
typedef struct {
    uint32_t highLongOfPSN;
    uint32_t lowLongOfPSN;
} MacWSProcessSerialNumber;

extern CGDirectDisplayID CGMainDisplayID(void);
extern CGRect CGDisplayBounds(CGDirectDisplayID display);
extern size_t CGDisplayPixelsWide(CGDirectDisplayID display);
extern size_t CGDisplayPixelsHigh(CGDirectDisplayID display);
extern CGEventRef CGEventCreateMouseEvent(const void *source, CGEventType type,
                                         CGPoint point, CGMouseButton button);
extern CGEventRef CGEventCreate(const void *source);
extern CGPoint CGEventGetLocation(CGEventRef event);
extern void CGEventSetIntegerValueField(CGEventRef event, CGEventField field,
                                        int64_t value);
extern void CGEventPost(CGEventTapLocation tap, CGEventRef event);
extern void CGEventPostToPid(pid_t pid, CGEventRef event);
extern bool CGPreflightPostEventAccess(void);
extern CFArrayRef CGWindowListCopyWindowInfo(CGWindowListOption option,
                                             CGWindowID relativeToWindow);
extern CGWindowLevel CGWindowLevelForKey(CGWindowLevelKey key);
extern const CFStringRef kCGWindowNumber;
extern const CFStringRef kCGWindowLayer;
extern const CFStringRef kCGWindowBounds;
extern const CFStringRef kCGWindowOwnerPID;
extern const CFStringRef kCGWindowOwnerName;
extern bool CGRectMakeWithDictionaryRepresentation(CFDictionaryRef dictionary,
                                                    CGRect *rect);

enum {
    MacWSCGEventLeftMouseDown = 1,
    MacWSCGEventLeftMouseUp = 2,
    MacWSCGEventRightMouseDown = 3,
    MacWSCGEventRightMouseUp = 4,
    MacWSCGEventMouseMoved = 5,
    MacWSCGEventLeftMouseDragged = 6,
    MacWSCGMouseButtonLeft = 0,
    MacWSCGMouseButtonRight = 1,
    MacWSCGHIDEventTap = 0,
    MacWSCGMouseEventClickState = 1,
    MacWSCGMouseEventButtonNumber = 3,
    MacWSCGMouseEventWindowUnderMousePointer = 91,
    MacWSCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent = 92,
    MacWSCGWindowListOptionOnScreenOnly = 1 << 0,
    MacWSCGWindowListExcludeDesktopElements = 1 << 4,
    MacWSCGPopUpMenuWindowLevelKey = 11,
};

static const char InputSocketPath[] = "/private/tmp/macws_host_input.sock";
static const char InputLockPath[] = "/private/tmp/macws_host_input.lock";
static const char TargetSocketPath[] = "/private/tmp/macws_input_target.sock";
static const char CaptureRequestPath[] = "/tmp/macws_capture_final";
static volatile sig_atomic_t StopRequested;
static volatile sig_atomic_t InputSocketFD = -1;
static volatile sig_atomic_t TargetSocketFD = -1;
static uint64_t LastCaptureGeneration;
static uint64_t TargetProbeNonce;

static bool RuntimeDiagnosticsEnabled(void) {
    static int cached = -1;
    if (cached < 0) {
        cached = getenv("MACWS_RUNTIME_DIAGNOSTICS") != NULL ||
            access("/tmp/macws_runtime_diagnostics", F_OK) == 0;
    }
    return cached != 0;
}

typedef struct {
    pid_t pid;
    int32_t windowID;
    bool selectedWasActive;
    bool selectedWasFrontUIProcess;
    bool competingActiveOwner;
    bool responseIncomplete;
} MacWSWindowTarget;

static void HandleSignal(int signalNumber) {
    (void)signalNumber;
    StopRequested = 1;
    // close(2) is async-signal-safe.  Closing the descriptor here makes a
    // blocking recv(2) return even on systems where signal() installs a
    // restarting handler, so launchd stop does not leave an orphan daemon.
    int socketFD = (int)InputSocketFD;
    InputSocketFD = -1;
    if (socketFD >= 0) close(socketFD);
    int targetSocketFD = (int)TargetSocketFD;
    TargetSocketFD = -1;
    if (targetSocketFD >= 0) close(targetSocketFD);
}

static const char *KindName(MacWSInputKind kind) {
    switch (kind) {
        case MacWSInputKindTouchDown: return "down";
        case MacWSInputKindTouchMove: return "move";
        case MacWSInputKindTouchUp: return "up";
        case MacWSInputKindTouchCancel: return "cancel";
        case MacWSInputKindHover: return "hover";
        case MacWSInputKindTap: return "tap";
        case MacWSInputKindTargetProbe: return "target-probe";
        case MacWSInputKindActivateTarget: return "activate-target";
        case MacWSInputKindDeactivateApplication: return "deactivate-app";
        case MacWSInputKindMenuHover: return "menu-hover";
        case MacWSInputKindKeyDown: return "key-down";
        case MacWSInputKindKeyUp: return "key-up";
        case MacWSInputKindModifierSnapshot: return "modifier-snapshot";
        case MacWSInputKindSecondaryTap: return "secondary-tap";
        case MacWSInputKindScroll: return "scroll";
        case MacWSInputKindMagnify: return "magnify";
        case MacWSInputKindRotate: return "rotate";
        case MacWSInputKindConfigureWindow: return "configure-window";
        case MacWSInputKindCloseWindow: return "close-window";
        case MacWSInputKindCreateInitialWindow: return "create-initial-window";
        case MacWSInputKindReopenApplication: return "reopen-application";
        case MacWSInputKindDesktopCommand: return "desktop-command";
        case MacWSInputKindSystemGesture: return "system-gesture";
        case MacWSInputKindPerformPaste: return "perform-paste";
        case MacWSInputKindOpenDocuments: return "open-documents";
        case MacWSInputKindPerformQuit: return "perform-quit";
    }
    return "invalid";
}

static bool IsSystemPointerKind(MacWSInputKind kind) {
    switch (kind) {
        case MacWSInputKindTouchDown:
        case MacWSInputKindTouchMove:
        case MacWSInputKindTouchUp:
        case MacWSInputKindTouchCancel:
        case MacWSInputKindHover:
        case MacWSInputKindMenuHover:
        case MacWSInputKindTap:
        case MacWSInputKindSecondaryTap:
            return true;
        default:
            return false;
    }
}

// Down and up must use the same session-vs-AppKit transport. Physical keys
// keep the session proxy because its modifier snapshot models real held HID
// state. Every software-toolbar key already carries an exact PID/window and
// must remain on AppInput: sending arrows or Control/Command chords to the
// global proxy discards the represented window and current AppKit responder.
static bool IsNativeKeyboardProxyRecord(const MacWSInputRecord *record) {
    if (!record || (record->kind != MacWSInputKindKeyDown &&
                    record->kind != MacWSInputKindKeyUp)) return false;
    return record->source == MacWSInputSourceHardwareKeyboard;
}

static bool RecordIsValid(const MacWSInputRecord *record) {
    if (record->kind == MacWSInputKindModifierSnapshot) {
        return record->magic == MACWS_INPUT_MAGIC &&
            MacWSInputVersionSupportsKind(record->version, record->kind) &&
            record->source == MacWSInputSourceHardwareKeyboard &&
            record->reserved <= 0xffu && record->contactID <= 1 &&
            (record->contactID == 0 || record->reserved == 0) &&
            isfinite(record->timestamp) && record->timestamp >= 0;
    }
    if (record->magic != MACWS_INPUT_MAGIC ||
        !MacWSInputVersionSupportsKind(record->version, record->kind) ||
        !isfinite(record->x) || !isfinite(record->y) ||
        record->frameWidth == 0 || record->frameHeight == 0 ||
        record->targetPID < 0 ||
        record->source > MacWSInputSourceMax ||
        !isfinite(record->altitude) || !isfinite(record->azimuth) ||
        !isfinite(record->tiltX) || !isfinite(record->tiltY) ||
        record->tiltX < -1.0f || record->tiltX > 1.0f ||
        record->tiltY < -1.0f || record->tiltY > 1.0f) {
        return false;
    }
    if (record->kind == MacWSInputKindConfigureWindow) {
        return record->targetPID > 1 &&
               MacWSInputWindowIDForScene(record->sceneID) != 0 &&
               record->x >= 64.0f && record->y >= 64.0f &&
               record->x <= 16384.0f && record->y <= 16384.0f &&
               isfinite(record->pressure) &&
               record->pressure >= 0.5f && record->pressure <= 4.0f;
    }
    if (record->kind == MacWSInputKindCloseWindow) {
        return record->targetPID > 1 &&
               MacWSInputWindowIDForScene(record->sceneID) != 0;
    }
    if (record->kind == MacWSInputKindCreateInitialWindow)
        return record->targetPID > 1;
    if (record->kind == MacWSInputKindReopenApplication)
        return record->targetPID > 1;
    if (record->kind == MacWSInputKindPerformPaste)
        return record->targetPID > 1;
    if (record->kind == MacWSInputKindOpenDocuments)
        return record->targetPID > 1 && record->sceneID != 0;
    if (record->kind == MacWSInputKindPerformQuit)
        return record->targetPID > 1;
    if (record->kind == MacWSInputKindDesktopCommand)
        return record->targetPID > 1 &&
            record->contactID >= MacWSDesktopCommandSpaceLeft &&
            record->contactID <= MacWSDesktopCommandSpaceRight;
    if (record->kind == MacWSInputKindScroll) {
        float horizontal = 0.0f;
        memcpy(&horizontal, &record->contactID, sizeof(horizontal));
        if (!isfinite(record->pressure) || !isfinite(horizontal) ||
            fabsf(record->pressure) > 16384.0f ||
            fabsf(horizontal) > 16384.0f) return false;
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
             phase != MacWSInputFlagGestureCancelled)) return false;
    }
    if (record->kind == MacWSInputKindSystemGesture) {
        uint16_t phase = record->flags &
            (MacWSInputFlagGestureBegan | MacWSInputFlagGestureChanged |
             MacWSInputFlagGestureEnded | MacWSInputFlagGestureCancelled);
        if (record->targetPID <= 1 ||
            (record->flags & MacWSInputFlagGlobalSystemSurface) == 0 ||
            (record->buttons != MacWSSystemGestureAxisHorizontal &&
             record->buttons != MacWSSystemGestureAxisVertical) ||
            record->contactID == 0 || !isfinite(record->pressure) ||
            fabsf(record->pressure) > 2.0f ||
            fabsf(record->altitude) > 12.0f ||
            (phase != MacWSInputFlagGestureBegan &&
             phase != MacWSInputFlagGestureChanged &&
             phase != MacWSInputFlagGestureEnded &&
             phase != MacWSInputFlagGestureCancelled)) return false;
    }
    if (
        record->x < 0.0f || record->y < 0.0f ||
        record->x >= record->frameWidth || record->y >= record->frameHeight ||
        record->kind < MacWSInputKindTouchDown ||
        record->kind > MacWSInputKindPerformQuit) {
        return false;
    }
    return true;
}

static CGPoint QuartzPointForRecord(const MacWSInputRecord *record,
                                    CGRect displayBounds) {
    double normalizedX = record->x / (double)record->frameWidth;
    double normalizedY = record->y / (double)record->frameHeight;
    normalizedX = fmin(fmax(normalizedX, 0.0), 1.0);
    normalizedY = fmin(fmax(normalizedY, 0.0), 1.0);
    return (CGPoint){
        displayBounds.origin.x + normalizedX * displayBounds.size.width,
        displayBounds.origin.y + normalizedY * displayBounds.size.height,
    };
}

static CGEventType EventTypeForRecord(const MacWSInputRecord *record,
                                      bool *buttonDown) {
    switch ((MacWSInputKind)record->kind) {
        case MacWSInputKindTouchDown:
            *buttonDown = true;
            return MacWSCGEventLeftMouseDown;
        case MacWSInputKindTouchMove:
            return *buttonDown ? MacWSCGEventLeftMouseDragged
                               : MacWSCGEventMouseMoved;
        case MacWSInputKindTouchUp:
        case MacWSInputKindTouchCancel:
            *buttonDown = false;
            return MacWSCGEventLeftMouseUp;
        case MacWSInputKindHover:
        case MacWSInputKindMenuHover:
            return MacWSCGEventMouseMoved;
        case MacWSInputKindTap:
            return MacWSCGEventLeftMouseDown;
        case MacWSInputKindSecondaryTap:
            return MacWSCGEventRightMouseDown;
        case MacWSInputKindTargetProbe:
        case MacWSInputKindActivateTarget:
        case MacWSInputKindDeactivateApplication:
        case MacWSInputKindKeyDown:
        case MacWSInputKindKeyUp:
        case MacWSInputKindScroll:
        case MacWSInputKindMagnify:
        case MacWSInputKindRotate:
        case MacWSInputKindConfigureWindow:
        case MacWSInputKindCloseWindow:
        case MacWSInputKindCreateInitialWindow:
        case MacWSInputKindReopenApplication:
        case MacWSInputKindDesktopCommand:
        case MacWSInputKindSystemGesture:
        case MacWSInputKindPerformPaste:
        case MacWSInputKindOpenDocuments:
        case MacWSInputKindPerformQuit:
            // Consumed before event construction in main().
            return 0;
    }
    return 0;
}

static bool ReadCursorPoint(CGPoint *point) {
    CGEventRef stateEvent = CGEventCreate(NULL);
    if (!stateEvent) return false;
    *point = CGEventGetLocation(stateEvent);
    CFRelease(stateEvent);
    return true;
}

static void ReadDisplayGeometry(CGDirectDisplayID *display, CGRect *bounds,
                                size_t *pixelWidth, size_t *pixelHeight) {
    *display = CGMainDisplayID();
    *bounds = CGDisplayBounds(*display);
    *pixelWidth = CGDisplayPixelsWide(*display);
    *pixelHeight = CGDisplayPixelsHigh(*display);
}

static bool PointInRect(CGPoint point, CGRect rect) {
    return point.x >= rect.origin.x && point.y >= rect.origin.y &&
           point.x < rect.origin.x + rect.size.width &&
           point.y < rect.origin.y + rect.size.height;
}

typedef SLSConnectionID (*MacWSSLSMainConnectionIDFn)(void);
typedef CFDictionaryRef
    (*MacWSSLSCopyWindowRoutingRecordsForScreenLocationFn)(
        SLSConnectionID connection, CGPoint location);
typedef int32_t (*MacWSSLSConnectionGetPIDFn)(SLSConnectionID connection,
                                              pid_t *pid);
typedef int32_t (*MacWSGetFrontProcessFn)(MacWSProcessSerialNumber *process);
typedef int32_t (*MacWSGetProcessPIDFn)(const MacWSProcessSerialNumber *process,
                                       pid_t *pid);
typedef int32_t (*MacWSGetProcessForPIDFn)(pid_t pid,
                                           MacWSProcessSerialNumber *process);
typedef int32_t (*MacWSSetFrontProcessWithOptionsFn)(
    const MacWSProcessSerialNumber *process, uint32_t options);

typedef struct {
    bool attempted;
    void *image;
    MacWSSLSMainConnectionIDFn mainConnectionID;
    MacWSSLSCopyWindowRoutingRecordsForScreenLocationFn
        copyRoutingRecords;
    MacWSSLSConnectionGetPIDFn connectionGetPID;
} MacWSSkyLightRoutingAPI;

static MacWSSkyLightRoutingAPI SkyLightRoutingAPI(void) {
    static MacWSSkyLightRoutingAPI api;
    if (api.attempted) return api;
    api.attempted = true;
    api.image = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY | RTLD_LOCAL);
    if (!api.image) return api;
    api.mainConnectionID = (MacWSSLSMainConnectionIDFn)dlsym(
        api.image, "SLSMainConnectionID");
    api.copyRoutingRecords =
        (MacWSSLSCopyWindowRoutingRecordsForScreenLocationFn)dlsym(
            api.image, "SLSCopyWindowRoutingRecordsForScreenLocation");
    api.connectionGetPID = (MacWSSLSConnectionGetPIDFn)dlsym(
        api.image, "SLSConnectionGetPID");
    return api;
}

// Read the session's real front-process owner without asking every AppKit
// application's main thread.  GetFrontProcess/GetProcessPID are the same
// public HIServices transaction used by macwsworkspacectl's activation path.
// They remain responsive while an application is inside a synchronous menu
// or control tracker, which is precisely when a per-application target probe
// cannot drain.  Resolve dynamically so another macOS image can retain the
// existing AppInput fallback if the compatibility framework is unavailable.
static pid_t FrontUIProcessPID(void) {
    static bool attempted;
    static void *applicationServices;
    static MacWSGetFrontProcessFn getFrontProcess;
    static MacWSGetProcessPIDFn getProcessPID;
    if (!attempted) {
        attempted = true;
        getFrontProcess = (MacWSGetFrontProcessFn)dlsym(
            RTLD_DEFAULT, "GetFrontProcess");
        getProcessPID = (MacWSGetProcessPIDFn)dlsym(
            RTLD_DEFAULT, "GetProcessPID");
        if (!getFrontProcess || !getProcessPID) {
            applicationServices = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/"
                "ApplicationServices",
                RTLD_LAZY | RTLD_LOCAL);
            if (applicationServices) {
                getFrontProcess = (MacWSGetFrontProcessFn)dlsym(
                    applicationServices, "GetFrontProcess");
                getProcessPID = (MacWSGetProcessPIDFn)dlsym(
                    applicationServices, "GetProcessPID");
            }
        }
    }
    if (!getFrontProcess || !getProcessPID) return 0;

    MacWSProcessSerialNumber process = {0};
    pid_t pid = 0;
    if (getFrontProcess(&process) != 0 ||
        getProcessPID(&process, &pid) != 0 || pid <= 1) {
        return 0;
    }
    return pid;
}

// The broker, rather than the inactive target application, owns the missing
// cross-process Workspace transaction. Runtime-confirmed on 2026-08-20:
// Steam's in-process repair returned ls-set=-54 and remained active=NO, while
// macwsworkspacectl's public NSRunningApplication + HIServices transaction
// activated the same PID and the next identical click opened Steam's Library
// menu.  A follow-up isolated the two halves: HIServices alone returned 0 but
// Steam still logged active-before=NO active-after=NO.  Keep the same ordering
// as macwsworkspacectl: Workspace activation first, then the front-window
// transaction. Neither path forges isActive/keyWindow or a control hit.
static bool ActivateRunningApplication(pid_t pid) {
    @autoreleasepool {
        Class applicationClass = objc_getClass("NSRunningApplication");
        if (!applicationClass) return false;
        id (*runningApplication)(id, SEL, pid_t) =
            (id (*)(id, SEL, pid_t))(void *)objc_msgSend;
        id application = runningApplication(
            (id)applicationClass,
            sel_registerName("runningApplicationWithProcessIdentifier:"), pid);
        if (!application) return false;
        bool (*activate)(id, SEL, unsigned long) =
            (bool (*)(id, SEL, unsigned long))(void *)objc_msgSend;
        // NSApplicationActivateAllWindows | IgnoringOtherApps. Keep these
        // public stable bit values local to avoid importing AppKit's umbrella
        // headers, which conflict with Theos's legacy IOKit vendor headers.
        return activate(application, sel_registerName("activateWithOptions:"),
                        (1ul << 0) | (1ul << 1));
    }
}

static int32_t ActivateFrontProcess(pid_t pid) {
    static bool attempted;
    static void *applicationServices;
    static MacWSGetProcessForPIDFn getProcessForPID;
    static MacWSSetFrontProcessWithOptionsFn setFrontProcessWithOptions;
    if (!attempted) {
        attempted = true;
        getProcessForPID = (MacWSGetProcessForPIDFn)dlsym(
            RTLD_DEFAULT, "GetProcessForPID");
        setFrontProcessWithOptions =
            (MacWSSetFrontProcessWithOptionsFn)dlsym(
                RTLD_DEFAULT, "SetFrontProcessWithOptions");
        if (!getProcessForPID || !setFrontProcessWithOptions) {
            applicationServices = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/"
                "ApplicationServices", RTLD_LAZY | RTLD_LOCAL);
            if (applicationServices) {
                getProcessForPID = (MacWSGetProcessForPIDFn)dlsym(
                    applicationServices, "GetProcessForPID");
                setFrontProcessWithOptions =
                    (MacWSSetFrontProcessWithOptionsFn)dlsym(
                        applicationServices, "SetFrontProcessWithOptions");
            }
        }
    }
    if (!getProcessForPID || !setFrontProcessWithOptions) return INT32_MIN;
    MacWSProcessSerialNumber process = {0};
    int32_t status = getProcessForPID(pid, &process);
    if (status != 0) return status;
    return setFrontProcessWithOptions(&process, (1u << 0) | (1u << 1));
}

// RE-confirmed against macOS 13.4 SkyLight:
// _SLSCopyWindowRoutingRecordsForScreenLocation at 0x18519cf58 sends the
// queried Quartz point to WindowServer and returns the server's routing
// property list; _SLSConnectionGetPID at 0x18536a2bc resolves each returned
// connection ID to its owning process. Runtime captures on 2026-08-02 proved
// that this distinguishes Finder's desktop, the active application's menu
// bar, ControlCenter status items, Dock, and ordinary AppKit windows even when
// Dock also owns a transparent full-display layer. Use the last valid routing
// record because it is the deepest destination in a nested routing chain.
static MacWSWindowTarget WindowServerRoutingTargetAtPoint(CGPoint point) {
    MacWSWindowTarget target = {0};
    MacWSSkyLightRoutingAPI api = SkyLightRoutingAPI();
    if (!api.mainConnectionID || !api.copyRoutingRecords ||
        !api.connectionGetPID) return target;

    SLSConnectionID queryingConnection = api.mainConnectionID();
    if (!queryingConnection) return target;
    CFDictionaryRef response = api.copyRoutingRecords(queryingConnection,
                                                       point);
    if (!response || CFGetTypeID(response) != CFDictionaryGetTypeID()) {
        if (response) CFRelease(response);
        return target;
    }

    int32_t windowID = 0;
    CFNumberRef windowValue = (CFNumberRef)CFDictionaryGetValue(
        response, CFSTR("WindowID"));
    if (windowValue &&
        CFGetTypeID(windowValue) == CFNumberGetTypeID()) {
        (void)CFNumberGetValue(windowValue, kCFNumberSInt32Type, &windowID);
    }

    CFArrayRef records = (CFArrayRef)CFDictionaryGetValue(
        response, CFSTR("Routing Records"));
    if (records && CFGetTypeID(records) == CFArrayGetTypeID()) {
        for (CFIndex index = CFArrayGetCount(records); index > 0; index--) {
            CFTypeRef value = CFArrayGetValueAtIndex(records, index - 1);
            if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID())
                continue;
            CFDictionaryRef record = (CFDictionaryRef)value;
            CFNumberRef connectionValue =
                (CFNumberRef)CFDictionaryGetValue(
                    record, CFSTR("Connection ID"));
            int32_t rawConnection = 0;
            if (!connectionValue ||
                CFGetTypeID(connectionValue) != CFNumberGetTypeID() ||
                !CFNumberGetValue(connectionValue, kCFNumberSInt32Type,
                                  &rawConnection) ||
                rawConnection <= 0) {
                continue;
            }
            pid_t pid = 0;
            if (api.connectionGetPID((SLSConnectionID)rawConnection, &pid) !=
                    0 ||
                pid <= 1 || pid == getpid()) {
                continue;
            }
            target.pid = pid;
            target.windowID = windowID;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                        "MACWS-INPUT SLS-ROUTE point=(%.2f,%.2f) "
                        "connection=%u pid=%d window=%d depth=%ld/%ld\n",
                        point.x, point.y, (unsigned)rawConnection, pid,
                        windowID, (long)index,
                        (long)CFArrayGetCount(records));
                fflush(stderr);
            }
            break;
        }
    }
    CFRelease(response);
    return target;
}

// Final-composite presentation deliberately retires duplicate Dock capture
// surfaces after their pixels have been folded into WindowServer's completed
// desktop.  A fullscreen Host can therefore send a zero-target hardware-style
// pointer record even though the live SLS route below resolves that point to
// Dock.  Preserve the same GlobalSystemSurface contract used by a retained
// displayd descriptor, but derive it from WindowServer's exact window/PID
// tuple rather than guessing a process name from an unrelated process list.
static bool WindowTargetIsDockSystemSurface(MacWSWindowTarget target) {
    if (target.pid <= 1 || target.windowID <= 0) return false;
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        MacWSCGWindowListOptionOnScreenOnly, 0);
    if (!windows || CFGetTypeID(windows) != CFArrayGetTypeID()) {
        if (windows) CFRelease(windows);
        return false;
    }
    bool matches = false;
    for (CFIndex index = 0; index < CFArrayGetCount(windows); index++) {
        CFTypeRef value = CFArrayGetValueAtIndex(windows, index);
        if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef window = (CFDictionaryRef)value;
        CFNumberRef number = (CFNumberRef)CFDictionaryGetValue(
            window, kCGWindowNumber);
        CFNumberRef ownerPID = (CFNumberRef)CFDictionaryGetValue(
            window, kCGWindowOwnerPID);
        CFStringRef ownerName = (CFStringRef)CFDictionaryGetValue(
            window, kCGWindowOwnerName);
        int32_t windowID = 0;
        int32_t pid = 0;
        if (number && ownerPID && ownerName &&
            CFGetTypeID(number) == CFNumberGetTypeID() &&
            CFGetTypeID(ownerPID) == CFNumberGetTypeID() &&
            CFGetTypeID(ownerName) == CFStringGetTypeID() &&
            CFNumberGetValue(number, kCFNumberSInt32Type, &windowID) &&
            CFNumberGetValue(ownerPID, kCFNumberSInt32Type, &pid) &&
            windowID == target.windowID && pid == target.pid &&
            CFStringCompare(ownerName, CFSTR("Dock"), 0) ==
                kCFCompareEqualTo) {
            matches = true;
            break;
        }
    }
    CFRelease(windows);
    return matches;
}

// CGEventPost(kCGHIDEventTap) updates only the posting process's cursor state
// in this chroot. The WindowServer routing query above is the authoritative
// path. Retain the public window-list scan solely as a compatibility fallback
// if the private symbols or routing response are unavailable on another OS.
// Window bounds and input points are both in Quartz logical coordinates.
static MacWSWindowTarget WindowListFallbackTargetAtPoint(CGPoint point) {
    MacWSWindowTarget target = {0};
    static unsigned probeCount;
    bool logProbe = RuntimeDiagnosticsEnabled() && probeCount++ < 2;
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        MacWSCGWindowListOptionOnScreenOnly |
            MacWSCGWindowListExcludeDesktopElements,
        0);
    if (!windows) {
        if (logProbe) {
            fprintf(stderr,
                    "MACWS-INPUT TARGET-LIST point=(%.2f,%.2f) result=NULL\n",
                    point.x, point.y);
            fflush(stderr);
        }
        return target;
    }

    CFIndex count = CFArrayGetCount(windows);
    if (logProbe) {
        fprintf(stderr,
                "MACWS-INPUT TARGET-LIST point=(%.2f,%.2f) count=%ld\n",
                point.x, point.y, (long)count);
    }
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(windows, i);
        CFNumberRef pidValue = (CFNumberRef)CFDictionaryGetValue(
            info, kCGWindowOwnerPID);
        CFNumberRef layerValue = (CFNumberRef)CFDictionaryGetValue(
            info, kCGWindowLayer);
        CFNumberRef windowValue = (CFNumberRef)CFDictionaryGetValue(
            info, kCGWindowNumber);
        CFStringRef ownerValue = (CFStringRef)CFDictionaryGetValue(
            info, kCGWindowOwnerName);
        CFDictionaryRef boundsValue = (CFDictionaryRef)CFDictionaryGetValue(
            info, kCGWindowBounds);
        int32_t pid = 0, layer = -1, windowID = 0;
        char ownerName[96] = {0};
        CGRect bounds = {{0, 0}, {0, 0}};
        bool decoded = pidValue && layerValue && windowValue && boundsValue &&
            CFNumberGetValue(pidValue, kCFNumberSInt32Type, &pid) &&
            CFNumberGetValue(layerValue, kCFNumberSInt32Type, &layer) &&
            CFNumberGetValue(windowValue, kCFNumberSInt32Type, &windowID) &&
            CGRectMakeWithDictionaryRepresentation(boundsValue, &bounds);
        if (ownerValue && CFGetTypeID(ownerValue) == CFStringGetTypeID()) {
            (void)CFStringGetCString(ownerValue, ownerName,
                                     sizeof(ownerName), kCFStringEncodingUTF8);
        }
        if (logProbe && i < 16) {
            fprintf(stderr,
                    "MACWS-INPUT TARGET-CANDIDATE index=%ld decoded=%s "
                    "pid=%d owner=%s layer=%d window=%d "
                    "bounds=(%.1f,%.1f %.1fx%.1f) contains=%s\n",
                    (long)i, decoded ? "YES" : "NO", pid,
                    ownerName[0] ? ownerName : "?", layer, windowID,
                    bounds.origin.x, bounds.origin.y,
                    bounds.size.width, bounds.size.height,
                    decoded && PointInRect(point, bounds) ? "YES" : "NO");
        }
        if (!decoded) {
            continue;
        }
        bool windowServerOwner = ownerValue &&
            CFGetTypeID(ownerValue) == CFStringGetTypeID() &&
            (CFEqual(ownerValue, CFSTR("WindowServer")) ||
             CFEqual(ownerValue, CFSTR("Window Server")));
        if (pid <= 1 || pid == getpid() || windowServerOwner || layer < 0 ||
            !PointInRect(point, bounds)) {
            continue;
        }
        target.pid = (pid_t)pid;
        target.windowID = windowID;
        break;
    }
    if (logProbe) fflush(stderr);
    CFRelease(windows);
    return target;
}

static MacWSWindowTarget WindowTargetAtPoint(CGPoint point) {
    MacWSWindowTarget target = WindowServerRoutingTargetAtPoint(point);
    if (target.pid > 1) return target;
    return WindowListFallbackTargetAtPoint(point);
}

static MacWSWindowTarget VisiblePopupMenuTarget(pid_t preferredPID) {
    MacWSWindowTarget target = {0};
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        MacWSCGWindowListOptionOnScreenOnly |
            MacWSCGWindowListExcludeDesktopElements,
        0);
    if (!windows) return target;
    const int32_t popupLevel =
        CGWindowLevelForKey(MacWSCGPopUpMenuWindowLevelKey);
    MacWSWindowTarget firstPopup = {0};
    for (CFIndex index = 0; index < CFArrayGetCount(windows); index++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(
            windows, index);
        CFNumberRef pidValue = (CFNumberRef)CFDictionaryGetValue(
            info, kCGWindowOwnerPID);
        CFNumberRef layerValue = (CFNumberRef)CFDictionaryGetValue(
            info, kCGWindowLayer);
        CFNumberRef windowValue = (CFNumberRef)CFDictionaryGetValue(
            info, kCGWindowNumber);
        CFDictionaryRef boundsValue = (CFDictionaryRef)CFDictionaryGetValue(
            info, kCGWindowBounds);
        int32_t ownerPID = 0, layer = 0, windowID = 0;
        CGRect bounds = {{0, 0}, {0, 0}};
        if (pidValue && layerValue && windowValue && boundsValue &&
            CFNumberGetValue(pidValue, kCFNumberSInt32Type, &ownerPID) &&
            CFNumberGetValue(layerValue, kCFNumberSInt32Type, &layer) &&
            CFNumberGetValue(windowValue, kCFNumberSInt32Type, &windowID) &&
            CGRectMakeWithDictionaryRepresentation(boundsValue, &bounds) &&
            ownerPID > 1 && windowID > 0 && layer >= popupLevel &&
            bounds.size.width > 0.0 && bounds.size.height > 0.0) {
            MacWSWindowTarget candidate = {
                .pid = (pid_t)ownerPID,
                .windowID = windowID,
            };
            if (firstPopup.pid <= 1) firstPopup = candidate;
            if (ownerPID == preferredPID) {
                target = candidate;
                break;
            }
        }
    }
    if (target.pid <= 1) target = firstPopup;
    CFRelease(windows);
    return target;
}

static uint64_t RealtimeNanoseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static uint64_t MonotonicNanoseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static void SignalInteractionWake(void) {
    static int wakeFD = -1;
    if (wakeFD < 0) {
        wakeFD = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (wakeFD >= 0) {
            (void)fcntl(wakeFD, F_SETFD, FD_CLOEXEC);
            int flags = fcntl(wakeFD, F_GETFL, 0);
            if (flags >= 0) {
                (void)fcntl(wakeFD, F_SETFL, flags | O_NONBLOCK);
            }
        }
    }
    if (wakeFD < 0) return;

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    strlcpy(address.sun_path, MACWS_INTERACTION_WAKE_SOCKET_PATH,
            sizeof(address.sun_path));
    const uint8_t token = 1;
    if (sendto(wakeFD, &token, sizeof(token), MSG_DONTWAIT,
               (const struct sockaddr *)&address, sizeof(address)) < 0 &&
        (errno == EBADF || errno == ENOTSOCK)) {
        close(wakeFD);
        wakeFD = -1;
    }
}

// WindowServer's coexistence completion scaffold deliberately uses a slow
// static-desktop cadence to avoid holding native AGX hot. VNC
// already publishes this boot-relative activity witness, but the iPad-native
// Host used to leave it untouched, so a live touch/keyboard session remained
// stuck at the idle interval. Publish the same transport-neutral
// interaction timestamp from the central broker.  Writes are bounded to 120
// Hz and happen before target probing, so even the first click selects the
// 16.667-ms interactive interval at WindowServer's next SwapEnd boundary.
static void NoteUserInteraction(void) {
    static int activityFD = -1;
    static uint64_t lastWriteNanoseconds = 0;
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return;
    uint64_t nanoseconds = (uint64_t)now.tv_sec * 1000000000ull +
        (uint64_t)now.tv_nsec;
    const uint64_t minimumInterval = 8ull * 1000000ull;
    if (lastWriteNanoseconds != 0 && nanoseconds > lastWriteNanoseconds &&
        nanoseconds - lastWriteNanoseconds < minimumInterval) return;
    lastWriteNanoseconds = nanoseconds;

    if (activityFD < 0) {
        activityFD = open("/private/tmp/macws_vnc_activity",
                          O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    }
    if (activityFD >= 0 &&
        pwrite(activityFD, &nanoseconds, sizeof(nanoseconds), 0) !=
            (ssize_t)sizeof(nanoseconds)) {
        close(activityFD);
        activityFD = -1;
    }
    SignalInteractionWake();
}

static void SendInputAcknowledgement(
        int socketFD, const struct sockaddr_un *sender,
        socklen_t senderLength, const MacWSInputRecord *record,
        uint32_t flags) {
    if (!sender || !record || senderLength <= sizeof(sa_family_t) ||
        sender->sun_family != AF_UNIX || sender->sun_path[0] == '\0' ||
        record->source != MacWSInputSourceVNC ||
        record->sampleSequence == 0) return;
    MacWSInputAck acknowledgement = {
        .magic = MACWS_INPUT_ACK_MAGIC,
        .version = MACWS_INPUT_ACK_VERSION,
        .size = sizeof(MacWSInputAck),
        .sampleSequence = record->sampleSequence,
        .flags = flags,
    };
    (void)sendto(socketFD, &acknowledgement, sizeof(acknowledgement),
                 MSG_DONTWAIT, (const struct sockaddr *)sender,
                 senderLength);
}

static bool SendToAppInputBridge(int socketFD,
                                 const MacWSInputRecord *record,
                                 int *errorOut) {
    if (record->targetPID <= 1) {
        if (errorOut) *errorOut = EDESTADDRREQ;
        return false;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    int length = snprintf(address.sun_path, sizeof(address.sun_path),
                          "/private/tmp/macws_app_input.%d.sock",
                          record->targetPID);
    if (length <= 0 || (size_t)length >= sizeof(address.sun_path)) {
        if (errorOut) *errorOut = ENAMETOOLONG;
        return false;
    }
    bool continuous = record->kind == MacWSInputKindTouchMove ||
                      record->kind == MacWSInputKindHover ||
                      record->kind == MacWSInputKindMenuHover ||
                      (record->kind == MacWSInputKindScroll &&
                       (record->flags & MacWSInputFlagScrollChanged)) ||
                      (record->kind == MacWSInputKindMagnify &&
                       (record->flags & MacWSInputFlagGestureChanged)) ||
                      (record->kind == MacWSInputKindRotate &&
                       (record->flags & MacWSInputFlagGestureChanged)) ||
                      (record->kind == MacWSInputKindSystemGesture &&
                       (record->flags & MacWSInputFlagGestureChanged));
    unsigned attempts = continuous ? 1 : 2;
    ssize_t sent = -1;
    int savedError = 0;
    for (unsigned attempt = 0; attempt < attempts; attempt++) {
        sent = sendto(socketFD, record, sizeof(*record), MSG_DONTWAIT,
                      (const struct sockaddr *)&address, sizeof(address));
        if (sent == (ssize_t)sizeof(*record)) break;
        savedError = sent < 0 ? errno : EMSGSIZE;
        if (continuous || (savedError != EAGAIN && savedError != ENOBUFS) ||
            attempt + 1 >= attempts) break;
        // A transition must not sit behind a 1+2+...+8 ms blind retry loop.
        // Wait once for actual socket writability, bounded to 2 ms, then retry.
        struct pollfd descriptor = {.fd = socketFD, .events = POLLOUT};
        if (poll(&descriptor, 1, 2) <= 0) break;
    }
    if (errorOut) *errorOut = sent == (ssize_t)sizeof(*record)
        ? 0 : savedError;
    return sent == (ssize_t)sizeof(*record);
}

// A zero-window fullscreen pointer belongs to WindowServer's current global
// presentation, not to the NSWindow whose pre-Mission-Control pixels happen
// to occupy that point. The installed OSXvnc process is the only runtime-
// proven producer that completes Dock's cross-Space window drag. Forward the
// already-validated wire record to its root-only local endpoint and keep the
// complete down/move/up transaction on that single system owner. If the
// endpoint is absent during an upgrade or restart, the caller retains the
// existing Dock/AppInput fallback rather than dropping input.
static bool SendToVNCPointerProxy(int socketFD,
                                  const MacWSInputRecord *record,
                                  int *errorOut) {
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, MACWS_VNC_POINTER_PROXY_SOCKET_PATH,
            sizeof(address.sun_path));
    bool continuous = record->kind == MacWSInputKindTouchMove ||
                      record->kind == MacWSInputKindHover ||
                      record->kind == MacWSInputKindMenuHover ||
                      (record->kind == MacWSInputKindScroll &&
                       (record->flags & MacWSInputFlagScrollChanged));
    unsigned attempts = continuous ? 1 : 2;
    ssize_t sent = -1;
    int savedError = 0;
    for (unsigned attempt = 0; attempt < attempts; attempt++) {
        sent = sendto(socketFD, record, sizeof(*record), MSG_DONTWAIT,
                      (const struct sockaddr *)&address, sizeof(address));
        if (sent == (ssize_t)sizeof(*record)) break;
        savedError = sent < 0 ? errno : EMSGSIZE;
        if (continuous || (savedError != EAGAIN && savedError != ENOBUFS) ||
            attempt + 1 >= attempts) break;
        struct pollfd descriptor = {.fd = socketFD, .events = POLLOUT};
        if (poll(&descriptor, 1, 2) <= 0) break;
    }
    if (errorOut) *errorOut = sent == (ssize_t)sizeof(*record)
        ? 0 : savedError;
    return sent == (ssize_t)sizeof(*record);
}

static size_t AppInputBridgePIDs(pid_t *pids, size_t capacity);

// The normal Workspace activation broadcast is absent in the chroot. A real
// native click can consequently leave both the old and new NSApplication
// reporting isActive=YES; runtime target replies then become ambiguous and the
// visible global menu bar remains owned by the old app. Send control records,
// never NSEvents, to make every non-target endpoint resign before the selected
// endpoint receives its matching activation control.
static size_t DeactivateOtherAppInputBridges(
        int socketFD, pid_t targetPID, const MacWSInputRecord *source) {
    pid_t pids[64] = {0};
    size_t discovered = AppInputBridgePIDs(pids, 64);
    size_t count = discovered < 64 ? discovered : 64;
    size_t sentCount = 0;
    for (size_t index = 0; index < count; index++) {
        if (pids[index] <= 1 || pids[index] == targetPID) continue;
        MacWSInputRecord control = *source;
        control.kind = MacWSInputKindDeactivateApplication;
        control.targetPID = pids[index];
        int error = 0;
        bool sent = SendToAppInputBridge(socketFD, &control, &error);
        if (sent) sentCount++;
        else fprintf(stderr,
                "MACWS-INPUT ACTIVATE deactivate-send pid=%d errno=%d\n",
                pids[index], error);
    }
    return sentCount;
}

static size_t AppInputBridgePIDs(pid_t *pids, size_t capacity) {
    static const char prefix[] = "macws_app_input.";
    static const char suffix[] = ".sock";
    DIR *directory = opendir("/private/tmp");
    if (!directory) return 0;
    size_t matches = 0;
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        const char *name = entry->d_name;
        size_t length = strlen(name);
        size_t prefixLength = sizeof(prefix) - 1;
        size_t suffixLength = sizeof(suffix) - 1;
        if (length <= prefixLength + suffixLength ||
            strncmp(name, prefix, prefixLength) != 0 ||
            strcmp(name + length - suffixLength, suffix) != 0) {
            continue;
        }
        char *end = NULL;
        long parsed = strtol(name + prefixLength, &end, 10);
        if (!end || strcmp(end, suffix) != 0 || parsed <= 1 ||
            parsed > INT32_MAX || kill((pid_t)parsed, 0) != 0) {
            continue;
        }
        if (matches < capacity) pids[matches] = (pid_t)parsed;
        matches++;
    }
    closedir(directory);
    return matches;
}

// Runtime-confirmed on the chroot launchd session: CGWindowListCopyWindowInfo
// returns NULL even though an AppInputBridge socket is live. When there is
// exactly one healthy AppKit endpoint, it remains an unambiguous fallback.
static pid_t SoleAppInputBridgePID(void) {
    pid_t pids[2] = {0};
    return AppInputBridgePIDs(pids, 2) == 1 ? pids[0] : 0;
}

static bool PIDInList(pid_t pid, const pid_t *pids, size_t count) {
    for (size_t index = 0; index < count; index++) {
        if (pids[index] == pid) return true;
    }
    return false;
}

// A DisplayStream system-surface descriptor is useful even when this
// launchd session cannot ask WindowServer for a routing record.  Validate the
// process-local receiver itself before using that descriptor as the bounded
// fallback: this rejects exited/reused owners without turning an unavailable
// SkyLight query into a false routing mismatch.
static bool AppInputBridgeEndpointExists(pid_t pid) {
    if (pid <= 1 || kill(pid, 0) != 0) return false;
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    int length = snprintf(path, sizeof(path),
                          "/private/tmp/macws_app_input.%d.sock", pid);
    return length > 0 && (size_t)length < sizeof(path) &&
           access(path, F_OK) == 0;
}

// Ask every live AppKit process to hit-test on its own main thread, then send
// the real event only to the unique best reply. This is a query broadcast,
// not an event broadcast: probes cannot create NSEvents. Active/key state
// disambiguates overlapping windows; equal-ranked overlaps remain unresolved
// rather than delivering one click to multiple applications.
static MacWSWindowTarget ProbeAppInputTarget(
        int targetSocketFD, const MacWSInputRecord *record) {
    MacWSWindowTarget target = {0};
    MacWSWindowTarget activeTarget = {0};
    MacWSWindowTarget frontTarget = {0};
    if (targetSocketFD < 0 || record->frameWidth == 0 ||
        record->frameHeight == 0) return target;

    pid_t pids[64] = {0};
    size_t discovered = AppInputBridgePIDs(pids, 64);
    size_t pidCount = discovered < 64 ? discovered : 64;
    if (pidCount == 0) return target;

    // Replies from a timed-out older probe must not influence this decision.
    MacWSInputTargetReply stale;
    while (recv(targetSocketFD, &stale, sizeof(stale), MSG_DONTWAIT) > 0) {}

    uint64_t nonce = ++TargetProbeNonce;
    if (nonce == 0) nonce = ++TargetProbeNonce;
    MacWSInputTargetProbe probe = {
        .magic = MACWS_TARGET_PROBE_MAGIC,
        .version = MACWS_TARGET_VERSION,
        .size = sizeof(MacWSInputTargetProbe),
        .nonce = nonce,
        .x = record->x,
        .y = record->y,
        .frameWidth = record->frameWidth,
        .frameHeight = record->frameHeight,
    };

    size_t sentCount = 0;
    for (size_t index = 0; index < pidCount; index++) {
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        int length = snprintf(address.sun_path, sizeof(address.sun_path),
                              "/private/tmp/macws_app_input.%d.sock",
                              pids[index]);
        if (length <= 0 || (size_t)length >= sizeof(address.sun_path)) continue;
        ssize_t sent = sendto(targetSocketFD, &probe, sizeof(probe),
                              MSG_DONTWAIT,
                              (const struct sockaddr *)&address,
                              sizeof(address));
        if (sent == (ssize_t)sizeof(probe)) sentCount++;
    }
    if (sentCount == 0) return target;

    uint64_t deadline = RealtimeNanoseconds() + 150000000ull;
    size_t replies = 0;
    int bestScore = -1;
    bool ambiguous = false;
    bool activeAmbiguous = false;
    bool frontAmbiguous = false;
    while (replies < sentCount) {
        uint64_t now = RealtimeNanoseconds();
        if (now >= deadline) break;
        int remainingMilliseconds = (int)((deadline - now + 999999ull) /
                                          1000000ull);
        struct pollfd descriptor = {
            .fd = targetSocketFD,
            .events = POLLIN,
        };
        int pollResult = poll(&descriptor, 1, remainingMilliseconds);
        if (pollResult <= 0) break;
        MacWSInputTargetReply reply = {0};
        ssize_t received = recv(targetSocketFD, &reply, sizeof(reply), 0);
        if (received != sizeof(reply) ||
            reply.magic != MACWS_TARGET_REPLY_MAGIC ||
            reply.version != MACWS_TARGET_VERSION ||
            reply.size != sizeof(MacWSInputTargetReply) ||
            reply.nonce != nonce || reply.pid <= 1 ||
            !PIDInList((pid_t)reply.pid, pids, pidCount)) {
            continue;
        }
        replies++;
        static unsigned replyLogs;
        if (RuntimeDiagnosticsEnabled() && replyLogs++ < 48) {
            fprintf(stderr,
                    "MACWS-INPUT TARGET-REPLY nonce=%llu pid=%d window=%d "
                    "flags=%#x\n",
                    (unsigned long long)nonce, reply.pid,
                    reply.windowNumber, reply.flags);
        }
        if (reply.flags & MacWSInputTargetApplicationActive) {
            if (activeTarget.pid <= 1) {
                activeTarget.pid = (pid_t)reply.pid;
                activeTarget.windowID = reply.windowNumber;
                activeTarget.selectedWasActive = true;
                activeTarget.selectedWasFrontUIProcess =
                    (reply.flags & MacWSInputTargetFrontUIProcess) != 0;
            } else if (activeTarget.pid != reply.pid) {
                activeAmbiguous = true;
            }
        }
        if (reply.flags & MacWSInputTargetFrontUIProcess) {
            if (frontTarget.pid <= 1) {
                frontTarget.pid = (pid_t)reply.pid;
                frontTarget.windowID = reply.windowNumber;
                frontTarget.selectedWasActive =
                    (reply.flags & MacWSInputTargetApplicationActive) != 0;
                frontTarget.selectedWasFrontUIProcess = true;
            } else if (frontTarget.pid != reply.pid) {
                frontAmbiguous = true;
            }
        }
        if (!(reply.flags & MacWSInputTargetHit)) continue;
        int score = 0;
        if (reply.flags & MacWSInputTargetFrontUIProcess) score += 4;
        if (reply.flags & MacWSInputTargetApplicationActive) score += 2;
        if (reply.flags & MacWSInputTargetKeyWindow) score += 1;
        if (score > bestScore) {
            bestScore = score;
            target.pid = (pid_t)reply.pid;
            target.windowID = reply.windowNumber;
            target.selectedWasActive =
                (reply.flags & MacWSInputTargetApplicationActive) != 0;
            target.selectedWasFrontUIProcess =
                (reply.flags & MacWSInputTargetFrontUIProcess) != 0;
            ambiguous = false;
        } else if (score == bestScore && target.pid != reply.pid) {
            ambiguous = true;
        }
    }
    // If an endpoint missed the deadline, only an active application's hit is
    // authoritative. Otherwise a responsive covered app could steal a click
    // from an unresponsive front app.
    if (ambiguous || (replies < sentCount && bestScore < 2))
        target = (MacWSWindowTarget){0};
    // Menu-bar and contextual-menu presentation surfaces are not ordinary
    // ordered NSWindows.  Use the unique application whose real AppKit state
    // reports active when no authoritative window hit exists.  Ordinary
    // click/down routing retains the stricter hit rule; the sole exception is
    // an ActivateTarget control in the physical top 4% of the framebuffer.
    // Runtime evidence at 2388x1668 showed the native menu-bar down at y=20
    // returning no hit from either AppKit endpoint and being dropped as PID 0,
    // even though Terminal was the unique active owner.  This control record
    // carries no NSEvent and therefore only repairs ownership; OSXvnc still
    // delivers the real native menu click.
    bool systemMenuActivation =
        record->kind == MacWSInputKindActivateTarget &&
        record->frameHeight > 0 &&
        record->y >= 0.0f &&
        record->y <= (float)record->frameHeight * 0.04f;
    bool allowActiveFallback =
        record->kind == MacWSInputKindTargetProbe ||
        record->kind == MacWSInputKindHover ||
        record->kind == MacWSInputKindMenuHover ||
        record->kind == MacWSInputKindKeyDown ||
        record->kind == MacWSInputKindKeyUp ||
        record->kind == MacWSInputKindScroll ||
        record->kind == MacWSInputKindMagnify ||
        record->kind == MacWSInputKindRotate ||
        record->kind == MacWSInputKindDesktopCommand ||
        systemMenuActivation;
    if (target.pid <= 1 && allowActiveFallback) {
        if (!frontAmbiguous && frontTarget.pid > 1) {
            target = frontTarget;
        } else if (!activeAmbiguous && activeTarget.pid > 1) {
            target = activeTarget;
        }
    }
    if (target.pid > 1) {
        target.competingActiveOwner = activeAmbiguous;
        // A native click may make the hit application active before a covered
        // application drains its main-thread target probe.  Runtime evidence
        // from a Terminal-over-GlassDemo switch showed nonce 1 receiving only
        // Terminal within the bounded 150-ms probe, followed immediately by
        // nonce 2 receiving both endpoints and reporting two active owners.
        // Treat an unanswered live endpoint as unresolved activation state;
        // the activation transaction will resign every non-target endpoint
        // and rebuild the selected application's real AppKit lifecycle.
        target.responseIncomplete = replies < sentCount;
    }
    static unsigned resultLogs;
    if (RuntimeDiagnosticsEnabled() && resultLogs++ < 32) {
        fprintf(stderr,
                "MACWS-INPUT TARGET-PROBE nonce=%llu endpoints=%zu sent=%zu "
                "replies=%zu selected=%d window=%d score=%d "
                "selected-active=%s selected-front=%s "
                "competing-active=%s incomplete=%s ambiguous=%s "
                "system-menu=%s\n",
                (unsigned long long)nonce, pidCount, sentCount, replies,
                target.pid, target.windowID, bestScore,
                target.selectedWasActive ? "YES" : "NO",
                target.selectedWasFrontUIProcess ? "YES" : "NO",
                target.competingActiveOwner ? "YES" : "NO",
                target.responseIncomplete ? "YES" : "NO",
                (ambiguous || activeAmbiguous || frontAmbiguous)
                    ? "YES" : "NO",
                systemMenuActivation ? "YES" : "NO");
        fflush(stderr);
    }
    return target;
}

// Compatibility fallback for systems where SkyLight's routing-record API is
// unavailable.  A target probe runs on every application's main thread, so it
// must not be the primary click path: an application doing synchronous layout,
// menu tracking, or first-run work cannot reply inside the bounded deadline.
// Retry only this fallback; periodic hover probes must never activate an app.
static MacWSWindowTarget ProbeActivationTarget(
        int targetSocketFD, const MacWSInputRecord *record) {
    MacWSWindowTarget first = ProbeAppInputTarget(targetSocketFD, record);
    if (first.pid > 1 && !first.responseIncomplete) return first;

    usleep(10000);
    MacWSWindowTarget second = ProbeAppInputTarget(targetSocketFD, record);
    if (second.pid > 1) {
        if (RuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "MACWS-INPUT ACTIVATE-PROBE-RETRY first=%d incomplete=%s "
                "second=%d competing=%s\n",
                first.pid, first.responseIncomplete ? "YES" : "NO",
                second.pid,
                second.competingActiveOwner ? "YES" : "NO");
        fflush(stderr);
        }
        return second;
    }
    if (first.pid > 1) {
        if (RuntimeDiagnosticsEnabled()) {
        fprintf(stderr,
                "MACWS-INPUT ACTIVATE-PROBE-RETRY first=%d incomplete=%s "
                "second=0 preserve-first=YES\n",
                first.pid, first.responseIncomplete ? "YES" : "NO");
        fflush(stderr);
        }
        return first;
    }
    return second;
}

// Arm one diagnostic capture for a completed gesture. Continuous PF80/PF115
// publication is responsible for live hover/drag feedback; creating/truncating
// this control file for every pointer sample previously forced up to five full
// 2388x1668 PF550 observations per second in addition to ordinary compositing.
// This remains a request for observation only: WindowServer must ACK the exact
// generation after publishing a real frame.
static uint64_t ArmCaptureForInput(const MacWSInputRecord *record) {
    // This file drives an expensive compositor observation path. Production
    // DisplayStream delivery already publishes completed IOSurfaces and must
    // not request another full-frame observation for every click/release.
    // Metal_hooks.x:2807-2817 records the runtime-confirmed PF550 instability
    // caused by an ordinary input creating this request. Keep it strictly as
    // an opt-in diagnostic witness.
    if (!RuntimeDiagnosticsEnabled()) return 0;
    if (record->kind != MacWSInputKindTouchUp &&
        record->kind != MacWSInputKindTouchCancel &&
        record->kind != MacWSInputKindTap) {
        return 0;
    }
    uint64_t generation = RealtimeNanoseconds();
    if (generation == 0) return 0;
    if (generation <= LastCaptureGeneration)
        generation = LastCaptureGeneration + 1;

    char value[48];
    int length = snprintf(value, sizeof(value), "%llu\n",
                          (unsigned long long)generation);
    int fd = open(CaptureRequestPath,
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return 0;
    ssize_t written = write(fd, value, (size_t)length);
    close(fd);
    if (written != length) {
        unlink(CaptureRequestPath);
        return 0;
    }
    LastCaptureGeneration = generation;
    return generation;
}

int main(void) {
    signal(SIGINT, HandleSignal);
    signal(SIGTERM, HandleSignal);

    int lockFD = open(InputLockPath, O_CREAT | O_RDWR, 0600);
    if (lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) < 0) {
        fprintf(stderr, "macwsinputd singleton lock %s failed: %s\n",
                InputLockPath, strerror(errno));
        if (lockFD >= 0) close(lockFD);
        return 1;
    }

    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socketFD < 0) {
        fprintf(stderr, "macwsinputd socket failed: %s\n", strerror(errno));
        close(lockFD);
        return 1;
    }
    InputSocketFD = socketFD;
    int inputReceiveBuffer = 512 * 1024;
    (void)setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF,
                     &inputReceiveBuffer, sizeof(inputReceiveBuffer));

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    _Static_assert(sizeof(InputSocketPath) <= sizeof(address.sun_path),
                   "input socket path exceeds sockaddr_un.sun_path");
    memcpy(address.sun_path, InputSocketPath, sizeof(InputSocketPath));
    unlink(InputSocketPath);
    if (bind(socketFD, (const struct sockaddr *)&address, sizeof(address)) < 0) {
        fprintf(stderr, "macwsinputd bind %s failed: %s\n",
                InputSocketPath, strerror(errno));
        close(socketFD);
        close(lockFD);
        return 2;
    }
    if (chmod(InputSocketPath, 0666) < 0) {
        fprintf(stderr, "macwsinputd chmod %s failed: %s\n",
                InputSocketPath, strerror(errno));
    }

    int targetSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (targetSocketFD >= 0) {
        struct sockaddr_un targetAddress = {0};
        targetAddress.sun_family = AF_UNIX;
        memcpy(targetAddress.sun_path, TargetSocketPath,
               sizeof(TargetSocketPath));
        unlink(TargetSocketPath);
        if (bind(targetSocketFD,
                 (const struct sockaddr *)&targetAddress,
                 sizeof(targetAddress)) < 0) {
            fprintf(stderr, "macwsinputd bind %s failed: %s\n",
                    TargetSocketPath, strerror(errno));
            close(targetSocketFD);
            targetSocketFD = -1;
        } else if (chmod(TargetSocketPath, 0666) < 0) {
            fprintf(stderr, "macwsinputd chmod %s failed: %s\n",
                    TargetSocketPath, strerror(errno));
        }
    } else {
        fprintf(stderr, "macwsinputd target socket failed: %s\n",
                strerror(errno));
    }
    TargetSocketFD = targetSocketFD;

    CGDirectDisplayID display;
    CGRect bounds;
    size_t pixelWidth;
    size_t pixelHeight;
    ReadDisplayGeometry(&display, &bounds, &pixelWidth, &pixelHeight);
    fprintf(stderr,
            "MACWS-INPUT READY socket=%s abi=%u-%u record=%zu display=%u "
            "bounds=(%.0f,%.0f %.0fx%.0f) pixels=%zux%zu postAccess=%s "
            "targetSocket=%s\n",
            InputSocketPath, MACWS_INPUT_LEGACY_VERSION,
            MACWS_INPUT_VERSION, sizeof(MacWSInputRecord),
            display, bounds.origin.x, bounds.origin.y,
            bounds.size.width, bounds.size.height, pixelWidth, pixelHeight,
            CGPreflightPostEventAccess() ? "YES" : "NO",
            targetSocketFD >= 0 ? "READY" : "UNAVAILABLE");
    fflush(stderr);

    uint64_t sequence = 0;
    bool buttonDown = false;
    MacWSWindowTarget gestureTarget = {0};
    MacWSWindowTarget hoverTarget = {0};
    // A native menu enters a synchronous event loop in the selected process,
    // so later target probes cannot be serviced until the menu closes.  Keep
    // the authoritative target resolved for the real button-down; OSXvnc only
    // emits MenuHover during its bounded native-menu candidate lifetime.
    MacWSWindowTarget menuTarget = {0};
    // A contextual menu owns the next primary tap even when that tap lies
    // outside its visible bounds. WindowServer correctly reports the window
    // underneath that point, but treating that expected mismatch as a stale
    // layer drops the cancellation before the native menu tracker sees it.
    // Arm one bounded capture only after a secondary tap was successfully
    // delivered to a verified global-system endpoint.
    MacWSWindowTarget globalSystemMenuCaptureTarget = {0};
    uint64_t globalSystemMenuCaptureDeadline = 0;
    while (!StopRequested) {
        MacWSInputRecord record = {0};
        struct sockaddr_un sender = {0};
        socklen_t senderLength = sizeof(sender);
        ssize_t received = recvfrom(socketFD, &record, sizeof(record), 0,
                                    (struct sockaddr *)&sender,
                                    &senderLength);
        if (received < 0) {
            // SIGTERM closes InputSocketFD to wake this blocking recv.  EBADF
            // is the expected half of that shutdown handshake, not a receiver
            // failure worth surfacing to the App's diagnostics.
            if (StopRequested || errno == EBADF) break;
            if (errno == EINTR) continue;
            fprintf(stderr, "MACWS-INPUT recv failed: %s\n", strerror(errno));
            break;
        }
        if (received != (ssize_t)sizeof(record) || !RecordIsValid(&record)) {
            fprintf(stderr,
                    "MACWS-INPUT REJECT bytes=%zd magic=%#x version=%u "
                    "kind=%u point=(%.3f,%.3f) frame=%ux%u target=%d "
                    "source=%u flags=%#x buttons=%u contact=%u "
                    "pressure=%.6f altitude=%.6f azimuth=%.6f "
                    "tilt=(%.6f,%.6f) finite=%s\n",
                    received, record.magic, record.version, record.kind,
                    record.x, record.y, record.frameWidth,
                    record.frameHeight, record.targetPID, record.source,
                    record.flags, record.buttons, record.contactID,
                    record.pressure, record.altitude, record.azimuth,
                    record.tiltX, record.tiltY,
                    (isfinite(record.x) && isfinite(record.y))
                        ? "YES" : "NO");
            fflush(stderr);
            continue;
        }

        // Normalize before any direct or derived AppInput delivery.  Old
        // ABI-5 AppKit/Dock endpoints remain alive across package installs;
        // all legacy kinds have the same 84-byte layout and are deliberately
        // emitted as v5 so a new broker can talk to either endpoint revision.
        record.version = MacWSInputWireVersionForKind(record.kind);

        // State release must not depend on an app, a focused window or a live
        // framebuffer. UIKit can retire all three before delivering key-up.
        if (record.kind == MacWSInputKindModifierSnapshot) {
            int proxyError = 0;
            if (!SendToVNCPointerProxy(socketFD, &record, &proxyError))
                fprintf(stderr, "MACWS-INPUT MODIFIER-SNAPSHOT failed errno=%d\n", proxyError);
            continue;
        }
        if (record.kind == MacWSInputKindKeyUp &&
            IsNativeKeyboardProxyRecord(&record)) {
            int proxyError = 0;
            if (SendToVNCPointerProxy(socketFD, &record, &proxyError)) continue;
        }

        NoteUserInteraction();

        // Window configuration is an exact-PID control-plane transaction.
        // It has no Quartz point and must remain usable while WindowServer is
        // still publishing or reconfiguring display geometry.
        if (record.kind == MacWSInputKindConfigureWindow ||
            record.kind == MacWSInputKindCloseWindow ||
            record.kind == MacWSInputKindPerformQuit) {
            int appBridgeError = 0;
            bool appBridgeSent = SendToAppInputBridge(
                socketFD, &record, &appBridgeError);
            sequence++;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "MACWS-INPUT APP-CONTROL kind=%s seq=%llu target=%d "
                    "window=%u size=%.1fx%.1f density=%.2f sent=%s errno=%d\n",
                    KindName(record.kind),
                    (unsigned long long)sequence, record.targetPID,
                    MacWSInputWindowIDForScene(record.sceneID),
                    record.x, record.y, record.pressure,
                    appBridgeSent ? "YES" : "NO", appBridgeError);
                fflush(stderr);
            }
            continue;
        }

        // launchd can start this job before WindowServer has published its
        // display. Refresh on the first record, whenever geometry is zero,
        // and periodically so later display reconfiguration is not frozen.
        if (sequence == 0 || bounds.size.width <= 0.0 ||
            bounds.size.height <= 0.0 || (sequence % 120) == 0) {
            ReadDisplayGeometry(&display, &bounds, &pixelWidth, &pixelHeight);
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                        "MACWS-INPUT DISPLAY display=%u bounds=(%.0f,%.0f %.0fx%.0f) pixels=%zux%zu\n",
                        display, bounds.origin.x, bounds.origin.y,
                        bounds.size.width, bounds.size.height,
                        pixelWidth, pixelHeight);
                fflush(stderr);
            }
        }
        if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
            fprintf(stderr,
                    "MACWS-INPUT DROP reason=no-display scene=%llx kind=%s frame=(%.2f,%.2f)/%ux%u\n",
                    (unsigned long long)record.sceneID,
                    KindName((MacWSInputKind)record.kind), record.x, record.y,
                    record.frameWidth, record.frameHeight);
            fflush(stderr);
            continue;
        }

        CGPoint point = QuartzPointForRecord(&record, bounds);
        if (record.kind == MacWSInputKindTargetProbe) {
            // WindowServer already owns the authoritative routing chain.  A
            // broadcast probe made every ordinary RFB click wait as long as
            // 150 ms for unrelated applications whose main thread was busy,
            // and an unanswered covered application could erase an otherwise
            // exact visible hit.  Use the same SLS route as ActivateTarget;
            // retain the old main-thread query only for an unavailable API.
            hoverTarget = WindowTargetAtPoint(point);
            if (hoverTarget.pid <= 1) {
                hoverTarget = ProbeAppInputTarget(targetSocketFD, &record);
            }
            sequence++;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                        "MACWS-INPUT HOVER-OWNER seq=%llu pid=%d window=%d "
                        "frame=(%.2f,%.2f)/%ux%u quartz=(%.2f,%.2f)\n",
                        (unsigned long long)sequence,
                        hoverTarget.pid, hoverTarget.windowID,
                        record.x, record.y, record.frameWidth,
                        record.frameHeight, point.x, point.y);
                fflush(stderr);
            }
            continue;
        }
        CGEventType eventType = EventTypeForRecord(&record, &buttonDown);
        MacWSWindowTarget eventTarget = {0};
        bool armSystemMenuCapture = false;
        uint64_t monotonicNow = MonotonicNanoseconds();
        uint32_t exactWindowID = MacWSInputWindowIDForScene(record.sceneID);
        bool pendingGlobalMenuTap = record.kind == MacWSInputKindTap &&
            globalSystemMenuCaptureTarget.pid > 1 &&
            globalSystemMenuCaptureTarget.windowID > 0 &&
            monotonicNow != 0 &&
            monotonicNow <= globalSystemMenuCaptureDeadline;
        // A native popup menu's synchronous tracker owns the next primary
        // tap even when the tap is outside the popup and Host therefore hit-
        // tests a different underlying layer.  Confirm a real on-screen
        // kCGPopUpMenuWindowLevel window and use its current owner (Dock can
        // hand the menu to DockHelper) before transferring the tap.  This is
        // state-derived, not a timed blind capture, and prevents a dismissed
        // menu from stealing the user's next independent click.
        MacWSWindowTarget visiblePopupTarget = pendingGlobalMenuTap
            ? VisiblePopupMenuTarget(globalSystemMenuCaptureTarget.pid)
            : (MacWSWindowTarget){0};
        bool capturedGlobalMenuTap = visiblePopupTarget.pid > 1 &&
            visiblePopupTarget.windowID > 0;
        if (capturedGlobalMenuTap) {
            // Dock delegates its context menu to DockHelper, so the visible
            // popup's real connection can legitimately differ from the
            // process that received the initiating secondary click.  Route
            // to the live popup window itself; the CGWindow catalog is the
            // authoritative ownership handoff.
            globalSystemMenuCaptureTarget = visiblePopupTarget;
            exactWindowID = (uint32_t)globalSystemMenuCaptureTarget.windowID;
            record.targetPID = globalSystemMenuCaptureTarget.pid;
            record.flags |= MacWSInputFlagGlobalSystemSurface;
            record.sceneID = MacWSInputSceneForWindow(
                exactWindowID, MacWSInputModifiersForScene(record.sceneID));
        } else if (pendingGlobalMenuTap) {
            globalSystemMenuCaptureTarget = (MacWSWindowTarget){0};
            globalSystemMenuCaptureDeadline = 0;
        }
        bool exactWindowRecord = record.targetPID > 1 && exactWindowID != 0;
        bool globalSystemSurfaceRecord = exactWindowRecord &&
            (record.flags & MacWSInputFlagGlobalSystemSurface) != 0;
        bool fullscreenGlobalPointerRecord = record.targetPID > 1 &&
            exactWindowID == 0 &&
            (record.flags & MacWSInputFlagGlobalSystemSurface) != 0 &&
            (IsSystemPointerKind((MacWSInputKind)record.kind) ||
             record.kind == MacWSInputKindScroll);
        bool keyRecord = record.kind == MacWSInputKindKeyDown ||
                         record.kind == MacWSInputKindKeyUp;
        bool scrollRecord = record.kind == MacWSInputKindScroll;
        bool magnifyRecord = record.kind == MacWSInputKindMagnify;
        bool rotateRecord = record.kind == MacWSInputKindRotate;
        bool desktopCommandRecord =
            record.kind == MacWSInputKindDesktopCommand;
        bool systemGestureRecord =
            record.kind == MacWSInputKindSystemGesture;
        bool gestureRecord = scrollRecord || magnifyRecord || rotateRecord;
        bool nativeKeyboardProxyRecord = IsNativeKeyboardProxyRecord(&record);
        if (nativeKeyboardProxyRecord) {
            int proxyError = 0;
            bool proxySent = SendToVNCPointerProxy(
                socketFD, &record, &proxyError);
            if (proxySent) {
                sequence++;
                if (RuntimeDiagnosticsEnabled()) {
                    fprintf(stderr,
                        "MACWS-INPUT KEYBOARD-PROXY seq=%llu kind=%s "
                        "pid=%d window=%u keycode=%u keysym=%#x\n",
                        (unsigned long long)sequence,
                        KindName((MacWSInputKind)record.kind),
                        record.targetPID, exactWindowID,
                        (unsigned)llround(record.pressure), record.contactID);
                    fflush(stderr);
                }
                continue;
            }
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "MACWS-INPUT KEYBOARD-PROXY kind=%s pid=%d "
                    "sent=NO errno=%d fallback=app-input\n",
                    KindName((MacWSInputKind)record.kind),
                    record.targetPID, proxyError);
                fflush(stderr);
            }
        }
        if (fullscreenGlobalPointerRecord) {
            int proxyError = 0;
            bool proxySent = SendToVNCPointerProxy(
                socketFD, &record, &proxyError);
            if (proxySent) {
                sequence++;
                if (RuntimeDiagnosticsEnabled() &&
                    record.kind != MacWSInputKindTouchMove &&
                    record.kind != MacWSInputKindHover &&
                    record.kind != MacWSInputKindMenuHover) {
                    fprintf(stderr,
                        "MACWS-INPUT GLOBAL-POINTER seq=%llu kind=%s "
                        "contact=%u route=osxvnc-proxy sent=YES\n",
                        (unsigned long long)sequence,
                        KindName((MacWSInputKind)record.kind),
                        record.contactID);
                    fflush(stderr);
                }
                if (record.kind == MacWSInputKindTouchUp ||
                    record.kind == MacWSInputKindTouchCancel ||
                    record.kind == MacWSInputKindTap ||
                    record.kind == MacWSInputKindSecondaryTap)
                    gestureTarget = (MacWSWindowTarget){0};
                continue;
            }
            if (RuntimeDiagnosticsEnabled() &&
                record.kind != MacWSInputKindTouchMove &&
                record.kind != MacWSInputKindHover &&
                record.kind != MacWSInputKindMenuHover) {
                fprintf(stderr,
                    "MACWS-INPUT GLOBAL-POINTER kind=%s contact=%u "
                    "route=osxvnc-proxy sent=NO errno=%d fallback=app-input\n",
                    KindName((MacWSInputKind)record.kind),
                    record.contactID, proxyError);
                fflush(stderr);
            }
        }
        if (fullscreenGlobalPointerRecord) {
            // A fullscreen workspace is a hardware-style global input
            // surface. Its composited Mission Control/Dock transforms are
            // authoritative only inside WindowServer, so never trust a stale
            // Host-captured CGWindow ID. Re-query WindowServer at the event
            // point instead. When that live route names the same system
            // endpoint, preserve its current window as well as its PID; Dock's
            // Mission Control modal router needs that exact Spaces Bar window
            // identity. If the routing API has no result, retain the existing
            // process-level fallback used by ordinary Dock/global clicks.
            eventTarget.pid = record.targetPID;
            MacWSWindowTarget liveTarget = WindowTargetAtPoint(point);
            if (liveTarget.pid == record.targetPID &&
                liveTarget.windowID > 0) {
                eventTarget = liveTarget;
            }
        } else if (globalSystemSurfaceRecord) {
            // Dock and other non-NSApplication surfaces need CoreGraphics'
            // per-process route, not a borrowed application's global poster.
            // Re-read WindowServer immediately before the transition so a
            // retired/covered DisplayStream layer can never steal the click.
            MacWSWindowTarget verifiedTarget = WindowTargetAtPoint(point);
            bool routingAvailable = verifiedTarget.pid > 1;
            // Capture ownership and event-route ownership are deliberately
            // different for the shared macOS menu bar.  Runtime evidence on
            // 2026-08-06: displayd described window 15 as WindowServer
            // (91623/15), while
            // SLSCopyWindowRoutingRecordsForScreenLocation returned the
            // active Terminal connection (2251/15).  The CGWindowID is the
            // stable identity; requiring the capture owner's PID discarded
            // an otherwise exact WindowServer route and made the menu bar
            // untouchable.  Accept only that same-window ownership transfer;
            // a different nonzero window is still treated as a stale/covered
            // DisplayStream layer and dropped below.
            bool routingMatches = routingAvailable &&
                verifiedTarget.windowID == (int32_t)exactWindowID;
            armSystemMenuCapture = !capturedGlobalMenuTap &&
                record.kind == MacWSInputKindTap && routingMatches &&
                verifiedTarget.pid != record.targetPID;
            bool capturedRouting = capturedGlobalMenuTap &&
                globalSystemMenuCaptureTarget.pid == record.targetPID &&
                globalSystemMenuCaptureTarget.windowID ==
                    (int32_t)exactWindowID;
            bool exactEndpointAvailable =
                AppInputBridgeEndpointExists(record.targetPID);
            if ((routingAvailable && !routingMatches && !capturedRouting) ||
                (!routingAvailable && !exactEndpointAvailable)) {
                sequence++;
                if (RuntimeDiagnosticsEnabled()) {
                    fprintf(stderr,
                        "MACWS-INPUT SYSTEM-SURFACE-DROP seq=%llu "
                        "requested=%d/%u verified=%d/%d point=(%.2f,%.2f)\n",
                        (unsigned long long)sequence, record.targetPID,
                        exactWindowID, verifiedTarget.pid,
                        verifiedTarget.windowID, point.x, point.y);
                    fflush(stderr);
                }
                continue;
            }
            if (capturedRouting) {
                eventTarget = globalSystemMenuCaptureTarget;
                if (RuntimeDiagnosticsEnabled()) {
                    fprintf(stderr,
                        "MACWS-INPUT SYSTEM-MENU-CAPTURE requested=%d/%u "
                        "verified=%d/%d point=(%.2f,%.2f)\n",
                        record.targetPID, exactWindowID, verifiedTarget.pid,
                        verifiedTarget.windowID, point.x, point.y);
                    fflush(stderr);
                }
            } else if (routingMatches) {
                eventTarget = verifiedTarget;
            } else {
                // Runtime-confirmed on 2026-08-06: Dock's real VNC click
                // opens Launchpad while this broker's SLS routing response
                // and public CGWindow catalog both contain no Dock window.
                // The Host descriptor still names Dock's current PID/window
                // and its process-local AppInput socket is live.  Treat this
                // as routing API unavailability, never as permission to
                // override a nonzero mismatching WindowServer result.
                eventTarget.pid = record.targetPID;
                eventTarget.windowID = (int32_t)exactWindowID;
                if (RuntimeDiagnosticsEnabled()) {
                    fprintf(stderr,
                        "MACWS-INPUT SYSTEM-SURFACE-ENDPOINT-FALLBACK "
                        "requested=%d/%u point=(%.2f,%.2f)\n",
                        record.targetPID, exactWindowID, point.x, point.y);
                    fflush(stderr);
                }
            }
        } else if (systemGestureRecord && record.targetPID > 1) {
            // Host resolves the real Dock owner from displayd's
            // GlobalSystemSurface catalog. A system gesture must never follow
            // the front application's menu/hover cache: Dock itself owns the
            // native fluid gesture controller and animation lifecycle.
            eventTarget.pid = record.targetPID;
        } else if (exactWindowRecord) {
            // A native iPadOS Scene is permanently bound to one AppKit owner
            // and window. Do not let a stale fullscreen hover/menu cache route
            // its pointer or keyboard record into another application.
            eventTarget.pid = record.targetPID;
            eventTarget.windowID = (int32_t)exactWindowID;
        } else if (keyRecord && record.targetPID > 1) {
            // A fullscreen Host keyboard record carries the application that
            // was frontmost when UIKit produced this exact press.  Treat that
            // live identity as authoritative before consulting pointer/menu
            // caches.  Runtime-confirmed on 2026-09-04: Host emitted `w` for
            // Terminal pid 87219, but a retained Activity Monitor menuTarget
            // rewrote both key records to pid 30246.  Activity Monitor's
            // search field therefore typed while Terminal, VSCode and Sublime
            // appeared keyboard-dead.  Records from legacy/global producers
            // with targetPID=0 still use the established menu/hover fallback
            // below.
            eventTarget.pid = record.targetPID;
        } else if ((keyRecord || gestureRecord) && menuTarget.pid > 1) {
            // ActivateTarget is resolved before the authoritative native
            // mouse-down and remains the front application target after the
            // menu candidate ends.  Keyboard focus follows that application,
            // including while its AppKit main thread is inside a nested menu
            // loop and cannot answer another target probe.
            eventTarget = menuTarget;
        } else if (record.kind == MacWSInputKindSecondaryTap &&
                   menuTarget.pid > 1) {
            // OSXvnc resolves and activates the hit owner on right-button
            // down, then emits the atomic tap on release. Reuse that exact
            // owner instead of starting a second main-thread probe just as
            // the application is about to enter its contextual-menu loop.
            eventTarget = menuTarget;
        } else if ((keyRecord || gestureRecord) && hoverTarget.pid > 1) {
            eventTarget = hoverTarget;
        } else if (record.kind == MacWSInputKindMenuHover &&
            menuTarget.pid > 1) {
            eventTarget = menuTarget;
        } else if ((record.kind == MacWSInputKindHover ||
                    record.kind == MacWSInputKindMenuHover) &&
            hoverTarget.pid > 1) {
            eventTarget = hoverTarget;
        } else if (record.kind == MacWSInputKindActivateTarget) {
            // Resolve real pointer ownership in WindowServer before asking
            // application main threads.  RE-confirmed against Ventura 13.4:
            // SLSCopyWindowRoutingRecordsForScreenLocation returns the
            // server's routing chain and SLSConnectionGetPID resolves its
            // deepest destination.  Runtime evidence on 2026-08-11 showed a
            // Terminal title-bar click returning only 3/9 AppInput probe
            // replies (none from Terminal, Finder, or Word), which produced
            // target=0 and made native-all discard activation even though the
            // same SkyLight API continued resolving the visible windows.
            // Main-thread probing is therefore only a compatibility fallback
            // when WindowServer has no route (for example an OS-version API
            // mismatch), never the ordinary activation dependency.
            eventTarget = WindowTargetAtPoint(point);
            if (eventTarget.pid > 1) {
                // WindowTargetAtPoint intentionally returns only routing
                // identity.  Leaving the four activation-state fields zero
                // made every click look like an inactive target: inputd then
                // deactivated every other endpoint and queued another AppKit
                // activation before OSXvnc's real native down.  Read the
                // session's upstream front owner instead.  A matching owner
                // is already ready; a different owner needs exactly one real
                // activation transaction.  No application main thread is on
                // this ordinary path.
                pid_t frontPID = FrontUIProcessPID();
                eventTarget.selectedWasActive =
                    frontPID == eventTarget.pid;
                eventTarget.selectedWasFrontUIProcess =
                    frontPID == eventTarget.pid;
                eventTarget.competingActiveOwner = false;
                eventTarget.responseIncomplete = frontPID <= 1;
                if (RuntimeDiagnosticsEnabled()) {
                    fprintf(stderr,
                            "MACWS-INPUT FRONT-OWNER routed=%d front=%d "
                            "ready=%s\n",
                            eventTarget.pid, frontPID,
                            frontPID == eventTarget.pid ? "YES" : "NO");
                    fflush(stderr);
                }
            } else {
                eventTarget = ProbeActivationTarget(
                    targetSocketFD, &record);
            }
        } else if (record.kind != MacWSInputKindHover &&
            record.kind != MacWSInputKindMenuHover &&
            record.kind != MacWSInputKindTap && gestureTarget.pid > 1) {
            eventTarget = gestureTarget;
        } else if (record.targetPID > 1) {
            eventTarget.pid = record.targetPID;
            if (record.kind == MacWSInputKindTouchDown)
                gestureTarget = eventTarget;
        } else {
            eventTarget = WindowTargetAtPoint(point);
            if (eventTarget.pid <= 1) {
                if (record.kind == MacWSInputKindTouchDown ||
                    record.kind == MacWSInputKindTap ||
                    record.kind == MacWSInputKindSecondaryTap || keyRecord ||
                    gestureRecord) {
                    eventTarget = ProbeAppInputTarget(targetSocketFD, &record);
                } else if ((record.kind == MacWSInputKindHover ||
                            record.kind == MacWSInputKindMenuHover) &&
                           hoverTarget.pid <= 1) {
                    // Recover if the cached endpoint exited between periodic
                    // target refreshes. Probe records themselves never enter
                    // an application's event stream.
                    eventTarget = ProbeAppInputTarget(targetSocketFD, &record);
                    hoverTarget = eventTarget;
                }
            }
            if (eventTarget.pid <= 1) {
                eventTarget.pid = SoleAppInputBridgePID();
            }
            if (record.kind == MacWSInputKindTouchDown)
                gestureTarget = eventTarget;
        }
        // A native scroll/magnify gesture has one hit-tested owner from begin
        // through its terminal phase.  Fullscreen Host records deliberately
        // carry targetPID=0 so the first sample can hit Dock, Finder, a menu,
        // or the actual AppKit window at that point.  Re-running SkyLight's
        // routing query for every Changed sample both adds a synchronous IPC
        // edge at touch cadence and can switch owners as content moves under
        // a stationary finger.  Latch the first authoritative target exactly
        // as mouse dragging already does, then clear it only at End/Cancel.
        if (scrollRecord &&
            (record.flags & MacWSInputFlagScrollBegan))
            gestureTarget = eventTarget;
        if (magnifyRecord &&
            (record.flags & MacWSInputFlagGestureBegan))
            gestureTarget = eventTarget;
        if (record.kind == MacWSInputKindActivateTarget)
            menuTarget = eventTarget;
        bool resolvedDockSystemSurface =
            record.targetPID <= 1 && exactWindowID == 0 &&
            IsSystemPointerKind((MacWSInputKind)record.kind) &&
            WindowTargetIsDockSystemSurface(eventTarget);
        uint64_t captureGeneration = ArmCaptureForInput(&record);
        // WindowTargetAtPoint resolves targetPID=0 producers (including RFB)
        // to an actual layer-zero AppKit window. Send that resolved PID on the
        // wire; passing the original zero-valued record made
        // SendToAppInputBridge reject it before sendto(2).
        MacWSInputRecord routedRecord = record;
        routedRecord.targetPID = eventTarget.pid;
        if (resolvedDockSystemSurface) {
            routedRecord.flags |= MacWSInputFlagGlobalSystemSurface;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "MACWS-INPUT GLOBAL-SURFACE-INFER pid=%d window=%d "
                    "source=live-sls-dock\n",
                    eventTarget.pid, eventTarget.windowID);
                fflush(stderr);
            }
        }
        // WindowTargetAtPoint resolved both halves of the destination.  The
        // per-process bridge reads its window identity from sceneID, so
        // forwarding only the resolved PID silently turns a precise
        // system-surface hit into window 0.  Runtime evidence on 2026-08-09:
        // the broker resolved Mission Control's add-Space point as Dock
        // 30658/window 71, while Dock received the same record as window 0.
        // Preserve modifier bits while carrying the authoritative window.
        if (eventTarget.windowID > 0 && exactWindowID == 0) {
            routedRecord.sceneID = MacWSInputSceneForWindow(
                (uint32_t)eventTarget.windowID,
                MacWSInputModifiersForScene(record.sceneID));
        }
        size_t deactivated = 0;
        bool workspaceActivationSucceeded = false;
        int32_t publicActivationStatus = INT32_MIN;
        bool activationRepairNeeded =
            record.kind == MacWSInputKindActivateTarget &&
            eventTarget.pid > 1 &&
            (!eventTarget.selectedWasActive ||
             !eventTarget.selectedWasFrontUIProcess ||
             eventTarget.competingActiveOwner ||
             eventTarget.responseIncomplete);
        // A freshly launched application can visibly own the system menu bar
        // while HIToolbox's long-lived menu presentation has not recalculated
        // its root menu under that ownership.  A top-bar down therefore needs
        // a control-plane preflight even when the target already reports both
        // active and front.  The target process runs its real SetRootMenu /
        // RecalcBar path before OSXvnc posts the native down; no mouse NSEvent
        // is synthesized here.  Do not deactivate other applications for this
        // already-consistent case.
        bool systemMenuPreflightNeeded =
            record.kind == MacWSInputKindActivateTarget &&
            eventTarget.pid > 1 && record.frameHeight > 0 &&
            record.y >= 0.0f &&
            record.y <= (float)record.frameHeight * 0.04f;
        if (record.kind == MacWSInputKindActivateTarget &&
            eventTarget.pid > 1) {
            workspaceActivationSucceeded =
                ActivateRunningApplication(eventTarget.pid);
            publicActivationStatus = ActivateFrontProcess(eventTarget.pid);
        }
        if (activationRepairNeeded) {
            deactivated = DeactivateOtherAppInputBridges(
                socketFD, eventTarget.pid, &record);
        }
        int appBridgeError = 0;
        // System surfaces such as Dock now expose a process-local endpoint.
        // Prefer it because this broker's CoreGraphics post access is denied;
        // retain the old per-PID CGEvent path only as an explicit fallback
        // when the endpoint is absent (sendto returns ENOENT/ECONNREFUSED).
        bool appBridgeAttempted = globalSystemSurfaceRecord ||
            fullscreenGlobalPointerRecord ||
            (record.kind != MacWSInputKindActivateTarget ||
             activationRepairNeeded || systemMenuPreflightNeeded);
        bool appBridgeSent = appBridgeAttempted &&
            SendToAppInputBridge(socketFD, &routedRecord, &appBridgeError);
        bool effectiveGlobalSystemSurface =
            globalSystemSurfaceRecord || resolvedDockSystemSurface;
        if (effectiveGlobalSystemSurface &&
            (record.kind == MacWSInputKindSecondaryTap ||
             armSystemMenuCapture) && appBridgeSent &&
            eventTarget.pid > 1 && eventTarget.windowID > 0 &&
            monotonicNow != 0) {
            globalSystemMenuCaptureTarget = eventTarget;
            globalSystemMenuCaptureDeadline = monotonicNow +
                30ull * 1000000000ull;
        } else if (capturedGlobalMenuTap) {
            // One primary tap either selects an item or dismisses the menu.
            // Never let a stale capture steal a later independent action.
            globalSystemMenuCaptureTarget = (MacWSWindowTarget){0};
            globalSystemMenuCaptureDeadline = 0;
        } else if (globalSystemMenuCaptureDeadline != 0 &&
                   monotonicNow > globalSystemMenuCaptureDeadline) {
            globalSystemMenuCaptureTarget = (MacWSWindowTarget){0};
            globalSystemMenuCaptureDeadline = 0;
        }
        if ((record.kind == MacWSInputKindHover ||
             record.kind == MacWSInputKindMenuHover) &&
            !appBridgeSent &&
            eventTarget.pid == hoverTarget.pid) {
            hoverTarget = (MacWSWindowTarget){0};
        }
        if (record.kind == MacWSInputKindMenuHover &&
            !appBridgeSent && eventTarget.pid == menuTarget.pid) {
            menuTarget = (MacWSWindowTarget){0};
        }
        if (record.kind == MacWSInputKindActivateTarget ||
            record.kind == MacWSInputKindDeactivateApplication) {
            if (record.kind == MacWSInputKindActivateTarget) {
                uint32_t acknowledgementFlags = 0;
                if (eventTarget.pid <= 1) {
                    acknowledgementFlags |= MacWSInputAckRouteFailed;
                } else if (!activationRepairNeeded &&
                           !systemMenuPreflightNeeded) {
                    acknowledgementFlags |= MacWSInputAckTargetReady;
                } else {
                    acknowledgementFlags |= MacWSInputAckRepairQueued;
                    if (systemMenuPreflightNeeded) {
                        acknowledgementFlags |=
                            MacWSInputAckMenuPreflight;
                    }
                    if (appBridgeAttempted && !appBridgeSent) {
                        acknowledgementFlags |= MacWSInputAckRouteFailed;
                    }
                }
                SendInputAcknowledgement(
                    socketFD, &sender, senderLength, &record,
                    acknowledgementFlags);
            }
            sequence++;
            if (RuntimeDiagnosticsEnabled()) fprintf(stderr,
                    "MACWS-INPUT ACTIVATE seq=%llu kind=%s target=%d "
                    "window=%d repair=%s menu-preflight=%s workspace=%s "
                    "hiservices=%d "
                    "deactivated=%zu "
                    "sent=%s errno=%d\n",
                    (unsigned long long)sequence,
                    KindName((MacWSInputKind)record.kind),
                    eventTarget.pid, eventTarget.windowID,
                    activationRepairNeeded ? "YES" : "NO",
                    systemMenuPreflightNeeded ? "YES" : "NO",
                    workspaceActivationSucceeded ? "YES" : "NO",
                    publicActivationStatus, deactivated,
                    !appBridgeAttempted ? "SKIPPED" :
                        (appBridgeSent ? "YES" : "NO"), appBridgeError);
            if (RuntimeDiagnosticsEnabled()) fflush(stderr);
            continue;
        }
        if (keyRecord) {
            // The chroot's global CG keyboard route is the failed transport
            // that this record replaces.  A key is meaningful only inside an
            // AppKit application, so never reinterpret eventType=0 as a mouse
            // event when target selection or the per-app socket is absent.
            sequence++;
            if (RuntimeDiagnosticsEnabled()) fprintf(stderr,
                    "MACWS-INPUT KEY seq=%llu kind=%s target=%d "
                    "keycode=%.0f keysym=%#x modifiers=%#llx sent=%s errno=%d\n",
                    (unsigned long long)sequence,
                    KindName((MacWSInputKind)record.kind), eventTarget.pid,
                    record.pressure, record.contactID,
                    (unsigned long long)(record.sceneID & 0xffffffffull),
                    appBridgeSent ? "YES" : "NO", appBridgeError);
            if (RuntimeDiagnosticsEnabled()) fflush(stderr);
            continue;
        }
        if (desktopCommandRecord) {
            sequence++;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "MACWS-INPUT DESKTOP-COMMAND seq=%llu target=%d "
                    "command=%u sent=%s errno=%d\n",
                    (unsigned long long)sequence, eventTarget.pid,
                    record.contactID, appBridgeSent ? "YES" : "NO",
                    appBridgeError);
                fflush(stderr);
            }
            continue;
        }
        if (scrollRecord) {
            uint32_t horizontalBits = record.contactID;
            float horizontal = 0.0f;
            memcpy(&horizontal, &horizontalBits, sizeof(horizontal));
            int32_t verticalPixels = (int32_t)lrintf(record.pressure);
            int32_t horizontalPixels = isfinite(horizontal)
                ? (int32_t)lrintf(horizontal) : 0;
            sequence++;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "MACWS-INPUT SCROLL seq=%llu target=%d delta=(%d,%d) "
                    "app-bridge=%s errno=%d\n",
                    (unsigned long long)sequence, eventTarget.pid,
                    horizontalPixels, verticalPixels,
                    appBridgeSent ? "YES" : "NO", appBridgeError);
                fflush(stderr);
            }
            if (record.flags & (MacWSInputFlagScrollEnded |
                                MacWSInputFlagScrollCancelled))
                gestureTarget = (MacWSWindowTarget){0};
            continue;
        }
        if (magnifyRecord) {
            sequence++;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "MACWS-INPUT MAGNIFY seq=%llu target=%d phase=%#x "
                    "amount=%.6f app-bridge=%s errno=%d\n",
                    (unsigned long long)sequence, eventTarget.pid,
                    record.flags, record.pressure,
                    appBridgeSent ? "YES" : "NO", appBridgeError);
                fflush(stderr);
            }
            if (record.flags & (MacWSInputFlagGestureEnded |
                                MacWSInputFlagGestureCancelled))
                gestureTarget = (MacWSWindowTarget){0};
            continue;
        }
        if (rotateRecord) {
            sequence++;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "MACWS-INPUT ROTATE seq=%llu target=%d phase=%#x "
                    "degrees=%.6f app-bridge=%s errno=%d\n",
                    (unsigned long long)sequence, eventTarget.pid,
                    record.flags, record.pressure,
                    appBridgeSent ? "YES" : "NO", appBridgeError);
                fflush(stderr);
            }
            if (record.flags & (MacWSInputFlagGestureEnded |
                                MacWSInputFlagGestureCancelled))
                gestureTarget = (MacWSWindowTarget){0};
            continue;
        }
        if (systemGestureRecord) {
            sequence++;
            if (RuntimeDiagnosticsEnabled()) {
                fprintf(stderr,
                    "MACWS-INPUT SYSTEM-GESTURE seq=%llu target=%d "
                    "axis=%u phase=%#x progress=%.6f velocity=%.6f "
                    "app-bridge=%s errno=%d\n",
                    (unsigned long long)sequence, eventTarget.pid,
                    record.buttons, record.flags, record.pressure,
                    record.altitude, appBridgeSent ? "YES" : "NO",
                    appBridgeError);
                fflush(stderr);
            }
            continue;
        }
        CGMouseButton mouseButton =
            record.kind == MacWSInputKindSecondaryTap
                ? MacWSCGMouseButtonRight : MacWSCGMouseButtonLeft;
        CGEventRef event = appBridgeSent ? NULL :
            CGEventCreateMouseEvent(NULL, eventType, point, mouseButton);
        bool created = event != NULL;
        CGPoint observed = {-1.0, -1.0};
        bool observedCursor = false;
        unsigned cursorSamples = 0;
        if (event) {
            if (eventType == MacWSCGEventLeftMouseDown ||
                eventType == MacWSCGEventLeftMouseUp ||
                eventType == MacWSCGEventRightMouseDown ||
                eventType == MacWSCGEventRightMouseUp) {
                CGEventSetIntegerValueField(event,
                    MacWSCGMouseEventClickState, 1);
            }
            CGEventSetIntegerValueField(event,
                MacWSCGMouseEventButtonNumber, mouseButton);
            if (eventTarget.pid > 1) {
                if (eventTarget.windowID > 0) {
                    CGEventSetIntegerValueField(event,
                        MacWSCGMouseEventWindowUnderMousePointer,
                        eventTarget.windowID);
                    CGEventSetIntegerValueField(event,
                        MacWSCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                        eventTarget.windowID);
                }
                CGEventPostToPid(eventTarget.pid, event);
            } else {
                CGEventPost(MacWSCGHIDEventTap, event);
            }
            CFRelease(event);
            if (record.kind == MacWSInputKindTap ||
                record.kind == MacWSInputKindSecondaryTap) {
                CGEventRef upEvent = CGEventCreateMouseEvent(
                    NULL,
                    record.kind == MacWSInputKindSecondaryTap
                        ? MacWSCGEventRightMouseUp
                        : MacWSCGEventLeftMouseUp,
                    point, mouseButton);
                if (upEvent) {
                    CGEventSetIntegerValueField(upEvent,
                        MacWSCGMouseEventClickState, 1);
                    CGEventSetIntegerValueField(upEvent,
                        MacWSCGMouseEventButtonNumber,
                        mouseButton);
                    if (eventTarget.pid > 1) {
                        if (eventTarget.windowID > 0) {
                            CGEventSetIntegerValueField(upEvent,
                                MacWSCGMouseEventWindowUnderMousePointer,
                                eventTarget.windowID);
                            CGEventSetIntegerValueField(upEvent,
                                MacWSCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                eventTarget.windowID);
                        }
                        CGEventPostToPid(eventTarget.pid, upEvent);
                    } else {
                        CGEventPost(MacWSCGHIDEventTap, upEvent);
                    }
                    CFRelease(upEvent);
                }
            }
            unsigned sampleLimit =
                record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC ? 21 : 1;
            for (unsigned sample = 0; sample < sampleLimit; sample++) {
                if (sample > 0) usleep(5000);
                observedCursor = ReadCursorPoint(&observed);
                cursorSamples++;
                if (!observedCursor || sampleLimit == 1 ||
                    (fabs(observed.x - point.x) <= 0.5 &&
                     fabs(observed.y - point.y) <= 0.5)) {
                    break;
                }
            }
        }
        sequence++;
        bool continuous = record.kind == MacWSInputKindTouchMove ||
                          record.kind == MacWSInputKindHover ||
                          record.kind == MacWSInputKindMenuHover;
        if ((RuntimeDiagnosticsEnabled() ||
             record.contactID == MACWS_INPUT_CONTACT_DIAGNOSTIC) &&
            (!continuous || (sequence % 60) == 0)) {
            fprintf(stderr,
                    "MACWS-INPUT RX seq=%llu scene=%llx kind=%s "
                    "target=%d frame=(%.2f,%.2f)/%ux%u quartz=(%.2f,%.2f) event=%u "
                    "created=%s post=%s route_errno=%d cursor=%s(%.2f,%.2f) samples=%u capture=%llu\n",
                    (unsigned long long)sequence,
                    (unsigned long long)record.sceneID,
                    KindName((MacWSInputKind)record.kind), record.targetPID,
                    record.x, record.y,
                    record.frameWidth, record.frameHeight, point.x, point.y,
                    eventType, created ? "YES" : "NO",
                    appBridgeSent || created ? "issued" : "not-issued",
                    appBridgeError,
                    observedCursor ? "observed" : "unavailable",
                    observed.x, observed.y, cursorSamples,
                    (unsigned long long)captureGeneration);
            fprintf(stderr,
                    "MACWS-INPUT ROUTE seq=%llu route=%s pid=%d window=%d\n",
                    (unsigned long long)sequence,
                    appBridgeSent ? "appkit-socket" :
                        (eventTarget.pid > 1 ? "target-pid" : "global-fallback"),
                    eventTarget.pid, eventTarget.windowID);
            fflush(stderr);
        }
        if (record.kind == MacWSInputKindTouchUp ||
            record.kind == MacWSInputKindTouchCancel ||
            record.kind == MacWSInputKindTap ||
            record.kind == MacWSInputKindSecondaryTap) {
            gestureTarget = (MacWSWindowTarget){0};
        }
    }

    if (InputSocketFD >= 0) {
        close((int)InputSocketFD);
        InputSocketFD = -1;
    }
    if (TargetSocketFD >= 0) {
        close((int)TargetSocketFD);
        TargetSocketFD = -1;
    }
    flock(lockFD, LOCK_UN);
    close(lockFD);
    unlink(InputSocketPath);
    unlink(TargetSocketPath);
    fprintf(stderr, "MACWS-INPUT STOP\n");
    return 0;
}
