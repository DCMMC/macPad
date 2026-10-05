// iosclear_ref — native-iOS reference for the AGX render-clear command ABI.
//
// Build this as arm64e/iOS and temporarily place it in a foreground UIKit app
// bundle.  A foreground app has the real iOS Metal/AGX setup that a headless
// ad-hoc tool does not.  The default path encodes one BGRA8 IOSurface clear.
// When /tmp/iosclear_draw_mode exists, it instead performs one
// IOSurface-to-IOSurface textured draw using QuartzCore's own read_surf_vert /
// read_surf_frag functions.  /tmp/iosclear_pf550_mode replaces the
// source with an exact reconstruction of WindowServer's two-plane compressed
// pf=550 scanout surface.  The BGRA modes prove execution with an exact pixel;
// pf550 mode treats command status/error as the witness because its compressed
// contents are intentionally uninitialized.
//
// This is diagnostic-only.  It does not load libmachook and does not patch any
// driver or command bytes.

@import Foundation;
@import IOSurface;
@import Metal;
@import UIKit;

#import <os/log.h>
#import <objc/runtime.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <signal.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

extern uint32_t IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef surface,
                                                    size_t plane);
extern size_t IOSurfaceGetHeightInCompressedTilesOfPlane(
    IOSurfaceRef surface, size_t plane);

static os_log_t g_log;

// MacWSHost links this file in library mode, so the standalone main() below
// does not get a chance to redirect stderr into os_log.  Keep a separate,
// opt-in diagnostic transcript for the native reference path.  Stage markers
// are deliberately written before and after each Metal call that can allocate,
// compile, submit, or wait; that makes a foreground-app stall attributable to
// a concrete API instead of process uptime or an un-symbolicated worker stack.
static const char *kMacWSReferenceLogPath =
    "/var/mobile/iosclear-reference.log";

static void macws_reference_log_reset(void) {
    int fd = open(kMacWSReferenceLogPath,
                  O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) close(fd);
}

static void macws_reference_log(const char *format, ...) {
    int fd = open(kMacWSReferenceLogPath,
                  O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    char line[2048];
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(line, sizeof(line), format, arguments);
    va_end(arguments);
    if (length < 0) {
        close(fd);
        return;
    }
    size_t used = (size_t)length < sizeof(line) - 2
        ? (size_t)length : sizeof(line) - 2;
    line[used++] = '\n';
    (void)write(fd, line, used);
    close(fd);
}

// Read-only native texture-descriptor control.  The same width/height
// invariant and address decoding are used by libmachook's WindowServer
// PageFault observer, so a compressed PF550 target can be compared without
// assuming that its auxiliary/acceleration address belongs to an ordinary
// IOGPU resource.  No descriptor byte or private ivar is modified.
static void macws_reference_log_texture_descriptor(id<MTLTexture> texture,
                                                    const char *role) {
    if (!texture) {
        macws_reference_log("TEXTURE-DESC role=%s texture=nil", role);
        return;
    }
    @try {
        size_t width = texture.width;
        size_t height = texture.height;
        ptrdiff_t impl_offset = 0x208;
        Ivar ivar = class_getInstanceVariable([texture class], "_impl");
        if (ivar) impl_offset = ivar_getOffset(ivar);
        void *impl = *(void **)((char *)(__bridge void *)texture + impl_offset);
        uint64_t gpu_mapping = impl
            ? *(const volatile uint64_t *)((const char *)impl + 0x40) : 0;
        for (ptrdiff_t offset = 0x140; impl && offset <= 0x240; offset++) {
            uint64_t word0 = 0, word1 = 0, extended_raw = 0;
            memcpy(&word0, (const char *)impl + offset, sizeof(word0));
            memcpy(&word1, (const char *)impl + offset + 8, sizeof(word1));
            size_t encoded_width = (size_t)((word0 >> 28) & 0x3fff) + 1;
            size_t encoded_height = (size_t)((word0 >> 42) & 0x3fff) + 1;
            if (encoded_width != width || encoded_height != height) continue;
            uint8_t bytes[24] = {0};
            memcpy(bytes, (const char *)impl + offset, sizeof(bytes));
            memcpy(&extended_raw, bytes + 16, sizeof(extended_raw));
            uint64_t address = ((word1 >> 2) & 0xfffffffffULL) << 4;
            uint64_t extended_low36 =
                (extended_raw & 0xfffffffffULL) << 4;
            char hex[sizeof(bytes) * 2 + 1] = {0};
            for (size_t index = 0; index < sizeof(bytes); index++) {
                snprintf(hex + index * 2, 3, "%02x", bytes[index]);
            }
            macws_reference_log(
                "TEXTURE-DESC role=%s texture=%p impl=%p %zux%zu pf=%lu "
                "gpu40=%#llx descOff=%#tx layout=%u compressed=%u "
                "extended=%u address=%#llx extendedLow36=%#llx "
                "extendedRaw=%#llx bytes=%s",
                role, (__bridge void *)texture, impl, width, height,
                (unsigned long)texture.pixelFormat,
                (unsigned long long)gpu_mapping, offset,
                (unsigned)((word0 >> 4) & 0x3),
                (unsigned)((word1 >> 39) & 1),
                (unsigned)((word1 >> 63) & 1),
                (unsigned long long)address,
                (unsigned long long)extended_low36,
                (unsigned long long)extended_raw, hex);
            return;
        }
        macws_reference_log(
            "TEXTURE-DESC role=%s texture=%p impl=%p %zux%zu pf=%lu NOT-FOUND",
            role, (__bridge void *)texture, impl, width, height,
            (unsigned long)texture.pixelFormat);
    } @catch (NSException *exception) {
        macws_reference_log("TEXTURE-DESC role=%s exception=%s", role,
            exception.description.UTF8String ?: "(nil)");
    }
}

static BOOL macws_is_relevant_agx_class(const char *name) {
    if (!name) return NO;
    if (strncmp(name, "AGX", 3) != 0 &&
        strncmp(name, "IOGPU", 5) != 0) return NO;
    return strstr(name, "Command") || strstr(name, "Render") ||
           strstr(name, "Context") || strstr(name, "Queue");
}

static void macws_dump_agx_method_list(FILE *output, Class cls,
                                       const char *kind) {
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    const char *name = class_getName(cls);
    Class superclass = class_getSuperclass(cls);
    fprintf(output,
        "IOSCLEAR AGX-CLASS kind=%s class=%p name=%s super=%s methods=%u\n",
        kind, (__bridge void *)cls, name ?: "(null)",
        superclass ? class_getName(superclass) : "(none)", count);
    unsigned int limit = count < 512 ? count : 512;
    for (unsigned int i = 0; i < limit; i++) {
        SEL selector = method_getName(methods[i]);
        IMP implementation = method_getImplementation(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        fprintf(output,
            "IOSCLEAR AGX-METHOD kind=%s class=%s index=%u imp=%p "
            "selector=%s types=%s\n",
            kind, name ?: "(null)", i, (void *)implementation,
            selector ? sel_getName(selector) : "(null)",
            types ?: "(null)");
    }
    free(methods);
}

static void macws_dump_agx_runtime(void) {
    FILE *output = fopen("/var/mobile/iosclear-agx-runtime.log", "w");
    if (!output) output = stderr;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    unsigned int matched = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!macws_is_relevant_agx_class(name)) continue;
        matched++;
        macws_dump_agx_method_list(output, classes[i], "instance");
        macws_dump_agx_method_list(output, object_getClass(classes[i]),
                                   "class");
    }
    fprintf(output,
        "IOSCLEAR AGX-RUNTIME classes=%u matched=%u complete=YES\n",
        count, matched);
    fflush(output);
    if (output != stderr) fclose(output);
    free(classes);
}

static void macws_save_commands(const char *phase, const void *bytes,
                                size_t length) {
    if (!phase || !bytes || !length || length > 0x10000) return;
    char path[PATH_MAX];
    int pathLength = snprintf(path, sizeof(path),
        "/var/mobile/iosclear-%s-kcmd.bin", phase);
    if (pathLength <= 0 || (size_t)pathLength >= sizeof(path)) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        fprintf(stderr, "IOSCLEAR %s KCMD save failed errno=%d\n",
            phase, errno);
        return;
    }
    const unsigned char *cursor = bytes;
    size_t written = 0;
    while (written < length) {
        ssize_t amount = write(fd, cursor + written, length - written);
        if (amount <= 0) break;
        written += (size_t)amount;
    }
    close(fd);
    fprintf(stderr, "IOSCLEAR %s KCMD saved=%zu/%zu path=%s\n",
        phase, written, length, path);
}

static size_t macws_dimension_from_env(const char *name, size_t fallback) {
    const char *value = getenv(name);
    if (!value || !*value) return fallback;
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    return end && *end == '\0' && parsed >= 1 && parsed <= 8192
        ? (size_t)parsed : fallback;
}

static __attribute__((unused)) int macws_log_write(
        void *cookie, const char *bytes, int count) {
    (void)cookie;
    static char line[2048];
    static int used;
    for (int i = 0; i < count; i++) {
        char c = bytes[i];
        if (c == '\n' || used == (int)sizeof(line) - 1) {
            line[used] = 0;
            if (used) os_log_error(g_log, "%{public}s", line);
            used = 0;
            if (c != '\n') line[used++] = c;
        } else {
            line[used++] = c;
        }
    }
    return count;
}

static void macws_dump_commands(id<MTLCommandBuffer> commandBuffer,
                                const char *phase) {
    SEL selector = NSSelectorFromString(
        @"getCurrentKernelCommandBufferStart:current:end:");
    if (![commandBuffer respondsToSelector:selector]) {
        fprintf(stderr, "IOSCLEAR %s no getCurrentKernelCommandBuffer SPI\n",
            phase);
        return;
    }

    void *start = NULL, *current = NULL, *end = NULL;
    IMP method = [(NSObject *)commandBuffer methodForSelector:selector];
    void (*implementation)(id, SEL, void **, void **, void **) =
        (void *)method;
    implementation(commandBuffer, selector, &start, &current, &end);
    size_t length = start && current > start
        ? (size_t)((uintptr_t)current - (uintptr_t)start) : 0;
    fprintf(stderr,
        "IOSCLEAR %s KCMD start=%p current=%p end=%p length=%#zx\n",
        phase, start, current, end, length);
    if (!start || !length || length > 0x10000) return;

    macws_save_commands(phase, start, length);

    const unsigned char *p = start;
    for (size_t off = 0; off < length; off += 32) {
        char line[256];
        int used = snprintf(line, sizeof(line),
            "IOSCLEAR %s +%04zx:", phase, off);
        for (size_t j = 0; j < 32 && off + j < length; j++) {
            used += snprintf(line + used, sizeof(line) - (size_t)used,
                " %02x", p[off + j]);
        }
        fprintf(stderr, "%s\n", line);
    }

    size_t off = 0;
    unsigned record = 0;
    while (off + 0x38 <= length && record < 16) {
        uint32_t type = *(const uint32_t *)(p + off);
        uint32_t next = *(const uint32_t *)(p + off + 0x28);
        uint32_t size = *(const uint32_t *)(p + off + 0x2c);
        uint32_t inner = *(const uint32_t *)(p + off + 0x30);
        uint32_t subtype = *(const uint32_t *)(p + off + 0x34);
        fprintf(stderr,
            "IOSCLEAR %s record[%u] off=%#zx type=%#x next=%#x "
            "size=%#x inner=%#x subtype=%u\n",
            phase, record++, off, type, next, size, inner, subtype);
        if ((type != 0x10000 && type != 0x10001) ||
            next < 0x38 || next > length - off) break;
        off += next;
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static IOSurfaceRef macws_create_bgra_surface(size_t width, size_t height) {
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
        (id)kIOSurfaceIsGlobal: @YES,
    };
    return IOSurfaceCreate((CFDictionaryRef)properties);
}
#pragma clang diagnostic pop

static IOSurfaceRef macws_create_pf550_surface(size_t width, size_t height) {
    // Runtime-captured verbatim from IOSurfaceCopyAllValues on WindowServer's
    // first 2388x1668 pf=550 CA framebuffer (2026-07-24).  The captured
    // values establish a 16x16 tile grid, 1024/256 data bytes per tile for
    // planes 0/1, and a 0x40000-byte header reservation after each plane's
    // tile-data region.  Parameterize that same layout so the native control
    // can match WindowServer's recurrent 1140x798 intermediate exactly.  A
    // successful native command completion is required before treating a new
    // geometry as a valid compressed-surface witness.
    size_t widthInTiles = (width + 15) / 16;
    size_t heightInTiles = (height + 15) / 16;
    size_t plane0BytesPerRow = widthInTiles * 1024;
    size_t plane1BytesPerRow = widthInTiles * 256;
    size_t plane0DataSize = plane0BytesPerRow * heightInTiles;
    size_t plane1DataSize = plane1BytesPerRow * heightInTiles;
    size_t plane0Size = plane0DataSize + 0x40000;
    size_t plane1Offset = plane0Size;
    size_t plane1HeaderOffset = plane1Offset + plane1DataSize;
    size_t plane1Size = plane1DataSize + 0x40000;
    size_t allocSize = plane0Size + plane1Size;
    NSDictionary *plane0 = @{
        @"IOSurfaceAddressFormat": @5,
        @"IOSurfacePlaneBytesPerCompressedTileHeader": @8,
        @"IOSurfacePlaneBytesPerElement": @1024,
        @"IOSurfacePlaneBytesPerRow": @(plane0BytesPerRow),
        @"IOSurfacePlaneBytesPerRowOfTileData": @(plane0BytesPerRow),
        @"IOSurfacePlaneBytesPerTileData": @1024,
        @"IOSurfacePlaneCompressedTileDataRegionOffset": @0,
        @"IOSurfacePlaneCompressedTileHeaderRegionOffset": @(plane0DataSize),
        @"IOSurfacePlaneCompressedTileHeight": @16,
        @"IOSurfacePlaneCompressedTileWidth": @16,
        @"IOSurfacePlaneCompressionFootprint": @0,
        @"IOSurfacePlaneCompressionType": @3,
        @"IOSurfacePlaneElementHeight": @16,
        @"IOSurfacePlaneElementWidth": @16,
        @"IOSurfacePlaneHeight": @(height),
        @"IOSurfacePlaneHeightInCompressedTiles": @(heightInTiles),
        @"IOSurfacePlaneOffset": @0,
        @"IOSurfacePlaneSize": @(plane0Size),
        @"IOSurfacePlaneWidth": @(width),
        @"IOSurfacePlaneWidthInCompressedTiles": @(widthInTiles),
    };
    NSDictionary *plane1 = @{
        @"IOSurfaceAddressFormat": @5,
        @"IOSurfacePlaneBytesPerCompressedTileHeader": @8,
        @"IOSurfacePlaneBytesPerElement": @256,
        @"IOSurfacePlaneBytesPerRow": @(plane1BytesPerRow),
        @"IOSurfacePlaneBytesPerRowOfTileData": @(plane1BytesPerRow),
        @"IOSurfacePlaneBytesPerTileData": @256,
        @"IOSurfacePlaneCompressedTileDataRegionOffset": @(plane1Offset),
        @"IOSurfacePlaneCompressedTileHeaderRegionOffset":
            @(plane1HeaderOffset),
        @"IOSurfacePlaneCompressedTileHeight": @16,
        @"IOSurfacePlaneCompressedTileWidth": @16,
        @"IOSurfacePlaneCompressionFootprint": @0,
        @"IOSurfacePlaneCompressionType": @3,
        @"IOSurfacePlaneElementHeight": @16,
        @"IOSurfacePlaneElementWidth": @16,
        @"IOSurfacePlaneHeight": @(height),
        @"IOSurfacePlaneHeightInCompressedTiles": @(heightInTiles),
        @"IOSurfacePlaneOffset": @(plane1Offset),
        @"IOSurfacePlaneSize": @(plane1Size),
        @"IOSurfacePlaneWidth": @(width),
        @"IOSurfacePlaneWidthInCompressedTiles": @(widthInTiles),
    };
    NSDictionary *properties = @{
        @"IOSurfaceAllocSize": @(allocSize),
        @"IOSurfaceCacheMode": @1792,
        @"IOSurfaceHeight": @(height),
        @"IOSurfaceMapCacheAttribute": @0,
        @"IOSurfaceMemoryRegion": @"PurpleGfxMem",
        @"IOSurfaceName": @"IOSCLEAR native pf550 reference",
        @"IOSurfacePixelFormat": @643969848,
        @"IOSurfacePixelSizeCastingAllowed": @0,
        @"IOSurfacePlaneInfo": @[plane0, plane1],
        @"IOSurfaceWidth": @(width),
    };
    IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)properties);
    fprintf(stderr,
        "IOSCLEAR PF550 geometry=%zux%zu tiles=%zux%zu alloc=%#zx "
        "compression-api plane=0 type=%u heightInTiles=%zu\n",
        width, height, widthInTiles, heightInTiles, allocSize,
        surface ? IOSurfaceGetCompressionTypeOfPlane(surface, 0) : UINT32_MAX,
        surface ? IOSurfaceGetHeightInCompressedTilesOfPlane(surface, 0)
                : SIZE_MAX);
    CFDictionaryRef actual = surface ? IOSurfaceCopyAllValues(surface) : NULL;
    fprintf(stderr, "IOSCLEAR PF550 surface=%p actual=%s\n", (void *)surface,
        actual ? [[(__bridge NSDictionary *)actual description] UTF8String]
               : "(null)");
    if (actual) CFRelease(actual);
    return surface;
}

static id<MTLTexture> macws_create_surface_texture(
    id<MTLDevice> device, IOSurfaceRef surface, size_t width, size_t height,
    MTLPixelFormat pixelFormat, MTLTextureUsage usage) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:pixelFormat
        width:width height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = usage;
    return surface ? [device newTextureWithDescriptor:descriptor
                                        iosurface:surface plane:0] : nil;
}

static void macws_fill_surface(IOSurfaceRef surface, size_t width,
                               size_t height, const unsigned char bgra[4]) {
    IOSurfaceLock(surface, 0, NULL);
    unsigned char *base = IOSurfaceGetBaseAddress(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    for (size_t y = 0; base && y < height; y++) {
        unsigned char *row = base + y * bytesPerRow;
        for (size_t x = 0; x < width; x++) {
            memcpy(row + x * 4, bgra, 4);
        }
    }
    IOSurfaceUnlock(surface, 0, NULL);
}

static void macws_run_textured_draw(id<MTLDevice> device,
                                    id<MTLCommandQueue> queue,
                                    size_t width, size_t height) {
    BOOL pf550Mode = getenv("IOSCLEAR_PF550_MODE") ||
        access("/tmp/iosclear_pf550_mode", F_OK) == 0;
    macws_reference_log("DRAW enter mode=%s width=%zu height=%zu device=%p queue=%p",
        pf550Mode ? "pf550" : "BGRA8", width, height,
        (__bridge void *)device, (__bridge void *)queue);
    macws_reference_log("DRAW before-source-surface");
    IOSurfaceRef sourceSurface = pf550Mode
        ? macws_create_pf550_surface(width, height)
        : macws_create_bgra_surface(width, height);
    macws_reference_log("DRAW after-source-surface source=%p", sourceSurface);
    macws_reference_log("DRAW before-destination-surface");
    IOSurfaceRef destinationSurface = macws_create_bgra_surface(width, height);
    macws_reference_log("DRAW after-destination-surface destination=%p",
        destinationSurface);
    const unsigned char expected[4] = {0x21, 0x43, 0x65, 0xff};
    if (sourceSurface && !pf550Mode) {
        macws_reference_log("DRAW before-fill-source");
        macws_fill_surface(sourceSurface, width, height, expected);
        macws_reference_log("DRAW after-fill-source");
    }

    macws_reference_log("DRAW before-source-texture");
    id<MTLTexture> sourceTexture = macws_create_surface_texture(
        device, sourceSurface, width, height,
        pf550Mode ? (MTLPixelFormat)550 : MTLPixelFormatBGRA8Unorm,
        pf550Mode ? (MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget)
                  : MTLTextureUsageShaderRead);
    macws_reference_log("DRAW after-source-texture texture=%p class=%s",
        (__bridge void *)sourceTexture,
        sourceTexture ? object_getClassName(sourceTexture) : "nil");
    macws_reference_log("DRAW before-destination-texture");
    id<MTLTexture> destinationTexture = macws_create_surface_texture(
        device, destinationSurface, width, height,
        MTLPixelFormatBGRA8Unorm,
        MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    macws_reference_log("DRAW after-destination-texture texture=%p class=%s",
        (__bridge void *)destinationTexture,
        destinationTexture ? object_getClassName(destinationTexture) : "nil");
    macws_reference_log_texture_descriptor(sourceTexture, "source");
    macws_reference_log_texture_descriptor(destinationTexture, "destination");
    fprintf(stderr,
        "IOSCLEAR DRAW mode=%s surfaces source=%p destination=%p "
        "textures=%p/%p classes=%s/%s\n",
        pf550Mode ? "pf550" : "BGRA8",
        (void *)sourceSurface, (void *)destinationSurface,
        (__bridge void *)sourceTexture, (__bridge void *)destinationTexture,
        sourceTexture ? object_getClassName(sourceTexture) : "nil",
        destinationTexture ? object_getClassName(destinationTexture) : "nil");

    NSError *error = nil;
    NSURL *libraryURL = [NSURL fileURLWithPath:
        @"/System/Library/Frameworks/QuartzCore.framework/default.metallib"];
    macws_reference_log("DRAW before-library path=%s",
        libraryURL.path.fileSystemRepresentation);
    id<MTLLibrary> library = [device newLibraryWithURL:libraryURL error:&error];
    macws_reference_log("DRAW after-library library=%p error=%s",
        (__bridge void *)library,
        error ? error.description.UTF8String : "nil");
    macws_reference_log("DRAW before-functions");
    id<MTLFunction> vertex = [library newFunctionWithName:@"read_surf_vert"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"read_surf_frag"];
    macws_reference_log("DRAW after-functions vertex=%p fragment=%p",
        (__bridge void *)vertex, (__bridge void *)fragment);
    MTLRenderPipelineDescriptor *pipelineDescriptor =
        [MTLRenderPipelineDescriptor new];
    pipelineDescriptor.label = @"IOSCLEAR QuartzCore read_surf reference";
    pipelineDescriptor.vertexFunction = vertex;
    pipelineDescriptor.fragmentFunction = fragment;
    pipelineDescriptor.colorAttachments[0].pixelFormat =
        MTLPixelFormatBGRA8Unorm;
    macws_reference_log("DRAW before-pipeline");
    id<MTLRenderPipelineState> pipeline = vertex && fragment
        ? [device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                                 error:&error] : nil;
    macws_reference_log("DRAW after-pipeline pipeline=%p error=%s",
        (__bridge void *)pipeline,
        error ? error.description.UTF8String : "nil");
    fprintf(stderr,
        "IOSCLEAR DRAW library=%p vertex=%p fragment=%p pipeline=%p error=%s\n",
        (__bridge void *)library, (__bridge void *)vertex,
        (__bridge void *)fragment, (__bridge void *)pipeline,
        error ? [[error description] UTF8String] : "nil");
    if (!sourceTexture || !destinationTexture || !pipeline) {
        macws_reference_log(
            "DRAW early-return sourceTexture=%p destinationTexture=%p pipeline=%p",
            (__bridge void *)sourceTexture,
            (__bridge void *)destinationTexture,
            (__bridge void *)pipeline);
        if (sourceSurface) CFRelease(sourceSurface);
        if (destinationSurface) CFRelease(destinationSurface);
        return;
    }

    MTLCommandBufferDescriptor *commandDescriptor =
        [MTLCommandBufferDescriptor new];
    commandDescriptor.retainedReferences = YES;
    commandDescriptor.errorOptions =
        MTLCommandBufferErrorOptionEncoderExecutionStatus;
    macws_reference_log("DRAW before-command-buffer");
    id<MTLCommandBuffer> commandBuffer =
        [queue commandBufferWithDescriptor:commandDescriptor];
    macws_reference_log("DRAW after-command-buffer commandBuffer=%p",
        (__bridge void *)commandBuffer);
    commandBuffer.label = @"IOSCLEAR native QuartzCore textured draw";

    MTLRenderPassDescriptor *renderPass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    renderPass.colorAttachments[0].texture = destinationTexture;
    // Keep this a draw-only reference.  A clear load action produces its own
    // render-state variant and obscures which subtype-1 fields belong to the
    // textured operation being compared with WindowServer.
    renderPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    macws_reference_log("DRAW before-render-encoder");
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
    macws_reference_log("DRAW after-render-encoder encoder=%p",
        (__bridge void *)encoder);
    encoder.label = @"IOSCLEAR native QuartzCore textured draw";
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:sourceTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    macws_reference_log("DRAW after-end-encoding");

    macws_reference_log("DRAW before-command-dump");
    macws_dump_commands(commandBuffer, "DRAW-PRE");
    macws_reference_log("DRAW after-command-dump");
    macws_reference_log("DRAW before-commit");
    [commandBuffer commit];
    macws_reference_log("DRAW after-commit status=%ld",
        (long)commandBuffer.status);
    macws_reference_log("DRAW before-wait");
    [commandBuffer waitUntilCompleted];
    macws_reference_log("DRAW after-wait status=%ld error=%s",
        (long)commandBuffer.status,
        commandBuffer.error ? commandBuffer.error.description.UTF8String
                            : "nil");

    IOSurfaceLock(destinationSurface, kIOSurfaceLockReadOnly, NULL);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(destinationSurface);
    const unsigned char *base = IOSurfaceGetBaseAddress(destinationSurface);
    const unsigned char *pixel = base
        ? base + (height / 2) * bytesPerRow + (width / 2) * 4 : NULL;
    BOOL match = !pf550Mode && pixel && memcmp(pixel, expected, 4) == 0;
    BOOL commandOK = [commandBuffer status] == MTLCommandBufferStatusCompleted &&
        [commandBuffer error] == nil;
    macws_reference_log(
        "DRAW result status=%ld commandOK=%s bpr=%zu center=%02x%02x%02x%02x match=%s",
        (long)commandBuffer.status, commandOK ? "YES" : "NO", bytesPerRow,
        pixel ? pixel[0] : 0, pixel ? pixel[1] : 0,
        pixel ? pixel[2] : 0, pixel ? pixel[3] : 0,
        match ? "YES" : "NO");
    fprintf(stderr,
        "IOSCLEAR DRAW-RESULT mode=%s status=%ld error=%s commandOK=%s "
        "bpr=%zu center=%02x%02x%02x%02x expected=%s match=%s\n",
        pf550Mode ? "pf550" : "BGRA8",
        (long)[commandBuffer status], [commandBuffer error]
            ? [[[commandBuffer error] description] UTF8String] : "nil",
        commandOK ? "YES" : "NO",
        bytesPerRow, pixel ? pixel[0] : 0, pixel ? pixel[1] : 0,
        pixel ? pixel[2] : 0, pixel ? pixel[3] : 0,
        pf550Mode ? "uninitialized" : "214365ff",
        match ? "YES" : "NO");
    IOSurfaceUnlock(destinationSurface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(sourceSurface);
    CFRelease(destinationSurface);
}

void MacWSRunIOSClearReference(void) {
    @autoreleasepool {
        macws_reference_log_reset();
        macws_reference_log("REFERENCE enter pid=%d", getpid());
        // Some FrontBoard-launched diagnostics cannot be attached reliably
        // while they are already stopped in raise(SIGSTOP): debugserver owns
        // the task, but never reaches its remote-protocol listen state.  This
        // opt-in bounded delay leaves the task runnable until LLDB attaches.
        // It is diagnostic-only and does not alter the default execution path.
        if (getenv("IOSCLEAR_EARLY_DELAY") ||
            access("/tmp/iosclear_early_delay", F_OK) == 0) {
            const char *configured = getenv("IOSCLEAR_EARLY_DELAY");
            unsigned long seconds = configured ? strtoul(configured, NULL, 10)
                                               : 8;
            if (seconds < 1 || seconds > 15) seconds = 8;
            fprintf(stderr,
                "IOSCLEAR EARLY-DELAY %lu seconds before MTL device "
                "creation pid=%d (attach project LLDB)\n",
                seconds, getpid());
            sleep((unsigned)seconds);
        }
        // Diagnostic attach point: unlike IOSCLEAR_HOLD below, this stops
        // before MTLCreateSystemDefaultDevice so project LLDB can observe the
        // complete native IOGPU setup/resource-create sequence.  The sentinel
        // is convenient for a UIKit app launched by FrontBoard, where adding
        // process environment variables is awkward.  It has no effect unless
        // explicitly armed and is intentionally confined to this reference
        // diagnostic.
        if (getenv("IOSCLEAR_EARLY_HOLD") ||
            access("/tmp/iosclear_early_hold", F_OK) == 0) {
            fprintf(stderr,
                "IOSCLEAR EARLY-HOLD before MTL device creation pid=%d "
                "(attach project LLDB)\n",
                getpid());
            raise(SIGSTOP);
        }
        macws_reference_log("REFERENCE before-device");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        macws_reference_log("REFERENCE after-device device=%p class=%s name=%s",
            (__bridge void *)device,
            device ? object_getClassName(device) : "nil",
            device ? device.name.UTF8String : "nil");
        macws_reference_log("REFERENCE before-queue");
        id<MTLCommandQueue> queue = [device newCommandQueue];
        macws_reference_log("REFERENCE after-queue queue=%p class=%s",
            (__bridge void *)queue,
            queue ? object_getClassName(queue) : "nil");
        fprintf(stderr, "IOSCLEAR device=%p class=%s name=%s queue=%p\n",
            (__bridge void *)device,
            device ? object_getClassName(device) : "nil",
            device ? [[device name] UTF8String] : "nil",
            (__bridge void *)queue);
        if (!device || !queue) {
            macws_reference_log("REFERENCE early-return device=%p queue=%p",
                (__bridge void *)device, (__bridge void *)queue);
            return;
        }
        if (getenv("IOSCLEAR_DUMP_AGX_METHODS") ||
            access("/tmp/iosclear_dump_agx_methods", F_OK) == 0) {
            macws_dump_agx_runtime();
        }

        size_t width = macws_dimension_from_env("IOSCLEAR_WIDTH", 64);
        size_t height = macws_dimension_from_env("IOSCLEAR_HEIGHT", 64);
        // FrontBoard launch does not offer a convenient per-run environment
        // override.  This diagnostic sentinel selects the iPad13,6 native
        // framebuffer dimensions used by the WindowServer/VNC comparison.
        if (access("/tmp/iosclear_hires", F_OK) == 0) {
            width = 2388;
            height = 1668;
        }
        // Exact WindowServer Terminal intermediate geometry.  FrontBoard
        // launches do not inherit a convenient per-run environment, so keep
        // this as an explicit diagnostic sentinel just like iosclear_hires.
        // It allows the native iOS textured record to be compared against the
        // recurrent 1140x798 chroot PageFault without a geometry confounder.
        if (access("/tmp/iosclear_terminal_size", F_OK) == 0) {
            width = 1140;
            height = 798;
        }
        macws_reference_log("REFERENCE dimensions width=%zu height=%zu", width,
            height);
        if (getenv("IOSCLEAR_DRAW_MODE") ||
            access("/tmp/iosclear_draw_mode", F_OK) == 0) {
            fprintf(stderr,
                "IOSCLEAR DRAW-MODE QuartzCore read_surf %zux%zu\n",
                width, height);
            macws_run_textured_draw(device, queue, width, height);
            macws_reference_log("REFERENCE draw-returned");
            return;
        }

        IOSurfaceRef surface = macws_create_bgra_surface(width, height);
        id<MTLTexture> texture = macws_create_surface_texture(
            device, surface, width, height,
            MTLPixelFormatBGRA8Unorm,
            MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        fprintf(stderr, "IOSCLEAR surface=%p texture=%p class=%s\n",
            (void *)surface, (__bridge void *)texture,
            texture ? object_getClassName(texture) : "nil");
        if (!surface || !texture) return;

        MTLCommandBufferDescriptor *commandDescriptor =
            [MTLCommandBufferDescriptor new];
        commandDescriptor.retainedReferences = YES;
        commandDescriptor.errorOptions =
            MTLCommandBufferErrorOptionEncoderExecutionStatus;
        id<MTLCommandBuffer> commandBuffer =
            [queue commandBufferWithDescriptor:commandDescriptor];
        commandBuffer.label = @"IOSCLEAR native clear reference";

        MTLRenderPassDescriptor *renderPass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        renderPass.colorAttachments[0].texture = texture;
        renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPass.colorAttachments[0].clearColor =
            MTLClearColorMake(0.125, 0.25, 0.5, 1.0);
        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
        encoder.label = @"IOSCLEAR native clear reference";
        [encoder endEncoding];

        macws_dump_commands(commandBuffer, "PRE");
        if (getenv("IOSCLEAR_HOLD")) {
            fprintf(stderr,
                "IOSCLEAR HOLD before commit pid=%d (attach project LLDB)\n",
                getpid());
            raise(SIGSTOP);
        }
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        // Do not call getCurrentKernelCommandBuffer... after completion.  The
        // iOS implementation releases its state before waitUntilCompleted
        // returns in a headless process; runtime crash evidence showed the
        // method dereferencing state+0x28 through NULL.  Project LLDB captures
        // the populated state synchronously at IOConnectCallMethod(sel=0x1a).

        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
        const unsigned char *base = IOSurfaceGetBaseAddress(surface);
        const unsigned char *pixel = base
            ? base + (height / 2) * bytesPerRow + (width / 2) * 4 : NULL;
        fprintf(stderr,
            "IOSCLEAR RESULT status=%ld error=%s bpr=%zu center=%02x%02x%02x%02x\n",
            (long)[commandBuffer status], [commandBuffer error]
                ? [[[commandBuffer error] description] UTF8String] : "nil",
            bytesPerRow, pixel ? pixel[0] : 0, pixel ? pixel[1] : 0,
            pixel ? pixel[2] : 0, pixel ? pixel[3] : 0);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        CFRelease(surface);
    }
}

#if !defined(IOSCLEAR_LIBRARY_MODE)
@interface IOSClearAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation IOSClearAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            MacWSRunIOSClearReference();
        });
    return YES;
}
@end

int main(int argc, char **argv) {
    g_log = os_log_create("com.dcmmc.iosclear", "reference");
    FILE *stream = funopen(NULL, NULL, macws_log_write, NULL, NULL);
    if (stream) {
        setvbuf(stream, NULL, _IONBF, 0);
        stderr = stream;
    }
    fprintf(stderr, "IOSCLEAR main pid=%d\n", getpid());
    // Lock-screen fallback for diagnostics.  This deliberately runs the same
    // binary/entitlements without UIApplication foreground activation.  If
    // MTLCreateSystemDefaultDevice fails here, that is runtime evidence that
    // the foreground sandbox extension (not merely platform-application) is
    // required; the normal UIKit path remains the authoritative reference.
    if (getenv("IOSCLEAR_HEADLESS")) {
        fprintf(stderr, "IOSCLEAR entering headless fallback\n");
        MacWSRunIOSClearReference();
        sleep(2);
        return 0;
    }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass(IOSClearAppDelegate.class));
    }
}
#endif
