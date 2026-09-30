#import "MacWSPerformanceGestureScenario.h"

#import "MacWSHostDiagnostics.h"

@implementation MacWSPerformanceGestureScenario

- (void)runWithCompletion:(MacWSPerformanceGestureCompletion)completion {
    MacWSPerformanceGestureCompletion finish =
        completion ? completion : ^(BOOL success, NSString *message) {
            (void)success;
            (void)message;
        };
    NSString *scenario = self.name ?: @"";
    CGPoint center = self.targetPoint;
    uint32_t width = self.frameWidth;
    uint32_t height = self.frameHeight;
    MacWSLog(@"performance-gesture-start scenario=%@ target=%d "
             "frame=%ux%u point=(%.1f,%.1f)", scenario, self.targetPID,
             width, height, center.x, center.y);

    if ([scenario isEqualToString:@"tap"] ||
        [scenario isEqualToString:@"right-tap"] ||
        [scenario isEqualToString:@"double-tap"]) {
        if (!self.emitPointer) {
            finish(NO, @"点击测试适配器不可用");
            return;
        }
        MacWSInputKind kind = [scenario isEqualToString:@"right-tap"]
            ? MacWSInputKindSecondaryTap : MacWSInputKindTap;
        self.emitPointer(kind, center, 1.0f, self.pointerFlags);
        if ([scenario isEqualToString:@"double-tap"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                self.emitPointer(MacWSInputKindTap, center, 1.0f,
                                 self.pointerFlags |
                                 MacWSInputFlagDoubleClick);
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     450 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSLog(@"performance-gesture-end scenario=%@ success=YES",
                     scenario);
            finish(YES, @"场景已完成");
        });
        return;
    }

    if ([scenario isEqualToString:@"tap-burst"]) {
        if (!self.emitPointer) {
            finish(NO, @"点击测试适配器不可用");
            return;
        }
        const NSInteger count = 24;
        const uint64_t interval = 100 * NSEC_PER_MSEC;
        // A stationary click can leave an already-focused view visually
        // unchanged. Alternate inside the same resolved native window so the
        // target AppKit boundary still produces independently measurable
        // samples without crossing into an overlapping fullscreen layer.
        CGPoint alternate = self.alternateTargetPoint;
        if (!isfinite(alternate.x) || !isfinite(alternate.y))
            alternate = center;
        for (NSInteger index = 0; index < count; index++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         index * interval),
                           dispatch_get_main_queue(), ^{
                self.emitPointer(MacWSInputKindTap,
                                 (index & 1) ? alternate : center, 1.0f,
                                 self.pointerFlags |
                                 MacWSInputFlagLatencyDiagnostic);
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     count * interval +
                                     450 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSLog(@"performance-gesture-end scenario=tap-burst "
                     "success=YES");
            finish(YES, @"真实应用 24 次点击响应场景已完成");
        });
        return;
    }

    if ([scenario isEqualToString:@"drag"] ||
        [scenario isEqualToString:@"window-drag"] ||
        [scenario isEqualToString:@"long-drag"]) {
        if (!self.emitPointer) {
            finish(NO, @"拖动测试适配器不可用");
            return;
        }
        BOOL longPress = [scenario isEqualToString:@"long-drag"];
        BOOL windowDrag = [scenario isEqualToString:@"window-drag"];
        const NSInteger steps = windowDrag ? 48 : 120;
        const uint64_t stepNanoseconds = NSEC_PER_SEC / 120;
        const uint64_t holdNanoseconds = longPress
            ? 420 * NSEC_PER_MSEC : 0;
        CGPoint start = center;
        CGPoint end = CGPointMake(
            fmin(width - 1.0, center.x + width *
                (windowDrag ? 0.08 : 0.12)),
            fmin(height - 1.0, center.y + height *
                (windowDrag ? 0.06 : 0.08)));
        uint16_t flags = windowDrag ? self.pointerFlags : 0;
        self.emitPointer(MacWSInputKindTouchDown, start, 1.0f, flags);
        for (NSInteger index = 1; index <= steps; index++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         holdNanoseconds +
                                         index * stepNanoseconds),
                           dispatch_get_main_queue(), ^{
                CGFloat progress = index / (CGFloat)steps;
                CGPoint point = CGPointMake(
                    start.x + (end.x - start.x) * progress,
                    start.y + (end.y - start.y) * progress);
                self.emitPointer(
                    MacWSInputKindTouchMove, point, 1.0f, flags);
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     holdNanoseconds +
                                     (steps + 1) * stepNanoseconds),
                       dispatch_get_main_queue(), ^{
            self.emitPointer(MacWSInputKindTouchUp, end, 0.0f, flags);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     holdNanoseconds +
                                     (steps + 1) * stepNanoseconds +
                                     400 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSLog(@"performance-gesture-end scenario=%@ success=YES",
                     scenario);
            finish(YES, windowDrag ? @"120 Hz 窗口拖动场景已完成" :
                (longPress ? @"长按后 120 Hz 拖动场景已完成"
                           : @"120 Hz 拖动场景已完成"));
        });
        return;
    }

    if ([scenario isEqualToString:@"scroll"] ||
        [scenario isEqualToString:@"scroll-momentum"] ||
        [scenario isEqualToString:@"magnify"]) {
        BOOL magnify = [scenario isEqualToString:@"magnify"];
        BOOL momentum = [scenario isEqualToString:@"scroll-momentum"];
        if ((magnify && !self.emitMagnify) ||
            (!magnify && !self.emitScroll)) {
            finish(NO, @"连续手势测试适配器不可用");
            return;
        }
        const NSInteger steps = 120;
        const uint64_t stepNanoseconds = NSEC_PER_SEC / 120;
        if (magnify) {
            self.emitMagnify(
                center, 0.0, MacWSInputFlagGestureBegan |
                MacWSInputFlagLatencyDiagnostic, CACurrentMediaTime());
        } else {
            self.emitScroll(
                center, CGPointZero, MacWSInputFlagScrollBegan |
                MacWSInputFlagLatencyDiagnostic, CACurrentMediaTime());
        }
        for (NSInteger index = 1; index <= steps; index++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         index * stepNanoseconds),
                           dispatch_get_main_queue(), ^{
                if (magnify) {
                    self.emitMagnify(
                        center, 0.004, MacWSInputFlagGestureChanged |
                        MacWSInputFlagLatencyDiagnostic,
                        CACurrentMediaTime());
                } else {
                    self.emitScroll(
                        center, CGPointMake(0.0, 3.0),
                        MacWSInputFlagScrollChanged |
                        MacWSInputFlagLatencyDiagnostic,
                        CACurrentMediaTime());
                }
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (steps + 1) * stepNanoseconds),
                       dispatch_get_main_queue(), ^{
            if (magnify) {
                self.emitMagnify(
                    center, 0.0, MacWSInputFlagGestureEnded |
                    MacWSInputFlagLatencyDiagnostic,
                    CACurrentMediaTime());
            } else {
                self.emitScroll(
                    center, CGPointZero, MacWSInputFlagScrollEnded |
                    MacWSInputFlagLatencyDiagnostic |
                    (momentum ? MacWSInputFlagScrollWillMomentum : 0),
                    CACurrentMediaTime());
                if (momentum && self.startMomentum)
                    self.startMomentum(CGPointMake(0.0, 900.0), center);
            }
        });
        uint64_t settleNanoseconds = momentum
            ? 2800 * NSEC_PER_MSEC : 500 * NSEC_PER_MSEC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (steps + 1) * stepNanoseconds +
                                     settleNanoseconds),
                       dispatch_get_main_queue(), ^{
            if (momentum && self.stopMomentum)
                self.stopMomentum(YES);
            MacWSLog(@"performance-gesture-end scenario=%@ success=YES",
                     scenario);
            finish(YES, magnify ? @"120 Hz 缩放场景已完成" :
                momentum ? @"滚动与原生惯性衰减场景已完成" :
                           @"120 Hz 滚动场景已完成");
        });
        return;
    }

    if ([scenario isEqualToString:@"hover"]) {
        if (!self.emitPointer) {
            finish(NO, @"悬停测试适配器不可用");
            return;
        }
        // Keep this bounded, but exercise the repeated left/right camera
        // motion used to reproduce Stray's lazy-pipeline failures.  A single
        // one-way one-second sweep only exposed the first visible material;
        // eight traversals cover both directions through the same production
        // indirect-pointer route at 120 Hz.
        const NSInteger traversalCount = 8;
        const NSInteger stepsPerTraversal = 120;
        const NSInteger steps = traversalCount * stepsPerTraversal;
        const uint64_t stepNanoseconds = NSEC_PER_SEC / 120;
        CGPoint start = CGPointMake(
            fmax(0.0, center.x - width * 0.06), center.y);
        CGPoint end = CGPointMake(
            fmin(width - 1.0, center.x + width * 0.06), center.y);
        for (NSInteger index = 0; index <= steps; index++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         index * stepNanoseconds),
                           dispatch_get_main_queue(), ^{
                NSInteger traversal = index / stepsPerTraversal;
                NSInteger traversalStep = index % stepsPerTraversal;
                CGFloat progress =
                    traversalStep / (CGFloat)stepsPerTraversal;
                if (traversal & 1) progress = 1.0 - progress;
                self.emitPointer(MacWSInputKindHover, CGPointMake(
                    start.x + (end.x - start.x) * progress, start.y),
                    0.0f, 0);
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (steps + 1) * stepNanoseconds +
                                     400 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSLog(@"performance-gesture-end scenario=hover success=YES "
                     "traversals=%ld samples=%ld",
                     (long)traversalCount, (long)(steps + 1));
            finish(YES, @"120 Hz 八次往返悬停场景已完成");
        });
        return;
    }

    NSDictionary<NSString *, NSArray<NSNumber *> *> *systemScenarios = @{
        @"three-up": @[@(MacWSSystemGestureAxisVertical), @(-0.35)],
        @"three-down": @[@(MacWSSystemGestureAxisVertical), @(0.35)],
        @"three-left": @[@(MacWSSystemGestureAxisHorizontal), @(0.35)],
        @"three-right": @[@(MacWSSystemGestureAxisHorizontal), @(-0.35)],
    };
    NSArray<NSNumber *> *system = systemScenarios[scenario];
    if (system) {
        if (!self.fullscreen || self.dockPID <= 1) {
            finish(NO, @"三指性能场景需要全屏工作区和可用 Dock 图层");
            return;
        }
        if (!self.prepareSystemGesture || !self.emitSystemGesture ||
            !self.resetSystemGesture) {
            finish(NO, @"三指测试适配器不可用");
            return;
        }
        MacWSSystemGestureAxis axis =
            (MacWSSystemGestureAxis)system[0].unsignedIntValue;
        CGFloat finalProgress = system[1].doubleValue;
        const NSInteger steps = 90;
        const uint64_t stepNanoseconds = NSEC_PER_SEC / 120;
        CGFloat progressVelocity = finalProgress / (steps / 120.0);
        self.prepareSystemGesture(
            axis, self.contactID, self.dockPID, width, height,
            progressVelocity);
        self.emitSystemGesture(
            axis, finalProgress / steps, progressVelocity,
            MacWSInputFlagGestureBegan, CACurrentMediaTime());
        for (NSInteger index = 2; index <= steps; index++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         index * stepNanoseconds),
                           dispatch_get_main_queue(), ^{
                CGFloat progress = finalProgress * index / steps;
                self.emitSystemGesture(
                    axis, progress, progressVelocity,
                    MacWSInputFlagGestureChanged, CACurrentMediaTime());
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (steps + 1) * stepNanoseconds +
                                     80 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            self.emitSystemGesture(
                axis, finalProgress, 0.0,
                MacWSInputFlagGestureCancelled, CACurrentMediaTime());
            self.resetSystemGesture();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (steps + 1) * stepNanoseconds +
                                     650 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSLog(@"performance-gesture-end scenario=%@ success=YES",
                     scenario);
            finish(YES, @"120 Hz 原生 Dock 三指场景已完成并取消恢复");
        });
        return;
    }

    if ([scenario isEqualToString:@"mission-select"]) {
        if (!self.fullscreen || self.dockPID <= 1) {
            finish(NO, @"Mission Control 选择测试需要全屏工作区和可用 Dock 图层");
            return;
        }
        if (!self.prepareSystemGesture || !self.emitSystemGesture ||
            !self.resetSystemGesture || !self.emitPointer) {
            finish(NO, @"Mission Control 选择测试适配器不可用");
            return;
        }
        const NSInteger steps = 90;
        const uint64_t stepNanoseconds = NSEC_PER_SEC / 120;
        const CGFloat finalProgress = -0.85;
        const CGFloat progressVelocity = finalProgress / (steps / 120.0);
        self.prepareSystemGesture(
            MacWSSystemGestureAxisVertical, self.contactID, self.dockPID,
            width, height, progressVelocity);
        self.emitSystemGesture(
            MacWSSystemGestureAxisVertical, finalProgress / steps,
            progressVelocity, MacWSInputFlagGestureBegan,
            CACurrentMediaTime());
        for (NSInteger index = 2; index <= steps; index++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         index * stepNanoseconds),
                           dispatch_get_main_queue(), ^{
                CGFloat progress = finalProgress * index / steps;
                self.emitSystemGesture(
                    MacWSSystemGestureAxisVertical, progress,
                    progressVelocity, MacWSInputFlagGestureChanged,
                    CACurrentMediaTime());
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (steps + 1) * stepNanoseconds),
                       dispatch_get_main_queue(), ^{
            self.emitSystemGesture(
                MacWSSystemGestureAxisVertical, finalProgress,
                progressVelocity, MacWSInputFlagGestureEnded,
                CACurrentMediaTime());
            self.resetSystemGesture();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (steps + 1) * stepNanoseconds +
                                     400 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (self.missionControlDidCommit)
                self.missionControlDidCommit();
        });
        // Keep the native hover primer and the measured click as two distinct
        // presentation transactions. Otherwise the monitor correctly binds
        // the first resulting frame to Hover and the Tap selection has no
        // independent input-to-visible sample.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (steps + 1) * stepNanoseconds +
                                     800 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            self.emitPointer(
                MacWSInputKindTap, center, 1.0f,
                self.pointerFlags | MacWSInputFlagLatencyDiagnostic);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (steps + 1) * stepNanoseconds +
                                     2200 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacWSLog(@"performance-gesture-end "
                     "scenario=mission-select success=YES");
            finish(YES, @"Mission Control 缩略图选择场景已完成");
        });
        return;
    }

    finish(NO, @"未知性能手势场景");
}

@end
