#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

#include "macws_catalyst_drawable_protocol.h"

NS_ASSUME_NONNULL_BEGIN

// Immutable ownership unit for one completed Catalyst CAMetalLayer drawable.
// The IOSurface lifetime is retained with the texture so callers never need to
// coordinate Mach-right or CF ownership with the render loop.
@interface MacWSCatalystDrawableFrame : NSObject
@property(nonatomic, readonly) MacWSCatalystDrawableRecord record;
@property(nonatomic, readonly) id<MTLTexture> texture;
@property(nonatomic, readonly) IOSurfaceRef surface;
@end

// Imports validated Catalyst IOSurface deliveries.  The newest frame remains
// available for identity/probe callers, while the display-clock consumer gets
// a bounded two-frame FIFO. Runtime profiling at 120 Hz showed that a
// single-frame latest mailbox reduced receipt latency but discarded 5% of
// frames that the following display tick could otherwise consume. Two frames
// preserve that phase-crossing throughput without unbounded backlog.
// IOSurface texture views are
// cached separately because CAMetalLayer normally cycles a three-surface pool.
// Transport remains in Transport/; this class is the rendering-side policy
// and lifetime boundary.
@interface MacWSCatalystDrawableCompositor : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable MacWSCatalystDrawableFrame *)consumeDeliveryObject:(id)object
    shouldAcceptOwner:(BOOL (^)(int32_t ownerPID))shouldAcceptOwner;
- (nullable MacWSCatalystDrawableFrame *)frameForOwnerPID:(int32_t)ownerPID;
- (nullable MacWSCatalystDrawableFrame *)dequeueFrameForOwnerPID:
    (int32_t)ownerPID;
- (void)associateFrame:(MacWSCatalystDrawableFrame *)frame
          withOwnerPID:(int32_t)ownerPID;
- (void)removeAllFrames;
@end

// Draw a complete Catalyst client texture into the client portion of one
// SkyLight window. Coordinates are backing pixels in the source composite;
// contentRect/viewSize describe the already-established Host viewport.
// Returns NO when the geometry is empty or invalid.
BOOL MacWSEncodeCatalystDrawable(
    id<MTLRenderCommandEncoder> encoder,
    MacWSCatalystDrawableFrame *frame,
    CGRect windowDestination,
    CGRect visiblePixels,
    CGRect contentRect,
    CGSize viewSize,
    CGFloat titlebarHeightPixels);

NS_ASSUME_NONNULL_END
