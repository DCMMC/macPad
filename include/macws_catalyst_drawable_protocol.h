#ifndef MACWS_CATALYST_DRAWABLE_PROTOCOL_H
#define MACWS_CATALYST_DRAWABLE_PROTOCOL_H

#include <stdbool.h>
#include <mach/mach.h>
#include <stddef.h>
#include <stdint.h>

// The stripped iPhoneOS SDK used by Theos omits servers/bootstrap.h even
// though these libSystem exports are present on the target. Keep the narrow
// ABI declarations beside the protocol that needs them.
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(
    mach_port_t bootstrapPort, const char *serviceName,
    mach_port_t *servicePort);
extern kern_return_t bootstrap_register(
    mach_port_t bootstrapPort, const char *serviceName,
    mach_port_t servicePort);
#ifndef BOOTSTRAP_SUCCESS
#define BOOTSTRAP_SUCCESS KERN_SUCCESS
#endif

// A Catalyst application carried by MacWSHost can present a CAMetalLayer
// drawable that is not folded into SkyLight's exact-window capture surface.
// The title bar still reaches CGDisplayStream, but its client area is black.
// Transfer a Mach right for the real drawable IOSurface so the foreground Host
// can compose it over that black client area without an RFB/CPU copy. The
// numeric IOSurface ID remains diagnostic metadata; cross-task ownership is
// carried only by the port descriptor.
#define MACWS_CATALYST_DRAWABLE_MAGIC 0x4d574344u /* "MWCD" */
#define MACWS_CATALYST_DRAWABLE_VERSION 3u
#define MACWS_CATALYST_DRAWABLE_MACH_SERVICE \
    "com.macwsguide.catalyst-drawable"
#define MACWS_CATALYST_DRAWABLE_MACH_MESSAGE_ID 0x4d574344

typedef uint32_t MacWSCatalystDrawableFlags;
enum {
    // The producer incremented the IOSurface cross-process use count before
    // sending this record.  A receiver that accepts the frame adopts that
    // exact count and must decrement it only after its last GPU reference has
    // completed.  This closes the old race where CAMetalLayer recycled a
    // drawable while Host was still sampling it, producing mixed old/new
    // tiles.  Rejected deliveries return the count synchronously.
    MacWSCatalystDrawableTransfersUseCount = 1u << 0,
    // The producer's presentation layer declares this IOSurface fully
    // opaque.  Consumers may use that semantic guarantee to elide pixels
    // which are completely covered by the drawable, but must continue to
    // blend records which do not carry this bit.  This is deliberately a
    // producer-owned property rather than an inference from a few sampled
    // pixels.
    MacWSCatalystDrawableOpaque = 1u << 1,
};

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    // Logical AppKit owner selected by displayd's fresh focused-window
    // authority. For an ordinary game this is also the sender. Chromium's
    // root GPU helper publishes on behalf of its focused Electron parent.
    int32_t ownerPID;
    // Exact Mach-message sender. The receiver compares this field with the
    // audit trailer before trusting ownerPID. Keeping both identities avoids
    // asking sandboxed MacWSHost to inspect a root chroot process hierarchy;
    // the root producer and displayd independently validate that hierarchy.
    int32_t producerPID;
    uint32_t surfaceID;
    uint64_t sequence;
    uint64_t completionTime;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t ioSurfacePixelFormat;
    uint32_t metalPixelFormat;
    uint32_t flags;
} MacWSCatalystDrawableRecord;

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surfacePort;
    MacWSCatalystDrawableRecord record;
} MacWSCatalystDrawableMachMessage;

static inline bool MacWSCatalystDrawableRecordIsValid(
        const MacWSCatalystDrawableRecord *record, size_t byteCount) {
    if (!record || byteCount != sizeof(*record) ||
        record->magic != MACWS_CATALYST_DRAWABLE_MAGIC ||
        record->version != MACWS_CATALYST_DRAWABLE_VERSION ||
        record->size != sizeof(*record) || record->ownerPID <= 1 ||
        record->producerPID <= 1 ||
        record->surfaceID == 0 || record->width == 0 ||
        record->height == 0 || record->width > 16384u ||
        record->height > 16384u || record->bytesPerRow > 16384u * 16u ||
        (record->flags & ~(MacWSCatalystDrawableTransfersUseCount |
                           MacWSCatalystDrawableOpaque)) != 0)
        return false;
    return record->bytesPerRow >= record->width * 4u;
}

#endif
