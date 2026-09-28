// Diagnostic-only observer for a disposable native-iOS Metal probe process.
// Unlike the production bridge this may use an inline hook: it never ships in
// a launchd job, never changes an argument/result, and a hook failure is
// confined to the one-shot probe.

#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern void MSHookFunction(void *symbol, void *replacement, void **original);

typedef kern_return_t (*call_method_fn)(mach_port_t, uint32_t,
    const uint64_t *, uint32_t, const void *, size_t,
    uint64_t *, uint32_t *, void *, size_t *);

static call_method_fn original_call_method;
static _Atomic unsigned samples;
static _Atomic unsigned submit_samples;

static uintptr_t strip_user_pointer(uint64_t value) {
    return (uintptr_t)(value & 0x0000ffffffffffffULL);
}

static void save_bytes(const char *path, const void *bytes, size_t length) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    const uint8_t *cursor = bytes;
    while (length) {
        ssize_t written = write(fd, cursor, length);
        if (written <= 0) break;
        cursor += written;
        length -= (size_t)written;
    }
    close(fd);
}

static void observe_submit(const void *structureInput,
                           size_t structureInputSize) {
    unsigned sample = atomic_fetch_add(&submit_samples, 1) + 1;
    if (sample > 2 || !structureInput || structureInputSize < 0x38) return;

    const uint8_t *entry = structureInput;
    uint64_t descriptorRaw = 0;
    memcpy(&descriptorRaw, entry + 0x10, sizeof(descriptorRaw));
    uintptr_t descriptor = strip_user_pointer(descriptorRaw);
    uint64_t selfRaw = 0;
    memcpy(&selfRaw, (const void *)(descriptor + 0x20), sizeof(selfRaw));
    uintptr_t self = strip_user_pointer(selfRaw);
    uint64_t stateRaw = 0;
    memcpy(&stateRaw, (const void *)(self + 0x250), sizeof(stateRaw));
    uintptr_t state = strip_user_pointer(stateRaw);

    uint64_t commandStartRaw = 0, commandCurrentRaw = 0;
    uint64_t listStartRaw = 0, listCurrentRaw = 0;
    memcpy(&commandStartRaw, (const void *)(state + 0x28), 8);
    memcpy(&commandCurrentRaw, (const void *)(state + 0x30), 8);
    memcpy(&listStartRaw, (const void *)(state + 0x68), 8);
    memcpy(&listCurrentRaw, (const void *)(state + 0x328), 8);
    uintptr_t commandStart = strip_user_pointer(commandStartRaw);
    uintptr_t commandCurrent = strip_user_pointer(commandCurrentRaw);
    uintptr_t listStart = strip_user_pointer(listStartRaw);
    uintptr_t listCurrent = strip_user_pointer(listCurrentRaw);
    size_t commandLength = commandCurrent >= commandStart
        ? commandCurrent - commandStart : 0;
    size_t listLength = listCurrent >= listStart
        ? listCurrent - listStart : 0;

    char line[1024];
    int used = snprintf(line, sizeof(line),
        "AGX-NATIVE-SUBMIT sample=%u inSC=%zu descriptor=%#llx "
        "self=%#llx state=%#llx kcmd=%#llx..%#llx len=%#zx "
        "list=%#llx..%#llx len=%#zx\n",
        sample, structureInputSize,
        (unsigned long long)descriptorRaw,
        (unsigned long long)selfRaw, (unsigned long long)stateRaw,
        (unsigned long long)commandStartRaw,
        (unsigned long long)commandCurrentRaw, commandLength,
        (unsigned long long)listStartRaw,
        (unsigned long long)listCurrentRaw, listLength);
    (void)write(STDERR_FILENO, line, (size_t)used);
    if (commandLength && commandLength <= 0x100000) {
        save_bytes("/var/mobile/agx_native_submit_kcmd.bin",
                   (const void *)commandStart, commandLength);
    }
    if (listLength && listLength <= 0x100000) {
        save_bytes("/var/mobile/agx_native_submit_list.bin",
                   (const void *)listStart, listLength);
    }
    save_bytes("/var/mobile/agx_native_submit_args.bin",
               structureInput, structureInputSize);
    save_bytes("/var/mobile/agx_native_submit_command_buffer.bin",
               (const void *)self, 0x300);
    save_bytes("/var/mobile/agx_native_submit_state.bin",
               (const void *)state, 0x400);
}

static kern_return_t observed_call_method(mach_port_t connection,
    uint32_t selector, const uint64_t *scalarInput, uint32_t scalarInputCount,
    const void *structureInput, size_t structureInputSize,
    uint64_t *scalarOutput, uint32_t *scalarOutputCount,
    void *structureOutput, size_t *structureOutputSize) {
    unsigned sample = (selector == 9 || selector == 10)
        ? atomic_fetch_add(&samples, 1) + 1 : 0;
    uint8_t snapshot[0x100] = {0};
    size_t snapshotSize = structureInputSize < sizeof(snapshot)
        ? structureInputSize : sizeof(snapshot);
    if (sample && sample <= 16 && structureInput) {
        memcpy(snapshot, structureInput, snapshotSize);
    }
    if (selector == 0x1a) {
        observe_submit(structureInput, structureInputSize);
    }

    kern_return_t result = original_call_method(connection, selector,
        scalarInput, scalarInputCount, structureInput, structureInputSize,
        scalarOutput, scalarOutputCount, structureOutput, structureOutputSize);

    if (sample && sample <= 16) {
        char line[1600];
        int used = snprintf(line, sizeof(line),
            "AGX-NATIVE-IOKIT sample=%u selector=%u inCnt=%u inSC=%zu "
            "outSC=%zu result=%#x words=", sample, selector,
            scalarInputCount, structureInputSize,
            structureOutputSize ? *structureOutputSize : 0, result);
        for (size_t offset = 0; offset < snapshotSize; offset += 8) {
            uint64_t value = 0;
            size_t width = snapshotSize - offset;
            if (width > sizeof(value)) width = sizeof(value);
            memcpy(&value, snapshot + offset, width);
            used += snprintf(line + used, sizeof(line) - (size_t)used,
                "+%02zx:%016llx ", offset, (unsigned long long)value);
        }
        line[used++] = '\n';
        (void)write(STDERR_FILENO, line, (size_t)used);
    }
    return result;
}

__attribute__((constructor))
static void install_observer(void) {
    void *symbol = dlsym(RTLD_DEFAULT, "IOConnectCallMethod");
    if (!symbol) {
        static const char missing[] = "AGX-NATIVE-IOKIT missing symbol\n";
        (void)write(STDERR_FILENO, missing, sizeof(missing) - 1);
        return;
    }
    MSHookFunction(symbol, (void *)&observed_call_method,
                   (void **)&original_call_method);
    char line[160];
    int used = snprintf(line, sizeof(line),
        "AGX-NATIVE-IOKIT installed symbol=%p original=%p\n",
        symbol, (void *)original_call_method);
    (void)write(STDERR_FILENO, line, (size_t)used);
}
