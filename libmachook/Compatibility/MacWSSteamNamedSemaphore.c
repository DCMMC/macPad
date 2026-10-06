#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "interpose.h"
#include "macws_control_protocol.h"
#include "macws_steam_semaphore_protocol.h"

// Steam build 1785799196 implements CSharedMemStream events with several
// named POSIX semaphores per stream. iPadOS 16 returns ENOSPC once its much
// smaller global named-semaphore table is exhausted. Runtime witness:
//
//   Failed to create BinarySemaphore: ... - /BSem/83ace80d
//   errno: 28, bCreator: false
//
// macwshostd owns the POSIX name/generation lifetime and creates one retained
// state vnode per generation. Protocol v23 makes flock + pread/pwrite on that
// vnode authoritative for uncontended post/trywait/getvalue. A zero blocking
// wait transfers its connected AF_UNIX descriptor into a hostd FIFO; a post
// seeing state.waiterCount delegates to hostd, which writes the reply to the
// oldest descriptor. The macOS client sleeps in kqueue/EVFILT_READ until that
// exact stream becomes readable. The real-iPad
// steam_kevent_wake_probe returned once after 1.005181 s when an iOS-native
// peer wrote the byte, and an LLDB snapshot of Steam Helper subsequently
// captured kevent -> MacWSSteamSemaphoreBrokerSocketValue -> sem_wait. This
// removes the protocol-v20 500-us predicate polling which generated roughly
// 1,000 wakeups/s. Broker generation IDs preserve sem_unlink lifetime until
// the final already-open handle closes.
//
// This replaces diagnostics which were not production-safe:
//  * counter + FIFO: /BSem/7c42de60 was posted while Helper remained in read.
//  * process-shared pthread condition: /BSem/25a9c935 was incremented and
//    signaled while the real multithreaded CEF waiter remained in psynch_cvwait.
//  * EVFILT_VNODE: /BSem/5fcdb63f reached value 1 in steam_osx while the real
//    Helper remained in kevent after registering NOTE_WRITE on the same vnode.
//  * APFS MAP_SHARED + ulock: /BSem/fc7e8f4d reached value=1/revision=2 in
//    the producer and a third mapping, but the real Helper mapping remained at
//    revision=1 and ULF_WAKE_ALL returned ENOENT.
//  * MAP_SHARED atomics + local poll: Helper waited on /BSem/912952d9 at
//    generation 6670971300437410543 after steam_osx posted value=1 to that
//    exact generation. It never observed the mapped update. This is why the
//    production transport reads the vnode through the kernel on every
//    predicate check instead of treating the mapped page as coherent.
//  * POSIX shm + ulock: Helper waited on /BSem/af9ccb4e at revision=1 while
//    both steam_osx and an iOS-native opener observed value=1/revision=2;
//    their wake calls did not release the real Helper thread. A native-only
//    two-process probe did wake, proving this mixed runtime mapping identity
//    cannot be used as the production semaphore transport.
//  * retained XPC reply: iOS hostd consumed a post and logged delivery for
//    /BSem/5336bc7a, while neither the macOS synchronous nor asynchronous XPC
//    reply path returned to the real Helper waiter.
//  * brokered Mach wake: hostd logged a two-waiter notification for
//    /BSem/59c896b5 after steam_osx wrote value=1, while the exact Helper
//    remained in mach_msg receive. Re-open retries accumulated 32 dead waiter
//    ports and then failed sem_open with ENOSPC.
//  * per-operation Unix stream RPC: protocol v18 used an ordinary blocking
//    read; adjacent request IDs arrived while a real Helper sem_post remained
//    in that read and hostd never observed its generation. Protocol v23 sends
//    the complete request first and waits through measured-good EVFILT_READ.
//  * persisted grant + SIGUSR2: steam_osx successfully granted and signaled
//    Helper 27164 for /BSem/88ece11, but the Helper exited without returning.
//  * persisted grant + Unix datagram: fd 59 was runtime-confirmed as the bound
//    /tmp/.macws-steam-wake-32463.sock and its receive queue reached 17 bytes,
//    while the receiver remained blocked in __recvfrom(fd=59).
//  * short-lived native POSIX wake endpoint: steam_osx persisted grant=1 and
//    sem_post returned success for /MacWSWake-0000d202-0019e4a2. An
//    iOS-native opener then consumed that exact queued token with sem_trywait,
//    while LLDB still found the Helper waiter blocked in syscall 271 at
//    libsystem_kernel.dylib`sem_wait+8.
// All failures were runtime-confirmed from exact producer/consumer logs.

#define MACWS_STEAM_SEM_HANDLE_MAGIC 0x4d575348u /* MWSH */

typedef struct MacWSSteamSemaphoreHandle {
    uint32_t magic;
    int descriptor;
    uint64_t brokerGeneration;
    unsigned referenceCount;
    bool unlinked;
    char name[MACWS_STEAM_SEM_NAME_CAPACITY];
    struct MacWSSteamSemaphoreHandle *next;
} MacWSSteamSemaphoreHandle;

// CEF's force-create contract is a batch of sem_unlink calls followed by the
// matching O_CREAT|O_EXCL opens. A native unlink/open pair is effectively
// immediate, but two synchronous broker round trips make that gap large
// enough for Steam's concurrent lookup loop to create the name first. Keep a
// short-lived, thread-owned receipt for each successful unlink so the broker
// can complete that exact caller's replace atomically. This is not a blanket
// EEXIST bypass: no receipt, a different thread, or an expired receipt retains
// ordinary POSIX O_EXCL behavior.
#define MACWS_STEAM_UNLINK_RECEIPT_CAPACITY 64u
#define MACWS_STEAM_UNLINK_RECEIPT_LIFETIME_NS UINT64_C(2000000000)
typedef struct MacWSSteamUnlinkReceipt {
    uint64_t generation;
    uint64_t threadID;
    uint64_t createdAt;
    char name[MACWS_STEAM_SEM_NAME_CAPACITY];
} MacWSSteamUnlinkReceipt;

static pthread_mutex_t gMacWSSteamSemaphoreHandlesLock =
    PTHREAD_MUTEX_INITIALIZER;
static MacWSSteamSemaphoreHandle *gMacWSSteamSemaphoreHandles;
static pthread_mutex_t gMacWSSteamUnlinkReceiptsLock =
    PTHREAD_MUTEX_INITIALIZER;
static MacWSSteamUnlinkReceipt
    gMacWSSteamUnlinkReceipts[MACWS_STEAM_UNLINK_RECEIPT_CAPACITY];
static uint32_t gMacWSSteamSemaphoreDiagnosticCount;
static pthread_once_t gMacWSSteamBrokerResetOnce = PTHREAD_ONCE_INIT;
static int gMacWSSteamBrokerResetError;
static pthread_mutex_t gMacWSSteamShmManifestLock =
    PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t gMacWSSteamSocketRequestID;
static _Atomic uint64_t gMacWSSteamSocketTimingFirstNanoseconds;
static _Atomic uint64_t gMacWSSteamSocketTimingCalls;
static _Atomic uint64_t gMacWSSteamSocketTimingNanoseconds;
static _Atomic uint64_t gMacWSSteamSocketTimingFailures;
static _Atomic uint64_t gMacWSSteamSocketTimingEagain;
static _Atomic uint64_t gMacWSSteamSocketTimingOperationCalls[7];
static _Atomic uint64_t gMacWSSteamSocketTimingOperationNanoseconds[7];
// Nonblocking value operations are synchronous per caller thread. Retaining
// one authenticated AF_UNIX stream in TLS preserves their exact broker order
// together with its EVFILT_READ kqueue while avoiding connect/accept/close and
// kqueue/create/register/close transactions for Steam's measured 10 ms
// controller poll. Blocking waits remain one-shot because hostd moves their
// descriptor into the semaphore FIFO until a producer posts.
static _Thread_local int gMacWSSteamValueSocket = -1;
static _Thread_local int gMacWSSteamValueKqueue = -1;
static _Thread_local bool gMacWSSteamValueKqueueRegistered;
static _Thread_local pid_t gMacWSSteamValueSocketPID;
static _Atomic uintptr_t gMacWSExactOverlayImageBase;
extern xpc_connection_t MacWSXPCConnectionCreateMachServiceRaw(
    const char *, dispatch_queue_t, uint64_t)
    __asm("_xpc_connection_create_mach_service");

static bool MacWSIsSteamProcess(void) {
    const char *program = getprogname();
    bool steamProcess = program &&
        (!strcmp(program, "steam_osx") ||
         !strcmp(program, "Steam Helper"));
    if (!steamProcess) {
        char executable[PATH_MAX] = {0};
        extern int proc_pidpath(int, void *, uint32_t);
        steamProcess = proc_pidpath(
            getpid(), executable, sizeof(executable)) > 0 &&
            (strstr(executable, "/Applications/Steam.app/") != NULL ||
             strstr(executable,
                    "/Library/Application Support/Steam/") != NULL);
    }
    return steamProcess;
}

// The named-semaphore/shm compatibility above must include Steam-launched
// games because Valve's injected overlay uses those primitives in the game
// process.  The deadline substitutions below are narrower: their runtime
// witnesses are Steam's CEF command pump and controller thread, and applying
// them to every executable below Application Support/Steam also classifies
// steamapps/macws-runtime games as the Steam client.
static bool MacWSIsSteamClientProcess(void) {
    const char *program = getprogname();
    return program && (!strcmp(program, "steam_osx") ||
                       !strcmp(program, "Steam Helper"));
}

static bool MacWSImageHasUUID(const struct mach_header_64 *header,
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

static bool MacWSIsExactOverlayEventWaitCallSite(const void *caller,
                                                 uintptr_t expectedOffset) {
    const char *enabled = getenv(
        "MACWS_STRAY_OVERLAY_EVENT_WAIT_DIAGNOSTIC");
    if (!enabled || strcmp(enabled, "1") || !caller) return false;
    uintptr_t base = atomic_load_explicit(
        &gMacWSExactOverlayImageBase, memory_order_relaxed);
    if (base != 0)
        return (uintptr_t)caller == base + expectedOffset;

    Dl_info image = {0};
    if (!dladdr(caller, &image) || !image.dli_fname || !image.dli_fbase ||
        !strstr(image.dli_fname, "gameoverlayrenderer")) return false;
    static const uint8_t expectedUUID[16] = {
        0x52, 0x9f, 0x4e, 0x8f, 0x0f, 0xfb, 0x30, 0xf9,
        0x88, 0xef, 0xae, 0x09, 0x18, 0xf4, 0xc3, 0x25,
    };
    if (!MacWSImageHasUUID(
            (const struct mach_header_64 *)image.dli_fbase,
            expectedUUID)) return false;
    base = (uintptr_t)image.dli_fbase;
    atomic_store_explicit(
        &gMacWSExactOverlayImageBase, base, memory_order_relaxed);
    dprintf(STDERR_FILENO,
            "[MacWSSteamSem] Stray overlay event-wait diagnostic armed "
            "image=%s base=%p UUID=529F4E8F-0FFB-30F9-88EF-AE0918F4C325\n",
            image.dli_fname, image.dli_fbase);
    return (uintptr_t)caller == base + expectedOffset;
}

static uint64_t MacWSSteamCurrentThreadID(void) {
    uint64_t threadID = 0;
    if (pthread_threadid_np(NULL, &threadID) != 0 || threadID == 0)
        threadID = 1;
    return threadID;
}

static uint64_t MacWSSteamMonotonicNanoseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) +
        (uint64_t)now.tv_nsec;
}

static int MacWSSteamRelativeDelay(useconds_t microseconds);

// A blocking flock waiter created by the macOS runtime does not reliably
// resume when another chroot process releases the vnode lock through the iOS
// kernel. Runtime samples steam-osx-prod.sample and steam-helper-prod.sample
// captured the producer in MacWSSteamSemOpen->flock and the consumer in
// MacWSSteamSemWait->flock for every sample, although each critical section is
// only one pread/pwrite. Retain flock as the cross-process mutual-exclusion
// predicate, but never enter its broken blocking wake path.
static int MacWSSteamFlockExclusive(int descriptor) {
    uint64_t retries = 0;
    for (;;) {
        if (flock(descriptor, LOCK_EX | LOCK_NB) == 0) return 0;
        if (errno != EWOULDBLOCK && errno != EAGAIN) return -1;
        retries++;
        bool report = retries <= 8 || (retries & (retries - 1)) == 0;
        if (report && getenv("MACWS_STEAM_SEM_DIAGNOSTICS")) {
            char path[PATH_MAX] = {0};
            if (fcntl(descriptor, F_GETPATH, path) != 0)
                strlcpy(path, "<unknown>", sizeof(path));
            struct stat status = {0};
            (void)fstat(descriptor, &status);
            dprintf(STDERR_FILENO,
                    "[MacWSSteamFlock] pid=%d program=%s fd=%d "
                    "dev=%llu inode=%llu retries=%llu path=%s\n",
                    getpid(), getprogname() ?: "?", descriptor,
                    (unsigned long long)status.st_dev,
                    (unsigned long long)status.st_ino,
                    (unsigned long long)retries, path);
        }
        // flock release does not generate an architectural event for a WFE
        // waiter.  Use the measured-good absolute Mach deadline so this
        // predicate is rechecked even when no unrelated interrupt arrives.
        (void)MacWSSteamRelativeDelay(250);
    }
}

static void MacWSSteamRecordUnlinkReceipt(const char *name,
                                           uint64_t generation) {
    uint64_t now = MacWSSteamMonotonicNanoseconds();
    uint64_t threadID = MacWSSteamCurrentThreadID();
    pthread_mutex_lock(&gMacWSSteamUnlinkReceiptsLock);
    size_t selected = MACWS_STEAM_UNLINK_RECEIPT_CAPACITY;
    uint64_t oldest = UINT64_MAX;
    for (size_t index = 0;
         index < MACWS_STEAM_UNLINK_RECEIPT_CAPACITY; index++) {
        MacWSSteamUnlinkReceipt *receipt =
            &gMacWSSteamUnlinkReceipts[index];
        if (receipt->generation != 0 && receipt->threadID == threadID &&
            !strcmp(receipt->name, name)) {
            selected = index;
            break;
        }
        if (receipt->generation == 0) {
            selected = index;
            break;
        }
        if (receipt->createdAt < oldest) {
            oldest = receipt->createdAt;
            selected = index;
        }
    }
    if (selected < MACWS_STEAM_UNLINK_RECEIPT_CAPACITY) {
        MacWSSteamUnlinkReceipt *receipt =
            &gMacWSSteamUnlinkReceipts[selected];
        memset(receipt, 0, sizeof(*receipt));
        receipt->generation = generation;
        receipt->threadID = threadID;
        receipt->createdAt = now;
        strlcpy(receipt->name, name, sizeof(receipt->name));
    }
    pthread_mutex_unlock(&gMacWSSteamUnlinkReceiptsLock);
}

static uint64_t MacWSSteamConsumeUnlinkReceipt(const char *name) {
    uint64_t now = MacWSSteamMonotonicNanoseconds();
    uint64_t threadID = MacWSSteamCurrentThreadID();
    uint64_t generation = 0;
    pthread_mutex_lock(&gMacWSSteamUnlinkReceiptsLock);
    for (size_t index = 0;
         index < MACWS_STEAM_UNLINK_RECEIPT_CAPACITY; index++) {
        MacWSSteamUnlinkReceipt *receipt =
            &gMacWSSteamUnlinkReceipts[index];
        if (receipt->generation == 0 || receipt->threadID != threadID ||
            strcmp(receipt->name, name)) continue;
        if (now != 0 && receipt->createdAt != 0 &&
            now >= receipt->createdAt &&
            now - receipt->createdAt <=
                MACWS_STEAM_UNLINK_RECEIPT_LIFETIME_NS)
            generation = receipt->generation;
        memset(receipt, 0, sizeof(*receipt));
        break;
    }
    pthread_mutex_unlock(&gMacWSSteamUnlinkReceiptsLock);
    return generation;
}

static bool MacWSIsSteamNamedSemaphore(const char *name) {
    if (!name || !MacWSIsSteamProcess()) return false;
    return strncmp(name, "/BSem/", 6) == 0 ||
        strncmp(name, "/Evt/", 5) == 0 ||
        strncmp(name, "/MTX/", 5) == 0;
}

static uint64_t MacWSSteamSemaphoreHash(const char *name) {
    uint64_t hash = UINT64_C(1469598103934665603);
    for (const unsigned char *cursor = (const unsigned char *)name;
         *cursor; cursor++) {
        hash ^= *cursor;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static void MacWSSteamSemaphorePath(const char *name, uint64_t generation,
                                    char *path, size_t pathSize) {
    snprintf(path, pathSize, "/tmp/.macws-steam-sem-%016llx-%016llx",
             (unsigned long long)MacWSSteamSemaphoreHash(name),
             (unsigned long long)generation);
}

static int MacWSSteamSemaphoreReadState(
        int descriptor, MacWSSteamSemaphoreState *state) {
    ssize_t amount = pread(descriptor, state, sizeof(*state), 0);
    if (amount != (ssize_t)sizeof(*state) ||
        state->magic != MACWS_STEAM_SEM_STATE_MAGIC ||
        state->version != MACWS_STEAM_SEM_STATE_VERSION ||
        state->waiterCount > MACWS_STEAM_SEM_WAITER_CAPACITY) {
        errno = EINVAL;
        return -1;
    }
    return 0;
}

static int MacWSSteamSemaphoreWriteState(
        int descriptor, MacWSSteamSemaphoreState *state) {
    if (!state || state->revision == UINT32_MAX) {
        errno = state ? EOVERFLOW : EINVAL;
        return -1;
    }
    state->revision++;
    ssize_t amount = pwrite(descriptor, state, sizeof(*state), 0);
    if (amount == (ssize_t)sizeof(*state)) return 0;
    if (amount >= 0) errno = EIO;
    return -1;
}

// Darwin's POSIX-shm namespace survives the crashing process which created an
// object. Steam's launcher cleans its filesystem endpoints, but shm_open names
// such as /Shm/9b59e709 are not filesystem paths. Runtime diagnostics captured
// the first reference to that exact name in a new steam_osx process returning
// EEXIST, followed by a successful non-exclusive open of a 16 KiB stale
// object. chromehtml then asserted at chrome_ipc_client.cpp:1285 because its
// random response stream was not the creator. Other names (for example
// /Shm/c9edbd50) were first created successfully in the current launch and
// only returned EEXIST when legitimately reopened, so a blanket unlink on
// EEXIST would corrupt the live IPC graph.
//
// Keep an epoch-scoped manifest in the ordinary filesystem. The first Steam
// process for a launch unlinks only the prior epoch's recorded POSIX-shm
// objects. During the one-time migration from builds without a manifest, an
// exclusive-create EEXIST name absent from the current epoch is also known to
// be stale and is reclaimed once. The manifest flock spans classify, reclaim,
// create and record, so another Steam process cannot mistake a live object for
// stale state.
#define MACWS_STEAM_SHM_MANIFEST_PATH \
    "/tmp/.macws-steam-shm-manifest-v1"
#define MACWS_STEAM_SHM_MANIFEST_LIMIT (256u * 1024u)

static bool MacWSIsSteamSharedMemoryName(const char *name) {
    return name && MacWSIsSteamProcess() &&
        strncmp(name, "/Shm/", 5) == 0 &&
        name[5] != '\0' && strlen(name) < 112;
}

static bool MacWSSteamShmManifestContains(const char *contents,
                                           const char *name) {
    if (!contents || !name) return false;
    size_t nameLength = strlen(name);
    const char *cursor = strchr(contents, '\n');
    if (!cursor) return false;
    cursor++;
    while (*cursor) {
        const char *end = strchr(cursor, '\n');
        size_t length = end ? (size_t)(end - cursor) : strlen(cursor);
        if (length == nameLength && !memcmp(cursor, name, length)) return true;
        if (!end) break;
        cursor = end + 1;
    }
    return false;
}

static int MacWSSteamShmManifestLockCurrent(
        const char *name, int *manifestDescriptor, bool *currentObject) {
    *manifestDescriptor = -1;
    *currentObject = false;
    const char *epoch = getenv("MACWS_STEAM_LAUNCH_EPOCH");
    if (!epoch || !epoch[0]) {
        errno = EINVAL;
        return -1;
    }
    uint64_t epochHash = MacWSSteamSemaphoreHash(epoch);
    char expectedHeader[40] = {0};
    int headerLength = snprintf(expectedHeader, sizeof(expectedHeader),
        "epoch=%016llx\n", (unsigned long long)epochHash);
    if (headerLength <= 0 || (size_t)headerLength >= sizeof(expectedHeader)) {
        errno = EINVAL;
        return -1;
    }

    int descriptor = open(MACWS_STEAM_SHM_MANIFEST_PATH,
        O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (descriptor < 0) return -1;
    if (MacWSSteamFlockExclusive(descriptor) != 0) {
        int savedError = errno;
        close(descriptor);
        errno = savedError;
        return -1;
    }

    struct stat status = {0};
    if (fstat(descriptor, &status) != 0 || status.st_size < 0 ||
        (uint64_t)status.st_size > MACWS_STEAM_SHM_MANIFEST_LIMIT) {
        status.st_size = 0;
    }
    size_t contentsSize = (size_t)status.st_size;
    char *contents = calloc(contentsSize + 1, 1);
    if (!contents) {
        int savedError = errno ?: ENOMEM;
        (void)flock(descriptor, LOCK_UN);
        close(descriptor);
        errno = savedError;
        return -1;
    }
    ssize_t amount = contentsSize ?
        pread(descriptor, contents, contentsSize, 0) : 0;
    if (amount < 0) amount = 0;
    contents[(size_t)amount] = '\0';

    bool sameEpoch = !strncmp(contents, expectedHeader,
                              (size_t)headerLength);
    if (!sameEpoch) {
        // Every data line was produced by this module after strict /Shm/
        // validation. Ignore malformed lines rather than widening cleanup.
        char *cursor = strchr(contents, '\n');
        if (cursor) cursor++;
        while (cursor && *cursor) {
            char *end = strchr(cursor, '\n');
            if (end) *end = '\0';
            if (!strncmp(cursor, "/Shm/", 5) && cursor[5] &&
                strlen(cursor) < 112) {
                (void)shm_unlink(cursor);
            }
            cursor = end ? end + 1 : NULL;
        }
        if (ftruncate(descriptor, 0) != 0 ||
            pwrite(descriptor, expectedHeader, (size_t)headerLength, 0) !=
                headerLength) {
            int savedError = errno ?: EIO;
            free(contents);
            (void)flock(descriptor, LOCK_UN);
            close(descriptor);
            errno = savedError;
            return -1;
        }
    } else {
        *currentObject = MacWSSteamShmManifestContains(contents, name);
    }
    free(contents);
    *manifestDescriptor = descriptor;
    return 0;
}

static int MacWSSteamShmManifestRecordLocked(int descriptor,
                                              const char *name) {
    char line[116] = {0};
    int lineLength = snprintf(line, sizeof(line), "%s\n", name);
    if (lineLength <= 0 || (size_t)lineLength >= sizeof(line)) {
        errno = EINVAL;
        return -1;
    }
    off_t end = lseek(descriptor, 0, SEEK_END);
    if (end < 0 || (uint64_t)end + (size_t)lineLength >
        MACWS_STEAM_SHM_MANIFEST_LIMIT) {
        errno = end < 0 ? errno : ENOSPC;
        return -1;
    }
    ssize_t amount = write(descriptor, line, (size_t)lineLength);
    if (amount != lineLength) {
        if (amount >= 0) errno = EIO;
        return -1;
    }
    return 0;
}

static void MacWSSteamSemaphoreDiagnose(const char *operation,
                                        const char *name, int result,
                                        unsigned value,
                                        const MacWSSteamSemaphoreHandle *handle) {
    if (!getenv("MACWS_STEAM_SEM_DIAGNOSTICS") ||
        __sync_fetch_and_add(&gMacWSSteamSemaphoreDiagnosticCount, 1) >=
            400) return;
    dprintf(STDERR_FILENO,
            "[MacWSSteamSem] pid=%d program=%s op=%s name=%s "
            "result=%d errno=%d value=%u handle=%p "
            "generation=%llu\n",
            getpid(), getprogname() ?: "?", operation, name ?: "?",
            result, result == 0 ? 0 : errno, value, handle,
            handle ? (unsigned long long)handle->brokerGeneration : 0);
}

static void MacWSSteamSemaphoreDiagnoseCaller(
        const char *operation, const MacWSSteamSemaphoreHandle *handle,
        void *caller) {
    const char *focus = getenv("MACWS_STEAM_SEM_CALLER_DIAGNOSTICS");
    if (!focus || !focus[0] || !handle || !caller ||
        !strstr(handle->name, focus)) return;
    Dl_info image = {0};
    dladdr(caller, &image);
    dprintf(STDERR_FILENO,
            "[MacWSSteamSemCaller] pid=%d program=%s op=%s name=%s "
            "generation=%llu caller=%p image=%s offset=%#llx\n",
            getpid(), getprogname() ?: "?", operation, handle->name,
            (unsigned long long)handle->brokerGeneration,
            caller, image.dli_fname ?: "?",
            image.dli_fbase ? (unsigned long long)(
                (uintptr_t)caller - (uintptr_t)image.dli_fbase) : 0);
    void *frames[10] = {0};
    int frameCount = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
    for (int index = 1; index < frameCount; index++) {
        Dl_info frameImage = {0};
        dladdr(frames[index], &frameImage);
        dprintf(STDERR_FILENO,
                "[MacWSSteamSemCaller] frame=%d address=%p image=%s "
                "offset=%#llx\n",
                index, frames[index], frameImage.dli_fname ?: "?",
                frameImage.dli_fbase ? (unsigned long long)(
                    (uintptr_t)frames[index] -
                    (uintptr_t)frameImage.dli_fbase) : 0);
    }
}

static xpc_object_t MacWSSteamSemaphoreBrokerRequest(
        const char *operation, const char *name, int flags, unsigned value,
        uint64_t generation) {
    // Runtime-confirmed on Steam Helper 1785799196: a retained connection
    // delivered the first WAIT_POLL request but every later synchronous call
    // returned the first value=0 dictionary without another request reaching
    // hostd. A one-shot connection reliably delivers each request. The blocking
    // caller below rate-limits empty polls, preventing the bootstrap lookup
    // storm seen with the earlier sched_yield busy loop.
    bool pollRequest = !strcmp(operation, MACWS_STEAM_SEM_OP_WAIT_POLL) ||
        !strcmp(operation, MACWS_STEAM_SEM_OP_GETVALUE) ||
        !strcmp(operation, MACWS_STEAM_SEM_OP_TRYWAIT);
    xpc_connection_t connection = MacWSXPCConnectionCreateMachServiceRaw(
        MACWS_CONTROL_SERVICE,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), 0);
    if (!connection) {
        errno = ENOTCONN;
        return NULL;
    }
    xpc_connection_set_event_handler(connection,
        ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_OP, operation);
    if (name)
        xpc_dictionary_set_string(request, MACWS_STEAM_SEM_KEY_NAME, name);
    xpc_dictionary_set_int64(request, MACWS_STEAM_SEM_KEY_FLAGS, flags);
    xpc_dictionary_set_uint64(request, MACWS_STEAM_SEM_KEY_VALUE, value);
    xpc_dictionary_set_uint64(request, MACWS_STEAM_SEM_KEY_GENERATION,
                              generation);
    if (pollRequest) {
        uint64_t threadID = 0;
        if (pthread_threadid_np(NULL, &threadID) != 0) threadID = 1;
        uint64_t waiter = ((uint64_t)(uint32_t)getpid() << 32) |
            (threadID & UINT64_C(0xffffffff));
        xpc_dictionary_set_uint64(request, MACWS_STEAM_SEM_KEY_WAITER,
                                  waiter ?: 1);
    }
    const char *epoch = getenv("MACWS_STEAM_LAUNCH_EPOCH");
    if (epoch && epoch[0])
        xpc_dictionary_set_string(request, MACWS_STEAM_SEM_KEY_EPOCH, epoch);
    if (getenv("MACWS_STEAM_SEM_DIAGNOSTICS") &&
        strcmp(operation, MACWS_STEAM_SEM_OP_DELAY) != 0)
        xpc_dictionary_set_bool(request,
            MACWS_STEAM_SEM_KEY_DIAGNOSTICS, true);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
        connection, request);
    xpc_release(request);
    xpc_connection_cancel(connection);
    xpc_release(connection);
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        if (reply) xpc_release(reply);
        errno = ENOTCONN;
        return NULL;
    }
    int brokerError = (int)xpc_dictionary_get_int64(
        reply, MACWS_STEAM_SEM_KEY_ERROR);
    if (brokerError != 0) {
        if (getenv("MACWS_STEAM_SEM_DIAGNOSTICS") &&
            brokerError != EAGAIN) {
            dprintf(STDERR_FILENO,
                    "[MacWSSteamSemBroker] pid=%d program=%s op=%s "
                    "name=%s flags=%#x value=%u generation=%llu "
                    "error=%d\n",
                    getpid(), getprogname() ?: "?", operation ?: "?",
                    name ?: "?", flags, value,
                    (unsigned long long)generation, brokerError);
        }
        xpc_release(reply);
        errno = brokerError;
        return NULL;
    }
    return reply;
}

static void MacWSSteamSemaphoreResetBroker(void) {
    const char *epoch = getenv("MACWS_STEAM_LAUNCH_EPOCH");
    if (!epoch || !epoch[0]) return;
    xpc_object_t reply = MacWSSteamSemaphoreBrokerRequest(
        MACWS_STEAM_SEM_OP_RESET, NULL, 0, 0, 0);
    if (!reply) {
        gMacWSSteamBrokerResetError = errno ?: ENOTCONN;
        return;
    }
    xpc_release(reply);
}

static int MacWSSteamSemaphoreBrokerOpen(
        const char *name, int flags, unsigned value,
        uint64_t unlinkedGeneration, uint64_t *generation, bool *created) {
    pthread_once(&gMacWSSteamBrokerResetOnce,
                 MacWSSteamSemaphoreResetBroker);
    if (gMacWSSteamBrokerResetError) {
        errno = gMacWSSteamBrokerResetError;
        return -1;
    }
    const char *operation = unlinkedGeneration != 0 ?
        MACWS_STEAM_SEM_OP_RECREATE : MACWS_STEAM_SEM_OP_OPEN;
    xpc_object_t reply = MacWSSteamSemaphoreBrokerRequest(
        operation, name, flags, value, unlinkedGeneration);
    if (!reply) return -1;
    uint64_t copiedGeneration = xpc_dictionary_get_uint64(
        reply, MACWS_STEAM_SEM_KEY_GENERATION);
    bool copiedCreated = xpc_dictionary_get_bool(
        reply, MACWS_STEAM_SEM_KEY_CREATED);
    if (getenv("MACWS_STEAM_SEM_DIAGNOSTICS"))
        dprintf(STDERR_FILENO,
                "[MacWSSteamSemBroker] pid=%d program=%s op=%s-reply "
                "name=%s generation=%llu created=%d receipt=%llu\n",
                getpid(), getprogname() ?: "?", operation, name ?: "?",
                (unsigned long long)copiedGeneration, copiedCreated,
                (unsigned long long)unlinkedGeneration);
    xpc_release(reply);
    if (copiedGeneration == 0) {
        errno = EIO;
        return -1;
    }
    *generation = copiedGeneration;
    if (created) *created = copiedCreated;
    return 0;
}

static int MacWSSteamSemaphoreBrokerUnlink(const char *name,
                                            uint64_t *generation) {
    xpc_object_t reply = MacWSSteamSemaphoreBrokerRequest(
        MACWS_STEAM_SEM_OP_UNLINK, name, 0, 0, 0);
    if (!reply) return -1;
    uint64_t copiedGeneration = xpc_dictionary_get_uint64(
        reply, MACWS_STEAM_SEM_KEY_GENERATION);
    xpc_release(reply);
    if (copiedGeneration == 0) {
        errno = EIO;
        return -1;
    }
    *generation = copiedGeneration;
    return 0;
}

static int MacWSSteamSemaphoreBrokerSimple(const char *operation,
                                            const char *name,
                                            uint64_t generation) {
    xpc_object_t reply = MacWSSteamSemaphoreBrokerRequest(
        operation, name, 0, 0, generation);
    if (!reply) return -1;
    xpc_release(reply);
    return 0;
}

static int MacWSSteamSemaphoreBrokerSocketValue(uint32_t operation,
                                                uint64_t generation,
                                                unsigned *value);

static int MacWSSteamWriteAll(int descriptor, const void *bytes,
                              size_t length) {
    const uint8_t *cursor = bytes;
    while (length != 0) {
        ssize_t amount = write(descriptor, cursor, length);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) {
            if (amount == 0) errno = EPIPE;
            return -1;
        }
        cursor += (size_t)amount;
        length -= (size_t)amount;
    }
    return 0;
}

static int MacWSSteamReadAll(int descriptor, int retainedQueue,
                             bool *retainedRegistered,
                             void *bytes, size_t length) {
    uint8_t *cursor = bytes;
    bool ownsQueue = retainedQueue < 0;
    int queue = ownsQueue ? kqueue() : retainedQueue;
    if (queue < 0) return -1;
    struct kevent change = {0};
    EV_SET(&change, descriptor, EVFILT_READ, EV_ADD | EV_ENABLE,
           0, 0, NULL);
    bool registered = retainedRegistered && *retainedRegistered;
    while (length != 0) {
        ssize_t amount = recv(descriptor, cursor, length, MSG_DONTWAIT);
        if (amount < 0 && errno == EINTR) continue;
        if (amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // Runtime-confirmed by steam_kevent_wake_probe on the real iPad:
            // a direct blocking read can miss a cross-runtime socket wake,
            // while EVFILT_READ returned exactly once 1.005181 s after an
            // iOS-native writer made this same AF_UNIX stream readable. CEF's
            // own service threads also rely on this kernel readiness path.
            // Block here instead of generating 500-us deadline wakeups.
            struct kevent event = {0};
            int eventCount = kevent(queue,
                registered ? NULL : &change,
                registered ? 0 : 1, &event, 1, NULL);
            if (eventCount < 0 && errno == EINTR) continue;
            if (eventCount != 1) {
                int savedError = errno ?: EIO;
                if (ownsQueue) close(queue);
                errno = savedError;
                return -1;
            }
            registered = true;
            if (retainedRegistered) *retainedRegistered = true;
            if (event.flags & EV_ERROR) {
                int savedError = event.data ? (int)event.data : EIO;
                if (ownsQueue) close(queue);
                errno = savedError;
                return -1;
            }
            continue;
        }
        if (amount <= 0) {
            if (amount == 0) errno = ECONNRESET;
            int savedError = errno;
            if (ownsQueue) close(queue);
            errno = savedError;
            return -1;
        }
        cursor += (size_t)amount;
        length -= (size_t)amount;
    }
    if (ownsQueue) close(queue);
    return 0;
}

static int MacWSSteamConnectValueSocket(void) {
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    int enabled = 1;
    (void)setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                     &enabled, sizeof(enabled));

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, MACWS_STEAM_SEM_WAIT_SOCKET_PATH,
            sizeof(address.sun_path));
    if (connect(descriptor, (const struct sockaddr *)&address,
                sizeof(address)) != 0) {
        int savedError = errno;
        close(descriptor);
        errno = savedError;
        return -1;
    }
    return descriptor;
}

static void MacWSSteamResetThreadValueSocket(void) {
    if (gMacWSSteamValueKqueue >= 0) close(gMacWSSteamValueKqueue);
    if (gMacWSSteamValueSocket >= 0) close(gMacWSSteamValueSocket);
    gMacWSSteamValueKqueue = -1;
    gMacWSSteamValueSocket = -1;
    gMacWSSteamValueKqueueRegistered = false;
    gMacWSSteamValueSocketPID = 0;
}

static int MacWSSteamSemaphoreBrokerSocketValueImpl(uint32_t operation,
                                                    uint64_t generation,
                                                    unsigned *value,
                                                    uint32_t timeoutMicroseconds) {
    bool persistent = operation != MACWS_STEAM_SEM_SOCKET_WAIT_BLOCK &&
        operation != MACWS_STEAM_SEM_SOCKET_WAIT_TIMED;
    pid_t process = getpid();
    int descriptor = -1;
    if (persistent) {
        // A fork inherits the descriptor number but not a valid per-thread
        // request stream identity. Never let child and parent interleave
        // envelopes on the same connection.
        if (gMacWSSteamValueSocketPID != process)
            MacWSSteamResetThreadValueSocket();
        if (gMacWSSteamValueSocket < 0) {
            gMacWSSteamValueSocket = MacWSSteamConnectValueSocket();
            if (gMacWSSteamValueSocket < 0) return -1;
            gMacWSSteamValueKqueue = kqueue();
            if (gMacWSSteamValueKqueue < 0) {
                int savedError = errno;
                MacWSSteamResetThreadValueSocket();
                errno = savedError;
                return -1;
            }
            gMacWSSteamValueSocketPID = process;
        }
        descriptor = gMacWSSteamValueSocket;
    } else {
        descriptor = MacWSSteamConnectValueSocket();
        if (descriptor < 0) return -1;
    }

    MacWSSteamSemaphoreWaitRequest request = {
        .magic = MACWS_STEAM_SEM_WAIT_MAGIC,
        .version = MACWS_STEAM_SEM_VERSION,
        .operation = operation,
        .reserved = getenv("MACWS_STEAM_SEM_DIAGNOSTICS") ?
            MACWS_STEAM_SEM_SOCKET_FLAG_DIAGNOSTICS : 0,
        .generation = generation,
        .timeoutMicroseconds = timeoutMicroseconds,
    };
    uint64_t threadID = 0;
    if (pthread_threadid_np(NULL, &threadID) != 0) threadID = 1;
    request.waiter = ((uint64_t)(uint32_t)getpid() << 32) |
        (threadID & UINT64_C(0xffffffff));
    request.requestID = ((uint64_t)(uint32_t)getpid() << 32) |
        (atomic_fetch_add_explicit(&gMacWSSteamSocketRequestID, 1,
                                   memory_order_relaxed) + 1);
    MacWSSteamSemaphoreWaitReply reply = {0};
    if (MacWSSteamWriteAll(descriptor, &request, sizeof(request)) != 0 ||
        MacWSSteamReadAll(
            descriptor,
            persistent ? gMacWSSteamValueKqueue : -1,
            persistent ? &gMacWSSteamValueKqueueRegistered : NULL,
            &reply, sizeof(reply)) != 0) {
        int savedError = errno;
        if (persistent)
            MacWSSteamResetThreadValueSocket();
        else
            close(descriptor);
        errno = savedError;
        return -1;
    }
    if (!persistent) close(descriptor);
    if (reply.magic != MACWS_STEAM_SEM_WAIT_MAGIC ||
        reply.version != MACWS_STEAM_SEM_VERSION ||
        reply.generation != generation ||
        reply.requestID != request.requestID) {
        if (getenv("MACWS_STEAM_SEM_DIAGNOSTICS"))
            dprintf(STDERR_FILENO,
                    "[MacWSSteamSemSocket] pid=%d program=%s "
                    "envelope-mismatch op=%u request_id=%llu "
                    "request_generation=%llu reply_magic=%#x "
                    "reply_version=%u reply_error=%d reply_value=%u "
                    "reply_generation=%llu reply_id=%llu\n",
                    getpid(), getprogname() ?: "?", operation,
                    (unsigned long long)request.requestID,
                    (unsigned long long)generation, reply.magic,
                    reply.version, reply.error, reply.value,
                    (unsigned long long)reply.generation,
                    (unsigned long long)reply.requestID);
        errno = EPROTO;
        return -1;
    }
    if (reply.error != 0) {
        if (reply.error != EAGAIN &&
            getenv("MACWS_STEAM_SEM_DIAGNOSTICS"))
            dprintf(STDERR_FILENO,
                    "[MacWSSteamSemSocket] pid=%d program=%s "
                    "broker-error op=%u request_id=%llu generation=%llu "
                    "error=%d value=%u\n",
                    getpid(), getprogname() ?: "?", operation,
                    (unsigned long long)request.requestID,
                    (unsigned long long)generation, reply.error,
                    reply.value);
        errno = reply.error;
        return -1;
    }
    if (reply.value > MACWS_STEAM_SEM_VALUE_MAX) {
        errno = EPROTO;
        return -1;
    }
    if (value) *value = reply.value;
    return 0;
}

static void MacWSSteamSemaphoreReportSocketTiming(uint32_t operation,
                                                  uint64_t startedAt,
                                                  int result,
                                                  int resultError) {
    if (startedAt == 0) return;
    uint64_t finishedAt = MacWSSteamMonotonicNanoseconds();
    if (finishedAt < startedAt) return;
    uint64_t elapsed = finishedAt - startedAt;
    uint64_t expectedFirst = 0;
    (void)atomic_compare_exchange_strong_explicit(
        &gMacWSSteamSocketTimingFirstNanoseconds, &expectedFirst,
        startedAt, memory_order_relaxed, memory_order_relaxed);
    uint64_t calls = atomic_fetch_add_explicit(
        &gMacWSSteamSocketTimingCalls, 1, memory_order_relaxed) + 1;
    atomic_fetch_add_explicit(&gMacWSSteamSocketTimingNanoseconds,
                              elapsed, memory_order_relaxed);
    if (result != 0) {
        atomic_fetch_add_explicit(&gMacWSSteamSocketTimingFailures, 1,
                                  memory_order_relaxed);
        if (resultError == EAGAIN)
            atomic_fetch_add_explicit(&gMacWSSteamSocketTimingEagain, 1,
                                      memory_order_relaxed);
    }
    if (operation < 7) {
        atomic_fetch_add_explicit(
            &gMacWSSteamSocketTimingOperationCalls[operation], 1,
            memory_order_relaxed);
        atomic_fetch_add_explicit(
            &gMacWSSteamSocketTimingOperationNanoseconds[operation],
            elapsed, memory_order_relaxed);
    }
    if (calls % 100 != 0) return;

    uint64_t first = atomic_load_explicit(
        &gMacWSSteamSocketTimingFirstNanoseconds, memory_order_relaxed);
    uint64_t wall = finishedAt > first ? finishedAt - first : 0;
    uint64_t total = atomic_load_explicit(
        &gMacWSSteamSocketTimingNanoseconds, memory_order_relaxed);
    uint64_t failures = atomic_load_explicit(
        &gMacWSSteamSocketTimingFailures, memory_order_relaxed);
    uint64_t eagain = atomic_load_explicit(
        &gMacWSSteamSocketTimingEagain, memory_order_relaxed);
    uint64_t trywaitCalls = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationCalls[
            MACWS_STEAM_SEM_SOCKET_TRYWAIT], memory_order_relaxed);
    uint64_t trywaitTime = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationNanoseconds[
            MACWS_STEAM_SEM_SOCKET_TRYWAIT], memory_order_relaxed);
    uint64_t postCalls = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationCalls[
            MACWS_STEAM_SEM_SOCKET_POST], memory_order_relaxed);
    uint64_t postTime = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationNanoseconds[
            MACWS_STEAM_SEM_SOCKET_POST], memory_order_relaxed);
    uint64_t getvalueCalls = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationCalls[
            MACWS_STEAM_SEM_SOCKET_GETVALUE], memory_order_relaxed);
    uint64_t getvalueTime = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationNanoseconds[
            MACWS_STEAM_SEM_SOCKET_GETVALUE], memory_order_relaxed);
    uint64_t waitCalls = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationCalls[
            MACWS_STEAM_SEM_SOCKET_WAIT_BLOCK], memory_order_relaxed);
    uint64_t waitTime = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationNanoseconds[
            MACWS_STEAM_SEM_SOCKET_WAIT_BLOCK], memory_order_relaxed);
    uint64_t timedWaitCalls = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationCalls[
            MACWS_STEAM_SEM_SOCKET_WAIT_TIMED], memory_order_relaxed);
    uint64_t timedWaitTime = atomic_load_explicit(
        &gMacWSSteamSocketTimingOperationNanoseconds[
            MACWS_STEAM_SEM_SOCKET_WAIT_TIMED], memory_order_relaxed);
    dprintf(STDERR_FILENO,
            "[MacWSSteamSemTiming] pid=%d program=%s calls=%llu "
            "wall_ms=%.3f calls_per_s=%.3f rpc_ms=%.3f avg_us=%.3f "
            "failures=%llu eagain=%llu trywait=%llu/%.3fms "
            "post=%llu/%.3fms getvalue=%llu/%.3fms wait=%llu/%.3fms "
            "timed=%llu/%.3fms\n",
            getpid(), getprogname() ?: "?", (unsigned long long)calls,
            (double)wall / 1000000.0,
            wall ? (double)calls * 1000000000.0 / (double)wall : 0.0,
            (double)total / 1000000.0,
            calls ? (double)total / (double)calls / 1000.0 : 0.0,
            (unsigned long long)failures, (unsigned long long)eagain,
            (unsigned long long)trywaitCalls,
            (double)trywaitTime / 1000000.0,
            (unsigned long long)postCalls,
            (double)postTime / 1000000.0,
            (unsigned long long)getvalueCalls,
            (double)getvalueTime / 1000000.0,
            (unsigned long long)waitCalls,
            (double)waitTime / 1000000.0,
            (unsigned long long)timedWaitCalls,
            (double)timedWaitTime / 1000000.0);
}

static int MacWSSteamSemaphoreBrokerSocketValue(uint32_t operation,
                                                uint64_t generation,
                                                unsigned *value) {
    uint64_t startedAt = getenv("MACWS_STEAM_SEM_TIMING_DIAGNOSTICS") ?
        MacWSSteamMonotonicNanoseconds() : 0;
    int result = MacWSSteamSemaphoreBrokerSocketValueImpl(
        operation, generation, value, 0);
    int resultError = errno;
    MacWSSteamSemaphoreReportSocketTiming(
        operation, startedAt, result, resultError);
    errno = resultError;
    return result;
}

static int MacWSSteamSemaphoreBrokerSocketTimedWait(
        uint64_t generation, uint32_t timeoutMicroseconds) {
    uint64_t startedAt = getenv("MACWS_STEAM_SEM_TIMING_DIAGNOSTICS") ?
        MacWSSteamMonotonicNanoseconds() : 0;
    unsigned value = 0;
    int result = MacWSSteamSemaphoreBrokerSocketValueImpl(
        MACWS_STEAM_SEM_SOCKET_WAIT_TIMED, generation, &value,
        timeoutMicroseconds);
    int resultError = errno;
    MacWSSteamSemaphoreReportSocketTiming(
        MACWS_STEAM_SEM_SOCKET_WAIT_TIMED, startedAt, result, resultError);
    errno = resultError;
    return result;
}

// Timed waits entered from this macOS CEF image do not receive their timeout
// from the iOS kernel. Runtime LLDB confirmed the real Helper stuck forever in
// nanosleep, EVFILT_TIMER/kevent and syscall_thread_switch WAIT, for both the
// browser IPC thread's 1 ms wait and the gamepad thread's 10 ms wait. Moving
// the sleep into iOS-native hostd also failed: two samples retained the same
// XPC reply receive names while hostd itself remained in
// usleep->__semwait_signal. Repeated one-shot XPC deadlines are not viable
// either: a runtime sample of steam_osx found HTMLController Commands stuck in
// xpc_connection_send_message_with_reply_sync after only a few successful
// calls, preventing the producer from reaching its CSharedMemStream post.
//
// A CLOCK_MONOTONIC + WFE deadline did preserve elapsed time, but runtime
// sample steam-osx-nbflock.sample attributed 604/749 main-thread samples and
// ~100% CPU to Valve's sem_trywait + 1 ms usleep loop: WFE returned too often
// to be a useful sleep primitive on that thread. A dispatch timer plus a
// process-private condition consumed no CPU but its macOS psynch waiter did
// not resume. mach_wait_until is the one measured kernel deadline primitive
// that does work in this mixed runtime: on-device steam_machwait_probe asked
// for 2 ms with timebase 125/3 and returned KERN_SUCCESS after 60173 ticks
// (2.507 ms). Use that absolute monotonic deadline directly.
static pthread_once_t gMacWSSteamTimebaseOnce = PTHREAD_ONCE_INIT;
static mach_timebase_info_data_t gMacWSSteamTimebase;

static void MacWSSteamInitializeTimebase(void) {
    (void)mach_timebase_info(&gMacWSSteamTimebase);
}

static int MacWSSteamRelativeDelay(useconds_t microseconds) {
    if (microseconds == 0) return 0;
    pthread_once(&gMacWSSteamTimebaseOnce, MacWSSteamInitializeTimebase);
    if (gMacWSSteamTimebase.numer == 0 ||
        gMacWSSteamTimebase.denom == 0) {
        errno = EIO;
        return -1;
    }

    uint64_t nanoseconds = (uint64_t)microseconds * UINT64_C(1000);
    __uint128_t scaled = (__uint128_t)nanoseconds *
        gMacWSSteamTimebase.denom + gMacWSSteamTimebase.numer - 1;
    uint64_t interval = (uint64_t)(scaled / gMacWSSteamTimebase.numer);
    if (interval == 0) interval = 1;
    uint64_t now = mach_absolute_time();
    uint64_t deadline = UINT64_MAX - now < interval ?
        UINT64_MAX : now + interval;
    kern_return_t result = mach_wait_until(deadline);
    if (result == KERN_SUCCESS) return 0;
    errno = result == KERN_ABORTED ? EINTR : EIO;
    return -1;
}

static MacWSSteamSemaphoreHandle *MacWSSteamSemaphoreFind(
        sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *result = NULL;
    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    for (MacWSSteamSemaphoreHandle *candidate =
             gMacWSSteamSemaphoreHandles;
         candidate; candidate = candidate->next) {
        if ((sem_t *)candidate == semaphore &&
            candidate->magic == MACWS_STEAM_SEM_HANDLE_MAGIC) {
            result = candidate;
            break;
        }
    }
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
    return result;
}

static MacWSSteamSemaphoreHandle *MacWSSteamSemaphoreFindReusableLocked(
        const char *name, uint64_t brokerGeneration) {
    for (MacWSSteamSemaphoreHandle *candidate =
             gMacWSSteamSemaphoreHandles;
         candidate; candidate = candidate->next) {
        if (candidate->unlinked || strcmp(candidate->name, name) ||
            candidate->brokerGeneration != brokerGeneration) continue;
        struct stat status = {0};
        if (fstat(candidate->descriptor, &status) != 0 ||
            status.st_nlink == 0) {
            candidate->unlinked = true;
            continue;
        }
        return candidate;
    }
    return NULL;
}

static sem_t *MacWSSteamSemOpen(const char *name, int flags, ...) {
    mode_t mode = 0;
    unsigned value = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        value = va_arg(arguments, unsigned);
        va_end(arguments);
    }
    if (!MacWSIsSteamNamedSemaphore(name)) {
        return (flags & O_CREAT) ? sem_open(name, flags, mode, value) :
            sem_open(name, flags);
    }
    if (strlen(name) >= MACWS_STEAM_SEM_NAME_CAPACITY) {
        errno = ENAMETOOLONG;
        return SEM_FAILED;
    }
    if (value > MACWS_STEAM_SEM_VALUE_MAX) {
        errno = EINVAL;
        return SEM_FAILED;
    }

    uint64_t brokerGeneration = 0;
    bool brokerCreated = false;
    uint64_t unlinkedGeneration =
        (flags & O_CREAT) && (flags & O_EXCL) ?
        MacWSSteamConsumeUnlinkReceipt(name) : 0;
    if (MacWSSteamSemaphoreBrokerOpen(
            name, flags, value, unlinkedGeneration, &brokerGeneration,
            &brokerCreated) != 0)
        return SEM_FAILED;

    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    MacWSSteamSemaphoreHandle *existing =
        MacWSSteamSemaphoreFindReusableLocked(name, brokerGeneration);
    if (existing) existing->referenceCount++;
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
    if (existing) {
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        MacWSSteamSemaphoreDiagnose("reuse", name, 0, 0, existing);
        MacWSSteamSemaphoreDiagnoseCaller(
            "reuse", existing, __builtin_return_address(0));
        return (sem_t *)existing;
    }

    char path[160] = {0};
    MacWSSteamSemaphorePath(name, brokerGeneration, path, sizeof(path));
    int descriptor = open(path, O_RDWR | O_CLOEXEC);
    if (descriptor < 0) {
        int savedError = errno;
        if (brokerCreated)
            (void)MacWSSteamSemaphoreBrokerSimple(
                MACWS_STEAM_SEM_OP_UNLINK, name, 0);
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        errno = savedError;
        return SEM_FAILED;
    }
    if (MacWSSteamFlockExclusive(descriptor) != 0) {
        int savedError = errno;
        close(descriptor);
        if (brokerCreated)
            (void)MacWSSteamSemaphoreBrokerSimple(
                MACWS_STEAM_SEM_OP_UNLINK, name, 0);
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        errno = savedError;
        return SEM_FAILED;
    }
    MacWSSteamSemaphoreState state = {0};
    int stateResult = MacWSSteamSemaphoreReadState(descriptor, &state);
    if (stateResult == 0 &&
        (strcmp(state.name, name) ||
         state.brokerGeneration != brokerGeneration)) {
        errno = EEXIST;
        stateResult = -1;
    }
    int savedError = errno;
    (void)flock(descriptor, LOCK_UN);
    if (stateResult != 0) {
        close(descriptor);
        if (brokerCreated)
            (void)MacWSSteamSemaphoreBrokerSimple(
                MACWS_STEAM_SEM_OP_UNLINK, name, 0);
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        errno = savedError;
        return SEM_FAILED;
    }

    MacWSSteamSemaphoreHandle *handle = calloc(1, sizeof(*handle));
    if (!handle) {
        savedError = errno;
        if (brokerCreated)
            (void)MacWSSteamSemaphoreBrokerSimple(
                MACWS_STEAM_SEM_OP_UNLINK, name, 0);
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        close(descriptor);
        errno = savedError;
        return SEM_FAILED;
    }
    handle->magic = MACWS_STEAM_SEM_HANDLE_MAGIC;
    handle->descriptor = descriptor;
    handle->brokerGeneration = brokerGeneration;
    handle->referenceCount = 1;
    strlcpy(handle->name, name, sizeof(handle->name));

    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    existing = MacWSSteamSemaphoreFindReusableLocked(
        name, brokerGeneration);
    if (existing) {
        existing->referenceCount++;
    } else {
        handle->next = gMacWSSteamSemaphoreHandles;
        gMacWSSteamSemaphoreHandles = handle;
    }
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
    if (existing) {
        (void)MacWSSteamSemaphoreBrokerSimple(
            MACWS_STEAM_SEM_OP_CLOSE, NULL, brokerGeneration);
        close(descriptor);
        free(handle);
        return (sem_t *)existing;
    }

    MacWSSteamSemaphoreDiagnose(brokerCreated ? "create" : "open", name, 0,
                                state.value, handle);
    MacWSSteamSemaphoreDiagnoseCaller(
        brokerCreated ? "create" : "open", handle,
        __builtin_return_address(0));
    return (sem_t *)handle;
}

static int MacWSSteamSemClose(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = NULL;
    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    MacWSSteamSemaphoreHandle **cursor = &gMacWSSteamSemaphoreHandles;
    while (*cursor) {
        if ((sem_t *)*cursor == semaphore &&
            (*cursor)->magic == MACWS_STEAM_SEM_HANDLE_MAGIC) {
            handle = *cursor;
            break;
        }
        cursor = &(*cursor)->next;
    }
    if (!handle) {
        pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
        return sem_close(semaphore);
    }
    if (handle->referenceCount > 1) {
        handle->referenceCount--;
        pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
        return 0;
    }
    if (handle->referenceCount != 1) {
        pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
        errno = EINVAL;
        return -1;
    }
    *cursor = handle->next;
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);

    int brokerResult = MacWSSteamSemaphoreBrokerSimple(
        MACWS_STEAM_SEM_OP_CLOSE, NULL, handle->brokerGeneration);
    int brokerError = errno;
    int descriptorResult = close(handle->descriptor);
    handle->magic = 0;
    free(handle);
    if (brokerResult != 0) {
        errno = brokerError;
        return -1;
    }
    return descriptorResult;
}

static int MacWSSteamSemUnlink(const char *name) {
    if (!MacWSIsSteamNamedSemaphore(name)) return sem_unlink(name);
    uint64_t brokerGeneration = 0;
    if (MacWSSteamSemaphoreBrokerUnlink(name, &brokerGeneration) != 0)
        return -1;
    MacWSSteamRecordUnlinkReceipt(name, brokerGeneration);
    pthread_mutex_lock(&gMacWSSteamSemaphoreHandlesLock);
    for (MacWSSteamSemaphoreHandle *candidate =
             gMacWSSteamSemaphoreHandles;
         candidate; candidate = candidate->next) {
        if (!strcmp(candidate->name, name) &&
            candidate->brokerGeneration == brokerGeneration)
            candidate->unlinked = true;
    }
    pthread_mutex_unlock(&gMacWSSteamSemaphoreHandlesLock);
    MacWSSteamSemaphoreDiagnose("unlink", name, 0, 0, NULL);
    return 0;
}

static int MacWSSteamSemaphoreConsumeKernelTokenInternal(
        MacWSSteamSemaphoreHandle *handle, bool nonblocking) {
    unsigned value = 0;
    uint32_t operation = nonblocking ?
        MACWS_STEAM_SEM_SOCKET_TRYWAIT :
        MACWS_STEAM_SEM_SOCKET_WAIT_BLOCK;
    int result = MacWSSteamSemaphoreBrokerSocketValue(
        operation, handle->brokerGeneration, &value);
    MacWSSteamSemaphoreDiagnose(
        nonblocking ? "trywait" : "wait", handle->name, result, value,
        handle);
    return result;
}

static int MacWSSteamSemaphoreConsumeKernelToken(
        MacWSSteamSemaphoreHandle *handle, bool nonblocking) {
    return MacWSSteamSemaphoreConsumeKernelTokenInternal(
        handle, nonblocking);
}

static int MacWSSteamSemaphoreLockState(
        MacWSSteamSemaphoreHandle *handle,
        MacWSSteamSemaphoreState *state) {
    if (!handle || !state || handle->descriptor < 0) {
        errno = EINVAL;
        return -1;
    }
    if (MacWSSteamFlockExclusive(handle->descriptor) != 0) return -1;
    if (MacWSSteamSemaphoreReadState(handle->descriptor, state) != 0 ||
        state->brokerGeneration != handle->brokerGeneration ||
        strcmp(state->name, handle->name)) {
        int savedError = errno ?: EPROTO;
        (void)flock(handle->descriptor, LOCK_UN);
        errno = savedError;
        return -1;
    }
    return 0;
}

static int MacWSSteamSemaphoreUnlockState(
        MacWSSteamSemaphoreHandle *handle, int result, int resultError) {
    if (flock(handle->descriptor, LOCK_UN) != 0 && result == 0) {
        result = -1;
        resultError = errno ?: EIO;
    }
    errno = resultError;
    return result;
}

static int MacWSSteamSemaphoreLocalTryWait(
        MacWSSteamSemaphoreHandle *handle) {
    MacWSSteamSemaphoreState state = {0};
    if (MacWSSteamSemaphoreLockState(handle, &state) != 0) return -1;
    int result = 0;
    int resultError = 0;
    if (state.value == 0) {
        result = -1;
        resultError = EAGAIN;
    } else {
        state.value--;
        if (MacWSSteamSemaphoreWriteState(handle->descriptor, &state) != 0) {
            result = -1;
            resultError = errno;
        }
    }
    return MacWSSteamSemaphoreUnlockState(
        handle, result, resultError);
}

static int MacWSSteamSemaphoreLocalPost(
        MacWSSteamSemaphoreHandle *handle, bool *brokerRequired) {
    if (brokerRequired) *brokerRequired = false;
    MacWSSteamSemaphoreState state = {0};
    if (MacWSSteamSemaphoreLockState(handle, &state) != 0) return -1;
    int result = 0;
    int resultError = 0;
    if (state.waiterCount != 0) {
        if (brokerRequired) *brokerRequired = true;
    } else if (state.value == MACWS_STEAM_SEM_VALUE_MAX) {
        result = -1;
        resultError = EOVERFLOW;
    } else {
        state.value++;
        if (MacWSSteamSemaphoreWriteState(handle->descriptor, &state) != 0) {
            result = -1;
            resultError = errno;
        }
    }
    return MacWSSteamSemaphoreUnlockState(
        handle, result, resultError);
}

static int MacWSSteamSemaphoreLocalGetValue(
        MacWSSteamSemaphoreHandle *handle, int *value) {
    if (!value) {
        errno = EINVAL;
        return -1;
    }
    MacWSSteamSemaphoreState state = {0};
    if (MacWSSteamSemaphoreLockState(handle, &state) != 0) return -1;
    *value = (int)state.value;
    return MacWSSteamSemaphoreUnlockState(handle, 0, 0);
}

static int MacWSSteamSemTryWait(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_trywait(semaphore);
    void *caller = __builtin_return_address(0);
    // RE-confirmed via gameoverlayrenderer UUID
    // 529F4E8F-0FFB-30F9-88EF-AE0918F4C325: +0xa278 implements its bounded
    // semaphore acquisition as usleep(10000) at +0xa2d8 followed by
    // sem_trywait at +0xa2e0 (return +0xa2e4). In the opt-in A/B, replace
    // only that exact polling pair with a brokered 10 ms event wait. The
    // broker consumes a real token or returns EAGAIN at the same deadline.
    int result = MacWSIsExactOverlayEventWaitCallSite(caller, 0xa2e4) ?
        MacWSSteamSemaphoreBrokerSocketTimedWait(
            handle->brokerGeneration, 10000) :
        MacWSSteamSemaphoreLocalTryWait(handle);
    MacWSSteamSemaphoreDiagnoseCaller(
        "trywait", handle, caller);
    return result;
}

static int MacWSSteamSemWait(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_wait(semaphore);
    MacWSSteamSemaphoreDiagnose("wait-enter", handle->name, 0, 0, handle);
    MacWSSteamSemaphoreDiagnoseCaller(
        "wait-enter", handle, __builtin_return_address(0));
    int result = MacWSSteamSemaphoreLocalTryWait(handle);
    if (result != 0 && errno == EAGAIN)
        result = MacWSSteamSemaphoreConsumeKernelToken(handle, false);
    MacWSSteamSemaphoreDiagnoseCaller(
        "wait-return", handle, __builtin_return_address(0));
    return result;
}

static int MacWSSteamSemPost(sem_t *semaphore) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_post(semaphore);
    bool brokerRequired = false;
    int result = MacWSSteamSemaphoreLocalPost(handle, &brokerRequired);
    unsigned value = 0;
    if (result == 0 && brokerRequired)
        result = MacWSSteamSemaphoreBrokerSocketValue(
            MACWS_STEAM_SEM_SOCKET_POST, handle->brokerGeneration, &value);
    MacWSSteamSemaphoreDiagnose("post", handle->name, result, value,
                                handle);
    MacWSSteamSemaphoreDiagnoseCaller(
        "post", handle, __builtin_return_address(0));
    return result;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int MacWSSteamSemGetValue(sem_t *semaphore, int *value) {
    MacWSSteamSemaphoreHandle *handle = MacWSSteamSemaphoreFind(semaphore);
    if (!handle) return sem_getvalue(semaphore, value);
    if (!value) {
        errno = EINVAL;
        return -1;
    }
    return MacWSSteamSemaphoreLocalGetValue(handle, value);
}

// Preserve Valve's explicit sem_trywait(EAGAIN) + usleep(timeout) polling
// contract. Runtime LLDB showed that discarding this deadline left steam_osx
// indefinitely blocked on a process-local semaphore which Helper never opens.
static int MacWSSteamUsleep(useconds_t microseconds) {
    // The matching +0xa2e4 sem_trywait above now performs this exact 10 ms
    // deadline as an event wait. Suppress only its UUID-locked predecessor;
    // leaving both would double Valve's timeout to 20 ms on EAGAIN.
    if (microseconds == 10000 && MacWSIsExactOverlayEventWaitCallSite(
            __builtin_return_address(0), 0xa2dc)) return 0;
    if (!MacWSIsSteamClientProcess()) return usleep(microseconds);
    char threadName[64] = {0};
    if (pthread_getname_np(pthread_self(), threadName,
                           sizeof(threadName)) == 0 &&
        !strcmp(threadName, "CGamepadAPITask::Run")) {
        // Runtime sample steam-helper-wfe-delay.sample attributed 1467/1520
        // samples (and ~99% process CPU) to this disabled controller backend
        // repeatedly completing its 10 ms userspace deadline. The production
        // launcher disables all three SDL joystick backends, so preserve the
        // cross-runtime kernel wait's observed permanent block for this one
        // optional thread. Mouse, keyboard and MacWS touch input do not use
        // this subsystem.
        return usleep(microseconds);
    }
    return MacWSSteamRelativeDelay(microseconds);
}

static int MacWSSteamNanosleep(const struct timespec *requested,
                               struct timespec *remaining) {
    if (!MacWSIsSteamClientProcess()) return nanosleep(requested, remaining);
    char threadName[64] = {0};
    if (pthread_getname_np(pthread_self(), threadName,
                           sizeof(threadName)) != 0 ||
        strcmp(threadName, "HTMLController Commands"))
        return nanosleep(requested, remaining);
    if (!requested || requested->tv_sec < 0 || requested->tv_nsec < 0 ||
        requested->tv_nsec >= 1000000000L) {
        errno = EINVAL;
        return -1;
    }
    uint64_t microseconds = (uint64_t)requested->tv_sec * 1000000ULL +
        ((uint64_t)requested->tv_nsec + 999ULL) / 1000ULL;
    // This runtime-confirmed command-pump sleep is short. Keep longer waits on
    // their native implementation rather than silently collapsing real Steam
    // deadlines into a single scheduling round trip.
    if (microseconds == 0) microseconds = 1;
    if (microseconds > 100000ULL)
        return nanosleep(requested, remaining);
    int result = MacWSSteamRelativeDelay((useconds_t)microseconds);
    if (result == 0 && remaining) memset(remaining, 0, sizeof(*remaining));
    return result;
}

// Steam derives the POSIX-shm name independently in steam_osx and Steam
// Helper. Besides the epoch cleanup above, this remains a passthrough: the
// shared bytes keep using Darwin's native shm implementation.
static int MacWSSteamShmOpen(const char *name, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    bool managedExclusiveCreate = MacWSIsSteamSharedMemoryName(name) &&
        (flags & (O_CREAT | O_EXCL)) == (O_CREAT | O_EXCL);
    int manifestDescriptor = -1;
    bool currentObject = false;
    int manifestMutexError = 0;
    bool manifestMutexLocked = false;
    if (managedExclusiveCreate) {
        manifestMutexError = pthread_mutex_lock(&gMacWSSteamShmManifestLock);
        manifestMutexLocked = manifestMutexError == 0;
        if (manifestMutexLocked &&
            MacWSSteamShmManifestLockCurrent(
                name, &manifestDescriptor, &currentObject) != 0) {
            manifestMutexError = errno ?: EIO;
        }
    }

    int result = -1;
    if (managedExclusiveCreate && manifestMutexError != 0) {
        errno = manifestMutexError;
    } else {
        result = (flags & O_CREAT) ? shm_open(name, flags, mode) :
            shm_open(name, flags);
        // If no object with this name has been recorded in this launch, an
        // EEXIST object predates the manifest/epoch. Reclaim exactly that
        // name and retry the original exclusive create once.
        if (managedExclusiveCreate && result < 0 && errno == EEXIST &&
            !currentObject) {
            (void)shm_unlink(name);
            result = shm_open(name, flags, mode);
        }
        if (managedExclusiveCreate && result >= 0 && !currentObject &&
            MacWSSteamShmManifestRecordLocked(
                manifestDescriptor, name) != 0) {
            int savedRecordError = errno ?: EIO;
            close(result);
            (void)shm_unlink(name);
            result = -1;
            errno = savedRecordError;
        }
    }
    int savedError = errno;
    if (manifestDescriptor >= 0) {
        (void)flock(manifestDescriptor, LOCK_UN);
        close(manifestDescriptor);
    }
    if (manifestMutexLocked)
        pthread_mutex_unlock(&gMacWSSteamShmManifestLock);
    if (getenv("MACWS_STEAM_SHM_DIAGNOSTICS") &&
        MacWSIsSteamProcess() && name) {
        struct stat status = {0};
        int statResult = result >= 0 ? fstat(result, &status) : -1;
        dprintf(STDERR_FILENO,
                "[MacWSSteamShm] pid=%d program=%s op=open name=%s "
                "flags=%#x mode=%#o fd=%d errno=%d stat=%d dev=%llu "
                "inode=%llu size=%lld\n",
                getpid(), getprogname() ?: "?", name, flags, mode, result,
                result < 0 ? savedError : 0, statResult,
                statResult == 0 ? (unsigned long long)status.st_dev : 0,
                statResult == 0 ? (unsigned long long)status.st_ino : 0,
                statResult == 0 ? (long long)status.st_size : 0);
    }
    errno = savedError;
    return result;
}

static int MacWSSteamShmUnlink(const char *name) {
    int result = shm_unlink(name);
    int savedError = errno;
    if (getenv("MACWS_STEAM_SHM_DIAGNOSTICS") &&
        MacWSIsSteamProcess() && name) {
        dprintf(STDERR_FILENO,
                "[MacWSSteamShm] pid=%d program=%s op=unlink name=%s "
                "result=%d errno=%d\n",
                getpid(), getprogname() ?: "?", name, result,
                result == 0 ? 0 : savedError);
    }
    errno = savedError;
    return result;
}

// Opt-in proof for Steam's CThread startup.  The top-level web helper embeds
// two Valve threads next to each other; one services CChromeIPCServer and the
// other services controller input.  A plain process sample cannot distinguish
// "the IPC thread was never created" from "it exited before sampling", so log
// the real pthread_create result and full caller chain when explicitly asked.
static int MacWSSteamPthreadCreate(pthread_t *thread,
        const pthread_attr_t *attributes, void *(*startRoutine)(void *),
        void *context) {
    int result = pthread_create(thread, attributes, startRoutine, context);
    if (getenv("MACWS_STEAM_THREAD_DIAGNOSTICS") &&
        getprogname() && !strcmp(getprogname(), "Steam Helper")) {
        dprintf(STDERR_FILENO,
                "[MacWSSteamThread] pid=%d result=%d thread=%#llx "
                "start=%p context=%p caller=%p\n",
                getpid(), result,
                thread ? (unsigned long long)(uintptr_t)*thread : 0,
                startRoutine, context, __builtin_return_address(0));
        void *frames[10] = {0};
        int frameCount = backtrace(
            frames, (int)(sizeof(frames) / sizeof(frames[0])));
        for (int index = 1; index < frameCount; index++) {
            Dl_info frameImage = {0};
            dladdr(frames[index], &frameImage);
            dprintf(STDERR_FILENO,
                    "[MacWSSteamThread] frame=%d address=%p image=%s "
                    "offset=%#llx\n",
                    index, frames[index], frameImage.dli_fname ?: "?",
                    frameImage.dli_fbase ? (unsigned long long)(
                        (uintptr_t)frames[index] -
                        (uintptr_t)frameImage.dli_fbase) : 0);
        }
    }
    return result;
}

DYLD_INTERPOSE(MacWSSteamSemOpen, sem_open)
DYLD_INTERPOSE(MacWSSteamSemClose, sem_close)
DYLD_INTERPOSE(MacWSSteamSemUnlink, sem_unlink)
DYLD_INTERPOSE(MacWSSteamSemWait, sem_wait)
DYLD_INTERPOSE(MacWSSteamSemTryWait, sem_trywait)
DYLD_INTERPOSE(MacWSSteamSemPost, sem_post)
DYLD_INTERPOSE(MacWSSteamSemGetValue, sem_getvalue)
#pragma clang diagnostic pop
DYLD_INTERPOSE(MacWSSteamUsleep, usleep)
DYLD_INTERPOSE(MacWSSteamNanosleep, nanosleep)
DYLD_INTERPOSE(MacWSSteamShmOpen, shm_open)
DYLD_INTERPOSE(MacWSSteamShmUnlink, shm_unlink)
DYLD_INTERPOSE(MacWSSteamPthreadCreate, pthread_create)
