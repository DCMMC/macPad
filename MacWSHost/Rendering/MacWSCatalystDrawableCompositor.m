#import "MacWSCatalystDrawableCompositor.h"

#import "MacWSHostDiagnostics.h"
#import "MacWSCatalystDrawableReceiver.h"

#import <IOSurface/IOSurfaceRef.h>
#import <simd/simd.h>
#include <string.h>

@interface NSObject (MacWSCatalystIOSurfaceAlignment)
- (NSUInteger)iosurfaceReadOnlyTextureAlignmentBytes;
@end

@interface MacWSCatalystDrawableFrame ()
- (instancetype)initWithRecord:(MacWSCatalystDrawableRecord)record
                        surface:(IOSurfaceRef)surface
                        texture:(id<MTLTexture>)texture;
@end

@implementation MacWSCatalystDrawableFrame {
    IOSurfaceRef _surface;
    BOOL _holdsTransferredUseCount;
}

- (instancetype)initWithRecord:(MacWSCatalystDrawableRecord)record
                        surface:(IOSurfaceRef)surface
                        texture:(id<MTLTexture>)texture {
    self = [super init];
    if (!self) return nil;
    _record = record;
    _surface = surface ? (IOSurfaceRef)CFRetain(surface) : NULL;
    _holdsTransferredUseCount = surface &&
        (record.flags & MacWSCatalystDrawableTransfersUseCount) != 0;
    _texture = texture;
    return self;
}

- (void)dealloc {
    if (_surface && _holdsTransferredUseCount)
        IOSurfaceDecrementUseCount(_surface);
    if (_surface) CFRelease(_surface);
}

- (IOSurfaceRef)surface {
    return _surface;
}

@end


@implementation MacWSCatalystDrawableCompositor {
    id<MTLDevice> _device;
    NSMutableDictionary<NSNumber *, MacWSCatalystDrawableFrame *> *_frames;
    NSMutableDictionary<NSNumber *, NSMutableArray<MacWSCatalystDrawableFrame *> *>
        *_pendingFrames;
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *_texturesBySurfaceID;
    NSMutableArray<NSNumber *> *_textureLRU;
    uint64_t _textureCacheHits;
    uint64_t _textureCacheMisses;
    BOOL _reportedGeometryRejection;
    BOOL _reportedTextureRejection;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _device = device;
    _frames = [NSMutableDictionary dictionary];
    _pendingFrames = [NSMutableDictionary dictionary];
    _texturesBySurfaceID = [NSMutableDictionary dictionary];
    _textureLRU = [NSMutableArray array];
    return self;
}

- (MacWSCatalystDrawableFrame *)consumeDeliveryObject:(id)object
    shouldAcceptOwner:(BOOL (^)(int32_t))shouldAcceptOwner {
    MacWSCatalystDrawableDelivery *delivery =
        [object isKindOfClass:MacWSCatalystDrawableDelivery.class]
            ? (MacWSCatalystDrawableDelivery *)object : nil;
    // One producer message transfers exactly one IOSurface use count. The
    // process-global notification can have several Scene observers, so the
    // first eligible consumer owns the delivery and every later observer must
    // reject it. NotificationCenter invokes these observers synchronously on
    // the receiver's main queue, making the delivery envelope the serialization
    // boundary rather than an advisory success flag.
    if (!delivery || delivery.isAccepted) return nil;
    IOSurfaceRef surface = delivery.surface;
    if (!_device || !surface) return nil;

    MacWSCatalystDrawableRecord record = delivery.record;
    if (!MacWSCatalystDrawableRecordIsValid(&record, sizeof(record))) return nil;
    if (shouldAcceptOwner && !shouldAcceptOwner(record.ownerPID)) {
        static BOOL reportedOwnerRejection = NO;
        if (!reportedOwnerRejection) {
            reportedOwnerRejection = YES;
            MacWSLog(@"catalyst-drawable reject-owner pid=%d sequence=%llu",
                     record.ownerPID,
                     (unsigned long long)record.sequence);
        }
        return nil;
    }

    NSNumber *ownerKey = @(record.ownerPID);
    MacWSCatalystDrawableFrame *previous = _frames[ownerKey];
    if (previous && previous.record.sequence >= record.sequence) return nil;

    BOOL geometryMatches = IOSurfaceGetWidth(surface) == record.width &&
        IOSurfaceGetHeight(surface) == record.height &&
        IOSurfaceGetBytesPerRow(surface) == record.bytesPerRow &&
        IOSurfaceGetPixelFormat(surface) == record.ioSurfacePixelFormat;
    NSUInteger alignment = [_device respondsToSelector:
        @selector(iosurfaceReadOnlyTextureAlignmentBytes)]
        ? [(id)_device iosurfaceReadOnlyTextureAlignmentBytes] : 0;
    if (!geometryMatches ||
        (alignment && record.bytesPerRow % alignment != 0)) {
        if (!_reportedGeometryRejection) {
            _reportedGeometryRejection = YES;
            MacWSLog(@"catalyst-drawable reject-geometry pid=%d sequence=%llu "
                     "record=%ux%u/bpr%u/pf%u actual=%zux%zu/bpr%zu/pf%u "
                     "alignment=%lu remainder=%lu",
                     record.ownerPID, (unsigned long long)record.sequence,
                     record.width, record.height, record.bytesPerRow,
                     record.ioSurfacePixelFormat, IOSurfaceGetWidth(surface),
                     IOSurfaceGetHeight(surface),
                     IOSurfaceGetBytesPerRow(surface),
                     IOSurfaceGetPixelFormat(surface),
                     (unsigned long)alignment,
                     (unsigned long)(alignment
                         ? record.bytesPerRow % alignment : 0));
        }
        return nil;
    }

    // CAMetalLayer rotates a small IOSurface pool. Importing a fresh Metal
    // texture view for every present needlessly repeats kernel/object setup on
    // UIKit's main thread and can make the panel-clock callback miss vblanks.
    // Cache by the IOSurface global ID, but validate immutable geometry before
    // reuse. Keeping at most three views mirrors the producer drawable pool and
    // prevents the cache from becoming a second unbounded surface owner.
    NSNumber *surfaceKey = @(record.surfaceID);
    id<MTLTexture> texture = _texturesBySurfaceID[surfaceKey];
    BOOL reusableTexture = texture &&
        texture.width == record.width && texture.height == record.height &&
        texture.pixelFormat == MTLPixelFormatBGRA8Unorm;
    if (reusableTexture) {
        _textureCacheHits++;
        [_textureLRU removeObject:surfaceKey];
        [_textureLRU addObject:surfaceKey];
    } else {
        if (texture) {
            [_texturesBySurfaceID removeObjectForKey:surfaceKey];
            [_textureLRU removeObject:surfaceKey];
        }
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                MTLPixelFormatBGRA8Unorm width:record.width height:record.height
                mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        texture = [_device newTextureWithDescriptor:descriptor
                                          iosurface:surface
                                              plane:0];
        if (texture) {
            _textureCacheMisses++;
            _texturesBySurfaceID[surfaceKey] = texture;
            [_textureLRU addObject:surfaceKey];
            while (_textureLRU.count > 3) {
                NSNumber *retiredKey = _textureLRU.firstObject;
                [_textureLRU removeObjectAtIndex:0];
                [_texturesBySurfaceID removeObjectForKey:retiredKey];
            }
        }
    }
    if (!texture) {
        if (!_reportedTextureRejection) {
            _reportedTextureRejection = YES;
            MacWSLog(@"catalyst-drawable reject-texture pid=%d sequence=%llu "
                     "size=%ux%u bpr=%u metal-pf=%u",
                     record.ownerPID, (unsigned long long)record.sequence,
                     record.width, record.height, record.bytesPerRow,
                     record.metalPixelFormat);
        }
        return nil;
    }

    MacWSCatalystDrawableFrame *frame =
        [[MacWSCatalystDrawableFrame alloc] initWithRecord:record
                                                   surface:surface
                                                   texture:texture];
    _frames[ownerKey] = frame;
    NSMutableArray<MacWSCatalystDrawableFrame *> *pending =
        _pendingFrames[ownerKey];
    if (!pending) {
        pending = [NSMutableArray arrayWithCapacity:3];
        _pendingFrames[ownerKey] = pending;
    }
    [pending addObject:frame];
    // Runtime-confirmed by the 2026-09-30 TestUFO focused-layer profile on
    // iPad13,6: the producer delivered 2,640 unique frames in 21.79 seconds,
    // enough to fill every 120-Hz panel slot, but a two-entry FIFO discarded
    // burst arrivals and then left 197/2,607 scheduler ticks empty. The
    // visible result was 110.54 fps with a 16.67-ms p95. Retain one entry for
    // each IOSurface in Chromium's real three-surface pool so short producer /
    // panel phase crossings are absorbed instead of becoming a visible missed
    // vblank. This does not allocate another texture or synthesize a frame;
    // the existing three-entry texture cache remains the matching lifetime
    // bound and every dequeued record is still a real completed generation.
    while (pending.count > 3)
        [pending removeObjectAtIndex:0];
    // Notification delivery is synchronous. Mark the delivery envelope only
    // after the IOSurface-backed texture and frame lease both exist; the
    // receiver returns the producer-transferred use count on every rejected
    // path.
    delivery.accepted = YES;
    if (!previous) {
        MacWSLog(@"runtime-confirmed catalyst-drawable imported owner=%d "
                 "producer=%d surface=%u size=%ux%u bpr=%u metal-pf=%u",
                 record.ownerPID, record.producerPID, record.surfaceID, record.width,
                 record.height, record.bytesPerRow, record.metalPixelFormat);
    }
    uint64_t imports = _textureCacheHits + _textureCacheMisses;
    // One steady-state witness is enough. Repeated diagnostic file writes in
    // the normal 120-Hz path would themselves distort the power measurement.
    if (imports == 240) {
        MacWSLog(@"runtime-confirmed catalyst-texture-cache hits=%llu "
                 "misses=%llu resident=%lu pending=%lu",
                 (unsigned long long)_textureCacheHits,
                 (unsigned long long)_textureCacheMisses,
                 (unsigned long)_texturesBySurfaceID.count,
                 (unsigned long)pending.count);
    }
    return frame;
}

- (MacWSCatalystDrawableFrame *)frameForOwnerPID:(int32_t)ownerPID {
    return ownerPID > 1 ? _frames[@(ownerPID)] : nil;
}

- (MacWSCatalystDrawableFrame *)dequeueFrameForOwnerPID:(int32_t)ownerPID {
    if (ownerPID <= 1) return nil;
    NSNumber *ownerKey = @(ownerPID);
    NSMutableArray<MacWSCatalystDrawableFrame *> *pending =
        _pendingFrames[ownerKey];
    MacWSCatalystDrawableFrame *frame = pending.firstObject;
    if (!frame) return nil;
    [pending removeObjectAtIndex:0];
    if (pending.count == 0) [_pendingFrames removeObjectForKey:ownerKey];
    return frame;
}

- (void)associateFrame:(MacWSCatalystDrawableFrame *)frame
          withOwnerPID:(int32_t)ownerPID {
    if (!frame || ownerPID <= 1) return;
    MacWSCatalystDrawableFrame *current = _frames[@(ownerPID)];
    if (!current || current.record.sequence <= frame.record.sequence)
        _frames[@(ownerPID)] = frame;
}

- (void)removeAllFrames {
    [_pendingFrames removeAllObjects];
    [_frames removeAllObjects];
    [_textureLRU removeAllObjects];
    [_texturesBySurfaceID removeAllObjects];
}

@end


BOOL MacWSEncodeCatalystDrawable(
    id<MTLRenderCommandEncoder> encoder,
    MacWSCatalystDrawableFrame *frame,
    CGRect windowDestination,
    CGRect visiblePixels,
    CGRect contentRect,
    CGSize viewSize,
    CGFloat titlebarHeightPixels) {
    if (!encoder || !frame.texture || viewSize.width <= 0 ||
        viewSize.height <= 0 || CGRectIsEmpty(windowDestination) ||
        CGRectIsEmpty(visiblePixels) || CGRectIsEmpty(contentRect)) return NO;

    CGFloat titlebar = fmin(fmax(titlebarHeightPixels, 0.0),
                            CGRectGetHeight(windowDestination));
    CGRect clientDestination = CGRectMake(
        CGRectGetMinX(windowDestination),
        CGRectGetMinY(windowDestination) + titlebar,
        CGRectGetWidth(windowDestination),
        CGRectGetHeight(windowDestination) - titlebar);
    CGRect clipped = CGRectIntersection(clientDestination, visiblePixels);
    if (CGRectIsNull(clipped) || CGRectIsEmpty(clipped)) return NO;

    CGFloat viewLeft = CGRectGetMinX(contentRect) +
        (CGRectGetMinX(clipped) - CGRectGetMinX(visiblePixels)) /
            CGRectGetWidth(visiblePixels) * CGRectGetWidth(contentRect);
    CGFloat viewRight = CGRectGetMinX(contentRect) +
        (CGRectGetMaxX(clipped) - CGRectGetMinX(visiblePixels)) /
            CGRectGetWidth(visiblePixels) * CGRectGetWidth(contentRect);
    CGFloat viewTop = CGRectGetMinY(contentRect) +
        (CGRectGetMinY(clipped) - CGRectGetMinY(visiblePixels)) /
            CGRectGetHeight(visiblePixels) * CGRectGetHeight(contentRect);
    CGFloat viewBottom = CGRectGetMinY(contentRect) +
        (CGRectGetMaxY(clipped) - CGRectGetMinY(visiblePixels)) /
            CGRectGetHeight(visiblePixels) * CGRectGetHeight(contentRect);

    // The Catalyst drawable includes UIKit's complete layer coordinate space,
    // while SkyLight supplies AppKit's title bar independently. Preserve the
    // established source mapping by cropping the title-bar fraction from the
    // drawable instead of stretching its full height into the client rect.
    float textureLeft = (CGRectGetMinX(clipped) -
        CGRectGetMinX(windowDestination)) / CGRectGetWidth(windowDestination);
    float textureRight = (CGRectGetMaxX(clipped) -
        CGRectGetMinX(windowDestination)) / CGRectGetWidth(windowDestination);
    float textureTop = (CGRectGetMinY(clipped) -
        CGRectGetMinY(windowDestination)) / CGRectGetHeight(windowDestination);
    float textureBottom = (CGRectGetMaxY(clipped) -
        CGRectGetMinY(windowDestination)) / CGRectGetHeight(windowDestination);
    simd_float4 vertices[4] = {
        {(float)(viewLeft / viewSize.width * 2.0 - 1.0),
         (float)(1.0 - viewBottom / viewSize.height * 2.0),
         textureLeft, textureBottom},
        {(float)(viewRight / viewSize.width * 2.0 - 1.0),
         (float)(1.0 - viewBottom / viewSize.height * 2.0),
         textureRight, textureBottom},
        {(float)(viewLeft / viewSize.width * 2.0 - 1.0),
         (float)(1.0 - viewTop / viewSize.height * 2.0),
         textureLeft, textureTop},
        {(float)(viewRight / viewSize.width * 2.0 - 1.0),
         (float)(1.0 - viewTop / viewSize.height * 2.0),
         textureRight, textureTop},
    };
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [encoder setFragmentTexture:frame.texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0 vertexCount:4];
    return YES;
}
