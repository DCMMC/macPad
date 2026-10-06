// Minimal iOS-native producer for the resource-shape tracer above.
//
//   clang -arch arm64 -fobjc-arc -fmodules \
//     -fmodules-cache-path=/tmp/macws-probe-modules \
//     -framework Foundation -framework Metal \
//     ios_metal_heap_shape_probe.m -o ios_metal_heap_shape_probe
//
@import Foundation;
@import Metal;

#include <stdio.h>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        fprintf(stderr, "IOS-METAL-HEAP device=%p name=%s\n",
                (__bridge void *)device,
                device.name.UTF8String ?: "(nil)");
        if (!device) return 2;

        id<MTLBuffer> shared = [device
            newBufferWithLength:0x10000
                         options:MTLResourceStorageModeShared];
        fprintf(stderr,
                "IOS-METAL-HEAP shared=%p length=%#lx contents=%p\n",
                (__bridge void *)shared, (unsigned long)shared.length,
                shared.contents);
        return shared ? 0 : 3;
    }
}
