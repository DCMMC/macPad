@import CydiaSubstrate;
@import Foundation;
@import Darwin;
#include <stdarg.h>
#include <time.h>
#include <syslog.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../include/macws_metal_dag_request.h"
#include "../include/macws_metal_image_filter_request.h"
#include "../include/macws_code_pointer.h"

// The rootless iOS 16 Theos SDK used by this project omits xpc/xpc.h.  This
// is the exact public C ABI needed by the UUID-locked reply observer.
extern void *xpc_data_create(const void *bytes, size_t length);

// Diagnostics are explicitly opt-in for the current boot.  They must never
// survive as configuration under a persistent mobile or rootless directory.
static bool MacWSCompilerDiagnosticsEnabled(void) {
    return access("/tmp/macws_mtlcompiler_diagnostics", F_OK) == 0;
}

static bool MacWSCompilerHoldEnabled(void) {
    return access("/tmp/macws_mtlcompiler_hold", F_OK) == 0;
}

// NOTE: do NOT take an ObjC block here. Under -fobjc-arc the on-device lld
// arm64e build mis-signs the block's metadata pointer, so ARC's objc_storeStrong
// on the block parameter PAC-faults in this dylib's %ctor (crashes MTLCompilerService
// on inject -> deadlocks the whole Metal/WindowServer path). Patch the word directly.
static void PatchInstruction(uint32_t *addr, uint32_t value) {
    vm_protect(mach_task_self(), (vm_address_t)addr, sizeof(uint32_t), false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    *addr = value;
    vm_protect(mach_task_self(), (vm_address_t)addr, sizeof(uint32_t), false, PROT_READ | PROT_EXEC);
}

// ─── AGXCompilerCore verifyLoweredIR bypass ─────────────────────────────
//
// The macOS-13.4 AIR that chroot WindowServer hands to MTLCompilerService
// uses `air.fract.v3f16` (fract on half3). Inside AGXCompilerCore an
// optimisation pass renames it to the AGX-internal name
// `agx.air.fract.v3f16.fast` (the same rename that exists for
// `air.fast_fract.v2f32` etc.). But the dispatch table built by
// `AGCLLVMAirBuiltinsMap::insertBuiltinReplacementsBase` only has keys
// `"fract"` and `"fast_fract"` — there's no entry for the typed-suffix
// `fract.v3f16.fast` form. `AGCLLVMUserObject::verifyLoweredIR()` then
// iterates the module's function list, finds the unlowered declaration
// whose name still contains "air.", logs
//   "Encountered unlowered function call to agx.air.fract.v3f16.fast"
// via _os_log_fault_impl, and the surrounding compile pipeline captures
// that log into the abort_with_payload(13, 4, …) reason string that CA
// turns into "Metal failed to build render pipeline" → WindowServer dies.
//
// Crucially: `AGCLLVMAirBuiltins::buildFastFract` IS implemented (and
// the v3f16 path inside it is the trivial `x - floor(x)` lowering — the
// f32-specific post-clamp is skipped by `cmp w10, #0x2 ; b.ne epilogue`
// at the start of its body). So if we silence the verifier's complaint
// about the rename, downstream codegen will either emit a working
// lowering itself or carry the call as a declaration the GPU runtime
// resolves via builtin tables — either way, the host-side abort goes
// away and we get to observe the actual GPU behaviour.
//
// The verifier function's symbol is stripped from the iOS-side
// AGXCompilerCore so MSFindSymbol can't locate it directly. Instead we
// anchor on the exported `_AIRNTGetVersion` (one of 33 surviving public
// `AIRNT*` symbols) and use the static delta measured against the
// iPad13,6 16.3.1 (20D67) Symbols build:
//
//   verifier = AIRNTGetVersion - 0x5fb78
//
// (verifier @ 0x1be30999c, AIRNTGetVersion @ 0x1be369514 in that build).
//
// Patch is one instruction: `pacibsp` at function entry → `ret`. The
// caller's BL set LR to the next instruction in the caller; no stack
// frame has been built yet, so simply returning to LR is correct and
// avoids the verifier's iteration over the module's function list.
//
// If the byte at the computed address is not `pacibsp` (0xd503237f),
// the iOS AGXCompilerCore has changed and the anchor needs re-checking;
// we abort instead of silently corrupting an unknown instruction.
// ─── AGX renamer fix: skip the "agx." prepend ─────────────────────────────
//
// `AGCLLVMUserObject::linkMetalRuntime(bool)` walks the module's
// runtime-shim function list and for each function builds a renamed
// declaration `"agx." + originalName + ".fast"`, replaces uses, and
// hands the new declaration to the next pass. For an originalName like
// `air.fract.v3f16` the produced name `agx.air.fract.v3f16.fast` is
// never matched by `AGCLLVMAirBuiltins::replaceBuiltins`'s dispatcher
// (which only accepts the "air." prefix), so the call survives into
// `AGCLLVMUserObject::verifyLoweredIR` as an unlowered declaration and
// the compile aborts.
//
// The rename is implemented as a `std::string::insert(0, "agx.")` call
// — instruction `bl __ZNSt3__112basic_string…::insert(pos, str)` that
// follows the `add x2, x2, #… ; "agx."` adrp pair. If we NOP that one
// BL the agx-prefix step is skipped: the rename becomes
// `"" + originalName + ".fast" = "air.fract.v3f16.fast"`, the
// dispatcher's findPrefix accepts the "air." prefix, splits at the
// first dot of the remainder into ("fract", "v3f16.fast"), and the
// "fract" key already resolves to `AGCLLVMAirBuiltins::buildFract`,
// which lowers via the operand's runtime LLVM type — the trailing
// ".fast" in the name is just a suffix on the Function name and is
// ignored by buildFract (it reads the actual Value type, not the
// Function name).
//
// The patch site is found by anchoring on the surviving export
// `_AIRNTGetVersion` (one of the 33 public AIRNT* symbols). Delta
// measured against the iPad13,6 16.3.1 (20D67) DSC:
//   bl insert @ 0x1be243b70
//   _AIRNTGetVersion @ 0x1be369514
//   delta = -0x1259a4
//
// Validation: the instruction at the patch site must be a BL (opcode
// bits 26..31 == 0b100101 == 0x25). If the iOS AGXCompilerCore has
// changed and the byte is not a BL, we leave the original behaviour
// alone instead of corrupting some unknown instruction.
// Sandboxed XPC services (like MTLCompilerService under its
// `seatbelt-profiles=[MTLCompilerService]` profile) cannot create files
// outside /private/var/mobile, so the old fopen("/tmp/...") path silently
// failed. Try multiple destinations: a file under /var/mobile (writable
// by the XPC service's sandbox), syslog (tagged "MTLBypass"), and stderr.
static void MTLPatchLog(const char *fmt, ...) {
    static int once = 0;
    if (!once) { openlog("MTLBypass", LOG_PID | LOG_NDELAY, LOG_USER); once = 1; }
    char buf[512];
    pid_t pid = getpid();
    time_t now = time(NULL);
    struct tm tm; localtime_r(&now, &tm);
    int hdr = snprintf(buf, sizeof(buf),
        "[%04d-%02d-%02d %02d:%02d:%02d pid=%d] ",
        tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday,
        tm.tm_hour, tm.tm_min, tm.tm_sec, pid);
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf + hdr, sizeof(buf) - hdr, fmt, ap);
    va_end(ap);
    syslog(LOG_NOTICE, "%s", buf + hdr);
    fprintf(stderr, "#### MTLBypass %s\n", buf + hdr);
    fflush(stderr);
    // File witnesses are diagnostic-only.  Trying four sandbox-denied paths
    // for every stock iOS compiler instance polluted the kernel log and added
    // filesystem work to Safari's shader hot path.
    if (!MacWSCompilerDiagnosticsEnabled())
        return;
    // Try several paths until one is writable from the sandbox.
    static const char *paths[] = {
        "/var/mobile/Library/Logs/mtl_compiler_patch.log",
        "/var/mobile/mtl_compiler_patch.log",
        "/var/jb/var/mobile/mtl_compiler_patch.log",
        "/tmp/mtl_compiler_patch.log",
        NULL,
    };
    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "a");
        if (f) {
            fputs(buf, f);
            fputc('\n', f);
            fclose(f);
            return;
        }
    }
}

// MTLCompilerService runs in the iOS host namespace, while the macOS Metal
// client constructs its clang module-cache path from the chroot's
// /var/folders tree.  Sharing that tree with bindfs is insufficient: the
// service's seatbelt evaluates the original /var/folders pathname and rejects
// creation of monolithic_metal.pcm with EPERM.  Adapt only paths below a
// com.apple.metalfe cache directory to the rootless mobile tree.  That exact
// namespace is runtime-confirmed writable by this process because
// MTLPatchLog's /var/jb/var/mobile log survives every compiler request;
// /var/mobile/Library/Caches was separately tried and returned EPERM.  This
// preserves the file operation and its real result; it does not
// turn a failed check into success or synthesize compiler output.
//
// Runtime witness before this adapter (vscode.log, 2026-07-28):
//   unable to open output file '/var/folders/.../com.apple.metalfe/
//   F0DURH57MFZX/monolithic_metal.pcm': 'Operation not permitted'
//
// The wrappers also log each translated operation and errno so a future path
// or libc call-site change fails visibly rather than becoming a silent cache
// bypass.
static const char *kMetalCacheRoot =
    "/var/jb/var/mobile/Library/Caches/macws-metalfe";
static const char *kMetalCacheMarker = "/com.apple.metalfe/";

// MTLCompilerService is shared by stock iOS clients as well as the chroot.
// The exact source-build call sites below are therefore the isolation
// boundary: only a request carrying both chroot-only compiler arguments may
// activate MacWS filesystem translation.  A write lock makes that scope
// exclusive, while ordinary native requests retain concurrent read access and
// can never inherit the MacWS cache namespace.
static pthread_rwlock_t gMetalBuildRequestLock = PTHREAD_RWLOCK_INITIALIZER;
static _Atomic bool gMacWSMetalBuildRequestActive = false;
static bool gMetalCacheAdapterInstalled = false;

static bool TranslateMetalCachePath(const char *path,
                                    char translated[PATH_MAX]) {
    if (!atomic_load_explicit(&gMacWSMetalBuildRequestActive,
                              memory_order_acquire)) return false;
    if (!path || strncmp(path, "/var/folders/zz/", 16) != 0) return false;
    const char *marker = strstr(path, kMetalCacheMarker);
    if (!marker) return false;
    const char *suffix = marker + strlen(kMetalCacheMarker);
    int n = snprintf(translated, PATH_MAX, "%s/%s", kMetalCacheRoot, suffix);
    return n > 0 && n < PATH_MAX;
}

static int (*OrigOpen)(const char *, int, ...) = NULL;
static int (*OrigOpenAt)(int, const char *, int, ...) = NULL;
static int (*OrigStat)(const char *, struct stat *) = NULL;
static int (*OrigMkdir)(const char *, mode_t) = NULL;
static int (*OrigMkdirAt)(int, const char *, mode_t) = NULL;
static int (*OrigRename)(const char *, const char *) = NULL;
static int (*OrigRenameAt)(int, const char *, int, const char *) = NULL;
static int (*OrigUnlink)(const char *) = NULL;
static int (*OrigUnlinkAt)(int, const char *, int) = NULL;

static int MetalCacheOpen(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
    }
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    const char *actual = changed ? mapped : path;
    int result = (flags & O_CREAT) ? OrigOpen(actual, flags, mode)
                                   : OrigOpen(actual, flags);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache open flags=%#x '%s' -> '%s' result=%d errno=%d",
                             flags, path, actual, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheOpenAt(int fd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
    }
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    const char *actual = changed ? mapped : path;
    int result = (flags & O_CREAT) ? OrigOpenAt(fd, actual, flags, mode)
                                   : OrigOpenAt(fd, actual, flags);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache openat fd=%d flags=%#x '%s' -> '%s' result=%d errno=%d",
                             fd, flags, path, actual, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheStat(const char *path, struct stat *st) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    const char *actual = changed ? mapped : path;
    int result = OrigStat(actual, st);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache stat '%s' -> '%s' result=%d errno=%d",
                             path, actual, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheMkdir(const char *path, mode_t mode) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    int result = OrigMkdir(changed ? mapped : path, mode);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache mkdir '%s' -> '%s' result=%d errno=%d",
                             path, mapped, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheMkdirAt(int fd, const char *path, mode_t mode) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    int result = OrigMkdirAt(fd, changed ? mapped : path, mode);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache mkdirat fd=%d '%s' -> '%s' result=%d errno=%d",
                             fd, path, mapped, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheRename(const char *from, const char *to) {
    char mappedFrom[PATH_MAX], mappedTo[PATH_MAX];
    bool changedFrom = TranslateMetalCachePath(from, mappedFrom);
    bool changedTo = TranslateMetalCachePath(to, mappedTo);
    int result = OrigRename(changedFrom ? mappedFrom : from,
                            changedTo ? mappedTo : to);
    int saved = errno;
    if (changedFrom || changedTo)
        MTLPatchLog("metal-cache rename '%s' -> '%s' result=%d errno=%d",
                    changedFrom ? mappedFrom : from,
                    changedTo ? mappedTo : to,
                    result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheRenameAt(int fromFD, const char *from,
                              int toFD, const char *to) {
    char mappedFrom[PATH_MAX], mappedTo[PATH_MAX];
    bool changedFrom = TranslateMetalCachePath(from, mappedFrom);
    bool changedTo = TranslateMetalCachePath(to, mappedTo);
    int result = OrigRenameAt(fromFD, changedFrom ? mappedFrom : from,
                              toFD, changedTo ? mappedTo : to);
    int saved = errno;
    if (changedFrom || changedTo)
        MTLPatchLog("metal-cache renameat '%s' -> '%s' result=%d errno=%d",
                    changedFrom ? mappedFrom : from,
                    changedTo ? mappedTo : to,
                    result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheUnlink(const char *path) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    int result = OrigUnlink(changed ? mapped : path);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache unlink '%s' -> '%s' result=%d errno=%d",
                             path, mapped, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheUnlinkAt(int fd, const char *path, int flags) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    int result = OrigUnlinkAt(fd, changed ? mapped : path, flags);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache unlinkat fd=%d '%s' -> '%s' result=%d errno=%d",
                             fd, path, mapped, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static void InstallMetalCachePathAdapter(void) {
    // Parent exists in the stock mobile container; errors are left visible in
    // the operation logs below.  The benchmark setup creates the final root
    // once, while translated mkdir calls create per-compiler hash directories.
    mkdir(kMetalCacheRoot, 0755);
#define HOOK_LIBC(name, replacement, original) do { \
    void *symbol = dlsym(RTLD_DEFAULT, name); \
    if (symbol) MSHookFunction(symbol, (void *)(replacement), (void **)&(original)); \
} while (0)
    HOOK_LIBC("open", MetalCacheOpen, OrigOpen);
    HOOK_LIBC("openat", MetalCacheOpenAt, OrigOpenAt);
    HOOK_LIBC("stat", MetalCacheStat, OrigStat);
    HOOK_LIBC("mkdir", MetalCacheMkdir, OrigMkdir);
    HOOK_LIBC("mkdirat", MetalCacheMkdirAt, OrigMkdirAt);
    HOOK_LIBC("rename", MetalCacheRename, OrigRename);
    HOOK_LIBC("renameat", MetalCacheRenameAt, OrigRenameAt);
    HOOK_LIBC("unlink", MetalCacheUnlink, OrigUnlink);
    HOOK_LIBC("unlinkat", MetalCacheUnlinkAt, OrigUnlinkAt);
#undef HOOK_LIBC
    MTLPatchLog("metal-cache adapter installed root=%s open=%p openat=%p stat=%p mkdir=%p rename=%p unlink=%p",
                kMetalCacheRoot, OrigOpen, OrigOpenAt, OrigStat, OrigMkdir,
                OrigRename, OrigUnlink);
}

// The chroot's macOS Metal client sends source requests to the iOS-hosted
// MTLCompilerService.  Runtime LLDB at MTLCodeGenServiceBuildRequest captured
// the complete request ABI:
//
//   uint64_t sourceLength; uint64_t argumentLength;
//   char source[sourceLength]; padding-to-8; char arguments[argumentLength];
//
// The arguments omit a target platform.  Consequently the iOS service emits
// an iOS MTLB (header 0x0001/0x8200), which the unmodified macOS Metal loader
// rejects at MTLLibraryDataWithArchive::parseArchiveSync+680.  LLDB replacing
// the complete `-working-directory "..."` argument with
// `-active-platform=macos` plus length-preserving padding advanced the same
// request through the archive-format check and into real module compilation.
// The runtime adapter additionally requires the chroot-only /var/folders
// module-cache argument before making that replacement.  It then calls the
// original compiler entry point; no compiler result or loader validation is
// bypassed.
//
// MTLCompilerService uses three calls to the same service-vtable +0x18 build
// slot. The exact offsets are executable-identity-specific and live in the
// UUID profiles below. In every admitted profile `_compileRequestMain` uses
// `blraaz x9` (0xd63f093f); the hang-timer and no-timer XPC paths use
// `blraaz x8` (0xd63f091f). The worker entry loads the same six-argument ABI
// from its context before the call: service, plugin/request identifiers,
// request bytes, request length, and result storage.
//
// Runtime-confirmed 2026-07-28: adapting only +0x25f0/+0x2628 let Chromium's
// more complex MSL take `_compileRequestMain`.  The reply contained the exact
// target string `air64-apple-ios16.3.0`, then macOS Metal rejected it with
// "This library format is not supported on this platform".  Replacing all
// three authenticated indirect calls with validated direct BLs keeps every
// source request on the same macOS-target adapter and avoids the arm64e
// Substrate-trampoline PAC failure while leaving compiler results and loader
// validation untouched.
typedef uintptr_t (*MTLCodeGenServiceBuildRequestFn)(
    uintptr_t, uintptr_t, uintptr_t, void *, size_t, void *);
static MTLCodeGenServiceBuildRequestFn OrigMTLCodeGenServiceBuildRequest = NULL;
static uintptr_t StripPAC(const void *p);

// RE-confirmed libGPUCompilerImpl UUID 41d2f0618da83cfa8c4ac3e9d7009604:
// GPUCompiler::stitch +0xa8 calls getDefaultTargetTriple(None), dropping the
// Catalyst context of its inputs. Runtime reply raw-48059-001-e produced an
// iOS MTLB (01 00 / 82), rejected by macOS Metal. A native isolated replay
// passing Optional(PLATFORM_MACCATALYST=6) into the ORIGINAL Triple builder
// produced 01 80 / 86 and macOS loaded it without changing its validation.
// Both the stitcher and its archive writer use this same target constructor.
// Preserve the 48-byte indirect return ABI and Apple's construction/ownership.
// Runtime-confirmed 2026-09-19 for native CoreImage AIR13.4 too: an actual
// 16x16 graph emitted an iOS archive that the macOS loader rejected. A genuine
// LLVM setTriple to macOS fixed archive admission but iOS AGX then rejected
// the pipeline with "Target OS is incompatible." The real Catalyst factory
// satisfies BOTH consumers. Translate only a wholly consistent, validated
// MacWS DAG request; never patch archive bytes or suppress either validation.
typedef struct { uint64_t storage[6]; } MacWSTripleABI;
typedef MacWSTripleABI (*MacWSDefaultTripleFn)(uint64_t);
static MacWSDefaultTripleFn gOriginalDefaultTriple = NULL;
static _Thread_local MacWSMetalDAGInputTarget gMacWSDAGInputTarget = MacWSMetalDAGInputUnknown;
static bool gCatalystDAGTargetAttempted = false;
static bool gCatalystDAGTargetReady = false;

static MacWSTripleABI MacWSDefaultTripleForRequest(uint64_t optionalPlatform) {
    if (gMacWSDAGInputTarget != MacWSMetalDAGInputUnknown && optionalPlatform == 0)
        optionalPlatform = (UINT64_C(1) << 32) | 6;
    return gOriginalDefaultTriple(optionalPlatform);
}

// Called lazily under the existing compiler-request write lock, exclusively
// after a well-formed supported MacWS DAG. No stock iOS service installs this
// hook merely by starting up; ordinary iOS requests retain original arguments.
static bool InstallCatalystDAGTargetContext(void) {
    if (gCatalystDAGTargetAttempted) return gCatalystDAGTargetReady;
    gCatalystDAGTargetAttempted = true;
    void *image = dlopen("/System/Library/PrivateFrameworks/GPUCompiler.framework/Libraries/libGPUCompilerImpl.dylib", RTLD_NOW | RTLD_LOCAL);
    void *function = image ? dlsym(image,
        "_ZN7metalfe11GPUCompiler22getDefaultTargetTripleEN4llvm8OptionalINS1_5MachO12PlatformTypeEEE") : NULL;
    Dl_info info = {0};
    const uint8_t uuid[16] = {0x41,0xd2,0xf0,0x61,0x8d,0xa8,0x3c,0xfa,0x8c,0x4a,0xc3,0xe9,0xd7,0x00,0x96,0x04};
    if (!function || !dladdr((void *)StripPAC(function), &info)) return false;
    const struct mach_header_64 *header = info.dli_fbase;
    if (!header || header->magic != MH_MAGIC_64 || header->sizeofcmds > 1048576)
        return false;
    bool matched = false;
    const uint8_t *cursor = (const void *)(header + 1), *end = cursor + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && cursor + sizeof(struct load_command) <= end; i++) {
        const struct load_command *cmd = (const void *)cursor;
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > (size_t)(end - cursor)) return false;
        if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command))
            matched = !memcmp(((const struct uuid_command *)cmd)->uuid, uuid, 16);
        cursor += cmd->cmdsize;
    }
    const uint32_t expected[] = {0xd503237f, 0xd10283ff, 0xa9065ff8, 0xa90757f6};
    void *entry = (void *)StripPAC(function);
    if (!matched || memcmp(entry, expected, sizeof(expected))) {
        MTLPatchLog("Catalyst DAG target context: unsupported compiler ABI; original retained");
        return false;
    }
    MSHookFunction(function, (void *)MacWSDefaultTripleForRequest,
                   (void **)&gOriginalDefaultTriple);
    kern_return_t protection = vm_protect(mach_task_self(), (vm_address_t)entry,
        sizeof(expected), false, VM_PROT_READ | VM_PROT_EXECUTE);
    gCatalystDAGTargetReady = gOriginalDefaultTriple && protection == KERN_SUCCESS;
    MTLPatchLog("Catalyst DAG target context installed=%d restore-rx=%d",
                gCatalystDAGTargetReady, protection);
    return gCatalystDAGTargetReady;
}

// CoreUI uses the distinct image-filter compiler request (kind 5). The
// captured raw-80913-001-5 request and its reply prove that this path emits
// macOS AIR even with the default-Triple adapter above. RE-confirmed in
// libComposeFilters BEAEC489-ED9B-3F62-B645-BC10399B2D18: +0x9bb8 receives
// three opaque vectors and an error-output pointer; its first vector contains
// Module pointers. It links the input modules, then composes the kernel using
// their target. It does not obtain that target from getDefaultTargetTriple.
//
// Adapt the request-owned LLVM modules BEFORE linking, through LLVM's real
// C API, without direct Module/Triple field writes or changes to request bytes,
// archive headers, compiler checks or return values. The original compose owns the modules
// and may destroy them, so never inspect or restore them after that call.
typedef void *(*MacWSComposeImageFiltersFn)(void *, void *, void *, void *);
typedef const char *(*MacWSLLVMGetTargetFn)(void *);
typedef void (*MacWSLLVMSetTargetFn)(void *, const char *);
static MacWSComposeImageFiltersFn gOriginalComposeImageFilters;
static MacWSLLVMGetTargetFn gImageFilterGetTarget;
static MacWSLLVMSetTargetFn gImageFilterSetTarget;
static _Thread_local uint32_t gImageFilterRequestModuleCount;
static bool gImageFilterTargetAttempted;
static bool gImageFilterTargetReady;

static void *MacWSComposeImageFilters(void *moduleVector, void *functions,
                                      void *filterInfo, void *errorOutput) {
    uint32_t count = gImageFilterRequestModuleCount;
    bool supported = count && count <= 4096 && moduleVector;
    void **modules = NULL;
    if (supported) {
        // Only this UUID-locked function's actual vector ABI is interpreted;
        // no ownership/construction/destruction of the C++ object is assumed.
        uintptr_t bounds[3];
        memcpy(bounds, moduleVector, sizeof(bounds));
        supported = bounds[0] && !(bounds[0] & 7) &&
            bounds[1] >= bounds[0] && bounds[2] >= bounds[1] &&
            !((bounds[1] - bounds[0]) & 7) &&
            !((bounds[2] - bounds[0]) & 7) &&
            bounds[1] - bounds[0] == (uintptr_t)count * sizeof(void *) &&
            bounds[2] - bounds[0] <= 4096U * sizeof(void *);
        if (supported) modules = (void **)bounds[0];
    }
    // Validate the entire live set before mutating any module. The byte-level
    // request classifier alone is not a substitute for LLVM's parsed target.
    for (uint32_t i = 0; supported && i < count; ++i) {
        if (!modules[i]) { supported = false; break; }
        for (uint32_t j = 0; j < i; ++j)
            if (modules[i] == modules[j]) { supported = false; break; }
        if (!supported) break;
        const char *target = gImageFilterGetTarget(modules[i]);
        supported = target && !strcmp(target, "air64-apple-macosx13.4.0");
    }
    if (supported) {
        for (uint32_t i = 0; i < count; ++i)
            gImageFilterSetTarget(modules[i], "air64-apple-ios19.0.0-macabi");
    }
    if (count && MacWSCompilerDiagnosticsEnabled())
        MTLPatchLog("MacWS image-filter module-target count=%u adapted=%d",
                    count, supported);
    return gOriginalComposeImageFilters(moduleVector, functions,
                                         filterInfo, errorOutput);
}

static bool MacWSCompilerSymbolMatches(const void *symbol,
        const uint8_t uuid[16], uintptr_t offset, const uint32_t prologue[4]) {
    if (!symbol) return false;
    uintptr_t entry = StripPAC(symbol);
    Dl_info info = {0};
    if (!dladdr((void *)entry, &info) || !info.dli_fbase ||
        entry - (uintptr_t)info.dli_fbase != offset) return false;
    const struct mach_header_64 *header = info.dli_fbase;
    if (header->magic != MH_MAGIC_64 || header->sizeofcmds > 1048576 ||
        header->ncmds > 2048) return false;
    const uint8_t *cursor = (const void *)(header + 1);
    const uint8_t *end = cursor + header->sizeofcmds;
    bool matched = false;
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return false;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            command->cmdsize > (size_t)(end - cursor)) return false;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command))
            matched = !memcmp(((const struct uuid_command *)command)->uuid, uuid, 16);
        cursor += command->cmdsize;
    }
    return matched && !memcmp((const void *)entry, prologue, 16);
}

// Called only under the compiler-request write lock, after a completely
// recognized native-macOS kind-5 envelope. Ordinary iOS compiler startup does
// not load or install this adapter. Unknown compiler ABIs retain stock behavior.
static bool InstallImageFilterTargetContext(void) {
    if (gImageFilterTargetAttempted) return gImageFilterTargetReady;
    gImageFilterTargetAttempted = true;
    void *compose = dlopen("/System/Library/PrivateFrameworks/GPUCompiler.framework/Libraries/libComposeFilters.dylib", RTLD_NOW | RTLD_LOCAL);
    void *llvm = dlopen("/usr/lib/libLLVM.dylib", RTLD_NOW | RTLD_LOCAL);
    void *function = compose ? dlsym(compose, "composeImageFilterFunctionsFromModulesSPI") : NULL;
    void *getTarget = llvm ? dlsym(llvm, "LLVMGetTarget") : NULL;
    void *setTarget = llvm ? dlsym(llvm, "LLVMSetTarget") : NULL;
    static const uint8_t composeUUID[16] = {0xbe,0xae,0xc4,0x89,0xed,0x9b,0x3f,0x62,0xb6,0x45,0xbc,0x10,0x39,0x9b,0x2d,0x18};
    static const uint8_t llvmUUID[16] = {0x3c,0x9d,0x9d,0x6c,0xcc,0x92,0x32,0x6a,0x91,0x1c,0x14,0x1b,0xc9,0x6d,0xc8,0xbe};
    static const uint32_t composeEntry[4] = {0xd503237f,0xd10443ff,0xa90b6ffc,0xa90c67fa};
    static const uint32_t getEntry[4] = {0xaa0003e8,0x91036000,0x39c3bd08,0x37f80048};
    static const uint32_t setEntry[4] = {0xd503237f,0xa9be4ff4,0xa9017bfd,0x910043fd};
    if (!MacWSCompilerSymbolMatches(function, composeUUID, 0x9bb8, composeEntry) ||
        !MacWSCompilerSymbolMatches(getTarget, llvmUUID, 0x844fb0, getEntry) ||
        !MacWSCompilerSymbolMatches(setTarget, llvmUUID, 0x844fcc, setEntry)) {
        MTLPatchLog("Image-filter target context: unsupported compiler ABI; original retained");
        return false;
    }
    gImageFilterGetTarget = (MacWSLLVMGetTargetFn)getTarget;
    gImageFilterSetTarget = (MacWSLLVMSetTargetFn)setTarget;
    MSHookFunction(function, (void *)MacWSComposeImageFilters,
                   (void **)&gOriginalComposeImageFilters);
    kern_return_t protection = vm_protect(mach_task_self(),
        (vm_address_t)StripPAC(function), sizeof(composeEntry), false,
        VM_PROT_READ | VM_PROT_EXECUTE);
    gImageFilterTargetReady = gOriginalComposeImageFilters && protection == KERN_SUCCESS;
    MTLPatchLog("Image-filter target context installed=%d restore-rx=%d",
                gImageFilterTargetReady, protection);
    return gImageFilterTargetReady;
}

static uint64_t MacWSFNV1a64(const void *data, size_t length) {
    const uint8_t *bytes = (const uint8_t *)data;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (size_t i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

// The compiler result is wrapped into XPC data immediately after the build
// call returns on the same request-handler thread (RE-confirmed in every
// UUID-locked executable profile below).
// Preserve only diagnostic correlation metadata across that boundary.  The
// request and result bytes themselves remain owned and consumed by Apple's
// original implementation.
static _Thread_local uint32_t gReplyRequestSequence = 0;
static _Thread_local uintptr_t gReplyRequestDiscriminator = 0;
static _Thread_local uint64_t gReplySourceHash = 0;

// Steam's current CEF build does not pass the -fmodules-cache-path argument
// used by Electron/VS Code, but it does preserve its bundle Resources path as
// the compiler working directory.  Accept only the two exact Steam Helper
// bundle locations that MacWS can launch.  This keeps ordinary iOS Metal
// clients outside the target adapter even though they use the same shared
// MTLCompilerService process.
static bool MacWSIsSteamHelperWorkingDirectoryToken(const uint8_t *token,
                                                     size_t tokenLength) {
    static const char *const exactTokens[] = {
        "-working-directory \"/Users/root/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/Frameworks/Steam Helper.app/Contents/Resources\"",
        "-working-directory \"/Applications/Steam.app/Contents/Frameworks/Steam Helper.app/Contents/Resources\"",
    };
    if (!token) return false;
    for (size_t i = 0; i < sizeof(exactTokens) / sizeof(exactTokens[0]); i++) {
        size_t expectedLength = strlen(exactTokens[i]);
        if (tokenLength == expectedLength &&
            memcmp(token, exactTokens[i], expectedLength) == 0) {
            return true;
        }
    }
    return false;
}

// Unity 2022.3.62f2 does not serialize the module-cache argument used by
// Chromium.  The arm64 7DTD runtime instead sends the same 335-byte Metal 3.0
// option block for every source library and identifies its prepared runtime
// through this exact Resources working directory.  Runtime capture on the
// iPad14,5/iOS 16.0 target recorded source requests with layout deltas 0 and
// 4; the latter is Apple's short serialization for the one-byte empty source.
// Admit only that exact private runtime contract.  This selects the existing
// real macOS compiler target and never changes a compiler result or loader
// validation.
static bool MacWSIsSevenDaysUnitySourceRequest(
        const uint8_t *token, size_t tokenLength,
        uint64_t sourceLength, uint64_t argumentLength,
        long long layoutDelta) {
    static const char exactToken[] =
        "-working-directory \"/Users/root/Library/Application Support/Steam/"
        "steamapps/macws-runtime/7 Days To Die/7DaysToDie-ARM.app/Contents/"
        "Resources\"";
    return token &&
        tokenLength == sizeof(exactToken) - 1 &&
        memcmp(token, exactToken, sizeof(exactToken) - 1) == 0 &&
        sourceLength >= 1 && argumentLength == 335 &&
        (layoutDelta == 0 || layoutDelta == 4);
}

// Steam's overlay injects one separate Metal source library after Unity's
// first library succeeds.  Runtime capture from the real Steam-owned 7DTD
// child on iPad14,5/iOS 16.0 recorded the exact source/serialization tuple
// below.  Leaving it on the service's iOS default target returned a real
// library whose `steamoverlay_vs` lookup was nil; the following stock render
// pipeline validation then aborted on `vertexFunction must not be nil`.
// Select macOS only for this byte-exact upstream overlay source in the exact
// prepared 7DTD Resources directory.  Compiler output and function/pipeline
// validation remain untouched.
static bool MacWSIsSevenDaysOverlaySourceRequest(
        const uint8_t *token, size_t tokenLength, size_t requestSize,
        uint64_t sourceLength, uint64_t argumentLength,
        long long layoutDelta, uint64_t sourceHash) {
    static const char exactToken[] =
        "-working-directory \"/Users/root/Library/Application Support/Steam/"
        "steamapps/macws-runtime/7 Days To Die/7DaysToDie-ARM.app/Contents/"
        "Resources\"";
    return token &&
        tokenLength == sizeof(exactToken) - 1 &&
        memcmp(token, exactToken, sizeof(exactToken) - 1) == 0 &&
        requestSize == 2407 && sourceLength == 2189 &&
        argumentLength == 199 && layoutDelta == 0 &&
        sourceHash == UINT64_C(0xc9b090f289e24745);
}

static void DumpCompilerRequest(uint32_t sequence, uint64_t sourceHash,
                                const void *request, size_t requestSize) {
    if (!request || !requestSize || sequence > 64) return;
    const char *directory =
        "/var/jb/var/mobile/mtlcompiler_requests";
    mkdir(directory, 0755);
    char path[PATH_MAX];
    snprintf(path, sizeof(path),
             "%s/request-%d-%03u-%zu-%016llx.bin",
             directory, getpid(), sequence, requestSize,
             (unsigned long long)sourceHash);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        MTLPatchLog("compiler request #%u dump open failed path=%s errno=%d",
                    sequence, path, errno);
        return;
    }
    const uint8_t *cursor = (const uint8_t *)request;
    size_t remaining = requestSize;
    while (remaining) {
        ssize_t written = write(fd, cursor, remaining);
        if (written <= 0) break;
        cursor += written;
        remaining -= (size_t)written;
    }
    close(fd);
    MTLPatchLog("compiler request #%u sourceHash=%016llx dump=%s written=%zu/%zu",
                sequence, (unsigned long long)sourceHash, path,
                requestSize - remaining, requestSize);
}

// Diagnostic-only, byte-for-byte request witness for non-source compiler
// operations.  A scene transition can make the long-lived worker abort while
// reading a binary module, after which launchd replays the same request into a
// fresh worker.  Keep the first 64 inputs from each worker so that replayed
// request is preserved without adding unbounded I/O to normal gameplay.  This
// runs before any source-target adaptation and never changes the request.
static void DumpRawCompilerRequest(uint32_t sequence, uintptr_t discriminator,
                                   const void *request, size_t requestSize) {
    if (!request || !requestSize || sequence > 64) return;
    const char *directory = "/var/jb/var/mobile/mtlcompiler_requests";
    mkdir(directory, 0755);
    uint64_t requestHash = MacWSFNV1a64(request, requestSize);
    char path[PATH_MAX];
    snprintf(path, sizeof(path),
             "%s/raw-%d-%03u-%lx-%zu-%016llx.bin",
             directory, getpid(), sequence,
             (unsigned long)discriminator, requestSize,
             (unsigned long long)requestHash);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        MTLPatchLog("raw compiler request #%u discriminator=%#lx dump open failed path=%s errno=%d",
                    sequence, (unsigned long)discriminator, path, errno);
        return;
    }
    const uint8_t *cursor = (const uint8_t *)request;
    size_t remaining = requestSize;
    while (remaining) {
        ssize_t written = write(fd, cursor, remaining);
        if (written <= 0) break;
        cursor += written;
        remaining -= (size_t)written;
    }
    close(fd);
    MTLPatchLog("raw compiler request #%u discriminator=%#lx hash=%016llx dump=%s written=%zu/%zu",
                sequence, (unsigned long)discriminator,
                (unsigned long long)requestHash, path,
                requestSize - remaining, requestSize);
}

// Read-only compiler-result witness. MTLCompilerService's exact executable
// reply block calls xpc_data_create at the UUID-profiled reply offset with the
// compiler result bytes and length. The adapter redirects only that BL here,
// records the returned container verbatim, then calls the real XPC API. No
// result bytes or status are changed.
static void *MacWSCompilerReplyDataCreate(const void *bytes, size_t length) {
    if (!MacWSCompilerDiagnosticsEnabled()) return xpc_data_create(bytes, length);
    static _Atomic uint32_t replySequence = 0;
    uint32_t sequence = atomic_fetch_add(&replySequence, 1) + 1;
    uint64_t hash = MacWSFNV1a64(bytes, length);
    uint8_t head[24] = {0};
    size_t headLength = length < sizeof(head) ? length : sizeof(head);
    if (bytes && headLength) memcpy(head, bytes, headLength);
    MTLPatchLog("compiler reply #%u request=%u discriminator=%#lx sourceHash=%016llx length=%zu hash=%016llx head=%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x",
                sequence, gReplyRequestSequence,
                (unsigned long)gReplyRequestDiscriminator,
                (unsigned long long)gReplySourceHash,
                length, (unsigned long long)hash,
                head[0], head[1], head[2], head[3],
                head[4], head[5], head[6], head[7],
                head[8], head[9], head[10], head[11],
                head[12], head[13], head[14], head[15],
                head[16], head[17], head[18], head[19],
                head[20], head[21], head[22], head[23]);

    if (bytes && length && sequence <= 64) {
        const char *directory =
            "/var/jb/var/mobile/mtlcompiler_replies";
        mkdir(directory, 0755);
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/reply-%d-%03u-%zu-%016llx.bin",
                 directory, getpid(), sequence, length,
                 (unsigned long long)hash);
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd >= 0) {
            const uint8_t *cursor = (const uint8_t *)bytes;
            size_t remaining = length;
            while (remaining) {
                ssize_t written = write(fd, cursor, remaining);
                if (written <= 0) break;
                cursor += written;
                remaining -= (size_t)written;
            }
            close(fd);
            MTLPatchLog("compiler reply #%u dump=%s written=%zu/%zu",
                        sequence, path, length - remaining, length);
        } else {
            MTLPatchLog("compiler reply #%u dump open failed path=%s errno=%d",
                        sequence, path, errno);
        }
    }
    return xpc_data_create(bytes, length);
}

static uintptr_t MacWSMTLCodeGenServiceBuildRequest(
    uintptr_t a0, uintptr_t a1, uintptr_t a2,
    void *request, size_t requestSize, void *a5) {
    static const char workingDirectoryPrefix[] = "-working-directory \"";
    static const char targetArgument[] = "-active-platform=macos";
    static _Atomic uint32_t requestSequence = 0;
    uint32_t sequence = atomic_fetch_add(&requestSequence, 1) + 1;
    bool diagnostics = MacWSCompilerDiagnosticsEnabled();
    gReplyRequestSequence = sequence;
    gReplyRequestDiscriminator = a2;
    gReplySourceHash = 0;
    // The original observer logged only source-build discriminator 0xd.  That
    // left a dangerous evidence gap: Chromium's complex worker path could
    // enter the same real service vtable with another discriminator and look
    // indistinguishable from "the compiler was never called".  Record the
    // complete six-argument ABI at a bounded cadence in diagnostic sessions;
    // production performs no logging and keeps the exact original call.
    if (diagnostics && (sequence <= 256 || (sequence % 500) == 0)) {
        uint8_t head[16] = {0};
        size_t headLength = requestSize < sizeof(head)
            ? requestSize : sizeof(head);
        if (request && headLength) memcpy(head, request, headLength);
        MTLPatchLog("target adapter entry #%u a0=%#lx a1=%#lx a2=%#lx request=%p total=%zu a5=%p head=%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x",
                    sequence, (unsigned long)a0, (unsigned long)a1,
                    (unsigned long)a2, request, requestSize, a5,
                    head[0], head[1], head[2], head[3],
                    head[4], head[5], head[6], head[7],
                    head[8], head[9], head[10], head[11],
                    head[12], head[13], head[14], head[15]);
    }
    if (diagnostics)
        DumpRawCompilerRequest(sequence, a2, request, requestSize);
    bool adapted = false;
    bool needsCacheAdapter = false;
    if (request && requestSize >= 16 && a2 == 0xd) {
        // Chromium's MSL requests use two closely related serializations.
        // Most are exactly 16 + source + 8-byte padding + arguments.  Others
        // declare the same source/argument lengths but are four bytes shorter
        // than that formula.  Both carry the literal compiler arguments, so
        // locate the two exact chroot-only tokens in the bounded request blob
        // instead of guessing which serializer produced it.
        static const char cacheMarker[] =
            "-fmodules-cache-path=\"/var/folders/zz/";
        uint8_t *bytes = (uint8_t *)request;
        uint64_t sourceLength = 0, argumentLength = 0;
        memcpy(&sourceLength, bytes, sizeof(sourceLength));
        memcpy(&argumentLength, bytes + 8, sizeof(argumentLength));
        bool sourceBoundsValid = sourceLength <= requestSize - 16;
        size_t sourceHashLength = sourceBoundsValid
            ? (size_t)sourceLength : 0;
        if (sourceHashLength && bytes[16 + sourceHashLength - 1] == 0)
            sourceHashLength--;
        uint64_t sourceHash = sourceHashLength
            ? MacWSFNV1a64(bytes + 16, sourceHashLength) : 0;
        uint64_t expectedSize = sourceLength <= UINT64_MAX - 23
            ? ((UINT64_C(16) + sourceLength + 7) & ~UINT64_C(7))
            : UINT64_MAX;
        if (expectedSize != UINT64_MAX &&
            argumentLength <= UINT64_MAX - expectedSize) {
            expectedSize += argumentLength;
        } else {
            expectedSize = UINT64_MAX;
        }
        long long layoutDelta = expectedSize <= LLONG_MAX
            ? (long long)expectedSize - (long long)requestSize
            : LLONG_MAX;
        size_t prefixLength = sizeof(workingDirectoryPrefix) - 1;
        size_t markerLength = sizeof(cacheMarker) - 1;
        size_t workingOffset = (size_t)-1;
        size_t cacheOffset = (size_t)-1;
        for (size_t i = 0; i + prefixLength <= requestSize; i++) {
            if (memcmp(bytes + i, workingDirectoryPrefix,
                       prefixLength) == 0) {
                workingOffset = i;
                break;
            }
        }
        for (size_t i = 0; i + markerLength <= requestSize; i++) {
            if (memcmp(bytes + i, cacheMarker, markerLength) == 0) {
                cacheOffset = i;
                break;
            }
        }
        if (workingOffset != (size_t)-1) {
            size_t closingQuote = workingOffset + prefixLength;
            while (closingQuote < requestSize &&
                   bytes[closingQuote] != '"') {
                closingQuote++;
            }
            size_t targetLength = sizeof(targetArgument) - 1;
            if (closingQuote < requestSize) {
                size_t tokenLength = closingQuote - workingOffset + 1;
                bool chrootCacheRequest = cacheOffset != (size_t)-1;
                bool steamHelperRequest =
                    MacWSIsSteamHelperWorkingDirectoryToken(
                        bytes + workingOffset, tokenLength);
                bool sevenDaysUnityRequest =
                    MacWSIsSevenDaysUnitySourceRequest(
                        bytes + workingOffset, tokenLength,
                        sourceLength, argumentLength, layoutDelta);
                bool sevenDaysOverlayRequest =
                    MacWSIsSevenDaysOverlaySourceRequest(
                        bytes + workingOffset, tokenLength, requestSize,
                        sourceLength, argumentLength, layoutDelta, sourceHash);
                // Runtime-confirmed by request-3749-019 on 2026-08-19:
                // Steam's in-game overlay compiles this source with nil
                // MTLCompileOptions, so the request has no module-cache
                // marker.  Its working directory is the prepared Stray
                // runtime bundle, not Steam Helper.  Match the complete
                // source/serialization tuple and exact directory before
                // selecting the macOS target; unrelated iOS compiler traffic
                // remains untouched.
                static const char strayOverlayToken[] =
                    "-working-directory \"/Users/root/Library/Application "
                    "Support/Steam/steamapps/macws-runtime/Stray/Stray.app/"
                    "Contents/Resources\"";
                bool strayOverlayRequest =
                    tokenLength == sizeof(strayOverlayToken) - 1 &&
                    memcmp(bytes + workingOffset, strayOverlayToken,
                           sizeof(strayOverlayToken) - 1) == 0 &&
                    requestSize == 2390 && sourceLength == 2189 &&
                    argumentLength == 182 &&
                    sourceHash == UINT64_C(0xc9b090f289e24745);
                // Reproducible package-asset builder for Steam's exact
                // Chromium 126 / ANGLE 5d4df51 default shader source.  Public
                // Metal always serializes the standalone probe's working
                // directory as /private/tmp, so it cannot satisfy the normal
                // Steam-helper token above.  Allow only the byte-exact
                // upstream source/ABI tuple while an explicit rootless
                // sentinel exists.  This is diagnostic build machinery, not
                // a production compatibility bypass; normal iOS requests and
                // every different source continue unchanged.
                static const char assetBuildToken[] =
                    "-working-directory \"/private/tmp\"";
                bool steamANGLEAssetBuild =
                    access("/tmp/macws_steam_angle_asset_build", F_OK) == 0 &&
                    tokenLength == sizeof(assetBuildToken) - 1 &&
                    memcmp(bytes + workingOffset, assetBuildToken,
                           sizeof(assetBuildToken) - 1) == 0 &&
                    requestSize == 175034 && sourceLength == 174926 &&
                    argumentLength == 90 &&
                    sourceHash == UINT64_C(0xa90e497bcdffdc8d);
                if ((chrootCacheRequest || steamHelperRequest ||
                     sevenDaysUnityRequest || sevenDaysOverlayRequest ||
                     strayOverlayRequest || steamANGLEAssetBuild) &&
                    tokenLength >= targetLength) {
                    memcpy(bytes + workingOffset, targetArgument,
                           targetLength);
                    memset(bytes + workingOffset + targetLength, ' ',
                           tokenLength - targetLength);
                    adapted = true;
                    needsCacheAdapter = chrootCacheRequest;
                }
            }
        }

        if (sourceBoundsValid) {
            gReplySourceHash = sourceHash;
            if (adapted || diagnostics) {
                MTLPatchLog("target adapter #%u request=%p total=%zu source=%llu sourceHash=%016llx args=%llu layoutDelta=%lld workingOffset=%lld cacheOffset=%lld adapted=%d cacheAdapter=%d",
                            sequence, request, requestSize,
                            (unsigned long long)sourceLength,
                            (unsigned long long)sourceHash,
                            (unsigned long long)argumentLength, layoutDelta,
                            workingOffset == (size_t)-1 ? -1LL
                                : (long long)workingOffset,
                            cacheOffset == (size_t)-1 ? -1LL
                                : (long long)cacheOffset,
                            adapted, needsCacheAdapter);
            }
            if (diagnostics)
                DumpCompilerRequest(sequence, sourceHash,
                                    request, requestSize);
        }
    }

    if (!OrigMTLCodeGenServiceBuildRequest) return (uintptr_t)-1;

    MacWSMetalDAGInputTarget dagInputTarget = a2 == 14
        ? MacWSMetalDAGGetInputTarget(request, requestSize) : MacWSMetalDAGInputUnknown;
    bool nativeImageFilter = a2 == 5 &&
        MacWSMetalImageFilterGetInputTarget(request, requestSize) == MacWSMetalDAGInputMacOS134;
    if (adapted || dagInputTarget != MacWSMetalDAGInputUnknown || nativeImageFilter)
        pthread_rwlock_wrlock(&gMetalBuildRequestLock);
    else
        pthread_rwlock_rdlock(&gMetalBuildRequestLock);
    // Do not interpose libc in a stock iOS compiler process at all.  The old
    // ctor-time install made Safari's MTLCompilerService execute our
    // MetalCacheUnlinkAt wrapper and runtime-confirmed stack-canary failures
    // followed.  A MacWS source request is the first legitimate point at
    // which this process needs the chroot cache namespace.
    if (needsCacheAdapter && !gMetalCacheAdapterInstalled) {
        InstallMetalCachePathAdapter();
        gMetalCacheAdapterInstalled = true;
    }
    atomic_store_explicit(&gMacWSMetalBuildRequestActive, needsCacheAdapter,
                          memory_order_release);
    MacWSMetalDAGInputTarget previousDAGContext = gMacWSDAGInputTarget;
    gMacWSDAGInputTarget = dagInputTarget && InstallCatalystDAGTargetContext()
        ? dagInputTarget : MacWSMetalDAGInputUnknown;
    uint32_t previousImageFilterCount = gImageFilterRequestModuleCount;
    gImageFilterRequestModuleCount = nativeImageFilter && InstallImageFilterTargetContext()
        ? MacWSMetalImageFilterReadLE32((const uint8_t *)request + 8) : 0;
    if (diagnostics && dagInputTarget)
        MTLPatchLog("MacWS DAG request input-target=%u catalyst-context=%d size=%zu",
            dagInputTarget, gMacWSDAGInputTarget != MacWSMetalDAGInputUnknown, requestSize);
    uintptr_t result = OrigMTLCodeGenServiceBuildRequest(
        a0, a1, a2, request, requestSize, a5);
    gImageFilterRequestModuleCount = previousImageFilterCount;
    gMacWSDAGInputTarget = previousDAGContext;
    atomic_store_explicit(&gMacWSMetalBuildRequestActive, false,
                          memory_order_release);
    pthread_rwlock_unlock(&gMetalBuildRequestLock);
    return result;
}

static void InstallMacOSMetalTargetAdapter(void) {
    // RE-confirmed from the complete executables, not inferred from the OS
    // version. All admitted images have the same three authenticated build-call
    // sites and the same reply call:
    //
    //   iOS 16.3.1 (20D67)  UUID 6D2CFE56-8D88-39AA-BC25-7FFE5058ED4E
    //   iOS 16.0   (20A8372) UUID B4745394-88D0-3739-9E17-4DE2FB12B00E
    //   iOS 16.5.1 (20F75)  UUID B5CBF457-B300-3FD0-A646-1261DA6E86B0
    //
    // The 20A8372 executable has SHA-256
    // 2f980bfb46e3d97c5a330f54c158b41de21793ec113f3d33891e3599e75faba5;
    // otool disassembly confirms +0x20e8 is `blraaz x9`, +0x25f0 and
    // +0x2628 are `blraaz x8`, and +0x2770 is the same xpc_data_create BL.
    // The 20F75 executable has SHA-256
    // 4f8475c2ffeae25f35d36ba2614a8986941f904439d46f1295546ca4ef758e5a.
    // RE-confirmed from that exact file: the same semantic calls are at
    // +0x2050/+0x2558/+0x2590, and +0x26d8 is `bl _xpc_data_create` with
    // encoding 0x940004ae. Do not combine its UUID with the older offsets:
    // doing so would pass identity but fail the instruction invariant.
    //
    // Keep offsets and expected instructions in the same exact UUID profile
    // so an unexamined service build always retains stock behavior.
    struct MacWSTargetAdapterCallSite {
        uintptr_t offset;
        uint32_t expected;
    };
    struct MacWSTargetAdapterProfile {
        uint8_t uuid[16];
        struct MacWSTargetAdapterCallSite callSites[3];
        uintptr_t replyOffset;
        uint32_t expectedReplyCall;
    };
    static const struct MacWSTargetAdapterProfile profiles[] = {
        {
            .uuid = {
                0x6d, 0x2c, 0xfe, 0x56, 0x8d, 0x88, 0x39, 0xaa,
                0xbc, 0x25, 0x7f, 0xfe, 0x50, 0x58, 0xed, 0x4e,
            },
            .callSites = {
                {0x20e8, 0xd63f093f},
                {0x25f0, 0xd63f091f},
                {0x2628, 0xd63f091f},
            },
            .replyOffset = 0x2770,
            .expectedReplyCall = 0x9400047c,
        },
        {
            .uuid = {
                0xb4, 0x74, 0x53, 0x94, 0x88, 0xd0, 0x37, 0x39,
                0x9e, 0x17, 0x4d, 0xe2, 0xfb, 0x12, 0xb0, 0x0e,
            },
            .callSites = {
                {0x20e8, 0xd63f093f},
                {0x25f0, 0xd63f091f},
                {0x2628, 0xd63f091f},
            },
            .replyOffset = 0x2770,
            .expectedReplyCall = 0x9400047c,
        },
        {
            .uuid = {
                0xb5, 0xcb, 0xf4, 0x57, 0xb3, 0x00, 0x3f, 0xd0,
                0xa6, 0x46, 0x12, 0x61, 0xda, 0x6e, 0x86, 0xb0,
            },
            .callSites = {
                {0x2050, 0xd63f093f},
                {0x2558, 0xd63f091f},
                {0x2590, 0xd63f091f},
            },
            .replyOffset = 0x26d8,
            .expectedReplyCall = 0x940004ae,
        },
    };
    const struct mach_header_64 *mh = NULL;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name,
                "MTLCompilerService.xpc/MTLCompilerService")) {
            mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
            break;
        }
    }
    if (!mh || mh->magic != MH_MAGIC_64 || mh->filetype != MH_EXECUTE) {
        MTLPatchLog("target adapter: executable Mach-O header unavailable mh=%p magic=%#x filetype=%#x",
                    mh, mh ? mh->magic : 0, mh ? mh->filetype : 0);
        return;
    }
    const struct load_command *lc =
        (const struct load_command *)((const uint8_t *)mh + sizeof(*mh));
    const struct MacWSTargetAdapterProfile *profile = NULL;
    uint8_t actualUUID[16] = {0};
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_UUID) {
            const struct uuid_command *uc = (const struct uuid_command *)lc;
            memcpy(actualUUID, uc->uuid, sizeof(actualUUID));
            for (size_t candidate = 0;
                 candidate < sizeof(profiles) / sizeof(profiles[0]);
                 candidate++) {
                if (memcmp(actualUUID, profiles[candidate].uuid,
                           sizeof(actualUUID)) == 0) {
                    profile = &profiles[candidate];
                    break;
                }
            }
            break;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!profile) {
        MTLPatchLog("target adapter: MTLCompilerService UUID mismatch "
                    "%02x%02x%02x%02x-%02x%02x-%02x%02x-"
                    "%02x%02x-%02x%02x%02x%02x%02x%02x",
                    actualUUID[0], actualUUID[1], actualUUID[2], actualUUID[3],
                    actualUUID[4], actualUUID[5], actualUUID[6], actualUUID[7],
                    actualUUID[8], actualUUID[9], actualUUID[10], actualUUID[11],
                    actualUUID[12], actualUUID[13], actualUUID[14], actualUUID[15]);
        return;
    }

    OrigMTLCodeGenServiceBuildRequest =
        (MTLCodeGenServiceBuildRequestFn)dlsym(
            RTLD_DEFAULT, "MTLCodeGenServiceBuildRequest");
    if (!OrigMTLCodeGenServiceBuildRequest) {
        MTLPatchLog("target adapter: symbol unavailable");
        OrigMTLCodeGenServiceBuildRequest = NULL;
        return;
    }

    uintptr_t target = StripPAC((const void *)MacWSMTLCodeGenServiceBuildRequest);
    // Validate the exact entry, not merely an address within BL range.
    if (*(const uint32_t *)target != 0xd503237fu) {
        MTLPatchLog("target adapter: wrapper entry validation failed target=%#lx insn=%#x",
                    (unsigned long)target, *(const uint32_t *)target);
        OrigMTLCodeGenServiceBuildRequest = NULL;
        return;
    }
    uint32_t branches[3] = {0};
    for (size_t i = 0; i < 3; i++) {
        uint32_t *callSite =
            (uint32_t *)((uintptr_t)mh + profile->callSites[i].offset);
        intptr_t delta = (intptr_t)target - (intptr_t)callSite;
        if (*callSite != profile->callSites[i].expected) {
            MTLPatchLog("target adapter: validation failed offset=%#lx site=%p insn=%#x",
                        (unsigned long)profile->callSites[i].offset, callSite,
                        *callSite);
            OrigMTLCodeGenServiceBuildRequest = NULL;
            return;
        }
        if ((delta & 3) != 0 || delta < -(1LL << 27) ||
            delta >= (1LL << 27)) {
            MTLPatchLog("target adapter: wrapper out of BL range offset=%#lx site=%p target=%#lx delta=%#lx",
                        (unsigned long)profile->callSites[i].offset, callSite,
                        (unsigned long)target, (unsigned long)delta);
            OrigMTLCodeGenServiceBuildRequest = NULL;
            return;
        }
        branches[i] = 0x94000000u |
            ((uint32_t)((uint64_t)(delta >> 2) & 0x03ffffffu));
    }
    for (size_t i = 0; i < 3; i++) {
        uint32_t *callSite =
            (uint32_t *)((uintptr_t)mh + profile->callSites[i].offset);
        PatchInstruction(callSite, branches[i]);
        MTLPatchLog("target adapter installed offset=%#lx site=%p old=%#x new=%#x wrapper=%#lx orig=%p",
                    (unsigned long)profile->callSites[i].offset, callSite,
                    profile->callSites[i].expected, *callSite,
                    (unsigned long)target,
                    OrigMTLCodeGenServiceBuildRequest);
    }

    // Reply dumping is a bounded diagnostic witness, not runtime machinery.
    // Never patch the stock iOS reply path in production.
    if (MacWSCompilerDiagnosticsEnabled()) {
        uint32_t *replyDataSite =
            (uint32_t *)((uintptr_t)mh + profile->replyOffset);
        const uint32_t expectedReplyCall = profile->expectedReplyCall;
        uintptr_t replyTarget = StripPAC((const void *)MacWSCompilerReplyDataCreate);
        // Architectural stripping preserves the exact four-byte-aligned
        // entry; never compensate by searching neighboring instructions.
        const uint32_t kPacibsp = 0xd503237fu;
        intptr_t replyDelta = (intptr_t)replyTarget - (intptr_t)replyDataSite;
        if (*(const uint32_t *)replyTarget != kPacibsp ||
            *replyDataSite != expectedReplyCall || (replyDelta & 3) != 0 ||
            replyDelta < -(1LL << 27) || replyDelta >= (1LL << 27)) {
            MTLPatchLog("compiler reply observer validation failed site=%p insn=%#x target=%#lx targetInsn=%#x delta=%#lx",
                        replyDataSite, *replyDataSite,
                        (unsigned long)replyTarget,
                        *(const uint32_t *)replyTarget,
                        (unsigned long)replyDelta);
            return;
        }
        uint32_t replyBranch = 0x94000000u |
            ((uint32_t)((uint64_t)(replyDelta >> 2) & 0x03ffffffu));
        PatchInstruction(replyDataSite, replyBranch);
        MTLPatchLog("compiler reply observer installed site=%p old=%#x new=%#x wrapper=%#lx",
                    replyDataSite, expectedReplyCall, *replyDataSite,
                    (unsigned long)replyTarget);
    }
}

// All callers pass code symbols, including dlsym/MSFindSymbol results.
// Runtime MTLCompilerService-2026-09-19-052757.ips and arm64e disassembly
// prove the former integer mask became `and ..., #0x7ffffffffff8`, rounding
// wrapper entry 0x4724 down to the preceding __stack_chk_fail at 0x4720.
// XPACI preserves every address bit; it also removes PAC bit47 without
// depending on an assumed virtual-address width.
static uintptr_t StripPAC(const void *p) {
    return MacWSCodeAddress(p);
}

// Scan a window around (anchor + delta_hint) for the BL site preceded by
// `add x2, x2, #<imm12>` where the imm12 is the offset of the "agx."
// literal within its __cstring page. Two known imm12 values across the
// AGXCompilerCore variants we run against:
//   - iOS-16.3 DSC:        add x2, x2, #0x44e (encoding 0x91113842)
//   - macOS-13.4 chroot DSC: add x2, x2, #0xdf4 (encoding 0x9137d042)
// The MTLCompilerBypassOSCheck tweak runs in iOS-side MTLCompilerService
// only, so the iOS signature is what we actually need. But scanning for
// either makes the code robust if the DSC version shifts.
// Returns the BL site pointer or NULL if not found in the search window.
//
// `image_lo`/`image_hi` bound the scan to the AGXCompilerCore image —
// passing 0/0 lets the scan run unrestrained. We also wrap each
// dereference in a SIGBUS/SIGSEGV-tolerant sigsetjmp so an off-image
// probe just stops the scan instead of crashing the whole tweak.
#include <setjmp.h>
#include <signal.h>
static sigjmp_buf g_renamer_scan_jmp;
static volatile sig_atomic_t g_renamer_scan_in_probe = 0;
static void RenamerScanSignalHandler(int sig) {
    (void)sig;
    if (g_renamer_scan_in_probe) {
        siglongjmp(g_renamer_scan_jmp, 1);
    }
}
static uint32_t *FindRenamerBLSite(void *anchor_raw, intptr_t delta_hint,
                                   int window_bytes,
                                   uintptr_t image_lo, uintptr_t image_hi) {
    // `add x2, x2, #imm12` encoding with imm12 specific to each DSC variant.
    // iOS-16.3 sees the "agx." literal at __cstring offset 0x44e; macOS-13.4
    // chroot at 0xdf4. Match either so the patch is portable.
    const uint32_t SIG_ADD_X2_44E = 0x91113842u; // add x2, x2, #0x44e (iOS)
    const uint32_t SIG_ADD_X2_DF4 = 0x9137d042u; // add x2, x2, #0xdf4 (chroot)
    uintptr_t anchor = StripPAC(anchor_raw);
    uint32_t *base = (uint32_t *)(anchor + delta_hint);
    int max_words = window_bytes / 4;

    struct sigaction sa_old_segv, sa_old_bus, sa = {0};
    sa.sa_handler = RenamerScanSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, &sa_old_segv);
    sigaction(SIGBUS,  &sa, &sa_old_bus);

    uint32_t *found = NULL;
    for (int off = -max_words; off <= max_words; off++) {
        uint32_t *probe = base + off;
        if (image_hi && ((uintptr_t)probe < image_lo + 4 ||
                         (uintptr_t)probe >= image_hi)) continue;
        uint32_t prev_insn, cur_insn;
        if (sigsetjmp(g_renamer_scan_jmp, 1) != 0) continue;
        g_renamer_scan_in_probe = 1;
        prev_insn = probe[-1];
        cur_insn  = probe[0];
        g_renamer_scan_in_probe = 0;
        if ((prev_insn == SIG_ADD_X2_44E ||
             prev_insn == SIG_ADD_X2_DF4) &&
            ((cur_insn >> 26) & 0x3F) == 0x25) {
            found = probe;
            break;
        }
    }
    sigaction(SIGSEGV, &sa_old_segv, NULL);
    sigaction(SIGBUS,  &sa_old_bus,  NULL);
    return found;
}

// Walk dyld's image list to get the AGXCompilerCore binary's mapped
// __TEXT range. We use this to bound the scan so an off-end probe
// doesn't dereference unmapped memory.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
static void GetAGXCompilerCoreTextRange(uintptr_t *lo_out, uintptr_t *hi_out) {
    *lo_out = 0; *hi_out = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "AGXCompilerCore")) continue;
        const struct mach_header_64 *mh =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *lc =
            (const struct load_command *)((const char *)mh + sizeof(*mh));
        for (uint32_t j = 0; j < mh->ncmds; j++) {
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sc =
                    (const struct segment_command_64 *)lc;
                if (strncmp(sc->segname, "__TEXT", 16) == 0) {
                    *lo_out = (uintptr_t)sc->vmaddr + slide;
                    *hi_out = *lo_out + sc->vmsize;
                    return;
                }
            }
            lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
        }
    }
}

static void PatchAGXRenamerSkipAgxPrefix(void) {
    MTLPatchLog("renamer-patch: ENTER pid=%d", getpid());
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        MTLPatchLog("renamer-patch: dlopen FAILED: %s",
                    dlerror() ?: "(no dlerror)");
        return;
    }
    MTLPatchLog("renamer-patch: dlopen ok (h=%p)", h);
    MSImageRef img = MSGetImageByName(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore");
    if (!img) {
        MTLPatchLog("renamer-patch: MSGetImageByName returned NULL");
        return;
    }
    void *anchor = MSFindSymbol(img, "_AIRNTGetVersion");
    if (!anchor) {
        MTLPatchLog("renamer-patch: MSFindSymbol _AIRNTGetVersion NULL");
        return;
    }
    uintptr_t anchor_stripped = StripPAC(anchor);
    MTLPatchLog("renamer-patch: anchor _AIRNTGetVersion=%p (stripped=%#lx)",
                anchor, (long)anchor_stripped);

    uintptr_t image_lo = 0, image_hi = 0;
    GetAGXCompilerCoreTextRange(&image_lo, &image_hi);
    MTLPatchLog("renamer-patch: AGXCompilerCore __TEXT range %#lx-%#lx",
                (long)image_lo, (long)image_hi);

    // Known iOS-16.3 delta from prior RE. May be stale — the scan below
    // handles drift by walking +/-16KB around the hint for the
    // (ADD x2,x2,#0xdf4 ; BL) pair.
    intptr_t delta_hint = -0x1259a4;
    uint32_t *bl_site = FindRenamerBLSite(anchor, delta_hint,
                                          16 * 1024,
                                          image_lo, image_hi);
    if (!bl_site) {
        MTLPatchLog("renamer-patch: ADD+BL signature NOT found within "
                    "+/-16KB of anchor+delta_hint=%#lx — scanning whole "
                    "__text for fallback", (unsigned long)delta_hint);
        // Broader fallback: scan from the image base offset, bounded by
        // __TEXT range. AGXCompilerCore's __text is roughly 1.7MB.
        if (image_hi) {
            // window = entire __TEXT size, centred at anchor
            int win = (int)(image_hi - image_lo);
            bl_site = FindRenamerBLSite(anchor, 0, win,
                                        image_lo, image_hi);
        }
        if (!bl_site) {
            MTLPatchLog("renamer-patch: FAILED — no ADD+BL pair found "
                        "within AGXCompilerCore __TEXT");
            return;
        }
    }
    intptr_t actual_delta = (intptr_t)((uintptr_t)bl_site - anchor_stripped);
    uint32_t cur = bl_site[0];
    MTLPatchLog("renamer-patch: found BL site=%p actual_delta=%#lx insn=%#x",
                bl_site, (long)actual_delta, cur);
    PatchInstruction(bl_site, 0xd503201fu);  // NOP
    uint32_t after = bl_site[0];
    MTLPatchLog("renamer-patch: NOPed BL site=%p was=%#x now=%#x %s",
                bl_site, cur, after,
                after == 0xd503201fu ? "OK" : "FAIL");
}

static void PatchAGXVerifyLoweredIR(void) {
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        NSLog(@"#### MTLCompilerBypassOSCheck dlopen AGXCompilerCore: %s",
              dlerror());
        return;
    }
    MSImageRef img = MSGetImageByName(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore");
    if (!img) {
        NSLog(@"#### MTLCompilerBypassOSCheck AGXCompilerCore not in image table");
        return;
    }
    void *anchor = MSFindSymbol(img, "_AIRNTGetVersion");
    if (!anchor) {
        NSLog(@"#### MTLCompilerBypassOSCheck _AIRNTGetVersion not found");
        return;
    }
    // verifier = anchor + delta. Measured on iPad13,6 16.3.1 (20D67) DSC.
    intptr_t delta = -0x5fb78;
    uint32_t *verifier = (uint32_t *)((uintptr_t)anchor + delta);
    const uint32_t kPacibsp = 0xd503237fu;
    const uint32_t kRet     = 0xd65f03c0u;
    if (verifier[0] != kPacibsp) {
        NSLog(@"#### MTLCompilerBypassOSCheck verifier@%p first insn=%#x "
              "expected %#x — DSC version drift, NOT patching",
              verifier, verifier[0], kPacibsp);
        return;
    }
    PatchInstruction(verifier, kRet);
    NSLog(@"#### MTLCompilerBypassOSCheck verifyLoweredIR @%p patched "
          "pacibsp → ret (AGX shader verify now permissive)", verifier);
}

%ctor {
    // Load the exported build entry point used by the exact request adapter.
    // Do not alter MTLCompiler or AGXCompilerCore globally: this executable is
    // also the compiler service for Safari, WebKit, SpringBoard, and other
    // native iOS clients.
    dlopen("/System/Library/PrivateFrameworks/MTLCompiler.framework/MTLCompiler", RTLD_GLOBAL);
    InstallMacOSMetalTargetAdapter();

    // Originally tried: PatchAGXVerifyLoweredIR() — bypass the
    // AGCLLVMUserObject::verifyLoweredIR check that surfaces the
    // `agx.air.fract.v3f16.fast` unlowered-call error. That moved the
    // crash into libLLVM (NULL Function metadata at offset 0x30 in
    // codegen) — see commit message. Kept for reference only.
    (void)PatchAGXVerifyLoweredIR;
    // Legacy diagnostics retained for explicit RE work only.  The former
    // production path NOPed MTLCompiler's OS rejection branch and the
    // AGXCompilerCore `agx.` renamer for every service instance.  Runtime
    // evidence on 2026-08-01 showed stock com.apple.WebKit.GPU repeatedly
    // aborting in QuartzCore pipeline compilation while those global patches
    // were active, then remaining stable after the tweak was disabled.  A
    // system compiler service must never be made permissive for unrelated iOS
    // clients, so neither bypass is installed here.
    (void)PatchAGXRenamerSkipAgxPrefix;
    if (MacWSCompilerHoldEnabled()) {
        MTLPatchLog("diagnostic hold: SIGSTOP before accepting compiler requests");
        raise(SIGSTOP);
    }
}
