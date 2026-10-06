// Diagnostic-only IOGPU ResCreate input/output tracer for an iOS-native
// Metal client. Build it as a MobileSubstrate dylib and inject it only into a
// bounded probe process; it changes no request or result bytes.
//
//   clang -arch arm64 -dynamiclib \
//     -I/var/jb/var/mobile/theos/vendor/include -framework IOKit \
//     -L/var/jb/usr/lib -lsubstrate \
//     ios_agx_resource_shape_trace.m -o ios_agx_resource_shape_trace.dylib
//
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <unistd.h>
#include <substrate.h>

static IOReturn (*MacWSOriginalIOConnectCallMethod)(
    mach_port_t, uint32_t, const uint64_t *, uint32_t,
    const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);

static IOReturn MacWSProbeIOConnectCallMethod(
    mach_port_t connection, uint32_t selector,
    const uint64_t *input, uint32_t inputCount,
    const void *inputStruct, size_t inputStructCount,
    uint64_t *output, uint32_t *outputCount,
    void *outputStruct, size_t *outputStructCount) {
    if (selector == 0x9 && inputStruct && inputStructCount <= 0x100) {
        const unsigned char *bytes = inputStruct;
        dprintf(STDERR_FILENO,
                "IOS-AGX-RESOURCE begin conn=%u selector=%#x "
                "inputCount=%u inputStructCount=%#zx "
                "outputStructRequested=%#zx\n",
                connection, selector, inputCount, inputStructCount,
                outputStructCount ? *outputStructCount : 0);
        for (size_t offset = 0; offset < inputStructCount; offset += 16) {
            char line[160];
            int used = snprintf(line, sizeof(line),
                                "IOS-AGX-RESOURCE +%02zx:", offset);
            for (size_t index = 0;
                 index < 16 && offset + index < inputStructCount; index++) {
                used += snprintf(line + used, sizeof(line) - (size_t)used,
                                 " %02x", bytes[offset + index]);
            }
            dprintf(STDERR_FILENO, "%s\n", line);
        }
    }
    IOReturn result = MacWSOriginalIOConnectCallMethod(
        connection, selector, input, inputCount,
        inputStruct, inputStructCount, output, outputCount,
        outputStruct, outputStructCount);
    if (selector == 0x9 && inputStruct && inputStructCount <= 0x100) {
        dprintf(STDERR_FILENO,
                "IOS-AGX-RESOURCE end result=%#x outputStructReturned=%#zx\n",
                result, outputStructCount ? *outputStructCount : 0);
    }
    return result;
}

__attribute__((constructor))
static void MacWSInstallIOGPUResourceShapeTrace(void) {
    MSHookFunction((void *)IOConnectCallMethod,
                   (void *)MacWSProbeIOConnectCallMethod,
                   (void **)&MacWSOriginalIOConnectCallMethod);
    dprintf(STDERR_FILENO,
            "IOS-AGX-RESOURCE hook-installed target=%p original=%p\n",
            IOConnectCallMethod, MacWSOriginalIOConnectCallMethod);
}
