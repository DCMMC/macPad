@import Darwin;
@import CydiaSubstrate;
@import Foundation;
@import MachO;

#include <dlfcn.h>
#include <errno.h>
#include <crt_externs.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <spawn.h>

// Valve's tier0 helper launcher has this exported ABI on Steam client build
// 1785799196 (arm64). RE-confirmed in libtier0_s.dylib at +0xd91c:
//
//   x0 command/argv, x1 flags, x2 cwd
//   bit 1: setpgrp, then setsid (the latter necessarily fails after the child
//          became a process-group leader, so the effective contract is a new
//          process group in the parent's existing session)
//   bit 2: shell command, bit 3: execv argv, bit 4: execvp argv
//
// Steam's webhelper call site in chromehtml.dylib at +0x71da0 passes 0x0a,
// so the child contract is argv + new session. The original implementation
// uses fork() first. On iPadOS 16.3 the child then crashes before exec inside
// Network.framework's nw_settings_child_has_forked atfork handler, jumping to
// the read-only xpc_dictionary_apply data page (runtime crash witness:
// steam_osx-2026-08-13-064756.ips).
//
// Reproduce the process contract atomically with posix_spawn. This avoids
// inheriting initialized Network/XPC state; it does not skip an atfork handler
// or claim that a failed child launch succeeded.
typedef int (*MacWSCreateSimpleProcessV3Function)(
    void *, int, const char *);
typedef int (*MacWSCreateSimpleProcessV4Function)(
    void *, int, char *const *, const char *);
typedef enum {
    MacWSSteamCreateSimpleProcessUnsupported = 0,
    MacWSSteamCreateSimpleProcessV3 = 3,
    MacWSSteamCreateSimpleProcessV4 = 4,
} MacWSSteamCreateSimpleProcessABI;
static void *gMacWSOriginalCreateSimpleProcess;
static MacWSSteamCreateSimpleProcessABI gMacWSCreateSimpleProcessABI;
static int MacWSSteamCreateSimpleProcessV3Adapter(
    void *commandOrArguments, int flags, const char *workingDirectory);
static int MacWSSteamCreateSimpleProcessV4Adapter(
    void *commandOrArguments, int flags, char *const *environment,
    const char *workingDirectory);
static bool MacWSPathEndsWith(const char *path, const char *suffix);
static bool MacWSIsTopLevelSteamBrowser(void);
static void MacWSInstallSteamApplicationLaunchCompatibility(void);
static pid_t MacWSSteamForkFromCallSite(
    const uint8_t *callerStack, const void *steamEngine,
    uint64_t manuallyClearFrames, pid_t steamPID, pid_t gamePID,
    const void *returnAddress);
extern kern_return_t bootstrap_check_in_new(
    mach_port_t bootstrapPort, const char *serviceName,
    mach_port_t *servicePort);
extern kern_return_t bootstrap_look_up_new(
    mach_port_t bootstrapPort, const char *serviceName,
    mach_port_t *servicePort);
extern void ModifyExecutableRegion(void *address, size_t size,
                                   void (^callback)(void));

// Steam client 1785799196's overlay launcher is a direct fork followed by
// substantial C++ argv/environment construction in the child. On this exact
// iPadOS 16.3 runtime the child never returns from fork: Network.framework's
// nw_settings_child_has_forked atfork handler faults in xpc_dictionary_apply.
// Runtime witness (2026-08-18 21:12):
//
//   SIGBUS/BUS_ADRALN pc=xpc_dictionary_apply
//   -[OS_nw_dictionary dealloc]
//   nw_path_release_globals
//   nw_settings_child_has_forked
//   _pthread_atfork_child_handlers
//   fork
//
// Keep the replacement narrower than a process-wide fork policy. The import
// gateway below sees the original caller stack/registers before a compiler
// prologue, and the C helper recognizes only steamclient.dylib+0xacc718 (the
// instruction after CheckForOverlayInstancesNeeded's fork). Every other fork
// still calls libSystem unchanged.
__attribute__((naked, used)) static pid_t MacWSSteamForkGateway(void) {
#if defined(__arm64__)
    __asm__ volatile(
        "mov x5, x30\n"
        "mov x4, x25\n"
        "mov x3, x24\n"
        "mov x2, x21\n"
        "mov x1, x19\n"
        "mov x0, sp\n"
        "b _MacWSSteamForkFromCallSite\n");
#else
    __asm__ volatile("brk #0x1\n");
#endif
}

static bool MacWSHeaderHasUUID(const struct mach_header_64 *header,
                               const uint8_t expected[16]) {
    if (!header || header->magic != MH_MAGIC_64) return false;
    const struct load_command *command =
        (const struct load_command *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (command->cmd == LC_UUID) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            return memcmp(uuid->uuid, expected, 16) == 0;
        }
        command = (const struct load_command *)
            ((const uint8_t *)command + command->cmdsize);
    }
    return false;
}

typedef struct {
    char **items;
    char *insertEntry;
    char *gamePidsEntry;
} MacWSOverlayEnvironment;

static MacWSOverlayEnvironment MacWSCopyOverlayEnvironment(
    const char *gamePids) {
    MacWSOverlayEnvironment result = {0};
    char ***environmentPointer = _NSGetEnviron();
    char **source = environmentPointer ? *environmentPointer : NULL;
    size_t count = 0;
    while (source && source[count]) count++;
    result.items = calloc(count + 3, sizeof(char *));
    if (!result.items) return result;
    if (asprintf(&result.insertEntry,
                 "DYLD_INSERT_LIBRARIES=/usr/local/lib/"
                 "libmachook_arm64.dylib") < 0 ||
        asprintf(&result.gamePidsEntry, "STEAM_GAME_PIDS=%s",
                 gamePids ? gamePids : "") < 0) {
        free(result.insertEntry);
        free(result.gamePidsEntry);
        free(result.items);
        return (MacWSOverlayEnvironment){0};
    }
    size_t output = 0;
    for (size_t index = 0; source && source[index]; index++) {
        if (!strncmp(source[index], "DYLD_INSERT_LIBRARIES=", 22) ||
            !strncmp(source[index], "STEAM_GAME_PIDS=", 16)) continue;
        result.items[output++] = source[index];
    }
    result.items[output++] = result.insertEntry;
    result.items[output++] = result.gamePidsEntry;
    result.items[output] = NULL;
    return result;
}

static void MacWSFreeOverlayEnvironment(MacWSOverlayEnvironment *environment) {
    if (!environment) return;
    free(environment->insertEntry);
    free(environment->gamePidsEntry);
    free(environment->items);
    *environment = (MacWSOverlayEnvironment){0};
}

static pid_t MacWSSteamSpawnProcessWorkItem(const uint8_t *callerStack,
                                            const uint8_t *workItem) {
    // RE-confirmed in steamui 1785799196, UUID
    // 1372EF86-CC8D-36FF-BBCC-2AE86F8E24F3:
    //
    //   +0xaedc90..+0xaede88 builds argv {/bin/sh, -c, command, NULL}
    //   +0xaedc58..+0xaedc68 flattens the environment into SP+0xd0
    //   +0xaee178 calls fork
    //   +0xaee6c0..+0xaee7b8 performs dup2/chdir/execvp in the child
    //
    // Re-express that same launch contract through posix_spawn so the child
    // never inherits Network.framework's incompatible atfork handlers.
    char *const *preparedArguments =
        *(char *const *const *)(callerStack + 0x88);
    char *const *preparedEnvironment =
        *(char *const *const *)(callerStack + 0xd0);
    int32_t environmentCount =
        *(const int32_t *)(callerStack + 0xe0);
    if (!preparedArguments || !preparedArguments[0] ||
        !preparedArguments[1] || !preparedArguments[2] ||
        environmentCount < 0 || environmentCount > 4096 ||
        (environmentCount && !preparedEnvironment)) {
        errno = EINVAL;
        return -1;
    }
    const char *command = preparedArguments[2];
    bool strayLaunch = strstr(command, "/steamapps/common/Stray/") ||
        strstr(command, "/steamapps/macws-runtime/Stray/");
    if (!strayLaunch) {
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
            fprintf(stderr,
                    "[MacWSSteamProcess] workitem-fork-passthrough "
                    "command=%s\n", command);
            fflush(stderr);
        }
        return fork();
    }
    char *arguments[] = {
        preparedArguments[0], preparedArguments[1], preparedArguments[2],
        NULL,
    };
    char **environment = calloc((size_t)environmentCount + 1,
                                sizeof(*environment));
    if (!environment) {
        errno = ENOMEM;
        return -1;
    }
    for (int32_t index = 0; index < environmentCount; index++)
        environment[index] = preparedEnvironment[index];

    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    bool actionsInitialized = result == 0;
    static const size_t descriptorOffsets[] = {0x148, 0x154, 0x15c};
    for (int target = 0; result == 0 && target < 3; target++) {
        int descriptor = *(const int *)(workItem + descriptorOffsets[target]);
        if (descriptor != -1)
            result = posix_spawn_file_actions_adddup2(
                &actions, descriptor, target);
    }
    const char *workingDirectory =
        *(const char *const *)(workItem + 0x200);
    if (result == 0 && workingDirectory && *workingDirectory) {
        typedef int (*MacWSAddChdirActionFunction)(
            posix_spawn_file_actions_t *, const char *);
        MacWSAddChdirActionFunction addChdir =
            (MacWSAddChdirActionFunction)dlsym(
                RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
        result = addChdir ? addChdir(&actions, workingDirectory) : ENOSYS;
    }
    pid_t child = -1;
    if (result == 0)
        result = posix_spawn(&child, arguments[0], &actions, NULL, arguments,
                             environment);
    if (actionsInitialized) posix_spawn_file_actions_destroy(&actions);
    free(environment);
    if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
        fprintf(stderr,
                "[MacWSSteamProcess] workitem-posix-spawn executable=%s "
                "command=%s child=%d result=%d envc=%d cwd=%s\n",
                arguments[0], command, child, result, environmentCount,
                workingDirectory ? workingDirectory : "");
        fflush(stderr);
    }
    if (result != 0) {
        errno = result;
        return -1;
    }
    return child;
}

__attribute__((noinline, used)) static pid_t MacWSSteamForkFromCallSite(
    const uint8_t *callerStack, const void *steamEngine,
    uint64_t manuallyClearFrames, pid_t steamPID, pid_t gamePID,
    const void *returnAddress) {
    Dl_info caller = {0};
    if (!returnAddress || !dladdr(returnAddress, &caller) ||
        !caller.dli_fname || !caller.dli_fbase) {
        return fork();
    }
    uintptr_t callerOffset =
        (uintptr_t)returnAddress - (uintptr_t)caller.dli_fbase;
    if (MacWSPathEndsWith(caller.dli_fname, "/steamui.dylib") &&
        callerOffset == 0xaee17c) {
        return MacWSSteamSpawnProcessWorkItem(
            callerStack, (const uint8_t *)steamEngine);
    }
    if (!MacWSPathEndsWith(caller.dli_fname, "/steamclient.dylib") ||
        callerOffset != 0xacc718) return fork();

    // RE-confirmed at steamclient.dylib+0xacc6d0: this CUtlString keeps a
    // short STEAM_GAME_PIDS value inline at caller SP+0xc8, and a long value
    // behind the pointer at that address. A tag of 0x17 is the empty value.
    const char *gamePids = "";
    int8_t pidsTag = *(const int8_t *)(callerStack + 0xdf);
    if (pidsTag < 0) {
        if (*(const uint32_t *)(callerStack + 0xd0))
            gamePids = *(const char *const *)(callerStack + 0xc8);
    } else if ((uint8_t)pidsTag != 0x17) {
        gamePids = (const char *)(callerStack + 0xc8);
    }

    const char *workingDirectory = steamEngine ?
        *(const char *const *)((const uint8_t *)steamEngine + 0x1a08) : NULL;
    if (!workingDirectory || !*workingDirectory) {
        errno = ENOENT;
        return -1;
    }
    char executable[PATH_MAX];
    if (snprintf(executable, sizeof(executable), "%s/gameoverlayui",
                 workingDirectory) >= (int)sizeof(executable)) {
        errno = ENAMETOOLONG;
        return -1;
    }

    char steamPIDText[24], gamePIDText[24], clearFramesText[24], gameIDText[32];
    snprintf(steamPIDText, sizeof(steamPIDText), "%d", steamPID);
    snprintf(gamePIDText, sizeof(gamePIDText), "%d", gamePID);
    snprintf(clearFramesText, sizeof(clearFramesText), "%llu",
             (unsigned long long)manuallyClearFrames);
    uint64_t gameID = *(const uint64_t *)(callerStack + 0x50);
    snprintf(gameIDText, sizeof(gameIDText), "%llu",
             (unsigned long long)gameID);
    char *arguments[] = {
        executable,
        (char *)"-pid", gamePIDText,
        (char *)"-steampid", steamPIDText,
        (char *)"-manuallyclearframes", clearFramesText,
        (char *)"-gameid", gameIDText,
        NULL,
    };

    MacWSOverlayEnvironment environment =
        MacWSCopyOverlayEnvironment(gamePids);
    if (!environment.items) {
        errno = ENOMEM;
        return -1;
    }
    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    bool actionsInitialized = result == 0;
    if (actionsInitialized) {
        typedef int (*MacWSAddChdirActionFunction)(
            posix_spawn_file_actions_t *, const char *);
        MacWSAddChdirActionFunction addChdir =
            (MacWSAddChdirActionFunction)dlsym(
                RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
        result = addChdir ? addChdir(&actions, workingDirectory) : ENOSYS;
    }
    pid_t child = -1;
    if (result == 0)
        result = posix_spawn(&child, executable, &actions, NULL, arguments,
                             environment.items);
    if (actionsInitialized) posix_spawn_file_actions_destroy(&actions);
    MacWSFreeOverlayEnvironment(&environment);
    if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
        fprintf(stderr,
                "[MacWSSteamProcess] overlay-posix-spawn path=%s child=%d "
                "result=%d steam=%d game=%d clear=%llu gameid=%llu "
                "pids=%s\n",
                executable, child, result, steamPID, gamePID,
                (unsigned long long)manuallyClearFrames,
                (unsigned long long)gameID, gamePids ? gamePids : "");
        fflush(stderr);
    }
    if (result != 0) {
        errno = result;
        return -1;
    }
    return child;
}

static void MacWSRebindSteamProcessImport(const struct mach_header *header,
                                           intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) return;
    Dl_info imageInfo = {0};
    if (!dladdr(header, &imageInfo) || !imageInfo.dli_fname) return;
    if (strstr(imageInfo.dli_fname, "/libmachook") ||
        strstr(imageInfo.dli_fname, "/libtier0_s.dylib")) return;
    bool chromiumFramework = strstr(
        imageInfo.dli_fname,
        "/Chromium Embedded Framework.framework/") != NULL;
    static const uint8_t steamClient1785799196UUID[16] = {
        0x2f, 0x00, 0x8d, 0x6b, 0xe4, 0xc2, 0x34, 0xbf,
        0x96, 0x59, 0x24, 0xc7, 0x3e, 0xca, 0x26, 0xa5,
    };
    bool exactSteamClient = MacWSPathEndsWith(
            imageInfo.dli_fname, "/steamclient.dylib") &&
        MacWSHeaderHasUUID((const struct mach_header_64 *)header,
                           steamClient1785799196UUID);
    static const uint8_t steamUI1785799196UUID[16] = {
        0x13, 0x72, 0xef, 0x86, 0xcc, 0x8d, 0x36, 0xff,
        0xbb, 0xcc, 0x2a, 0xe8, 0x6f, 0x8e, 0x24, 0xf3,
    };
    bool exactSteamUI = MacWSPathEndsWith(
            imageInfo.dli_fname, "/steamui.dylib") &&
        MacWSHeaderHasUUID((const struct mach_header_64 *)header,
                           steamUI1785799196UUID);

    const struct mach_header_64 *header64 =
        (const struct mach_header_64 *)header;
    const struct load_command *command =
        (const struct load_command *)(header64 + 1);
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symbols = NULL;
    const struct dysymtab_command *dynamicSymbols = NULL;
    for (uint32_t index = 0; index < header64->ncmds; index++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if (!strcmp(segment->segname, SEG_LINKEDIT)) linkedit = segment;
        } else if (command->cmd == LC_SYMTAB) {
            symbols = (const struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dynamicSymbols = (const struct dysymtab_command *)command;
        }
        command = (const struct load_command *)
            ((const uint8_t *)command + command->cmdsize);
    }
    if (!linkedit || !symbols || !dynamicSymbols) return;

    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr -
        linkedit->fileoff;
    const struct nlist_64 *symbolTable =
        (const struct nlist_64 *)(linkeditBase + symbols->symoff);
    const char *stringTable =
        (const char *)(linkeditBase + symbols->stroff);
    const uint32_t *indirectTable =
        (const uint32_t *)(linkeditBase + dynamicSymbols->indirectsymoff);

    command = (const struct load_command *)(header64 + 1);
    for (uint32_t commandIndex = 0;
         commandIndex < header64->ncmds; commandIndex++) {
        if (command->cmd != LC_SEGMENT_64) {
            command = (const struct load_command *)
                ((const uint8_t *)command + command->cmdsize);
            continue;
        }
        const struct segment_command_64 *segment =
            (const struct segment_command_64 *)command;
        const struct section_64 *section =
            (const struct section_64 *)(segment + 1);
        for (uint32_t sectionIndex = 0;
             sectionIndex < segment->nsects; sectionIndex++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS &&
                type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            uintptr_t *pointers = (uintptr_t *)
                ((uintptr_t)slide + section->addr);
            size_t count = (size_t)(section->size / sizeof(uintptr_t));
            for (size_t pointerIndex = 0;
                 pointerIndex < count; pointerIndex++) {
                uint32_t indirectIndex = section->reserved1 + pointerIndex;
                if (indirectIndex >= dynamicSymbols->nindirectsyms) break;
                uint32_t symbolIndex =
                    indirectTable[indirectIndex];
                if (symbolIndex == INDIRECT_SYMBOL_ABS ||
                    symbolIndex == INDIRECT_SYMBOL_LOCAL ||
                    symbolIndex == (INDIRECT_SYMBOL_LOCAL |
                                    INDIRECT_SYMBOL_ABS) ||
                    symbolIndex >= symbols->nsyms) continue;
                const char *name = stringTable +
                    symbolTable[symbolIndex].n_un.n_strx;
                if (!name) continue;
                uintptr_t replacement = 0;
                bool directLazyWrite = false;
                if (!strcmp(name, "_CreateSimpleProcess")) {
                    // Never publish the Valve adapter until its fallback
                    // target is known. dyld can notify us about steamui before
                    // libtier0; any unsupported call in that interval must
                    // retain Valve's implementation.
                    if (!gMacWSOriginalCreateSimpleProcess) continue;
                    if (gMacWSCreateSimpleProcessABI ==
                            MacWSSteamCreateSimpleProcessV3) {
                        replacement = (uintptr_t)
                            MacWSSteamCreateSimpleProcessV3Adapter;
                    } else if (gMacWSCreateSimpleProcessABI ==
                                   MacWSSteamCreateSimpleProcessV4) {
                        replacement = (uintptr_t)
                            MacWSSteamCreateSimpleProcessV4Adapter;
                    } else {
                        // An updater changed a private Valve ABI. Leave its
                        // original import intact until that exact image has
                        // been disassembled and admitted above.
                        continue;
                    }
                } else if ((exactSteamClient || exactSteamUI) &&
                           type == S_LAZY_SYMBOL_POINTERS &&
                           !strcmp(name, "_fork")) {
                    replacement = (uintptr_t)MacWSSteamForkGateway;
                    directLazyWrite = true;
                } else if (chromiumFramework &&
                           type == S_LAZY_SYMBOL_POINTERS &&
                           !strcmp(name, "_bootstrap_check_in")) {
                    replacement = (uintptr_t)bootstrap_check_in_new;
                    directLazyWrite = true;
                } else if (chromiumFramework &&
                           type == S_LAZY_SYMBOL_POINTERS &&
                           !strcmp(name, "_bootstrap_look_up")) {
                    replacement = (uintptr_t)bootstrap_look_up_new;
                    directLazyWrite = true;
                } else {
                    continue;
                }
                uintptr_t previous = __atomic_load_n(
                    &pointers[pointerIndex], __ATOMIC_ACQUIRE);
                if (directLazyWrite) {
                    // __DATA,__la_symbol_ptr is writable in this exact CEF
                    // image. A direct atomic store is the fishhook contract:
                    // the existing stub now branches to our wrapper and never
                    // enters dyld_stub_binder, so no later lazy bind can
                    // replace it. MSHookMemory is for executable/const pages
                    // and did not provide a verifiable data-slot write here.
                    __atomic_store_n(&pointers[pointerIndex], replacement,
                                     __ATOMIC_RELEASE);
                } else {
                    // This slot may live in __DATA_CONST. Do not use
                    // MSHookMemory here: runtime-confirmed in Steam Helper
                    // PID 90074 that ElleKit's stopAllThreads suspended all
                    // 32 peer threads while rebinding steamclient.dylib and
                    // returned without balancing them. The project's writer
                    // preserves the actual region permissions and tracks each
                    // successful peer suspension through its matching resume.
                    ModifyExecutableRegion(&pointers[pointerIndex],
                                           sizeof(replacement), ^{
                        __atomic_store_n(&pointers[pointerIndex], replacement,
                                         __ATOMIC_RELEASE);
                    });
                }
                uintptr_t readback = __atomic_load_n(
                    &pointers[pointerIndex], __ATOMIC_ACQUIRE);
                if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
                    fprintf(stderr,
                            "[MacWSSteamProcess] rebound import image=%s "
                            "symbol=%s slot=%p previous=%p replacement=%p "
                            "readback=%p%s\n",
                            imageInfo.dli_fname, name,
                            &pointers[pointerIndex], (void *)previous,
                            (void *)replacement, (void *)readback,
                            readback == replacement ? "" : " WRITE-FAILED");
                    fflush(stderr);
                }
            }
        }
        command = (const struct load_command *)
            ((const uint8_t *)command + command->cmdsize);
    }
}

static bool MacWSIsSteamProcess(void) {
    const char *program = getprogname();
    if (program && (!strcmp(program, "steam_osx") ||
                    !strcmp(program, "Steam Helper"))) return true;
    char executable[PATH_MAX] = {0};
    extern int proc_pidpath(int, void *, uint32_t);
    return proc_pidpath(getpid(), executable, sizeof(executable)) > 0 &&
        strstr(executable, "/Library/Application Support/Steam/") != NULL;
}

static bool MacWSIsTopLevelSteamBrowser(void) {
    const char *program = getprogname();
    if (!program || strcmp(program, "Steam Helper") != 0) return false;
    char ***argumentsPointer = _NSGetArgv();
    char **arguments = argumentsPointer ? *argumentsPointer : NULL;
    for (size_t index = 1; arguments && arguments[index]; index++) {
        if (!strncmp(arguments[index], "--type=", 7)) return false;
    }
    return true;
}

// Steam's native macOS game path deliberately uses NSWorkspace instead of
// Valve's _CreateSimpleProcess adapter. Runtime-confirmed with client
// 1785799196: Stray reaches CreatingProcess with its .app URL, while no
// _CreateSimpleProcess entry is recorded.
//
// There are two incompatible integrity owners on iPadOS. Steam must keep the
// depot copy byte-for-byte vendor signed or its content verifier reports a
// corrupt file signature. The iPadOS exec policy rejects that same macOS
// Developer-ID main executable even after its original CDHash is placed in the
// jailbreak trustcache. Runtime oslog witness for the untouched Stray binary:
//
//   System Policy: bash(...) deny(1) process-exec* .../Stray-Mac-Shipping
//   process-exec denied while updating label
//   killing com.annapurnainteractive.Stray ... failed to apply exec policy
//
// The root-layer compatibility is a separately prepared APFS-cloned runtime
// app below steamapps/macws-runtime. Its code files carry the MacWS signing
// profile while its large resources share storage with the depot copy. Steam
// continues to verify only steamapps/common. Preserve NSWorkspace as launch
// owner: first let it attempt the exact vendor bundle, then retry the prepared
// runtime bundle with the same options/arguments/environment. posix_spawn is a
// final fallback only if both stock NSWorkspace attempts fail.
typedef id (*MacWSNSWorkspaceLaunchFunction)(
    id, SEL, NSURL *, NSUInteger, NSDictionary *, NSError **);
static MacWSNSWorkspaceLaunchFunction
    gMacWSOriginalNSWorkspaceLaunchApplication;
static MacWSNSWorkspaceLaunchFunction gMacWSOriginalNSWorkspaceOpenURL;
typedef id (*MacWSNSWorkspaceOpenURLsFunction)(
    id, SEL, NSArray *, NSURL *, NSUInteger, NSDictionary *, NSError **);
static MacWSNSWorkspaceOpenURLsFunction gMacWSOriginalNSWorkspaceOpenURLs;

static NSURL *MacWSSteamRuntimeApplicationURL(NSString *applicationPath) {
    static NSString *const steamAppsPrefix =
        @"/Users/root/Library/Application Support/Steam/steamapps/common/";
    static NSString *const runtimePrefix =
        @"/Users/root/Library/Application Support/Steam/steamapps/macws-runtime/";
    if (![applicationPath hasPrefix:steamAppsPrefix] ||
        ![applicationPath hasSuffix:@".app"]) return nil;

    NSString *relative = [applicationPath substringFromIndex:
        steamAppsPrefix.length];
    if (!relative.length || [relative hasPrefix:@"/"] ||
        [[relative pathComponents] containsObject:@".."]) return nil;

    // RE-confirmed from the installed Steam app 251570 depot on iPad14,5:
    // both 7dLauncher.app/Contents/MacOS/7dLauncher and the vendor
    // 7DaysToDie.app Unity player are x86_64-only.  The separately prepared
    // 2022.3.62f2 runtime bundle carries the arm64 Unity player while its Data,
    // Resources, Mono and plug-in paths resolve back to the untouched depot.
    // Preserve Steam/NSWorkspace as launch owner, but select that real arm64
    // bundle instead of asking iPadOS to execute either unsupported x86_64
    // entry point.  The ready marker and Info.plist checks below remain the
    // authority for whether the runtime was actually prepared.
    if ([relative isEqualToString:@"7 Days To Die/7dLauncher.app"] ||
        [relative isEqualToString:@"7 Days To Die/7DaysToDie.app"]) {
        relative = @"7 Days To Die/7DaysToDie-ARM.app";
    }
    NSString *runtimePath = [runtimePrefix stringByAppendingPathComponent:
        relative];
    NSString *readyMarker = [[runtimePath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@".macws-shadow-ready"];
    NSString *infoPath = [runtimePath stringByAppendingPathComponent:
        @"Contents/Info.plist"];
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:readyMarker] ||
        ![files fileExistsAtPath:infoPath]) return nil;

    // Stray's UE4 PhysX loader asks for libAPEXFramework.dylib, while the
    // vendor bundle spells the file libApexFramework.dylib.  That is the same
    // file on a stock case-insensitive macOS APFS volume, but not on the
    // case-sensitive chroot rootfs.  Keep Steam's verified depot untouched and
    // reproduce the normal macOS lookup contract in the writable runtime
    // shadow with a relative alias.
    NSString *physXDirectory = [runtimePath stringByAppendingPathComponent:
        @"Contents/UE4/Engine/Binaries/ThirdParty/PhysX3/Mac"];
    NSString *physXTarget = [physXDirectory stringByAppendingPathComponent:
        @"libApexFramework.dylib"];
    NSString *physXAlias = [physXDirectory stringByAppendingPathComponent:
        @"libAPEXFramework.dylib"];
    if ([files fileExistsAtPath:physXTarget] &&
        ![files fileExistsAtPath:physXAlias]) {
        NSError *aliasError = nil;
        [files createSymbolicLinkAtPath:physXAlias
                   withDestinationPath:@"libApexFramework.dylib"
                                  error:&aliasError];
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
            fprintf(stderr,
                    "[MacWSSteamProcess] PhysX case alias path=%s result=%s "
                    "error=%s\n",
                    physXAlias.UTF8String ?: "(null)",
                    [files fileExistsAtPath:physXAlias] ? "ready" : "failed",
                    aliasError.localizedDescription.UTF8String ?: "(none)");
            fflush(stderr);
        }
    }
    return [NSURL fileURLWithPath:runtimePath isDirectory:YES];
}

static bool MacWSIsSevenDaysToDieARMRuntimeExecutable(
        NSString *executablePath) {
    if (![executablePath.lastPathComponent
            isEqualToString:@"7 Days To Die"]) return false;
    return [executablePath containsString:
        @"/steamapps/macws-runtime/7 Days To Die/"
         "7DaysToDie-ARM.app/Contents/MacOS/"];
}

static id MacWSExistingSevenDaysRuntimeApplication(
        NSURL *runtimeApplicationURL, NSString *executablePath) {
    if (!runtimeApplicationURL ||
        !MacWSIsSevenDaysToDieARMRuntimeExecutable(executablePath)) return nil;

    NSBundle *bundle = [NSBundle bundleWithURL:runtimeApplicationURL];
    NSString *bundleIdentifier = bundle.bundleIdentifier;
    Class runningApplicationClass = NSClassFromString(@"NSRunningApplication");
    SEL applicationsSelector = NSSelectorFromString(
        @"runningApplicationsWithBundleIdentifier:");
    if (!bundleIdentifier.length ||
        ![runningApplicationClass respondsToSelector:applicationsSelector]) {
        return nil;
    }

    NSArray *applications = ((id (*)(id, SEL, id))objc_msgSend)(
        runningApplicationClass, applicationsSelector, bundleIdentifier);
    SEL processSelector = NSSelectorFromString(@"processIdentifier");
    SEL terminatedSelector = NSSelectorFromString(@"isTerminated");
    SEL executableURLSelector = NSSelectorFromString(@"executableURL");
    for (id application in applications) {
        if (![application respondsToSelector:processSelector] ||
            ![application respondsToSelector:executableURLSelector]) continue;
        if ([application respondsToSelector:terminatedSelector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(
                application, terminatedSelector)) continue;
        pid_t processIdentifier = ((pid_t (*)(id, SEL))objc_msgSend)(
            application, processSelector);
        NSURL *candidateExecutableURL = ((id (*)(id, SEL))objc_msgSend)(
            application, executableURLSelector);
        if (processIdentifier <= 1 ||
            ![candidateExecutableURL.path isEqualToString:executablePath]) {
            continue;
        }
        if (kill(processIdentifier, 0) != 0 && errno == ESRCH) continue;
        return application;
    }
    return nil;
}

static NSString *MacWSInsertLibraryForSteamExecutable(
        NSString *executablePath) {
    // Steam's LaunchServices configuration does not retain dyld's insertion
    // variable.  Runtime LLDB on Stray PID 82012 showed the child stopped in
    // libSystem_initializer -> os_variant_has_internal_diagnostics while
    // `image list libmachook*.dylib` returned no modules.  Select the same
    // thin runtime slice as launchdchrootexec from the executable's actual
    // Mach-O subtype.  A universal Steam title executes its arm64 slice on
    // this device, so the non-thin/default result is arm64 rather than arm64e.
    NSString *insert = @"/usr/local/lib/libmachook_arm64.dylib";
    int descriptor = open(executablePath.fileSystemRepresentation, O_RDONLY);
    if (descriptor < 0) return insert;
    struct mach_header_64 header = {};
    ssize_t readCount = pread(descriptor, &header, sizeof(header), 0);
    close(descriptor);
    if (readCount == sizeof(header) && header.magic == MH_MAGIC_64 &&
        header.cputype == CPU_TYPE_ARM64 &&
        (header.cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E) {
        insert = @"/usr/local/lib/libmachook.dylib";
    }
    return insert;
}

static NSString *MacWSStrayRHIThreadSelector(
        NSDictionary *configuration, NSString *executablePath) {
    if (![executablePath containsString:@"/steamapps/macws-runtime/Stray/"] ||
        ![executablePath.lastPathComponent
            isEqualToString:@"Stray-Mac-Shipping"]) return nil;
    NSDictionary *configured = [configuration objectForKey:
        @"NSWorkspaceLaunchConfigurationEnvironment"];
    NSString *selector = [configured isKindOfClass:[NSDictionary class]]
        ? configured[@"MACWS_STRAY_RHI_THREAD_SELECTOR"] : nil;
    if (![selector isKindOfClass:[NSString class]]) {
        selector = [[[NSProcessInfo processInfo] environment]
            objectForKey:@"MACWS_STRAY_RHI_THREAD_SELECTOR"];
    }
    if ([selector isEqualToString:@"on"] ||
        [selector isEqualToString:@"off"]) return selector;
    return nil;
}

static NSArray *MacWSArgumentsForWorkspaceConfiguration(
        NSDictionary *configuration, NSString *executablePath) {
    NSArray *configured = [configuration objectForKey:
        @"NSWorkspaceLaunchConfigurationArguments"];
    if (![configured isKindOfClass:[NSArray class]]) configured = @[];
    NSString *selector = MacWSStrayRHIThreadSelector(
        configuration, executablePath);
    if (!selector) return configured;

    NSMutableArray *arguments = [NSMutableArray arrayWithCapacity:
        configured.count + 1];
    for (id value in configured) {
        if ([value isKindOfClass:[NSString class]] &&
            ([(NSString *)value caseInsensitiveCompare:@"-rhithread"] ==
                 NSOrderedSame ||
             [(NSString *)value caseInsensitiveCompare:@"-norhithread"] ==
                 NSOrderedSame)) continue;
        [arguments addObject:value];
    }
    NSString *argument = [selector isEqualToString:@"off"]
        ? @"-norhithread" : @"-rhithread";
    [arguments addObject:argument];
    fprintf(stderr,
            "[MacWSSteamProcess] Stray RHI thread A/B selector=%s "
            "argument=%s\n",
            selector.UTF8String, argument.UTF8String);
    fflush(stderr);
    return arguments;
}

static NSMutableDictionary *MacWSMergedEnvironmentForWorkspaceConfiguration(
        NSDictionary *configuration, NSString *executablePath) {
    NSDictionary *configured = [configuration objectForKey:
        @"NSWorkspaceLaunchConfigurationEnvironment"];
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:
        [[NSProcessInfo processInfo] environment]];
    if ([configured isKindOfClass:[NSDictionary class]])
        [merged addEntriesFromDictionary:configured];
    if (executablePath.length) {
        NSString *macwsInsert =
            MacWSInsertLibraryForSteamExecutable(executablePath);
        NSMutableArray<NSString *> *insertLibraries =
            [NSMutableArray arrayWithObject:macwsInsert];
        NSString *steamInsert = merged[@"STEAM_DYLD_INSERT_LIBRARIES"];
        BOOL steamRuntime = [executablePath
            containsString:@"/steamapps/macws-runtime/"];
        BOOL strayOverlayInjectionDiagnostic =
            steamRuntime &&
            [executablePath.lastPathComponent
                isEqualToString:@"Stray-Mac-Shipping"] &&
            access("/tmp/macws_stray_no_overlay_injection", F_OK) == 0;
        // Steam's real launch configuration carries its requested loader and
        // overlay images in STEAM_DYLD_INSERT_LIBRARIES.  The NSWorkspace
        // fallback used on this host previously replaced DYLD_INSERT_LIBRARIES
        // with libmachook alone.  Runtime confirmation from Stray PID 7451:
        // STEAM_DYLD named steamloader + gameoverlayrenderer, while `vmmap`
        // contained neither image and SteamAPI_Init could not find Steam.
        //
        // iPadOS dyld rejects a universal image in DYLD_INSERT_LIBRARIES, so
        // ensure_steam_trust.sh publishes signed/trusted arm64 slices at these
        // stable paths.  Preserve Steam's own request rather than enabling the
        // overlay for launches where Steam did not ask for it.
        if (steamRuntime && [steamInsert isKindOfClass:[NSString class]]) {
            NSFileManager *files = [NSFileManager defaultManager];
            NSString *thinLoader =
                @"/usr/local/lib/macws-steamloader-arm64.dylib";
            NSString *thinOverlay =
                @"/usr/local/lib/macws-gameoverlayrenderer-arm64.dylib";
            if ([steamInsert containsString:@"steamloader.dylib"] &&
                [files isReadableFileAtPath:thinLoader]) {
                [insertLibraries addObject:thinLoader];
            }
            if ([steamInsert containsString:@"gameoverlayrenderer.dylib"] &&
                [files isReadableFileAtPath:thinOverlay] &&
                !strayOverlayInjectionDiagnostic) {
                [insertLibraries addObject:thinOverlay];
            }
            if (strayOverlayInjectionDiagnostic) {
                fprintf(stderr,
                    "[MacWSSteamProcess] DIAGNOSTIC Stray overlay injection "
                    "disabled marker=/tmp/macws_stray_no_overlay_injection\n");
                fflush(stderr);
            }
        }
        merged[@"DYLD_INSERT_LIBRARIES"] =
            [insertLibraries componentsJoinedByString:@":"];
        // Steam's own CEF stays on the bounded CPU download profile, but a
        // launched macOS game must receive the production native-AGX contract.
        // Do this in the child environment so enabling a game never revives
        // Steam Helper's historical GPU/SwiftShader memory growth.
        if ([executablePath containsString:@"/steamapps/macws-runtime/"]) {
            [merged removeObjectForKey:@"MACWS_STEAM_CPU_RENDERING"];
            merged[@"MACWS_AGX_NATIVE"] = @"1";
            merged[@"MACWS_AGX_REGISTER_CLASSES"] = @"1";
            [merged removeObjectForKey:@"MACWS_PIN_FALLBACK"];
            if (MacWSIsSevenDaysToDieARMRuntimeExecutable(executablePath)) {
                // Runtime-confirmed with the exact arm64 Unity 2022.3.62f2
                // player on iPad14,5: Mono reaches gameplay initialization
                // through the page-granular W^X compatibility path, while the
                // completed CAMetalDrawable IOSurface is the authoritative
                // visible client area in MacWSHost.  Keep every switch scoped
                // to this exact runtime bundle; Steam, Stray and the M1 desktop
                // retain their existing launch contracts.
                merged[@"MACWS_MONO_JIT_COMPAT"] = @"1";
                merged[@"MACWS_JIT_MPROTECT_COMPAT"] = @"1";
                merged[@"MACWS_JIT_FAULT_WRITE_COMPAT"] = @"1";
                merged[@"MACWS_CATALYST_DIRECT_DRAWABLE"] = @"1";
                // Unity's macOS AGX producer emits opcode zero for the same
                // anchor-validated subtype-3 resource ABI family whose
                // generic/native form uses opcode four. Keep zero admission
                // scoped to this exact arm64 runtime; libmachook still
                // validates the complete record and segment-list structure.
                merged[@"MACWS_AGX_OPCODE_ZERO_COMPAT"] = @"1";
                // The iPad fullscreen scene is 1366x1024 logical points at a
                // 2x backing scale. Rendering this exact game at one backing
                // pixel per logical point keeps its fullscreen aspect and
                // leaves the final scale to MacWSHost's native Metal
                // compositor. Metal_hooks validates the exact executable
                // again before applying the public CAMetalLayer size policy.
                merged[@"MACWS_7DTD_RENDER_SCALE_COMPAT"] = @"1";
                merged[@"MACWS_STRAY_TARGET_FPS"] = @"60";
                // Steam owns this child as uid 501.  The Ventura rootfs has
                // no matching account record, so route it to the dedicated
                // real cfprefsd login agent and synthetic /Users/mobile home.
                // This restores Unity PlayerPrefs persistence; no preference
                // value or EULA state is synthesized here.
                merged[@"MACWS_SYNTHETIC_MOBILE_USER"] = @"1";
                if (![merged[@"SteamAppId"] isKindOfClass:[NSString class]])
                    merged[@"SteamAppId"] = @"251570";
                if (![merged[@"SteamGameId"] isKindOfClass:[NSString class]])
                    merged[@"SteamGameId"] = @"251570";
                fprintf(stderr,
                    "[MacWSSteamProcess] 7DTD arm64 environment "
                    "agx=%s monoJIT=%s directDrawable=%s targetFPS=%s "
                    "opcodeZero=%s renderScale=%s steamAppId=%s "
                    "insertLibraries=%lu\n",
                    [merged[@"MACWS_AGX_NATIVE"] UTF8String] ?: "(nil)",
                    [merged[@"MACWS_MONO_JIT_COMPAT"] UTF8String] ?: "(nil)",
                    [merged[@"MACWS_CATALYST_DIRECT_DRAWABLE"] UTF8String]
                        ?: "(nil)",
                    [merged[@"MACWS_STRAY_TARGET_FPS"] UTF8String] ?: "(nil)",
                    [merged[@"MACWS_AGX_OPCODE_ZERO_COMPAT"] UTF8String]
                        ?: "(nil)",
                    [merged[@"MACWS_7DTD_RENDER_SCALE_COMPAT"] UTF8String]
                        ?: "(nil)",
                    [merged[@"SteamAppId"] UTF8String] ?: "(nil)",
                    (unsigned long)insertLibraries.count);
                fflush(stderr);
            }
            // Stray's macOS 13 AGX command records have producer-version ABI
            // fields that differ from iOS 16's native consumer.  Keep the
            // exact, anchor-validated adapters game-scoped; Steam itself and
            // unrelated games must not inherit them.  This also makes the
            // verified NSWorkspace launch use the same contract as the
            // direct diagnostic runner instead of depending on the launcher's
            // ambient environment.
            if ([executablePath.lastPathComponent
                    isEqualToString:@"Stray-Mac-Shipping"]) {
                merged[@"MACWS_STRAY_AGX_COMPAT"] = @"1";
                // Launcher-only diagnostic selector. Keep fatal-signal and
                // abort instrumentation out of Steam, shell utilities and
                // desktop services; only the exact Stray child receives it.
                NSString *crashTraceSelector = merged[
                    @"MACWS_STRAY_CRASH_TRACE_SELECTOR"];
                BOOL crashTraceDiagnostic =
                    [crashTraceSelector isKindOfClass:[NSString class]] &&
                    [crashTraceSelector isEqualToString:@"1"];
                if (crashTraceDiagnostic) {
                    merged[@"MACWS_AGX_CRASH_DIAG"] = @"1";
                    merged[@"MACWS_ABORT_TRACE"] = @"1";
                }
                [merged removeObjectForKey:
                    @"MACWS_STRAY_CRASH_TRACE_SELECTOR"];
                NSString *overlayCEFWaitDiagnostic = merged[
                    @"MACWS_STRAY_OVERLAY_DISABLE_CEF_WAIT_DIAGNOSTIC"];
                BOOL disableOverlayCEFWait =
                    [overlayCEFWaitDiagnostic
                        isKindOfClass:[NSString class]] &&
                    [overlayCEFWaitDiagnostic isEqualToString:@"1"];
                if (disableOverlayCEFWait) {
                    merged[
                        @"STEAM_OVERLAY_DISABLE_WAIT_FOR_CEF_FRAME"] = @"1";
                }
                [merged removeObjectForKey:
                    @"MACWS_STRAY_OVERLAY_DISABLE_CEF_WAIT_DIAGNOSTIC"];
                NSString *overlayEventWaitSelector = merged[
                    @"MACWS_STRAY_OVERLAY_EVENT_WAIT_DIAGNOSTIC_SELECTOR"];
                BOOL overlayEventWaitDiagnostic =
                    [overlayEventWaitSelector isKindOfClass:[NSString class]] &&
                    [overlayEventWaitSelector isEqualToString:@"1"];
                if (overlayEventWaitDiagnostic) {
                    merged[
                        @"MACWS_STRAY_OVERLAY_EVENT_WAIT_DIAGNOSTIC"] = @"1";
                    merged[@"MACWS_STEAM_SEM_TIMING_DIAGNOSTICS"] = @"1";
                }
                [merged removeObjectForKey:
                    @"MACWS_STRAY_OVERLAY_EVENT_WAIT_DIAGNOSTIC_SELECTOR"];
                // Match the virtual-display completion cadence to the same
                // production target used by GameUserSettings. This prevents
                // WindowServer from composing 60/120 complete Retina frames
                // for a game whose configured production cap is 54 FPS.
                NSString *completionFPSDiagnostic =
                    merged[@"MACWS_STRAY_COMPLETION_FPS_DIAGNOSTIC"];
                BOOL completion30Diagnostic =
                    [completionFPSDiagnostic isKindOfClass:[NSString class]] &&
                    [completionFPSDiagnostic isEqualToString:@"30"];
                BOOL completion50Diagnostic =
                    [completionFPSDiagnostic isKindOfClass:[NSString class]] &&
                    [completionFPSDiagnostic isEqualToString:@"50"];
                BOOL completion60Diagnostic =
                    [completionFPSDiagnostic isKindOfClass:[NSString class]] &&
                    [completionFPSDiagnostic isEqualToString:@"60"];
                BOOL completion120Diagnostic =
                    [completionFPSDiagnostic isKindOfClass:[NSString class]] &&
                    [completionFPSDiagnostic isEqualToString:@"120"];
                merged[@"MACWS_STRAY_TARGET_FPS"] =
                    completion30Diagnostic ? @"30" :
                    (completion50Diagnostic ? @"50" :
                    (completion60Diagnostic ? @"60" :
                    (completion120Diagnostic ? @"120" : @"54")));
                // The selector is an inherited launcher-only A/B control.
                // Do not expose it as a second runtime switch in the game.
                [merged removeObjectForKey:
                    @"MACWS_STRAY_COMPLETION_FPS_DIAGNOSTIC"];
                // Launcher-only selector. The actual UE contract is the
                // binary's early -rhithread/-norhithread option, appended to
                // NSWorkspace argv by MacWSArgumentsForWorkspaceConfiguration.
                // Do not create a similarly named runtime environment switch.
                [merged removeObjectForKey:
                    @"MACWS_STRAY_RHI_THREAD_SELECTOR"];
                // Drawable protocol v2 transfers an explicit IOSurface use
                // count to Host and retains the accepted frame through the
                // consuming GPU submission, so CAMetalLayer cannot recycle
                // the storage while Host samples it. Runtime-confirmed on
                // iPad13,6 with publication active from Stray's first frame:
                // the complete startup, real-gameplay W probe and 15-second
                // score remained pixel-continuous and live at 2388x1668
                // Medium/100%, while WindowServer fell from 20.64% to 4.63%
                // mean CPU versus the otherwise identical capture route.
                // Make that validated zero-copy route part of the normal
                // Steam launch contract instead of requiring benchmark
                // marker files.
                merged[@"MACWS_CATALYST_DIRECT_DRAWABLE"] = @"1";
                fprintf(stderr,
                    "[MacWSSteamProcess] Stray environment "
                    "agx=%s targetFPS=%s completionDiagnostic=%s "
                    "overlayCEFWaitDiagnostic=%s "
                    "overlayEventWaitDiagnostic=%s "
                    "crashTraceDiagnostic=%s "
                    "directDrawable=%s "
                    "insertLibraries=%lu\n",
                    [merged[@"MACWS_AGX_NATIVE"] UTF8String] ?: "(nil)",
                    [merged[@"MACWS_STRAY_TARGET_FPS"] UTF8String] ?: "(nil)",
                    completion30Diagnostic ? "30" :
                        (completion50Diagnostic ? "50" :
                        (completion60Diagnostic ? "60" :
                        (completion120Diagnostic ? "120" : "off"))),
                    disableOverlayCEFWait ? "disabled" : "off",
                    overlayEventWaitDiagnostic ? "event-10ms" : "off",
                    crashTraceDiagnostic ? "on" : "off",
                    [merged[@"MACWS_CATALYST_DIRECT_DRAWABLE"] UTF8String]
                        ?: "(nil)",
                    (unsigned long)insertLibraries.count);
                fflush(stderr);
            }
        }
        // Reuse the existing bounded termination recorder only while the
        // Steam launch adapter's explicit diagnostic mode is enabled.  This
        // is removed with MACWS_STEAM_PROCESS_DIAGNOSTICS in production.
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS"))
            merged[@"MACWS_STEAM_EXIT_DIAGNOSTICS"] = @"1";
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS"))
            merged[@"MACWS_STEAM_UE4_DIAGNOSTICS"] = @"1";
    }
    // launchdchrootexec normally supplies this data invariant to descendants.
    // Keep it explicit when Steam creates a fresh environment dictionary.
    if (![merged[@"MACWS_CHROOT_HOST_ROOT"] isKindOfClass:[NSString class]])
        merged[@"MACWS_CHROOT_HOST_ROOT"] = @"/private/var/mnt/rootfs";

    return merged;
}

static char **MacWSCopyEnvironmentForWorkspaceConfiguration(
        NSDictionary *configuration, NSString *executablePath) {
    NSDictionary *merged = MacWSMergedEnvironmentForWorkspaceConfiguration(
        configuration, executablePath);
    char **environment = calloc(merged.count + 1, sizeof(*environment));
    if (!environment) return NULL;
    __block size_t output = 0;
    __block bool valid = true;
    [merged enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]] ||
            ![value isKindOfClass:[NSString class]]) {
            valid = false;
            *stop = YES;
            return;
        }
        const char *keyBytes = [(NSString *)key UTF8String];
        const char *valueBytes = [(NSString *)value UTF8String];
        if (!keyBytes || !valueBytes ||
            asprintf(&environment[output], "%s=%s", keyBytes, valueBytes) < 0) {
            valid = false;
            *stop = YES;
            return;
        }
        output++;
    }];
    if (valid) return environment;
    for (size_t index = 0; index < output; index++) free(environment[index]);
    free(environment);
    return NULL;
}

static void MacWSFreeCStringVector(char **vector) {
    if (!vector) return;
    for (size_t index = 0; vector[index]; index++) free(vector[index]);
    free(vector);
}

static id MacWSSteamLaunchApplicationAtURL(
        id workspace, SEL selector, NSURL *applicationURL, NSUInteger options,
        NSDictionary *configuration, NSError **error) {
    id launched = gMacWSOriginalNSWorkspaceLaunchApplication
        ? gMacWSOriginalNSWorkspaceLaunchApplication(
            workspace, selector, applicationURL, options, configuration, error)
        : nil;
    NSError *originalError = error ? *error : nil;
    NSString *applicationPath = [applicationURL path];
    bool diagnostics = getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS") != NULL;
    if (diagnostics) {
        NSDictionary *configuredEnvironment = [configuration objectForKey:
            @"NSWorkspaceLaunchConfigurationEnvironment"];
        NSArray *configuredArguments = [configuration objectForKey:
            @"NSWorkspaceLaunchConfigurationArguments"];
        fprintf(stderr,
                "[MacWSSteamProcess] NSWorkspace launch path=%s options=%#lx "
                "result=%p error-domain=%s error-code=%ld argc=%lu envc=%lu\n",
                applicationPath.UTF8String ?: "(null)",
                (unsigned long)options, launched,
                originalError.domain.UTF8String ?: "(none)",
                (long)originalError.code,
                (unsigned long)([configuredArguments isKindOfClass:
                    [NSArray class]] ? configuredArguments.count : 0),
                (unsigned long)([configuredEnvironment isKindOfClass:
                    [NSDictionary class]] ? configuredEnvironment.count : 0));
        if ([configuredArguments isKindOfClass:[NSArray class]]) {
            for (NSUInteger index = 0; index < configuredArguments.count;
                 index++) {
                NSString *argument = configuredArguments[index];
                fprintf(stderr,
                        "[MacWSSteamProcess] workspace-argv[%lu]=%s\n",
                        (unsigned long)index,
                        [argument isKindOfClass:[NSString class]]
                            ? argument.UTF8String : "(non-string)");
            }
        }
        fflush(stderr);
    }
    static NSString *const steamAppsPrefix =
        @"/Users/root/Library/Application Support/Steam/steamapps/common/";
    if (launched || !getenv("MACWS_STEAM_APP_LAUNCH_COMPAT") ||
        ![applicationPath hasPrefix:steamAppsPrefix] ||
        ![applicationPath hasSuffix:@".app"]) {
        return launched;
    }

    // Steam has already verified the depot path before it reaches this call.
    // If the stock NSWorkspace launch failed, give the same LaunchServices
    // owner a separately signed runtime bundle. This retains app registration,
    // activation and Steam's launch environment instead of fabricating a
    // successful return around a failed source-bundle launch.
    NSURL *runtimeApplicationURL = MacWSSteamRuntimeApplicationURL(
        applicationPath);
    if (runtimeApplicationURL &&
        gMacWSOriginalNSWorkspaceLaunchApplication) {
        CFBundleRef runtimeBundle = CFBundleCreate(
            kCFAllocatorDefault, (__bridge CFURLRef)runtimeApplicationURL);
        CFURLRef runtimeExecutableURL = runtimeBundle
            ? CFBundleCopyExecutableURL(runtimeBundle) : NULL;
        NSString *runtimeExecutablePath = runtimeExecutableURL
            ? [(__bridge NSURL *)runtimeExecutableURL path] : nil;
        // Runtime-confirmed on iPad14,5 after two consecutive Steam
        // `-applaunch 251570` generations: PID 30667 had already completed
        // its AppKit/LaunchServices check-in when the replacement Steam
        // process launched PID 31118 from the same runtime bundle. Both
        // players then submitted 1366x1024 direct drawables with comparable
        // sustained CPU load. Stock LaunchServices normally treats an
        // already-running application as the result of a second open. The
        // signed-runtime fallback must preserve that single-instance
        // invariant explicitly because Steam asked to open the x86 launcher
        // bundle, not the already-running arm64 runtime bundle.
        id existingRuntimeApplication =
            MacWSExistingSevenDaysRuntimeApplication(
                runtimeApplicationURL, runtimeExecutablePath);
        if (existingRuntimeApplication) {
            pid_t existingPID = ((pid_t (*)(id, SEL))objc_msgSend)(
                existingRuntimeApplication,
                NSSelectorFromString(@"processIdentifier"));
            fprintf(stderr,
                    "[MacWSSteamProcess] existing 7DTD runtime reused "
                    "pid=%d executable=%s\n",
                    existingPID,
                    runtimeExecutablePath.UTF8String ?: "(null)");
            fflush(stderr);
            if (runtimeExecutableURL) CFRelease(runtimeExecutableURL);
            if (runtimeBundle) CFRelease(runtimeBundle);
            if (error) *error = nil;
            return existingRuntimeApplication;
        }
        NSMutableDictionary *runtimeConfiguration = configuration
            ? [configuration mutableCopy] : [NSMutableDictionary dictionary];
        NSDictionary *runtimeEnvironment =
            MacWSMergedEnvironmentForWorkspaceConfiguration(
                configuration, runtimeExecutablePath);
        runtimeConfiguration[@"NSWorkspaceLaunchConfigurationEnvironment"] =
            runtimeEnvironment;
        runtimeConfiguration[@"NSWorkspaceLaunchConfigurationArguments"] =
            MacWSArgumentsForWorkspaceConfiguration(
                configuration, runtimeExecutablePath);
        NSError *runtimeError = nil;
        id runtimeApplication =
            gMacWSOriginalNSWorkspaceLaunchApplication(
                workspace, selector, runtimeApplicationURL, options,
                runtimeConfiguration, &runtimeError);
        fprintf(stderr,
                "[MacWSSteamProcess] NSWorkspace runtime launch source=%s "
                "runtime=%s insert=%s result=%p error-domain=%s "
                "error-code=%ld\n",
                applicationPath.UTF8String ?: "(null)",
                runtimeApplicationURL.path.UTF8String ?: "(null)",
                [runtimeEnvironment[@"DYLD_INSERT_LIBRARIES"] UTF8String]
                    ?: "(null)",
                runtimeApplication,
                runtimeError.domain.UTF8String ?: "(none)",
                (long)runtimeError.code);
        fflush(stderr);
        if (runtimeExecutableURL) CFRelease(runtimeExecutableURL);
        if (runtimeBundle) CFRelease(runtimeBundle);
        if (runtimeApplication) {
            if (error) *error = nil;
            return runtimeApplication;
        }
        applicationURL = runtimeApplicationURL;
    }

    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault,
                                        (__bridge CFURLRef)applicationURL);
    CFURLRef executableURL = bundle ? CFBundleCopyExecutableURL(bundle) : NULL;
    NSString *executablePath = executableURL
        ? [(__bridge NSURL *)executableURL path] : nil;
    NSArray *configuredArguments =
        MacWSArgumentsForWorkspaceConfiguration(configuration, executablePath);
    // UE4 shipping builds normally keep their early boot log out of stderr.
    // During the bounded launch diagnostic, request the engine's own log and
    // preserve it in the chroot tmp directory.  These arguments are never
    // present when MACWS_STEAM_PROCESS_DIAGNOSTICS is disabled.
    NSArray *diagnosticArguments = diagnostics ? @[
        @"-log",
        @"-stdout",
        @"-FullStdOutLogOutput",
        @"-abslog=/tmp/MacWS-Stray.log"
    ] : @[];
    char **arguments = executablePath
        ? calloc(configuredArguments.count + diagnosticArguments.count + 2,
                 sizeof(*arguments)) : NULL;
    char **environment = MacWSCopyEnvironmentForWorkspaceConfiguration(
        configuration, executablePath);
    bool valid = arguments && environment;
    if (valid) arguments[0] = strdup(executablePath.UTF8String);
    for (NSUInteger index = 0; valid && index < configuredArguments.count;
         index++) {
        NSString *argument = configuredArguments[index];
        if (![argument isKindOfClass:[NSString class]] ||
            !(arguments[index + 1] = strdup(argument.UTF8String))) {
            valid = false;
        }
    }
    for (NSUInteger index = 0; valid && index < diagnosticArguments.count;
         index++) {
        NSString *argument = diagnosticArguments[index];
        NSUInteger output = configuredArguments.count + index + 1;
        if (!(arguments[output] = strdup(argument.UTF8String))) valid = false;
    }

    posix_spawn_file_actions_t actions;
    bool actionsReady = false;
    int spawnError = valid ? posix_spawn_file_actions_init(&actions) : EINVAL;
    if (spawnError == 0) {
        actionsReady = true;
        typedef int (*MacWSAddChdirFunction)(
            posix_spawn_file_actions_t *, const char *);
        MacWSAddChdirFunction addChdir = (MacWSAddChdirFunction)dlsym(
            RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
        NSString *workingDirectory =
            [executablePath stringByDeletingLastPathComponent];
        if (addChdir && workingDirectory.length)
            spawnError = addChdir(&actions, workingDirectory.UTF8String);
    }
    pid_t child = 0;
    if (spawnError == 0) {
        spawnError = posix_spawn(&child, executablePath.UTF8String,
                                 &actions, NULL, arguments, environment);
    }
    if (actionsReady) posix_spawn_file_actions_destroy(&actions);
    MacWSFreeCStringVector(arguments);
    MacWSFreeCStringVector(environment);
    if (executableURL) CFRelease(executableURL);
    if (bundle) CFRelease(bundle);

    id runningApplication = nil;
    if (spawnError == 0) {
        Class runningApplicationClass = NSClassFromString(@"NSRunningApplication");
        SEL runningSelector = NSSelectorFromString(
            @"runningApplicationWithProcessIdentifier:");
        // The spawned UE4 runtime performs its AppKit/LaunchServices check-in
        // asynchronously.  Runtime-confirmed on Stray: a two-second bound
        // returned nil and Steam immediately raised AppError_46/OS Error 0,
        // even though that exact PID published its AppKit window moments
        // later.  Wait for the real NSRunningApplication object; never
        // fabricate one or report a dead child as launched.
        for (unsigned int attempt = 0;
             attempt < 1000 && !runningApplication; attempt++) {
            if ([runningApplicationClass respondsToSelector:runningSelector]) {
                runningApplication = ((id (*)(id, SEL, pid_t))objc_msgSend)(
                    runningApplicationClass, runningSelector, child);
            }
            if (!runningApplication) {
                if (kill(child, 0) != 0 && errno == ESRCH) break;
                usleep(10000);
            }
        }
        if (runningApplication && error) *error = nil;
    }
    fprintf(stderr,
            "[MacWSSteamProcess] NSWorkspace fallback executable=%s "
            "insert=%s spawn-error=%d pid=%d running-app=%p "
            "original-error=%ld\n",
            executablePath.UTF8String ?: "(null)",
            MacWSInsertLibraryForSteamExecutable(executablePath).UTF8String,
            spawnError, child, runningApplication,
            (long)originalError.code);
    fflush(stderr);
    return runningApplication;
}

static id MacWSSteamOpenURL(
        id workspace, SEL selector, NSURL *url, NSUInteger options,
        NSDictionary *configuration, NSError **error) {
    id launched = gMacWSOriginalNSWorkspaceOpenURL
        ? gMacWSOriginalNSWorkspaceOpenURL(
            workspace, selector, url, options, configuration, error) : nil;
    if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
        NSError *launchError = error ? *error : nil;
        fprintf(stderr,
                "[MacWSSteamProcess] NSWorkspace openURL path=%s "
                "options=%#lx result=%p error-domain=%s error-code=%ld\n",
                url.path.UTF8String ?: "(null)", (unsigned long)options,
                launched, launchError.domain.UTF8String ?: "(none)",
                (long)launchError.code);
        fflush(stderr);
    }
    if (launched || ![url.path hasSuffix:@".app"]) return launched;
    return MacWSSteamLaunchApplicationAtURL(
        workspace,
        NSSelectorFromString(
            @"launchApplicationAtURL:options:configuration:error:"),
        url, options, configuration, error);
}

static id MacWSSteamOpenURLs(
        id workspace, SEL selector, NSArray *urls, NSURL *applicationURL,
        NSUInteger options, NSDictionary *configuration, NSError **error) {
    id launched = gMacWSOriginalNSWorkspaceOpenURLs
        ? gMacWSOriginalNSWorkspaceOpenURLs(
            workspace, selector, urls, applicationURL, options,
            configuration, error) : nil;
    if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
        NSError *launchError = error ? *error : nil;
        fprintf(stderr,
                "[MacWSSteamProcess] NSWorkspace openURLs app=%s items=%lu "
                "options=%#lx result=%p error-domain=%s error-code=%ld\n",
                applicationURL.path.UTF8String ?: "(null)",
                (unsigned long)([urls isKindOfClass:[NSArray class]]
                    ? urls.count : 0),
                (unsigned long)options, launched,
                launchError.domain.UTF8String ?: "(none)",
                (long)launchError.code);
        fflush(stderr);
    }
    if (launched || ![applicationURL.path hasSuffix:@".app"])
        return launched;
    return MacWSSteamLaunchApplicationAtURL(
        workspace,
        NSSelectorFromString(
            @"launchApplicationAtURL:options:configuration:error:"),
        applicationURL, options, configuration, error);
}

static void MacWSInstallSteamApplicationLaunchCompatibility(void) {
    // DYLD_INSERT_LIBRARIES initializes libmachook before Steam has
    // necessarily realized AppKit's NSWorkspace class.  Do not consume the
    // once token until the real method exists: doing so permanently disabled
    // the verified-depot -> signed-runtime launch adapter for that Steam
    // process and made every game launch end in AppError_49.
    Class workspaceClass = NSClassFromString(@"NSWorkspace");
    SEL sharedSelector = NSSelectorFromString(@"sharedWorkspace");
    id sharedWorkspace = [workspaceClass respondsToSelector:sharedSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, sharedSelector)
        : nil;
    Class implementationClass = sharedWorkspace
        ? object_getClass(sharedWorkspace) : workspaceClass;
    SEL selector = NSSelectorFromString(
        @"launchApplicationAtURL:options:configuration:error:");
    Method method = implementationClass
        ? class_getInstanceMethod(implementationClass, selector) : NULL;
    if (!method) {
        static unsigned unavailableLogs;
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS") &&
            unavailableLogs++ < 4) {
            fprintf(stderr,
                    "[MacWSSteamProcess] NSWorkspace launch compatibility "
                    "deferred pid=%d program=%s class=%p implementation=%p\n",
                    getpid(), getprogname() ?: "(null)", workspaceClass,
                    implementationClass);
            fflush(stderr);
        }
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gMacWSOriginalNSWorkspaceLaunchApplication =
            (MacWSNSWorkspaceLaunchFunction)method_getImplementation(method);
        method_setImplementation(method,
                                 (IMP)MacWSSteamLaunchApplicationAtURL);
        SEL openURLSelector = NSSelectorFromString(
            @"openURL:options:configuration:error:");
        Method openURLMethod = class_getInstanceMethod(
            implementationClass, openURLSelector);
        if (openURLMethod) {
            gMacWSOriginalNSWorkspaceOpenURL =
                (MacWSNSWorkspaceLaunchFunction)method_getImplementation(
                    openURLMethod);
            method_setImplementation(openURLMethod, (IMP)MacWSSteamOpenURL);
        }
        SEL openURLsSelector = NSSelectorFromString(
            @"openURLs:withApplicationAtURL:options:configuration:error:");
        Method openURLsMethod = class_getInstanceMethod(
            implementationClass, openURLsSelector);
        if (openURLsMethod) {
            gMacWSOriginalNSWorkspaceOpenURLs =
                (MacWSNSWorkspaceOpenURLsFunction)method_getImplementation(
                    openURLsMethod);
            method_setImplementation(openURLsMethod, (IMP)MacWSSteamOpenURLs);
        }
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
            fprintf(stderr,
                    "[MacWSSteamProcess] NSWorkspace launch compatibility "
                    "installed pid=%d program=%s class=%s launch=%p "
                    "openURL=%p openURLs=%p\n",
                    getpid(), getprogname() ?: "(null)",
                    implementationClass ? class_getName(implementationClass)
                        : "(null)",
                    gMacWSOriginalNSWorkspaceLaunchApplication,
                    gMacWSOriginalNSWorkspaceOpenURL,
                    gMacWSOriginalNSWorkspaceOpenURLs);
            fflush(stderr);
        }
    });
}

// AppKit's first finishLaunching pass asks HIServices for the lazily linked
// AccessibilityBaseImplementations image.  Steam CEF has already created and
// retired startup workers by that point.  On the iPadOS 16 kernel the macOS
// dyld recursive API lock can retain a Mach-thread owner name that is no
// longer valid: runtime-confirmed in Steam Helper 1785799196 with dlopen_from
// waiting on owner 0x10c02 while mach_port_type(task, 0x10c02) returned
// KERN_INVALID_NAME (0xf).
//
// Resolve the same HIServices soft-link accessor while the top-level browser
// is still in its single-threaded image-initializer phase.  The accessor does
// the stock dlopen and returns the stock implementation library; no
// Accessibility result or lock operation is bypassed.  Later AppKit
// registration consumes HIServices' initialized once-state and therefore
// does not begin its first lazy load after worker retirement.
static void MacWSPrepareSteamAccessibilityRuntime(void) {
    if (!MacWSIsTopLevelSteamBrowser()) return;
    typedef void *(*MacWSAccessibilityLibraryFunction)(void *);
    static const char *const paths[] = {
        "/System/Library/Frameworks/ApplicationServices.framework/"
        "Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices",
        "/System/Library/Frameworks/ApplicationServices.framework/"
        "Frameworks/HIServices.framework/HIServices",
        NULL,
    };
    MSImageRef image = NULL;
    for (size_t index = 0; paths[index] && !image; index++) {
        image = MSGetImageByName(paths[index]);
        if (!image && dlopen(paths[index], RTLD_LAZY | RTLD_LOCAL))
            image = MSGetImageByName(paths[index]);
    }

    // This generated HIServices soft-link accessor is deliberately private,
    // so dlsym cannot resolve it even after dlopen. RE-confirmed in the exact
    // macOS 13.4 DSC (UUID 7D9FAA84-5C6B-3EF4-9379-FABA64346673):
    // _libAccessibilityBaseImplementationsLibraryCore is at unslid
    // 0x185c79564 and performs the stock _sl_dlopen sequence. Resolve the
    // private symbol through Substrate's Mach-O image lookup instead.
    MacWSAccessibilityLibraryFunction library = image ?
        (MacWSAccessibilityLibraryFunction)MSFindSymbol(
            image, "_libAccessibilityBaseImplementationsLibraryCore") : NULL;
    if (!library) return;
    // RE-confirmed call sites in _AXUIElementRegisterServerWithRunLoop at
    // 0x185c535a8 and +0xf4 explicitly pass x0 = NULL to this accessor.
    void *handle = library(NULL);
    if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
        fprintf(stderr,
                "[MacWSSteamProcess] Accessibility implementation "
                "preloaded=%p\n", handle);
        fflush(stderr);
    }
}

// Valve's bit-2 call sites build a sequence of individually single-quoted
// arguments (runtime example: '.../steamsysinfo' '-steamid' '0' ...). Parse
// only that unambiguous form so it can be spawned atomically without a second
// shell exec. Any metacharacter, unquoted token or embedded quote rejects the
// parse and retains the native /bin/sh contract below.
static char **MacWSParseValveQuotedArguments(const char *command) {
    if (!command) return NULL;
    size_t count = 0;
    size_t capacity = 8;
    char **arguments = calloc(capacity, sizeof(*arguments));
    if (!arguments) return NULL;
    const char *cursor = command;
    while (*cursor) {
        while (*cursor == ' ' || *cursor == '\t') cursor++;
        if (!*cursor) break;
        if (*cursor++ != '\'') goto invalid;
        const char *start = cursor;
        while (*cursor && *cursor != '\'') cursor++;
        if (*cursor != '\'') goto invalid;
        size_t length = (size_t)(cursor - start);
        char *argument = strndup(start, length);
        if (!argument) goto invalid;
        cursor++;
        if (*cursor && *cursor != ' ' && *cursor != '\t') {
            free(argument);
            goto invalid;
        }
        if (count + 2 > capacity) {
            capacity *= 2;
            char **grown = realloc(arguments,
                                   capacity * sizeof(*arguments));
            if (!grown) {
                free(argument);
                goto invalid;
            }
            arguments = grown;
        }
        arguments[count++] = argument;
        arguments[count] = NULL;
    }
    if (count > 0 && arguments[0][0] == '/') return arguments;
invalid:
    for (size_t index = 0; index < count; index++) free(arguments[index]);
    free(arguments);
    return NULL;
}

static void MacWSFreeParsedArguments(char **arguments) {
    if (!arguments) return;
    for (size_t index = 0; arguments[index]; index++) free(arguments[index]);
    free(arguments);
}

static bool MacWSPathEndsWith(const char *path, const char *suffix) {
    if (!path || !suffix) return false;
    size_t pathLength = strlen(path);
    size_t suffixLength = strlen(suffix);
    return pathLength >= suffixLength &&
        !strcmp(path + pathLength - suffixLength, suffix);
}

// Steam's browser process runs under the same explicitly unsandboxed MacWS
// compatibility profile as its parent. Chromium 126 nevertheless attempts to
// construct the macOS Seatbelt parameter table and terminates at
// sandbox_parameters_mac.mm:69 when iPadOS cannot provide that macOS process
// metadata (runtime log: errno=EIO). Select Chromium's supported no-sandbox
// launch mode at the parent call site, before initialization; this keeps its
// internal invariants intact and matches the kernel policy already attached to
// the process. Restrict the switch to Valve's exact browser helper.
static bool MacWSSteamArgumentPresent(char *const *arguments,
                                      const char *expected) {
    for (size_t index = 0; arguments && arguments[index]; index++) {
        if (!strcmp(arguments[index], expected)) return true;
    }
    return false;
}

static char **MacWSArgumentsByAddingSteamBrowserPolicy(
    const char *executable, char *const *arguments) {
    static const char helperSuffix[] =
        "/Steam Helper.app/Contents/MacOS/Steam Helper";
    if (!MacWSPathEndsWith(executable, helperSuffix) || !arguments) return NULL;
    size_t count = 0;
    while (arguments[count]) count++;

    // Steam's outer -cef-disable-gpu switch enables Chromium's software
    // compositor but still allows the GPU helper to instantiate SwiftShader.
    // The historical Jetsam witness attributed 600180 resident 16-KiB pages
    // (9.16 GiB) to that exact gpu-process role. In the explicit download/UI
    // profile, keep software page compositing while disabling the separate
    // software rasterizer, GPU raster and zero-copy buffer paths.  Apply the
    // policy to every Valve Helper role.  Runtime command-line capture on
    // 2026-08-19 disproved the earlier assumption that Chromium propagates
    // all three switches: the gpu-process inherited gpu-rasterization only,
    // then reached 648584 resident 16-KiB pages before Jetsam.  The exact
    // helper-path restriction above still keeps games and unrelated MacWS
    // applications untouched.
    bool cpuRendering = getenv("MACWS_STEAM_CPU_RENDERING") != NULL;
    static const char *const cpuPolicies[] = {
        "--disable-software-rasterizer",
        "--disable-gpu-rasterization",
        "--disable-zero-copy",
    };
    size_t additions = MacWSSteamArgumentPresent(arguments, "--no-sandbox")
        ? 0 : 1;
    if (cpuRendering) {
        for (size_t index = 0;
             index < sizeof(cpuPolicies) / sizeof(cpuPolicies[0]); index++) {
            if (!MacWSSteamArgumentPresent(arguments, cpuPolicies[index]))
                additions++;
        }
    }
    if (additions == 0) return NULL;

    char **result = calloc(count + additions + 1, sizeof(*result));
    if (!result) return NULL;
    for (size_t index = 0; index < count; index++)
        result[index] = arguments[index];
    size_t output = count;
    if (!MacWSSteamArgumentPresent(arguments, "--no-sandbox"))
        result[output++] = (char *)"--no-sandbox";
    if (cpuRendering) {
        for (size_t index = 0;
             index < sizeof(cpuPolicies) / sizeof(cpuPolicies[0]); index++) {
            if (!MacWSSteamArgumentPresent(arguments, cpuPolicies[index]))
                result[output++] = (char *)cpuPolicies[index];
        }
    }
    return result;
}

static int MacWSCallOriginalCreateSimpleProcess(
        void *commandOrArguments, int flags, char *const *environment,
        const char *workingDirectory) {
    if (!gMacWSOriginalCreateSimpleProcess) return 0;
    if (gMacWSCreateSimpleProcessABI == MacWSSteamCreateSimpleProcessV4) {
        return ((MacWSCreateSimpleProcessV4Function)
            gMacWSOriginalCreateSimpleProcess)(
                commandOrArguments, flags, environment, workingDirectory);
    }
    if (gMacWSCreateSimpleProcessABI == MacWSSteamCreateSimpleProcessV3) {
        return ((MacWSCreateSimpleProcessV3Function)
            gMacWSOriginalCreateSimpleProcess)(
                commandOrArguments, flags, workingDirectory);
    }
    return 0;
}

static int MacWSSteamCreateSimpleProcessShared(
        void *commandOrArguments, int flags, char *const *environment,
        const char *workingDirectory) {
    bool diagnostics = getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS") != NULL;
    if (diagnostics) {
        fprintf(stderr,
                "[MacWSSteamProcess] entry command=%p flags=%#x cwd=%p "
                "steam=%s\n",
                commandOrArguments, flags,
                workingDirectory,
                MacWSIsSteamProcess() ? "yes" : "no");
        fflush(stderr);
    }
    if (getenv("MACWS_STEAM_PROCESS_TRACE_ONLY")) {
        return MacWSCallOriginalCreateSimpleProcess(
            commandOrArguments, flags, environment, workingDirectory);
    }
    if (!MacWSIsSteamProcess() || (flags & 0x20) ||
        !(flags & (0x04 | 0x08 | 0x10))) {
        if (diagnostics) {
            fprintf(stderr,
                    "[MacWSSteamProcess] fallback to Valve implementation "
                    "flags=%#x\n", flags);
            fflush(stderr);
        }
        return MacWSCallOriginalCreateSimpleProcess(
            commandOrArguments, flags, environment, workingDirectory);
    }

    char *shellArguments[4] = {0};
    char *shellCommand = NULL;
    char **parsedArguments = NULL;
    char *const *arguments = NULL;
    const char *executable = NULL;
    bool searchPath = false;

    if (flags & 0x08) {
        arguments = (char *const *)commandOrArguments;
        executable = arguments ? arguments[0] : NULL;
    } else if (flags & 0x10) {
        arguments = (char *const *)commandOrArguments;
        executable = arguments ? arguments[0] : NULL;
        searchPath = true;
    } else {
        // RE-confirmed in Valve's implementation: the bit-2 path prefixes
        // "exec " before /bin/sh -c. Preserve that exact contract. Omitting
        // the prefix left the shell itself alive after its chrooted fork path
        // failed, consuming one core until ChildProcessQuery timed out.
        parsedArguments = MacWSParseValveQuotedArguments(
            (const char *)commandOrArguments);
        if (parsedArguments) {
            arguments = parsedArguments;
            executable = parsedArguments[0];
        } else {
            if (asprintf(&shellCommand, "exec %s",
                         (const char *)commandOrArguments) < 0) {
                errno = ENOMEM;
                return 0;
            }
            shellArguments[0] = (char *)"sh";
            shellArguments[1] = (char *)"-c";
            shellArguments[2] = shellCommand;
            arguments = shellArguments;
            executable = "/bin/sh";
        }
    }
    if (!executable || !arguments) {
        errno = EINVAL;
        return 0;
    }

    char **policyArguments = MacWSArgumentsByAddingSteamBrowserPolicy(
        executable, arguments);
    if (policyArguments) arguments = policyArguments;
    if (diagnostics) {
        fprintf(stderr,
                "[MacWSSteamProcess] spawn request executable=%s flags=%#x "
                "cwd=%s argv0=%s argv1=%s\n",
                executable, flags, workingDirectory ?: "(null)",
                arguments[0] ?: "(null)", arguments[1] ?: "(null)");
        for (size_t index = 0; index < 96 && arguments[index]; index++) {
            fprintf(stderr, "[MacWSSteamProcess] argv[%zu]=%s\n",
                    index, arguments[index]);
        }
        fflush(stderr);
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        free(shellCommand);
        free(policyArguments);
        MacWSFreeParsedArguments(parsedArguments);
        errno = result;
        return 0;
    }
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        free(shellCommand);
        free(policyArguments);
        MacWSFreeParsedArguments(parsedArguments);
        errno = result;
        return 0;
    }

    if (workingDirectory && workingDirectory[0]) {
        // The iOS SDK marks this macOS ABI unavailable even though the
        // chroot's macOS libSystem exports it. Resolve the running image's
        // implementation without mutating the multithreaded parent's cwd.
        typedef int (*MacWSAddChdirFunction)(
            posix_spawn_file_actions_t *, const char *);
        MacWSAddChdirFunction addChdir = (MacWSAddChdirFunction)dlsym(
            RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
        result = addChdir ? addChdir(&actions, workingDirectory) : ENOSYS;
    }

    // Preserve Valve's actual process-group and signal-mask contract.
    // RE-confirmed in client 1785799196's arm64 libtier0_s.dylib:
    //   +0x40 fork
    //   +0x44 setpgrp; +0x48 setsid
    //   +0x60 sigprocmask(SIG_UNBLOCK, { SIGCHLD }, NULL)
    // Calling setpgrp first makes the child a process-group leader, so the
    // following setsid necessarily fails with EPERM; POSIX_SPAWN_SETSID was
    // therefore observably different (new session) from Valve's effective
    // contract. Build a new process group in the existing session and apply
    // the parent's mask with SIGCHLD removed atomically at spawn.
    short attributeFlags = 0;
    if (result == 0 && (flags & 0x02)) {
        result = posix_spawnattr_setpgroup(&attributes, 0);
        if (result == 0) attributeFlags |= POSIX_SPAWN_SETPGROUP;
    }
    sigset_t childSignalMask;
    if (result == 0 &&
        sigprocmask(SIG_SETMASK, NULL, &childSignalMask) != 0)
        result = errno;
    if (result == 0 && sigdelset(&childSignalMask, SIGCHLD) != 0)
        result = errno;
    if (result == 0) {
        result = posix_spawnattr_setsigmask(&attributes, &childSignalMask);
        if (result == 0) attributeFlags |= POSIX_SPAWN_SETSIGMASK;
    }
    if (result == 0)
        result = posix_spawnattr_setflags(&attributes, attributeFlags);

    pid_t child = 0;
    extern char **environ;
    char *const *spawnEnvironment = environment ? environment : environ;
    if (result == 0) {
        result = searchPath ?
            posix_spawnp(&child, executable, &actions, &attributes,
                         (char *const *)arguments,
                         (char *const *)spawnEnvironment) :
            posix_spawn(&child, executable, &actions, &attributes,
                        (char *const *)arguments,
                        (char *const *)spawnEnvironment);
    }

    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    free(shellCommand);
    if (result != 0) {
        errno = result;
        if (diagnostics) {
            fprintf(stderr,
                    "[MacWSSteamProcess] spawn failed executable=%s "
                    "flags=%#x cwd=%s error=%d\n",
                    executable, flags,
                    workingDirectory ?: "(null)", result);
            fflush(stderr);
        }
        MacWSFreeParsedArguments(parsedArguments);
        free(policyArguments);
        return 0;
    }
    if (diagnostics) {
        fprintf(stderr,
                "[MacWSSteamProcess] spawn success executable=%s "
                "flags=%#x cwd=%s pid=%d\n",
                executable, flags, workingDirectory ?: "(null)", child);
        fflush(stderr);
    }
    MacWSFreeParsedArguments(parsedArguments);
    free(policyArguments);
    return child;
}

static int MacWSSteamCreateSimpleProcessV3Adapter(
        void *commandOrArguments, int flags,
        const char *workingDirectory) {
    return MacWSSteamCreateSimpleProcessShared(
        commandOrArguments, flags, NULL, workingDirectory);
}

static int MacWSSteamCreateSimpleProcessV4Adapter(
        void *commandOrArguments, int flags, char *const *environment,
        const char *workingDirectory) {
    return MacWSSteamCreateSimpleProcessShared(
        commandOrArguments, flags, environment, workingDirectory);
}

static void MacWSSteamProcessImageLoaded(const struct mach_header *header,
                                         intptr_t slide) {
    if (!MacWSIsSteamProcess()) return;
    // The constructor may precede NSWorkspace class realization.  This call
    // is a cheap dispatch_once after success and a real retry beforehand.
    MacWSInstallSteamApplicationLaunchCompatibility();
    Dl_info image = {0};
    if (dladdr(header, &image) && image.dli_fname &&
        strstr(image.dli_fname, "/libtier0_s.dylib")) {
        gMacWSOriginalCreateSimpleProcess =
            MSFindSymbol((MSImageRef)header, "_CreateSimpleProcess");
        uintptr_t implementationOffset = gMacWSOriginalCreateSimpleProcess ?
            (uintptr_t)gMacWSOriginalCreateSimpleProcess -
                (uintptr_t)header : 0;
        // RE-confirmed from the two admitted libtier0_s arm64 images:
        //
        // 1785799196 +0xd91c accepts x0=argv, x1=flags, x2=cwd.
        // 1788652215 UUID 54365CF9-4CDD-3F42-94B9-5AAE7279DB41
        // +0xbd1c saves x2 as an environment vector and x3 as cwd, then the
        // child stores x2 into _environ before chdir(x3).  The matching
        // chromehtml call at +0x69648..+0x69658 loads all four registers.
        static const uint8_t tier0Build1788652215UUID[16] = {
            0x54, 0x36, 0x5c, 0xf9, 0x4c, 0xdd, 0x3f, 0x42,
            0x94, 0xb9, 0x5a, 0xae, 0x72, 0x79, 0xdb, 0x41,
        };
        if (implementationOffset == 0xd91c) {
            gMacWSCreateSimpleProcessABI = MacWSSteamCreateSimpleProcessV3;
        } else if (implementationOffset == 0xbd1c &&
                   MacWSHeaderHasUUID(
                       (const struct mach_header_64 *)header,
                       tier0Build1788652215UUID)) {
            gMacWSCreateSimpleProcessABI = MacWSSteamCreateSimpleProcessV4;
        } else {
            gMacWSCreateSimpleProcessABI =
                MacWSSteamCreateSimpleProcessUnsupported;
        }
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
            fprintf(stderr,
                    "[MacWSSteamProcess] resolved Valve implementation=%p "
                    "offset=%#lx abi=%u image=%s\n",
                    gMacWSOriginalCreateSimpleProcess,
                    (unsigned long)implementationOffset,
                    (unsigned)gMacWSCreateSimpleProcessABI,
                    image.dli_fname);
            fflush(stderr);
        }
        // libtier0 may load after steamui. Revisit every already-mapped image
        // now that both sides of the adapter are valid; future images continue
        // through the normal add-image callback below.
        if (gMacWSOriginalCreateSimpleProcess &&
            gMacWSCreateSimpleProcessABI !=
                MacWSSteamCreateSimpleProcessUnsupported) {
            for (uint32_t index = 0; index < _dyld_image_count(); index++) {
                MacWSRebindSteamProcessImport(
                    _dyld_get_image_header(index),
                    _dyld_get_image_vmaddr_slide(index));
            }
        }
    }
    MacWSRebindSteamProcessImport(header, slide);
}

__attribute__((constructor))
static void MacWSInstallSteamProcessCompatibility(void) {
    // Diagnostic isolation switch only. Production keeps the adapter enabled;
    // this lets a bounded run compare Valve's original fork path without
    // changing the shipped default.
    if (getenv("MACWS_DISABLE_STEAM_PROCESS_COMPAT")) return;
    if (MacWSIsSteamProcess()) {
        MacWSPrepareSteamAccessibilityRuntime();
        MacWSInstallSteamApplicationLaunchCompatibility();
        _dyld_register_func_for_add_image(MacWSSteamProcessImageLoaded);
        for (uint32_t index = 0; index < _dyld_image_count(); index++)
            MacWSSteamProcessImageLoaded(_dyld_get_image_header(index),
                                         _dyld_get_image_vmaddr_slide(index));
    }
}
