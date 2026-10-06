@import Darwin;
@import CydiaSubstrate;
@import Foundation;

#import "interpose.h"

#include <fcntl.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <IOKit/IOKitLib.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <mach/exception_types.h>

// One-launch evidence collector for Steam's bootstrap FIFO. This deliberately
// preserves every syscall result and errno; it is not a compatibility shim.
// Enable only on the Steam process being investigated with
// MACWS_STEAM_PIPE_DIAGNOSTICS=1.
static bool MacWSSteamPipeDiagnosticsEnabled(void) {
    return getenv("MACWS_STEAM_PIPE_DIAGNOSTICS") != NULL;
}

static bool MacWSIsSteamPipePath(const char *path) {
    return path && strstr(path, "steam.pipe") != NULL;
}

static void MacWSLogSteamPipeCall(const char *api, const char *path,
                                  long argument, int result,
                                  int savedError) {
    if (!MacWSSteamPipeDiagnosticsEnabled() ||
        !MacWSIsSteamPipePath(path)) return;
    fprintf(stderr,
            "[MacWSSteamPipeDiagnostics] api=%s pid=%d program=%s "
            "path=%s argument=%#lx result=%d errno=%d return=%p\n",
            api, getpid(), getprogname() ?: "(unknown)", path, argument,
            result, result < 0 ? savedError : 0,
            __builtin_return_address(0));
    fflush(stderr);
}

static int MacWSSteamPipeOpen(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    int result = (flags & O_CREAT) ? open(path, flags, mode) :
        open(path, flags);
    int savedError = errno;
    MacWSLogSteamPipeCall("open", path, flags, result, savedError);
    errno = savedError;
    return result;
}

static int MacWSSteamPipeMkfifo(const char *path, mode_t mode) {
    int result = mkfifo(path, mode);
    int savedError = errno;
    MacWSLogSteamPipeCall("mkfifo", path, mode, result, savedError);
    errno = savedError;
    return result;
}

static int MacWSSteamPipeUnlink(const char *path) {
    int result = unlink(path);
    int savedError = errno;
    MacWSLogSteamPipeCall("unlink", path, 0, result, savedError);
    errno = savedError;
    return result;
}

DYLD_INTERPOSE(MacWSSteamPipeOpen, open)
DYLD_INTERPOSE(MacWSSteamPipeMkfifo, mkfifo)
DYLD_INTERPOSE(MacWSSteamPipeUnlink, unlink)

// Diagnostic-only: ElleKit installs a task exception port the first time its
// JIT-less hook machinery is used. For Steam Helper and separately signed
// macws-runtime game shadows this converts the original startup exception into
// exit(1), so neither CrashReporter nor LLDB receives the faulting state.
// Refuse only CydiaSubstrate's exact installation call under an explicit
// one-shot flag; every other task_set_exception_ports call and all production
// runs preserve the native kernel result.
static bool MacWSIsSteamNativeExceptionDiagnosticTarget(void) {
    const char *program = getprogname();
    if (program && strcmp(program, "Steam Helper") == 0) {
        char ***argumentsPointer = _NSGetArgv();
        char **arguments = argumentsPointer ? *argumentsPointer : NULL;
        for (size_t index = 1; arguments && arguments[index]; index++) {
            if (!strncmp(arguments[index], "--type=", 7)) return false;
        }
        return true;
    }
    char executable[PATH_MAX] = {};
    uint32_t executableSize = sizeof(executable);
    return _NSGetExecutablePath(executable, &executableSize) == 0 &&
        strstr(executable, "/steamapps/macws-runtime/") != NULL;
}

static bool MacWSIsAnySteamHelper(void) {
    const char *program = getprogname();
    return program && strcmp(program, "Steam Helper") == 0;
}

static bool MacWSExecutablePathIsSteamRuntimeGame(void) {
    char executable[PATH_MAX] = {};
    uint32_t executableSize = sizeof(executable);
    return _NSGetExecutablePath(executable, &executableSize) == 0 &&
        strstr(executable, "/steamapps/macws-runtime/") != NULL;
}

static bool MacWSIsSteamExecutable(void) {
    const char *program = getprogname();
    if (program && (!strcmp(program, "steam_osx") ||
                    !strcmp(program, "Steam Helper"))) return true;
    // Steam game diagnostics are confined to the separately signed runtime
    // shadow.  Do not hook arbitrary applications that merely inherit a
    // Steam-related environment variable.
    return MacWSExecutablePathIsSteamRuntimeGame();
}

static bool MacWSIsSteamRuntimeGame(void) {
    return MacWSExecutablePathIsSteamRuntimeGame();
}

// Bounded root-cause trace for the installed Stray arm64 Shipping binary.
// RE-confirmed against UUID C72D3F73-25F4-333B-9108-83432E09E687:
// GuardedMain returns the first non-zero result from PreInitPreStartupScreen,
// PreInitPostStartupScreen or Init, which runGameThread then passes to _Exit.
// Preserve every original return value; this trace observes, never bypasses.
typedef int (*MacWSUE4PreInitPreFunction)(void *, const uint16_t *);
typedef int (*MacWSUE4StageFunction)(void *);
typedef void (*MacWSUE4RequestExitFunction)(const uint16_t *);
typedef int (*MacWSUE4MessageDialogFunction)(int, const void *, const void *);
typedef void *(*MacWSUE4LoadModuleFunction)(void *, uint64_t, int *);
typedef void *(*MacWSUE4LoadModuleSimpleFunction)(void *, uint64_t);
typedef uint32_t (*MacWSUE4FNameToStringFunction)(const uint64_t *,
                                                  uint16_t *);
typedef bool (*MacWSUE4ConfigGetStringFunction)(void *, const uint16_t *,
                                                const uint16_t *, void *,
                                                const void *);
typedef int (*MacWSUE4NoArgumentResultFunction)(void);
typedef bool (*MacWSUE4LoadingPhaseFunction)(void *, int);
typedef void *(*MacWSUE4LoadPhysicsLibraryFunction)(const void *);
typedef void (*MacWSUE4StaticFailDebugFunction)(const uint16_t *,
                                                const char *, int,
                                                const uint16_t *, bool, int);
typedef void (*MacWSUE4HandleErrorFunction)(void *);
typedef void (*MacWSUE4InitializeGPUDescriptorFunction)(
    void *, void *, io_registry_entry_t, CFDictionaryRef);
typedef void (*MacWSUE4MetalCommandBufferFailureFunction)(void *);
static MacWSUE4PreInitPreFunction gMacWSUE4OriginalPreInitPre;
static MacWSUE4StageFunction gMacWSUE4OriginalPreInitPost;
static MacWSUE4StageFunction gMacWSUE4OriginalInit;
static MacWSUE4RequestExitFunction gMacWSUE4OriginalRequestExit;
static MacWSUE4MessageDialogFunction gMacWSUE4OriginalMessageDialog;
static MacWSUE4LoadModuleFunction gMacWSUE4OriginalLoadModule;
static MacWSUE4LoadModuleSimpleFunction gMacWSUE4OriginalLoadModuleSimple;
static MacWSUE4FNameToStringFunction gMacWSUE4FNameToString;
static MacWSUE4ConfigGetStringFunction gMacWSUE4OriginalConfigGetString;
static MacWSUE4NoArgumentResultFunction gMacWSUE4OriginalAppInit;
static MacWSUE4NoArgumentResultFunction gMacWSUE4OriginalInitGamePhys;
static MacWSUE4LoadingPhaseFunction gMacWSUE4OriginalPluginLoadPhase;
static MacWSUE4LoadingPhaseFunction gMacWSUE4OriginalProjectLoadPhase;
static MacWSUE4LoadPhysicsLibraryFunction
    gMacWSUE4OriginalLoadPhysicsLibrary;
static MacWSUE4StaticFailDebugFunction gMacWSUE4OriginalStaticFailDebug;
static MacWSUE4HandleErrorFunction gMacWSUE4OriginalHandleError;
static MacWSUE4InitializeGPUDescriptorFunction
    gMacWSUE4OriginalInitializeGPUDescriptor;
static MacWSUE4MetalCommandBufferFailureFunction
    gMacWSUE4OriginalMetalCommandBufferFailure;
static uintptr_t gMacWSUE4DiagnosticMainBase;

typedef struct {
    const uint16_t *data;
    int32_t count;
    int32_t capacity;
} MacWSUE4FString;

static void MacWSLogUE4UTF16(const char *label, const uint16_t *text) {
    char output[768] = {};
    size_t index = 0;
    if (text) {
        for (; index + 1 < sizeof(output) && index < 767 && text[index];
             index++) {
            uint16_t character = text[index];
            output[index] = character >= 0x20 && character <= 0x7e
                ? (char)character : '?';
        }
    }
    fprintf(stderr, "[MacWSUE4Diagnostics] %s=%s\n", label,
            text ? output : "(null)");
    fflush(stderr);
}

static bool MacWSUE4UTF16EqualsASCII(const uint16_t *text,
                                     const char *ascii) {
    if (!text || !ascii) return false;
    size_t index = 0;
    for (; ascii[index]; index++) {
        if (text[index] != (uint8_t)ascii[index]) return false;
    }
    return text[index] == 0;
}

static bool MacWSUE4ConfigGetString(void *cache, const uint16_t *section,
                                    const uint16_t *key, void *value,
                                    const void *filename) {
    bool result = gMacWSUE4OriginalConfigGetString(cache, section, key,
                                                   value, filename);
    if (MacWSUE4UTF16EqualsASCII(section, "OnlineSubsystem")) {
        const MacWSUE4FString *stringValue = value;
        const MacWSUE4FString *stringFilename = filename;
        MacWSLogUE4UTF16("config-key", key);
        MacWSLogUE4UTF16("config-value",
                         result && stringValue ? stringValue->data : NULL);
        MacWSLogUE4UTF16("config-file",
                         stringFilename ? stringFilename->data : NULL);
        fprintf(stderr, "[MacWSUE4Diagnostics] config-result=%d\n", result);
        fflush(stderr);
    }
    return result;
}

static int MacWSUE4AppInit(void) {
    int result = gMacWSUE4OriginalAppInit();
    fprintf(stderr, "[MacWSUE4Diagnostics] AppInit=%d\n", result);
    fflush(stderr);
    return result;
}

static int MacWSUE4InitGamePhys(void) {
    int result = gMacWSUE4OriginalInitGamePhys();
    fprintf(stderr, "[MacWSUE4Diagnostics] InitGamePhys=%d\n", result);
    fflush(stderr);
    return result;
}

static bool MacWSUE4PluginLoadPhase(void *manager, int phase) {
    bool result = gMacWSUE4OriginalPluginLoadPhase(manager, phase);
    fprintf(stderr,
            "[MacWSUE4Diagnostics] PluginLoadPhase phase=%d result=%d\n",
            phase, result);
    fflush(stderr);
    return result;
}

static bool MacWSUE4ProjectLoadPhase(void *manager, int phase) {
    bool result = gMacWSUE4OriginalProjectLoadPhase(manager, phase);
    fprintf(stderr,
            "[MacWSUE4Diagnostics] ProjectLoadPhase phase=%d result=%d\n",
            phase, result);
    fflush(stderr);
    return result;
}

static void *MacWSUE4LoadPhysicsLibrary(const void *path) {
    const MacWSUE4FString *stringPath = path;
    void *result = gMacWSUE4OriginalLoadPhysicsLibrary(path);
    MacWSLogUE4UTF16("PhysX-library",
                     stringPath ? stringPath->data : NULL);
    fprintf(stderr, "[MacWSUE4Diagnostics] PhysX-handle=%p\n", result);
    fflush(stderr);
    return result;
}

static void MacWSUE4StaticFailDebug(const uint16_t *expression,
                                    const char *file, int line,
                                    const uint16_t *description,
                                    bool isEnsure, int errorCode) {
    // StaticFailDebug receives the already-expanded description from
    // LowLevelFatalErrorHandler.  Observing here avoids attempting to forward
    // an opaque variadic argument list while preserving UE4's fatal path.
    MacWSLogUE4UTF16("fatal-expression", expression);
    MacWSLogUE4UTF16("fatal-description", description);
    fprintf(stderr,
            "[MacWSUE4Diagnostics] fatal-file=%s line=%d ensure=%d "
            "error-code=%d\n",
            file ?: "(null)", line, isEnsure, errorCode);
    void *frames[48] = {};
    int frameCount = backtrace(frames,
        (int)(sizeof(frames) / sizeof(frames[0])));
    for (int index = 0; index < frameCount; index++) {
        Dl_info frameImage = {};
        if (dladdr(frames[index], &frameImage) && frameImage.dli_fbase) {
            fprintf(stderr,
                    "[MacWSUE4Diagnostics] Fatal stack #%02d %s+%#lx %s\n",
                    index, frameImage.dli_fname ?: "(unknown)",
                    (unsigned long)((uintptr_t)frames[index] -
                        (uintptr_t)frameImage.dli_fbase),
                    frameImage.dli_sname ?: "(unknown)");
        }
    }
    fflush(stderr);
    gMacWSUE4OriginalStaticFailDebug(expression, file, line, description,
                                     isEnsure, errorCode);
}

static void MacWSUE4HandleError(void *outputDevice) {
    MacWSLogUE4UTF16("HandleError-GErrorHist",
        (const uint16_t *)(gMacWSUE4DiagnosticMainBase + 0x54344c8));
    MacWSLogUE4UTF16("HandleError-GErrorExceptionDescription",
        (const uint16_t *)(gMacWSUE4DiagnosticMainBase + 0x543c4c8));
    void *frames[64] = {};
    int frameCount = backtrace(frames,
        (int)(sizeof(frames) / sizeof(frames[0])));
    for (int index = 0; index < frameCount; index++) {
        Dl_info frameImage = {};
        if (dladdr(frames[index], &frameImage) && frameImage.dli_fbase) {
            fprintf(stderr,
                    "[MacWSUE4Diagnostics] HandleError stack #%02d "
                    "%s+%#lx %s\n",
                    index, frameImage.dli_fname ?: "(unknown)",
                    (unsigned long)((uintptr_t)frames[index] -
                        (uintptr_t)frameImage.dli_fbase),
                    frameImage.dli_sname ?: "(unknown)");
        }
    }
    fflush(stderr);
    gMacWSUE4OriginalHandleError(outputDevice);
}

static void MacWSUE4InitializeGPUDescriptor(
        void *manager, void *descriptor, io_registry_entry_t deviceEntry,
        CFDictionaryRef deviceProperties) {
    fprintf(stderr,
            "[MacWSUE4Diagnostics] GPUDescriptor begin entry=%u "
            "descriptor=%p properties=%p\n",
            deviceEntry, descriptor, deviceProperties);
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t iteratorResult = IORegistryEntryGetChildIterator(
        deviceEntry, kIOServicePlane, &iterator);
    fprintf(stderr,
            "[MacWSUE4Diagnostics] GPUDescriptor child-iterator=%#x\n",
            iteratorResult);
    if (iteratorResult == KERN_SUCCESS) {
        io_registry_entry_t child;
        while ((child = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            io_name_t name = {};
            IORegistryEntryGetName(child, name);
            CFTypeRef category = IORegistryEntrySearchCFProperty(
                child, kIOServicePlane, CFSTR("IOMatchCategory"),
                kCFAllocatorDefault, 0);
            char categoryText[128] = {};
            bool categoryString = category &&
                CFGetTypeID(category) == CFStringGetTypeID() &&
                CFStringGetCString((CFStringRef)category, categoryText,
                                   sizeof(categoryText),
                                   kCFStringEncodingUTF8);
            fprintf(stderr,
                    "[MacWSUE4Diagnostics] GPUDescriptor child=%u name=%s "
                    "category=%s type=%lu\n",
                    child, name, categoryString ? categoryText : "(none)",
                    category ? (unsigned long)CFGetTypeID(category) : 0ul);
            if (category) CFRelease(category);
            IOObjectRelease(child);
        }
        IOObjectRelease(iterator);
    }
    fflush(stderr);
    gMacWSUE4OriginalInitializeGPUDescriptor(
        manager, descriptor, deviceEntry, deviceProperties);
    fprintf(stderr,
            "[MacWSUE4Diagnostics] GPUDescriptor end accelerator=%p "
            "vendor=%#x target=%#x memoryMB=%u\n",
            *(void **)((uint8_t *)descriptor + 0x40),
            *(uint32_t *)((uint8_t *)descriptor + 0x28),
            *(uint32_t *)((uint8_t *)descriptor + 0x2c),
            *(uint32_t *)((uint8_t *)descriptor + 0x30));
    fflush(stderr);
}

static void MacWSUE4MetalCommandBufferFailure(void *commandBufferReference) {
    // RE-confirmed via mtlpp::CommandBuffer::GetError/GetLabel for this UUID:
    // the wrapper's retained id<MTLCommandBuffer> is stored at +0x8.
    id commandBuffer = commandBufferReference
        ? *(id *)((uint8_t *)commandBufferReference + 0x8) : nil;
    NSString *label = nil;
    NSError *error = nil;
    NSUInteger status = 0;
    if ([commandBuffer respondsToSelector:@selector(label)])
        label = ((id (*)(id, SEL))objc_msgSend)(commandBuffer,
                                                @selector(label));
    if ([commandBuffer respondsToSelector:@selector(status)])
        status = ((NSUInteger (*)(id, SEL))objc_msgSend)(
            commandBuffer, @selector(status));
    if ([commandBuffer respondsToSelector:@selector(error)])
        error = [commandBuffer error];
    fprintf(stderr,
            "[MacWSUE4Diagnostics] MetalCommandBufferFailure object=%p "
            "class=%s label=%s status=%lu error-domain=%s code=%ld "
            "description=%s userInfo=%s\n",
            commandBuffer,
            commandBuffer ? object_getClassName(commandBuffer) : "(nil)",
            label.UTF8String ?: "(none)", (unsigned long)status,
            error.domain.UTF8String ?: "(none)", (long)error.code,
            error.localizedDescription.UTF8String ?: "(none)",
            error.userInfo.description.UTF8String ?: "(none)");
    fflush(stderr);
    gMacWSUE4OriginalMetalCommandBufferFailure(commandBufferReference);
}

static int MacWSUE4PreInitPre(void *engineLoop, const uint16_t *commandLine) {
    MacWSLogUE4UTF16("command-line", commandLine);
    int result = gMacWSUE4OriginalPreInitPre(engineLoop, commandLine);
    fprintf(stderr, "[MacWSUE4Diagnostics] PreInitPreStartupScreen=%d\n",
            result);
    fflush(stderr);
    return result;
}

static int MacWSUE4PreInitPost(void *engineLoop) {
    int result = gMacWSUE4OriginalPreInitPost(engineLoop);
    fprintf(stderr, "[MacWSUE4Diagnostics] PreInitPostStartupScreen=%d\n",
            result);
    fflush(stderr);
    return result;
}

static int MacWSUE4Init(void *engineLoop) {
    int result = gMacWSUE4OriginalInit(engineLoop);
    fprintf(stderr, "[MacWSUE4Diagnostics] EngineLoopInit=%d\n", result);
    fflush(stderr);
    return result;
}

static void MacWSUE4RequestExit(const uint16_t *reason) {
    MacWSLogUE4UTF16("RequestEngineExit", reason);
    gMacWSUE4OriginalRequestExit(reason);
}

static int MacWSUE4MessageDialog(int type, const void *message,
                                const void *title) {
    void *caller = __builtin_return_address(0);
    int result = gMacWSUE4OriginalMessageDialog(type, message, title);
    Dl_info image = {};
    dladdr(caller, &image);
    fprintf(stderr,
            "[MacWSUE4Diagnostics] MessageDialog type=%d result=%d "
            "caller-main-offset=%#lx\n",
            type, result,
            image.dli_fbase ? (unsigned long)((uintptr_t)caller -
                (uintptr_t)image.dli_fbase) : 0ul);
    fflush(stderr);
    return result;
}

static void *MacWSUE4LoadModule(void *manager, uint64_t name,
                               int *failureReason) {
    void *caller = __builtin_return_address(0);
    void *module = gMacWSUE4OriginalLoadModule(manager, name, failureReason);
    if (!module) {
        Dl_info image = {};
        uint16_t moduleName[1024] = {};
        if (gMacWSUE4FNameToString)
            gMacWSUE4FNameToString(&name, moduleName);
        dladdr(caller, &image);
        fprintf(stderr,
                "[MacWSUE4Diagnostics] LoadModule failed fname=%#llx "
                "reason=%d caller-main-offset=%#lx name=",
                (unsigned long long)name,
                failureReason ? *failureReason : -1,
                image.dli_fbase ? (unsigned long)((uintptr_t)caller -
                    (uintptr_t)image.dli_fbase) : 0ul);
        for (size_t index = 0; index + 1 < 1024 && moduleName[index];
             index++) {
            uint16_t character = moduleName[index];
            fputc(character >= 0x20 && character <= 0x7e
                      ? (char)character : '?', stderr);
        }
        fputc('\n', stderr);
        static bool dumpedLoadStack = false;
        if (!dumpedLoadStack) {
            dumpedLoadStack = true;
            void *frames[32] = {};
            int frameCount = backtrace(frames,
                (int)(sizeof(frames) / sizeof(frames[0])));
            for (int index = 0; index < frameCount; index++) {
                Dl_info frameImage = {};
                if (dladdr(frames[index], &frameImage) &&
                    frameImage.dli_fbase) {
                    fprintf(stderr,
                            "[MacWSUE4Diagnostics] LoadModule stack #%02d "
                            "%s+%#lx %s\n",
                            index, frameImage.dli_fname ?: "(unknown)",
                            (unsigned long)((uintptr_t)frames[index] -
                                (uintptr_t)frameImage.dli_fbase),
                            frameImage.dli_sname ?: "(unknown)");
                }
            }
        }
        fflush(stderr);
    }
    return module;
}

static void *MacWSUE4LoadModuleSimple(void *manager, uint64_t name) {
    void *caller = __builtin_return_address(0);
    void *module = gMacWSUE4OriginalLoadModuleSimple(manager, name);
    if (!module) {
        Dl_info image = {};
        uint16_t moduleName[1024] = {};
        if (gMacWSUE4FNameToString)
            gMacWSUE4FNameToString(&name, moduleName);
        dladdr(caller, &image);
        fprintf(stderr,
                "[MacWSUE4Diagnostics] LoadModule caller failed "
                "caller-main-offset=%#lx name=",
                image.dli_fbase ? (unsigned long)((uintptr_t)caller -
                    (uintptr_t)image.dli_fbase) : 0ul);
        for (size_t index = 0; index + 1 < 1024 && moduleName[index];
             index++) {
            uint16_t character = moduleName[index];
            fputc(character >= 0x20 && character <= 0x7e
                      ? (char)character : '?', stderr);
        }
        fputc('\n', stderr);
        fflush(stderr);
    }
    return module;
}

static bool MacWSMainImageHasStrayDiagnosticUUID(
        const struct mach_header_64 *header) {
    static const uint8_t expectedUUID[16] = {
        0xc7, 0x2d, 0x3f, 0x73, 0x25, 0xf4, 0x33, 0x3b,
        0x91, 0x08, 0x83, 0x43, 0x2e, 0x09, 0xe6, 0x87
    };
    if (!header || header->magic != MH_MAGIC_64) return false;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *end = cursor + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (cursor + sizeof(struct load_command) > end) return false;
        const struct load_command *command =
            (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            cursor + command->cmdsize > end) return false;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            return memcmp(uuid->uuid, expectedUUID, sizeof(expectedUUID)) == 0;
        }
        cursor += command->cmdsize;
    }
    return false;
}

static void *MacWSUE4DelayedFatalBufferSnapshot(void *context) {
    uintptr_t base = (uintptr_t)context;
    // The Mac platform exception path can set GErrorHist without entering
    // LowLevelFatalErrorHandler.  Take one bounded, read-only snapshot after
    // startup; this thread is installed only by the explicit Stray diagnostic.
    sleep(2);
    MacWSLogUE4UTF16("GErrorHist",
                    (const uint16_t *)(base + 0x54344c8));
    MacWSLogUE4UTF16("GErrorExceptionDescription",
                    (const uint16_t *)(base + 0x543c4c8));
    return NULL;
}

__attribute__((constructor))
static void MacWSInstallStrayUE4Diagnostics(void) {
    if (!getenv("MACWS_STEAM_UE4_DIAGNOSTICS") ||
        !MacWSIsSteamRuntimeGame()) return;
    const struct mach_header_64 *header = NULL;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *name = _dyld_get_image_name(index);
        if (name && strstr(name,
                "/steamapps/macws-runtime/Stray/Stray.app/Contents/MacOS/"
                "Stray-Mac-Shipping")) {
            header = (const struct mach_header_64 *)
                _dyld_get_image_header(index);
            break;
        }
    }
    if (!MacWSMainImageHasStrayDiagnosticUUID(header)) {
        fprintf(stderr,
                "[MacWSUE4Diagnostics] refused: unexpected main UUID\n");
        fflush(stderr);
        return;
    }
    uintptr_t base = (uintptr_t)header;
    gMacWSUE4DiagnosticMainBase = base;
    // RE-confirmed for this UUID via LLDB disassembly: this overload is
    // FName::ToString(char16_t *) const.  It returns the character count and
    // does not mutate the FName.  Keep it UUID-bound with the stage hooks.
    gMacWSUE4FNameToString =
        (MacWSUE4FNameToStringFunction)(base + 0x1436dd4);
    MSHookFunction((void *)(base + 0x13a4668),
                   (void *)MacWSUE4ConfigGetString,
                   (void **)&gMacWSUE4OriginalConfigGetString);
    MSHookFunction((void *)(base + 0x672dcc), (void *)MacWSUE4AppInit,
                   (void **)&gMacWSUE4OriginalAppInit);
    MSHookFunction((void *)(base + 0x33b877c), (void *)MacWSUE4InitGamePhys,
                   (void **)&gMacWSUE4OriginalInitGamePhys);
    MSHookFunction((void *)(base + 0x1458c20),
                   (void *)MacWSUE4PluginLoadPhase,
                   (void **)&gMacWSUE4OriginalPluginLoadPhase);
    MSHookFunction((void *)(base + 0x1461ccc),
                   (void *)MacWSUE4ProjectLoadPhase,
                   (void **)&gMacWSUE4OriginalProjectLoadPhase);
    MSHookFunction((void *)(base + 0x20024cc),
                   (void *)MacWSUE4LoadPhysicsLibrary,
                   (void **)&gMacWSUE4OriginalLoadPhysicsLibrary);
    // RE-confirmed via /tmp/Stray-Mac-Shipping+0x13925ac: the variadic
    // LowLevelFatalErrorHandler formats into a stack UTF-16 buffer, then calls
    // StaticFailDebug at main+0x1392200 with that buffer in x3.
    MSHookFunction((void *)(base + 0x1392200),
                   (void *)MacWSUE4StaticFailDebug,
                   (void **)&gMacWSUE4OriginalStaticFailDebug);
    // RE-confirmed via Stray main+0x1356f60: FMacErrorOutputDevice::HandleError
    // is the owner of the observed "Spinning after fatal error" loop at
    // +0x1356ff0, after GErrorHist has already been populated.
    MSHookFunction((void *)(base + 0x1356f60),
                   (void *)MacWSUE4HandleError,
                   (void **)&gMacWSUE4OriginalHandleError);
    // RE-confirmed via Stray main+0x1366c9c: this is the GPU registry
    // descriptor initializer reached after the outer AppleARMIODevice/sgx
    // match.  The hook is read-only and records the actual child category
    // that determines whether UE4 appends the descriptor.
    MSHookFunction((void *)(base + 0x1366c9c),
                   (void *)MacWSUE4InitializeGPUDescriptor,
                   (void **)&gMacWSUE4OriginalInitializeGPUDescriptor);
    // RE-confirmed via Stray main+0x11e89c0: the Code=1 dispatch target for a
    // failed Metal command buffer.  Observe the actual Objective-C command
    // buffer and NSError before UE4 formats and raises its fatal error.
    MSHookFunction((void *)(base + 0x11e89c0),
                   (void *)MacWSUE4MetalCommandBufferFailure,
                   (void **)&gMacWSUE4OriginalMetalCommandBufferFailure);
    MSHookFunction((void *)(base + 0x66f7b8), (void *)MacWSUE4PreInitPre,
                   (void **)&gMacWSUE4OriginalPreInitPre);
    MSHookFunction((void *)(base + 0x6739b4), (void *)MacWSUE4PreInitPost,
                   (void **)&gMacWSUE4OriginalPreInitPost);
    MSHookFunction((void *)(base + 0x66a1f8), (void *)MacWSUE4Init,
                   (void **)&gMacWSUE4OriginalInit);
    MSHookFunction((void *)(base + 0x13bea88), (void *)MacWSUE4RequestExit,
                   (void **)&gMacWSUE4OriginalRequestExit);
    MSHookFunction((void *)(base + 0x13d040c),
                   (void *)MacWSUE4MessageDialog,
                   (void **)&gMacWSUE4OriginalMessageDialog);
    MSHookFunction((void *)(base + 0x1401b10), (void *)MacWSUE4LoadModule,
                   (void **)&gMacWSUE4OriginalLoadModule);
    MSHookFunction((void *)(base + 0x1401998),
                   (void *)MacWSUE4LoadModuleSimple,
                   (void **)&gMacWSUE4OriginalLoadModuleSimple);
    fprintf(stderr,
            "[MacWSUE4Diagnostics] installed UUID="
            "C72D3F73-25F4-333B-9108-83432E09E687\n");
    fflush(stderr);
    pthread_t snapshotThread;
    if (pthread_create(&snapshotThread, NULL,
                       MacWSUE4DelayedFatalBufferSnapshot,
                       (void *)base) == 0)
        pthread_detach(snapshotThread);
}

static kern_return_t MacWSSteamDiagnosticTaskSetExceptionPorts(
    task_t task, exception_mask_t mask, mach_port_t newPort,
    exception_behavior_t behavior, thread_state_flavor_t flavor) {
    if (getenv("MACWS_STEAM_NATIVE_EXCEPTION_DIAGNOSTICS") &&
        MacWSIsSteamNativeExceptionDiagnosticTarget()) {
        Dl_info caller = {0};
        void *returnAddress = __builtin_return_address(0);
        if (dladdr(returnAddress, &caller) && caller.dli_fname &&
            strstr(caller.dli_fname, "/CydiaSubstrate.framework/")) {
            fprintf(stderr,
                    "[MacWSSteamNativeException] refused ElleKit exception "
                    "port caller=%p mask=%#x behavior=%#x flavor=%d\n",
                    returnAddress, mask, behavior, flavor);
            fflush(stderr);
            return KERN_FAILURE;
        }
    }
    return task_set_exception_ports(task, mask, newPort, behavior, flavor);
}

DYLD_INTERPOSE(MacWSSteamDiagnosticTaskSetExceptionPorts,
               task_set_exception_ports)

static void MacWSSteamExitDiagnostics(void) {
    if (!getenv("MACWS_STEAM_EXIT_DIAGNOSTICS")) return;
    void *frames[96];
    int count = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
    fprintf(stderr,
            "[MacWSSteamExitDiagnostics] atexit pid=%d program=%s frames=%d\n",
            getpid(), getprogname() ?: "(unknown)", count);
    for (int index = 0; index < count; index++) {
        Dl_info image = {0};
        if (dladdr(frames[index], &image) && image.dli_fbase) {
            fprintf(stderr, "[MacWSSteamExitDiagnostics] #%02d %p %s+%#lx %s\n",
                    index, frames[index], image.dli_fname ?: "(unknown)",
                    (unsigned long)((uintptr_t)frames[index] -
                                    (uintptr_t)image.dli_fbase),
                    image.dli_sname ?: "(unknown)");
        } else {
            fprintf(stderr, "[MacWSSteamExitDiagnostics] #%02d %p\n",
                    index, frames[index]);
        }
    }
    fflush(stderr);
}

typedef void (*MacWSNoreturnStatusFunction)(int);
static MacWSNoreturnStatusFunction gMacWSOriginalExit;
static MacWSNoreturnStatusFunction gMacWSOriginalUnderscoreExit;
static MacWSNoreturnStatusFunction gMacWSOriginalCapitalExit;
typedef void (*MacWSNoreturnVoidFunction)(void);
static MacWSNoreturnVoidFunction gMacWSOriginalAbort;

static void MacWSLogSteamTermination(const char *api, int status) {
    // The ElleKit exception-port worker converts an unhandled Mach exception
    // into exit(1), obscuring the original faulting thread from CrashReporter
    // and LLDB's signal handlers. An explicitly requested one-shot diagnostic
    // stops the task before the worker destroys that evidence; attaching LLDB
    // can then inspect every thread without changing the production outcome.
    if (getenv("MACWS_STEAM_EXIT_STOP")) raise(SIGSTOP);
    void *frames[96];
    int count = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
    fprintf(stderr,
            "[MacWSSteamExitDiagnostics] api=%s pid=%d program=%s "
            "status=%d frames=%d\n",
            api, getpid(), getprogname() ?: "(unknown)", status, count);
    for (int index = 0; index < count; index++) {
        Dl_info image = {0};
        if (dladdr(frames[index], &image) && image.dli_fbase) {
            fprintf(stderr, "[MacWSSteamExitDiagnostics] #%02d %p %s+%#lx %s\n",
                    index, frames[index], image.dli_fname ?: "(unknown)",
                    (unsigned long)((uintptr_t)frames[index] -
                                    (uintptr_t)image.dli_fbase),
                    image.dli_sname ?: "(unknown)");
        }
    }
    fflush(stderr);
}

__attribute__((noreturn))
static void MacWSSteamExit(int status) {
    MacWSLogSteamTermination("exit", status);
    gMacWSOriginalExit(status);
    __builtin_unreachable();
}

__attribute__((noreturn))
static void MacWSSteamUnderscoreExit(int status) {
    MacWSLogSteamTermination("_exit", status);
    gMacWSOriginalUnderscoreExit(status);
    __builtin_unreachable();
}

__attribute__((noreturn))
static void MacWSSteamCapitalExit(int status) {
    MacWSLogSteamTermination("_Exit", status);
    gMacWSOriginalCapitalExit(status);
    __builtin_unreachable();
}

__attribute__((noreturn))
__attribute__((noinline))
static void MacWSSteamAbort(void) {
    // RE-confirmed against the installed Ventura 13.4 HIServices image
    // (UUID AB1464A5-20E6-3C95-8548-1C03866FB283): the abort return address
    // at image+0x7e50 follows _RegisterApplication's formatted ASN-failure
    // message. Its 0x1420-byte frame keeps that 0x1000-byte message at
    // caller-fp-0x1070. Record the actual LaunchServices error during this
    // opt-in diagnostic, but only after verifying both the exact image/offset
    // and that the bounded string lives in the current pthread stack.
    void *returnAddress = __builtin_return_address(0);
    Dl_info caller = {0};
    if (dladdr(returnAddress, &caller) && caller.dli_fname &&
        strstr(caller.dli_fname, "/HIServices.framework/") &&
        caller.dli_fbase &&
        (uintptr_t)returnAddress - (uintptr_t)caller.dli_fbase == 0x7e50) {
        pthread_t thread = pthread_self();
        uintptr_t stackHigh = (uintptr_t)pthread_get_stackaddr_np(thread);
        size_t stackSize = pthread_get_stacksize_np(thread);
        uintptr_t stackLow = stackHigh - stackSize;
        uintptr_t currentFrame = (uintptr_t)__builtin_frame_address(0);
        uintptr_t callerFrame = 0;
        if (currentFrame >= stackLow &&
            currentFrame <= stackHigh - sizeof(callerFrame)) {
            // arm64's frame record begins with the previous x29 value. Read
            // it only after bounding the current record inside this thread's
            // stack; __builtin_frame_address(1) is both unsafe and rejected by
            // the strict production compiler.
            memcpy(&callerFrame, (const void *)currentFrame,
                   sizeof(callerFrame));
        }
        uintptr_t messageAddress = callerFrame >= 0x1070
            ? callerFrame - 0x1070 : 0;
        if (callerFrame && messageAddress >= stackLow &&
            messageAddress + 1024 <= stackHigh) {
            fprintf(stderr,
                    "[MacWSSteamExitDiagnostics] HIServices-ASN-message="
                    "%.1024s\n",
                    (const char *)messageAddress);
            fflush(stderr);
        }
    }
    MacWSLogSteamTermination("abort", SIGABRT);
    gMacWSOriginalAbort();
    __builtin_unreachable();
}

__attribute__((constructor))
static void MacWSInstallSteamExitDiagnostics(void) {
    if (!getenv("MACWS_STEAM_EXIT_DIAGNOSTICS") ||
        !MacWSIsSteamExecutable()) return;
    bool isHelper = MacWSIsAnySteamHelper();
    bool isRuntimeGame = MacWSIsSteamRuntimeGame();
    if (isHelper) atexit(MacWSSteamExitDiagnostics);
    void *abortTarget = dlsym(RTLD_DEFAULT, "abort");
    if (abortTarget)
        MSHookFunction(abortTarget, (void *)MacWSSteamAbort,
                       (void **)&gMacWSOriginalAbort);
    if (!isHelper && !isRuntimeGame) return;
    void *exitTarget = dlsym(RTLD_DEFAULT, "exit");
    void *underscoreExitTarget = dlsym(RTLD_DEFAULT, "_exit");
    void *capitalExitTarget = dlsym(RTLD_DEFAULT, "_Exit");
    if (exitTarget)
        MSHookFunction(exitTarget, (void *)MacWSSteamExit,
                       (void **)&gMacWSOriginalExit);
    if (underscoreExitTarget)
        MSHookFunction(underscoreExitTarget, (void *)MacWSSteamUnderscoreExit,
                       (void **)&gMacWSOriginalUnderscoreExit);
    if (capitalExitTarget && capitalExitTarget != underscoreExitTarget)
        MSHookFunction(capitalExitTarget, (void *)MacWSSteamCapitalExit,
                       (void **)&gMacWSOriginalCapitalExit);
}
