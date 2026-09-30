#pragma once

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>

#include "macws_catalyst_drawable_protocol.h"

FOUNDATION_EXPORT NSNotificationName const
    MacWSCatalystDrawableDidPresentNotification;

// Synchronous process-local envelope for one authenticated Mach delivery.
// The receiver owns `surface` until notification delivery returns; an
// accepting compositor creates its own retained frame before setting
// accepted. Keeping the fixed-size record inline avoids NSData/dictionary
// allocation and hash lookups on every 120-Hz frame.
@interface MacWSCatalystDrawableDelivery : NSObject
@property(nonatomic, readonly) MacWSCatalystDrawableRecord record;
@property(nonatomic, readonly, assign) IOSurfaceRef surface;
@property(nonatomic, getter=isAccepted) BOOL accepted;
- (instancetype)initWithRecord:(MacWSCatalystDrawableRecord)record
                        surface:(IOSurfaceRef)surface;
@end

// Starts the authenticated Catalyst IOSurface transport exactly once.
void MacWSStartCatalystDrawableReceiver(void);
