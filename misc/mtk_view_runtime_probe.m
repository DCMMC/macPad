#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <stdio.h>
#include <string.h>

static BOOL Interesting(const char *name) {
    return name && (strcasestr(name, "display") ||
                    strcasestr(name, "frame") ||
                    strcasestr(name, "draw") ||
                    strcasestr(name, "pause"));
}

static void DumpMethodBytes(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    const uint8_t *implementation = (const uint8_t *)method_getImplementation(
        method);
    printf("imp class=%s selector=%s address=%p bytes=",
           class_getName(cls), sel_getName(selector), implementation);
    for (NSUInteger index = 0; index < 128; index++)
        printf("%02x", implementation[index]);
    printf("\n");
}

int main(void) {
    @autoreleasepool {
        Class roots[] = {
            MTKView.class,
            NSClassFromString(@"CADisplayLink"),
            NSClassFromString(@"UIScreen"),
            NSClassFromString(@"UIWindowScene"),
        };
        for (NSUInteger rootIndex = 0;
             rootIndex < sizeof(roots) / sizeof(roots[0]); rootIndex++) {
          for (Class cls = roots[rootIndex]; cls;
               cls = class_getSuperclass(cls)) {
            printf("class=%s\n", class_getName(cls));
            unsigned int ivarCount = 0;
            Ivar *ivars = class_copyIvarList(cls, &ivarCount);
            for (unsigned int index = 0; index < ivarCount; index++) {
                const char *name = ivar_getName(ivars[index]);
                if (Interesting(name)) {
                    printf("  ivar offset=%td name=%s type=%s\n",
                           ivar_getOffset(ivars[index]), name,
                           ivar_getTypeEncoding(ivars[index]));
                }
            }
            free(ivars);

            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (unsigned int index = 0; index < methodCount; index++) {
                const char *name = sel_getName(method_getName(methods[index]));
                if (Interesting(name))
                    printf("  method %s\n", name);
            }
            free(methods);
            if (cls == roots[rootIndex] ||
                rootIndex == 0 && cls == UIView.class) break;
          }
        }

        DumpMethodBytes(MTKView.class,
                        @selector(setPreferredFramesPerSecond:));
        DumpMethodBytes(MTKView.class,
                        NSSelectorFromString(@"setNominalFramesPerSecond:"));
        DumpMethodBytes(MTKView.class, @selector(displayLayer:));

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        MTKView *view = [[MTKView alloc] initWithFrame:
            CGRectMake(0, 0, 320, 240) device:device];
        view.delegate = nil;
        view.enableSetNeedsDisplay = NO;
        view.paused = NO;
        view.preferredFramesPerSecond = 120;
        SEL nominalSelector = NSSelectorFromString(@"nominalFramesPerSecond");
        NSInteger nominal = [view respondsToSelector:nominalSelector]
            ? ((NSInteger (*)(id, SEL))objc_msgSend)(view, nominalSelector) : -1;
        Ivar displayLinkIvar = class_getInstanceVariable(MTKView.class,
                                                         "_displayLink");
        CADisplayLink *link = displayLinkIvar
            ? object_getIvar(view, displayLinkIvar) : nil;
        NSInteger actual = 0;
        SEL actualSelector = NSSelectorFromString(@"actualFramesPerSecond");
        if ([link respondsToSelector:actualSelector]) {
            actual = ((NSInteger (*)(id, SEL))objc_msgSend)(
                link, actualSelector);
        }
        CAFrameRateRange range = link.preferredFrameRateRange;
        printf("instance preferred=%ld nominal=%ld link=%p actual=%ld "
               "range=%.1f/%.1f/%.1f duration-ms=%.3f\n",
               (long)view.preferredFramesPerSecond, (long)nominal, link,
               (long)actual, range.minimum, range.maximum, range.preferred,
               link.duration * 1000.0);
    }
    return 0;
}
