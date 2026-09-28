// Observe the resource-create requests produced by this device's native Metal
// stack.  The interposer never changes arguments or results; it records a
// bounded prefix around one device and one 64-KiB buffer creation.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

typedef struct __IOSurface *IOSurfaceRef;
extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern uint32_t IOSurfaceGetID(IOSurfaceRef surface);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef surface);
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef surface);

#define MACWS_INTERPOSE(replacement, replacee)                              \
    __attribute__((used)) static struct {                                   \
        const void *replacement;                                            \
        const void *replacee;                                               \
    } macws_interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&replacement,                              \
        (const void *)(uintptr_t)&replacee                                  \
    }

static kern_return_t MacWSObservedIOConnectCallMethod(
    mach_port_t connection, uint32_t selector,
    const uint64_t *scalarInput, uint32_t scalarInputCount,
    const void *structureInput, size_t structureInputSize,
    uint64_t *scalarOutput, uint32_t *scalarOutputCount,
    void *structureOutput, size_t *structureOutputSize) {
    static _Atomic unsigned observations = 0;
    unsigned sequence = selector == 0x9
        ? atomic_fetch_add(&observations, 1) + 1 : 0;
    if (sequence && sequence <= 16) {
        fprintf(stderr,
            "AGX-NATIVE-REQUEST #%u BEGIN conn=%u inCnt=%u inSC=%#zx outSC=%#zx",
            sequence, connection, scalarInputCount, structureInputSize,
            structureOutputSize ? *structureOutputSize : 0);
        const uint8_t *bytes = structureInput;
        size_t count = structureInputSize < 0x100
            ? structureInputSize : 0x100;
        for (size_t offset = 0; bytes && offset < count; offset += 8) {
            uint64_t value = 0;
            size_t remaining = count - offset;
            memcpy(&value, bytes + offset,
                   remaining < sizeof(value) ? remaining : sizeof(value));
            fprintf(stderr, " +%02zx=%#llx", offset,
                    (unsigned long long)value);
        }
        fputc('\n', stderr);
    }

    kern_return_t result = IOConnectCallMethod(connection, selector,
        scalarInput, scalarInputCount, structureInput, structureInputSize,
        scalarOutput, scalarOutputCount, structureOutput, structureOutputSize);

    if (sequence && sequence <= 16) {
        fprintf(stderr,
            "AGX-NATIVE-REQUEST #%u END result=%#x outSC=%#zx\n",
            sequence, result,
            structureOutputSize ? *structureOutputSize : 0);
    }
    return result;
}

MACWS_INTERPOSE(MacWSObservedIOConnectCallMethod, IOConnectCallMethod);

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        fprintf(stderr, "AGX-NATIVE device=%s registryID=%#llx\n",
                device.name.UTF8String,
                (unsigned long long)device.registryID);
        if (!device) return 2;
        id<MTLBuffer> buffer = [device newBufferWithLength:0x10000 options:0];
        fprintf(stderr, "AGX-NATIVE buffer=%p length=%#llx contents=%p\n",
                buffer, (unsigned long long)buffer.length, buffer.contents);
        NSDictionary *surfaceProperties = @{
            @"IOSurfaceWidth": @2732,
            @"IOSurfaceHeight": @2048,
            @"IOSurfaceBytesPerElement": @4,
            @"IOSurfacePixelFormat": @((uint32_t)'BGRA'),
            @"IOSurfaceIsGlobal": @NO,
            @"IOSurfaceCacheMode": @0,
        };
        IOSurfaceRef surface = IOSurfaceCreate(
            (__bridge CFDictionaryRef)surfaceProperties);
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:2732 height:2048 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageRenderTarget |
            MTLTextureUsageShaderRead;
        id<MTLTexture> texture = surface
            ? [device newTextureWithDescriptor:descriptor
                                     iosurface:surface plane:0] : nil;
        fprintf(stderr,
            "AGX-NATIVE surface=%p id=%u bpr=%#zx alloc=%#zx "
            "texture=%p format=%lu\n",
            surface, surface ? IOSurfaceGetID(surface) : 0,
            surface ? IOSurfaceGetBytesPerRow(surface) : 0,
            surface ? IOSurfaceGetAllocSize(surface) : 0,
            texture, (unsigned long)texture.pixelFormat);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLRenderPassDescriptor *renderPass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        renderPass.colorAttachments[0].texture = texture;
        renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPass.colorAttachments[0].clearColor =
            MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = texture
            ? [commandBuffer renderCommandEncoderWithDescriptor:renderPass]
            : nil;
        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        fprintf(stderr,
            "AGX-NATIVE clear queue=%p commandBuffer=%p encoder=%p "
            "status=%lu error=%s\n",
            queue, commandBuffer, encoder,
            (unsigned long)commandBuffer.status,
            commandBuffer.error
                ? commandBuffer.error.description.UTF8String : "nil");
        if (surface) CFRelease(surface);
        return buffer && texture && encoder &&
            commandBuffer.status == MTLCommandBufferStatusCompleted ? 0 : 3;
    }
}
