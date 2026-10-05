#ifndef MACWS_HOST_PROTOCOL_H
#define MACWS_HOST_PROTOCOL_H

#include <stdint.h>

#define MACWS_FRAME_MAGIC 0x564e4346u /* "VNCF" */
#define MACWS_INPUT_MAGIC 0x4d574556u /* "MWEV" */
#define MACWS_INPUT_LEGACY_VERSION 5u
#define MACWS_INPUT_DOCUMENT_VERSION 6u
#define MACWS_INPUT_QUIT_VERSION 7u
#define MACWS_INPUT_KEYBOARD_VERSION 8u
#define MACWS_INPUT_VERSION 9u
#define MACWS_INPUT_CONTACT_DIAGNOSTIC 0x44494147u /* "DIAG" */
#define MACWS_INPUT_WINDOW_SCENE_FLAG UINT64_C(0x0000000080000000)
#define MACWS_TARGET_PROBE_MAGIC 0x4d575450u /* "MWTP" */
#define MACWS_TARGET_REPLY_MAGIC 0x4d575452u /* "MWTR" */
#define MACWS_TARGET_VERSION 1u
#define MACWS_INPUT_ACK_MAGIC 0x4d574941u /* "MWIA" */
#define MACWS_INPUT_ACK_VERSION 1u
#define MACWS_INTERACTION_WAKE_SOCKET_PATH \
    "/private/tmp/macws_interaction_wake.sock"
#define MACWS_RENDER_ACTIVITY_PATH \
    "/private/tmp/macws_render_activity"
#define MACWS_RENDER_ACTIVITY_MAGIC 0x4d575241u /* "MWRA" */
#define MACWS_RENDER_ACTIVITY_LEGACY_VERSION 1u
#define MACWS_RENDER_ACTIVITY_AUTHORITY_VERSION 2u
#define MACWS_RENDER_ACTIVITY_VERSION 3u
#define MACWS_RENDER_AUTHORITY_PATH \
    "/private/tmp/macws_render_authority"
#define MACWS_RENDER_AUTHORITY_MAGIC 0x4d575255u /* "MWRU" */
#define MACWS_RENDER_AUTHORITY_VERSION 1u
#define MACWS_DIRECT_DRAWABLE_ACTIVITY_PATH \
    "/private/tmp/macws_direct_drawable_activity"
#define MACWS_DIRECT_DRAWABLE_ACTIVITY_MAGIC 0x4d574441u /* "MWDA" */
#define MACWS_DIRECT_DRAWABLE_ACTIVITY_VERSION 1u
#define MACWS_VNC_ACTIVATION_REPLY_SOCKET_PATH \
    "/private/tmp/macws_vnc_activation_reply.sock"
#define MACWS_VNC_POINTER_PROXY_SOCKET_PATH \
    "/private/tmp/macws_vnc_pointer_proxy.sock"

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
} MacWSFrameHeader;

// A presenting application publishes both freshness and the cadence it can
// actually consume.  The earlier timestamp-only file made WindowServer run a
// fixed 60-Hz completion loop even when Stray was deliberately capped at
// 50 FPS, and pointer activity temporarily raised that full-desktop loop to
// 120 Hz.  Keep the record versioned so the consumer can reject torn or stale
// data while retaining an explicit legacy timestamp fallback.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t timestampNS;
    uint32_t targetPaceUS;
    // Version 2 identifies the process which presented the real drawable.
    // Version 1 left these bytes zero and remains accepted only as the legacy
    // game signal during a rolling package update.
    int32_t producerPID;
    // Version 3 adds the monotonic count of authority-matched, window-sized
    // presentations.  It is sampled through the existing 10-Hz activity
    // write, so profiling can distinguish producer cadence from WindowServer
    // and Host cadence without adding per-frame I/O or logging.
    uint64_t presentSequence;
} MacWSRenderActivityRecord;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t timestampNS;
    uint32_t targetPaceUS;
    int32_t producerPID;
} MacWSRenderActivityRecordV2;

// displayd owns this authorization edge after matching a visible, focused
// AppKit window to the real SkyLight layer graph. A Metal-presenting child
// (Chromium's GPU helper, for example) may request an active compositor pace
// only while it remains a descendant of this exact owner and its drawable
// matches the observed window-sized IOSurface. Both producer and WindowServer
// validate this record; freshness makes a dead displayd or focus change fail
// closed to the cool idle cadence.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t timestampNS;
    int32_t ownerPID;
    uint32_t layerWindowID;
    uint32_t width;
    uint32_t height;
} MacWSRenderAuthorityRecord;

// macwsdisplayd publishes this only for a fullscreen Host after its
// direct-drawable heartbeat has matched a live, focused SkyLight layer
// carrying AppInputBridge's FullscreenCanvas capability. A focused
// exact-window direct drawable uses the same Host/displayd validation to
// suspend its redundant capture, but deliberately does not publish this
// pacing lease because Chromium requestAnimationFrame still consumes the
// WindowServer completion clock. Freshness is monotonic and fail-closed so a
// dead Host/display service naturally restores the ordinary cadence/capture.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t timestampNS;
    int32_t ownerPID;
    uint32_t layerWindowID;
    uint32_t width;
    uint32_t height;
} MacWSDirectDrawableActivityRecord;

typedef uint16_t MacWSInputKind;
enum {
    MacWSInputKindTouchDown = 1,
    MacWSInputKindTouchMove = 2,
    MacWSInputKindTouchUp = 3,
    MacWSInputKindTouchCancel = 4,
    MacWSInputKindHover = 5,
    // A complete stationary primary-button gesture.  Keeping the down/up pair
    // in one datagram prevents an accepted mouse-up from being separated from
    // a failed mouse-down when a local AF_UNIX queue is under pressure.
    MacWSInputKindTap = 6,
    // Refresh macwsinputd's unique AppKit hover owner without creating an
    // NSEvent.  OSXvnc sends this after its native pointer path has updated
    // WindowServer's global cursor/application state; the following hover can
    // then supplement AppKit menu tracking in that one selected process.
    MacWSInputKindTargetProbe = 7,
    // Control-plane records used only for a real VNC button-down. The producer
    // sends ActivateTarget after receiving that user packet but immediately
    // before posting its native down, so the broker can resolve the still-
    // responsive target even when the down enters a synchronous menu tracker.
    // The broker deactivates every other endpoint and activates the selected
    // endpoint. Neither control record constructs an NSEvent.
    MacWSInputKindActivateTarget = 8,
    MacWSInputKindDeactivateApplication = 9,
    // A button-free pointer update during a native menu lifecycle. macOS
    // 13.4's NSCarbonMenuImpl ultimately waits in NSApplication's NSEvent
    // queue through _NSHLTBMenuEventProc, so this kind lets the selected app
    // feed that queue from its socket thread while the main thread is inside
    // the synchronous menu tracker. It remains distinct from normal-window
    // hover so the route is bounded to an actual menu candidate lifetime.
    MacWSInputKindMenuHover = 10,
    // OSXvnc's own key-table/state machine has already translated the RFB
    // keysym when these records are emitted.  For key records, pressure is
    // the translated 16-bit CGKeyCode, contactID is the original 32-bit RFB
    // keysym, and sceneID's low 32 bits carry NSEvent/CG modifier flags.  The
    // v4 receivers validate the complete record before using these fields.
    MacWSInputKindKeyDown = 11,
    MacWSInputKindKeyUp = 12,
    // A complete stationary secondary-button gesture. Like Tap, the pair is
    // transported in one datagram and materialized inside the selected
    // AppKit process, so a fast RFB release cannot overtake its down before
    // rightMouseDown enters the native contextual-menu tracker.
    MacWSInputKindSecondaryTap = 13,
    // Two-axis precision scrolling. x/y remain the cursor location in frame
    // pixels, pressure carries vertical pixel delta, and contactID carries
    // the IEEE-754 bits of the horizontal float delta.
    MacWSInputKindScroll = 14,
    // Control-plane request for one captured AppKit window. sceneID carries
    // its exact window number, x/y are the desired frame size in macOS
    // logical points, and pressure carries iPad points per macOS point.
    // AppInputBridge clamps against the real NSWindow minimum before calling
    // the native frame setter; it never bypasses AppKit validation.
    MacWSInputKindConfigureWindow = 15,
    // A user discarded the iPad window Scene representing one exact AppKit
    // window. The target process performs the ordinary NSWindow close action;
    // backgrounding or stream disconnection never emits this control record.
    MacWSInputKindCloseWindow = 16,
    // Bootstrap one ordinary document/browser window in an AppKit process
    // that deliberately launches without a window (Finder is the concrete
    // case). The target resolves the enabled Command-N item from its current
    // NSMainMenu and sends that item's real target/action through NSApp.
    MacWSInputKindCreateInitialWindow = 17,
    // Deliver the standard NSApplication reopen lifecycle inside a directly
    // exec'd chroot application. Such processes have real HIServices and
    // WindowServer records but no LaunchServices AppleEvent endpoint, so a
    // Dock/open-style kAEReopenApplication addressed from another process
    // returns procNotFound. The target asks its real NSApplicationDelegate to
    // handle applicationShouldHandleReopen:hasVisibleWindows: on the main
    // thread; no application-specific window is synthesized.
    MacWSInputKindReopenApplication = 18,
    // Native AppKit magnification gesture. pressure carries the incremental
    // magnification delta (for example +0.05 means 5% larger), contactID is a
    // stable identity for the gesture, and the phase reuses the scroll-phase
    // flag bits below. The wire record stays ABI-compatible at 84 bytes.
    MacWSInputKindMagnify = 19,
    // Legacy one-shot desktop command retained only for wire compatibility
    // with older diagnostic clients. Fullscreen Host no longer emits it:
    // semantic commands cannot carry native fluid gesture progress.
    MacWSInputKindDesktopCommand = 20,
    // Continuous macOS system-trackpad gesture, delivered only to Dock's
    // process-local input endpoint. pressure is the signed, cumulative
    // progress; altitude is progress/second; buttons carries
    // MacWSSystemGestureAxis; contactID remains stable from Begin through the
    // terminal phase. Dock's Ventura gesture controller, rather than Host,
    // owns the native Mission Control/Spaces animation and completion policy.
    MacWSInputKindSystemGesture = 21,
    // Native AppKit two-finger rotation. pressure carries the incremental
    // angle in degrees (matching -[NSEvent rotation]); contactID is stable for
    // the complete gesture and phase reuses the gesture flag aliases below.
    // Version 5 adds this kind without changing the 84-byte record layout.
    MacWSInputKindRotate = 22,
    // Invoke the target application's currently enabled Command-V menu item.
    // The item supplies its real AppKit target/action after the Host has
    // focused the exact drop point and macwsinteropd has committed the data.
    MacWSInputKindPerformPaste = 23,
    // Complete a document-open transaction inside the target AppKit process.
    // sceneID is a nonzero hostd-generated nonce naming a mode-0600 sidecar
    // that contains only already-validated absolute document paths.  This is
    // version 6's replacement for the missing cross-process AppleEvent
    // endpoint; the receiver constructs kAEOpenDocuments and passes it to
    // NSApplication's normal Ventura open-event handler.
    MacWSInputKindOpenDocuments = 24,
    // Deliver the standard application-quit lifecycle inside the exact
    // directly-exec'd AppKit process. Dock's ordinary aevt/quit AppleEvent
    // cannot find these applications because launchdchrootexec does not give
    // them a LaunchServices AppleEvent endpoint. The receiver enters AppKit's
    // own Ventura quit handler on its main thread; applicationShouldTerminate,
    // unsaved-document prompts and cancellation remain application-owned.
    MacWSInputKindPerformQuit = 25,
    // Physical keyboard ownership snapshot, independent of any window/frame.
    // reserved bits 0..7 identify L/R Shift, Control, Option, Command (in
    // that order). sceneID retains the corresponding aggregate modifier bits.
    // contactID=1 ends this Host's keyboard ownership; 0 updates physical state.
    // Only the session keyboard proxy consumes it; never an AppKit endpoint.
    MacWSInputKindModifierSnapshot = 26,
    // Game-camera motion. x/y retain the locked anchor inside the exact
    // window's backing surface, while pressure and altitude carry signed raw
    // horizontal/vertical mouse counts. An indirect physical pointer requires
    // confirmed iPadOS pointer lock; a finger is already a bounded UIKit
    // contact and can emit successive relative deltas without pointer lock.
    // Both remain exact-window records and must never be reinterpreted as an
    // absolute WindowServer cursor position.
    MacWSInputKindRelativePointer = 27,
};

// ABI 6 added OpenDocuments, ABI 7 PerformQuit, ABI 8 a keyboard snapshot,
// and ABI 9 pointer-locked relative motion.
// The packed record
// itself is still the
// 84-byte ABI introduced by version 5.  During a package upgrade, UIKit Host,
// macwsinputd and long-lived AppKit/Dock processes cannot all replace their
// mapped code atomically.  Keep every pre-existing kind on the version-5 wire
// dialect and let current receivers accept either dialect for those kinds.
// OpenDocuments stays on version 6 for rolling-upgrade compatibility and
// accepts v7/v8/v9 as well. PerformQuit stays on the v7 wire because older
// endpoints do not implement the AppKit lifecycle transaction.
static inline int MacWSInputVersionSupportsKind(uint16_t version,
                                                MacWSInputKind kind) {
    if (kind == MacWSInputKindOpenDocuments)
        return version == MACWS_INPUT_DOCUMENT_VERSION ||
            version == MACWS_INPUT_QUIT_VERSION ||
            version == MACWS_INPUT_KEYBOARD_VERSION ||
            version == MACWS_INPUT_VERSION;
    if (kind == MacWSInputKindPerformQuit)
        return version == MACWS_INPUT_QUIT_VERSION ||
            version == MACWS_INPUT_KEYBOARD_VERSION ||
            version == MACWS_INPUT_VERSION;
    if (kind == MacWSInputKindModifierSnapshot)
        return version == MACWS_INPUT_KEYBOARD_VERSION ||
            version == MACWS_INPUT_VERSION;
    if (kind == MacWSInputKindRelativePointer)
        return version == MACWS_INPUT_VERSION;
    return kind >= MacWSInputKindTouchDown &&
        kind <= MacWSInputKindPerformPaste &&
        (version == MACWS_INPUT_LEGACY_VERSION ||
         version == MACWS_INPUT_DOCUMENT_VERSION ||
         version == MACWS_INPUT_QUIT_VERSION ||
         version == MACWS_INPUT_KEYBOARD_VERSION ||
         version == MACWS_INPUT_VERSION);
}

static inline uint16_t MacWSInputWireVersionForKind(MacWSInputKind kind) {
    if (kind == MacWSInputKindOpenDocuments)
        return MACWS_INPUT_DOCUMENT_VERSION;
    if (kind == MacWSInputKindPerformQuit)
        return MACWS_INPUT_QUIT_VERSION;
    if (kind == MacWSInputKindModifierSnapshot)
        return MACWS_INPUT_KEYBOARD_VERSION;
    if (kind == MacWSInputKindRelativePointer)
        return MACWS_INPUT_VERSION;
    return MACWS_INPUT_LEGACY_VERSION;
}

#define MACWS_OPEN_DOCUMENT_SIDECAR_PREFIX \
    "/private/tmp/macws_open_documents"
#define MACWS_OPEN_DOCUMENT_ACK_MAGIC 0x4d574f41u /* "MWOA" */
#define MACWS_OPEN_DOCUMENT_ACK_VERSION 1u

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t nonce;
    int32_t targetPID;
    uint32_t acceptedCount;
} MacWSOpenDocumentAck;

typedef uint32_t MacWSDesktopCommand;
enum {
    // Reserved wire values from the retired diagnostic implementation.
    // Production fullscreen gestures use MacWSInputKindSystemGesture.
    MacWSDesktopCommandMissionControl = 1,
    MacWSDesktopCommandApplicationWindows = 2,
    MacWSDesktopCommandSpaceLeft = 3,
    MacWSDesktopCommandSpaceRight = 4,
};

typedef uint32_t MacWSSystemGestureAxis;
enum {
    // These values intentionally match Ventura 13.4's navigation-gesture
    // field (CGEvent field 123) consumed by -[DOCKGestures handleEvent:].
    // Dock derives the actual left/right/up/down gesture from the signed
    // progress, exactly as it does for a physical MacBook trackpad.
    MacWSSystemGestureAxisHorizontal = 1,
    MacWSSystemGestureAxisVertical = 2,
};

typedef uint16_t MacWSHostInputMode;
enum {
    // Finger location maps directly to the macOS backing surface. Best for
    // large controls and is the default for a touch-first iPad experience.
    MacWSHostInputModeDirect = 1,
    // The iPad glass acts as a relative precision touchpad. Magic Keyboard
    // pointer events remain absolute and are not converted to relative input.
    MacWSHostInputModeTrackpad = 2,
    // A physical Magic Keyboard trackpad/mouse requests iPadOS pointer lock
    // and emits raw relative motion for first-person/game camera control.
    // One-finger glass movement emits exact-window relative deltas too, while
    // ordinary Direct and Trackpad desktop modes retain their existing paths.
    MacWSHostInputModeGame = 3,
};

typedef uint16_t MacWSHostDisplayDensity;
enum {
    // Both selectable modes keep AppKit's real 2x Retina backing. Standard
    // maps that source to the iPad drawable without resampling. Larger keeps
    // the iPad drawable at its native screen scale and performs the required
    // macOS-style HiDPI enlargement in MacWSHost's Metal presentation pass.
    MacWSHostDisplayDensityRetinaStandard = 1,
    MacWSHostDisplayDensityRetinaLarger = 2,
    // Source-compatible names retained for older clients/producers.
    MacWSHostDisplayDensityTouchComfort =
        MacWSHostDisplayDensityRetinaStandard,
    MacWSHostDisplayDensityKeyboard =
        MacWSHostDisplayDensityRetinaLarger,
    // Persisted non-Retina enlargement modes. They are intentionally no
    // longer selectable and normalize to Retina Standard on upgrade.
    MacWSHostDisplayDensityComfort = 3,
    MacWSHostDisplayDensityComfort125 = 4,
    MacWSHostDisplayDensityComfort150 = 5,
};

static inline MacWSHostDisplayDensity MacWSNormalizedDisplayDensity(
        MacWSHostDisplayDensity density) {
    if (density == MacWSHostDisplayDensityRetinaLarger)
        return MacWSHostDisplayDensityRetinaLarger;
    return MacWSHostDisplayDensityRetinaStandard;
}

static inline double MacWSDisplayDensityFactor(
        MacWSHostDisplayDensity density) {
    density = MacWSNormalizedDisplayDensity(density);
    if (density == MacWSHostDisplayDensityRetinaLarger) return 1.25;
    return 1.0;
}

// Source semantics of an input sample. Version 4 keeps physical devices
// explicit instead of inferring Pencil, finger and indirect-pointer behavior
// from pressure or contact IDs. Producers that cannot identify the device
// (for example the legacy VNC bridge) use Unknown. The interoperability probe
// is deliberately distinct from a physical finger: it briefly asks AppKit to
// publish the selected files on its native dragging pasteboard, and must not
// be routed through the longer process-local direct-manipulation lifecycle.
typedef uint16_t MacWSInputSource;
enum {
    MacWSInputSourceUnknown = 0,
    MacWSInputSourceFinger = 1,
    MacWSInputSourcePencil = 2,
    MacWSInputSourceIndirectPointer = 3,
    MacWSInputSourceHardwareKeyboard = 4,
    MacWSInputSourceSoftwareKeyboard = 5,
    MacWSInputSourceVNC = 6,
    MacWSInputSourceInteropDragProbe = 7,
    MacWSInputSourceMax = MacWSInputSourceInteropDragProbe,
};

enum {
    MacWSInputFlagPreciseLocation = 1u << 0,
    MacWSInputFlagEstimatedLocation = 1u << 1,
    MacWSInputFlagEstimatedPressure = 1u << 2,
    MacWSInputFlagExpectingLocationUpdate = 1u << 3,
    MacWSInputFlagExpectingPressureUpdate = 1u << 4,
    // UIKit's authoritative UITouch.tapCount says this atomic primary tap is
    // the second member of a double click. The first tap is still delivered
    // immediately, so ordinary single-click latency is unchanged.
    MacWSInputFlagDoubleClick = 1u << 5,
    // Coordinates remain in the complete desktop framebuffer and the target
    // is a CGS-connected system-pointer owner.  There are two forms:
    //   * an encoded nonzero window names an exact captured Dock/system layer,
    //     which the broker independently confirms before posting;
    //   * encoded window zero is the fullscreen workspace's hardware-style
    //     global pointer stream.  targetPID is Dock's live endpoint and
    //     WindowServer performs the authoritative hit test, including native
    //     Mission Control transforms that do not belong to any captured
    //     application's local AppKit coordinate space.
    MacWSInputFlagGlobalSystemSurface = 1u << 6,
    // The producer has already accepted the release velocity and will follow
    // this finger ScrollEnded record with a momentum Began sequence. The AppKit
    // endpoint keeps its native per-window scroll target latched across that
    // boundary; without this explicit contract it must end the session now.
    MacWSInputFlagScrollWillMomentum = 1u << 7,
    MacWSInputFlagScrollBegan = 1u << 8,
    MacWSInputFlagScrollChanged = 1u << 9,
    MacWSInputFlagScrollEnded = 1u << 10,
    MacWSInputFlagScrollCancelled = 1u << 11,
    MacWSInputFlagScrollMomentum = 1u << 12,
    // These aliases describe the same NSEventPhase state machine for native
    // magnification without allocating another set of wire bits.
    MacWSInputFlagGestureBegan = MacWSInputFlagScrollBegan,
    MacWSInputFlagGestureChanged = MacWSInputFlagScrollChanged,
    MacWSInputFlagGestureEnded = MacWSInputFlagScrollEnded,
    MacWSInputFlagGestureCancelled = MacWSInputFlagScrollCancelled,
    // ConfigureWindow requests from an exact native Host Scene anchor the
    // represented AppKit window at the upper-left of its real NSScreen. This
    // makes AppKit constrain popovers against the same screen edge that bounds
    // the Scene capture instead of an arbitrary restored desktop position.
    MacWSInputFlagConfigureAnchorTopLeft = 1u << 13,
    // Keep an ordinary captured window's upper-right corner on the real
    // NSScreen edge. If an application has no real maximum and its Scene grows
    // wider than NSScreen, AppInput instead keeps the leading title-bar edge
    // reachable; exact-window capture still represents the complete surface.
    MacWSInputFlagConfigureAnchorTopRight = 1u << 14,
    // Bounded lab probes may request latency aggregation at the receiving
    // AppInput endpoint. Production UIKit/VNC producers leave this clear.
    MacWSInputFlagLatencyDiagnostic = 1u << 15,
};

// Versioned wire record for the iOS-host -> macOS event bridge.
// Coordinates are physical pixels in the producer's MacWSFrameHeader space.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t kind;
    uint64_t sceneID;
    double timestamp;
    float x;
    float y;
    float pressure;
    uint32_t contactID;
    uint32_t frameWidth;
    uint32_t frameHeight;
    int32_t targetPID;
    uint16_t source;
    uint16_t flags;
    uint32_t buttons;
    // Raw UIKit Pencil geometry in radians plus normalized Cartesian tilt.
    // Non-Pencil producers write zero. tiltX/tiltY are in [-1, 1].
    float altitude;
    float azimuth;
    float tiltX;
    float tiltY;
    // Monotonic per-producer sequence. Zero means the producer has no sequence.
    uint32_t sampleSequence;
    uint32_t reserved;
} MacWSInputRecord;

// ABI v3 originally used sceneID as an opaque scene token, while key records
// reserved its low 32 bits for modifier flags. A window Scene needs both an
// exact CGWindowID and those modifiers. UIKit's modifier flags occupy bits
// 16..21, so unused bit 31 marks this encoding, bits 32..63 retain the full
// 32-bit macOS window number, and bits 0..30 retain modifier flags.
// Untargeted RFB records keep the marker bit clear. A fullscreen global
// pointer can set the marker with a zero window ID so modifiers survive while
// WindowServer, rather than a captured NSWindow, remains the hit-test owner.
static inline uint64_t MacWSInputSceneForWindow(uint32_t windowID,
                                                uint32_t modifiers) {
    return MACWS_INPUT_WINDOW_SCENE_FLAG |
        ((uint64_t)windowID << 32) |
        (modifiers & UINT32_C(0x7fffffff));
}

static inline uint32_t MacWSInputWindowIDForScene(uint64_t sceneID) {
    if ((sceneID & MACWS_INPUT_WINDOW_SCENE_FLAG) == 0) return 0;
    return (uint32_t)(sceneID >> 32);
}

static inline uint32_t MacWSInputModifiersForScene(uint64_t sceneID) {
    return (uint32_t)sceneID & UINT32_C(0x7fffffff);
}

// macwsinputd has no usable CoreGraphics window list in its launchd session.
// Before routing an untargeted RFB down/tap, it asks every live AppKit endpoint
// to hit-test the point on that process's main thread. Only the selected PID
// receives the real MacWSInputRecord; probes never synthesize an NSEvent.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t nonce;
    float x;
    float y;
    uint32_t frameWidth;
    uint32_t frameHeight;
} MacWSInputTargetProbe;

enum {
    MacWSInputTargetHit = 1u << 0,
    MacWSInputTargetApplicationActive = 1u << 1,
    MacWSInputTargetKeyWindow = 1u << 2,
    // The global menu bar and application-owned transient surfaces follow
    // Process Manager's front UI process, which can diverge from
    // NSApplication.isActive when the chroot misses a LaunchServices
    // lifecycle update.  This flag is observational and lets the broker
    // request a real activation transaction when that divergence exists.
    MacWSInputTargetFrontUIProcess = 1u << 3,
};

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t nonce;
    int32_t pid;
    int32_t windowNumber;
    uint32_t flags;
} MacWSInputTargetReply;

enum {
    MacWSInputAckTargetReady = 1u << 0,
    MacWSInputAckRepairQueued = 1u << 1,
    MacWSInputAckRouteFailed = 1u << 2,
    MacWSInputAckMenuPreflight = 1u << 3,
};

// Bounded control-plane acknowledgement used only before OSXvnc emits a real
// native mouse-down. It reports whether the broker found the already-active
// target or had to queue an activation repair; it never acknowledges the
// subsequent NSEvent and therefore cannot create duplicate event ownership.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t sampleSequence;
    uint32_t flags;
} MacWSInputAck;

#if defined(__cplusplus)
static_assert(sizeof(MacWSFrameHeader) == 16, "MacWS frame header ABI");
static_assert(sizeof(MacWSInputRecord) == 84, "MacWS input record ABI");
static_assert(sizeof(MacWSInputTargetProbe) == 32,
              "MacWS target probe ABI");
static_assert(sizeof(MacWSInputTargetReply) == 28,
              "MacWS target reply ABI");
static_assert(sizeof(MacWSInputAck) == 16, "MacWS input ack ABI");
#else
_Static_assert(sizeof(MacWSFrameHeader) == 16, "MacWS frame header ABI");
_Static_assert(sizeof(MacWSInputRecord) == 84, "MacWS input record ABI");
_Static_assert(sizeof(MacWSInputTargetProbe) == 32,
               "MacWS target probe ABI");
_Static_assert(sizeof(MacWSInputTargetReply) == 28,
               "MacWS target reply ABI");
_Static_assert(sizeof(MacWSInputAck) == 16, "MacWS input ack ABI");
#endif

#endif
