// Read-only probe for the IOGPU selector used by AGX setupImmediate.
//
// This deliberately tests only the two output lengths present in the exact
// macOS 13.4 and iOS 16.3 call sites.  It does not create queues/resources or
// mutate GPU state.  Build natively on the target iOS device:
//   clang -arch arm64 -framework IOKit -framework CoreFoundation \
//       agx_device_info_probe.c -o agx_device_info_probe

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void probe(io_connect_t connection, size_t requested_size) {
    uint8_t output[0x78];
    memset(output, 0xa5, sizeof(output));
    size_t actual_size = requested_size;
    kern_return_t result = IOConnectCallStructMethod(connection, 0x100,
        NULL, 0, output, &actual_size);
    fprintf(stderr,
        "AGX-DEVICE-INFO requested=%#zx actual=%#zx result=%#x bytes=",
        requested_size, actual_size, result);
    size_t count = actual_size < 16 ? actual_size : 16;
    for (size_t index = 0; index < count; index++) {
        fprintf(stderr, "%02x", output[index]);
    }
    fputc('\n', stderr);
}

int main(void) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IOAcceleratorES"));
    if (service == IO_OBJECT_NULL) {
        fprintf(stderr, "AGX-DEVICE-INFO no IOAcceleratorES service\n");
        return 2;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 1,
        &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "AGX-DEVICE-INFO open result=%#x\n", result);
        return 3;
    }

    probe(connection, 0x70);
    probe(connection, 0x78);
    IOServiceClose(connection);
    return 0;
}
