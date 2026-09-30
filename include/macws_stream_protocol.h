#ifndef MACWS_STREAM_PROTOCOL_H
#define MACWS_STREAM_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

// The display service is owned by a macOS process launched through
// launchdchrootexec.  MacWSHost consumes it from the iOS side.  Keep every
// message self-describing: the two processes are built against different SDKs
// and can temporarily be on different package revisions during development.
#define MACWS_STREAM_SERVICE "com.macwsguide.display"
#define MACWS_STREAM_INVALIDATE_SOCKET_PATH \
    "/private/tmp/macws_display_invalidate.sock"
#define MACWS_STREAM_MAGIC 0x4d575354u /* "MWST" */
// Version 8 adds a validated fullscreen direct-drawable activity lease so the
// display service can suspend exactly one redundant full-resolution
// exact-window capture while Host is already presenting that application's
// completed CAMetalDrawable. Version 7 adds an explicit final-composite
// base-frame flag. Version 6
// separated ordered layer geometry transactions from IOSurface content
// frames. Version 5 republished the same IOSurface Mach right and acquired
// another lease for every native Spaces/Mission Control position; that
// multiplied one 60-Hz catalog sample by every moving desktop layer.
// Keep this as a hard wire boundary so an old daemon cannot silently send a
// message shape that a new Host interprets without the sequence invariant.
#define MACWS_STREAM_VERSION 8u

#define MACWS_STREAM_MAX_DIMENSION 16384u
#define MACWS_STREAM_MAX_BYTES_PER_ROW (MACWS_STREAM_MAX_DIMENSION * 16u)
#define MACWS_STREAM_MAX_WINDOWS 256u
#define MACWS_STREAM_MAX_DAMAGE_RECTS 64u
#define MACWS_STREAM_MAX_LAYER_GEOMETRY 64u
// AppKit window bounds are expressed in logical points while Chromium's
// completed drawable is already in backing pixels.  During a native
// fullscreen transition the two independently rounded edges can differ by
// two logical points on a 2x display.  Keep one shared, pixel-sized bound at
// every consumer so Host and displayd cannot disagree about the same exact
// window generation.  This remains deliberately far below a resize-scale
// tolerance: a genuine geometry change must wait for a matching catalog.
#define MACWS_DIRECT_DRAWABLE_GEOMETRY_TOLERANCE_PIXELS 4u
#define MACWS_WINDOW_METRICS_MAGIC 0x4d57474du /* "MWGM" */
#define MACWS_WINDOW_METRICS_VERSION 3u
#define MACWS_WINDOW_METRICS_V2_ENTRY_SIZE 20u
#define MACWS_GEOMETRY_INVALIDATION_MAGIC 0x4d574749u /* "MWGI" */
#define MACWS_GEOMETRY_INVALIDATION_VERSION 1u

#define MACWS_STREAM_KEY_OP "op"
#define MACWS_STREAM_KEY_EVENT "event"
#define MACWS_STREAM_KEY_PROTOCOL_VERSION "protocol_version"
#define MACWS_STREAM_KEY_MODE "mode"
#define MACWS_STREAM_KEY_WINDOW_ID "window_id"
#define MACWS_STREAM_KEY_LAYER_WINDOW_ID "layer_window_id"
#define MACWS_STREAM_KEY_STREAM_ID "stream_id"
#define MACWS_STREAM_KEY_SEQUENCE "sequence"
#define MACWS_STREAM_KEY_DESCRIPTOR "descriptor"
#define MACWS_STREAM_KEY_WINDOWS "windows"
// Optional input-only WindowServer surfaces; never selectable iPad Scenes.
#define MACWS_STREAM_KEY_SYSTEM_INPUT_WINDOWS "system-input-windows"
#define MACWS_STREAM_KEY_WINDOW_LIMITS "window_limits"
#define MACWS_STREAM_KEY_SURFACE_PORT "surface_port"
#define MACWS_STREAM_KEY_SURFACE_ID "surface_id"
#define MACWS_STREAM_KEY_DAMAGE_RECTS "damage_rects"
#define MACWS_STREAM_KEY_LAYER_GEOMETRY "layer_geometry"
#define MACWS_STREAM_KEY_LEASE_TOKEN "lease_token"
#define MACWS_STREAM_KEY_MESSAGE "message"
#define MACWS_STREAM_KEY_OK "ok"
#define MACWS_STREAM_KEY_ACTIVE "active"
#define MACWS_STREAM_KEY_OWNER_PID "owner_pid"
#define MACWS_STREAM_KEY_WIDTH "width"
#define MACWS_STREAM_KEY_HEIGHT "height"

#define MACWS_STREAM_OP_HELLO "hello"
#define MACWS_STREAM_OP_LIST_WINDOWS "list_windows"
#define MACWS_STREAM_OP_SUBSCRIBE "subscribe"
#define MACWS_STREAM_OP_UNSUBSCRIBE "unsubscribe"
#define MACWS_STREAM_OP_RELEASE_FRAME "release_frame"
#define MACWS_STREAM_OP_DIRECT_DRAWABLE_ACTIVITY \
    "direct_drawable_activity"

#define MACWS_STREAM_EVENT_READY "ready"
#define MACWS_STREAM_EVENT_WINDOWS "windows"
#define MACWS_STREAM_EVENT_FRAME "frame"
#define MACWS_STREAM_EVENT_LAYER_REMOVED "layer_removed"
#define MACWS_STREAM_EVENT_LAYER_GEOMETRY "layer_geometry"
#define MACWS_STREAM_EVENT_STOPPED "stopped"
#define MACWS_STREAM_EVENT_ERROR "error"

typedef uint32_t MacWSStreamMode;
enum {
    // One iPadOS scene presents the complete macOS display.  This is the
    // replacement for the native Host's use of an RFB/full-frame snapshot.
    MacWSStreamModeFullscreen = 1,
    // One iPadOS scene is bound to exactly one SkyLight window number.
    MacWSStreamModeWindow = 2,
};

typedef uint32_t MacWSStreamWindowFlags;
enum {
    MacWSStreamWindowVisible = 1u << 0,
    MacWSStreamWindowOnScreen = 1u << 1,
    MacWSStreamWindowHasShadow = 1u << 2,
    MacWSStreamWindowResizable = 1u << 3,
    MacWSStreamWindowMenuBar = 1u << 4,
    MacWSStreamWindowTransient = 1u << 5,
    MacWSStreamWindowFocused = 1u << 6,
    // The owning application presents a spatial canvas whose primary direct-
    // touch manipulation is button-down dragging, not document scrolling.
    // AppInputBridge derives this from the real bundle identity and publishes
    // it with each native window; Host never guesses from localized titles or
    // control coordinates. Two-finger magnification remains independent.
    MacWSStreamWindowSpatialCanvas = 1u << 7,
    // The owning application intentionally renders a self-contained game
    // canvas.  While that exact window is the active target of the iPad's
    // fullscreen workspace, Host may crop the authoritative WindowServer
    // composite to its published destination and fit it to the iPad Scene.
    // This keeps native overlays (including Steam's FPS panel) and uses the
    // same crop for input-coordinate mapping.  AppInputBridge derives this
    // capability from the real bundle identity; Host never guesses from a
    // title, process name or hard-coded desktop rectangle.
    MacWSStreamWindowFullscreenCanvas = 1u << 8,
    // macwsdisplayd resolves this from the first eligible level-zero AppKit
    // window in WindowServer's live on-screen front-to-back list. Several
    // simultaneously running applications can each retain a process-local
    // key window, and NSWorkspace can lag an explicit CGS activation in this
    // chroot, so neither source alone identifies the visibly frontmost app.
    MacWSStreamWindowFrontmostApplication = 1u << 9,
    // Per-axis AppKit frame constraints. A window can retain the Resizable
    // style while minSize/maxSize pin only one dimension (System Settings is
    // a concrete example). Host forwards these facts to the exact iPadOS
    // Scene so its resize grid can spring back on the constrained axis.
    MacWSStreamWindowFixedWidth = 1u << 10,
    MacWSStreamWindowFixedHeight = 1u << 11,
};

typedef uint32_t MacWSStreamFrameFlags;
enum {
    MacWSStreamFrameComplete = 1u << 0,
    MacWSStreamFrameHasDamage = 1u << 1,
    MacWSStreamFrameSizeChanged = 1u << 2,
    MacWSStreamFrameOccluded = 1u << 3,
    MacWSStreamFrameOverlay = 1u << 4,
    // The captured layer belongs to a non-AppKit global input owner such as
    // Dock. Host must preserve desktop coordinates and route through that
    // process's CGS endpoint even when its AppInput socket is present.
    MacWSStreamFrameGlobalSystemSurface = 1u << 5,
    // Visual-only system layers (currently the real WindowServer cursor)
    // participate in Metal composition but must never become the hit-test
    // owner for a touch at the cursor's own position.
    MacWSStreamFrameInputPassthrough = 1u << 6,
    // This fullscreen base is WindowServer's completed native AGX composite,
    // not the graphite workspace canvas. It already contains every SkyLight
    // layer and compositor-only effect. Host keeps overlay descriptors and
    // surfaces for hit testing, but must not paint them over these pixels.
    MacWSStreamFrameFinalComposite = 1u << 7,
    // A window-mode popup samples its exact, catalog-validated rectangle in
    // WindowServer's completed composite. Texture crop coordinates are not
    // AppKit-local input coordinates. The base remains an isolated stream.
    MacWSStreamFrameNativePopupComposite = 1u << 8,
};

// Title bytes immediately follow this descriptor in a window-list item.  The
// title is UTF-8 and is not NUL-terminated on the wire.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t windowID;
    int32_t ownerPID;
    uint32_t flags;
    // Stable identity for one user-visible AppKit window group.  AppKit tabs
    // are separate NSWindow/CGWindow objects and selecting a tab changes the
    // on-screen window number.  All members of a tab group publish the same
    // nonzero ID so an iPadOS Scene can follow that native identity change.
    uint32_t logicalGroupID;
    float logicalX;
    float logicalY;
    float logicalWidth;
    float logicalHeight;
    uint32_t pixelWidth;
    uint32_t pixelHeight;
    float minimumLogicalWidth;
    float minimumLogicalHeight;
    float backingScale;
    uint32_t titleLength;
} MacWSStreamWindowDescriptor;

// The IOSurface itself is transported separately as a Mach send right.  Its
// global IOSurfaceID is included only as a compatibility fallback and must be
// validated against this descriptor before creating a Metal texture.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t streamID;
    uint32_t windowID;
    uint32_t flags;
    uint64_t leaseToken;
    uint64_t sequence;
    uint64_t displayTime;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t pixelFormat;
    float backingScale;
    uint32_t damageRectCount;
    // Select the useful pixel rectangle in this exact-window IOSurface. The
    // current SkyLight producer uses the complete surface; keeping the fields
    // explicit makes padding/plane changes forward-compatible without changing
    // input or Scene geometry.
    uint32_t contentX;
    uint32_t contentY;
    uint32_t contentWidth;
    uint32_t contentHeight;
    // Every Scene has one base layer and zero or more SkyLight window layers.
    // A window Scene attaches its AppKit-owned transients; a fullscreen Scene
    // attaches the visible desktop window catalog over a Retina IOSurface
    // canvas. Each is transported as its own native window IOSurface and
    // composed by Host Metal. destination* is expressed in base backing pixels.
    uint32_t layerWindowID;
    // Fullscreen input must follow the same graph that Host composites.
    // SkyLight's independent global routing order can disagree after captured
    // windows have been repositioned, so carry the actual layer owner too.
    int32_t layerOwnerPID;
    int32_t layerLevel;
    int32_t destinationX;
    int32_t destinationY;
    uint32_t destinationWidth;
    uint32_t destinationHeight;
} MacWSStreamFrameDescriptor;

// A native workspace animation usually changes only composition geometry;
// the application's IOSurface pixels remain immutable. displayd batches these
// records in one ordered XPC event. streamID + sequence share the corresponding
// content producer's monotonic order, so Host can reject a delayed frame or
// geometry record instead of visually jumping back to an older position.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint64_t streamID;
    uint64_t sequence;
    uint64_t displayTime;
    uint32_t windowID;
    uint32_t layerWindowID;
    int32_t layerOwnerPID;
    int32_t layerLevel;
    int32_t destinationX;
    int32_t destinationY;
    uint32_t destinationWidth;
    uint32_t destinationHeight;
    uint32_t flags;
} MacWSStreamLayerGeometry;

static inline bool MacWSStreamLayerGeometryIsValid(
        const MacWSStreamLayerGeometry *geometry, size_t byteCount) {
    if (!geometry || byteCount != sizeof(*geometry) ||
        geometry->magic != MACWS_STREAM_MAGIC ||
        geometry->version != MACWS_STREAM_VERSION ||
        geometry->size != sizeof(*geometry) || geometry->streamID == 0 ||
        geometry->sequence == 0 || geometry->displayTime == 0 ||
        geometry->layerWindowID == 0 ||
        geometry->layerWindowID == geometry->windowID ||
        geometry->destinationWidth == 0 ||
        geometry->destinationHeight == 0 ||
        geometry->destinationWidth > MACWS_STREAM_MAX_DIMENSION ||
        geometry->destinationHeight > MACWS_STREAM_MAX_DIMENSION ||
        geometry->destinationX < -(int32_t)MACWS_STREAM_MAX_DIMENSION ||
        geometry->destinationY < -(int32_t)MACWS_STREAM_MAX_DIMENSION ||
        geometry->destinationX > (int32_t)MACWS_STREAM_MAX_DIMENSION ||
        geometry->destinationY > (int32_t)MACWS_STREAM_MAX_DIMENSION ||
        (geometry->flags & MacWSStreamFrameOverlay) == 0) return false;
    uint32_t allowedFlags = MacWSStreamFrameOverlay |
        MacWSStreamFrameGlobalSystemSurface |
        MacWSStreamFrameInputPassthrough;
    return (geometry->flags & ~allowedFlags) == 0;
}

static inline bool MacWSStreamLayerGeometrySupersedesFrame(
        const MacWSStreamLayerGeometry *geometry,
        const MacWSStreamFrameDescriptor *frame) {
    return geometry && frame && geometry->streamID == frame->streamID &&
        geometry->layerWindowID == frame->layerWindowID &&
        geometry->sequence > frame->sequence;
}

// A layer-removed event carries the exact producer stream and the last frame
// sequence detached from Host. displayd may keep that CGDisplayStream alive
// during its five-second reuse grace and explicitly republish the retained
// IOSurface if the same SkyLight window returns. In that case a higher
// sequence from the same stream is authoritative; an older/equal sequence is
// a delayed pre-removal frame and must remain rejected. A zero cutoff is the
// compatibility form from an older producer and cannot prove same-stream
// return, so only a different stream generation may clear it.
static inline bool MacWSStreamFrameSupersedesLayerRemoval(
        uint64_t frameStreamID, uint64_t frameSequence,
        uint64_t removedStreamID, uint64_t removedThroughSequence) {
    if (removedStreamID == 0 || frameStreamID != removedStreamID) return true;
    return removedThroughSequence != 0 &&
           frameSequence > removedThroughSequence;
}

// Map a point in the fullscreen desktop canvas into one captured layer.  A
// continuous gesture must use the descriptor captured at its Begin boundary:
// the window's live destination changes while WindowServer drags it, and
// feeding that new destination into the next sample subtracts the displacement
// that the preceding sample just applied.
static inline bool MacWSStreamMapDesktopPointToLayer(
    const MacWSStreamFrameDescriptor *descriptor, float desktopX,
    float desktopY, float *layerX, float *layerY) {
    if (!descriptor || !layerX || !layerY ||
        descriptor->destinationWidth == 0 ||
        descriptor->destinationHeight == 0 ||
        descriptor->contentWidth == 0 || descriptor->contentHeight == 0) {
        return false;
    }
    double u = (desktopX - descriptor->destinationX) /
        (double)descriptor->destinationWidth;
    double v = (desktopY - descriptor->destinationY) /
        (double)descriptor->destinationHeight;
    if (u < 0.0) u = 0.0;
    if (u > 0.999999) u = 0.999999;
    if (v < 0.0) v = 0.0;
    if (v > 0.999999) v = 0.999999;
    bool popup = (descriptor->flags & MacWSStreamFrameNativePopupComposite) != 0;
    *layerX = (popup ? 0 : descriptor->contentX) + (float)(u * descriptor->contentWidth);
    *layerY = (popup ? 0 : descriptor->contentY) + (float)(v * descriptor->contentHeight);
    return true;
}

typedef struct __attribute__((packed)) {
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
} MacWSStreamDamageRect;

// AppInputBridge sends this datagram only after AppKit has accepted a real
// NSWindow geometry change. Carry the committed target in pixels so displayd
// does not race an asynchronously updated CGWindow catalog when deciding
// whether an exact-window DisplayStream must be recreated.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t windowID;
    uint32_t pixelWidth;
    uint32_t pixelHeight;
} MacWSGeometryInvalidation;

static inline bool MacWSGeometryInvalidationIsValid(
    const MacWSGeometryInvalidation *record, size_t byteCount) {
    return record && byteCount == sizeof(*record) &&
        record->magic == MACWS_GEOMETRY_INVALIDATION_MAGIC &&
        record->version == MACWS_GEOMETRY_INVALIDATION_VERSION &&
        record->size == sizeof(*record) && record->windowID != 0 &&
        record->pixelWidth != 0 && record->pixelHeight != 0 &&
        record->pixelWidth <= MACWS_STREAM_MAX_DIMENSION &&
        record->pixelHeight <= MACWS_STREAM_MAX_DIMENSION;
}

// AppInputBridge publishes this small per-process sidecar under
// /private/tmp/macws_window_metrics.<pid>.bin. macwsdisplayd reads it only
// while building the window catalog; it is never on the per-frame path.
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t entrySize;
    uint32_t entryCount;
    uint64_t generation;
} MacWSWindowMetricsHeader;

typedef struct __attribute__((packed)) {
    double timestamp;
    uint32_t sequence;
    float requestedWidth;
    float requestedHeight;
    float appliedWidth;
    float appliedHeight;
} MacWSWindowConfigureAck;

// Optional windows-event companion. The V8 descriptor and surface protocol
// remain unchanged; old Hosts ignore this key, new Hosts accept its absence.
// Exact PID/window identity prevents a limit from leaking to sibling Scenes.
typedef struct __attribute__((packed)) {
    uint32_t windowID;
    int32_t ownerPID;
    float maximumLogicalWidth;
    float maximumLogicalHeight;
    MacWSWindowConfigureAck configureAck;
} MacWSStreamWindowLimits;

typedef struct __attribute__((packed)) {
    uint32_t windowID;
    uint32_t flags;
    uint32_t logicalGroupID;
    float minimumLogicalWidth;
    float minimumLogicalHeight;
    // Version 3 appends to the unchanged V2 prefix. Zero means unavailable.
    float maximumLogicalWidth;
    float maximumLogicalHeight;
    MacWSWindowConfigureAck configureAck;
} MacWSWindowMetricsEntry;

static inline bool MacWSWindowMetricsAreValid(
    const MacWSWindowMetricsHeader *header, size_t byteCount) {
    if (!header || header->magic != MACWS_WINDOW_METRICS_MAGIC ||
        !((header->version == 2 &&
           header->entrySize == MACWS_WINDOW_METRICS_V2_ENTRY_SIZE) ||
          (header->version == MACWS_WINDOW_METRICS_VERSION &&
           header->entrySize == sizeof(MacWSWindowMetricsEntry))) ||
        header->size != sizeof(*header) ||
        header->entryCount > MACWS_STREAM_MAX_WINDOWS ||
        header->generation == 0) return false;
    size_t entriesSize =
        (size_t)header->entryCount * header->entrySize;
    return entriesSize <= SIZE_MAX - sizeof(*header) &&
        byteCount == sizeof(*header) + entriesSize;
}

static inline bool MacWSWindowMetricsReadEntry(
    const MacWSWindowMetricsHeader *header, size_t byteCount,
    uint32_t index, MacWSWindowMetricsEntry *entry) {
    if (!entry || !MacWSWindowMetricsAreValid(header, byteCount) ||
        index >= header->entryCount) return false;
    memset(entry, 0, sizeof(*entry));
    memcpy(entry, (const uint8_t *)header + header->size +
           (size_t)index * header->entrySize, header->entrySize);
    return true;
}

static inline bool MacWSStreamWindowLimitsAreValid(
    const MacWSStreamWindowLimits *limits, size_t byteCount) {
    if (!limits || byteCount != sizeof(*limits) || !limits->windowID ||
        limits->ownerPID <= 1 ||
        !isfinite(limits->maximumLogicalWidth) ||
        !isfinite(limits->maximumLogicalHeight) ||
        limits->maximumLogicalWidth < 0 || limits->maximumLogicalHeight < 0 ||
        limits->maximumLogicalWidth > MACWS_STREAM_MAX_DIMENSION ||
        limits->maximumLogicalHeight > MACWS_STREAM_MAX_DIMENSION)
        return false;
    MacWSWindowConfigureAck ack = limits->configureAck;
    if (!isfinite(ack.timestamp) || ack.timestamp < 0) return false;
    if (ack.timestamp == 0)
        return ack.sequence == 0 && ack.requestedWidth == 0 &&
            ack.requestedHeight == 0 && ack.appliedWidth == 0 &&
            ack.appliedHeight == 0;
    return isfinite(ack.requestedWidth) && isfinite(ack.requestedHeight) &&
        isfinite(ack.appliedWidth) && isfinite(ack.appliedHeight) &&
        ack.requestedWidth > 0 && ack.requestedHeight > 0 &&
        ack.appliedWidth > 0 && ack.appliedHeight > 0 &&
        ack.requestedWidth <= MACWS_STREAM_MAX_DIMENSION &&
        ack.requestedHeight <= MACWS_STREAM_MAX_DIMENSION &&
        ack.appliedWidth <= MACWS_STREAM_MAX_DIMENSION &&
        ack.appliedHeight <= MACWS_STREAM_MAX_DIMENSION;
}

static inline bool MacWSStreamWindowDescriptorIsValid(
    const MacWSStreamWindowDescriptor *descriptor, size_t byteCount) {
    if (!descriptor || byteCount < sizeof(*descriptor) ||
        descriptor->magic != MACWS_STREAM_MAGIC ||
        descriptor->version != MACWS_STREAM_VERSION ||
        descriptor->size != sizeof(*descriptor) ||
        descriptor->windowID == 0 || descriptor->ownerPID <= 0 ||
        descriptor->logicalWidth <= 0.0f ||
        descriptor->logicalHeight <= 0.0f ||
        descriptor->pixelWidth == 0 || descriptor->pixelHeight == 0 ||
        descriptor->pixelWidth > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->pixelHeight > MACWS_STREAM_MAX_DIMENSION ||
        !(descriptor->minimumLogicalWidth >= 0.0f) ||
        !(descriptor->minimumLogicalHeight >= 0.0f) ||
        descriptor->minimumLogicalWidth > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->minimumLogicalHeight > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->backingScale <= 0.0f ||
        descriptor->backingScale > 8.0f) {
        return false;
    }
    return descriptor->titleLength <= byteCount - sizeof(*descriptor);
}

static inline bool MacWSStreamFrameDescriptorIsValid(
    const MacWSStreamFrameDescriptor *descriptor, size_t byteCount) {
    if (!descriptor || byteCount != sizeof(*descriptor) ||
        descriptor->magic != MACWS_STREAM_MAGIC ||
        descriptor->version != MACWS_STREAM_VERSION ||
        descriptor->size != sizeof(*descriptor) ||
        descriptor->streamID == 0 || descriptor->leaseToken == 0 ||
        descriptor->sequence == 0 || descriptor->width == 0 ||
        descriptor->height == 0 ||
        descriptor->width > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->height > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->bytesPerRow < descriptor->width * 4u ||
        descriptor->bytesPerRow > MACWS_STREAM_MAX_BYTES_PER_ROW ||
        descriptor->backingScale <= 0.0f ||
        descriptor->backingScale > 8.0f ||
        descriptor->damageRectCount > MACWS_STREAM_MAX_DAMAGE_RECTS ||
        descriptor->contentWidth == 0 || descriptor->contentHeight == 0 ||
        descriptor->contentX > descriptor->width ||
        descriptor->contentY > descriptor->height ||
        descriptor->contentWidth > descriptor->width - descriptor->contentX ||
        descriptor->contentHeight > descriptor->height - descriptor->contentY ||
        descriptor->layerWindowID == 0 ||
        descriptor->destinationWidth == 0 ||
        descriptor->destinationHeight == 0 ||
        descriptor->destinationWidth > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationHeight > MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationX < -(int32_t)MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationY < -(int32_t)MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationX > (int32_t)MACWS_STREAM_MAX_DIMENSION ||
        descriptor->destinationY > (int32_t)MACWS_STREAM_MAX_DIMENSION) {
        return false;
    }
    uint32_t allowedFlags = MacWSStreamFrameComplete |
        MacWSStreamFrameHasDamage | MacWSStreamFrameSizeChanged |
        MacWSStreamFrameOccluded | MacWSStreamFrameOverlay |
        MacWSStreamFrameGlobalSystemSurface |
        MacWSStreamFrameInputPassthrough |
        MacWSStreamFrameFinalComposite | MacWSStreamFrameNativePopupComposite;
    if ((descriptor->flags & ~allowedFlags) != 0) return false;
    if ((descriptor->flags & MacWSStreamFrameFinalComposite) != 0 &&
        ((descriptor->flags & MacWSStreamFrameOverlay) != 0 ||
         descriptor->windowID != 0)) return false;
    if ((descriptor->flags & MacWSStreamFrameNativePopupComposite) != 0 &&
        ((descriptor->flags & MacWSStreamFrameOverlay) == 0 ||
         (descriptor->flags & (MacWSStreamFrameFinalComposite |
             MacWSStreamFrameGlobalSystemSurface)) != 0 ||
         descriptor->windowID == 0 || descriptor->layerOwnerPID <= 1)) return false;
    return (uint64_t)descriptor->bytesPerRow * descriptor->height <= SIZE_MAX;
}

#if defined(__cplusplus)
static_assert(sizeof(MacWSStreamWindowDescriptor) == 64,
              "MacWS window descriptor ABI");
static_assert(sizeof(MacWSStreamFrameDescriptor) == 116,
              "MacWS frame descriptor ABI");
static_assert(sizeof(MacWSStreamLayerGeometry) == 68,
              "MacWS layer geometry ABI");
static_assert(sizeof(MacWSStreamDamageRect) == 16,
              "MacWS damage rect ABI");
static_assert(sizeof(MacWSGeometryInvalidation) == 20,
              "MacWS geometry invalidation ABI");
static_assert(sizeof(MacWSWindowMetricsHeader) == 24,
              "MacWS window metrics header ABI");
static_assert(sizeof(MacWSWindowConfigureAck) == 28, "Window configure ACK ABI");
static_assert(sizeof(MacWSStreamWindowLimits) == 44, "Window limits ABI");
static_assert(offsetof(MacWSWindowMetricsEntry, maximumLogicalWidth) == 20,
              "Window metrics V2 prefix ABI");
static_assert(sizeof(MacWSWindowMetricsEntry) == 56,
              "MacWS window metrics entry ABI");
#else
_Static_assert(sizeof(MacWSStreamWindowDescriptor) == 64,
               "MacWS window descriptor ABI");
_Static_assert(sizeof(MacWSStreamFrameDescriptor) == 116,
               "MacWS frame descriptor ABI");
_Static_assert(sizeof(MacWSStreamLayerGeometry) == 68,
               "MacWS layer geometry ABI");
_Static_assert(sizeof(MacWSStreamDamageRect) == 16,
               "MacWS damage rect ABI");
_Static_assert(sizeof(MacWSGeometryInvalidation) == 20,
               "MacWS geometry invalidation ABI");
_Static_assert(sizeof(MacWSWindowMetricsHeader) == 24,
               "MacWS window metrics header ABI");
_Static_assert(sizeof(MacWSWindowConfigureAck) == 28, "Window configure ACK ABI");
_Static_assert(sizeof(MacWSStreamWindowLimits) == 44, "Window limits ABI");
_Static_assert(offsetof(MacWSWindowMetricsEntry, maximumLogicalWidth) == 20,
               "Window metrics V2 prefix ABI");
_Static_assert(sizeof(MacWSWindowMetricsEntry) == 56,
               "MacWS window metrics entry ABI");
#endif

#endif
